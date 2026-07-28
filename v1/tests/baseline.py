#!/usr/bin/env python3
"""THE ENTRY POINTS, MEASURED ONCE AND WATCHED AFTERWARDS.

A source does not usually break loudly. dnf5 prints a fixed-width table where
dnf4 printed pipes; osquery renames a column between releases; a tool stops being
installed; a permission changes. In every one of those the collection still
succeeds — it just returns fewer rows, or the same rows with a column gone, and
everything downstream carries on with less. That is the failure this file exists
to catch.

So each entry point is recorded once, deliberately, as a BASELINE: which columns
it produced, how many rows, and how long it took. Afterwards the suite compares
against it and complains when

  * a column that used to be produced is gone (a rename or a dropped field),
  * the row count collapses (below half the baseline, or to zero),
  * a source that produced nothing does not SAY it may produce nothing,
  * or it became much slower than it was.

Growth is never a failure: more rows and more columns are what a healthy machine
does. The baseline is data about THIS machine, so it lives beside the tests and
is updated on purpose:

    cd v1 && PYTHONNOUSERSITE=1 python3 tests/baseline.py --update

Run it when a change to a rule is meant to change what it collects — and read the
diff it prints before committing, because that diff is the claim you are making.
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

V1 = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, V1)

BASELINE = Path(V1) / "tests" / "baseline.json"

# How far a source may fall before it counts as broken rather than quiet. A
# process list moves by a few percent a minute; a package inventory hardly moves
# at all. Half is loose enough for both and still catches a source that has
# stopped answering.
MIN_SHARE = 0.5
# A collection has sixty seconds per source. A source that has grown past this
# is on its way to failing outright, and it is better to hear it now.
SLOW_SECONDS = 25.0


def measure(store) -> dict:
    """Run every entry point once and record what it produced."""
    from core import osquery, pipeline, shell

    out = {}
    for rule in pipeline.load_inputs():
        name = rule.get("name")
        kind = str(rule.get("kind", ""))
        if kind == "tetragon" or not (rule.get("query") or rule.get("command")):
            continue
        table = rule.get("table") or name
        t0 = time.perf_counter()
        arity_wrong, arity_seen = 0, {}
        try:
            if kind == "command":
                path = shell.run_to_file(rule["command"])
                # THE SAME PASS ANSWERS BOTH QUESTIONS. A command's output has no
                # header, so columns are mapped by POSITION: a value holding a tab
                # or a newline shifts data sideways or tears the row in half. It
                # is counted here rather than in a second collection, because
                # running every source twice for two questions is the sort of cost
                # that gets a check deleted later.
                want = len(rule.get("tsv_columns") or [])
                with open(path, errors="replace") as fh:
                    for line in fh:
                        if line.strip():
                            n = line.rstrip("\n").count("\t") + 1
                            arity_seen[n] = arity_seen.get(n, 0) + 1
                            if n != want:
                                arity_wrong += 1
                rows = store.replace_table_from_tsv(
                    table, path, list(rule.get("tsv_columns") or []))
            else:
                path = osquery.run_to_file(rule["query"])
                rows = store.replace_table_from_json(table, path)
            os.unlink(path)
            err = ""
        except Exception as e:  # noqa: BLE001 — a broken source is the news here
            rows, err = 0, str(e).splitlines()[0][:200]
        out[name] = {
            "table": table,
            "rows": rows,
            "arity_wrong": arity_wrong,
            "arity_seen": arity_seen,
            "seconds": round(time.perf_counter() - t0, 2),
            "columns": sorted(store.columns(table)) if not err else [],
            "error": err,
            "may_be_empty": bool(rule.get("may_be_empty")),
        }
    return out


# fields that describe THIS run rather than the shape of the source, so they are
# not written into the baseline (they would make every diff noisy)
_RUNTIME = ("arity_wrong", "arity_seen")


def strip_runtime(measured: dict) -> dict:
    return {k: {a: b for a, b in v.items() if a not in _RUNTIME}
            for k, v in measured.items()}


def load() -> dict:
    try:
        return json.loads(BASELINE.read_text())
    except Exception:  # noqa: BLE001 — no baseline yet is a normal first run
        return {}


def compare(now: dict, was: dict) -> list[str]:
    """What changed for the worse. Growth is not a failure."""
    problems = []
    for name, base in was.items():
        cur = now.get(name)
        if cur is None:
            problems.append(f"{name}: the entry point is gone (it was collecting "
                            f"{base['rows']} rows)")
            continue
        if cur["error"]:
            problems.append(f"{name}: fails now — {cur['error'][:120]}")
            continue
        lost = [c for c in base["columns"] if c not in cur["columns"]]
        if lost:
            problems.append(f"{name}: no longer produces {', '.join(lost[:6])}")
        floor = int(base["rows"] * MIN_SHARE)
        if base["rows"] > 0 and cur["rows"] < max(floor, 1):
            problems.append(f"{name}: {cur['rows']} rows where it used to collect "
                            f"{base['rows']}")
        if cur["rows"] == 0 and not cur["may_be_empty"]:
            problems.append(f"{name}: collected nothing, and the rule does not say "
                            f"it may (add may_be_empty: with the reason)")
        if cur["seconds"] > SLOW_SECONDS and cur["seconds"] > base["seconds"] * 3:
            problems.append(f"{name}: {cur['seconds']}s, was {base['seconds']}s")
    for name, cur in now.items():
        if name not in was and not cur["error"]:
            # not a failure — but say it, so a new source is a decision and not a
            # thing that appeared
            problems.append(f"NEW {name}: {cur['rows']} rows "
                            f"({len(cur['columns'])} columns) — run "
                            f"tests/baseline.py --update to record it")
    return problems


def main() -> int:
    from core.store import Store

    store = Store()
    try:
        now = measure(store)
    finally:
        store.close()
    was = load()
    if "--update" in sys.argv or not was:
        diff = compare(now, was) if was else []
        for d in diff:
            print("  changing:", d)
        BASELINE.write_text(
            json.dumps(strip_runtime(now), indent=1, sort_keys=True) + "\n")
        total = sum(v["rows"] for v in now.values())
        print(f"recorded {len(now)} entry points, {total:,} rows in total")
        return 0
    problems = compare(now, was)
    for p in problems:
        print("  FAIL", p)
    print(f"{len(now)} entry points checked against the baseline, "
          f"{len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

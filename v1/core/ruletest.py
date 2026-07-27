"""Run the `tests:` a rule declares about its own table.

WHY A RULE CARRIES ITS OWN TESTS. A source is a query or a shell command whose
output shape is decided by somebody else's tool — dnf5 prints a fixed-width table
where dnf4 printed pipes, osquery fills a column on macOS and leaves it empty on
Linux, `ss` shows an owner only for your own sockets. When one of those changes,
the source does not fail: it collects fewer rows, or the same rows with an empty
column, and everything downstream keeps working on less. That is the failure mode
this file exists for — the rule states what it must produce, and the statement is
checked against what it did produce.

The vocabulary is deliberately small, because a test nobody writes protects
nothing:

    tests:
      min_rows: 10                  # fewer than this means the source went quiet
      expect_columns: [a, b]        # these must exist (the contract check does
                                    # the same for `columns:`, this is for rules
                                    # that declare neither)
      not_empty: [pid, name]        # these must be filled in most rows
      fill: 0.9                     # "most" — the share required, default 0.9
      expect:                       # named conditions, with a floor or a ceiling
        - name: systemd timers are collected
          where: "kind = 'timer'"
          min_rows: 1
        - name: every IP socket has its protocol decoded
          where: "family_name NOT IN ('unix','packet') AND protocol_name = ''"
          max_rows: 0             # "there must be none of these"

Everything is evaluated as SQL against the table the rule filled, so a test can
say anything SQL can and nothing it cannot — no code from a rule is executed here.
"""
from __future__ import annotations

from .db import ident, select_only


def _count(store, table: str, where: str = "") -> int:
    sql = f"SELECT count(*) FROM {ident(table)}"
    if where:
        sql += f" WHERE {where}"
    return int(store.fetch(sql)["rows"][0][0])


def run_one(store, rule: dict) -> list[dict]:
    """Check one rule's tests. Returns a result per assertion, never raises."""
    spec = rule.get("tests") or {}
    table = rule.get("table") or rule.get("name")
    out: list[dict] = []

    def add(name, passed, detail=""):
        out.append({"rule": rule.get("name"), "table": table, "test": name,
                    "passed": bool(passed), "detail": detail})

    if not spec:
        return out
    try:
        cols = store.columns(table)
    except Exception as e:  # noqa: BLE001
        add("table exists", False, str(e).splitlines()[0])
        return out
    if not cols:
        add("table exists", False, "the source produced no table")
        return out

    want = spec.get("expect_columns") or []
    missing = [c for c in want if c not in cols]
    if want:
        add("expected columns", not missing,
            "missing: " + ", ".join(missing) if missing else "")

    total = _count(store, table)
    mr = spec.get("min_rows")
    if mr is not None:
        add(f"at least {mr} rows", total >= int(mr), f"got {total}")

    fill = float(spec.get("fill", 0.9))
    for c in spec.get("not_empty") or []:
        if c not in cols:
            add(f"{c} is filled", False, "no such column")
            continue
        filled = _count(store, table,
                        f"{ident(c)} IS NOT NULL AND CAST({ident(c)} AS VARCHAR) <> ''")
        share = filled / total if total else 0.0
        add(f"{c} is filled", share >= fill,
            f"{filled} of {total} rows ({share:.0%}, wanted {fill:.0%})")

    for e in spec.get("expect") or []:
        where = str(e.get("where") or "")
        if where and not select_only(f"SELECT 1 FROM x WHERE {where}"):
            add(str(e.get("name") or where), False, "the condition is not a plain SELECT")
            continue
        try:
            n = _count(store, table, where)
        except Exception as ex:  # noqa: BLE001 — a broken condition is a failure
            add(str(e.get("name") or where), False, str(ex).splitlines()[0])
            continue
        name = str(e.get("name") or where)
        if "max_rows" in e:
            # the "there must be none of these" form — the one that states an
            # invariant rather than a floor, and the one that catches a column
            # quietly going empty for a subset of rows
            ceil = int(e["max_rows"])
            add(name, n <= ceil, f"got {n}, allowed {ceil}")
        else:
            floor = int(e.get("min_rows", 1))
            add(name, n >= floor, f"got {n}, wanted {floor}")
    return out


def run_all(store, rules: list[dict]) -> list[dict]:
    out: list[dict] = []
    for r in rules:
        out.extend(run_one(store, r))
    return out

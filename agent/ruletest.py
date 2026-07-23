"""Running and testing expertise rules straight from the UI.

Two things without which a rule cannot be written "blind":

  run_now(pipe, ref)  - RUN NOW: take the live input (the command of the input
                        connected to the rule in the pipeline), run the plugin
                        and show what came out. No need to wait for the
                        interval and dig into "Last run".

  run_tests(pipe, ref) - run the `tests:` section inside the rule itself (a
                        technique from R-Vision SIEM, where the test lives next
                        to the rule). A rule is self-checking: the author writes
                        the input and the expectation, presses a button and sees
                        pass/fail.

The format of the tests in the rule's YAML:
    tests:
      - name: an ordinary line
        input: |
          rpm<TAB>bash<TAB>5.2.15
        expect:
          rows: 1                      # exactly this many rows
          min_rows: 1                  # or "no fewer than"
          contains: {kind: rpm}        # such a row is among the results
          row0: {name: bash}           # checking a specific row by index
"""
from .core import pipeline as P


def _rule(pipe, ref: str) -> dict:
    for cat in ("normalize", "enrich", "filters"):
        cfg = pipe.objects.get(cat, {}).get(ref)
        if cfg:
            return {"cfg": cfg, "cat": cat}
    return {}


def input_for(pipe, ref: str) -> dict:
    """The input connected to this rule in some pipeline."""
    for pname, pl in pipe.pipelines.items():
        nodes = {n["id"]: n for n in pl.get("nodes", [])}
        targets = [n["id"] for n in pl.get("nodes", []) if n.get("ref") == ref]
        for a, b in pl.get("edges", []):
            if b in targets and a in nodes and nodes[a].get("kind") == "input":
                icfg = pipe.objects.get("inputs", {}).get(nodes[a].get("ref"))
                if icfg:
                    return {"pipeline": pname, "ref": nodes[a]["ref"],
                            "title": icfg.get("title", ""),
                            "command": icfg.get("command", "")}
    return {}


def run_now(pipe, ref: str, sample: str = "") -> dict:
    """Run the rule against the live input (or against the given text)."""
    import subprocess
    found = _rule(pipe, ref)
    if not found:
        return {"error": "rule \u00ab%s\u00bb not found" % ref}
    cfg, cat = found["cfg"], found["cat"]
    src, text = "provided manually", sample

    if not text:
        inp = input_for(pipe, ref)
        if not inp:
            return {"error": "no input is connected to this rule — "
                             "paste sample text instead"}
        cmd = inp["command"]
        if isinstance(cmd, str):
            cmd = ["bash", "-c", cmd]
        try:
            text = subprocess.run(cmd, capture_output=True, text=True,
                                  timeout=60).stdout
        except Exception as e:
            return {"error": "input failed: %s" % e}
        src = "%s (%s)" % (inp["title"] or inp["ref"], inp["ref"])

    code = (cfg.get("code") or "").strip()
    if not code:
        return {"error": "the rule has no Python plugin (code field)"}
    try:
        rows = (P.run_enrich(code, []) if cat == "enrich"
                else P.run_python(code, text))
    except Exception as e:
        return {"error": str(e), "source": src,
                "input_preview": (text or "")[:4000]}

    cols = []
    for r in rows:
        for k in r:
            if k not in cols:
                cols.append(k)
    return {"error": "", "source": src, "count": len(rows), "columns": cols,
            "rows": rows[:200], "input_preview": (text or "")[:4000],
            "input_lines": len((text or "").splitlines())}


def _check(exp: dict, rows: list) -> tuple:
    """Checking the test expectations. Returns (ok, explanation)."""
    if "rows" in exp:
        want = int(exp["rows"])
        if len(rows) != want:
            return False, "expected %d rows, got %d" % (want, len(rows))
    if "min_rows" in exp:
        want = int(exp["min_rows"])
        if len(rows) < want:
            return False, "expected at least %d rows, got %d" % (want, len(rows))
    if "contains" in exp and isinstance(exp["contains"], dict):
        want = {str(k): str(v) for k, v in exp["contains"].items()}
        hit = any(all(str(r.get(k, "")) == v for k, v in want.items()) for r in rows)
        if not hit:
            return False, "no row with values %s" % want
    for key, val in exp.items():
        if not (key.startswith("row") and key[3:].isdigit()):
            continue
        i = int(key[3:])
        if i >= len(rows):
            return False, "no row at index %d (of %d)" % (i, len(rows))
        for k, v in (val or {}).items():
            got = str(rows[i].get(k, ""))
            if got != str(v):
                return False, "row %d, field %s: expected %r, got %r" % (
                    i, k, str(v), got)
    return True, "ok"


def run_tests(pipe, ref: str) -> dict:
    """Run the tests: section of a rule. The test lives next to the rule."""
    found = _rule(pipe, ref)
    if not found:
        return {"error": "rule \u00ab%s\u00bb not found" % ref, "tests": []}
    cfg, cat = found["cfg"], found["cat"]
    tests = cfg.get("tests") or []
    if not tests:
        return {"error": "", "tests": [], "hint":
                "the rule has no tests: section — add input and expectations "
                "to make it self-checking"}
    code = (cfg.get("code") or "").strip()
    if not code:
        return {"error": "the rule has no Python plugin (code field)", "tests": []}

    out, passed = [], 0
    for i, t in enumerate(tests):
        name = str((t or {}).get("name") or "test %d" % (i + 1))
        text = str((t or {}).get("input") or "")
        exp = (t or {}).get("expect") or {}
        try:
            rows = (P.run_enrich(code, []) if cat == "enrich"
                    else P.run_python(code, text))
        except Exception as e:
            out.append({"name": name, "passed": False,
                        "detail": "plugin raised: %s" % e, "got": 0})
            continue
        ok, detail = _check(exp, rows)
        passed += 1 if ok else 0
        out.append({"name": name, "passed": ok, "detail": detail,
                    "got": len(rows),
                    "sample": rows[0] if rows else {}})
    return {"error": "", "tests": out, "passed": passed, "total": len(out)}

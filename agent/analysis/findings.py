"""The findings ENGINE. The rules themselves live in the expertise, not here.

This file used to hold eleven rules written directly in Python: to add a check
you had to edit the application code. That broke principle 2 of
expertise/PRINCIPLES.md ("the logic lives in the expertise"): a user could
neither read a rule nor fix it without opening the sources.
sources.

Now the rules are expertise objects in `expertise/findings/*.yaml`
(type: finding). What is left here is only the executor: take the SQL of a rule,
run it against the right database, collect the evidence from the template and
hand it to the interface.

The rule format:
    severity   high | medium | low
    source     state | events   - which database the sql runs against
    sql        SELECT ...       - read only, the database is opened ro
    evidence   "{column} ..."   - the template of an evidence line
    why        why this matters (without it a finding is useless)
    action     what to do about it
    time_col   the column with the time - it goes into the when field
    explore_*  where to jump in "State" to look at it yourself
"""
import sqlite3

SEV = {"high": 3, "medium": 2, "low": 1}


class _Safe(dict):
    """The evidence template must not fail because a column is missing."""

    def __missing__(self, key):
        return ""


def _ro(path):
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    return con


def _run(rule: dict, con) -> list:
    sql = str(rule.get("sql") or "").strip()
    if not sql:
        return []
    low = sql.lower()
    # a rule may only READ: the database is opened ro anyway, but it is better
    # to refuse right away and clearly than to get an sqlite error mid-run
    if not low.startswith("select") or any(
            w in low for w in ("attach", "pragma", "insert", "update",
                               "delete", "drop", "alter", "create")):
        raise ValueError("a finding rule may contain only SELECT")
    return [dict(r) for r in con.execute(sql)]


def build(db, eventsdb=None, rules: dict | None = None) -> dict:
    """rules - expertise objects of the findings category (ref -> yaml)."""
    if rules is None:                       # standalone call (tests, CLI)
        from ..core.pipeline import StatePipeline
        rules = StatePipeline(db).objects.get("findings", {})

    out, errors = [], []
    cons = {}
    try:
        for ref in sorted(rules):
            r = rules[ref]
            src = str(r.get("source") or "state")
            try:
                if src not in cons:
                    if src == "events":
                        if eventsdb is None:
                            continue
                        cons[src] = _ro(eventsdb.path)
                    else:
                        cons[src] = _ro(db.path)
                rows = _run(r, cons[src])
            except Exception as e:
                # a rule may refer to a table that does not exist yet - that is
                # no reason to break the whole dashboard, but staying silent is wrong
                errors.append("%s: %s" % (r.get("name", ref), e))
                continue
            if not rows:
                continue
            tmpl = str(r.get("evidence") or "")
            ev, when = [], ""
            tcol = str(r.get("time_col") or "")
            for row in rows:
                ev.append(tmpl.format_map(_Safe(row)).strip()
                          if tmpl else str(row))
                if tcol and row.get(tcol) and str(row[tcol]) > when:
                    when = str(row[tcol])
            out.append({
                "severity": str(r.get("severity") or "low"),
                "title": "%s: %d" % (r.get("title", ref), len(rows)),
                "why": str(r.get("why") or ""),
                "action": str(r.get("action") or ""),
                "evidence": ev[:12], "count": len(rows),
                "when": when,               # when this happened last
                "rule": r.get("name", ref), "rule_id": r.get("id", ""),
                "source": src,
                "table": str(r.get("explore_table") or ""),
                "col": str(r.get("explore_col") or ""),
                "val": str(r.get("explore_val") or ""),
                "tag": str(r.get("tag") or "")})
    finally:
        for c in cons.values():
            c.close()

    out.sort(key=lambda x: (-SEV.get(x["severity"], 0), -x["count"]))
    return {"findings": out,
            "total": sum(f["count"] for f in out),
            "high": sum(1 for f in out if f["severity"] == "high"),
            "medium": sum(1 for f in out if f["severity"] == "medium"),
            "low": sum(1 for f in out if f["severity"] == "low"),
            "rules": len(rules), "errors": errors}

"""The correlation engine: turns a stream of events into detections.

Until now `type: detection` rules were only a placeholder - the engine did not
execute them, and the rule_*/risk_score fields of the taxonomy always stayed
empty. Here they start working.

The rule model (following R-Vision: filter -> grouping -> threshold -> window):

    where:      the SQL condition that selects events
    group_by:   which fields to group by (who / where to / over what)
    threshold:  how many events in a group are enough
    window:     within how many seconds
    severity/tactic/technique/title/message

A hit produces a NEW event in the same table (event_kind = alert) - a detection
lives next to the raw events, is found by the same filters and is visible in the
same feed. Deduplication: event_id includes the window, so the same hit is not
multiplied on every run of the pipeline.
"""
import datetime
import re

_SAFE = re.compile(r"^[A-Za-z0-9_]+$")


def _now():
    return datetime.datetime.now(datetime.timezone.utc)


def _iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def _fmt(template: str, ctx: dict) -> str:
    """Substituting {field} into the message text - no eval, only replacement."""
    out = template or ""
    for k, v in ctx.items():
        out = out.replace("{%s}" % k, str(v))
    return out


def run(eventsdb, rules: dict, now=None) -> dict:
    """Runs all detection rules. Returns {alerts, fired, errors}."""
    now = now or _now()
    alerts, fired, errors = [], [], []

    for ref, rule in sorted(rules.items()):
        if not isinstance(rule, dict) or rule.get("enabled") is False:
            continue
        where = str(rule.get("where") or "").strip()
        group_by = [g for g in (rule.get("group_by") or []) if _SAFE.match(str(g))]
        try:
            threshold = max(1, int(rule.get("threshold", 1)))
            window = max(1, int(rule.get("window", 300)))
        except (TypeError, ValueError):
            errors.append("%s: threshold/window is not a number" % ref)
            continue
        if not where:
            errors.append("%s: no where condition" % ref)
            continue

        since = _iso(now - datetime.timedelta(seconds=window))
        cols = ", ".join('"%s"' % g for g in group_by)
        sel = (cols + ", ") if cols else ""
        grp = (" GROUP BY " + cols) if cols else ""
        sql = (f"SELECT {sel}COUNT(*) AS n, MIN(ts) AS first_ts, MAX(ts) AS last_ts "
               f"FROM events WHERE ({where}) AND ts >= '{since}' "
               f"AND COALESCE(event_kind,'') <> 'alert'{grp}")
        res = eventsdb.query(sql)
        if res.get("error"):
            errors.append("%s: %s" % (ref, res["error"]))
            continue

        for row in res.get("rows", []):
            n = int(row.get("n") or 0)
            if n < threshold:
                continue
            ctx = {g: (row.get(g) or "") for g in group_by}
            ctx["count"] = n
            # the window is part of the id - one hit is not duplicated every run
            bucket = int(now.timestamp()) // window
            gid = "|".join(str(ctx.get(g, "")) for g in group_by) or "-"
            sev = {"low": 30, "medium": 55, "high": 75,
                   "critical": 90}.get(str(rule.get("severity", "medium")).lower(), 55)
            alerts.append({
                "ts": _iso(now),
                "event_id": "alert:%s:%s:%s" % (rule.get("name", ref), gid, bucket),
                "event_kind": "alert",
                "event_category": rule.get("category", "intrusion_detection"),
                "event_type": "info",
                "event_action": rule.get("name", ref),
                "event_outcome": "success",
                "event_severity": sev,
                "risk_score": sev,
                "event_module": "correlation",
                "event_dataset": "detection",
                "event_provider": "lisin",
                "rule_id": str(rule.get("id", "")),
                "rule_name": str(rule.get("title", rule.get("name", ref))),
                "rule_tactic": str(rule.get("tactic", "")),
                "rule_technique": str(rule.get("technique", "")),
                "subject_type": "system",
                "subject_name": ctx.get("subject_name", "") or "correlation",
                "object_type": "event",
                "object_name": gid,
                "message": _fmt(rule.get("message")
                                or "%s: %d events in %d s" % (
                                    rule.get("title", ref), n, window), ctx),
                "not_normalized": "",
            })
            fired.append({"rule": rule.get("title", ref), "group": gid,
                          "count": n, "window": window,
                          "first": row.get("first_ts", ""),
                          "last": row.get("last_ts", "")})

    added = eventsdb.append(alerts) if alerts else 0
    return {"alerts": alerts, "added": added, "fired": fired, "errors": errors}

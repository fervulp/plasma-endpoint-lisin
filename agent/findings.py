"""ДВИЖОК находок. Сами правила живут в экспертизе, а не здесь.

Раньше в этом файле лежали одиннадцать правил, написанных прямо на Python:
чтобы добавить проверку, надо было править код приложения. Это нарушало
положение 2 из expertise/PRINCIPLES.md («логика живёт в экспертизе»):
пользователь не мог ни прочитать правило, ни поправить его, не открывая
исходники.

Теперь правила — объекты экспертизы `expertise/findings/*.yaml`
(type: finding). Здесь остался только исполнитель: взять SQL правила,
выполнить против нужной базы, собрать доказательства по шаблону и отдать
в интерфейс.

Формат правила:
    severity   high | medium | low
    source     state | events   — против какой базы выполняется sql
    sql        SELECT ...       — только чтение, база открыта в режиме ro
    evidence   "{колонка} ..."  — шаблон строки-доказательства
    why        почему это важно (без этого находка бесполезна)
    action     что с этим делать
    time_col   колонка со временем — попадает в поле when
    explore_*  куда перейти в «Состоянии», чтобы посмотреть самому
"""
import sqlite3

SEV = {"high": 3, "medium": 2, "low": 1}


class _Safe(dict):
    """Шаблон доказательства не должен падать из-за отсутствующей колонки."""

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
    # правило может только ЧИТАТЬ: база и так открыта ro, но лучше отказать
    # сразу и понятно, чем получить ошибку sqlite посреди прогона
    if not low.startswith("select") or any(
            w in low for w in ("attach", "pragma", "insert", "update",
                               "delete", "drop", "alter", "create")):
        raise ValueError("a finding rule may contain only SELECT")
    return [dict(r) for r in con.execute(sql)]


def build(db, eventsdb=None, rules: dict | None = None) -> dict:
    """rules — объекты экспертизы категории findings (ref -> yaml)."""
    if rules is None:                       # автономный вызов (тесты, CLI)
        from .pipeline import StatePipeline
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
                # правило может ссылаться на таблицу, которой ещё нет — это
                # не повод ронять весь дашборд, но и молчать нельзя
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
                "when": when,               # когда это было в последний раз
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

"""Запуск и тестирование правил экспертизы прямо из UI.

Две вещи, без которых правило нельзя написать «вслепую»:

  run_now(pipe, ref)  — ВЫПОЛНИТЬ СЕЙЧАС: взять живой вход (команду точки
                        входа, подключённой к правилу в конвейере), прогнать
                        плагин и показать, что получилось. Не нужно ждать
                        интервала и лезть в «Last run».

  run_tests(pipe, ref) — прогнать секцию `tests:` внутри самого правила
                        (приём из R-Vision SIEM, где тест лежит рядом с
                        правилом). Правило самопроверяемо: автор пишет
                        вход и ожидание, жмёт кнопку и видит pass/fail.

Формат тестов в YAML правила:

    tests:
      - name: обычная строка
        input: |
          rpm<TAB>bash<TAB>5.2.15
        expect:
          rows: 1                      # ровно столько строк
          min_rows: 1                  # или «не меньше»
          contains: {kind: rpm}        # такая строка есть среди результата
          row0: {name: bash}           # проверка конкретной строки по индексу
"""
from . import pipeline as P


def _rule(pipe, ref: str) -> dict:
    for cat in ("normalize", "enrich", "filters"):
        cfg = pipe.objects.get(cat, {}).get(ref)
        if cfg:
            return {"cfg": cfg, "cat": cat}
    return {}


def input_for(pipe, ref: str) -> dict:
    """Точка входа, подключённая к этому правилу в каком-нибудь конвейере."""
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
    """Прогнать правило на живом входе (или на переданном тексте)."""
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
    """Проверка ожиданий теста. Возвращает (ok, пояснение)."""
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
    """Прогнать секцию tests: правила. Тест лежит рядом с правилом."""
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

"""Связи между компонентами системы.

Две задачи:

1. `model(db)` — КАРТА СВЯЗЕЙ между таблицами. Не зашита в коде: связи
   ОБНАРУЖИВАЮТСЯ измерением пересечения значений колонок. Если 90%
   значений `processes.user` встречаются в `users.name` — это связь, и её
   видно, даже если я о ней не думал. Так карта не устаревает при
   добавлении нового источника: он свяжется сам.

2. `around(db, eventsdb, pid)` — что окружает КОНКРЕТНЫЙ процесс:
   пользователь, родитель и дети, пакет, сокеты и их удалённые адреса,
   открытые файлы, юнит systemd. Раскладка (x/y) считается ЗДЕСЬ, а не в
   интерфейсе: иначе узлы прыгают при каждой перерисовке.
"""
import math
import re
import sqlite3

# служебные колонки и заведомо бессмысленные для связывания значения
SKIP_COLS = {"_id", "_src", "content", "description", "message", "detail",
             "key", "vrl", "code", "options", "raw"}
NOISE_VALUES = {"", "-", "—", "0", "1", "yes", "no", "none", "(none)",
                "unknown", "n/a", "root"}


def _ro(path):
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    return con


def _columns(con, table):
    return [r["name"] for r in con.execute(f'PRAGMA table_info("{table}")')
            if r["name"] not in SKIP_COLS]


def _values(con, table, col, limit=4000):
    """Набор непустых значений колонки — для измерения пересечения."""
    try:
        rows = con.execute(
            f'SELECT DISTINCT "{col}" FROM "{table}" '
            f'WHERE COALESCE("{col}",\'\') <> \'\' LIMIT {limit}').fetchall()
    except sqlite3.Error:
        return set()
    out = set()
    for r in rows:
        v = str(r[0]).strip().lower()
        if v and v not in NOISE_VALUES and len(v) > 2:
            out.add(v)
    return out


def _is_measure(values: set) -> bool:
    """Похоже ли на ИЗМЕРЕНИЕ, а не на идентификатор.

    Реальный случай: `processes.rss_mb` (память в МБ) и
    `vulnerabilities.cvss_score` (балл) пересеклись на восьми значениях
    (9.6, 7.4, 8.8…), и уязвимости начали цепляться к процессам ПО ОБЪЁМУ
    ПАМЯТИ. Признак структурный: дробное число — это величина; идентификатор
    дробным почти не бывает. Целые числа сюда не попадают: uid и номер порта
    остаются связуемыми.
    """
    dec = 0
    for v in values:
        try:
            float(v)
        except ValueError:
            return False
        if "." in v:
            dec += 1
    return bool(values) and dec / len(values) > 0.7


def _is_counter(values: set) -> bool:
    """Похоже ли на порядковый номер, а не на идентификатор.

    Ложные связи брались именно отсюда: `pkg_history.id` и
    `shell_history.n` — оба просто 1..200, пересечение 100%, а смысла ноль.
    Признак структурный: все значения целые и образуют плотный диапазон
    (число значений близко к длине интервала). Настоящие числовые ключи
    (uid, номер порта) разрежены и этот тест проходят.
    """
    nums = []
    for v in values:
        if not v.isdigit():
            return False
        nums.append(int(v))
    if len(nums) < 5:
        return False
    span = max(nums) - min(nums) + 1
    return span and len(nums) / span > 0.7


def model(db, min_overlap: float = 0.5, min_values: int = 3) -> dict:
    """Карта связей: какие колонки каких таблиц ссылаются друг на друга.

    Связь считается найденной, если не меньше min_overlap значений одной
    колонки встречается в другой. Порог и требование min_values отсекают
    случайные совпадения на двух-трёх строках.
    """
    con = _ro(db.path)
    try:
        tabs = [r["name"] for r in
                con.execute("SELECT name FROM _tabs ORDER BY name")]
        vals = {}
        for t in tabs:
            for c in _columns(con, t):
                v = _values(con, t, c)
                if len(v) >= min_values and not _is_counter(v) \
                        and not _is_measure(v):
                    vals[(t, c)] = v
    finally:
        con.close()

    links, seen = [], set()
    keys = list(vals)
    for i, a in enumerate(keys):
        for b in keys[i + 1:]:
            if a[0] == b[0]:
                continue                    # связи внутри таблицы не считаем
            va, vb = vals[a], vals[b]
            inter = va & vb
            if len(inter) < min_values:
                continue
            # доля считается от МЕНЬШЕГО набора: справочник (users) всегда
            # меньше, чем таблица фактов (processes), и связь «многие к
            # одному» иначе не обнаружилась бы
            ratio = len(inter) / min(len(va), len(vb))
            if ratio < min_overlap:
                continue
            k = (a, b) if a < b else (b, a)
            if k in seen:
                continue
            seen.add(k)
            links.append({"from_table": a[0], "from_col": a[1],
                          "to_table": b[0], "to_col": b[1],
                          "shared": len(inter), "ratio": round(ratio, 2),
                          "sample": sorted(inter)[:3]})
    links.sort(key=lambda x: (-x["ratio"], -x["shared"]))

    # раскладка карты считается здесь: таблицы по кругу, чтобы связи были
    # видны и узлы не прыгали между перерисовками
    involved = []
    for l in links:
        for t in (l["from_table"], l["to_table"]):
            if t not in involved:
                involved.append(t)
    nodes = []
    n = max(1, len(involved))
    for i, t in enumerate(involved):
        ang = 2 * math.pi * i / n
        deg = sum(1 for l in links
                  if l["from_table"] == t or l["to_table"] == t)
        nodes.append({"id": t, "label": t, "degree": deg,
                      "x": round(500 + 420 * math.cos(ang)),
                      "y": round(430 + 330 * math.sin(ang))})
    return {"nodes": nodes, "links": links, "tables": len(involved)}


def _q(con, sql, args=()):
    try:
        return [dict(r) for r in con.execute(sql, args)]
    except sqlite3.Error:
        return []


def _open_targets(pid: str, cap: int = 14) -> list:
    """К ЧЕМУ ПРОЦЕСС ОБРАЩАЕТСЯ ПРЯМО СЕЙЧАС — из /proc/<pid>/fd.

    Показываем ВСЁ, что открыто, с классификацией: обычный файл, устройство,
    /proc и /sys (так процесс читает состояние системы), сокет, канал.
    Раньше подобная выборка отбрасывала /proc и сокеты — и для монитора вроде
    btop не оставалось ничего, хотя именно они и есть суть его работы.

    ВАЖНОЕ ОГРАНИЧЕНИЕ, его надо говорить прямо: дескриптор виден, только
    пока файл ОТКРЫТ. Программа, которая читает /proc в цикле и сразу
    закрывает, в снимке не проявится. Чтобы видеть сами обращения, нужны
    правила аудита ядра, а это root (packaging/lisin-grant-access).
    """
    import os
    out, seen = [], set()
    d = "/proc/%s/fd" % pid
    try:
        names = os.listdir(d)
    except OSError:
        return out
    for n in names:
        try:
            t = os.readlink(os.path.join(d, n))
        except OSError:
            continue
        if t in seen:
            continue
        seen.add(t)
        if t.startswith("socket:"):
            kind = "socket"
        elif t.startswith("pipe:"):
            kind = "pipe"
        elif t.startswith("anon_inode:"):
            kind = "kernel"
        elif t.startswith(("/proc", "/sys")):
            kind = "system state"
        elif t.startswith("/dev"):
            kind = "device"
        else:
            kind = "file"
        out.append({"target": t, "kind": kind})
        if len(out) >= cap:
            break
    return out


def _is_private(ip: str) -> bool:
    """Локальный ли адрес — чтобы пометить внешние сессии.

    Признак структурный (RFC1918/loopback/link-local), а не список «плохих»
    адресов: внешнее направление само по себе не угроза, но при разборе
    смотрят на него первым.
    """
    ip = (ip or "").strip()
    if ip.startswith(("127.", "10.", "192.168.", "169.254.", "::1", "fe80")):
        return True
    if ip.startswith("172."):
        try:
            return 16 <= int(ip.split(".")[1]) <= 31
        except (IndexError, ValueError):
            return False
    return not ip


def _fd_count(pid: str) -> int:
    """Сколько файловых дескрипторов держит процесс (best-effort, без root)."""
    import os
    try:
        return len(os.listdir("/proc/%s/fd" % pid))
    except OSError:
        return 0


# ---- КАТЕГОРИИ ГРАФА (оформление + сворачивание) ----
# Категория, в которую попадает связанная таблица. Тип узла (kind) и колонка
# подписи — тоже оформление. САМА связь берётся из обнаруженной карты
# (links.model), а не отсюда: этот словарь только раскладывает найденное по
# смысловым группам (положение 2 — данные приходят из экспертизы).
CATMAP = {
    "users":           ("identity",    "user",      "name",     "reanchor"),
    "applications":    ("package",     "package",   "name",     "reanchor"),
    "services":        ("startup",     "service",   "unit",     "state"),
    "ports":           ("network",     "remote",    "remote",   "state"),
    "unix_sockets":    ("ipc",         "socket",    "path",     "state"),
    "open_files":      ("files",       "file",      "path",     "state"),
    "app_config":      ("configs",     "config",    "path",     "state"),
    "config_files":    ("configs",     "config",    "path",     "state"),
    "scheduled":       ("startup",     "scheduled", "name",     "state"),
    "persistence":     ("startup",     "persist",   "path",     "state"),
    "privesc":         ("privesc",     "privesc",   "name",     "state"),
    "suid_binaries":   ("privesc",     "suid",      "path",     "state"),
    "vulnerabilities": ("vulns",       "vuln",      "advisory", "state"),
    "kernel_modules":  ("kmod",        "kmod",      "name",     "state"),
    "processes":       ("tree",        "process",   "command",  "reanchor"),
}
# категория -> (подпись блока, цвет, порядок СВЕРХУ ВНИЗ в лесенке)
# ПОРЯДОК ПО СМЫСЛУ РАЗБОРА: процесс -> чем является (пакет) -> чем запущен
# (служба) -> куда ходит (сеть) -> что держит (файлы) -> чем настроен.
# У «процессов» и «событий» подписи НЕТ: тип и так виден по иконке и
# содержимому узлов, слово только шумит.
CAT_META = {
    "tree":        ("",             "#4c7ef3", 0),
    "package":     ("Application",   "#27ae60", 1),
    # services + scheduled + persistence — один вопрос «что и когда
    # запускается»; тремя блоками это заставляло искать в трёх местах
    "startup":     ("Startup",       "#2471a3", 2),
    "network":     ("Network",       "#e67e22", 3),
    "files":       ("Files",         "#5d6d7e", 4),
    "configs":     ("Configuration", "#16a085", 5),
    "ipc":         ("IPC",          "#8e44ad", 6),
    "identity":    ("User",          "#2980b9", 7),
    "privesc":     ("Privileges",    "#d35400", 10),
    "vulns":       ("Vulnerabilities","#c0392b", 11),
    "events":      ("",             "#7f8c8d", 12),
    "kmod":        ("Kernel Modules","#7d3c98", 13),
}
# ЧТО ПИСАТЬ ВТОРОЙ СТРОКОЙ у узла-сателлита. Раньше туда шло ИМЯ ТАБЛИЦЫ
# («app_config», «services») — это про устройство хранилища, а не про суть.
# Берём поле, которое реально объясняет объект.
SUBCOL = {
    "services": "desc", "app_config": "scope", "config_files": "scope",
    "persistence": "vector", "vulnerabilities": "cvss_rating",
    "suid_binaries": "owner", "privesc": "risk", "scheduled": "detail",
    "kernel_modules": "description", "unix_sockets": "type",
    "open_files": "kind", "ports": "exposure", "applications": "version",
}
COLLAPSE_MIN = 4      # категория крупнее — сворачивается в мета-узел
# свободный коридор между деревом процессов и колонкой блоков:
# рёбрам нужно место, чтобы не идти поверх карточек
COLUMN_GAP = 280
ROW_GAP = 160         # блоки начинаются НИЖЕ дерева процессов
GRID = 40             # та же сетка, что рисует полотно


def _snap(v):
    """Округлить до сетки полотна: узлы должны стоять по линиям."""
    return int(round(v / GRID) * GRID)
# что КАЖДЫЙ якорь собирает ВРУЧНУЮ — обнаружение эти таблицы для него
# пропускает, чтобы не задвоить. Для application ручного нет: его процессы
# приходят обнаружением (applications.name <-> processes.package), и это верно.
MANUAL_TABLES = {
    "address":   {"processes", "ports"},
    "user":      {"processes", "sessions", "shell_history"},
    "port":      {"processes", "ports"},
    "config":    {"applications", "processes"},
    "open_file": {"applications", "processes"},
}


def _emit_categories(add, link, anchor_id, ax, ay, cats, expanded,
                     tree_right=None, tree_bottom=None):
    """КАТЕГОРИИ СПРАВА ОТ ДЕРЕВА: блоки идут сверху вниз в своей колонке.

    Читается как ступеньки разбора: сам процесс, под ним ПРИЛОЖЕНИЕ (пакет),
    ниже служба, сетевые соединения, файлы, конфигурация. Члены блока лежат
    слева направо с переносом. Крупный блок свёрнут в мета-узел со счётчиком.

    Геометрия ЦЕЛИКОМ здесь (положение: раскладка в Python, QML только рисует).
    Возвращает сводку категорий.
    """
    present = [c for c in cats if cats[c]]
    present.sort(key=lambda c: CAT_META.get(c, ("", "", 99))[2])
    summary = []
    # ЛЕСЕНКА: каждая категория — свой горизонтальный БЛОК, блоки идут
    # СВЕРХУ ВНИЗ (процесс -> приложение -> сеть -> файлы...), члены блока —
    # слева направо с переносом. Читается как ступеньки разбора.
    # БЛОКИ СПРАВА ОТ ДЕРЕВА ПРОЦЕССОВ, а не под ним. Когда они лежали ниже,
    # рёбра от якоря шли вниз и пересекали само дерево. Теперь между деревом и
    # блоками — широкий свободный коридор, и линии идут вбок, ни через что не
    # проходя.
    # Блоки лежат СПРАВА и НИЖЕ уровня процессов: дерево занимает верхнюю
    # левую часть полотна, параметры — правую нижнюю, и между ними остаётся
    # свободный коридор для рёбер. Всё кратно сетке GRID, которую рисует
    # полотно, — иначе узлы «висят» между линиями.
    base = ax if tree_right is None else tree_right
    LEFT = _snap(base + COLUMN_GAP)
    # шаг больше ширины узла (184 px в QML) — иначе блоки слипаются
    CW, ROW_H, PER_ROW, BAND_GAP = 240, 120, 4, 40
    y = _snap((ay if tree_bottom is None else tree_bottom) + ROW_GAP)
    for cat in present:
        # ДЕДУПЛИКАЦИЯ ДО ПОДСЧЁТА: один путь, открытый несколькими
        # дескрипторами, — это один узел. Иначе блок обещал «292», а рисовал
        # 286 (add() схлопывает по id), и счётчик врал.
        members, seen_m = [], set()
        for m in cats[cat]:
            if m["id"] in seen_m:
                continue
            seen_m.add(m["id"])
            members.append(m)
        label, color, _o = CAT_META.get(cat, (cat, "#888888", 99))
        # ВСЕ категории свёрнуты по умолчанию: от якоря идёт стрелка к БЛОКУ
        # («Приложение», «Файлы», «Сеть»), а его содержимое раскрывается по
        # клику. Обзор сначала — детали по требованию.
        collapsed = cat not in expanded
        summary.append({"id": cat, "label": label, "color": color,
                        "count": len(members), "collapsed": collapsed})
        cx, cy = LEFT, y
        # ЗАГОЛОВОК КАТЕГОРИИ есть ВСЕГДА (мета-узел). Свёрнут — «+N раскрыть»;
        # раскрыт — «−N свернуть». Клик по нему всегда шлёт toggleCategory, так
        # что путь СВОРАЧИВАНИЯ достижим (раньше заголовок исчезал при раскрытии
        # и свернуть было нечем).
        gid = "group:" + cat
        rep = members[0]
        add(gid, "group", label,
            ("%d — expand" % len(members)) if collapsed
            else ("%d — collapse" % len(members)),
            rep.get("table", ""), "", "", category=cat, color=color,
            count=len(members), collapsed=collapsed,
            # ИКОНКА БЛОКА = иконка его содержимого. Подписи «Процессы» и
            # «События» убраны как лишние слова, но тип обязан читаться —
            # иначе у якоря-пользователя два безымянных блока (процессы и
            # события) не отличить друг от друга.
            icon_kind=rep.get("kind", ""),
            badge=("+%d" % len(members)) if collapsed else "−",
            drill="toggle", x=_snap(cx), y=_snap(cy))
        link(anchor_id, gid, label, rel="member", count=len(members),
             via_x=round(LEFT - COLUMN_GAP / 2))
        if collapsed:
            y += ROW_H + BAND_GAP
        else:
            # ВСЕ элементы блока, без среза: пользователь раскрыл категорию
            # именно чтобы увидеть всё. Компактность обеспечивает сворачивание,
            # а не молчаливое обрезание списка.
            mem = sorted(members, key=lambda m: (not m.get("risk"), m["label"]))
            for i, m in enumerate(mem):
                # ОСТАЛЬНЫЕ ПОЛЯ ЧЛЕНА ПЕРЕДАЮТСЯ КАК ЕСТЬ. Раньше здесь был
                # закрытый список полей, и всё, что сборщик добавлял сверху
                # (время события, пометки), молча пропадало по дороге в узел.
                extra = {k: v for k, v in m.items()
                         if k not in ("id", "kind", "label", "sub", "table",
                                      "col", "val", "rel", "drill", "risk")}
                extra.update(category=cat, color=color,
                             drill=m.get("drill", "state"),
                             risk=bool(m.get("risk")),
                             origin_x=round(cx), origin_y=round(cy),
                             x=_snap(LEFT + 200 + (i % PER_ROW) * CW),
                             y=_snap(y + (i // PER_ROW) * ROW_H))
                nid = add(m["id"], m["kind"], m["label"], m.get("sub", ""),
                          m.get("table", ""), m.get("col", ""), m.get("val", ""),
                          **extra)
                # РЕБРО ИДЁТ ОТ БЛОКА К КАЖДОМУ ЭЛЕМЕНТУ. Раньше эта строка
                # стояла ВНЕ цикла, и связь получал только последний узел —
                # при раскрытии блока стрелка вела к одному элементу.
                # via_x — коридор между заголовком блока и сеткой членов,
                # иначе ребро ко второму ряду идёт поверх первого.
                link(gid, nid, cat, rel=m.get("rel", "owns"),
                     via_x=round(LEFT + 150))
            rows = (len(mem) + PER_ROW - 1) // PER_ROW
            y += rows * ROW_H + BAND_GAP
    return summary


def _normalize_xy(nodes, pad=120):
    """Сдвинуть все узлы так, чтобы минимум x/y был положительным отступом.

    Категории раскладываются полукругом, и верхние кластеры получают
    ОТРИЦАТЕЛЬНЫЙ y — Flickable его не проскроллит (contentY >= 0), и они
    уходили за верх канвы. Один сдвиг чинит это для любого якоря.
    """
    if not nodes:
        return
    minx = min(n["x"] for n in nodes)
    miny = min(n["y"] for n in nodes)
    dx = pad - minx if minx < pad else 0
    dy = pad - miny if miny < pad else 0
    # сдвиг тоже кратен сетке, иначе выравнивание теряется
    dx = int(round(dx / GRID) * GRID)
    dy = int(round(dy / GRID) * GRID)
    if dx or dy:
        for nd in nodes:
            nd["x"] += dx
            nd["y"] += dy


def _owner_pid(db, kind: str, val: str) -> str:
    """Какому процессу принадлежит сущность — чтобы войти в его граф.

    Возвращает pid или "" если владельца нет (тогда строится обобщённый
    граф). Ничего не выдумываем: pid берётся из тех же таблиц конвейера.
    """
    con = _ro(db.path)
    try:
        if kind == "port":
            for r in _q(con, "SELECT process FROM ports WHERE port=? "
                             "AND COALESCE(process,'')<>'' LIMIT 1", (val,)):
                m = re.search(r"\((\d+)\)", str(r.get("process") or ""))
                if m:
                    return m.group(1)
        elif kind in ("open_file", "config"):
            for r in _q(con, "SELECT pid FROM open_files WHERE path=? "
                             "AND COALESCE(pid,'')<>'' LIMIT 1", (val,)):
                return str(r["pid"])
            if kind == "config":
                # файл никем не открыт — берём процесс пакета-владельца
                for r in _q(con, "SELECT p.pid FROM app_config c "
                                 "JOIN processes p ON p.package = c.app "
                                 "WHERE c.path=? AND p.command NOT LIKE '[%' "
                                 "LIMIT 1", (val,)):
                    return str(r["pid"])
        elif kind == "application":
            for r in _q(con, "SELECT pid FROM processes WHERE package=? "
                             "AND command NOT LIKE '[%' LIMIT 1", (val,)):
                return str(r["pid"])
    finally:
        con.close()
    return ""


def anchor_graph(db, eventsdb, kind: str, val: str, expanded=()) -> dict:
    """ЕДИНЫЙ ПИВОТ: граф вокруг сущности ЛЮБОГО типа.

    kind = process | application | port | user | config | open_file.
    Процесс строит дерево запуска (спину) + категории; остальные — центр +
    категории из обнаруженных связей. Контракт возврата один и тот же
    ({nodes, edges, width, height, categories, anchor}), поэтому QML и боковая
    панель работают одинаково для всех якорей.
    """
    if kind == "process":
        return around(db, eventsdb, str(val), expanded=expanded)

    # ВХОД ЧЕРЕЗ ДРУГОЙ ЭЛЕМЕНТ ВЕДЁТ В ТОТ ЖЕ ГРАФ. Порт, конфиг, открытый
    # файл, приложение — это всё принадлежит процессу, и разбирают в итоге
    # процесс. Поэтому резолвим сущность до её процесса и строим ОБЫЧНЫЙ
    # граф процесса со всеми блоками, помечая, через что вошли.
    # Пользователь — исключение: это не один объект, а множество процессов,
    # и обобщённый граф с блоком «процессы» тут честнее.
    pid = _owner_pid(db, kind, str(val))
    if pid:
        g = around(db, eventsdb, pid, expanded=expanded)
        if not g.get("error"):
            g["entered_via"] = {"kind": kind, "val": str(val)}
            return g

    ANCHORS = {
        "address": ("ports", "remote", "remote"),
        "application": ("applications", "name", "package"),
        "port":        ("ports", "port", "listen"),
        "user":        ("users", "name", "user"),
        "config":      ("app_config", "path", "config"),
        "open_file":   ("open_files", "path", "file"),
    }
    if kind not in ANCHORS:
        return {"nodes": [], "edges": [], "error": "unknown anchor %s" % kind}
    table, col, nkind = ANCHORS[kind]
    return _anchor_generic(db, eventsdb, kind, table, col, str(val), nkind,
                           set(expanded))


def _anchor_generic(db, eventsdb, kind, table, col, val, nkind, expanded):
    con = _ro(db.path)
    try:
        tabs = {r["name"] for r in con.execute("SELECT name FROM _tabs")}
        if table not in tabs:
            return {"nodes": [], "edges": [], "error": "no such table: %s" % table}
        center = _q(con, 'SELECT * FROM "%s" WHERE "%s"=? LIMIT 1'
                    % (table, col), (val,))
        if not center:
            center = _q(con, 'SELECT * FROM "%s" WHERE "%s" LIKE ? LIMIT 1'
                        % (table, col), ("%" + val + "%",))
        center = center[0] if center else {}
    finally:
        con.close()

    nodes, edges, seen = [], [], set()

    def add(nid, k, label, sub="", t="", c="", v="", **extra):
        if nid in seen:
            return nid
        seen.add(nid)
        node = {"id": nid, "kind": k, "label": label, "sub": sub,
                "table": t, "col": c, "val": v, "x": 0, "y": 0}
        node.update(extra)
        nodes.append(node)
        return nid

    def link(a, b, label="", rel="", direction="fwd", count=0, via_x=0):
        # via_x — координата свободного коридора для ребра; общая раскладка
        # категорий передаёт её всем графам, и без неё якорь-НЕ-процесс падал
        edges.append({"a": a, "b": b, "label": label, "rel": rel,
                      "dir": direction, "count": count, "via_x": via_x})

    ax, ay = 520, 440
    label = str(center.get(CATMAP.get(table, ("", "", col))[2], val) or val)
    label = label.rstrip("/").rsplit("/", 1)[-1][:30] or val
    root = add(table + ":" + val, nkind, label, table, table, col, val,
               focus=True, x=ax, y=ay)

    # опорные значения центра: собственный ключ + package/user, если есть
    keyvals = {(table, col): val}
    if center.get("package"):
        keyvals[("processes", "package")] = center["package"]
        keyvals[("applications", "name")] = center["package"]
    if table == "applications":
        keyvals[("processes", "package")] = center.get("name", val)
    if center.get("user"):
        keyvals[("users", "name")] = center["user"]

    try:
        model_links = model(db).get("links", [])
    except Exception:
        model_links = []
    skip_manual = MANUAL_TABLES.get(kind, set())

    cats = {}

    # РУЧНЫЕ КАТЕГОРИИ по реальным колонкам — там, где авто-обнаружение слабое
    # (users всего 2 строки, config/open_file — путь). Это не выдумка: колонки
    # существуют (processes.user, open_files.path), просто порог model() их не
    # ловит. Тянем напрямую.
    mc = _ro(db.path)
    try:
        if kind == "user":
            for r in _q(mc, "SELECT pid, command FROM processes WHERE user=? "
                            "LIMIT 400", (val,)):
                nm = (r.get("command") or "").split()[0].rsplit("/", 1)[-1]
                cats.setdefault("tree", []).append(dict(
                    id="proc:" + str(r["pid"]), kind="process",
                    label=nm[:24] or str(r["pid"]), sub="pid " + str(r["pid"]),
                    table="processes", col="pid", val=str(r["pid"]),
                    rel="owns", drill="reanchor"))
            for r in _q(mc, "SELECT tty, what, start AS login FROM logins "
                            "WHERE user=? AND active='yes' "
                            "LIMIT 400", (val,)):
                cats.setdefault("identity", []).append(dict(
                    id="sess:" + str(r.get("tty")), kind="user",
                    label="session " + str(r.get("tty") or ""),
                    sub=str(r.get("what") or ""), table="sessions", col="user",
                    val=val, rel="owns", drill="state"))
            for r in _q(mc, "SELECT n, command FROM shell_history WHERE user=? "
                            "ORDER BY n DESC LIMIT 400", (val,)):
                cats.setdefault("events", []).append(dict(
                    id="hist:%s:%s" % (val, r.get("n")), kind="action",
                    label=str(r.get("command") or "")[:26], sub="history",
                    table="shell_history", col="user", val=val,
                    rel="did", drill="state"))
        elif kind == "address":
            # КТО ХОДИЛ НА ЭТОТ АДРЕС. Тот же разбор, что у процесса, только
            # опора — удалённый адрес: сначала живые сокеты из снимка, затем
            # события сети (соединение могло закрыться, в снимке его уже нет,
            # а в событиях оно осталось — иначе «кто отправлял» терялось).
            seen_pids = set()
            for r in _q(mc, "SELECT proto, local, remote, process, state "
                            "FROM ports WHERE remote LIKE ? LIMIT 200",
                        (val + ":%",)):
                proc = str(r.get("process") or "")
                pm = re.search(r"\((\d+)\)", proc)
                if pm and pm.group(1) not in seen_pids:
                    seen_pids.add(pm.group(1))
                    cats.setdefault("tree", []).append(dict(
                        id="proc:" + pm.group(1), kind="process",
                        label=(proc.split()[0][:22] or pm.group(1)),
                        sub="live socket", table="processes", col="pid",
                        val=pm.group(1), rel="connected", drill="reanchor"))
                rem = str(r.get("remote") or "")
                cats.setdefault("network", []).append(dict(
                    id="sock:" + rem + str(r.get("local")), kind="remote",
                    label=rem,
                    sub="%s · %s · from :%s" % (
                        str(r.get("proto") or "").upper(),
                        r.get("state") or "",
                        str(r.get("local") or "").rsplit(":", 1)[-1]),
                    table="ports", col="remote", val=val,
                    rel="connected", drill="whois"))
            if eventsdb is not None:
                try:
                    for e in eventsdb.query(
                            "SELECT process_name, process_pid, COUNT(*) n, "
                            "MAX(ts) last FROM events WHERE destination_ip = ? "
                            "GROUP BY process_pid, process_name "
                            "ORDER BY n DESC LIMIT 60", (val,)).get("rows", []):
                        pid_ = str(e.get("process_pid") or "").strip()
                        nm = str(e.get("process_name") or "").strip()
                        if pid_ and pid_ not in seen_pids:
                            seen_pids.add(pid_)
                            cats.setdefault("tree", []).append(dict(
                                id="proc:" + pid_, kind="process",
                                label=nm[:22] or pid_,
                                sub="%s events" % e["n"], when=str(e["last"] or ""),
                                table="processes", col="pid", val=pid_,
                                rel="connected", drill="reanchor"))
                        cats.setdefault("events", []).append(dict(
                            id="ev:%s:%s" % (val, pid_ or nm), kind="action",
                            label=(nm or "unknown process")[:24],
                            sub="%s events" % e["n"], when=str(e["last"] or ""),
                            table="", col="", val=val, rel="did", drill="events"))
                except Exception:
                    pass
        elif kind == "port":
            # владелец порта + удалённые пиры на этом порту
            for r in _q(mc, "SELECT proto, remote, process, exposure FROM ports "
                            "WHERE port=? LIMIT 400", (val,)):
                proc = str(r.get("process") or "")
                pm = re.search(r"\((\d+)\)", proc)
                if pm:
                    cats.setdefault("tree", []).append(dict(
                        id="proc:" + pm.group(1), kind="process",
                        label=(proc.split()[0][:20] or pm.group(1)),
                        sub="port owner", table="processes", col="pid",
                        val=pm.group(1), rel="listens", drill="reanchor"))
                rem = str(r.get("remote") or "")
                if rem:
                    host = rem.rsplit(":", 1)[0]
                    cats.setdefault("network", []).append(dict(
                        id="net:" + rem, kind="remote", label=host,
                        sub=str(r.get("exposure") or ""), table="ports",
                        col="remote", val=host, rel="connected", drill="whois"))
        if kind in ("config", "open_file"):
            # пакет-владелец файла (из строки app_config.app)
            pk = str(center.get("app") or center.get("package") or "").strip()
            if pk:
                cats.setdefault("package", []).append(dict(
                    id="pkg:" + pk, kind="package", label=pk, sub="owner",
                    table="applications", col="name", val=pk,
                    rel="from_package", drill="reanchor"))
            # кто ДЕРЖИТ файл открытым (директории тоже)
            for r in _q(mc, "SELECT DISTINCT pid, process FROM open_files "
                            "WHERE path=? LIMIT 400", (val,)):
                pr = str(r.get("process") or r.get("pid"))
                cats.setdefault("tree", []).append(dict(
                    id="proc:" + str(r["pid"]), kind="process",
                    label=pr.split()[0][:22] if pr else str(r["pid"]),
                    sub="has it open", table="processes", col="pid",
                    val=str(r["pid"]), rel="opened", drill="reanchor"))
            # события по этому пути
            if eventsdb is not None:
                try:
                    for e in eventsdb.query(
                            "SELECT event_action a, COUNT(*) n FROM events "
                            "WHERE file_path=? GROUP BY a LIMIT 100",
                            (val,)).get("rows", []):
                        cats.setdefault("events", []).append(dict(
                            id="ev:%s:%s" % (val, e["a"]), kind="action",
                            label=str(e["a"]), sub="%s times" % e["n"],
                            table="", col="", val=val, rel="did", drill="events"))
                except Exception:
                    pass
    finally:
        mc.close()

    con3 = _ro(db.path)
    try:
        seen_sat = set()
        for l in model_links:
            hook = None
            if (l["from_table"], l["from_col"]) in keyvals:
                hook = (l["from_table"], l["from_col"], l["to_table"], l["to_col"])
            elif (l["to_table"], l["to_col"]) in keyvals:
                hook = (l["to_table"], l["to_col"], l["from_table"], l["from_col"])
            if not hook:
                continue
            bt, bc, ot, oc = hook
            # не дублируем таблицы, собранные вручную для ЭТОГО якоря, и
            # само себя
            if ot == table or ot in skip_manual or ot not in CATMAP:
                continue
            v = keyvals.get((bt, bc), "")
            if not v or (ot, oc) in seen_sat:
                continue
            seen_sat.add((ot, oc))
            cat, k2, lcol, drill = CATMAP[ot]
            try:
                found = _q(con3, 'SELECT * FROM "%s" WHERE "%s"=? LIMIT 400'
                           % (ot, oc), (v,))
            except Exception:
                found = []
            for fr in found:
                raw = str(fr.get(lcol) or "")
                lab = raw.rstrip("/").rsplit("/", 1)[-1][:26] or ot
                nid = "%s:%s" % (ot, fr.get("_id") or raw or fr.get(oc))
                risky = ot == "vulnerabilities" or str(fr.get("risk")) == "high"
                cats.setdefault(cat, []).append(dict(
                    id=nid, kind=k2, label=lab,
                    sub=str(fr.get(SUBCOL.get(ot, ""), "") or "")[:38],
                    table=ot, col=lcol, val=raw,
                    rel="declares", drill=drill, risk=risky))
    finally:
        con3.close()

    categories = _emit_categories(add, link, root, ax, ay, cats, expanded)
    _normalize_xy(nodes)
    width = max((n["x"] for n in nodes), default=800) + 300
    height = max((n["y"] for n in nodes), default=600) + 200
    return {"nodes": nodes, "edges": edges, "width": width, "height": height,
            "categories": categories,
            "anchor": {"kind": kind, "table": table, "col": col, "val": val,
                       "label": label}, "error": ""}


def around(db, eventsdb, pid: str, depth_up: int = 6,
           depth_down: int = 2, expanded=()) -> dict:
    """ДЕРЕВО ПРОЦЕССОВ СТУПЕНЬКАМИ вокруг выбранного.

    Ступенька = поколение: слева предки (вплоть до init), в центре сам
    процесс, справа потомки. Так сразу видно, КАК он запустился и кого
    породил — это первый вопрос при разборе.

    На каждой ступеньке у узла показаны счётчики: сетевые сокеты, unix-
    сокеты, открытые дескрипторы, события. Они отвечают «чем этот процесс
    вообще занят», не заставляя открывать каждый узел.

    Контекст самого процесса (пользователь, пакет, удалённые адреса)
    добавляется отдельными узлами — по ним можно провалиться дальше.
    Раскладка считается здесь: x = ступенька, y = строка внутри ступеньки.
    """
    pid = str(pid)
    con = _ro(db.path)
    try:
        rows = _q(con, "SELECT pid, ppid, user, command, package, purpose, "
                       "title, rss_mb, cpu, arg_files FROM processes")
        by_pid = {str(r["pid"]): r for r in rows}
        kids_of = {}
        for r in rows:
            kids_of.setdefault(str(r["ppid"] or ""), []).append(r)
        me = by_pid.get(pid)
        if not me:
            return {"error": "process %s is not in the current snapshot" % pid,
                    "nodes": [], "edges": []}
        user = (me.get("user") or "").strip()
        urow = _q(con, "SELECT name, uid, shell, privilege, admin_groups, "
                       "privilege_source FROM users WHERE name=?", (user,))
        socks = _q(con, "SELECT proto, local, remote, state, exposure, port, "
                        "service FROM ports WHERE process LIKE ?",
                   ("%(" + pid + ")%",))
        pkg = (me.get("package") or "").strip()
        app = _q(con, "SELECT name, kind, version, vendor, deps_count, "
                      "required_by FROM applications WHERE name=? LIMIT 1",
                 (pkg,)) if pkg else []

        # счётчики сокетов сразу для всех процессов ветки — один проход
        net_n, unix_n = {}, {}
        for r in _q(con, "SELECT process FROM ports WHERE COALESCE(process,'')<>''"):
            m = re.search(r"\((\d+)\)", str(r["process"]))
            if m:
                net_n[m.group(1)] = net_n.get(m.group(1), 0) + 1
        for r in _q(con, "SELECT process FROM unix_sockets "
                         "WHERE COALESCE(process,'')<>''"):
            m = re.search(r"(\d+)", str(r["process"]))
            if m:
                unix_n[m.group(1)] = unix_n.get(m.group(1), 0) + 1
    finally:
        con.close()

    # ---- ветка: предки вверх, потомки вниз ----
    chain = []
    cur, guard = me, 0
    while cur is not None and guard < depth_up:
        chain.append(cur)
        nxt = by_pid.get(str(cur.get("ppid") or ""))
        if nxt is None or str(nxt["pid"]) == str(cur["pid"]):
            break
        cur, guard = nxt, guard + 1
    chain.reverse()                      # от init к нашему процессу

    levels = {}                          # ступенька -> список процессов
    for i, r in enumerate(chain):
        levels.setdefault(i, []).append(r)
    base = len(chain) - 1

    def descend(node, lvl):
        if lvl - base >= depth_down:
            return
        for k in kids_of.get(str(node["pid"]), [])[:12]:
            levels.setdefault(lvl + 1, []).append(k)
            descend(k, lvl + 1)
    descend(me, base)

    # ---- события по процессам ветки ----
    ev_n = {}
    if eventsdb is not None:
        pids = [str(r["pid"]) for lst in levels.values() for r in lst]
        if pids:
            marks = ",".join("?" * len(pids))
            try:
                for e in eventsdb.query(
                        "SELECT process_pid AS p, COUNT(*) AS n FROM events "
                        "WHERE process_pid IN (%s) GROUP BY process_pid" % marks,
                        tuple(pids)).get("rows", []):
                    ev_n[str(e["p"])] = e["n"]
            except Exception:
                pass

    nodes, edges = [], []
    seen = set()

    def add(nid, kind, label, sub="", table="", col="", val="", **extra):
        if nid in seen:
            return nid
        seen.add(nid)
        n = {"id": nid, "kind": kind, "label": label, "sub": sub,
             "table": table, "col": col, "val": val, "x": 0, "y": 0}
        n.update(extra)
        nodes.append(n)
        return nid

    def link(a, b, label="", rel="", direction="fwd", count=0, via_x=0):
        edges.append({"a": a, "b": b, "label": label, "rel": rel,
                      "dir": direction, "count": count, "via_x": via_x})

    # шаги кратны сетке полотна (GRID=40), иначе узлы стоят между линиями
    STEP_X, STEP_Y = 240, 120
    for lvl in sorted(levels):
        group = levels[lvl]
        for row, r in enumerate(group):
            rpid = str(r["pid"])
            name = (r.get("command") or "").split()[0].rsplit("/", 1)[-1] or rpid
            nid = "proc:" + rpid
            fd = _fd_count(rpid)
            # ЧЕМ ЗАНЯТ процесс — счётчики прямо на узле
            counts = []
            if net_n.get(rpid):
                counts.append("net %d" % net_n[rpid])
            if unix_n.get(rpid):
                counts.append("unix %d" % unix_n[rpid])
            if fd:
                counts.append("files %d" % fd)
            if ev_n.get(rpid):
                counts.append("events %d" % ev_n[rpid])
            add(nid, "process", name,
                "pid %s · %s" % (rpid, r.get("user") or ""),
                "processes", "pid", rpid,
                counts=" · ".join(counts),
                focus=(rpid == pid), drill="reanchor",
                risk=bool(not (r.get("package") or "").strip()),
                purpose=(r.get("purpose") or r.get("title") or ""))
            n = nodes[-1] if nodes[-1]["id"] == nid else \
                [x for x in nodes if x["id"] == nid][0]
            n["x"] = 160 + lvl * STEP_X
            n["y"] = 120 + row * STEP_Y
            ppid = str(r.get("ppid") or "")
            if "proc:" + ppid in seen and ppid != rpid:
                link("proc:" + ppid, nid, "spawned")

    # ---- КОНТЕКСТ ПРОЦЕССА: КАТЕГОРИИ-КЛАСТЕРЫ вокруг узла ----
    # Вместо длинной колонки — смысловые категории (пользователь, пакет,
    # служба, сеть, IPC, файлы, конфиги, события, уязвимости...). Крупная
    # категория сворачивается в мета-узел со счётчиком; expanded управляет,
    # какие раскрыты. Раскладку кластеров считает _emit_categories.
    root = "proc:" + pid
    focus_node = [x for x in nodes if x["id"] == root][0]
    ax, ay = focus_node["x"], focus_node["y"]
    cats = {}

    def push(cat, mid, kind, label, sub, table, col, val, **ex):
        cats.setdefault(cat, []).append(dict(
            id=mid, kind=kind, label=label, sub=sub, table=table,
            col=col, val=val, **ex))

    # служба (systemd-юнит из cgroup) — «что реально запустило»
    unit = ""
    try:
        cg = open("/proc/%s/cgroup" % pid).read()
        m = re.search(r"/([\w@.\-]+\.(service|scope|socket|timer))", cg)
        if m:
            unit = m.group(1)
    except OSError:
        unit = ""
    if unit:
        udesc = ""
        try:
            uc = _ro(db.path)
            urow2 = _q(uc, "SELECT desc FROM services WHERE unit=? LIMIT 1", (unit,))
            uc.close()
            if urow2:
                udesc = urow2[0].get("desc", "")
        except Exception:
            udesc = ""
        push("startup", "services:" + unit, "service", unit,
             udesc or "systemd unit", "services", "unit", unit,
             rel="runs_unit", drill="state")

    # пользователь
    if user:
        u = urow[0] if urow else {}
        push("identity", "user:" + user, "user", user,
             (u.get("privilege") or "") +
             (" · " + u.get("admin_groups") if u.get("admin_groups") else ""),
             "users", "name", user, rel="owns", drill="reanchor")

    # пакет
    if pkg:
        a = app[0] if app else {}
        push("package", "pkg:" + pkg, "package", pkg,
             (a.get("kind") or "") + " " + (a.get("version") or ""),
             "applications", "name", pkg, rel="from_package", drill="reanchor")

    # СЕТЬ: открытые сессии процесса. Читается как фраза «с <адресом> по
    # <порту> <протокол>» — именно так о соединении и думают. Берём per-pid,
    # это авторитетнее связи по пакету.
    for s_ in socks:
        remote = (s_.get("remote") or "").strip()
        openx = s_.get("exposure") == "OPEN (exposed)"
        proto = (s_.get("proto") or "").lower()
        state = (s_.get("state") or "").strip()
        if remote and "*" not in remote:
            host = remote.rsplit(":", 1)[0]
            rport = remote.rsplit(":", 1)[-1]
            # локальный порт показываем как «откуда» — видно направление
            lport = (s_.get("local") or "").rsplit(":", 1)[-1]
            sub = proto.upper() + " · " + (state or "session")
            if lport:
                sub += " · from :" + lport
            push("network", "net:" + remote, "remote",
                 host + ":" + rport, sub,
                 "ports", "remote", host, rel="connected", drill="whois",
                 badge=("external" if not _is_private(host) else ""))
        else:
            push("network", "listen:" + (s_.get("local") or ""), "listen",
                 "listening " + (s_.get("port") or ""),
                 proto.upper() + " · " + (s_.get("exposure") or ""),
                 "ports", "port", s_.get("port") or "", rel="listens",
                 drill="state", risk=openx, badge=("OPEN" if openx else ""))

    # открытые файлы И ДИРЕКТОРИИ
    opened = []
    try:
        con2 = _ro(db.path)
        opened = [{"target": r["path"], "kind": r["kind"], "deleted": r["deleted"]}
                  for r in _q(con2, "SELECT path, kind, deleted FROM open_files "
                                    "WHERE pid=? AND kind IN ('file','device',"
                                    "'system state','directory') "
                                    "ORDER BY deleted DESC LIMIT 400", (pid,))]
        con2.close()
    except Exception:
        opened = []
    if not opened:
        opened = _open_targets(pid)
    # ФАЙЛЫ ГРУППИРУЮТСЯ ПО КАТАЛОГАМ. Полсотни отдельных узлов с именами
    # вроде «places.sqlite» ничего не говорят: важно, ГДЕ процесс работает —
    # в своём каталоге, в /etc, в /tmp или в чужом профиле. Поэтому в
    # подписи стоит каталог, а имя файла идёт второй строкой; каталог виден
    # и в подсказке целиком.
    by_dir = {}
    for f in opened:
        tgt = f["target"]
        is_dir = f["kind"] == "directory" or tgt.endswith("/")
        d = tgt.rstrip("/") if is_dir else (tgt.rsplit("/", 1)[0] or "/")
        by_dir.setdefault(d, []).append(f)
    for d in sorted(by_dir):
        items = by_dir[d]
        gone = [x for x in items if x.get("deleted")]
        names = ", ".join(sorted(
            (x["target"].rstrip("/").rsplit("/", 1)[-1] or x["target"])
            for x in items)[:4])
        if len(items) > 4:
            names += ", …"
        push("files", "dir:" + d, "dir",
             (d if len(d) <= 34 else "…" + d[-33:]),
             ("%d files · " % len(items) if len(items) > 1 else "") + names,
             "open_files", "dir", d, rel="works in", drill="state",
             risk=bool(gone),
             badge=("%d DELETED" % len(gone)) if gone else "",
             count=len(items))

    # ФАЙЛЫ ИЗ КОМАНДНОЙ СТРОКИ (конфиги, сертификаты, ключи). У демона под
    # другим пользователем /proc/<pid>/fd не читается, и «с каким конфигом он
    # работает» оставалось без ответа; аргументы-пути видны всегда.
    for f_ in [x for x in str(me.get("arg_files") or "").split(", ") if x]:
        push("configs", "argfile:" + f_, "config",
             f_.rsplit("/", 1)[-1][:26], "given on the command line",
             "app_config", "path", f_, rel="declares", drill="state")

    # КОГДА ВКЛЮЧИЛИ СИСТЕМУ и БЫЛ ЛИ КТО-ТО В СЕАНСЕ. Процесс живёт внутри
    # запуска системы и, как правило, внутри чьего-то сеанса: без этого
    # «когда он появился» повисает в воздухе.
    # своё соединение: прежнее (uc) живёт в другом блоке и уже закрыто
    bc = _ro(db.path)
    try:
        for b_ in _q(bc, "SELECT boot_id, started FROM boot_sessions "
                         "WHERE kind = 'boot' AND started <> '' "
                         "ORDER BY started DESC LIMIT 1"):
            push("startup", "boot:" + str(b_.get("boot_id") or ""), "event",
                 "system started", str(b_.get("started") or ""),
                 "boot_sessions", "boot_id", str(b_.get("boot_id") or ""),
                 rel="within", drill="state", when=str(b_.get("started") or ""))
    except Exception:
        pass
    if me.get("user"):
        try:
            for s_ in _q(bc, "SELECT user, tty, \"from\", start FROM logins "
                             "WHERE user = ? AND active = 'yes' "
                             "ORDER BY start DESC LIMIT 5", (me.get("user"),)):
                push("user", "sess:%s:%s" % (s_.get("user"), s_.get("tty")),
                     "user", "%s on %s" % (s_.get("user"), s_.get("tty")),
                     "session since " + str(s_.get("start") or ""),
                     "logins", "tty", str(s_.get("tty") or ""),
                     rel="session", drill="state", when=str(s_.get("start") or ""))
        except Exception:
            pass
    try:
        bc.close()
    except Exception:
        pass

    # события — что процесс делал (drill: события по pid)
    if eventsdb is not None:
        try:
            acts = eventsdb.query(
                "SELECT event_action a, COUNT(*) n, MAX(ts) last FROM events "
                "WHERE process_pid = ? GROUP BY event_action "
                "ORDER BY n DESC LIMIT 100", (pid,)).get("rows", [])
        except Exception:
            acts = []
        for e_ in acts:
            push("events", "act:%s:%s" % (pid, e_["a"]), "action", str(e_["a"]),
                 "%s times" % e_["n"],
                 "events", "event_action", str(e_["a"]),
                 rel="did", drill="events", pid=pid, when=str(e_["last"] or ""))

    # ---- ОСТАЛЬНЫЕ САТЕЛЛИТЫ ИЗ ОБНАРУЖЕННОЙ КАРТЫ (config/vuln/persist/...) ----
    try:
        model_links = model(db).get("links", [])
    except Exception:
        model_links = []
    keyvals = {("processes", "pid"): pid, ("processes", "package"): pkg,
               ("processes", "user"): user, ("applications", "name"): pkg}
    # вручную собранное выше не дублируем
    SKIP = {"processes", "applications", "users", "services", "ports", "open_files"}
    con3 = _ro(db.path)
    try:
        seen_sat = set()
        for l in model_links:
            hook = None
            if (l["from_table"], l["from_col"]) in keyvals:
                hook = (l["from_table"], l["from_col"], l["to_table"], l["to_col"])
            elif (l["to_table"], l["to_col"]) in keyvals:
                hook = (l["to_table"], l["to_col"], l["from_table"], l["from_col"])
            if not hook:
                continue
            bt, bc, ot, oc = hook
            if ot in SKIP or ot not in CATMAP:
                continue
            v = keyvals.get((bt, bc), "")
            if not v or (ot, oc) in seen_sat:
                continue
            seen_sat.add((ot, oc))
            cat, k2, lcol, drill = CATMAP[ot]
            # Закрытый бюллетень — это ИСТОРИЯ, а в блоке «Уязвимости» он
            # читается как «у процесса есть дыра». В графе показываем только
            # непропатченное; полный список остаётся во вкладке уязвимостей.
            where = ' AND status = \'open\'' if ot == "vulnerabilities" else ""
            try:
                found = _q(con3, 'SELECT * FROM "%s" WHERE "%s"=?%s LIMIT 400'
                           % (ot, oc, where), (v,))
            except Exception:
                found = []
            for fr in found:
                raw = str(fr.get(lcol) or "")
                lab = raw.rstrip("/").rsplit("/", 1)[-1][:26] or ot
                nid = "%s:%s" % (ot, fr.get("_id") or raw or fr.get(oc))
                risky = ot == "vulnerabilities" or str(fr.get("risk")) == "high"
                sub = str(fr.get(SUBCOL.get(ot, ""), "") or "")[:38]
                push(cat, nid, k2, lab, sub, ot, lcol, raw,
                     rel="declares", drill=drill, risk=risky)
    finally:
        con3.close()

    # блоки идут СПРАВА от дерева процессов
    tree_right = max((n["x"] for n in nodes if n["id"].startswith("proc:")),
                     default=ax)
    tree_bottom = max((n["y"] for n in nodes if n["id"].startswith("proc:")),
                      default=ay)
    categories = _emit_categories(add, link, root, ax, ay, cats,
                                  set(expanded), tree_right=tree_right,
                                  tree_bottom=tree_bottom)

    _normalize_xy(nodes)
    width = max((n["x"] for n in nodes), default=800) + 300
    height = max((n["y"] for n in nodes), default=600) + 200
    return {"nodes": nodes, "edges": edges, "pid": pid,
            "command": me.get("command", ""), "width": width,
            "height": height, "levels": len(levels),
            "anchor": {"kind": "process", "table": "processes", "col": "pid",
                       "val": pid, "label": (me.get("command") or "")[:40]},
            "categories": categories, "error": ""}


def node_detail(db, eventsdb, table: str, col: str, val: str) -> dict:
    """ВСЁ, что известно об объекте узла — для боковой панели графа.

    Работает для любого типа узла, потому что опирается не на зашитую схему,
    а на КАРТУ СВЯЗЕЙ (model): берём строку из её таблицы, а затем по всем
    обнаруженным связям подтягиваем связанные строки из других таблиц. Новый
    источник свяжется сам и появится здесь без правки кода.

    Возвращает секции [{title, rows:[{k,v}]}] — интерфейс только рисует.
    """
    table, col, val = str(table), str(col), str(val)
    if not table:
        return {"sections": [], "error": "this node has no source table"}

    con = _ro(db.path)
    try:
        tabs = {r["name"] for r in con.execute("SELECT name FROM _tabs")}
        if table not in tabs:
            return {"sections": [], "error": "no such table"}
        cols = _columns(con, table)
        if col and col in cols:
            rows = _q(con, 'SELECT * FROM "%s" WHERE "%s"=? LIMIT 5'
                      % (table, col), (val,))
            if not rows:
                rows = _q(con, 'SELECT * FROM "%s" WHERE "%s" LIKE ? LIMIT 5'
                          % (table, col), ("%" + val + "%",))
        else:
            rows = []

        sections = []
        if rows:
            main = rows[0]
            sections.append({
                "title": "What This Is",
                "rows": [{"k": k, "v": str(v)} for k, v in main.items()
                         if not k.startswith("_") and str(v).strip()][:24]})
        else:
            main = {}

        # связанные таблицы — из обнаруженной карты связей
        rel = []
        try:
            m = model(db)
            for l in m["links"]:
                if l["from_table"] == table and l["from_col"] in main:
                    rel.append((l["to_table"], l["to_col"], main[l["from_col"]],
                                l["from_col"]))
                elif l["to_table"] == table and l["to_col"] in main:
                    rel.append((l["from_table"], l["from_col"],
                                main[l["to_col"]], l["to_col"]))
        except Exception:
            rel = []

        seen = set()
        for rtable, rcol, rval, viacol in rel:
            if not str(rval).strip() or (rtable, rcol) in seen:
                continue
            seen.add((rtable, rcol))
            found = _q(con, 'SELECT * FROM "%s" WHERE "%s"=? LIMIT 6'
                       % (rtable, rcol), (str(rval),))
            if not found:
                continue
            body = []
            for fr in found:
                body.append({"k": str(fr.get(rcol, "")),
                             "v": "; ".join("%s=%s" % (k, v)
                                            for k, v in fr.items()
                                            if not k.startswith("_")
                                            and k != rcol and str(v).strip())[:220]})
            sections.append({
                "title": "%s (via %s)" % (rtable, viacol),
                "rows": body})
    finally:
        con.close()

    # что этот объект делал — из событий, если он там упоминается
    if eventsdb is not None and val:
        try:
            ev = eventsdb.query(
                "SELECT ts, event_action, event_category, message FROM events "
                "WHERE object_name = ? OR process_name = ? OR destination_ip = ? "
                "OR user_name = ? ORDER BY _id DESC LIMIT 8",
                (val, val, val, val)).get("rows", [])
        except Exception:
            ev = []
        if ev:
            sections.append({
                "title": "Recent Events",
                "rows": [{"k": str(e["ts"])[:19].replace("T", " "),
                          "v": "%s · %s" % (e["event_action"],
                                            (e["message"] or "")[:120])}
                         for e in ev]})
    return {"sections": sections, "table": table, "value": val, "error": ""}

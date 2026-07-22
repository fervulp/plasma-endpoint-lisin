"""Данные для дашборда «Состояние».

Собирает в одну структуру то, что иначе лежит по разным таблицам: процессы
(граф запуска, как в SIEM/EDR), потребление ресурсов, зависимости программ,
сеть (экспозиция портов и куда реально ходим). Чистый stdlib, только чтение.

Раскладку графа считаем ЗДЕСЬ (x/y узлов), чтобы QML только рисовал —
так расположение детерминировано и не прыгает между перерисовками.
"""
import os
import sqlite3
from collections import defaultdict

from . import entities


def _ro(path):
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    return con


def _rows(con, table):
    try:
        return [dict(r) for r in con.execute(f'SELECT * FROM "{table}"')]
    except Exception:
        return []


def _f(v):
    try:
        return float(v or 0)
    except Exception:
        return 0.0


def _base(cmd):
    cmd = (cmd or "").strip()
    if not cmd:
        return ""
    # поток ядра «[kworker/0:1-events]» → «kworker», иначе имена резались в
    # мусор вида «0]» и группировались как попало
    if cmd.startswith("["):
        return cmd.strip("[]").split("/", 1)[0].split(":", 1)[0][:28]
    tok = cmd.split(None, 1)[0]
    return tok.rsplit("/", 1)[-1][:28]


def _pid_of(process_field):
    """'code (261773)' -> '261773'."""
    s = process_field or ""
    i, j = s.rfind("("), s.rfind(")")
    if i >= 0 and j > i:
        v = s[i + 1:j].strip()
        return v if v.isdigit() else ""
    return ""


def process_detail(db, eventsdb, pid):
    """EDR-разбор ОДНОГО процесса: сколько ест, как запустился, что сделал,
    какой программе принадлежит, от чего та зависит, что лежит рядом с его
    бинарником и какой systemd-юнит за него отвечает.

    Всё собирается по связям между таблицами: processes → applications
    (пакет + его depends/required_by) → ports (сокеты) → events (что делал).
    """
    import os
    pid = str(pid)
    con = _ro(db.path)
    try:
        procs = {str(r["pid"]): r for r in _rows(con, "processes") if r.get("pid")}
        apps = _rows(con, "applications")
        ports = _rows(con, "ports")
        services = _rows(con, "services")
    finally:
        con.close()

    me = procs.get(pid)
    if not me:
        return {"error": "process %s is not in the current snapshot" % pid}

    def readlink(p):
        try:
            return os.readlink(p)
        except OSError:
            return ""

    exe = readlink("/proc/%s/exe" % pid).split(" (deleted)")[0]
    cwd = readlink("/proc/%s/cwd" % pid)
    cmd = (me.get("command") or "").strip()
    if not exe and cmd and not cmd.startswith("["):
        exe = cmd.split(None, 1)[0]

    # --- как запустился: цепочка предков ---
    chain, cur, guard = [], pid, 0
    while cur in procs and guard < 24:
        r = procs[cur]
        chain.append({"pid": cur, "user": r.get("user", ""),
                      "command": (r.get("command") or "")[:140],
                      "elapsed": r.get("elapsed", "")})
        nxt = str(r.get("ppid") or "")
        if nxt == cur or not nxt:
            break
        cur, guard = nxt, guard + 1
    chain.reverse()

    # --- systemd-юнит, который отвечает за процесс ---
    unit = ""
    try:
        cg = open("/proc/%s/cgroup" % pid).read()
        segs = [s for s in cg.replace("\n", "/").split("/") if s]
        for suf in (".service", ".scope", ".slice"):
            for s in reversed(segs):
                if s.endswith(suf):
                    unit = s
                    break
            if unit:
                break
    except OSError:
        pass
    unit_row = next((s for s in services if s.get("unit") == unit), None)

    # --- какой программе принадлежит бинарник ---
    base = exe.rsplit("/", 1)[-1] if exe else ""
    pkg = None
    # СНАЧАЛА берём УЖЕ ОБОГАЩЁННЫЙ пакет из строки процесса: обогащение
    # proc_purpose разворачивает интерпретатор (python3 -> tuned), а тут
    # своя резолвинг-логика этого не делала и показывала «python3».
    row_pkg = (r.get("package") or "").strip()
    if row_pkg:
        pkg = next((a for a in apps if a.get("name") == row_pkg), {"name": row_pkg})
    for a in apps:
        if pkg is None and a.get("path") and a["path"] == exe:
            pkg = a
            break
    if pkg is None and base:
        low = base.lower()
        cand = [a for a in apps if (a.get("name") or "").lower() == low]
        pkg = cand[0] if cand else None
    if pkg is None and exe:
        # авторитетный ответ от rpm: /usr/bin/Telegram → telegram-desktop
        # (в инвентаре путь у rpm-строк не заполнен, а имя пакета ≠ имя файла)
        import subprocess
        try:
            out = subprocess.run(["rpm", "-qf", "--qf", "%{NAME}", exe],
                                 capture_output=True, text=True, timeout=5).stdout.strip()
        except Exception:
            out = ""
        if out and "not owned" not in out and " " not in out:
            pkg = next((a for a in apps if a.get("name") == out), {"name": out})

    # СОСЕДИ БИНАРНИКА УБРАНЫ. Показывали ±18 имён файлов рядом в
    # каталоге — в /usr/bin это тысячи пакетных файлов, и список ничего
    # не давал. Исходный смысл (заметить подброшенный файл рядом с
    # легитимным) уже закрыт признаком «вне пакетов»: он структурный и
    # работает в любом каталоге, а не только в алфавитном окне.
    neighbours = []
    bindir = exe.rsplit("/", 1)[0] if "/" in exe else ""

    # --- ФАЙЛЫ, КОТОРЫЕ ПРОЦЕСС ДЕРЖИТ ОТКРЫТЫМИ ---
    # Из таблицы open_files (её наполняет конвейер), а не чтением /proc в
    # обход. Сокеты и каналы отсеиваем: они показаны отдельной секцией, а
    # здесь нужен ответ на вопрос «с какими файлами он работает».
    files = []
    try:
        # ОДИН ПУТЬ — ОДНА СТРОКА: процесс держит один и тот же файл
        # несколькими дескрипторами (у zen-bin /dev/dri/renderD128 шесть
        # раз), и список превращался в повтор одной строки.
        # ТОТ ЖЕ НАБОР И ТОТ ЖЕ ПОТОЛОК, ЧТО В ГРАФЕ (links.around):
        # раньше здесь не было 'директория' и стоял LIMIT 60, поэтому граф
        # показывал 110 файлов, а панель — 60, и было непонятно, кому верить.
        for r in db.query(
                "SELECT path, kind, MAX(deleted) deleted, COUNT(*) n "
                "FROM open_files WHERE pid='%s' "
                "AND kind IN ('file','device','system state',"
                "'directory') "
                "GROUP BY path ORDER BY n DESC, path LIMIT 400"
                % pid.replace("'", "''")
        ).get("rows", []):
            files.append({"path": r["path"], "kind": r["kind"],
                          "deleted": r["deleted"], "fds": r["n"]})
    except Exception:
        files = []

    # --- сокеты процесса ---
    socks = [{"proto": p.get("proto", ""), "local": p.get("local", ""),
              "remote": p.get("remote", ""), "state": p.get("state", ""),
              "exposure": p.get("exposure", "")}
             for p in ports if _pid_of(p.get("process", "")) == pid]

    # --- что процесс делал: события по этому pid ---
    did = []
    if eventsdb is not None:
        try:
            q = eventsdb.query(
                "SELECT ts, event_category, event_action, event_outcome, "
                "destination_ip, destination_port, destination_as_org, "
                "process_command_line, message FROM events "
                "WHERE process_pid = '%s' ORDER BY _id DESC LIMIT 201"
                % pid.replace("'", "''"))
            did = q.get("rows", [])
        except Exception:
            did = []
    # НЕ ОБРЕЗАЕМ МОЛЧА: если упёрлись в потолок, панель скажет об этом прямо
    did_truncated = len(did) > 200
    did = did[:200]

    # --- дети процесса ---
    kids = [{"pid": p, "command": (r.get("command") or "")[:120],
             "rss": round(_f(r.get("rss_mb")), 1)}
            for p, r in procs.items() if str(r.get("ppid") or "") == pid][:25]

    return {
        "pid": pid,
        "name": _base(cmd),
        "user": me.get("user", ""),
        "rss": round(_f(me.get("rss_mb")), 1),
        "cpu": round(_f(me.get("cpu")), 1),
        "elapsed": me.get("elapsed", ""),
        "command": cmd,
        "exe": exe,
        "cwd": cwd,
        "unit": unit,
        "unit_desc": (unit_row or {}).get("desc", ""),
        "unit_enabled": (unit_row or {}).get("enabled", ""),
        "ancestry": chain,
        "children": kids,
        "sockets": socks,
        "events": did, "events_truncated": did_truncated,
        "package": (pkg or {}).get("name", ""),
        "package_kind": (pkg or {}).get("kind", ""),
        "package_version": (pkg or {}).get("version", ""),
        "package_deps": (pkg or {}).get("depends", ""),
        "deps_count": (pkg or {}).get("deps_count", ""),
        "required_by": (pkg or {}).get("required_by", ""),
        "required_by_names": (pkg or {}).get("required_by_names", ""),
        "bindir": bindir,
        "neighbours": neighbours,
        "files": files,
    }


_EXE_CACHE = {}


def readlink_exe(pid):
    """/proc/PID/exe → путь (пусто, если нет прав/процесс умер)."""
    import os
    if pid in _EXE_CACHE:
        return _EXE_CACHE[pid]
    try:
        v = os.readlink("/proc/%s/exe" % pid).split(" (deleted)")[0]
    except OSError:
        v = ""
    _EXE_CACHE[pid] = v
    return v


def build(db, eventsdb=None, top=18):
    con = _ro(db.path)
    try:
        procs = [r for r in _rows(con, "processes") if r.get("pid")]
        ports = _rows(con, "ports")
        apps = _rows(con, "applications")
        mem = _rows(con, "memory")
        usock = _rows(con, "unix_sockets")
    finally:
        con.close()

    by_pid = {str(r["pid"]): r for r in procs}
    live = [r for r in procs if not (r.get("command") or "").strip().startswith("[")]

    # ---- сеть по процессам ----
    net_by_pid = defaultdict(list)
    exposure = defaultdict(int)
    for p in ports:
        pid = _pid_of(p.get("process", ""))
        exp = p.get("exposure", "") or ""
        if exp:
            exposure[exp] += 1
        if pid:
            net_by_pid[pid].append(p)

    # ---- граф запуска: топ по RSS + ВСЕ их предки ----
    ranked = sorted(live, key=lambda r: -_f(r.get("rss_mb")))[:top]
    keep = set()
    for r in ranked:
        pid = str(r["pid"])
        seen = 0
        while pid and pid in by_pid and pid not in keep and seen < 24:
            keep.add(pid)
            pid = str(by_pid[pid].get("ppid") or "")
            seen += 1

    depth, order = {}, []

    def dep_of(pid, guard=0):
        if pid in depth:
            return depth[pid]
        pp = str(by_pid.get(pid, {}).get("ppid") or "")
        d = 0 if (pp not in keep or pp == pid or guard > 24) else dep_of(pp, guard + 1) + 1
        depth[pid] = d
        return d

    for pid in keep:
        dep_of(pid)
    # порядок: по глубине, внутри — по родителю и имени (стабильно)
    for pid in sorted(keep, key=lambda p: (depth[p],
                                           str(by_pid[p].get("ppid") or ""),
                                           _base(by_pid[p].get("command")))):
        order.append(pid)

    rowat = defaultdict(int)
    nodes = []
    for pid in order:
        r = by_pid[pid]
        d = depth[pid]
        y = rowat[d]
        rowat[d] += 1
        nets = net_by_pid.get(pid, [])
        worst = ""
        for n in nets:
            e = n.get("exposure", "")
            if e == "OPEN (exposed)":
                worst = e
            elif e and not worst:
                worst = e
        nodes.append({
            "pid": pid,
            "ppid": str(r.get("ppid") or ""),
            "name": _base(r.get("command")),
            "command": (r.get("command") or "")[:160],
            "user": r.get("user", "") or "",
            "rss": round(_f(r.get("rss_mb")), 1),
            "cpu": round(_f(r.get("cpu")), 1),
            "depth": d,
            "x": d,
            "y": y,
            "ports": len(nets),
            "exposure": worst,
            "root": (r.get("user") == "root"),
        })
    edges = [[n["ppid"], n["pid"]] for n in nodes
             if n["ppid"] in keep and n["ppid"] != n["pid"]]

    # ---- ПОЛНОЕ дерево процессов с оценкой риска ----
    # Показывать только «топ по памяти» нельзя: опасное обычно МАЛЕНЬКОЕ
    # (дроппер в /tmp, reverse-shell, минер-загрузчик). Поэтому отдаём ВСЕ
    # процессы деревом, а вверх всплывают они не по размеру, а по РИСКУ —
    # так это устроено в Process Explorer / EDR-консолях.
    import os
    pkg_names = {(a.get("name") or "").lower() for a in apps}
    pkg_paths = {a.get("path") for a in apps if a.get("path")}
    TMPISH = ("/tmp/", "/dev/shm/", "/var/tmp/", "/run/user/")

    unix_by_pid = defaultdict(int)
    for u in usock:
        up = _pid_of(u.get("process", ""))
        if up:
            unix_by_pid[up] += 1

    kids_of = defaultdict(list)
    for r in procs:
        kids_of[str(r.get("ppid") or "")].append(str(r["pid"]))

    def risk_of(r, pid, exe, nets):
        score, why = 0, []
        user = r.get("user", "")
        cmd = (r.get("command") or "").strip()
        kernel = cmd.startswith("[")
        if kernel:
            return 0, []
        base = (exe or cmd.split(None, 1)[0]).rsplit("/", 1)[-1]
        if exe:
            if exe.startswith(TMPISH) or "/.cache/" in exe:
                score += 3; why.append("runs from temp dir")
            if exe.startswith(os.path.expanduser("~")) and "/.local/bin" not in exe:
                score += 2; why.append("binary in home")
            if "(deleted)" in (r.get("command") or ""):
                score += 3; why.append("binary deleted")
            if exe not in pkg_paths and base.lower() not in pkg_names:
                score += 2; why.append("not from a package")
        for n in nets:
            if n.get("exposure") == "OPEN (exposed)":
                score += 3; why.append("listening exposed")
                break
        for n in nets:
            rem = (n.get("remote") or "").rsplit(":", 1)[0].strip("[]")
            if rem and not (rem.startswith(("10.", "192.168.", "127.", "172.16.",
                                            "172.17.", "172.18.", "172.19.", "::1"))):
                score += 2; why.append("external connection")
                break
        if user == "root":
            score += 1; why.append("root")
        if base and base != (cmd.split(None, 1)[0].rsplit("/", 1)[-1] if cmd else base):
            score += 1; why.append("name/exe mismatch")
        return score, why

    tree, seen_t = [], set()

    def walk(pid, depth):
        if pid in seen_t or depth > 24:
            return
        seen_t.add(pid)
        r = by_pid.get(pid)
        if r is None:
            return
        cmd = (r.get("command") or "").strip()
        kernel = cmd.startswith("[")
        exe = "" if kernel else readlink_exe(pid)
        nets = net_by_pid.get(pid, [])
        sc, why = risk_of(r, pid, exe, nets)
        worst = ""
        for n in nets:
            if n.get("exposure") == "OPEN (exposed)":
                worst = n["exposure"]
            elif n.get("exposure") and not worst:
                worst = n["exposure"]
        # сколько объектов держит открытыми — это ресурс, и он виден без
        # root: по нему сразу заметен процесс, который «течёт» дескрипторами
        try:
            nfd = len(os.listdir("/proc/%s/fd" % pid))
        except OSError:
            nfd = 0
        # АДРЕСА ПРОЦЕССА строкой — чтобы процесс искался ПО IP и ПОРТУ.
        # Без этого поиск шёл только по имени/команде/пользователю, и на
        # вопрос «кто соединён с 198.51.100.7» ответить было нечем.
        from . import links as _links
        addrs, remote_n, external = [], 0, False
        for n in nets:
            rem = (n.get("remote") or "").strip()
            if rem and "*" not in rem:
                remote_n += 1
                addrs.append(rem)
                if not _links._is_private(rem.rsplit(":", 1)[0]):
                    external = True
            else:
                for f in ("local", "port"):
                    v = (n.get(f) or "").strip()
                    if v:
                        addrs.append(v)
        tree.append({
            "addrs": " ".join(addrs[:60]),
            "remote_n": remote_n, "external": external,
            "unpackaged": not (r.get("package") or "").strip() and not kernel,
            "pid": pid, "ppid": str(r.get("ppid") or ""),
            "name": _base(cmd) or "?", "command": cmd[:200],
            # «что это и зачем» — из обогащения proc_purpose
            "title": r.get("title", "") or "", "purpose": r.get("purpose", "") or "",
            "user": r.get("user", ""), "rss": round(_f(r.get("rss_mb")), 1),
            "cpu": round(_f(r.get("cpu")), 1), "elapsed": r.get("elapsed", ""),
            "depth": depth, "kernel": kernel, "exe": exe,
            "ports": len(nets), "exposure": worst,
            "unix": unix_by_pid.get(pid, 0),
            "risk": sc, "why": ", ".join(why), "files": nfd,
            "children": len(kids_of.get(pid, [])),
        })
        # ДЕРЕВО ПОКАЗЫВАЕТСЯ ПОЛНОСТЬЮ. Раньше одинаковые дети-листья
        # (≥3 с одним именем) схлопывались в строку «имя ×N» — дерево было
        # короче, но нужный процесс мог оказаться внутри группы, и найти его
        # было нечем. Полное дерево длиннее, зато в нём виден каждый процесс.
        kids = sorted(kids_of.get(pid, []),
                      key=lambda k: -_f(by_pid.get(k, {}).get("rss_mb")))
        for k in kids:
            walk(k, depth + 1)

    # СУММЫ ПО ПОДДЕРЕВУ. Свёрнутая ветка должна показывать, сколько ест ВСЯ
    # ветка, иначе браузер с 17 процессами выглядит лёгким: у корня 200 МБ, а
    # на деле 2 ГБ. Считаем снизу вверх по уже построенному дереву — оно в
    # DFS-порядке, поэтому достаточно одного прохода с конца.
    def sum_subtree(rows):
        acc = {}
        for node in reversed(rows):
            pid_ = node["pid"]
            own = acc.setdefault(pid_, {"rss": 0.0, "cpu": 0.0,
                                        "files": 0, "ports": 0, "n": 0})
            own["rss"] += _f(node.get("rss"))
            own["cpu"] += _f(node.get("cpu"))
            own["files"] += int(node.get("files") or 0)
            own["ports"] += int(node.get("ports") or 0)
            own["n"] += 1
            node["rss_total"] = round(own["rss"], 1)
            node["cpu_total"] = round(own["cpu"], 1)
            node["files_total"] = own["files"]
            node["ports_total"] = own["ports"]
            node["subtree"] = own["n"]
            up = node.get("ppid")
            if up:
                par = acc.setdefault(up, {"rss": 0.0, "cpu": 0.0,
                                          "files": 0, "ports": 0, "n": 0})
                par["rss"] += own["rss"]
                par["cpu"] += own["cpu"]
                par["files"] += own["files"]
                par["ports"] += own["ports"]
                par["n"] += own["n"]
        return rows

    roots = [str(r["pid"]) for r in procs
             if str(r.get("ppid") or "") not in by_pid or str(r.get("ppid")) == "0"]
    for rt in sorted(roots, key=lambda k: -_f(by_pid.get(k, {}).get("rss_mb"))):
        walk(rt, 0)
    for r in procs:                      # осиротевшие (родитель уже умер)
        walk(str(r["pid"]), 0)

    # ---- потребление ----
    top_rss = [{"name": _base(r.get("command")), "pid": str(r["pid"]),
                "user": r.get("user", ""), "value": round(_f(r.get("rss_mb")), 1)}
               for r in sorted(live, key=lambda r: -_f(r.get("rss_mb")))[:10]]
    top_cpu = [{"name": _base(r.get("command")), "pid": str(r["pid"]),
                "user": r.get("user", ""), "value": round(_f(r.get("cpu")), 1)}
               for r in sorted(live, key=lambda r: -_f(r.get("cpu")))[:10]
               if _f(r.get("cpu")) > 0]

    # ---- зависимости: программы с наибольшим числом компонентов ----
    try:
        inv = entities.programs(db)
    except Exception:
        inv = []
    progs = [e for e in inv if e.get("role") == "program"]
    top_deps = [{"name": e["name"], "kind": e["kind"], "value": e["components"]}
                for e in sorted(progs, key=lambda e: -e.get("components", 0))[:10]
                if e.get("components", 0) > 0]

    # ---- сеть: куда реально ходим (из событий, уже обогащённых ASN) ----
    top_dest = []
    if eventsdb is not None:
        try:
            q = eventsdb.query(
                'SELECT destination_ip AS ip, '
                'MAX(destination_as_org) AS org, MAX(destination_geo_country) AS cc, '
                'COUNT(*) AS n FROM events '
                "WHERE destination_ip IS NOT NULL AND destination_ip <> '' "
                'GROUP BY destination_ip ORDER BY n DESC LIMIT 10')
            top_dest = [{"ip": r["ip"], "org": r["org"] or "",
                         "country": r["cc"] or "", "value": r["n"]}
                        for r in q.get("rows", [])]
        except Exception:
            top_dest = []

    ev_total = 0
    if eventsdb is not None:
        try:
            ev_total = eventsdb.count()
        except Exception:
            ev_total = 0

    ram = ""
    for m in mem:
        if str(m.get("item", "")).lower() in ("used", "in use"):
            ram = str(m.get("value", ""))

    tiles = [
        {"label": "Processes", "value": str(len(live)), "icon": "system-run"},
        {"label": "Programs", "value": str(len(progs)), "icon": "applications-all"},
        {"label": "Listening", "value": str(sum(1 for p in ports
                                                if not (p.get("remote") or ""))),
         "icon": "network-server"},
        {"label": "Exposed", "value": str(exposure.get("OPEN (exposed)", 0)),
         "icon": "security-low",
         "alert": exposure.get("OPEN (exposed)", 0) > 0},
        {"label": "Connections", "value": str(sum(1 for p in ports
                                                  if (p.get("remote") or ""))),
         "icon": "network-connect"},
        {"label": "Events", "value": str(ev_total), "icon": "view-calendar-list"},
    ]

    risky = sorted([t for t in tree if t["risk"] > 0],
                   key=lambda t: (-t["risk"], -t["rss"]))
    return {
        "tree": sum_subtree(tree),
        "risky_count": len(risky),
        "proc_total": len(tree),
        "tiles": tiles,
        "graph": {"nodes": nodes, "edges": edges,
                  "depth": (max(depth.values()) + 1) if depth else 1},
        "top_rss": top_rss,
        "top_cpu": top_cpu,
        "top_deps": top_deps,
        "top_dest": top_dest,
        # максимум для сравнительных шкал в интерфейсе (шкала относительная,
        # а не абсолютная: важно «кто тяжелее», а не сколько именно)
        "max_rss": max([t["rss"] for t in tree] or [0]),
        "exposure": [{"value": k, "count": v}
                     for k, v in sorted(exposure.items(), key=lambda x: -x[1])],
        "ram": ram,
    }

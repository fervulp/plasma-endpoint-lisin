"""Тематические панели расследования: файлы, привилегии, сеть.

Общая лента событий отвечает «что произошло вообще». Аналитику при разборе
нужен срез по теме: что творилось с файлами, кто повышал права, с кем
разговаривала машина. Здесь три таких среза — каждый агрегирует события и
состояние так, чтобы ответ был виден без листания сырых строк.
"""
import sqlite3


def _ro(path):
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    return con


def _q(db, sql, args=()):
    try:
        return [dict(r) for r in db.execute(sql, args)]
    except Exception:
        return []


def _eq(eventsdb, sql, args=()):
    try:
        return eventsdb.query(sql, args).get("rows", [])
    except Exception:
        return []


# --------------------------------------------------------------------------
def file_activity(db, eventsdb, limit=200) -> dict:
    """Файлы: что создавали, меняли, удаляли и чьи это файлы."""
    if eventsdb is None:
        return {"events": [], "by_action": [], "by_dir": [], "total": 0}

    events = _eq(eventsdb, f"""
        SELECT ts, event_action, file_path, file_name, file_directory,
               file_mode, file_owner, package_name, subject_name,
               process_name, event_severity, message
        FROM events
        WHERE event_category = 'file' AND COALESCE(file_path,'') <> ''
        ORDER BY _id DESC LIMIT {int(limit)}""")

    by_action = _eq(eventsdb, """
        SELECT event_action AS value, COUNT(*) AS n FROM events
        WHERE event_category = 'file' GROUP BY event_action ORDER BY n DESC""")

    by_dir = _eq(eventsdb, """
        SELECT COALESCE(file_directory,'') AS value, COUNT(*) AS n FROM events
        WHERE event_category = 'file' AND COALESCE(file_directory,'') <> ''
        GROUP BY file_directory ORDER BY n DESC LIMIT 15""")

    by_pkg = _eq(eventsdb, """
        SELECT COALESCE(package_name,'(unpackaged)') AS value, COUNT(*) AS n
        FROM events WHERE event_category = 'file'
        GROUP BY package_name ORDER BY n DESC LIMIT 12""")

    # КТО ИЗМЕНИЛ. rpm -Va честно не знает автора правки — он лишь сверяет
    # файл с эталоном пакета. Автора знает АУДИТ ЯДРА, поэтому связываем по
    # пути: если по этому файлу были audit-события, показываем субъекта и
    # время. Где данных нет — так и пишем, а не подставляем догадку.
    who = {}
    for r in _eq(eventsdb, """
            SELECT file_path, MAX(ts) AS ts,
                   MAX(COALESCE(subject_name,'')) AS subject,
                   MAX(COALESCE(user_name,'')) AS user_name,
                   MAX(COALESCE(process_name,'')) AS process_name,
                   MAX(COALESCE(user_audit_id,'')) AS login_uid
            FROM events
            WHERE COALESCE(file_path,'') <> '' AND event_module <> 'fim'
            GROUP BY file_path"""):
        who[r["file_path"]] = r
    for e in events:
        w = who.get(e.get("file_path"))
        if w:
            e["changed_by"] = w.get("subject") or w.get("process_name") or ""
            e["changed_by_user"] = w.get("user_name") or w.get("login_uid") or ""
            e["changed_at"] = w.get("ts") or ""
            e["who_source"] = "kernel audit"
        else:
            e["changed_by"] = ""
            e["changed_by_user"] = ""
            e["changed_at"] = ""
            # честно: сверка rpm показывает ФАКТ расхождения, но не автора
            e["who_source"] = "rpm -Va: the editor is not recorded"

    by_who = _eq(eventsdb, """
        SELECT COALESCE(NULLIF(subject_name,''),'(not recorded)') AS value,
               COUNT(*) AS n, MAX(ts) AS last_seen
        FROM events WHERE COALESCE(file_path,'') <> ''
        GROUP BY value ORDER BY n DESC LIMIT 12""")

    # график активности по часам — виден ритм и всплески
    series = _eq(eventsdb, """
        SELECT substr(ts,1,13) AS bucket, COUNT(*) AS n FROM events
        WHERE event_category='file' GROUP BY bucket
        ORDER BY bucket DESC LIMIT 48""")
    series = list(reversed(series))

    total = 0
    for r in by_action:
        total += int(r.get("n") or 0)
    return {"events": events, "by_action": by_action, "by_dir": by_dir,
            "by_package": by_pkg, "by_who": by_who, "series": series,
            "total": total}


# --------------------------------------------------------------------------
def privesc_activity(db, eventsdb, limit=150) -> dict:
    """Повышение привилегий: и события (кто что делал), и постоянные векторы."""
    events, auth_fail, sudo_cmd = [], [], []
    if eventsdb is not None:
        events = _eq(eventsdb, f"""
            SELECT ts, event_action, event_outcome, subject_name, user_name,
                   user_audit_id, process_name, process_command_line,
                   object_name, event_severity, message
            FROM events
            WHERE event_category IN ('authentication','iam')
               OR event_action IN ('user_command','privilege_change')
            ORDER BY _id DESC LIMIT {int(limit)}""")
        auth_fail = _eq(eventsdb, """
            SELECT COALESCE(subject_name,'?') AS value, COUNT(*) AS n FROM events
            WHERE event_category = 'authentication' AND event_outcome = 'failure'
            GROUP BY subject_name ORDER BY n DESC LIMIT 10""")
        sudo_cmd = _eq(eventsdb, """
            SELECT COALESCE(process_command_line,'') AS value, COUNT(*) AS n
            FROM events WHERE event_action = 'user_command'
              AND COALESCE(process_command_line,'') <> ''
            GROUP BY process_command_line ORDER BY n DESC LIMIT 15""")

    con = _ro(db.path)
    try:
        # ВРЕМЯ ОБЯЗАТЕЛЬНО (положение 6): вектор без даты нельзя связать с
        # инцидентом. changed — mtime носителя вектора, age_days — возраст.
        # Сортировка по свежести: недавно появившееся важнее давно лежащего.
        vectors = _q(con, "SELECT kind, name, detail, risk, nopasswd, source, "
                          "changed, age_days FROM privesc "
                          "ORDER BY changed DESC, risk DESC LIMIT 200")
        suid = _q(con, "SELECT path, owner, perms FROM suid_binaries LIMIT 200")
        admins = _q(con, "SELECT name, privilege, admin_groups, shell FROM users "
                         "WHERE COALESCE(admin_groups,'') <> ''")
        polkit = _q(con, "SELECT action, title, allow_active FROM polkit_actions "
                         "WHERE risk = 'high' LIMIT 60")
    finally:
        con.close()
    return {"events": events, "auth_failures": auth_fail, "sudo_commands": sudo_cmd,
            "vectors": vectors, "suid": suid, "admins": admins, "polkit": polkit,
            "total": len(events)}


# --------------------------------------------------------------------------
def network_flows(db, eventsdb, limit=60) -> dict:
    """С кем и как часто разговаривает машина.

    Объём трафика в байтах нам недоступен без root (conntrack/eBPF), поэтому
    честная метрика — ЧИСЛО СЕССИЙ: сколько раз соединение открывалось.
    Пишем это прямо в поле unit, чтобы не выдавать сессии за байты.
    """
    flows, dns, by_asn = [], [], []
    if eventsdb is not None:
        flows = _eq(eventsdb, f"""
            SELECT destination_ip AS ip,
                   MAX(COALESCE(process_name,'')) AS process_name,
                   MAX(COALESCE(process_source,'')) AS process_source,
                   MAX(COALESCE(network_protocol,'')) AS protocol,
                   MAX(COALESCE(destination_domain,'')) AS domain,
                   MAX(COALESCE(destination_as_org,'')) AS as_org,
                   MAX(COALESCE(destination_geo_country,'')) AS country,
                   MAX(COALESCE(threat_indicator,'')) AS threat,
                   MAX(COALESCE(network_direction,'')) AS direction,
                   COUNT(*) AS sessions,
                   COUNT(DISTINCT destination_port) AS ports,
                   MAX(COALESCE(destination_port,'')) AS last_port,
                   MAX(COALESCE(process_name,'')) AS process,
                   MIN(ts) AS first_seen, MAX(ts) AS last_seen,
                   COUNT(DISTINCT substr(ts,1,13)) AS active_hours
            FROM events
            WHERE event_category = 'network' AND COALESCE(destination_ip,'') <> ''
            GROUP BY destination_ip
            ORDER BY sessions DESC LIMIT {int(limit)}""")

        dns = _eq(eventsdb, """
            SELECT COALESCE(destination_domain,'') AS name,
                   MAX(destination_ip) AS ip, COUNT(*) AS n
            FROM events WHERE COALESCE(destination_domain,'') <> ''
            GROUP BY destination_domain ORDER BY n DESC LIMIT 25""")

        by_asn = _eq(eventsdb, """
            SELECT COALESCE(destination_as_org,'(unknown)') AS value,
                   COUNT(*) AS n, COUNT(DISTINCT destination_ip) AS ips
            FROM events WHERE event_category = 'network'
              AND COALESCE(destination_ip,'') <> ''
            GROUP BY destination_as_org ORDER BY n DESC LIMIT 15""")

    # к кому машина ходит прямо сейчас — из снимка сокетов
    con = _ro(db.path)
    try:
        live = _q(con, "SELECT proto, local, remote, process, exposure "
                       "FROM ports WHERE COALESCE(remote,'') <> '' LIMIT 200")
        resolvers = _q(con, "SELECT item, value FROM dns LIMIT 40")
    finally:
        con.close()

    ext = sum(1 for f in flows if f.get("direction") == "external")

    # РЕДКИЕ СЕССИИ. Массовый трафик (браузер, мессенджер) виден и так;
    # опасное обычно малозаметно: несколько соединений к одному адресу,
    # владелец неизвестен, живёт в узком окне времени. Признак чисто
    # структурный — никаких списков «плохих» адресов.
    for f in flows:
        n = int(f.get("sessions") or 0)
        hours = int(f.get("active_hours") or 0)
        marks = []
        if f.get("direction") == "external" and n <= 3:
            marks.append("few sessions")
        if not f.get("process_name"):
            marks.append("owner unknown")
        if hours <= 1 and f.get("direction") == "external":
            marks.append("narrow time window")
        if f.get("threat"):
            marks.append("matched a threat feed")
        f["rare"] = ", ".join(marks) if len(marks) >= 2 else ""

    # ГРАФИК: сессии по часам. Ровный ритм = автоматика (опрос, синхронизация),
    # всплеск = разовая активность. Считаем в Python, чтобы интерфейс только
    # рисовал и точки не прыгали между перерисовками.
    series = _eq(eventsdb, """
        SELECT substr(ts,1,13) AS bucket, COUNT(*) AS n,
               SUM(CASE WHEN network_direction='external' THEN 1 ELSE 0 END) AS ext
        FROM events WHERE event_category='network'
        GROUP BY bucket ORDER BY bucket DESC LIMIT 48""") if eventsdb else []
    series = list(reversed(series))

    # КТО создаёт сессии — то, ради чего дашборд и нужен
    by_proc = _eq(eventsdb, """
        SELECT COALESCE(NULLIF(process_name,''),'(owner unknown)') AS value,
               COUNT(*) AS n, COUNT(DISTINCT destination_ip) AS ips,
               MAX(ts) AS last_seen
        FROM events WHERE event_category='network'
        GROUP BY value ORDER BY n DESC LIMIT 15""") if eventsdb else []

    return {"flows": flows, "dns": dns, "by_asn": by_asn, "live": live,
            "resolvers": resolvers, "total": len(flows), "external": ext,
            "series": series, "by_process": by_proc,
            "rare": sum(1 for f in flows if f.get("rare")),
            "unit": "sessions (byte volume needs root)"}


def flow_detail(db, eventsdb, ip: str) -> dict:
    """Разбор одного направления: кто говорил, когда, чем и куда смотреть.

    Дашборд обязан отвечать не «сколько», а «что делать». Поэтому здесь:
    участники (процессы и их пакеты), лента событий со временем, живые
    сокеты и ГОТОВЫЕ переходы в «Состояние» — чтобы не искать вручную.
    """
    out = {"ip": ip, "events": [], "processes": [], "live": [], "explore": []}
    if eventsdb is not None:
        out["events"] = _eq(eventsdb, """
            SELECT ts, event_action, process_name, process_pid, process_source,
                   source_port, destination_port, network_transport,
                   network_protocol, network_direction, destination_as_org,
                   destination_domain, threat_indicator, user_name
            FROM events WHERE destination_ip = ? OR source_ip = ?
            ORDER BY ts DESC LIMIT 200""", (str(ip), str(ip)))
        out["processes"] = _eq(eventsdb, """
            SELECT COALESCE(NULLIF(process_name,''),'(unknown)') AS name,
                   MAX(COALESCE(process_pid,'')) AS pid,
                   MAX(COALESCE(process_source,'')) AS how,
                   COUNT(*) AS sessions, MIN(ts) AS first_seen, MAX(ts) AS last_seen
            FROM events WHERE destination_ip = ?
            GROUP BY name ORDER BY sessions DESC""", (str(ip),))

    con = _ro(db.path)
    try:
        rows = _q(con, "SELECT proto, local, remote, process, exposure, "
                       "owner_cmd, owner_user FROM ports WHERE remote LIKE ?",
                  (str(ip) + ":%",))
        out["live"] = rows
        # чем является процесс: пакет и назначение — из инвентаря
        names = {r["name"] for r in out["processes"] if r["name"] != "(unknown)"}
        pkg = []
        for n in list(names)[:10]:
            pkg += _q(con, "SELECT command, user, pid, package, purpose FROM "
                           "processes WHERE command LIKE ? LIMIT 3", ("%" + n + "%",))
        out["packages"] = pkg
    finally:
        con.close()

    # куда смотреть дальше — переходы, а не совет «посмотрите сами»
    # Переходы: у каждого — КУДА идти и С КАКИМ условием. Раньше у «событий
    # по адресу» не было ни таблицы, ни условия, поэтому кнопка была мертва.
    esc = str(ip).replace("'", "''")
    out["explore"] = [
        {"label": "Sockets for this address", "kind": "state", "table": "ports",
         "col": "remote", "val": str(ip)},
        {"label": "Events for this address", "kind": "events",
         "where": "destination_ip = '%s' OR source_ip = '%s'" % (esc, esc)},
    ]
    for p_ in out["processes"][:3]:
        if p_["name"] != "(unknown)":
            out["explore"].append(
                {"label": "Events for process " + p_["name"], "kind": "events",
                 "where": "process_name = '%s'" % p_["name"].replace("'", "''")})
    for p_ in out["processes"][:3]:
        if p_["name"] != "(unknown)":
            out["explore"].append({"label": "Process " + p_["name"],
                                   "kind": "state", "table": "processes",
                                   "col": "command", "val": p_["name"]})
    return out

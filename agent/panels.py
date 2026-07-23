"""Thematic investigation panels: files, privileges, network.

The common event feed answers "what happened at all". While working through a
case an analyst needs a slice by topic: what happened to the files, who
escalated privileges, who the machine talked to. Here are three such slices -
each aggregates events and state so that the answer is visible without scrolling
through raw rows.
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
    """Files: what was created, changed, deleted and whose files they are."""
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

    # WHO CHANGED IT. rpm -Va honestly does not know the author of a change - it
    # only compares the file with the package reference. The author is known to
    # the KERNEL AUDIT, so we link by path: if there were audit events for this
    # file, we show the subject and the time. Where there is no data we say so
    # plainly instead of substituting a guess.
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
            # honestly: the rpm check shows the FACT of a divergence, not the author
            e["who_source"] = "rpm -Va: the editor is not recorded"

    by_who = _eq(eventsdb, """
        SELECT COALESCE(NULLIF(subject_name,''),'(not recorded)') AS value,
               COUNT(*) AS n, MAX(ts) AS last_seen
        FROM events WHERE COALESCE(file_path,'') <> ''
        GROUP BY value ORDER BY n DESC LIMIT 12""")

    # an activity chart by hour - the rhythm and the spikes become visible
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
    """Privilege escalation: both events (who did what) and standing vectors."""
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
        # THE TIME IS MANDATORY (principle 6): a vector without a date cannot be
        # tied to an incident. changed is the mtime of the vector's carrier,
        # age_days is its age. Sorted by freshness: something that appeared
        # recently matters more than something that has been lying around.
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
    """Who the machine talks to, and how often.

    The traffic volume in bytes is unavailable to us without root
    (conntrack/eBPF), so the honest metric is the NUMBER OF SESSIONS: how many
    times a connection was opened. We write that into the unit field so as not to
    pass sessions off as bytes.
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

    # who the machine is talking to right now - from the socket snapshot
    con = _ro(db.path)
    try:
        live = _q(con, "SELECT proto, local, remote, process, exposure "
                       "FROM ports WHERE COALESCE(remote,'') <> '' LIMIT 200")
        resolvers = _q(con, "SELECT item, value FROM dns LIMIT 40")
    finally:
        con.close()

    ext = sum(1 for f in flows if f.get("direction") == "external")

    # RARE SESSIONS. Bulk traffic (a browser, a messenger) is visible anyway;
    # the dangerous thing is usually inconspicuous: a few connections to one
    # address, an unknown owner, living in a narrow time window. The property is
    # purely structural - no lists of "bad" addresses.
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

    # THE CHART: sessions by hour. An even rhythm means automation (polling,
    # synchronisation), a spike means one-off activity. Computed in Python so that
    # the interface only draws it and the points do not jump between repaints.
    series = _eq(eventsdb, """
        SELECT substr(ts,1,13) AS bucket, COUNT(*) AS n,
               SUM(CASE WHEN network_direction='external' THEN 1 ELSE 0 END) AS ext
        FROM events WHERE event_category='network'
        GROUP BY bucket ORDER BY bucket DESC LIMIT 48""") if eventsdb else []
    series = list(reversed(series))

    # WHO creates the sessions - the very thing the dashboard exists for
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
    """A breakdown of one direction: who talked, when, with what and where to look.

    A dashboard must answer not "how many" but "what to do". Hence: the
    participants (processes and their packages), a feed of events with times,
    live sockets and READY jumps into "State" - so that nothing has to be
    searched for by hand.
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
        # what the process is: the package and the purpose - from the inventory
        names = {r["name"] for r in out["processes"] if r["name"] != "(unknown)"}
        pkg = []
        for n in list(names)[:10]:
            pkg += _q(con, "SELECT command, user, pid, package, purpose FROM "
                           "processes WHERE command LIKE ? LIMIT 3", ("%" + n + "%",))
        out["packages"] = pkg
    finally:
        con.close()

    # where to look next - jumps, not the advice "go and look yourself"
    # Jumps: each has a DESTINATION and a CONDITION. The one for events by
    # address used to have neither a table nor a condition, so the button was dead.
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

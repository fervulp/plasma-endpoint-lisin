"""Data for the "State" dashboard.

It gathers into one structure what otherwise lies in different tables:
processes (the launch graph, as in a SIEM/EDR), resource usage, program
dependencies, network (port exposure and where we actually go). Pure stdlib,
read only.

The graph layout is computed HERE (the x/y of the nodes) so that QML only draws
it - that way the placement is deterministic and does not jump between repaints.
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
    # a kernel thread "[kworker/0:1-events]" -> "kworker", otherwise the names
    # were cut into rubbish like "0]" and grouped at random
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


def activity_history(eventsdb, pid):
    """The chronological history of ONE process: (list, truncated).

    "Which commands did it launch, and what did it do, in time order?" A
    process_started event carries parent_pid = this pid for every COMMAND this
    process launched (its child's pid is process_pid), while process_pid = this
    pid gives the process's OWN actions (connections, file changes). Merging the
    two and ordering by time is the history. The most recent 500 are kept and
    reversed to ascending, so a long-running process shows its latest activity
    rather than only its first (and says so if older activity was dropped).

    Honest limit: procmon/journal are pollers, so a command that lived entirely
    between two polls is missed; kernel audit (execve) catches more.
    """
    pid = str(pid)
    history = []
    if eventsdb is None:
        return history, False
    try:
        hrows = eventsdb.query(
            "SELECT ts, event_category, event_action, process_pid, "
            "parent_pid, process_name, process_executable, "
            "process_command_line, destination_ip, destination_port, "
            "destination_as_org, file_path, object_name, message FROM events "
            "WHERE process_pid = ? OR parent_pid = ? "
            "ORDER BY ts DESC, _id DESC LIMIT 501", (pid, pid)).get("rows", [])
    except Exception:
        hrows = []
    truncated = len(hrows) > 500
    for e in reversed(hrows[:500]):              # back to ascending time
        act = e.get("event_action") or ""
        cat = e.get("event_category") or ""
        ppd = str(e.get("process_pid") or "")
        ppid = str(e.get("parent_pid") or "")
        child = ""
        if act == "process_started" and ppd == pid:
            kind = "started"                     # this process itself came up
            target = (e.get("process_command_line") or e.get("process_executable")
                      or e.get("process_name") or "")
        elif act == "process_started" and ppid == pid:
            kind = "launched"                    # a command this process launched
            target = (e.get("process_command_line") or e.get("process_executable")
                      or e.get("process_name") or e.get("message") or "")
            child = ppd
        elif cat == "network":
            kind = "network"
            dip = e.get("destination_ip") or ""
            dp = e.get("destination_port")
            org = e.get("destination_as_org") or ""
            target = ((dip + (":" + str(dp) if dp else "")) or
                      (e.get("object_name") or ""))
            if org:
                target += "  (" + org + ")"
        elif cat == "file":
            kind = "file"
            target = e.get("file_path") or e.get("object_name") or ""
        elif cat == "authentication":
            kind = "auth"
            target = e.get("object_name") or e.get("message") or ""
        else:
            kind = cat or "event"
            target = e.get("object_name") or e.get("message") or ""
        history.append({
            "ts": e.get("ts", ""), "kind": kind, "action": act,
            "target": str(target)[:140], "child_pid": child,
            "message": str(e.get("message") or "")[:160]})
    return history, truncated


def history_sections(eventsdb, pid):
    """The activity history as sidebar sections, grouped by the DAY it happened.

    This answers "how did it change over time": the timeline for the graph's
    Activity-history block, shown in the right side panel like any other node.
    """
    hist, truncated = activity_history(eventsdb, pid)
    if not hist:
        return {"sections": [], "error": "no recorded activity for this process"}
    verb = {"started": "started", "launched": "launched", "network": "→",
            "file": "changed", "auth": "auth", "event": ""}
    groups = []            # [(day, [rows])] preserving chronological order
    index = {}
    for h in hist:
        day = (h["ts"] or "")[:10] or "unknown"
        if day not in index:
            index[day] = []
            groups.append((day, index[day]))
        t = (h["ts"] or "")[11:19]
        label = verb.get(h["kind"], h["kind"])
        v = (label + " " + h["target"]).strip() or h["message"]
        if h["child_pid"]:
            v += "  [pid %s]" % h["child_pid"]
        index[day].append({"k": t, "v": v})
    sections = []
    for i, (day, rows) in enumerate(groups):
        title = day
        if i == 0:
            title = ("Timeline (latest 500)" if truncated else "Timeline") + "  ·  " + day
        sections.append({"title": title, "rows": rows})
    return {"sections": sections, "error": ""}


def process_detail(db, eventsdb, pid):
    """An EDR breakdown of ONE process: how much it eats, how it started, what it
    did, which program it belongs to, what that program depends on, and which
    systemd unit is responsible for it.

    Everything is gathered through the links between tables: processes ->
    applications (the package plus its depends/required_by) -> ports (sockets) ->
    events (what it did).
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

    # --- how it started: the chain of ancestors ---
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

    # --- the systemd unit responsible for the process ---
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

    # --- which program the binary belongs to ---
    base = exe.rsplit("/", 1)[-1] if exe else ""
    pkg = None
    # FIRST we take the ALREADY ENRICHED package from the process row: the
    # proc_purpose enrichment unwraps the interpreter (python3 -> tuned), while
    # the resolving logic here did not and showed "python3".
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
        # the authoritative answer from rpm: /usr/bin/Telegram -> telegram-desktop
        # (in the inventory rpm rows have no path, and the package name != the file name)
        import subprocess
        try:
            out = subprocess.run(["rpm", "-qf", "--qf", "%{NAME}", exe],
                                 capture_output=True, text=True, timeout=5).stdout.strip()
        except Exception:
            out = ""
        if out and "not owned" not in out and " " not in out:
            pkg = next((a for a in apps if a.get("name") == out), {"name": out})

    # THE NEIGHBOURS OF THE BINARY WERE REMOVED. They showed +-18 file names
    # nearby in the directory - in /usr/bin that is thousands of packaged files,
    # and the list gave nothing. The original point (noticing a planted file next
    # to a legitimate one) is already covered by the "outside any package"
    # property: it is structural and works in any directory, not only in an
    # alphabetical window.
    neighbours = []
    bindir = exe.rsplit("/", 1)[0] if "/" in exe else ""

    # --- THE FILES THE PROCESS HOLDS OPEN ---
    # From the open_files table (which the pipeline fills), not by reading /proc
    # behind its back. Sockets and pipes are filtered out: they are shown in a
    # separate section, and here we need the answer to "which files does it work
    # with".
    files = []
    try:
        # ONE PATH - ONE ROW: a process holds the same file through several
        # descriptors (zen-bin holds /dev/dri/renderD128 six times), and the list
        # turned into a repetition of one row.
        # THE SAME SET AND THE SAME CEILING AS IN THE GRAPH (links.around):
        # this place used to lack 'directory' and had LIMIT 60, so the graph
        # showed 110 files and the panel 60, and it was unclear which to believe.
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

    # --- the sockets of the process ---
    socks = [{"proto": p.get("proto", ""), "local": p.get("local", ""),
              "remote": p.get("remote", ""), "state": p.get("state", ""),
              "exposure": p.get("exposure", "")}
             for p in ports if _pid_of(p.get("process", "")) == pid]

    # --- what the process did: events for this pid ---
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
    # NO SILENT TRUNCATION: if we hit the ceiling, the panel says so plainly
    did_truncated = len(did) > 200
    did = did[:200]

    # --- THE ACTIVITY HISTORY: what the process did, in time order ---
    # "Which commands did it launch, and what did it do, chronologically?" A
    # process_started event carries parent_pid = this pid for every COMMAND this
    # process launched (its child's pid is process_pid), while process_pid = this
    # pid gives the process's OWN actions (connections, file changes). Merging the
    # two and ordering by time is the history. We take the most recent 500 and
    # reverse to ascending, so a long-running process shows its latest activity
    # rather than only its first (and says so if older activity was dropped).
    #
    # Honest limit: procmon/journal are pollers, so a command that lived entirely
    # between two polls is missed; kernel audit (execve) catches more, which is
    # why packaging/lisin-grant-access installs those rules.
    history, hist_truncated = activity_history(eventsdb, pid)

    # --- the children of the process ---
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
        "history": history, "history_truncated": hist_truncated,
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
    """/proc/PID/exe -> the path (empty if there are no rights / the process died)."""
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

    # ---- network by process ----
    net_by_pid = defaultdict(list)
    exposure = defaultdict(int)
    for p in ports:
        pid = _pid_of(p.get("process", ""))
        exp = p.get("exposure", "") or ""
        if exp:
            exposure[exp] += 1
        if pid:
            net_by_pid[pid].append(p)

    # ---- the launch graph: the top by RSS + ALL their ancestors ----
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
    # order: by depth, and within it by parent and name (stable)
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

    # ---- the FULL process tree with a risk score ----
    # Showing only "the top by memory" is wrong: the dangerous thing is usually
    # SMALL (a dropper in /tmp, a reverse shell, a miner loader). So we return ALL
    # processes as a tree, and what floats to the top is decided not by size but
    # by RISK - the way it is done in Process Explorer and EDR consoles.
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
        # how many objects it holds open - that is a resource, and it is visible
        # without root: it immediately shows a process leaking descriptors
        try:
            nfd = len(os.listdir("/proc/%s/fd" % pid))
        except OSError:
            nfd = 0
        # THE ADDRESSES OF THE PROCESS as a string - so that a process can be
        # found BY IP AND PORT. Without it the search covered only the name, the
        # command line and the user, and "who is connected to 198.51.100.7" had no answer.
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
            # "what this is and what it is for" - from the proc_purpose enrichment
            "title": r.get("title", "") or "", "purpose": r.get("purpose", "") or "",
            "user": r.get("user", ""), "rss": round(_f(r.get("rss_mb")), 1),
            "cpu": round(_f(r.get("cpu")), 1), "elapsed": r.get("elapsed", ""),
            "depth": depth, "kernel": kernel, "exe": exe,
            "ports": len(nets), "exposure": worst,
            "unix": unix_by_pid.get(pid, 0),
            "risk": sc, "why": ", ".join(why), "files": nfd,
            "children": len(kids_of.get(pid, [])),
        })
        # THE TREE IS SHOWN IN FULL. Identical leaf children (3 or more with the
        # same name) used to collapse into a row "name xN" - the tree was shorter,
        # but the process you needed could end up inside a group with no way to
        # find it. A full tree is longer, but every process is visible in it.
        kids = sorted(kids_of.get(pid, []),
                      key=lambda k: -_f(by_pid.get(k, {}).get("rss_mb")))
        for k in kids:
            walk(k, depth + 1)

    # SUMS OVER THE SUBTREE. A collapsed branch must show how much the WHOLE
    # branch eats, otherwise a browser with 17 processes looks light: 200 MB at
    # the root while in reality it is 2 GB. We count bottom up over the already
    # built tree - it is in DFS order, so a single pass from the end is enough.
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
    for r in procs:                      # orphaned (the parent has already died)
        walk(str(r["pid"]), 0)

    # ---- consumption ----
    top_rss = [{"name": _base(r.get("command")), "pid": str(r["pid"]),
                "user": r.get("user", ""), "value": round(_f(r.get("rss_mb")), 1)}
               for r in sorted(live, key=lambda r: -_f(r.get("rss_mb")))[:10]]
    top_cpu = [{"name": _base(r.get("command")), "pid": str(r["pid"]),
                "user": r.get("user", ""), "value": round(_f(r.get("cpu")), 1)}
               for r in sorted(live, key=lambda r: -_f(r.get("cpu")))[:10]
               if _f(r.get("cpu")) > 0]

    # ---- dependencies: the programs with the most components ----
    try:
        inv = entities.programs(db)
    except Exception:
        inv = []
    progs = [e for e in inv if e.get("role") == "program"]
    top_deps = [{"name": e["name"], "kind": e["kind"], "value": e["components"]}
                for e in sorted(progs, key=lambda e: -e.get("components", 0))[:10]
                if e.get("components", 0) > 0]

    # ---- network: where we actually go (from events already enriched with ASN) ----
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
        # the maximum for the comparative scales in the interface (the scale is
        # relative, not absolute: what matters is "who is heavier", not by how much)
        "max_rss": max([t["rss"] for t in tree] or [0]),
        "exposure": [{"value": k, "count": v}
                     for k, v in sorted(exposure.items(), key=lambda x: -x[1])],
        "ram": ram,
    }

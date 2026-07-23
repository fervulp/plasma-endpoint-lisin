"""EVENT CHAINS: from separate records to a coherent story.

A single event means almost nothing: "a connection was opened", "a process was
started", "a file was changed". The meaning appears when the SEQUENCE is
visible: a user logged in -> started a shell -> it downloaded a file -> the file
was executed -> a connection went out. It is the chain that gets investigated,
not a single row.

What we link by is what actually exists in the taxonomy, without guessing:

  1. PROCESS ANCESTRY is the basis. Start events have process_pid and
     parent_pid; from them a map "child -> ancestor" is built, and every event
     is lifted to the ROOT of its branch. The root is the chain identifier.
  2. An event without a process (part of the journal, audit without a pid) is
     attached by user and time window - but marked as linked more weakly.

A chain answers four questions at once: who (the subject and the user), when
(the start and the end), what they did (the categories and actions of the
steps), where they went (the addresses). Everything else can be hung on it.
"""
# the order of category importance: it decides what a chain "looks like"
CAT_ORDER = ["process", "authentication", "file", "network", "package",
             "iam", "intrusion_detection"]


def _rows(eventsdb, sql, args=(), max_rows=0):
    try:
        return eventsdb.query(sql, args, max_rows=max_rows).get("rows", [])
    except Exception:
        return []


def _short(cmd: str) -> str:
    cmd = (cmd or "").strip()
    if not cmd:
        return ""
    first = cmd.split()[0]
    return first.rsplit("/", 1)[-1]


def build(eventsdb, limit: int = 4000, min_len: int = 2,
          statedb=None, want_steps=None, want_index=False) -> dict:
    """Build chains from the latest events.

    limit is how many of the latest events we consider (chains are built over a
    window, not over the whole database: otherwise, on hundreds of thousands of
    records, it is pointlessly slow and the chains glue together).
    """
    if eventsdb is None:
        return {"chains": [], "total": 0, "linked": 0, "events": 0}

    # ALL fields: the steps of a chain are shown by the same table and the same
    # side panel as the ordinary feed, so they need the whole taxonomy
    ev = _rows(eventsdb, "SELECT * FROM events ORDER BY _id DESC LIMIT ?",
               (int(limit),), max_rows=int(limit))
    ev.reverse()                       # chronological order
    if not ev:
        return {"chains": [], "total": 0, "linked": 0, "events": 0}

    # ---- the ancestry map: pid -> ppid ----
    # It is built WIDER than the window: journal/audit/netmon events have a pid
    # but NO parent_pid, so within one window they did not rise to a root and were
    # only linked weakly, by user. We take the ancestry from two complete sources:
    # all procmon events (they always have a ppid) and the LIVE snapshot of the
    # state processes. After that an event with only a pid finds its branch.

    parent = {}
    name_of = {}
    for r in _rows(eventsdb,
                   "SELECT process_pid p, parent_pid pp, process_name n "
                   "FROM events WHERE COALESCE(parent_pid,'') <> '' "
                   "ORDER BY _id DESC LIMIT 40000", max_rows=40000):
        pp_, p_ = str(r["pp"] or "").strip(), str(r["p"] or "").strip()
        if p_ and pp_ and p_ != pp_:
            parent.setdefault(p_, pp_)
        if p_ and r["n"]:
            name_of.setdefault(p_, r["n"])
    if statedb is not None:
        try:
            import sqlite3
            con = sqlite3.connect("file:%s?mode=ro" % statedb.path, uri=True)
            for pid_, ppid_, cmd_ in con.execute(
                    "SELECT pid, ppid, command FROM processes"):
                a_, b_ = str(pid_ or "").strip(), str(ppid_ or "").strip()
                if a_ and b_ and a_ != b_:
                    parent.setdefault(a_, b_)
                if a_ and cmd_ and a_ not in name_of:
                    name_of[a_] = str(cmd_).split()[0].rsplit("/", 1)[-1]
            con.close()
        except Exception:
            pass
    for e in ev:
        p = str(e.get("process_pid") or "").strip()
        pp = str(e.get("parent_pid") or "").strip()
        if p and pp and p != pp:
            parent.setdefault(p, pp)
        if p and e.get("process_name"):
            name_of.setdefault(p, e["process_name"])

    # THE BOUNDARY OF THE STORY is the command the user started.
    # Ancestry by itself gives no boundary: everything in a session converges on
    # systemd, and we ended up with ONE chain of 15000 events, from which nothing
    # can be read. So we rise only to the process whose PARENT is an interactive
    # shell. The list of shells comes from /etc/shells: the system itself declares
    # what it considers a login shell, no names from us.

    shells = set()
    try:
        with open("/etc/shells") as f:
            for ln in f:
                ln = ln.strip()
                if ln and not ln.startswith("#"):
                    shells.add(ln.rsplit("/", 1)[-1])
    except OSError:
        pass

    def root_of(pid: str) -> str:
        """The root of a branch - but NOT init.

        If we rise all the way to the top, everything started in a graphical
        session ends up in ONE chain named after some dbus-broker-launch: 900
        events from which no story can be read. So we stop at the LAST ancestor
        that still has an ancestor of its own in the map - that is, at the
        application started by the session manager (a terminal, a browser, a
        service), not at the manager. The property is structural: "the parent of
        the parent is already unknown" - no lists of names.


        Loop protection is mandatory: pids are reused, and a cycle in the ancestor
        map would hang the build.
        """
        seen, cur = set(), str(pid)
        while cur not in seen:
            seen.add(cur)
            up = parent.get(cur)
            if up is None or up in seen:
                return cur
            # the parent is an interactive shell: so the CURRENT process is the
            # command that was typed, there is no point rising further
            if name_of.get(up, "").rsplit("/", 1)[-1] in shells:
                return cur
            # we know nothing above the parent - it is the session manager
            if parent.get(up) is None:
                return cur
            cur = up
        return cur

    # ---- THE LINKING CASCADE ----
    # Ancestry alone covers only events that have a pid: netmon without an owner,
    # rpmdb, fim and statediff have none by nature. That does not make them
    # "nobody's" - they can be attached by OTHER facts, and every method is
    # marked honestly so that it is visible how reliable the link is:
    #   1) ancestry - the same process or its ancestor (the most reliable);
    #   2) socket   - the same socket (address and port on both sides) that was
    #                 already seen on an event with a known owner;
    #   3) object   - the same file/package the chain touched;
    #   4) time     - the same user and the same time window (weak).

    LINK_STRENGTH = {"ancestry": "strong", "socket": "strong",
                     "object": "medium", "time": "weak"}

    def sock_key(e):
        d = str(e.get("destination_ip") or "")
        dp = str(e.get("destination_port") or "")
        return (d + ":" + dp) if d else ""

    def obj_key(e):
        for f in ("file_path", "object_name", "package_name"):
            v = str(e.get(f) or "").strip()
            if v:
                return v
        return ""

    chains = {}
    by_link = {}
    sock_owner, obj_owner, user_last = {}, {}, {}

    def touch(key, e, how):
        c = chains.get(key)
        if c is None:
            c = chains[key] = {
                "id": key, "how": how, "steps": [], "pids": [],
                "cats": {}, "actions": {}, "dests": {}, "users": [],
                "links": {}, "severity": 0,
                "start": e["ts"], "end": e["ts"]}
        c["steps"].append(e)
        c["end"] = e["ts"]
        c["links"][how] = c["links"].get(how, 0) + 1
        by_link[how] = by_link.get(how, 0) + 1
        pid = str(e.get("process_pid") or "").strip()
        if pid and pid not in c["pids"]:
            c["pids"].append(pid)
        cat = e.get("event_category") or ""
        if cat:
            c["cats"][cat] = c["cats"].get(cat, 0) + 1
        act = e.get("event_action") or ""
        if act:
            c["actions"][act] = c["actions"].get(act, 0) + 1
        d = e.get("destination_ip") or ""
        if d:
            c["dests"][d] = c["dests"].get(d, 0) + 1
        u = (e.get("subject_name") or e.get("user_name") or "").strip()
        if u and u not in c["users"]:
            c["users"].append(u)
        try:
            c["severity"] = max(c["severity"], int(e.get("event_severity") or 0))
        except (TypeError, ValueError):
            pass
        # remember the "fingerprints" of a chain so that later events without a
        # process can attach themselves to it
        sk = sock_key(e)
        if sk:
            sock_owner[sk] = key
        ok = obj_key(e)
        if ok:
            obj_owner[ok] = key
        # FINGERPRINT BY COMMAND LINE. rpmdb events ("btop was installed") and
        # state transitions have no pid and are not attached by ancestry. But the
        # package name stands as an ARGUMENT of the command that installed it:
        # "sudo dnf install btop". We register the meaningful arguments as a
        # fingerprint of the chain - then "btop was installed" finds exactly that
        # command instead of a common heap. This is a link of medium reliability,
        # and it is marked as object.
        cmd = str(e.get("process_command_line") or "")
        if cmd:
            for tok in cmd.split():
                tok = tok.strip("\"'`")
                if (len(tok) > 3 and not tok.startswith("-")
                        and "/" not in tok and tok not in ("sudo", "install",
                                                           "remove", "update")):
                    obj_owner.setdefault(tok, key)
        if u:
            user_last[u] = key

    for e in ev:
        pid = str(e.get("process_pid") or "").strip()
        if pid:
            touch("proc:" + root_of(pid), e, "ancestry")
            continue
        sk = sock_key(e)
        if sk and sk in sock_owner:
            touch(sock_owner[sk], e, "socket")
            continue
        ok = obj_key(e)
        if ok and ok in obj_owner:
            touch(obj_owner[ok], e, "object")
            continue
        u = (e.get("subject_name") or e.get("user_name") or "").strip()
        if u and u in user_last:
            touch(user_last[u], e, "time")
            continue
        if u:
            touch("user:" + u, e, "time")
            continue
        # with no identifying marks at all - a separate chain for the source, so
        # that the event is still visible instead of getting lost
        touch("mod:" + str(e.get("event_module") or "?"), e, "time")

    linked = by_link.get("ancestry", 0) + by_link.get("socket", 0)

    out = []
    for key, c in chains.items():
        if len(c["steps"]) < min_len:
            continue
        root_pid = key.split(":", 1)[1]
        first = c["steps"][0]
        title = name_of.get(root_pid) or _short(first.get("process_command_line")) \
            or first.get("process_name") or root_pid
        # a variety of categories is a sign of a "meaningful" chain:
        # start + network + file is more interesting than a hundred identical records
        span = len(c["cats"])
        out.append({
            "id": key, "title": title, "how": c["how"],
            "root_pid": root_pid if key.startswith("proc:") else "",
            "users": ", ".join(c["users"][:3]),
            "start": c["start"], "end": c["end"],
            "count": len(c["steps"]), "pids": len(c["pids"]),
            "categories": sorted(c["cats"], key=lambda x:
                                 CAT_ORDER.index(x) if x in CAT_ORDER else 99),
            "cat_counts": c["cats"],
            "top_actions": sorted(c["actions"].items(),
                                  key=lambda kv: -kv[1])[:4],
            "destinations": sorted(c["dests"].items(),
                                   key=lambda kv: -kv[1])[:4],
            "severity": c["severity"], "span": span,
            "links": c["links"],
        })
    # sorting: the varied and critical ones first - they contain a story
    out.sort(key=lambda c: (-c["span"], -c["severity"], -c["count"]))
    strong = by_link.get("ancestry", 0) + by_link.get("socket", 0)
    steps_of = []
    if want_steps and want_steps in chains:
        steps_of = chains[want_steps]["steps"]
    # the index "event -> chain": through it a state transition shows which story
    # it was part of, and one can jump there
    index_of = {}
    if want_index:
        titles = {c["id"]: c["title"] for c in out}
        for key, c in chains.items():
            t = titles.get(key, key)
            for e in c["steps"]:
                eid = e.get("event_id")
                if eid:
                    index_of[eid] = {"id": key, "title": t}
    return {"chains": out, "total": len(out), "linked": linked,
            "steps_of": steps_of, "index_of": index_of,
            "events": len(ev), "by_link": by_link,
            "strength": LINK_STRENGTH,
            "strong_pct": strong * 100 // max(1, len(ev)),
            "covered_pct": sum(v for v in by_link.values()) * 100 // max(1, len(ev))}


def detail(eventsdb, chain_id: str, limit: int = 4000, statedb=None) -> dict:
    """The steps of one chain - as FULL event rows.

    It is assembled by the same build() as the list: different linking logic in
    the list and in the breakdown has already led to a click showing nothing.
    One function - one result.
    """
    if eventsdb is None:
        return {"id": chain_id, "steps": [], "count": 0,
                "error": "no event database"}
    d = build(eventsdb, limit=limit, min_len=1, statedb=statedb,
              want_steps=chain_id)
    return {"id": chain_id, "steps": d.get("steps_of", []),
            "count": len(d.get("steps_of", [])), "error": ""}

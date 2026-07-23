"""Links between the components of the system.

Two jobs:

1. `model(db)` - the MAP OF LINKS between tables. It is not hard-coded: links
   are DISCOVERED by measuring the overlap of column values. If 90% of the
   values of `processes.user` occur in `users.name`, that is a link, and it is
   visible even if I never thought about it. That way the map does not go stale
   when a new source is added: it links itself.

2. `around(db, eventsdb, pid)` - what surrounds a SPECIFIC process: the user,
   the parent and the children, the package, the sockets and their remote
   addresses, the open files, the systemd unit. The layout (x/y) is computed
   HERE, not in the interface: otherwise the nodes jump on every repaint.
"""
import math
import re
import sqlite3

# service columns and values that are meaningless for linking
SKIP_COLS = {"_id", "_src", "content", "description", "message", "detail",
             "key", "vrl", "code", "options", "raw"}
NOISE_VALUES = {"", "-", "—", "0", "1", "yes", "no", "none", "(none)",
                "unknown", "n/a", "root"}


def _ro(db):
    # the shared per-thread reader (StateDB._reader): a graph makes ~11 reads on
    # one click; reusing one connection is the 5 ms -> 0.7 ms SQLite win. Never
    # closed here - it lives in threading.local and is reused across calls.
    return db._reader()


def _columns(con, table):
    return [r["name"] for r in con.execute(f'PRAGMA table_info("{table}")')
            if r["name"] not in SKIP_COLS]


def _values(con, table, col, limit=4000):
    """The set of non-empty values of a column - for measuring the overlap."""
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
    """Does it look like a MEASUREMENT rather than an identifier?

    A real case: `processes.rss_mb` (memory in MB) and
    `vulnerabilities.cvss_score` (a score) overlapped on eight values
    (9.6, 7.4, 8.8...), and vulnerabilities started attaching to processes BY
    THE AMOUNT OF MEMORY. The property is structural: a fractional number is a
    quantity; an identifier is almost never fractional. Integers do not fall in
    here: a uid and a port number remain linkable.
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
    """Does it look like a sequence number rather than an identifier?

    The false links came from exactly here: `pkg_history.id` and
    `shell_history.n` are both simply 1..200, with a 100% overlap and no meaning
    at all. The property is structural: all the values are integers and they form
    a dense range (the number of values is close to the length of the interval).
    Real numeric keys (a uid, a port number) are sparse and pass this test.
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


def _all_numeric(values: set) -> bool:
    """Every value is an integer - so the column is a number, not a name/path."""
    return bool(values) and all(v.isdigit() for v in values)


def model(db, min_overlap: float = 0.5, min_values: int = 3) -> dict:
    """The map of links: which columns of which tables refer to each other.

    A link counts as found if no fewer than min_overlap of the values of one
    column occur in the other. The threshold and the min_values requirement cut
    off accidental coincidences on two or three rows.
    """
    con = _ro(db)
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
        pass

    links, seen = [], set()
    keys = list(vals)
    for i, a in enumerate(keys):
        for b in keys[i + 1:]:
            if a[0] == b[0]:
                continue                    # links inside a table do not count
            va, vb = vals[a], vals[b]
            # A LINK BETWEEN TWO NUMERIC COLUMNS is only real when the columns
            # MEAN THE SAME THING - i.e. carry the same name: pid<->pid,
            # mtu<->mtu, uid<->uid. Two DIFFERENT numeric columns overlap on the
            # small integers 0,1,2,3,... by coincidence, not by reference: a file
            # descriptor (open_files.fd) was "linking" to a visit count
            # (browser_history.visits) and an install counter (pkg_history.altered)
            # purely because both contain small numbers. Names are compared, the
            # values are not - a real key link has the same column on both sides.
            if _all_numeric(va) and _all_numeric(vb) and a[1].lower() != b[1].lower():
                continue
            inter = va & vb
            if len(inter) < min_values:
                continue
            # the share is measured against the SMALLER set: a reference table
            # (users) is always smaller than a fact table (processes), and a
            # "many to one" link would not be discovered otherwise
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

    # the layout of the map is computed here: tables in a circle, so that the
    # links are visible and the nodes do not jump between repaints
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
    """WHAT THE PROCESS IS ACCESSING RIGHT NOW - from /proc/<pid>/fd.

    We show EVERYTHING that is open, with a classification: an ordinary file, a
    device, /proc and /sys (that is how a process reads the system state), a
    socket, a pipe. A similar selection used to throw away /proc and sockets - and
    for a monitor like btop nothing was left, although those are the essence of
    its work.
    AN IMPORTANT LIMITATION that has to be stated plainly: a descriptor is visible
    only while the file is OPEN. A program that reads /proc in a loop and closes
    it immediately will not show up in a snapshot. To see the accesses themselves
    one needs kernel audit rules, and that means root (packaging/lisin-grant-access).
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
    """Is the address local - so that external sessions can be marked.

    The property is structural (RFC1918/loopback/link-local), not a list of
    "bad" addresses: an outbound direction is not a threat by itself, but during
    an investigation it is the first thing to look at.
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
    """How many file descriptors the process holds (best effort, no root)."""
    import os
    try:
        return len(os.listdir("/proc/%s/fd" % pid))
    except OSError:
        return 0


# ---- GRAPH CATEGORIES (presentation + collapsing) ----
# The category a linked table falls into. The node type (kind) and the label
# column are presentation as well. THE LINK ITSELF comes from the discovered map
# (links.model), not from here: this dictionary only arranges what was found into
# meaningful groups (principle 2 - the data comes from the expertise).
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
# category -> (block label, colour, order TOP TO BOTTOM in the ladder)
# THE ORDER FOLLOWS THE INVESTIGATION: the process -> what it is (the package) ->
# what started it (the service) -> where it goes (network) -> what it holds
# (files) -> how it is configured. "Processes" and "events" have NO label: the
# type is visible from the icon and the contents, the word is only noise.
CAT_META = {
    "tree":        ("",             "#4c7ef3", 0),
    "session":     ("Session & boot", "#3498db", 0.5),
    "package":     ("Application",   "#27ae60", 1),
    # services + scheduled + persistence - one question, "what starts and when";
    # as three blocks it forced you to look in three places
    "startup":     ("Startup",       "#2471a3", 2),
    "network":     ("Network",       "#e67e22", 3),
    "files":       ("Files",         "#5d6d7e", 4),
    "configs":     ("Configuration", "#16a085", 5),
    "ipc":         ("IPC",          "#8e44ad", 6),
    "identity":    ("User",          "#2980b9", 7),
    "privesc":     ("Privileges",    "#d35400", 10),
    "vulns":       ("Vulnerabilities","#c0392b", 11),
    "events":      ("",             "#7f8c8d", 12),
    # the chronological timeline: shown as ONE block, its steps open in the side
    # panel (not expanded into nodes), because a history is read in order, not
    # scattered across the canvas
    "activity":    ("Activity history", "#b7950b", 11.5),
    "kmod":        ("Kernel Modules","#7d3c98", 13),
    "location":    ("Working directory", "#5d6d7e", 4.5),
}
# categories that do NOT expand into member nodes but open in the side panel
# (a timeline is read in order; scattering it across the canvas helps nobody)
SIDEBAR_CATS = {"activity"}
# WHAT TO WRITE ON THE SECOND LINE of a satellite node. It used to be the TABLE
# NAME ("app_config", "services") - that is about the storage layout, not about
# the substance. We take the field that actually explains the object.
SUBCOL = {
    "services": "desc", "app_config": "scope", "config_files": "scope",
    "persistence": "vector", "vulnerabilities": "cvss_rating",
    "suid_binaries": "owner", "privesc": "risk", "scheduled": "detail",
    "kernel_modules": "description", "unix_sockets": "type",
    "open_files": "kind", "ports": "exposure", "applications": "version",
    "boot_sessions": "source", "logins": "from",
}
COLLAPSE_MIN = 4      # a bigger category collapses into a meta node
# a free corridor between the process tree and the column of blocks:
# the edges need room so as not to run over the cards
COLUMN_GAP = 280
ROW_GAP = 160         # the blocks start BELOW the process tree
GRID = 40             # the same grid the canvas draws


def _snap(v):
    """Round to the canvas grid: nodes must stand on the lines."""
    return int(round(v / GRID) * GRID)
# what EVERY anchor collects MANUALLY - discovery skips these tables for it so as
# not to duplicate them. For application there is no manual set: its processes
# come from discovery (applications.name <-> processes.package), and that is right.
MANUAL_TABLES = {
    "address":   {"processes", "ports"},
    "user":      {"processes", "sessions", "shell_history"},
    "port":      {"processes", "ports"},
    "config":    {"applications", "processes"},
    "open_file": {"applications", "processes"},
}


def _emit_categories(add, link, anchor_id, ax, ay, cats, expanded,
                     tree_right=None, tree_bottom=None):
    """THE CATEGORIES TO THE RIGHT OF THE TREE: blocks go top to bottom in their column.

    It reads like the steps of an investigation: the process itself, the
    APPLICATION (package) below it, then the service, the network connections,
    the files, the configuration. The members of a block lie left to right with
    wrapping. A large block is collapsed into a meta node with a counter.
    The geometry is ENTIRELY here (the principle: layout in Python, QML only
    draws). Returns a summary of the categories.
    """
    present = [c for c in cats if cats[c]]
    present.sort(key=lambda c: CAT_META.get(c, ("", "", 99))[2])
    summary = []
    # THE LADDER: every category is its own horizontal BLOCK, the blocks go TOP TO
    # BOTTOM (process -> application -> network -> files...), the members of a
    # block go left to right with wrapping. It reads like investigation steps.
    # THE BLOCKS ARE TO THE RIGHT OF THE PROCESS TREE, not below it. When they lay
    # below, the edges from the anchor went down and crossed the tree itself. Now
    # there is a wide free corridor between the tree and the blocks, and the lines
    # go sideways, crossing nothing.
    # The blocks lie TO THE RIGHT and BELOW the level of the processes: the tree
    # occupies the upper left part of the canvas, the parameters the lower right,
    # and a free corridor for the edges stays between them. Everything is a
    # multiple of the GRID the canvas draws - otherwise nodes "hang" between lines.
    base = ax if tree_right is None else tree_right
    LEFT = _snap(base + COLUMN_GAP)
    # the step is bigger than the node width (184 px in QML) - otherwise blocks stick together
    CW, ROW_H, PER_ROW, BAND_GAP = 240, 120, 4, 40
    y = _snap((ay if tree_bottom is None else tree_bottom) + ROW_GAP)
    for cat in present:
        # DEDUPLICATION BEFORE COUNTING: one path opened through several
        # descriptors is one node. Otherwise a block promised "292" and drew 286
        # (add() collapses by id), and the counter lied.
        members, seen_m = [], set()
        for m in cats[cat]:
            if m["id"] in seen_m:
                continue
            seen_m.add(m["id"])
            members.append(m)
        label, color, _o = CAT_META.get(cat, (cat, "#888888", 99))
        rep = members[0]
        # A SIDEBAR block (the timeline) never expands into nodes and shows its
        # own real step count; a click opens it in the side panel. Ordinary blocks
        # collapse/expand on the canvas.
        sidebar = cat in SIDEBAR_CATS
        cnt = rep.get("block_count", len(members)) if sidebar else len(members)
        collapsed = sidebar or cat not in expanded
        summary.append({"id": cat, "label": label, "color": color,
                        "count": cnt, "collapsed": collapsed})
        cx, cy = LEFT, y
        # THE CATEGORY HEADER IS ALWAYS THERE (a meta node). Collapsed: "+N
        # expand"; expanded: "-N collapse". Clicking it always sends
        # toggleCategory, so the COLLAPSE path is reachable (the header used to
        # disappear on expansion and there was nothing left to collapse with).
        gid = "group:" + cat
        add(gid, "group", label,
            ("%d steps · open" % cnt) if sidebar
            else (("%d — expand" % cnt) if collapsed else ("%d — collapse" % cnt)),
            rep.get("table", ""), rep.get("col", "") if sidebar else "",
            rep.get("val", "") if sidebar else "", category=cat, color=color,
            count=cnt, collapsed=collapsed,
            # THE BLOCK ICON = the icon of its contents. The labels "Processes"
            # and "Events" were removed as extra words, but the type must still be
            # readable - otherwise with a user anchor two unnamed blocks
            # (processes and events) cannot be told apart.
            icon_kind=rep.get("kind", ""),
            badge=("+%d" % cnt) if (collapsed and not sidebar) else ("" if sidebar else "−"),
            drill=("timeline" if sidebar else "toggle"),
            pid=rep.get("pid", ""), x=_snap(cx), y=_snap(cy))
        link(anchor_id, gid, label, rel="member", count=cnt,
             via_x=round(LEFT - COLUMN_GAP / 2))
        if collapsed:
            y += ROW_H + BAND_GAP
        else:
            # ALL the members of the block, without a slice: the user expanded the
            # category precisely in order to see everything. Compactness comes
            # from collapsing, not from silently truncating the list.
            mem = sorted(members, key=lambda m: (not m.get("risk"), m["label"]))
            for i, m in enumerate(mem):
                # THE REMAINING FIELDS OF A MEMBER ARE PASSED THROUGH AS THEY ARE.
                # There used to be a closed list of fields here, and everything the
                # collector added on top (the event time, marks) silently vanished
                # on the way into the node.
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
                # THE EDGE GOES FROM THE BLOCK TO EVERY MEMBER. This line used to
                # stand OUTSIDE the loop, so only the last node got a link - when a
                # block was expanded the arrow led to a single element.
                # via_x is the corridor between the block header and the grid of
                # members, otherwise the edge to the second row runs over the first.
                link(gid, nid, cat, rel=m.get("rel", "owns"),
                     via_x=round(LEFT + 150))
            rows = (len(mem) + PER_ROW - 1) // PER_ROW
            y += rows * ROW_H + BAND_GAP
    return summary


def _declutter(nodes, w=240, h=120, rounds=80):
    """Push overlapping cards apart so none sit on top of each other.

    The tree, the boot/login spine, the working-directory node and the category
    grids are each placed independently, so a directory could land on a tree node
    (that was the "directories overlap strangely" bug). This one pass guarantees a
    clear gap - the same idea as the pipeline editor's enforceLayout. It only ever
    moves cards that actually collide, so a graph that is already tidy is untouched.
    Pushes are whole GRID steps, so cards stay grid-aligned and a later snap cannot
    pull two cleared cards back on top of each other.
    """
    if len(nodes) < 2:
        return
    for n in nodes:                               # start grid-aligned
        n["x"] = _snap(n["x"])
        n["y"] = _snap(n["y"])
    for _ in range(rounds):
        moved = False
        for i in range(len(nodes)):
            a = nodes[i]
            for j in range(i + 1, len(nodes)):
                b = nodes[j]
                dx = b["x"] - a["x"]
                dy = b["y"] - a["y"]
                ox = w - abs(dx)
                oy = h - abs(dy)
                if ox <= 0 or oy <= 0:
                    continue                      # no overlap
                if ox < oy:                       # separate along x (smaller push)
                    s = (ox // 2 // GRID + 1) * GRID
                    if dx >= 0:
                        a["x"] -= s; b["x"] += s
                    else:
                        a["x"] += s; b["x"] -= s
                else:                             # separate along y
                    s = (oy // 2 // GRID + 1) * GRID
                    if dy >= 0:
                        a["y"] -= s; b["y"] += s
                    else:
                        a["y"] += s; b["y"] -= s
                moved = True
        if not moved:
            break


def _normalize_xy(nodes, edges=None, pad=120):
    """Shift all nodes so that the minimum x/y is a positive margin.

    The categories used to be laid out in a semicircle, and the upper clusters got
    a NEGATIVE y - Flickable will not scroll to it (contentY >= 0), so they went
    off the top of the canvas. One shift fixes that for any anchor.

    CRITICAL: the edges carry via_x (a routing-corridor X coordinate), which must
    be shifted by the SAME dx - otherwise every corridor ends up to the wrong side
    of its nodes and the edge hooks backwards ("the tail goes the other way").
    """
    if not nodes:
        return
    minx = min(n["x"] for n in nodes)
    miny = min(n["y"] for n in nodes)
    dx = pad - minx if minx < pad else 0
    dy = pad - miny if miny < pad else 0
    # the shift is a multiple of the grid as well, otherwise the alignment is lost
    dx = int(round(dx / GRID) * GRID)
    dy = int(round(dy / GRID) * GRID)
    if dx or dy:
        for nd in nodes:
            nd["x"] += dx
            nd["y"] += dy
        for ed in (edges or []):
            if ed.get("via_x"):
                ed["via_x"] += dx


def _owner_pid(db, kind: str, val: str, eventsdb=None) -> str:
    """Which process an entity belongs to - so that we can enter its graph.

    Returns the pid, or "" if there is no owner (then a generic graph is built).
    We invent nothing: the pid comes from the same pipeline tables.
    """
    con = _ro(db)
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
                # nobody has the file open - take the process of the owning package
                for r in _q(con, "SELECT p.pid FROM app_config c "
                                 "JOIN processes p ON p.package = c.app "
                                 "WHERE c.path=? AND p.command NOT LIKE '[%' "
                                 "LIMIT 1", (val,)):
                    return str(r["pid"])
        elif kind == "application":
            for r in _q(con, "SELECT pid FROM processes WHERE package=? "
                             "AND command NOT LIKE '[%' LIMIT 1", (val,)):
                return str(r["pid"])
        elif kind == "address":
            # a connection is tied to a process: first a live socket whose remote
            # is this address, then the owner recorded on a network event. Even a
            # "network connection" leads to a PID - that is what to investigate.
            for r in _q(con, "SELECT process FROM ports WHERE remote LIKE ? "
                             "AND COALESCE(process,'')<>'' "
                             "ORDER BY _id DESC LIMIT 1", (str(val) + ":%",)):
                m = re.search(r"\((\d+)\)", str(r.get("process") or ""))
                if m and m.group(1) in _live_pids(con):
                    return m.group(1)
            if eventsdb is not None:
                try:
                    for r in eventsdb.query(
                            "SELECT process_pid p FROM events "
                            "WHERE destination_ip=? AND COALESCE(process_pid,'')<>'' "
                            "ORDER BY ts DESC LIMIT 20", (str(val),)).get("rows", []):
                        if str(r.get("p")) in _live_pids(con):
                            return str(r["p"])
                except Exception:
                    pass
    finally:
        pass
    return ""


_LIVE = {}


def _live_pids(con):
    # the pids present in the current snapshot, cached per connection so a graph
    # that checks several candidates does not re-read the table each time
    key = id(con)
    hit = _LIVE.get(key)
    if hit is not None:
        return hit
    pids = {str(r["pid"]) for r in _q(con, "SELECT pid FROM processes")}
    _LIVE.clear()
    _LIVE[key] = pids
    return pids


def anchor_graph(db, eventsdb, kind: str, val: str, expanded=()) -> dict:
    """THE SINGLE PIVOT: a graph around an entity of ANY type.

    kind = process | application | port | user | config | open_file.
    A process builds the launch tree (the spine) + the categories; the others get
    the centre + the categories from the discovered links. The return contract is
    one and the same ({nodes, edges, width, height, categories, anchor}), so QML
    and the side panel work identically for every anchor.
    """
    if kind == "process":
        return around(db, eventsdb, str(val), expanded=expanded)

    # ENTERING THROUGH ANOTHER ELEMENT LEADS TO THE SAME GRAPH. A port, a config,
    # an open file, an application - all of them belong to a process, and in the
    # end it is the process that gets investigated. So we resolve the entity down
    # to its process and build the ORDINARY process graph with all the blocks,
    # marking what we entered through.
    # A user is the exception: that is not one object but a set of processes, and a
    # generic graph with a "processes" block is more honest here.
    pid = _owner_pid(db, kind, str(val), eventsdb)
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
    con = _ro(db)
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
        pass

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
        # via_x is the coordinate of the free corridor for an edge; the common
        # category layout passes it to every graph, and without it a non-process
        # anchor used to fail
        edges.append({"a": a, "b": b, "label": label, "rel": rel,
                      "dir": direction, "count": count, "via_x": via_x})

    ax, ay = 520, 440
    label = str(center.get(CATMAP.get(table, ("", "", col))[2], val) or val)
    label = label.rstrip("/").rsplit("/", 1)[-1][:30] or val
    root = add(table + ":" + val, nkind, label, table, table, col, val,
               focus=True, x=ax, y=ay)

    # the reference values of the centre: its own key + package/user, if present
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

    # MANUAL CATEGORIES over real columns - where automatic discovery is weak
    # (users has only 2 rows, config/open_file is a path). This is not an
    # invention: the columns exist (processes.user, open_files.path), it is just
    # that the model() threshold does not catch them. We pull them directly.
    mc = _ro(db)
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
            # WHO WENT TO THIS ADDRESS. The same breakdown as for a process, only
            # the support is the remote address: first the live sockets from the
            # snapshot, then the network events (a connection may have closed and
            # be gone from the snapshot while it remains in the events - otherwise
            # "who sent it" was lost).
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
            # the owner of the port + the remote peers on that port
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
            # the package that owns the file (from the app_config.app row)
            pk = str(center.get("app") or center.get("package") or "").strip()
            if pk:
                cats.setdefault("package", []).append(dict(
                    id="pkg:" + pk, kind="package", label=pk, sub="owner",
                    table="applications", col="name", val=pk,
                    rel="from_package", drill="reanchor"))
            # who HOLDS the file open (directories too)
            for r in _q(mc, "SELECT DISTINCT pid, process FROM open_files "
                            "WHERE path=? LIMIT 400", (val,)):
                pr = str(r.get("process") or r.get("pid"))
                cats.setdefault("tree", []).append(dict(
                    id="proc:" + str(r["pid"]), kind="process",
                    label=pr.split()[0][:22] if pr else str(r["pid"]),
                    sub="has it open", table="processes", col="pid",
                    val=str(r["pid"]), rel="opened", drill="reanchor"))
            # events for this path
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
        pass

    con3 = _ro(db)
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
            # we do not duplicate the tables collected manually for THIS anchor,
            # nor the anchor itself
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
        pass

    categories = _emit_categories(add, link, root, ax, ay, cats, expanded)
    _declutter(nodes)
    _normalize_xy(nodes, edges)
    width = max((n["x"] for n in nodes), default=800) + 300
    height = max((n["y"] for n in nodes), default=600) + 200
    return {"nodes": nodes, "edges": edges, "width": width, "height": height,
            "categories": categories,
            "anchor": {"kind": kind, "table": table, "col": col, "val": val,
                       "label": label}, "error": ""}


def _fmt_ram(mb):
    """rss in MB -> a short human string ('640 MB', '2.1 GB'); '' if none."""
    try:
        v = float(mb)
    except (TypeError, ValueError):
        return ""
    if v <= 0:
        return ""
    return ("%.1f GB" % (v / 1024)) if v >= 1024 else ("%d MB" % round(v))


def _started_from_elapsed(elapsed):
    """ps etime ('[[DD-]HH:]MM:SS') -> local clock 'HH:MM' when the process began.

    The processes table already carries the uptime; subtracting it from now gives
    when it was launched, which is what the analyst reads on the node.
    """
    s = str(elapsed or "").strip()
    if not s:
        return ""
    try:
        from datetime import datetime, timedelta
        days = 0
        if "-" in s:
            d, s = s.split("-", 1)
            days = int(d)
        parts = [int(x) for x in s.split(":")]
        while len(parts) < 3:
            parts.insert(0, 0)
        secs = days * 86400 + parts[-3] * 3600 + parts[-2] * 60 + parts[-1]
        return (datetime.now() - timedelta(seconds=secs)).strftime("%H:%M")
    except Exception:
        return ""


def _proc_started_abs(pid, boot_iso):
    """Absolute ISO-8601 (UTC) start time of a process.

    /proc/<pid>/stat field 22 is the start time in clock ticks SINCE BOOT, so
    adding it to the boot time gives when the process actually began. This is how
    the graph decides WHICH login session a process came from - the session whose
    window contains this instant - so logging out and back in picks the right one.
    Returns '' if it cannot be read (the process is gone, or boot time unknown).
    """
    if not boot_iso:
        return ""
    try:
        import os
        from datetime import datetime, timedelta, timezone
        with open("/proc/%s/stat" % pid) as f:
            data = f.read()
        rest = data[data.rindex(")") + 2:].split()   # skip "pid (comm) "
        starttime = int(rest[19])                     # field 22, 0-based here
        hz = os.sysconf("SC_CLK_TCK") or 100
        bdt = datetime.fromisoformat(boot_iso.rstrip("Z")).replace(
            tzinfo=timezone.utc)
        pdt = bdt + timedelta(seconds=starttime / float(hz))
        return pdt.strftime("%Y-%m-%dT%H:%M:%SZ")
    except Exception:
        return ""


def around(db, eventsdb, pid: str, depth_up: int = 6,
           depth_down: int = 2, expanded=()) -> dict:
    """THE PROCESS TREE AS STEPS around the selected one.

    A step is a generation: the ancestors on the left (up to init), the process
    itself in the centre, the descendants on the right. That immediately shows HOW
    it started and what it spawned - the first question in an investigation.

    On every step the node shows counters: network sockets, unix sockets, open
    descriptors, events. They answer "what is this process busy with at all"
    without forcing you to open every node.

    The context of the process itself (the user, the package, the remote
    addresses) is added as separate nodes - one can drill through them further.
    The layout is computed here: x = the step, y = the row within the step.
    """
    import os
    pid = str(pid)
    con = _ro(db)
    try:
        rows = _q(con, "SELECT pid, ppid, user, command, package, purpose, "
                       "title, rss_mb, cpu, elapsed, arg_files FROM processes")
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

        # socket counters for all the processes of the branch at once - one pass
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
        pass

    # ---- the branch: ancestors up, descendants down ----
    chain = []
    cur, guard = me, 0
    while cur is not None and guard < depth_up:
        chain.append(cur)
        nxt = by_pid.get(str(cur.get("ppid") or ""))
        if nxt is None or str(nxt["pid"]) == str(cur["pid"]):
            break
        cur, guard = nxt, guard + 1
    chain.reverse()                      # from init to our process

    levels = {}                          # step -> the list of processes
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

    # ---- events for the processes of the branch ----
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

    # the steps are multiples of the canvas grid (GRID=40), otherwise the nodes stand between lines
    STEP_X, STEP_Y = 240, 120
    for lvl in sorted(levels):
        group = levels[lvl]
        for row, r in enumerate(group):
            rpid = str(r["pid"])
            name = (r.get("command") or "").split()[0].rsplit("/", 1)[-1] or rpid
            nid = "proc:" + rpid
            fd = _fd_count(rpid)
            # WHAT the process is busy with - counters right on the node
            counts = []
            if net_n.get(rpid):
                counts.append("net %d" % net_n[rpid])
            if unix_n.get(rpid):
                counts.append("unix %d" % unix_n[rpid])
            if fd:
                counts.append("files %d" % fd)
            if ev_n.get(rpid):
                counts.append("events %d" % ev_n[rpid])
            # A FAINT METRICS LINE: RAM, CPU and when it started. Small and low
            # contrast (rendered dim in QML) - present for a glance, not shouting.
            mtr = []
            ram = _fmt_ram(r.get("rss_mb"))
            if ram:
                mtr.append(ram)
            cpu = str(r.get("cpu") or "").strip()
            if cpu and cpu not in ("0", "0.0", "0.00"):
                mtr.append(cpu + "%")
            started = _started_from_elapsed(r.get("elapsed"))
            if started:
                mtr.append("↑ " + started)
            add(nid, "process", name,
                "pid %s · %s" % (rpid, r.get("user") or ""),
                "processes", "pid", rpid,
                counts=" · ".join(counts),
                metrics=" · ".join(mtr),
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

    # ---- THE ORIGIN OF THE PROCESS: boot -> the login session it came from ----
    # This is part of the SPINE, not a side block: every process ultimately begins
    # when the computer was turned on (systemd, pid 1) and, for a user process,
    # when that user logged in. Read left to right it is a timeline:
    #   [computer on] -> [user logged in] -> ...ancestors... -> the process.
    # The session is resolved BY TIME (see _proc_started_abs), so logging out and
    # back in selects the RIGHT session, not merely the most recent login.
    origin_anchor = ("proc:" + str(chain[0]["pid"])) if chain else root
    OX, OY = 160, 120
    bc = _ro(db)
    try:
        boot_iso = ""
        br = _q(bc, "SELECT boot_id, started FROM boot_sessions "
                    "WHERE kind='boot' AND current='yes' "
                    "ORDER BY started DESC LIMIT 1") \
            or _q(bc, "SELECT boot_id, started FROM boot_sessions "
                      "WHERE kind='boot' ORDER BY started DESC LIMIT 1")
        boot_here = False
        if br:
            boot_iso = str(br[0].get("started") or "")
            add("boot:origin", "boot", "computer turned on",
                boot_iso[:10] + " " + boot_iso[11:19], "boot_sessions",
                "boot_id", str(br[0].get("boot_id") or ""), drill="state",
                when=boot_iso)
            nodes[-1]["x"] = OX - 2 * STEP_X
            nodes[-1]["y"] = OY
            boot_here = True
        # the session this process came from: the login whose window contains the
        # process start time (for the process's own user)
        sess = None
        if user:
            pstart = _proc_started_abs(pid, boot_iso)
            logins = _q(bc, 'SELECT tty, "from", start, until FROM logins '
                            "WHERE user=? AND COALESCE(start,'')<>'' "
                            "ORDER BY start DESC", (user,))
            if pstart:
                for lg in logins:
                    s, u = str(lg.get("start") or ""), str(lg.get("until") or "")
                    if s <= pstart and (not u or pstart <= u):
                        sess = lg
                        break
            if sess is None and logins:
                sess = logins[0]      # fall back to the most recent login
        if sess is not None:
            frm = str(sess.get("from") or "")
            fromtxt = (" from " + frm) if frm and frm not in ("local", ":0") else ""
            add("session:origin", "session", "%s logged in" % user,
                ("on " + str(sess.get("tty") or "")) + fromtxt, "logins",
                "tty", str(sess.get("tty") or ""), drill="state",
                when=str(sess.get("start") or ""))
            nodes[-1]["x"] = OX - STEP_X
            nodes[-1]["y"] = OY
            # boot started systemd (pid 1); the login started the FIRST process of
            # this branch that belongs to the user - that is where the session
            # actually enters the tree, not at systemd which predates the login.
            user_root = next((c_ for c_ in chain
                              if (c_.get("user") or "").strip() == user), me)
            if boot_here:
                link("boot:origin", origin_anchor, "booted", rel="booted")
                link("boot:origin", "session:origin", "then", rel="logged_in")
            link("session:origin", "proc:" + str(user_root["pid"]),
                 "started", rel="session")
        elif boot_here:
            link("boot:origin", origin_anchor, "booted", rel="booted")
    finally:
        pass

    # ---- THE CONTEXT OF THE PROCESS: CATEGORY CLUSTERS around the node ----
    # Instead of a long column - meaningful categories (user, package, service,
    # network, IPC, files, configs, events, vulnerabilities...). A large category
    # collapses into a meta node with a counter; expanded controls which ones are
    # open. The layout of the clusters is computed by _emit_categories.
    root = "proc:" + pid
    focus_node = [x for x in nodes if x["id"] == root][0]
    ax, ay = focus_node["x"], focus_node["y"]
    cats = {}

    def push(cat, mid, kind, label, sub, table, col, val, **ex):
        cats.setdefault(cat, []).append(dict(
            id=mid, kind=kind, label=label, sub=sub, table=table,
            col=col, val=val, **ex))

    # the service (the systemd unit from cgroup) - "what really started it"
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
            uc = _ro(db)
            urow2 = _q(uc, "SELECT desc FROM services WHERE unit=? LIMIT 1", (unit,))
            if urow2:
                udesc = urow2[0].get("desc", "")
        except Exception:
            udesc = ""
        push("startup", "services:" + unit, "service", unit,
             udesc or "systemd unit", "services", "unit", unit,
             rel="runs_unit", drill="state")

    # the user
    if user:
        u = urow[0] if urow else {}
        push("identity", "user:" + user, "user", user,
             (u.get("privilege") or "") +
             (" · " + u.get("admin_groups") if u.get("admin_groups") else ""),
             "users", "name", user, rel="owns", drill="reanchor")

    # the package
    if pkg:
        a = app[0] if app else {}
        push("package", "pkg:" + pkg, "package", pkg,
             (a.get("kind") or "") + " " + (a.get("version") or ""),
             "applications", "name", pkg, rel="from_package", drill="reanchor")

    # NETWORK: the open sessions of the process. It reads as a phrase "with
    # <address> over <port> <protocol>" - that is exactly how one thinks about a
    # connection. Taken per pid, which is more authoritative than a link by package.
    for s_ in socks:
        remote = (s_.get("remote") or "").strip()
        openx = s_.get("exposure") == "OPEN (exposed)"
        proto = (s_.get("proto") or "").lower()
        state = (s_.get("state") or "").strip()
        if remote and "*" not in remote:
            host = remote.rsplit(":", 1)[0]
            rport = remote.rsplit(":", 1)[-1]
            # the local port is shown as "from" - the direction becomes visible
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

    # open files AND DIRECTORIES
    opened = []
    try:
        con2 = _ro(db)
        opened = [{"target": r["path"], "kind": r["kind"], "deleted": r["deleted"]}
                  for r in _q(con2, "SELECT path, kind, deleted FROM open_files "
                                    "WHERE pid=? AND kind IN ('file','device',"
                                    "'system state','directory') "
                                    "ORDER BY deleted DESC LIMIT 400", (pid,))]
    except Exception:
        opened = []
    if not opened:
        opened = _open_targets(pid)
    # FILES ARE GROUPED BY DIRECTORY. Fifty separate nodes with names like
    # "places.sqlite" say nothing: what matters is WHERE the process works - in
    # its own directory, in /etc, in /tmp or in someone else's profile. So the
    # label holds the directory and the file name goes on the second line; the
    # full directory is also visible in the tooltip.
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

    # FILES FROM THE COMMAND LINE (configs, certificates, keys). For a daemon
    # running as another user /proc/<pid>/fd cannot be read, and "which config
    # does it work with" had no answer; path arguments are always visible.
    for f_ in [x for x in str(me.get("arg_files") or "").split(", ") if x]:
        push("configs", "argfile:" + f_, "config",
             f_.rsplit("/", 1)[-1][:26], "given on the command line",
             "app_config", "path", f_, rel="declares", drill="state")

    # THE USER'S OWN SERVICES - the services enabled for the logged-in user, tied
    # to the origin. Kept as a collapsible block (the boot and the login itself are
    # now the spine, above); the services answer "what this user's session starts".
    if user:
        try:
            for sv in _q(con, "SELECT unit, desc FROM services "
                              "WHERE scope = 'user' AND enabled = 'enabled' "
                              "ORDER BY unit LIMIT 60"):
                push("startup", "usvc:" + str(sv.get("unit") or ""), "service",
                     str(sv.get("unit") or ""),
                     str(sv.get("desc") or "") or "user service",
                     "services", "unit", str(sv.get("unit") or ""),
                     rel="user_service", drill="state")
        except Exception:
            pass

    # THE WORKING-DIRECTORY NODE WAS REMOVED. It was shown directly under the
    # process, but its path could be wrong: when open_files had no fd='cwd' row it
    # fell back to reading /proc/<pid>/cwd LIVE, and a pid reused since the
    # snapshot pointed it at a completely different process's directory. Where the
    # process works is already answered honestly by the "Files" block, which comes
    # from open_files (the right pid), so the standalone node only added risk of a
    # wrong path.

    # events - what the process did (drill: events by pid)
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

        # THE ACTIVITY-HISTORY BLOCK. One block whose count is the number of
        # recorded steps; a click opens the chronological timeline in the side
        # panel (drill="timeline"), it does NOT expand into nodes on the canvas
        # (SIDEBAR_CATS). A history is read in order, not scattered around.
        try:
            hn = eventsdb.query(
                "SELECT COUNT(*) n FROM events WHERE process_pid = ? "
                "OR parent_pid = ?", (pid, pid)).get("rows", [{}])[0].get("n", 0)
        except Exception:
            hn = 0
        if hn:
            push("activity", "hist:" + pid, "action", "Activity history",
                 "%d steps" % int(hn), "events", "process_pid", pid,
                 rel="did", drill="timeline", pid=pid, block_count=int(hn))

    # ---- THE REMAINING SATELLITES FROM THE DISCOVERED MAP (config/vuln/persist/...) ----
    try:
        model_links = model(db).get("links", [])
    except Exception:
        model_links = []
    keyvals = {("processes", "pid"): pid, ("processes", "package"): pkg,
               ("processes", "user"): user, ("applications", "name"): pkg}
    # what was collected manually above is not duplicated
    SKIP = {"processes", "applications", "users", "services", "ports", "open_files"}
    con3 = _ro(db)
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
            # A closed advisory is HISTORY, and in the "Vulnerabilities" block it
            # reads as "the process has a hole". In the graph we show only what is
            # unpatched; the full list stays in the vulnerabilities tab.
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
        pass

    # the blocks go TO THE RIGHT of the process tree
    tree_right = max((n["x"] for n in nodes if n["id"].startswith("proc:")),
                     default=ax)
    tree_bottom = max((n["y"] for n in nodes if n["id"].startswith("proc:")),
                      default=ay)
    categories = _emit_categories(add, link, root, ax, ay, cats,
                                  set(expanded), tree_right=tree_right,
                                  tree_bottom=tree_bottom)

    _declutter(nodes)
    _normalize_xy(nodes, edges)
    width = max((n["x"] for n in nodes), default=800) + 300
    height = max((n["y"] for n in nodes), default=600) + 200
    return {"nodes": nodes, "edges": edges, "pid": pid,
            "command": me.get("command", ""), "width": width,
            "height": height, "levels": len(levels),
            "anchor": {"kind": "process", "table": "processes", "col": "pid",
                       "val": pid, "label": (me.get("command") or "")[:40]},
            "categories": categories, "error": ""}


def node_detail(db, eventsdb, table: str, col: str, val: str) -> dict:
    """EVERYTHING known about the object of a node - for the graph side panel.

    It works for a node of any type because it relies not on a hard-coded schema
    but on the MAP OF LINKS (model): we take the row from its table and then pull
    the related rows from other tables through every discovered link. A new source
    links itself and shows up here without a code change.

    Returns sections [{title, rows:[{k,v}]}] - the interface only draws them.
    """
    table, col, val = str(table), str(col), str(val)
    if not table:
        return {"sections": [], "error": "this node has no source table"}

    con = _ro(db)
    try:
        tabs = {r["name"] for r in con.execute("SELECT name FROM _tabs")}
        if table not in tabs:
            return {"sections": [], "error": "no such table"}
        cols = _columns(con, table)
        # EXACT MATCH ONLY. A substring fallback (LIKE '%val%') used to run when
        # nothing matched exactly, and it was actively misleading: a working
        # directory node for /home/local found NO row with dir='/home/local'
        # (files live in sub-directories), fell back to LIKE '%/home/local%' and
        # showed the first file it happened to contain - a Telegram log under it.
        # A node stands for a SPECIFIC value; a different row that merely contains
        # it as a substring is a different thing.
        if col and col in cols:
            rows = _q(con, 'SELECT * FROM "%s" WHERE "%s"=? LIMIT 5'
                      % (table, col), (val,))
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
            # no row is exactly this value (e.g. a directory that holds files but
            # is not itself an open file) - show the value itself honestly instead
            # of guessing a substring match
            main = {col: val} if col and val else {}
            if main:
                sections.append({"title": "What This Is",
                                 "rows": [{"k": col, "v": val}]})

        # the linked tables - from the discovered map of links
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
        pass

    # what this object did - from the events, if it is mentioned there
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

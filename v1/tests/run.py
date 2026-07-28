#!/usr/bin/env python3
"""LiSin v1 — the checks that must pass before anything is called done.

WHY THIS EXISTS. Most defects in this app were not syntax errors and not layout
errors: they were a query the interface builds being refused by the database on
some table, or a value carried over from the previously open table. Compiling
proves the QML parses; rendering proves it lays out; neither presses a button.
So this walks the actual paths — on EVERY tab — and fails loudly.

Run it after every change:

    cd v1 && PYTHONNOUSERSITE=1 python3 tests/run.py

The app holds a lock on the DuckDB files, so stop the service first:

    systemctl --user stop lisin.service

Sections:
  compile  — every .py imports, every .qml parses
  engine   — a full forced collection: every input works, every view applies
  data     — columns that are empty in every row (a source that stopped working)
  paths    — per tab: free-text search, a condition, sort, grouping, and the
             invariant that the query bar's SELECT is what the table shows
Exit code is the number of failed sections.
"""
from __future__ import annotations

import glob
import os
import pathlib
import subprocess
import sys
import time

V1 = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, V1)
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ.setdefault("QT_QUICK_CONTROLS_STYLE", "org.kde.desktop")
os.environ["LISIN_NO_COLLECT"] = "1"      # the test drives collection itself

FAIL: list[str] = []


def section(name: str) -> None:
    print(f"\n=== {name} ===")


def bad(msg: str) -> None:
    FAIL.append(msg)
    print(f"  FAIL  {msg}")


def ok(msg: str) -> None:
    print(f"  ok    {msg}")


# ---------------------------------------------------------------- compile
def check_compile() -> None:
    section("compile")
    pys = [p for p in glob.glob(f"{V1}/**/*.py", recursive=True)
           if "/vendor/" not in p]
    r = subprocess.run([sys.executable, "-m", "py_compile", *pys],
                       capture_output=True, text=True)
    if r.returncode:
        bad(f"python: {r.stderr.strip()[:300]}")
    else:
        ok(f"{len(pys)} python files compile")

    from PySide6.QtGui import QGuiApplication
    from PySide6.QtQml import QQmlComponent, QQmlEngine
    from PySide6.QtCore import QUrl
    app = QGuiApplication.instance() or QGuiApplication(sys.argv)
    eng = QQmlEngine()
    eng.addImportPath(f"{V1}/ui")
    qmls = sorted(glob.glob(f"{V1}/ui/**/*.qml", recursive=True))
    broken = 0
    for f in qmls:
        c = QQmlComponent(eng, QUrl.fromLocalFile(f))
        if c.isError():
            broken += 1
            bad(f"qml {os.path.relpath(f, V1)}: {c.errors()[0].toString()[:160]}")
    if not broken:
        ok(f"{len(qmls)} qml files parse")


# ---------------------------------------------------------------- engine
def check_engine(store):
    section("engine")
    from core import pipeline
    # leftovers from a previous run that was killed mid-collection are not this
    # run's leak; clear them so the check below means what it says
    pipeline.sweep_temp(older_than=120)
    t = time.perf_counter()
    started = time.time()
    st = pipeline.run_all(store, force=True)
    el = time.perf_counter() - t
    failed = [x for x in st["inputs"] if x["error"]]
    # A DERIVATION MUST NOT SHARE A NAME WITH A SENSOR TABLE. The derivation
    # layer replaces the object it owns (a slow one is stored as a table), so a
    # collision would mean one rule silently destroying the other's data every
    # cycle. Cheap to assert, impossible to notice otherwise.
    from core import views as _views
    from core import pipeline as _pl
    dnames = {v.get("name") for v in _views.load_views()}
    inames = {i.get("table") or i.get("name") for i in _pl.load_inputs()}
    clash = sorted(n for n in dnames & inames if n)
    if clash:
        bad(f"a derivation and an input share a name: {', '.join(clash)}")
    else:
        ok(f"{len(dnames)} derivations, {len(inames)} inputs, no name collision")
    for x in failed:
        bad(f"input {x['table']}: {x['error'][:120]}")
    if not failed:
        ok(f"{len(st['inputs'])} inputs collected in {el:.1f}s")
    for v in st.get("derive", {}).get("views", []):
        if v["error"]:
            bad(f"view {v['view']}: {v['error'][:120]}")
    if not any(v["error"] for v in st.get("derive", {}).get("views", [])):
        ok("all views apply")
    # a collection cycle must not creep towards the tick
    if el > 45:
        bad(f"collection cycle {el:.0f}s is too slow for a 30 s source")
    # ONLY THE FILES THIS RUN COULD HAVE MADE. The pattern also matches debris
    # left by anything else that drove a collection and was killed — a probe, an
    # earlier session — and reporting those as a leak here sends the reader after
    # a defect that is not in the collector.
    left = [f for f in glob.glob("/tmp/lisin-osq-*.json")
                     + glob.glob("/tmp/lisin-cmd-*.tsv")
                     + glob.glob("/tmp/lisin-auth-*.py")
                     + glob.glob("/tmp/lisin-boots-*.py")
            if os.path.getmtime(f) >= started]
    if left:
        bad(f"{len(left)} temp files left behind by this collection")
    else:
        ok("no temp files left behind")


# ------------------------------------------------------------------ guard
def check_sql_guard():
    """THE READ-ONLY GUARD MUST REFUSE WHAT IT IS FOR AND NOTHING ELSE. It is the
    only thing standing between the query service (and the SQL page) and a write,
    so it cannot be loosened casually — and it cannot be so blunt that ordinary
    queries are refused, because the refusal is silent and the feature just stops
    working. Both directions are asserted here; the third case is the one the
    dead-column audit found, where a COLUMN NAMED `load` read as the LOAD
    statement."""
    section("sql guard")
    from core.db import select_only
    cases = [
        ('SELECT a FROM t', True, "a plain select"),
        ('SELECT "load" FROM failed_units', True, "a column named load"),
        ('SELECT "attach" FROM t', True, "a column named attach"),
        ("SELECT 'delete' AS x", True, "a keyword inside a value"),
        ("SELECT * FROM t WHERE x = 'a;b'", True, "a semicolon inside a literal"),
        ("WITH c AS (SELECT 1) SELECT * FROM c", True, "a CTE"),
        ('LOAD httpfs', False, "a real LOAD"),
        ('INSTALL httpfs', False, "a real INSTALL"),
        ("ATTACH 'x.db' AS y", False, "a real ATTACH"),
        ("SELECT 1; DROP TABLE t", False, "two statements"),
        ("DROP TABLE t", False, "a drop"),
        ("UPDATE t SET a = 1", False, "an update"),
    ]
    wrong = [(s, w, l) for s, w, l in cases if select_only(s) is not w]
    for s, w, l in wrong:
        bad(f"the guard {'refuses' if w else 'allows'} {l}: {s}")
    if not wrong:
        ok(f"{len(cases)} cases: everything that writes is refused, "
           f"everything that reads is not")


# ------------------------------------------------------------ authentication
def check_ssh_parsing():
    """SSH LOGINS MUST BE UNDERSTOOD ON A MACHINE THAT HAS NONE. This laptop has
    no sshd traffic in its journal, so the rule's own tests — which run SQL
    against what was collected — cannot say whether the SSH half works. The
    parser is therefore driven directly with invented journal records: an
    accepted key, a refused password, an unknown user, a PAM session and the
    kernel's own audit verdict. Addresses are from the ranges RFC 5737 reserves
    for documentation.

    The result column is what this guards. It was wrong once already: the audit
    message nests its fields inside a quoted blob, the pattern swallowed the blob
    whole, and every successful authentication was recorded as a failure."""
    section("ssh")
    import json as _j
    import subprocess as _sp
    import tempfile as _tf
    import yaml as _y

    rule = _y.safe_load(
        open(os.path.join(V1, "expertise/inputs/authentication.yaml")))
    cmd = rule["command"]
    prog = cmd.split("<<'PYAUTH'\n", 1)[1].split("PYAUTH\n", 1)[0]
    prog = "\n".join(l[2:] if l.startswith("  ") else l for l in prog.split("\n"))
    fh = _tf.NamedTemporaryFile("w", suffix=".py", delete=False)
    fh.write(prog)
    fh.close()

    def rec(**kw):
        d = {"__REALTIME_TIMESTAMP": "1785260000000000"}
        d.update(kw)
        return _j.dumps(d)

    feed = "\n".join([
        rec(SYSLOG_IDENTIFIER="sshd",
            MESSAGE="Accepted publickey for analyst from 198.51.100.7 port 55210 ssh2"),
        rec(SYSLOG_IDENTIFIER="sshd",
            MESSAGE="Failed password for invalid user admin from 203.0.113.9 port 41022 ssh2"),
        rec(SYSLOG_IDENTIFIER="sshd",
            MESSAGE="pam_unix(sshd:session): session opened for user analyst(uid=1001) by (uid=0)"),
        rec(_AUDIT_TYPE_NAME="AUDIT1112",
            MESSAGE=("AUDIT1112 pid=1 uid=0 auid=1001 ses=9 msg='op=login "
                     "acct=\"analyst\" exe=\"/usr/sbin/sshd\" addr=198.51.100.7 "
                     "terminal=ssh res=failed'")),
        rec(_AUDIT_TYPE_NAME="AUDIT1100",
            MESSAGE=("AUDIT1100 pid=2 uid=1000 auid=1000 ses=6 msg='op=PAM:authentication "
                     "acct=\"local\" exe=\"/usr/bin/sudo\" res=success'")),
    ])
    try:
        out = _sp.run([sys.executable, fh.name], input=feed, capture_output=True,
                      text=True, timeout=60)
    finally:
        os.unlink(fh.name)
    if out.returncode != 0:
        bad(f"the authentication parser failed: {out.stderr.strip()[:140]}")
        return
    rows = [l.split("\t") for l in out.stdout.strip().split("\n") if l.strip()]
    got = {(r[1], r[2], r[3], r[4], r[5]) for r in rows}
    want = [
        (("success", "analyst", "sshd", "publickey", "198.51.100.7:55210"),
         "an accepted key, with who and from where"),
        (("failed", "admin", "sshd", "password", "203.0.113.9:41022"),
         "a refused password"),
        (("failed", "analyst", "login", "login", "198.51.100.7"),
         "the kernel's own verdict on a failed login"),
    ]
    missing = [why for w, why in want if w not in got]
    if missing:
        for why in missing:
            bad(f"the authentication rule does not record {why}")
    else:
        ok(f"{len(rows)} invented records parsed: accepted, refused, and the "
           f"kernel's verdict")
    # and the one that was wrong: a success must never read as a failure
    wrong = [r for r in rows if r[1] == "failed" and "res=success" in " ".join(r)]
    if wrong or ("success", "local", "authentication", "authenticate", "") not in got:
        bad("a successful authentication is not recorded as success")
    else:
        ok("a success is recorded as a success, not as a failure")


# ------------------------------------------------------------- rule tests
def check_rule_tests(store):
    """Run what each rule says about its own table. A source does not usually
    FAIL when somebody else's output format changes — dnf5 prints a fixed-width
    table where dnf4 printed pipes, osquery fills a column on one system and not
    another — it collects fewer rows, or the same rows with an empty column, and
    everything downstream carries on with less. That is what these catch."""
    section("rule tests")
    from core import pipeline as _pl, views as _v, ruletest
    rules = _pl.load_inputs() + _v.load_views()
    have = [r for r in rules if r.get("tests")]
    results = ruletest.run_all(store, [r for r in _pl.load_inputs() if r.get("tests")])
    failed = [r for r in results if not r["passed"]]
    for r in failed:
        bad(f"{r['rule']}: {r['test']} — {r['detail']}")
    if not failed:
        ok(f"{len(results)} assertions from {len(have)} rules, all hold")


# ------------------------------------------------------------- duplicates
def check_duplicates(store):
    """A ROW THAT APPEARS TWICE IS A COUNT THAT LIES. Three ways it happened
    here: osquery returns every listening port twice (identical down to the file
    descriptor, checked against osqueryi itself), rpm lists the same
    configuration file twice for the same package, and long URLs were cut to a
    fixed width so different addresses became the same row. The third is the
    nastiest — the data was not duplicated, it was TRUNCATED into looking
    duplicated, which is why a truncated value now ends in an ellipsis.

    A few tables legitimately hold repeats (a history of events), so this asks
    about SNAPSHOT tables: what is on the machine right now."""
    section("duplicates")
    from core.db import ident as _id
    # a snapshot of state: each row is a thing that exists, so two identical rows
    # mean one thing counted twice
    skip = {"shell_history", "logins", "authentication", "pkg_history",
            "browser_history", "events"}
    found, checked = [], 0
    for table in sorted(x for x in store.tables() if not x.startswith("_")):
        if table in skip:
            continue
        cols = [c for c in store.columns(table) if not c.startswith("_")]
        if not cols:
            continue
        total = store.row_count(table)
        if total == 0:
            continue
        sel = ", ".join(_id(c) for c in cols)
        try:
            uniq = store.fetch(
                f"SELECT count(*) FROM (SELECT DISTINCT {sel} FROM {_id(table)})"
            )["rows"][0][0]
        except Exception:  # noqa: BLE001
            continue
        checked += 1
        if uniq < total:
            found.append(f"{table}: {total} rows but only {uniq} distinct "
                         f"({total - uniq} counted twice)")
    for f in found:
        bad(f)
    if not found:
        ok(f"{checked} snapshot tables hold no row twice")


# ------------------------------------------------------------------- clock
def check_clock(store):
    """EVERY STORED MOMENT IS UTC. The interface converts once, at the display
    boundary, and a bare timestamp is READ there as UTC — so a rule that writes
    LOCAL time has its values shifted by the whole time zone when shown. Seven
    rules were doing it: an authentication at 21:21 local was displayed as 00:21
    the next day.

    Two ways to catch it, because a machine may be either side of UTC:
    a moment in the FUTURE is impossible for something that already happened, and
    a freshly collected table whose newest value sits on LOCAL now rather than UTC
    now is storing local time. Columns that legitimately hold the future (next_*)
    are asked about their past instead."""
    section("clock")
    import datetime as _dt
    import re as _re
    from core.db import ident as _id

    now_utc = _dt.datetime.now(_dt.UTC).replace(tzinfo=None)
    now_local = _dt.datetime.now()
    offset = abs((now_local - now_utc).total_seconds())
    checked, bad_cols = 0, []
    for table in sorted(x for x in store.tables() if not x.startswith("_")):
        cols = store.columns(table)
        for c in cols:
            low = c.lower()
            if low.startswith("next"):
                continue                      # legitimately in the future
            if not any(k in low for k in ("time", "_at", "date", "started",
                                          "issued", "changed", "modified",
                                          "installed", "last_run", "ended")):
                continue
            try:
                v = store.fetch(
                    f"SELECT max(CAST({_id(c)} AS VARCHAR)) FROM {_id(table)}"
                )["rows"][0][0]
            except Exception:  # noqa: BLE001
                continue
            if not v or not _re.match(r"^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}", str(v)):
                continue
            try:
                seen = _dt.datetime.fromisoformat(str(v)[:19].replace("T", " "))
            except ValueError:
                continue
            checked += 1
            ahead = (seen - now_utc).total_seconds()
            if ahead > 300:
                bad_cols.append(f"{table}.{c} = {v} — {ahead/3600:.1f} h in the "
                                f"future, which is what local time looks like here")
            elif offset > 600 and abs((seen - now_local).total_seconds()) < 120:
                bad_cols.append(f"{table}.{c} = {v} sits on LOCAL now, not UTC now")
    for b in bad_cols:
        bad(b)
    if not bad_cols:
        ok(f"{checked} timestamp columns are stored in UTC")

    # AND AT THE SOURCE, because the check above can only see columns whose
    # newest value is near NOW: a file modification time from three months ago is
    # three hours wrong in exactly the same way and looks entirely plausible. No
    # rule may ask for local time at all — a mechanical fact about the text, and
    # the one that catches every rule rather than the fresh ones.
    from core import pipeline as _pl, views as _vw
    guilty = []
    for r in _pl.load_inputs() + _vw.load_views():
        body = str(r.get("command") or "") + str(r.get("query") or "") + str(r.get("sql") or "")
        for needle in ("localtime", "time.localtime", "'localtime'"):
            if needle in body:
                guilty.append(f"{r.get('name')} asks for {needle}")
                break
    for g in guilty:
        bad(f"a rule writes LOCAL time — {g}")
    if not guilty:
        ok(f"no rule asks for local time ({len(_pl.load_inputs())} checked)")


# ---------------------------------------------------------------- orphans
def check_orphans(store):
    """THE STORE MIRRORS THE EXPERTISE: one table per rule, and nothing else.

    Rename a rule or delete it and its old table used to stay behind for ever —
    as a TAB, titled by its raw name, with a provenance line naming a rule that
    does not exist. A stale answer is worse than no answer, and this one looked
    exactly like a real source.

    Checked by making one: a table with no rule must be gone after a collection,
    its measurements with it, and nothing a rule DOES own may be touched."""
    section("orphans")
    from core import pipeline as _pl, views as _vw

    owned = {str(i.get("table") or i.get("name")) for i in _pl.load_inputs()}
    owned |= {str(v.get("name")) for v in _vw.load_views()}
    before = {t for t in store.tables() if not t.startswith("_")}
    left = sorted(before - owned)
    if left:
        bad(f"tables no rule owns: {', '.join(left[:6])}")

    store._con.execute("CREATE OR REPLACE TABLE _probe_orphan AS SELECT 1 AS a")
    store._con.execute("ALTER TABLE _probe_orphan RENAME TO probe_orphan")
    dropped = _pl.drop_orphans(store)
    after = {t for t in store.tables() if not t.startswith("_")}
    if "probe_orphan" in after:
        bad("a table with no rule survived the collection")
        store._con.execute("DROP TABLE IF EXISTS probe_orphan")
    elif "probe_orphan" not in dropped:
        bad("the orphan was removed without being reported")
    else:
        ok("a table with no rule is removed, and reported")
    lost = sorted(owned & before - after)
    if lost:
        bad(f"the cleanup removed tables that ARE owned: {', '.join(lost[:6])}")
    else:
        ok(f"all {len(before & owned)} owned tables untouched")


# ------------------------------------------------------------ entry points
def check_entry_points(store):
    """WHAT EACH ENTRY POINT PRODUCES, AGAINST WHAT IT PRODUCED BEFORE.

    A source rarely breaks loudly. dnf5 prints a fixed-width table where dnf4
    printed pipes; osquery renames a column between releases; a tool stops being
    installed; a permission changes. The collection still succeeds — it just
    returns fewer rows, or the same rows with a column gone, and everything
    downstream carries on with less.

    So every entry point is run once here and compared against tests/baseline.json
    on three counts: it must not LOSE a column, it must not collapse in row count,
    and it must not come back empty unless the rule SAYS it may (`may_be_empty:`
    with the reason). Growth is never a failure.

    The same pass counts fields per line, because a command's output has no header
    and columns are mapped by position: a value holding a tab or a newline shifts
    data sideways or tears the row in half — which is exactly what `vms` was doing.
    One collection answers both questions; two would be the sort of cost that gets
    a check deleted later.

    When a change is MEANT to change what a source collects:
        cd v1 && PYTHONNOUSERSITE=1 python3 tests/baseline.py --update
    and read the diff it prints — that diff is the claim being made."""
    section("entry points")
    sys.path.insert(0, os.path.join(V1, "tests"))
    import baseline as _bl

    now = _bl.measure(store)
    arity = [(n, v) for n, v in now.items() if v.get("arity_wrong")]
    for n, v in arity:
        bad(f"{n}: {v['arity_wrong']} line(s) do not have the fields the rule "
            f"declares (seen: {v['arity_seen']})")
    if not arity:
        cmds = sum(1 for v in now.values() if v.get("arity_seen"))
        ok(f"{cmds} command rules print exactly the fields they declare")

    was = _bl.load()
    if not was:
        bad("there is no baseline yet — run tests/baseline.py to record one")
        return
    problems = _bl.compare(now, was)
    for p in problems:
        bad(p)
    if not problems:
        total = sum(v["rows"] for v in now.values())
        ok(f"{len(now)} entry points match the baseline ({total:,} rows, "
           f"no column lost, none unexpectedly empty)")


# --------------------------------------------------------------- contract
def check_contract(store):
    """A RULE'S DECLARED COLUMNS MUST EXIST. `columns:` is the rule's contract
    with the interface — the fields it says are worth reading first, which is
    what the table shows before anything is unhidden. A name that does not exist
    is dropped silently, so the tab quietly shows less than its author intended
    and nothing anywhere says so. Two rules were doing exactly that: `network`
    named ipv4/ipv6 where the query produces family/address, and `startup_items`
    named path where the query aliases it to command."""
    section("contract")
    from core import pipeline as _pl, views as _views
    have = {t: set(store.columns(t)) for t in store.tables()}
    checked = broken = 0
    for r in _pl.load_inputs() + _views.load_views():
        decl = list(r.get("columns") or [])
        if not decl:
            continue
        name = r.get("table") or r.get("name")
        checked += 1
        missing = [c for c in decl if c not in have.get(name, set())]
        if missing:
            broken += 1
            bad(f"{name} declares columns it does not produce: {', '.join(missing)}")
    if not broken:
        ok(f"{checked} rules declare columns, all of them exist")


# ---------------------------------------------------------------- data
def check_data(store):
    section("data")
    from core.db import ident
    empty_tables, dead_total, cols_total = [], 0, 0
    for t in sorted(x for x in store.tables() if not x.startswith("_")):
        cols = store.columns(t)
        n = store.row_count(t)
        if n == 0 or cols == ["empty"]:
            empty_tables.append(t)
            continue
        parts = ", ".join(
            f"sum(CASE WHEN {ident(c)} IS NULL OR CAST({ident(c)} AS VARCHAR) = ''"
            f" THEN 0 ELSE 1 END)" for c in cols)
        vals = store._con.execute(f"SELECT {parts} FROM {ident(t)}").fetchone()
        dead = [c for c, v in zip(cols, vals) if not v]
        cols_total += len(cols)
        dead_total += len(dead)
    ok(f"{dead_total} columns of {cols_total} are empty in every row")

    if empty_tables:
        ok(f"empty tables (may be legitimate, e.g. need root): {', '.join(empty_tables)}")
    # a source that produced rows before and produces none now is worth shouting
    # about; that needs history, so it is only reported, not failed.


# ---------------------------------------------------------------- paths
def check_reads(backend):
    """EVERY TABLE THE INTERFACE OFFERS MUST READ IN UNDER A FRAME. These calls
    happen on the GUI thread: a tab whose page costs 170 ms is a window that
    stops for 170 ms on every switch and every push. The dependency footprint
    was exactly that (a recursive CTE recomputed per read) until the derivation
    layer began storing slow derivations; this keeps it from coming back on any
    tab, not just that one."""
    section("reads")
    import time as _t
    snap = backend._snapshot()
    slow = []
    for tab in [x["name"] for x in snap["tabs"]]:
        t0 = _t.perf_counter()
        backend.tableRows(tab, 0, 50, "", "")
        ms = (_t.perf_counter() - t0) * 1000
        if ms > 60:
            slow.append((tab, ms))
    if slow:
        for tab, ms in sorted(slow, key=lambda x: -x[1]):
            bad(f"a page of {tab} costs {ms:.0f} ms on the GUI thread")
    else:
        ok(f"all {len(snap['tabs'])} tabs read a page in under 60 ms")


def check_events(events):
    """The event pipeline has produced more defects than anything else — a
    watermark derived instead of stored (endless re-work), a counter inside the
    try (retention never ran), a memory cap below what a backlog costs (ingest
    died), a prune that ran before the watermark existed (raw never trimmed). Each
    is invisible from the outside: events simply stop, or the file grows. So the
    invariants are asserted here."""
    section("events")
    from core.eventstore import MAX_ROWS, RAW_WINDOW, BATCH_BYTES
    raw = events.raw_count()
    hist = events._con.execute("SELECT count(*) FROM events").fetchone()[0]
    ok(f"{hist:,} events, {raw:,} raw lines staged")

    # 1. materialize is idempotent: caught up means nothing to do
    events.materialize()
    again = events.materialize()
    if again:
        bad(f"materialize is not idempotent: did {again} rows again when caught up")
    else:
        ok("materialize is idempotent when caught up")

    # 2. a line the normalization drops must not make it loop forever
    events.append(["this is not json"])
    events.materialize()
    stuck = events.materialize()
    if stuck:
        bad("a line the view drops keeps materialize reporting work forever")
    else:
        ok("a dropped line does not stall the watermark")

    # 3. retention actually bounds both tables
    events.prune()
    raw2 = events.raw_count()
    hist2 = events._con.execute("SELECT count(*) FROM events").fetchone()[0]
    if raw2 > RAW_WINDOW + BATCH_SLACK:
        bad(f"raw staging is {raw2:,} rows, above the {RAW_WINDOW:,} window")
    else:
        ok(f"raw staging bounded to {raw2:,} (window {RAW_WINDOW:,})")
    if hist2 > MAX_ROWS + BATCH_SLACK:
        bad(f"history is {hist2:,} rows, above the {MAX_ROWS:,} bound")
    else:
        ok(f"history bounded to {hist2:,} (max {MAX_ROWS:,})")

    # 4. FOLDING MUST MOVE AN EVENT, NEVER LOSE ONE. A process start and its end
    # arrive as two events, and the ends were 134 389 rows of 281 514 — so the end
    # is written onto the row that already describes that process. Two things have
    # to hold: a pair becomes ONE row carrying the lifetime, and an end whose
    # start is not in the table is still recorded, as itself.
    import json as _j
    tag2 = "lisin-foldtest"
    eid = "foldtest-exec-id-1"
    def _tetra(kind, exec_id, when, pid):
        key = "process_exec" if kind == "exec" else "process_exit"
        proc = {"binary": "/usr/bin/true", "pid": pid, "uid": 0, "arguments": "",
                "exec_id": exec_id, "start_time": when}
        return _j.dumps({key: {"process": proc, "parent": proc},
                         "node_name": tag2, "time": when})
    mark2 = events._con.execute(
        "SELECT coalesce(max(seq), -1) FROM tetragon_raw").fetchone()[0]
    events.append([
        _tetra("exec", eid, "2026-01-01T00:00:00.000Z", 991001),
        _tetra("exit", eid, "2026-01-01T00:00:02.500Z", 991001),
        _tetra("exit", "foldtest-orphan-id", "2026-01-01T00:00:03.000Z", 991002),
    ])
    events.materialize()
    got = events._con.execute(
        "SELECT event_kind, lifetime_ms FROM events WHERE host = ? ORDER BY 1",
        [tag2]).fetchall()
    kinds = [g[0] for g in got]
    life = [g[1] for g in got if g[0] == "exec"]
    if kinds != ["exec", "exit"]:
        bad(f"a folded pair should leave one exec and the orphan exit, got {kinds}")
    elif not life or life[0] != 2500:
        bad(f"the folded exec should carry a 2500 ms lifetime, got {life}")
    else:
        ok("an exit folds onto its exec (2500 ms) and an orphan exit is kept")
    events._con.execute("DELETE FROM tetragon_raw WHERE seq > ?", [mark2])
    events._con.execute("DELETE FROM events WHERE host = ?", [tag2])

    # 4. A BURST OF LONG LINES MUST STILL NORMALIZE. Parsing raw JSON into the
    # taxonomy costs roughly a hundred times the line itself, and that allocation
    # counts against the memory cap while not showing up in duckdb_memory() — so
    # a batch counted in ROWS silently became a 40x range of real work, and a run
    # of long lines killed the ingest with OutOfMemory. The batch is budgeted in
    # BYTES now; this stages several budgets' worth of the longest lines the
    # sensor produces and requires the pass to survive. The synthetic rows are
    # tagged and removed afterwards, so the history stays the machine's own.
    import json as _json
    tag = "lisin-selftest"
    big = " ".join(f"--flag-{i}=/some/long/argument/path/{i}" for i in range(190))
    line = _json.dumps({"process_exec": {
        "process": {"binary": "/usr/bin/true", "pid": 999999, "uid": 0,
                    "arguments": big, "start_time": "2026-01-01T00:00:00Z"},
        "parent": {"binary": "/usr/bin/true", "pid": 1}},
        "node_name": tag, "time": "2026-01-01T00:00:00Z"})
    burst = max(1, (BATCH_BYTES * 3) // len(line))
    mark = events._con.execute("SELECT coalesce(max(seq), -1) FROM tetragon_raw").fetchone()[0]
    events.append([line] * burst)
    try:
        done = events.materialize()
        if done < burst:
            bad(f"{burst} long lines staged, only {done} normalized")
        else:
            ok(f"a burst of {burst} long lines ({burst * len(line) // 1024} KB, "
               f"{burst * len(line) / BATCH_BYTES:.1f} batches) normalized")
    except Exception as e:  # noqa: BLE001 — this is exactly the failure guarded
        bad(f"a burst of long lines broke the ingest: {str(e).splitlines()[0]}")
    finally:
        events._con.execute("DELETE FROM tetragon_raw WHERE seq > ?", [mark])
        events._con.execute("DELETE FROM events WHERE host = ?", [tag])

    # 5. the file must not carry the raw copy of what it already normalized.
    # Measured against the USED bytes, not the file size: DuckDB does not return
    # freed blocks to the operating system, so a file that has just lost rows is
    # mostly empty until it is rewritten — that is the compaction section's
    # business, and counting it here would report the wrong defect.
    # The ratio only MEANS anything once the history is large: the staging window
    # is a fixed few thousand raw lines, so on a small table it is most of the
    # file by itself. Below that the numbers are reported and not judged, which is
    # the honest thing to do with a measurement that does not apply yet.
    free, total = events.waste()
    used = max(total - free, 0)
    per = used / max(hist2, 1)
    if hist2 < 50_000:
        ok(f"{used/1048576:.0f} MB of data for {hist2:,} events and {raw2:,} staged"
           f" raw lines — too few events yet to judge bytes per event")
    elif per > 1500:
        bad(f"{used/1048576:.0f} MB of data for {hist2:,} events = {per:.0f} bytes"
            f" each — the raw copy is being kept as well as the normalized one")
    else:
        ok(f"{used/1048576:.0f} MB of data ({total/1048576:.0f} MB file),"
           f" {per:.0f} bytes per event")


BATCH_SLACK = 6000      # one materialize batch may sit above the bound


def check_errors(backend):
    """A BROKEN SOURCE MUST BE VISIBLE. This is checked by actually breaking one:
    a temporary rule with a query no database will accept is dropped into the
    expertise directory, a collection is run, and the failure has to arrive both
    in the backend's status and on the flow the Pipelines page draws. Silence here
    is the worst failure mode this tool has — a stale table looks exactly like a
    quiet system."""
    section("errors")
    import pathlib
    rule = pathlib.Path(V1) / "expertise/inputs/_test_broken.yaml"
    rule.write_text(
        "name: _test_broken\ntable: _test_broken\ntype: input\nversion: 1.0.0\n"
        "title: Deliberately broken\ninterval: 0\n"
        "description: written by tests/run.py, removed at the end of the run\n"
        "query: |\n  SELECT * FROM no_such_table_at_all\n")
    try:
        backend._run_all(force=True)
        st = backend._status.get("_test_broken", {})
        if not st.get("error"):
            bad("a source whose query fails is not recorded anywhere")
        else:
            ok(f"failure recorded: {st['error'][:60]}")
        flows = {f["name"]: f for f in backend.pipelineFlows()}
        f = flows.get("_test_broken", {})
        if not f.get("error"):
            bad("the failure does not reach the Pipelines page")
        else:
            ok("the failure reaches the flow the Pipelines page draws")
        if not f.get("error_at"):
            bad("the failure has no timestamp")
        else:
            ok(f"with the time it happened ({f['error_at']})")
    finally:
        rule.unlink(missing_ok=True)
        backend._status.pop("_test_broken", None)
        backend._meta = backend._load_meta()
        try:
            backend.store._con.execute('DROP TABLE IF EXISTS "_test_broken"')
        except Exception:  # noqa: BLE001
            pass


def check_ingest_visible(backend):
    """A STOPPED EVENT INGEST MUST BE VISIBLE TOO. The stream is the other half
    of this tool, and its loop used to swallow every exception: normalizing a
    batch hit the memory cap, every later cycle threw on the same backlog, and
    the interface kept showing the events collected before that — a stream that
    had stopped hours ago looked exactly like a quiet machine. Broken here on
    purpose, the way a source is."""
    section("ingest")
    real = backend.events.materialize
    backend.events.materialize = lambda: (_ for _ in ()).throw(
        RuntimeError("deliberate: normalization refused"))
    try:
        # one turn of the loop body, without waiting on the thread's sleep
        try:
            backend.events.materialize()
        except Exception as e:  # noqa: BLE001
            backend._set_status("_events", str(e).splitlines()[0],
                                at="2026-01-01T00:00:00Z")
        flow = next((f for f in backend.pipelineFlows()
                     if "tetragon" in f.get("name", "")), None)
        if flow is None:
            bad("the Tetragon stream has no flow on the Pipelines page")
        elif not flow.get("error"):
            bad("a stopped ingest does not reach the Pipelines page")
        elif not flow.get("error_at"):
            bad("the stopped ingest has no timestamp")
        else:
            ok(f"stopped ingest is visible: {flow['error'][:50]}")
    finally:
        backend.events.materialize = real
        backend._clear_status("_events")


def check_compaction(backend):
    """A DATABASE FILE MUST NOT KEEP GROWING WHILE THE DATA STAYS THE SAME.
    DuckDB never returns freed blocks to the operating system, and retention
    deletes rows constantly — measured before this was handled, the event store
    was 163 MB holding 93 MB of events, and the state store 33 MB holding 16 MB.
    The rewrite is checked for the two things that matter: the file gets smaller,
    and every row is still there afterwards."""
    section("compaction")
    for name, db, table in (("state", backend.store, "processes"),
                            ("events", backend.events, "events")):
        try:
            before_rows = db.row_count(table)
            free, total = db.waste()
            r = db.compact()
            after_rows = db.row_count(table)
        except Exception as e:  # noqa: BLE001
            bad(f"compacting {name} raised: {str(e).splitlines()[0][:100]}")
            continue
        if after_rows != before_rows:
            bad(f"{name}: {before_rows:,} rows before the rewrite, "
                f"{after_rows:,} after — data was lost")
        elif r.get("error"):
            bad(f"{name}: {r['error'][:100]}")
        elif r.get("compacted"):
            ok(f"{name}: {r['before_mb']} -> {r['after_mb']} MB "
               f"({r['freed_mb']} MB reclaimed in {r['seconds']} s), "
               f"{after_rows:,} rows intact")
        else:
            ok(f"{name}: {round(free/1048576)} MB free of "
               f"{round(total/1048576)} MB — below the rewrite threshold")


def check_provenance(backend):
    """EVERY TABLE MUST ACCOUNT FOR ITSELF. Rows used to appear with no statement
    of where they came from: which rule produced them, how that rule reads the
    machine, how often it runs, when this copy was collected. All of it existed
    in the Pipelines page and in the source — but not where the rows are read,
    which is where the question gets asked."""
    section("provenance")
    tabs = backend._snapshot()["tabs"]
    missing = [t["name"] for t in tabs if not (t.get("source") or {}).get("rule")]
    if missing:
        bad(f"{len(missing)} tabs cannot say what produced them: "
            f"{', '.join(missing[:6])}")
        return
    unknown = [t["name"] for t in tabs if not (t["source"].get("how") or "")]
    if unknown:
        bad(f"tabs that do not say HOW they are collected: {', '.join(unknown[:6])}")
    # the rule a table names must be a rule that exists — a dead link here is
    # worse than no link, because it looks like an answer
    from core import pipeline as _pl, views as _vw
    known = {f"inputs/{i.get('name')}" for i in _pl.load_inputs()}
    known |= {f"views/{v.get('name')}" for v in _vw.load_views()}
    known |= {"events/normalize"}
    broken = [(t["name"], t["source"]["ref"]) for t in tabs
              if t["source"].get("ref") and t["source"]["ref"] not in known]
    if broken:
        bad(f"tabs pointing at a rule that does not exist: {broken[:4]}")
    else:
        ok(f"all {len(tabs)} tabs name the rule that produced them, and it exists")


def check_engine_visible(backend):
    """THE MACHINERY MUST BE VISIBLE FROM THE INTERFACE, not only from the source.
    Every mechanism in this engine has surprised me at least once while building
    it — a file rewritten because it was half empty, a normalization that had
    fallen behind, a retention bound deciding how far back the history goes,
    process ends folded onto their starts, and which process owns the databases.
    The card that says all that is only as good as the numbers behind it, so the
    numbers are checked: present, and consistent with what the databases hold."""
    section("engine card")
    st = backend.engineState()
    need = ["owner", "socket", "databases", "stream", "collection", "tetragon"]
    missing = [k for k in need if k not in st]
    if missing:
        bad(f"the engine card would be missing: {', '.join(missing)}")
        return
    dbs = {d["name"]: d for d in st["databases"]}
    if set(dbs) != {"state", "events"}:
        bad(f"expected both databases, got {sorted(dbs)}")
    for name, d in dbs.items():
        if d.get("file_mb", 0) <= 0 or d.get("used_mb", -1) < 0:
            bad(f"{name}: file {d.get('file_mb')} MB, used {d.get('used_mb')} MB")
    stream = st["stream"]
    real = backend.events.row_count("events")
    if stream.get("materialized") != real:
        bad(f"the card says {stream.get('materialized')} events, the table has {real}")
    if stream.get("backlog", 0) < 0:
        bad(f"a negative backlog: {stream.get('backlog')}")
    # THE RATE IS THE ONE THAT LIES QUIETLY: the stream is stored in UTC and a
    # bare now() is local time, which answered "nothing in the last five minutes"
    # on a machine three hours ahead — a stopped stream and a busy one looking
    # exactly alike. The check is that the card AGREES with the same window
    # measured independently; whether the stream is live is not its business
    # (the suite runs with the agent stopped, when zero is the honest answer).
    same = backend.events.fetch(
        "SELECT count(*) FROM events WHERE ts > (now() AT TIME ZONE 'UTC')"
        " - INTERVAL 5 MINUTE")["rows"][0][0]
    if abs(stream.get("per_minute", 0) - round(same / 5)) > 1:
        bad(f"the card says {stream.get('per_minute')} events/min while the same "
            f"five minutes hold {same} ({round(same / 5)}/min)")
    ok(f"the card reports {stream.get('materialized'):,} events, "
       f"{stream.get('per_minute')}/min, backlog {stream.get('backlog')}, "
       f"{len(dbs)} databases, {st['collection'].get('sources')} sources")

    # and a rule's own tests, run the way the Expertise page runs them
    r = backend.ruleTests("scheduled")
    if r.get("error"):
        bad(f"running a rule's tests from the interface failed: {r['error']}")
    elif not r.get("results"):
        bad("a rule with tests returned no assertions")
    else:
        ok(f"a rule's tests run from the interface: {r['passed']} passed, "
           f"{r['failed']} failed")
    r2 = backend.ruleTests("memory")
    if not r2.get("note"):
        bad("a rule without tests should say so, not return an empty result")
    else:
        ok("a rule with no tests says so")


def check_concurrency(backend):
    """A SECOND PROCESS MUST BE ABLE TO READ WHILE THIS ONE COLLECTS. DuckDB
    locks a file exclusively — measured: while a writer holds it, another process
    cannot open it even read-only — so the owner serves reads over a Unix socket
    instead. This is that promise, checked by actually starting another process:
    it has to see the same numbers, be refused a write, and find the socket
    private to this user."""
    section("concurrency")
    import subprocess, stat
    if not backend.owner or backend.service is None:
        bad("this process is not the owner, so the service was never started")
        return
    from core.service import socket_path
    sp = socket_path()
    if not os.path.exists(sp):
        bad("the owner is not serving: no socket")
        return
    mode = stat.S_IMODE(os.stat(sp).st_mode)
    if mode != 0o600:
        bad(f"the socket is {oct(mode)}, not 0600 — anyone on the machine could read")
    else:
        ok("the socket is private to this user (0600)")
    mine = backend.store.row_count("processes")
    prog = (
        "import sys; sys.path.insert(0, %r)\n"
        "from core.remote import RemoteDB, probe\n"
        "p = probe()\n"
        "s = RemoteDB('state'); e = RemoteDB('events')\n"
        "n = s.row_count('processes'); m = e.row_count('events')\n"
        "try:\n"
        "    s.fetch('DROP TABLE processes'); w = 'ALLOWED'\n"
        "except Exception: w = 'refused'\n"
        "print(p.get('pid'), n, m, w)\n" % V1)
    r = subprocess.run([sys.executable, "-c", prog], capture_output=True,
                       text=True, timeout=60,
                       env={**os.environ, "PYTHONNOUSERSITE": "1"})
    if r.returncode != 0:
        bad(f"a second process could not read: {r.stderr.strip().splitlines()[-1][:110]}")
        return
    pid, n, m, w = r.stdout.split()
    if int(pid) != os.getpid():
        bad(f"the second process reached pid {pid}, not this owner ({os.getpid()})")
    elif int(n) != mine:
        bad(f"the second process sees {n} processes, the owner {mine}")
    else:
        ok(f"a second process reads the same {n} processes and {int(m):,} events")
    if w != "refused":
        bad("a client was allowed to WRITE through the service")
    else:
        ok("a client may read, never write")


def check_layout(backend):
    """THE TABLE MUST ACTUALLY OCCUPY THE PAGE. Compiling proves the QML parses;
    the path walk proves the queries run; neither notices a table that is drawn
    at zero size. That happened: wrapping the table in a layout to add a line
    above it left its anchors ignored, and every tab in Data came up blank while
    the rows were sitting in the model. So the size is measured, on several tabs,
    against the window it should be filling."""
    section("layout")
    from PySide6.QtGui import QGuiApplication
    from PySide6.QtQml import QQmlApplicationEngine
    from PySide6.QtCore import QUrl, QMetaObject, Qt, Q_ARG

    app = QGuiApplication.instance() or QGuiApplication(sys.argv)
    eng = QQmlApplicationEngine()
    eng.rootContext().setContextProperty("backend", backend)
    eng.addImportPath(f"{V1}/ui")
    eng.load(QUrl.fromLocalFile(f"{V1}/ui/Main.qml"))
    if not eng.rootObjects():
        bad("Main.qml did not load")
        return
    win = eng.rootObjects()[0]
    win.resize(1500, 900)
    QMetaObject.invokeMethod(win, "open", Qt.DirectConnection,
                             Q_ARG("QVariant", "state"))
    for _ in range(12):
        app.processEvents()

    def visual(root):  # noqa: E306
        """Every item in the VISUAL tree. A ListView's delegates hang off its
        contentItem, and QObject.children() does not reach them — which is why
        the tab list read as empty from a probe while it was on screen."""
        out, stack, seen = [], [root], set()
        while stack:
            it = stack.pop()
            if it is None or id(it) in seen:
                continue
            seen.add(id(it))
            out.append(it)
            try:
                stack.extend(it.childItems())
            except Exception:  # noqa: BLE001 — not every object is an Item
                pass
        return out

    # A QQuickItem ROOT, not the window. eng.rootObjects()[0] arrives as a plain
    # QWindow, and objects reached through QObject.children() are not typed as
    # items either — so childItems() is unavailable and the visual tree, where a
    # ListView keeps its delegates, cannot be walked at all. findChild gives back
    # a properly typed item to start from.
    from PySide6.QtQuick import QQuickItem
    root_item = win.findChild(QQuickItem)

    def page_of(o):
        for it in visual(o):
            if (it.property("curName") is not None
                    and it.property("tabsModel") is not None):
                return it
        return None

    def tables(o, out=None):
        # a DataTable is the thing with both a row height and a column list
        if out is None:
            out = []
        if o.property("rowHeight") is not None and o.property("columns") is not None:
            out.append(o)
        for c in o.children():
            tables(c, out)
        return out

    pg = page_of(root_item) if root_item is not None else None
    if pg is None:
        bad("the Data page was not found in the window")
        return
    checked, blank = 0, []
    for i in (0, 1, 5, 9, 20):
        pg.setProperty("tabIndex", i)
        for _ in range(8):
            app.processEvents()
        name = pg.property("curName")
        vis = [d for d in tables(pg) if d.property("visible")]
        if not vis:
            blank.append(f"{name}: no visible table")
            continue
        w = max(d.property("width") for d in vis)
        h = max(d.property("height") for d in vis)
        checked += 1
        if w < 200 or h < 200:
            blank.append(f"{name}: {w:.0f}x{h:.0f} px")
    if blank:
        for b in blank:
            bad(f"the table is not drawn — {b}")
    else:
        ok(f"the table fills the page on {checked} tabs")

    # THE SCROLL POSITION MUST SURVIVE A DATA REFRESH. Rows are replaced every
    # few seconds, and replacing a ListView's model puts it back at the top:
    # reading anything below the first screen was impossible, because every ten
    # seconds the table threw you back to row one.
    pg.setProperty("tabIndex", 1)
    for _ in range(8):
        app.processEvents()
    # the widest visible one is the table itself; the narrow hidden one is the
    # grouping panel's
    vis = sorted((d for d in tables(pg) if d.property("visible")),
                 key=lambda d: -d.property("width"))
    dt = vis[0] if vis else None
    lv = next((i for i in visual(dt)
               if i.property("contentY") is not None
               and i.property("cacheBuffer") is not None), None) if dt else None
    if lv is None:
        bad("the table's list was not found, so the scroll cannot be checked")
    else:
        lv.setProperty("contentY", 300.0)
        for _ in range(4):
            app.processEvents()
        QMetaObject.invokeMethod(pg, "loadRows", Qt.DirectConnection)
        for _ in range(10):
            app.processEvents()
        kept = lv.property("contentY")
        if abs(kept - 300.0) > 2:
            bad(f"a refresh moved the scroll from 300 px to {kept:.0f} px")
        else:
            ok("the scroll position survives a data refresh")
        QMetaObject.invokeMethod(dt, "scrollToTop", Qt.DirectConnection)
        for _ in range(4):
            app.processEvents()
        if lv.property("contentY") > 2:
            bad("scrollToTop did not return to the first row")
        else:
            ok("changing the table still starts at its first row")

    # TYPED TEXT THAT LOOKS LIKE A CONDITION IS STILL TEXT. Anything holding
    # = < > or the word LIKE was handed to the database as SQL, so searching for
    # "--flag=value" or "-->" answered "the query failed" — and those are exactly
    # the strings one looks for in a command line or a message. The database
    # decides now: if it refuses the condition, the same text is searched as text.
    pg.setProperty("tabIndex", 0)
    for _ in range(8):
        app.processEvents()
    trouble = []
    for q, must_find in (("--flag=value", False), ("-->", False), ("a>b", False)):
        QMetaObject.invokeMethod(pg, "applyQuery", Qt.DirectConnection,
                                 Q_ARG("QVariant", q))
        for _ in range(8):
            app.processEvents()
        err = str(pg.property("rowsError") or "")
        if err:
            trouble.append(f"searching for {q!r} still fails: {err[:70]}")
    QMetaObject.invokeMethod(pg, "applyQuery", Qt.DirectConnection, Q_ARG("QVariant", ""))
    for _ in range(6):
        app.processEvents()
    # and a REAL condition must still be run as one, not turned into a text search
    QMetaObject.invokeMethod(pg, "applyQuery", Qt.DirectConnection,
                             Q_ARG("QVariant", "1 = 1"))
    for _ in range(8):
        app.processEvents()
    if pg.property("queryNote"):
        trouble.append("a valid condition was demoted to a text search")
    QMetaObject.invokeMethod(pg, "applyQuery", Qt.DirectConnection, Q_ARG("QVariant", ""))
    for _ in range(6):
        app.processEvents()
    for x in trouble:
        bad(x)
    if not trouble:
        ok("text that looks like SQL is searched as text, and real conditions run")

    # THE COUNTER ALTERNATES between how many rows and how full the table is.
    def counters():
        out = []
        for it in visual(pg):
            try:
                s = it.property("text")
            except Exception:  # noqa: BLE001
                continue
            if isinstance(s, str) and it.x() < 400:
                if s.endswith("%") or s.replace(",", "").isdigit():
                    out.append(s)
        return out

    pg.setProperty("showFill", False)
    for _ in range(6):
        app.processEvents()
    rows_shown = counters()
    pg.setProperty("showFill", True)
    for _ in range(8):
        app.processEvents()
    fill_shown = counters()
    pcts = [s for s in fill_shown if s.endswith("%")]
    if not rows_shown:
        bad("the tab list shows no counter at all")
    elif not pcts:
        bad("switching the counter to fill showed no percentage")
    elif rows_shown == fill_shown:
        bad("the counter did not change when switched to fill")
    else:
        ok(f"the tab counter alternates: {len(rows_shown)} counts, "
           f"{len(pcts)} of them become percentages")


def check_bindings():
    """A PROPERTY MUST NOT BE BOTH BOUND AND ASSIGNED. Assigning to a property
    that carries a declarative binding destroys the binding silently, and from
    then on the value only changes where somebody remembered to assign it — which
    is how the Expertise page came to show the previous catalog's rules after the
    Refresh button had been pressed once. The pattern is detectable, so it is
    checked rather than remembered.

    An initial VALUE is not a binding: `property var x: []` or a multi-line object
    literal of constants can be assigned freely. The two are told apart by whether
    the right-hand side refers to anything — after the strings and the object keys
    are removed, a literal has no identifiers left."""
    section("bindings")
    import re as _re

    def rhs_of(src, at):
        """The whole right-hand side, across lines, until the brackets balance."""
        depth, out = 0, []
        for ch in src[at:]:
            if ch == "\n" and depth == 0:
                break
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
            out.append(ch)
        return "".join(out)

    def is_literal(rhs):
        s = _re.sub(r"//[^\n]*", " ", rhs)
        s = _re.sub(r'"[^"]*"|\'[^\']*\'', " ", s)      # strings
        s = _re.sub(r"\b\w+\s*:", " ", s)               # object keys
        s = _re.sub(r"\b(true|false|null|undefined)\b", " ", s)
        s = _re.sub(r"[-\d.]+", " ", s)                  # numbers
        return not _re.search(r"[A-Za-z_]", s)

    found = []
    for f in sorted(pathlib.Path(V1, "ui").rglob("*.qml")):
        src = f.read_text()
        for m in _re.finditer(
                r"^[ \t]*(?:readonly\s+)?property\s+\w+\s+(\w+)\s*:[ \t]*", src, _re.M):
            name = m.group(1)
            rhs = rhs_of(src, m.end())
            if not rhs.strip() or is_literal(rhs):
                continue                       # an initial value, not a binding
            if _re.search(rf"(?<![.\w])(?<!var ){name}\s*=(?!=)", src):
                found.append(f"{f.name}: {name}")
    if found:
        for x in found:
            bad(f"a bound property is also assigned — {x}")
    else:
        ok("no property is both bound and assigned")


def check_paths(backend):
    section("paths")
    from PySide6.QtGui import QGuiApplication
    from PySide6.QtQml import QQmlApplicationEngine
    from PySide6.QtCore import QUrl, QMetaObject, Qt, Q_ARG
    import PySide6.QtCore as C

    warn: list[str] = []
    # "Detected anchors on an item that is managed by a layout" belongs here: it
    # is how Qt reports the mistake that left every table in Data at zero size —
    # the page still compiled, still had its rows, and drew nothing.
    C.qInstallMessageHandler(lambda m, c, t: warn.append(t) if any(
        k in t for k in ("ReferenceError", "TypeError", "Unable to assign",
                         "is not a function", "Cannot read",
                         "Detected anchors", "managed by a layout",
                         "Binding loop")) else None)
    app = QGuiApplication.instance() or QGuiApplication(sys.argv)
    eng = QQmlApplicationEngine()
    eng.rootContext().setContextProperty("backend", backend)
    eng.addImportPath(f"{V1}/ui")
    eng.load(QUrl.fromLocalFile(f"{V1}/ui/Main.qml"))
    if not eng.rootObjects():
        bad("Main.qml did not load")
        return
    win = eng.rootObjects()[0]
    win.resize(1400, 850)

    def find(r, n):
        if r.objectName() == n:
            return r
        for c in r.children():
            x = find(c, n)
            if x is not None:
                return x

    def prop(o, n):
        v = o.property(n)
        return v.toVariant() if hasattr(v, "toVariant") else v

    def pump(n=6):
        # SIX TURNS, NOT THREE. The query bar re-asserts its selection through
        # Qt.callLater — deliberately, because the bindings it derives from
        # re-evaluate after the handler returns — so a reader in the same turn
        # can still see the PREVIOUS table's columns and report a mismatch that
        # does not exist. Caught as a test that failed once and then passed.
        for _ in range(n):
            app.processEvents()

    QMetaObject.invokeMethod(win, "open", Qt.DirectConnection,
                             Q_ARG("QVariant", "state"))
    pump()
    page, qbar = find(win, "statePage"), find(win, "queryBar")
    if page is None or qbar is None:
        bad("Data page or query bar not found")
        return
    tabs = [t["name"] for t in prop(page, "tabsModel")]
    per_tab_fail = 0
    for i, name in enumerate(tabs):
        page.setProperty("tabIndex", i)
        pump()
        issues = []
        vis = prop(page, "visibleCols") or []
        sel = (prop(qbar, "spec") or {}).get("select", [])
        foreign = sorted(set(sel) - set(prop(page, "listCols") or []))
        if foreign:
            issues.append(f"SELECT holds columns this table does not have: {foreign[:4]}")
        if sorted(sel) != sorted(vis):
            issues.append(f"SELECT ({len(sel)}) is not what the table shows ({len(vis)})")
        # free-text search
        qbar.setProperty("quickText", "zoom")
        QMetaObject.invokeMethod(qbar, "apply", Qt.DirectConnection)
        pump()
        if prop(page, "rowsError"):
            issues.append(f"free-text search: {prop(page, 'rowsError')[:80]}")
        qbar.setProperty("quickText", "")
        QMetaObject.invokeMethod(qbar, "clearAll", Qt.DirectConnection)
        QMetaObject.invokeMethod(qbar, "apply", Qt.DirectConnection)
        pump()
        if vis:
            col = vis[0]
            QMetaObject.invokeMethod(qbar, "addCondition", Qt.DirectConnection,
                                     Q_ARG("QVariant", col),
                                     Q_ARG("QVariant", "MATCH"),
                                     Q_ARG("QVariant", "a"))
            QMetaObject.invokeMethod(qbar, "apply", Qt.DirectConnection)
            pump()
            if prop(page, "rowsError"):
                issues.append(f"condition on {col}: {prop(page, 'rowsError')[:70]}")
            QMetaObject.invokeMethod(qbar, "clearAll", Qt.DirectConnection)
            QMetaObject.invokeMethod(qbar, "apply", Qt.DirectConnection)
            pump()
            QMetaObject.invokeMethod(page, "toggleSort", Qt.DirectConnection,
                                     Q_ARG("QVariant", col))
            pump()
            if prop(page, "rowsError"):
                issues.append(f"sort by {col}: {prop(page, 'rowsError')[:70]}")
            page.setProperty("groupBy", [col])
            QMetaObject.invokeMethod(page, "reloadGroups", Qt.DirectConnection)
            pump()
            if prop(page, "groupError"):
                issues.append(f"group by {col}: {prop(page, 'groupError')[:70]}")
            page.setProperty("groupBy", [])
            pump(2)
        if issues:
            per_tab_fail += 1
            for m in issues:
                bad(f"{name}: {m}")
    if not per_tab_fail:
        ok(f"all paths work on all {len(tabs)} tabs")
    else:
        print(f"        ({per_tab_fail} of {len(tabs)} tabs have a failing path)")
    if warn:
        for w in dict.fromkeys(warn)[:6] if isinstance(warn, dict) else list(dict.fromkeys(warn))[:6]:
            bad(f"qml runtime: {w[:140]}")
    else:
        ok("no qml runtime warnings")


def main() -> int:
    check_compile()
    from backend import Backend
    try:
        be = Backend()
    except Exception as e:  # noqa: BLE001
        bad(f"backend would not start: {e}")
        print(f"\n{len(FAIL)} failures")
        return len(FAIL)
    # WHICH CHECKS CAN RUN DEPENDS ON WHO OWNS THE DATABASES. Collecting,
    # normalizing and breaking a rule on purpose are WRITES, and there is exactly
    # one writer — so when the application is already running, this process is a
    # follower and those sections cannot run here. The read-side checks still can,
    # through the same socket the interface uses, and which ones were skipped is
    # said out loud rather than quietly passing a shorter suite.
    try:
        check_sql_guard()
        check_ssh_parsing()
        check_bindings()
        check_layout(be)
        if be.owner:
            check_engine(be.store)
            check_duplicates(be.store)
            check_clock(be.store)
            check_orphans(be.store)
            check_entry_points(be.store)
            check_contract(be.store)
            check_rule_tests(be.store)
            check_data(be.store)
            check_reads(be)
            check_events(be.events)
            check_errors(be)
            check_ingest_visible(be)
            check_compaction(be)
            check_provenance(be)
            check_engine_visible(be)
            check_concurrency(be)
        else:
            section("follower")
            ok(f"the databases are owned by pid {getattr(be, '_owner_pid', '?')};"
               " reading through its service")
            print("  --    skipped (they write, and the owner is the only writer):"
                  " engine, data, events, errors, ingest")
            check_duplicates(be.store)
            check_clock(be.store)
            check_orphans(be.store)
            check_entry_points(be.store)
            check_contract(be.store)
            check_rule_tests(be.store)
            check_reads(be)
        check_paths(be)
    finally:
        be.events.close()
        be.store.close()
    print(f"\n{'PASS' if not FAIL else str(len(FAIL)) + ' FAILURES'}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())

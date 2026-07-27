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
    st = pipeline.run_all(store, force=True)
    el = time.perf_counter() - t
    failed = [x for x in st["inputs"] if x["error"]]
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
    left = glob.glob("/tmp/lisin-osq-*.json") + glob.glob("/tmp/lisin-cmd-*.tsv")
    if left:
        bad(f"{len(left)} temp files left behind by the collector")
    else:
        ok("no temp files left behind")


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

    # 4. the file must not carry the deleted pages
    import os as _os
    size = _os.path.getsize(events.path) / 1048576
    per = size * 1048576 / max(hist2, 1)
    if per > 1500:
        bad(f"{size:.0f} MB for {hist2:,} events = {per:.0f} bytes each — the raw"
            f" copy is being kept as well as the normalized one")
    else:
        ok(f"{size:.0f} MB on disk, {per:.0f} bytes per event")


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


def check_paths(backend):
    section("paths")
    from PySide6.QtGui import QGuiApplication
    from PySide6.QtQml import QQmlApplicationEngine
    from PySide6.QtCore import QUrl, QMetaObject, Qt, Q_ARG
    import PySide6.QtCore as C

    warn: list[str] = []
    C.qInstallMessageHandler(lambda m, c, t: warn.append(t) if any(
        k in t for k in ("ReferenceError", "TypeError", "Unable to assign",
                         "is not a function", "Cannot read")) else None)
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

    def pump(n=3):
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
    try:
        check_engine(be.store)
        check_data(be.store)
        check_events(be.events)
        check_errors(be)
        check_paths(be)
    finally:
        be.events.close()
        be.store.close()
    print(f"\n{'PASS' if not FAIL else str(len(FAIL)) + ' FAILURES'}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())

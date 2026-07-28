"""Qt <-> v1 core bridge.

Exposes the slots the QML expects — the stateReady(snapshot) signal and the
Data / Events / Dashboard / Expertise slots — serving everything from the
DuckDB stores (state + events) rather than reading anything live.

Shapes:
  snapshot   : {os, tabs:[{name,title,icon,builtin,columns,count,colcfg,
               collected_at}], collected_at}
  tableRows  : {rows, total, columns, error}   (each row stamped with _id)

The SQL/DuckDB plumbing (identifier quoting, YAML loading, view application) is
shared from core/db.py; this file is the Qt boundary and the view-models.
"""
from __future__ import annotations

import datetime
import json
import os
import platform
import re
import threading
import time
from pathlib import Path

import yaml
from PySide6.QtCore import QObject, Signal, Slot

from core import eventstore, pipeline, remote, ruletest, service, views
from core.db import data_dir, ident, load_yaml_dir, select_only
from core.eventstore import EventStore
from core.store import Store
from core.tetragon_reader import TetragonReader

_SQL_HISTORY = data_dir() / "sql_history.json"
_EXPERTISE = Path(__file__).resolve().parent / "expertise"
_QUERIES_DIR = _EXPERTISE / "queries"
_EXP_CATS = [("inputs", "Inputs"), ("events", "Normalization"),
             ("taxonomy", "Taxonomy"), ("views", "Enrichment"),
             ("edges", "Edges"), ("queries", "Queries")]

# The Events tab's default view: the curated columns shown first (the rest of the
# taxonomy stays available in the Columns picker), and the noisier ones hidden by
# default. This lives with the backend so the Events tab is served exactly like
# every other tab — StatePage no longer fabricates it.
_EVENTS_COLUMNS = ["ts", "event_kind", "event_action", "event_category",
                   "event_outcome", "subject_name", "process_name", "process_pid",
                   "process_args", "parent_name", "object_type", "object_name",
                   "host", "message"]
_EVENTS_HIDDEN = ["event_category", "event_outcome", "process_pid",
                  "process_args", "object_type", "host"]


def _san_name(name: str) -> str:
    s = re.sub(r"[^0-9A-Za-z_Ѐ-ӿ-]+", "_", str(name).strip()).strip("_")
    return s or "query"


# A grouping term that STARTS with an aggregate call is a measure, not a key.
# The list is SQL's own aggregate vocabulary (plus DuckDB's), not a choice about
# this machine's data.
_AGGREGATE = re.compile(
    r"^\s*(sum|avg|mean|min|max|count|median|mode|stddev\w*|var\w*|product|"
    r"string_agg|list|array_agg|any_value|first|last|quantile\w*|approx\w*|"
    r"bit_and|bit_or|bit_xor|bool_and|bool_or|histogram|entropy)\s*\(",
    re.I,
)


def _iso_now() -> str:
    return datetime.datetime.now().replace(microsecond=0).isoformat(sep=" ")


def _fmt_elapsed(sec: int) -> str:
    """Human process age: '3d 4h', '5h 12m', '8m', '40s'."""
    if sec <= 0:
        return ""
    d, rem = divmod(sec, 86400)
    h, rem = divmod(rem, 3600)
    m, _s = divmod(rem, 60)
    if d:
        return f"{d}d {h}h"
    if h:
        return f"{h}h {m}m"
    if m:
        return f"{m}m"
    return f"{sec}s"


def _num(v) -> int:
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return 0


class Backend(QObject):
    stateReady = Signal("QVariant")

    def __init__(self):
        super().__init__()
        # ONE PROCESS OWNS THE DATABASES; ANYONE ELSE ASKS IT.
        # DuckDB takes an exclusive lock on a file: measured here, a second
        # process cannot open it even read-only while a writer holds it. So the
        # first instance to start owns both stores, collects, and serves reads on
        # a Unix socket; a later instance (a second window, the test suite, a
        # script) finds the socket and reads through it. Both are the same
        # application — the difference is only who does the writing.
        self.owner = True
        self.service = None
        try:
            self.store = Store()
            self.events = EventStore()
        except Exception as own_err:      # noqa: BLE001 — someone owns the file
            info = remote.probe()
            if not info:
                raise                      # locked, and nobody answering: real
            self.owner = False
            self.store = remote.RemoteDB("state")
            self.events = remote.RemoteDB("events")
            self._owner_pid = info.get("pid")
            self._own_error = str(own_err).splitlines()[0]
        self.reader = TetragonReader()
        self._events_at = ""
        self._collected_at: dict[str, str] = {}
        # per-table (columns, count) cache + the collection generation it is for
        self._tab_cache: dict[str, tuple] = {}
        self._gen = 0
        # last outcome per source: {table: {error, at, rows}} — read by the
        # Pipelines page, so a broken source is visible instead of silent
        self._status: dict[str, dict] = {}
        # Bumped by every status write. The flow list is cached against the
        # collection generation, and a failure can appear BETWEEN collections
        # (the event ingest runs on its own thread) — without this, a stopped
        # stream stayed invisible until the next source happened to collect.
        self._status_rev = 0
        self._fill: dict[str, float] = {}   # share of cells that hold a value
        self._fill_gen = -1
        self._cycle: dict = {}        # what the last collection cycle cost
        self._compacted: dict = {}    # what the last file rewrite reclaimed
        self._engine_cache: tuple = (0.0, {})
        self._flows_cache = None      # pipelineFlows is expensive to build
        self._flows_gen = (-1, -1)
        self._meta = self._load_meta()
        if self.owner:
            self.events.apply_views()
            self.service = service.QueryService(
                {"state": self.store, "events": self.events},
                hooks={"apply_event_views": self.events.apply_views,
                       "agent_state": self._agent_state},
            )
            self.service.start()
            if not os.environ.get("LISIN_NO_COLLECT"):
                threading.Thread(target=self._scheduler, daemon=True).start()
                threading.Thread(target=self._event_loop, daemon=True).start()
        else:
            # Not collecting — the owner does that. Following instead: the
            # owner's generation and per-source outcomes are polled, so this
            # window shows the same failures and the same timestamps rather
            # than an empty Pipelines page.
            threading.Thread(target=self._follow, daemon=True).start()

    # ---------- what the owner tells a follower ----------
    def _agent_state(self) -> dict:
        return {"gen": self._gen, "status_rev": self._status_rev,
                "status": self._status, "collected_at": self._collected_at,
                "events_at": self._events_at}

    def _follow(self):
        """A follower's whole loop: ask the owner what changed, redraw if so."""
        seen, misses = None, 0
        while True:
            try:
                st = self.store.hook("agent_state")
                key = (st.get("gen"), st.get("status_rev"), st.get("events_at"))
                if key != seen:
                    seen = key
                    self._gen = int(st.get("gen") or 0)
                    self._status = dict(st.get("status") or {})
                    self._collected_at = dict(st.get("collected_at") or {})
                    self._events_at = str(st.get("events_at") or "")
                    self._status_rev += 1
                    self._push_state()
            except Exception as e:  # noqa: BLE001
                # One miss is normal: the owner may be mid-restart. A run of them
                # is not — this window would go on showing an hour-old snapshot as
                # if it were current, which is the exact failure this project
                # keeps finding. Said out loud after half a minute of silence.
                misses += 1
                if misses == 15:
                    self._set_status(
                        "_agent", "no answer from the agent that owns the "
                        f"databases ({str(e).splitlines()[0]}) — what is shown "
                        "is the last state it reported")
            else:
                if misses:
                    misses = 0
                    self._clear_status("_agent")
            time.sleep(2)

    # ---------- metadata (table -> title/icon, from the YAML rules) ----------
    def _load_meta(self) -> dict:
        # `columns:` in a rule is the author saying WHICH FIELDS MATTER for that
        # table (the rest stay one click away); without it the engine measures
        # which columns are empty and hides those.
        m = {}
        for inp in pipeline.load_inputs():
            t = inp.get("table") or inp.get("name")
            # WHERE A TABLE COMES FROM travels with it, so the page showing the
            # rows can say which rule produced them, how it reads the machine and
            # how often — instead of the rows arriving from nowhere.
            m[t] = {"title": inp.get("title", t), "icon": inp.get("icon", "table"),
                    "hidden": bool(inp.get("hidden")),
                    "columns": inp.get("columns") or [],
                    "priority": inp.get("priority"),
                    "rule": inp.get("name", t),
                    "ref": "inputs/" + str(inp.get("name", t)),
                    "how": ("a command" if str(inp.get("kind", "")) == "command"
                            else "the Tetragon stream"
                            if str(inp.get("kind", "")) == "tetragon"
                            else "an osquery query"),
                    "interval": inp.get("interval", pipeline.DEFAULT_INTERVAL),
                    "tests": bool(inp.get("tests")),
                    "enabled": inp.get("enabled") is not False}
        for v in views.load_views():
            n = v.get("name")
            m[n] = {"title": v.get("title", n), "icon": v.get("icon", "table"),
                    "hidden": bool(v.get("hidden")),
                    "columns": v.get("columns") or [],
                    "priority": v.get("priority"),
                    "rule": n,
                    "ref": "views/" + str(n),
                    "how": "a SQL view over other tables",
                    "interval": 0,
                    "tests": bool(v.get("tests")),
                    "enabled": True}
        return m

    # ---------- collection ----------
    def _scheduler(self):
        # hand over whatever the database already holds at once, then collect.
        # The tick is short; WHAT runs is decided per input by its own interval
        # (pipeline._due), so a fast source stays fresh without dragging every
        # slow inventory source along with it.
        pipeline.sweep_temp()      # leftovers from a previous run, if it was killed
        self._push_state()
        # measure every table ONCE at startup: an hourly source would otherwise
        # have no fill figure for an hour, and a blank number reads as zero
        for _t in self.store.tables():
            if not _t.startswith("_"):
                self._measure_fill(_t)
        self._push_state()
        cycles = 0
        while True:
            self._run_all()
            cycles += 1
            if cycles % self.COMPACT_EVERY == 0:
                self._maybe_compact()
            time.sleep(5)

    def _set_status(self, key: str, error: str = "", rows: int = 0,
                    at: str = "") -> None:
        """The ONE place a source's outcome is recorded. Everything the interface
        says about what is working goes through here, so nothing can be changed
        without the pages that draw it being told."""
        self._status[key] = {"error": error, "at": at or _iso_now(), "rows": rows}
        self._status_rev += 1

    def _clear_status(self, key: str) -> None:
        if self._status.pop(key, None) is not None:
            self._status_rev += 1

    # how many collection cycles between checks for a wasteful database file
    COMPACT_EVERY = 600            # the scheduler ticks every 5 s -> ~50 minutes

    def _maybe_compact(self):
        """Rewrite a database file that is mostly free space. DuckDB never gives
        freed blocks back: retention deletes rows and the file only grows —
        measured here, the event store was 163 MB holding 93 MB of events. The
        rewrite is atomic (see DuckDB.compact) and takes about a second, and the
        outcome is recorded like any other source so a file that stopped shrinking
        is visible rather than just large."""
        for name, db in (("state", self.store), ("events", self.events)):
            try:
                r = db.compact()
                if r.get("compacted"):
                    self._compacted[name] = dict(r, at=_iso_now())
                    self._set_status(
                        "_compact_" + name,
                        f"reclaimed {r['freed_mb']} MB from the {name} database "
                        f"({r['before_mb']} -> {r['after_mb']} MB) in "
                        f"{r['seconds']} s")
                elif r.get("error"):
                    self._set_status("_compact_" + name,
                                     f"could not compact {name}: {r['error']}")
            except Exception as e:  # noqa: BLE001
                self._set_status("_compact_" + name, str(e).splitlines()[0])

    def _run_all(self, force: bool = False):
        ran = []
        _t0 = time.perf_counter()
        try:
            # NB: no lock here — run_all takes the store lock itself, only around
            # the writes. Holding it across the osquery subprocesses froze the UI
            # (every read slot goes through the same lock) for a whole cycle.
            st = pipeline.run_all(self.store, force=force)
            ran = st.get("inputs", [])
            if ran:
                now = _iso_now()
                self._gen += 1      # invalidates the per-table columns/count cache
                for x in ran:
                    # A FAILING SOURCE MUST BE VISIBLE. It used to be swallowed
                    # here, and a broken input then looked exactly like a table
                    # nobody had touched in a while — the worst kind of silence in
                    # a tool whose whole job is to tell you what is on the machine.
                    if x.get("error"):
                        self._set_status(x["table"], x["error"], at=now)
                    else:
                        self._collected_at[x["table"]] = now
                        self._set_status(x["table"], rows=x.get("rows", 0), at=now)
                        self._measure_fill(x["table"])
            for v in st.get("derive", {}).get("views", []):
                if v.get("error"):
                    self._set_status(v["view"], v["error"])
                elif v.get("view"):
                    # a derivation is filled by the same cycle, so it is measured
                    # by it too — otherwise the four view tabs are the only ones
                    # with no number, which reads as "not measurable"
                    self._measure_fill(v["view"])
        except Exception as e:  # noqa: BLE001
            self._set_status("_collector", str(e))
        if ran:
            # kept so the interface can say what a cycle COSTS, rather than the
            # user having to guess from how the window feels
            self._cycle = {"seconds": round(time.perf_counter() - _t0, 1),
                           "sources": len(ran),
                           "failing": sum(1 for x in ran if x.get("error")),
                           "at": _iso_now()}
        # the tick is every few seconds but most of them collect nothing (each
        # input has its own interval) — pushing a snapshot then would just make
        # every open page re-read for no new data.
        if ran or force:
            self._push_state()

    def _measure_fill(self, table: str) -> None:
        """HOW FULL A TABLE IS — the share of its cells that hold a value.

        A source that keeps returning its rows while one of its columns has gone
        empty looks perfectly healthy by row count alone: that is exactly how the
        browser tab sat at a tenth of the machine's extensions, and how four
        storage columns stayed blank for weeks. The row count answers "did it
        collect"; this answers "did it collect anything".

        Measured HERE, on the collector's thread and only for the table that was
        just rewritten — which is also the only moment the answer can change.
        Doing it while building a snapshot cost 1.9 s on the thread that draws the
        window."""
        try:
            cols = self.store.columns(table)
            rows = self.store.row_count(table)
            filled = self._filled(table, cols)
            cells = rows * len(filled)
            share = round(sum(filled) / cells, 3) if cells else None
            self._fill[table] = share
            # KEPT IN THE DATABASE, not only in this process: a second window
            # collects nothing, and a window that has just started has not
            # collected the hourly sources yet — both would show no number at all
            # while the first one shows it, which is a difference nobody can
            # explain. Stored where every reader can see it.
            if share is not None:
                with self.store._lock:
                    # `at` is a reserved word in DuckDB (AT TIME ZONE) — the same
                    # trap as the column named `load`, and the same lesson: an
                    # identifier gets quoted or gets a name that is not a keyword.
                    self.store._con.execute(
                        'CREATE TABLE IF NOT EXISTS _fill ('
                        '  "name" VARCHAR PRIMARY KEY, "share" DOUBLE,'
                        '  "measured_at" VARCHAR)')
                    self.store._con.execute('DELETE FROM _fill WHERE "name" = ?',
                                            [table])
                    self.store._con.execute("INSERT INTO _fill VALUES (?, ?, ?)",
                                            [table, share, _iso_now()])
        except Exception:  # noqa: BLE001 — a measurement must never break a run
            self._fill.pop(table, None)

    def _push_state(self):
        try:
            self.stateReady.emit(self._snapshot())
        except RuntimeError:
            pass  # the window is gone

    # ---------- event ingestion (Tetragon log tail -> raw -> normalize view) ----------
    def _event_loop(self):
        cycles = 0
        while True:
            # the counter advances even when a cycle fails — it used to sit inside
            # the try, so one failing materialize() (a broken normalization rule)
            # meant prune() never ran again and the raw table grew without bound.
            cycles += 1
            try:
                lines = self.reader.read_new()
                if lines:
                    self.events.append(lines)
                    self._events_at = _iso_now()
                # normalize new raw rows into the queryable `events` table (cheap
                # when caught up; a one-time backlog fill on the first run)
                filled = self.events.materialize()
                if lines or filled:
                    self._push_state()  # refresh the Events tab count
                if cycles % 20 == 0:    # the stream's own fill, now and then
                    try:
                        cols = [c for c in self.events.columns("events")
                                if c != "seq"]
                        n = self.events.row_count("events")
                        parts = ", ".join(
                            f"sum(CASE WHEN {ident(c)} IS NULL OR "
                            f"CAST({ident(c)} AS VARCHAR) = '' THEN 0 ELSE 1 END)"
                            for c in cols)
                        vals = self.events.fetch(
                            f"SELECT {parts} FROM events")["rows"][0]
                        cells = n * len(cols)
                        self._fill["events"] = (round(sum(int(v or 0) for v in vals)
                                                      / cells, 3) if cells else None)
                    except Exception:  # noqa: BLE001
                        pass
                if self.reader.cursor_error:
                    self._set_status("_events", self.reader.cursor_error)
                else:
                    self._clear_status("_events")
            except Exception as e:  # noqa: BLE001
                # A STOPPED INGEST MUST BE VISIBLE, for the same reason a failing
                # source is. This was `pass`, and it hid a real one: normalizing a
                # batch hit the memory cap, every later cycle threw on the same
                # backlog, and the interface went on showing the events collected
                # before that — a stream that had stopped hours ago looked exactly
                # like a quiet machine. Recorded like any other source, drawn on
                # the Pipelines page with the time it happened.
                self._set_status("_events", str(e).splitlines()[0])
            try:
                if cycles % 20 == 0:  # ~every 60 s: bound the stream
                    self.events.prune()
                    self._clear_status("_retention")
            except Exception as e:  # noqa: BLE001
                # retention failing is not visible in the interface at all — the
                # events keep arriving, the file just grows until the disk is full
                self._set_status("_retention",
                                 "retention: " + str(e).splitlines()[0])
            time.sleep(3)

    def _events_tab(self) -> dict:
        """The Events tab, served like any other tab (uniform ownership). Its
        count/freshness come from the live event store; the curated column set is
        the default view (the full taxonomy is still offered in the picker)."""
        cnt, cols = 0, []
        try:
            cnt = self.events.fetch("SELECT count(*) FROM events")["rows"][0][0]
            cols = [c for c in self.events.columns("events") if c != "seq"]
        except Exception:  # noqa: BLE001 — an empty/absent stream is not an error
            pass
        # THE COLUMNS ARE THE TABLE'S REAL COLUMNS (so a field picker only ever
        # offers something that exists); the curated set is what is SHOWN by
        # default — everything else starts hidden and is one click away.
        if not cols:
            cols = list(_EVENTS_COLUMNS)
        shown = [c for c in _EVENTS_COLUMNS if c in cols]
        hidden = [c for c in cols if c not in shown]
        est = self._status.get("_events") or {}
        return {
            "name": "events", "title": "Events", "icon": "view-calendar-list",
            "builtin": True, "priority": 10,   # the stream comes first
            # the stream accounts for itself like every other table does
            "source": {"rule": "events/normalize", "ref": "events/normalize",
                       "how": "the Tetragon eBPF stream, normalized by a SQL view",
                       "interval": 0, "tests": True, "enabled": True,
                       "error": est.get("error", ""),
                       "error_at": est.get("at", "")},
            # curated first, then the rest — the default order reads as a phrase
            "columns": shown + hidden,
            "count": cnt, "collected_at": self._events_at,
            "fill": self._fill.get("events"),
            "colcfg": {"hidden": hidden},
        }

    def _cached_count(self, name: str, tables) -> int:
        """Row count from the snapshot cache when it has one. Counting a view
        means running it, and one of ours is a recursive graph query."""
        if name not in tables:
            return 0
        c = self._tab_cache.get(name)
        if c is not None:
            return c[2]
        try:
            return self.store.row_count(name)
        except Exception:  # noqa: BLE001
            return 0

    def _filled(self, table: str, cols: list[str]) -> list[int]:
        """How many rows hold a value, per column — ONE query, used for two
        answers: which columns are empty in every row (they start hidden), and how
        full the table is overall. Both were worth a query; neither is worth two."""
        if not cols or cols == ["empty"]:
            return []
        parts = ", ".join(
            f"sum(CASE WHEN {ident(c)} IS NULL OR CAST({ident(c)} AS VARCHAR) = ''"
            f" THEN 0 ELSE 1 END)"
            for c in cols
        )
        try:
            vals = self.store.fetch(f"SELECT {parts} FROM {ident(table)}")["rows"][0]
        except Exception:  # noqa: BLE001
            return []
        return [int(v or 0) for v in vals]

    def _dead_columns(self, table: str, cols: list[str]) -> list[str]:
        """Columns that hold NO value at all in this table, right now.

        A column that is empty in every row is noise in a table view — it costs a
        column of width and tells the reader nothing. Rather than curate a list of
        "interesting" fields by hand (which would go stale the moment a source
        changes), the emptiness is MEASURED and those columns start hidden; they
        are one click away in the Columns panel, and they appear by themselves as
        soon as they carry data. One query per table, cached per collection."""
        vals = self._filled(table, cols)
        return [c for c, v in zip(cols, vals) if not v]

    # ---------- snapshot ----------
    def _snapshot(self) -> dict:
        # A SNAPSHOT IS SENT EVERY FEW SECONDS, so it must be cheap. Counting rows
        # per table meant re-running count(*) on every table on every push — and
        # for a view (ports_owned) that re-executes its JOIN. Both the count and
        # the column list only change when the table is rewritten, so they are
        # cached and refreshed only when the collection timestamp moved.
        # what the collector measured, from wherever it is running
        if self._fill_gen != self._gen:
            try:
                for n, s in self.store.fetch(
                        "SELECT name, share FROM _fill")["rows"]:
                    self._fill.setdefault(str(n), s)
                    if not self.owner:      # a follower has no measurements of its own
                        self._fill[str(n)] = s
            except Exception:  # noqa: BLE001 — the table appears with the first run
                pass
            self._fill_gen = self._gen
        tabs = []
        for name in self.store.tables():
            if name.startswith("_"):
                continue
            meta = self._meta.get(name, {})
            if meta.get("hidden"):  # e.g. the plain listening_ports, superseded
                continue            # by the ports_owned view (with the owner)
            # Keyed by THIS TABLE's collection stamp so one source being
            # re-collected does not invalidate the other thirty-five; a
            # derived view has no stamp of its own, so it follows the
            # generation instead.
            stamp = self._collected_at.get(name, "")
            key = stamp or f"gen{self._gen}"
            cached = self._tab_cache.get(name)
            if cached is None or cached[0] != key:
                cols = self.store.columns(name)
                rows_n = self.store.row_count(name)
                # what the rule itself declares comes first; otherwise the
                # columns that are empty in every row start hidden
                declared = meta.get("columns") or []
                if declared:
                    hidden = [c for c in cols if c not in declared]
                    # the rule's order IS the order — it says what to read
                    # first; without passing it as the order the UI would
                    # re-sort by its own name heuristic and put `path` ahead
                    # of `pid`.
                    cols = [c for c in declared if c in cols] + hidden
                    order = list(cols)
                else:
                    hidden = self._dead_columns(name, cols)
                    order = []
                cached = (key, cols, rows_n, hidden, order)
                self._tab_cache[name] = cached
            st = self._status.get(name, {})
            tabs.append({
                "source": {"rule": meta.get("rule", name),
                           "ref": meta.get("ref", ""),
                           "how": meta.get("how", ""),
                           "interval": meta.get("interval", 0),
                           "tests": bool(meta.get("tests")),
                           "enabled": meta.get("enabled", True),
                           "error": st.get("error", ""),
                           "error_at": st.get("at", "")},
                "name": name,
                "title": meta.get("title", name),
                "icon": meta.get("icon", "table"),
                "priority": meta.get("priority"),
                "builtin": True,
                "columns": cached[1],
                "count": cached[2],
                # MEASURED BY THE COLLECTOR, not here: a snapshot is sent every few
                # seconds and scanning every column of every table cost 1.9 s on
                # the thread that draws the window. The collector measures a table
                # right after it fills it, which is also the only moment the answer
                # can change.
                "fill": self._fill.get(name),
                "colcfg": {"hidden": cached[3], "order": cached[4]},
                "collected_at": stamp,
            })
        # the Events tab is served here like every other tab (StatePage sorts it
        # first via its priority map); its rows come from the event store.
        tabs.append(self._events_tab())
        last = max(self._collected_at.values(), default="")
        # `gen` counts COLLECTIONS of state. A page can then tell "new events
        # arrived" (gen unchanged) from "my table was rewritten" (gen moved) and
        # skip re-reading rows that cannot have changed.
        return {"os": self._os_info(), "tabs": tabs, "collected_at": last,
                "gen": self._gen}

    def _os_info(self) -> dict:
        return {
            "pretty": platform.platform(),
            "kernel": platform.release(),
            "host": platform.node(),
        }

    # ---------- slots the Data tab calls ----------
    @Slot()
    def reload(self):
        self._push_state()

    @Slot(str, str, str, int, int, result="QVariant")
    def tableRows(self, name, where="", order="", limit=0, offset=0):
        """One page of a table/view. `events` comes from the event store (rows
        keyed by the stable seq, newest first); every other table from the state
        store (keyed by page offset)."""
        if name == "events":
            return self._rows(self.events, "events", where, order, limit, offset,
                              default_order="seq DESC", id_col="seq")
        if name not in self.store.tables():
            return {"rows": [], "total": 0, "columns": [], "error": "unknown table"}
        return self._rows(self.store, name, where, order, limit, offset)

    def _rows(self, target, table, where, order, limit, offset,
              default_order="", id_col=None):
        """Shared table-page reader for both stores: count + a SELECT window, each
        row turned into a QML-friendly dict with a stable _id."""
        wh = f" WHERE {where}" if where else ""
        order = order or default_order
        try:
            total = target.fetch(
                f"SELECT count(*) FROM {ident(table)}{wh}")["rows"][0][0]
            sql = f"SELECT * FROM {ident(table)}{wh}"
            if order:
                sql += f" ORDER BY {order}"
            if limit and int(limit) > 0:
                sql += f" LIMIT {int(limit)} OFFSET {int(offset)}"
            # the read cap must follow the page size, or a page silently comes
            # back short while the footer still reports the true total
            cap = int(limit) if limit and int(limit) > 0 else 5000
            cols, rows, truncated = target.query(sql, max_rows=cap)
            base = int(offset) if (limit and int(limit) > 0) else 0
            objs = []
            for i, r in enumerate(rows):
                # a datetime / typed value cannot cross to QML (it arrives as
                # "QVariant(PyObject)") — stringify anything not already a
                # primitive. _id is a stable per-row key (seq) or the offset.
                o = {c: (v if v is None or isinstance(v, (str, int, float, bool))
                         else str(v))
                     for c, v in zip(cols, r)}
                o["_id"] = (str(o[id_col]) if id_col and id_col in o
                            else str(base + i))
                objs.append(o)
            return {"rows": objs, "total": total, "columns": cols,
                    "truncated": truncated, "error": ""}
        except Exception as e:  # noqa: BLE001
            return {"rows": [], "total": 0, "columns": [],
                    "truncated": False, "error": str(e)}

    @Slot(result="QVariant")
    def eventTaxonomy(self):
        f = _EXPERTISE / "taxonomy" / "events.yaml"
        try:
            d = yaml.safe_load(f.read_text()) or {}
        except Exception:
            return {"names": [], "groups": []}
        groups = d.get("groups", [])
        names = [fld for g in groups for fld in g.get("fields", [])]
        return {"names": names, "groups": groups}

    @Slot(str, str, str, result="QVariant")
    def stateGroups(self, table, fields_json, where=""):
        """Distinct value groups with counts, for the group panel.

        A term is either a COLUMN NAME or an EXPRESSION (`substr(path,1,12)`,
        `date_trunc('hour', ts)`): grouping "by the hour" or "by the first path
        segment" is a normal thing to want and is not expressible as a bare
        column. The terms arrive as a JSON array, because an expression contains
        commas and a comma-separated string would split it in the middle.

        A column name is quoted as an identifier; an expression is passed through
        after the same SELECT-only guard the views use — it is going into the same
        SQL text the user can already type in the query bar."""
        try:
            fields = [str(f).strip() for f in json.loads(fields_json or "[]")]
        except Exception:  # noqa: BLE001 — tolerate the old comma-joined form
            fields = [f.strip() for f in str(fields_json or "").split(",")]
        fields = [f for f in fields if f]
        if not fields:
            return {"rows": []}
        # A TERM IS EITHER A KEY OR A MEASURE, exactly as in SQL. `kind` groups the
        # rows; `sum(own_mb)` measures each group. Typing an aggregate used to be
        # treated as a key — which is not valid SQL and produced nothing — so it is
        # classified here instead: an aggregate call becomes a column of the group
        # panel, everything else becomes a GROUP BY key.
        keys, key_labels, measures = [], [], []
        for f in fields:
            if re.fullmatch(r"[A-Za-z0-9_]+", f):
                keys.append(ident(f))        # SQL text: quoted identifier
                key_labels.append(f)         # what the user typed, for the header
                continue
            if not select_only("SELECT " + f):
                return {"rows": [], "error": f"not a valid term: {f}"}
            if _AGGREGATE.match(f):
                measures.append(f)
            else:
                keys.append(f)
                key_labels.append(f)
        # events group over the event store; everything else over the state store
        target = self.events if table == "events" else self.store
        if table != "events" and table not in self.store.tables():
            return {"rows": []}
        wh = f" WHERE {where}" if where else ""
        cols = keys + ["count(*)"] + measures
        sel = ", ".join(cols)
        grp = f" GROUP BY {', '.join(keys)}" if keys else ""
        # order by the FIRST measure when there is one (the interesting groups
        # are the heavy ones, not the numerous ones), else by the count
        order = f"{measures[0]} DESC" if measures else "count(*) DESC"
        try:
            rows = target.fetch(
                f"SELECT {sel} FROM {ident(table)}{wh}{grp} "
                f"ORDER BY {order} LIMIT 500")["rows"]
            nk = len(keys)
            out = []
            for r in rows:
                parts = ["" if r[i] is None else str(r[i]) for i in range(nk)]
                vals = []
                for j, v in enumerate(r[nk + 1:]):
                    if v is None:
                        vals.append("")
                    elif isinstance(v, float):
                        vals.append(f"{v:.1f}" if abs(v) < 1e6 else f"{v:.0f}")
                    else:
                        vals.append(str(v))
                out.append({
                    "value": " · ".join(parts),
                    "parts": parts,
                    "n": r[nk],
                    "measures": vals,
                })
            return {"rows": out, "keys": key_labels, "measures": measures}
        except Exception as e:  # noqa: BLE001
            return {"rows": [], "error": str(e)}

    # ---------- Process dashboard: the process tree ----------
    @Slot(result="QVariant")
    def processTree(self):
        """The processes table shaped into a tree (parent -> children), in
        depth-first order with a `depth` per row. For each process: its own RSS
        and CPU, the WHOLE BRANCH's total RSS (the process plus every descendant),
        and how long it has been running. Built from the collected `processes`
        table, not read live."""
        if "processes" not in self.store.tables():
            return []
        cols, rows, _tr = self.store.query(
            "SELECT pid, ppid, name, user, rss, cpu_pct, elapsed_sec "
            "FROM processes",
            max_rows=100000,
        )
        col = {c: i for i, c in enumerate(cols)}
        nodes: dict[str, dict] = {}
        kids: dict[str, list] = {}
        order: list[str] = []
        for r in rows:
            pid = str(r[col["pid"]])
            ppid = str(r[col["ppid"]])
            if pid in nodes:  # pids are unique, but guard anyway
                continue
            nodes[pid] = {
                "pid": pid, "ppid": ppid,
                "name": r[col["name"]] or "",
                "user": r[col["user"]] or "",
                "rss": _num(r[col["rss"]]),
                "cpu": r[col["cpu_pct"]] or "",
                "elapsed": _num(r[col["elapsed_sec"]]),
            }
            kids.setdefault(ppid, []).append(pid)
            order.append(pid)

        # branch RSS = own RSS + every descendant's RSS (memoised, cycle-guarded)
        branch: dict[str, int] = {}

        def branch_rss(pid, seen):
            if pid in branch:
                return branch[pid]
            if pid in seen:
                return 0
            seen = seen | {pid}
            total = nodes[pid]["rss"]
            for c in kids.get(pid, []):
                if c in nodes and c != pid:
                    total += branch_rss(c, seen)
            branch[pid] = total
            return total

        for pid in order:
            branch_rss(pid, set())

        # roots: a process whose parent is not itself a listed process
        roots = [p for p in order
                 if nodes[p]["ppid"] not in nodes or nodes[p]["ppid"] == p]

        out: list[dict] = []

        def walk(pid, depth, seen):
            if pid in seen:
                return
            seen = seen | {pid}
            n = nodes[pid]
            out.append({
                "_id": pid,
                "depth": depth,
                "name": n["name"],
                "pid": pid,
                "user": n["user"],
                "cpu": n["cpu"],
                "rss_mb": round(n["rss"] / 1048576, 1),
                "branch_mb": round(branch.get(pid, n["rss"]) / 1048576, 1),
                "uptime": _fmt_elapsed(n["elapsed"]),
                "kids": len(kids.get(pid, [])),
            })
            # heaviest branch first, so the biggest consumers surface at the top
            for c in sorted(kids.get(pid, []),
                            key=lambda k: branch.get(k, 0), reverse=True):
                if c in nodes:
                    walk(c, depth + 1, seen)

        # roots ordered by their branch weight too
        for root in sorted(roots, key=lambda k: branch.get(k, 0), reverse=True):
            walk(root, 0, set())
        return out

    # ---------- the engine's own state, so the machinery is not a black box ----
    @Slot(result="QVariant")
    def engineState(self):
        """WHAT THE ENGINE IS DOING, in the interface rather than in the code.

        Every mechanism here was invisible from the outside: a file being rewritten
        because it was half empty, a stream whose normalization is behind by some
        number of lines, a retention bound that decides how far back the history
        goes, a process ends being folded onto their starts, and which process
        owns the databases at all. Each of those has surprised me at least once
        while building this, and the cost of not showing them is that the only way
        to find out is to read the source.

        Cached for a few seconds: it is drawn on a page that redraws whenever data
        arrives, and it asks the databases for their sizes."""
        now = time.time()
        if now - self._engine_cache[0] < 4 and self._engine_cache[1]:
            return self._engine_cache[1]

        def db_facts(name, db):
            out = {"name": name}
            try:
                free, total = db.waste()
                out.update(file_mb=round(total / 1048576, 1),
                           used_mb=round((total - free) / 1048576, 1),
                           free_mb=round(free / 1048576, 1),
                           free_share=round(free / total, 2) if total else 0)
            except Exception as e:  # noqa: BLE001
                out["error"] = str(e).splitlines()[0]
            c = self._compacted.get(name) or {}
            if c:
                out["compacted_at"] = c.get("at", "")
                out["reclaimed_mb"] = c.get("freed_mb", 0)
                out["compact_seconds"] = c.get("seconds", 0)
            return out

        stream = {}
        try:
            stream["materialized"] = self.events.row_count("events")
            stream["staged_raw"] = self.events.row_count("tetragon_raw")
            hi = self.events.fetch(
                "SELECT coalesce(max(seq), -1) FROM tetragon_raw")["rows"][0][0]
            wm = self.events.fetch(
                "SELECT coalesce(max(seq), -1) FROM events")["rows"][0][0]
            stream["watermark"] = wm
            # what has arrived but is not normalized yet — the number that tells
            # you the difference between "quiet" and "stuck"
            stream["backlog"] = max(int(hi) - int(wm), 0)
            # AT TIME ZONE 'UTC', because the stream is stored in UTC and a bare
            # now() is this machine's local time: compared against a naive UTC
            # column that silently answered "nothing in the last five minutes" on
            # a machine three hours ahead — a stopped stream and a busy one
            # looking exactly alike, which is the failure this whole card exists
            # to prevent.
            r = self.events.fetch(
                "SELECT max(ts)::VARCHAR, count(*) FILTER (WHERE ts > "
                "(now() AT TIME ZONE 'UTC') - INTERVAL 5 MINUTE) FROM events"
            )["rows"][0]
            stream["last_event"] = r[0] or ""
            stream["per_minute"] = round((r[1] or 0) / 5)
            f = eventstore.load_event_views()
            fold = (f[0].get("fold") if f else None) or {}
            if fold:
                folded = self.events.fetch(
                    "SELECT count(*) FROM events WHERE lifetime_ms IS NOT NULL"
                )["rows"][0][0]
                stream["fold"] = {"when": fold.get("when", ""),
                                  "onto": fold.get("onto", ""),
                                  "key": fold.get("key", ""),
                                  "rows": folded}
            stream["retention_rows"] = eventstore.MAX_ROWS
            stream["raw_window"] = eventstore.RAW_WINDOW
            stream["batch_bytes"] = eventstore.BATCH_BYTES
        except Exception as e:  # noqa: BLE001
            stream["error"] = str(e).splitlines()[0]

        inputs = [i for i in pipeline.load_inputs()
                  if i.get("query") or i.get("command")]
        state = {
            "owner": self.owner,
            "pid": os.getpid(),
            "owner_pid": getattr(self, "_owner_pid", 0),
            "socket": service.socket_path(),
            "serving": bool(self.service and self.service._srv is not None),
            "tetragon": {"log": self.reader.log,
                         "readable": self.reader.available(),
                         "cursor": str(self.reader.cursor),
                         "cursor_error": self.reader.cursor_error},
            "databases": [db_facts("state", self.store),
                          db_facts("events", self.events)],
            "stream": stream,
            "collection": {
                "sources": len(inputs),
                "disabled": sum(1 for i in inputs if i.get("enabled") is False),
                "last": self._cycle,
                "failing": sum(1 for k, v in self._status.items()
                               if v.get("error") and not k.startswith("_")),
                "workers": pipeline.WORKERS,
                "cadences": sorted({int(float(i.get("interval",
                                                  pipeline.DEFAULT_INTERVAL)))
                                    for i in inputs}),
            },
        }
        self._engine_cache = (now, state)
        return state

    @Slot(str, result="QVariant")
    def ruleTests(self, name):
        """Run one rule's own tests, from the interface. The suite runs them too,
        but a rule is edited HERE — and a rule that says what it must produce is
        only worth writing if the answer is one click away from where it is
        written."""
        rules = pipeline.load_inputs() + views.load_views()
        rule = next((r for r in rules
                     if (r.get("name") == name or r.get("table") == name)), None)
        if rule is None:
            return {"error": f"no rule called {name}"}
        if not rule.get("tests"):
            return {"results": [], "note": "this rule declares no tests"}
        try:
            res = ruletest.run_one(self.store, rule)
        except Exception as e:  # noqa: BLE001
            return {"error": str(e).splitlines()[0]}
        return {"results": res,
                "passed": sum(1 for r in res if r["passed"]),
                "failed": sum(1 for r in res if not r["passed"])}

    # ---------- Pipelines: the data flows, built from the expertise itself ----------
    @Slot(result="QVariant")
    def pipelineFlows(self):
        """Cached per collection. Building this walks every rule file and counts
        every table and view — and counting a VIEW re-executes it, which for the
        dependency graph is a recursive CTE over twenty thousand edges. Measured
        at 781 ms, called from the GUI thread every time events arrived: with the
        Pipelines page open the window froze every few seconds. The flows can only
        change when a collection ran, so they are rebuilt only then."""
        key = (self._gen, self._status_rev)
        if self._flows_cache is not None and self._flows_gen == key:
            return self._flows_cache
        flows = self._build_flows()
        self._flows_cache, self._flows_gen = flows, key
        return flows

    def _build_flows(self):
        """One flow per ENTRY POINT, as declared in expertise — not a hardcoded
        picture. An osquery input flows into its table and then into whichever
        enrichment views read that table; the Tetragon entry point flows into the
        raw stream, the normalization view and the materialized events table.
        Each stage carries live numbers (rows) so a flow shows what it produced."""
        flows = []

        # --- osquery inputs: input -> table -> views that read it ---
        view_specs = views.load_views()
        inputs = pipeline.load_inputs()
        tables = set(self.store.tables())
        for inp in inputs:
            if str(inp.get("kind", "")) == "tetragon":
                continue                    # handled below (a stream, not a query)
            table = inp.get("table") or inp.get("name")
            stages = [{
                "kind": "input", "name": inp.get("name", table),
                "title": inp.get("title", table),
                "detail": "osquery", "rows": -1,
                "ref": "inputs/" + str(inp.get("name", table)),
            }]
            rows = self._cached_count(table, tables)
            stages.append({
                "kind": "table", "name": table, "title": table,
                "detail": "DuckDB table", "rows": rows, "ref": "",
            })
            # a view belongs to this flow if it READS this table — matched on a
            # word boundary, so `ports` does not also match `ports_owned`
            tre = re.compile(r"\b" + re.escape(str(table)) + r"\b") if table else None
            for v in view_specs:
                if tre and tre.search(str(v.get("sql", ""))):
                    vn = v.get("name", "")
                    stages.append({
                        "kind": "view", "name": vn,
                        "title": v.get("title", vn),
                        "detail": "SQL view",
                        "rows": self._cached_count(vn, tables),
                        "ref": "views/" + str(vn),
                    })
            st = self._status.get(table, {})
            flows.append({
                "error": st.get("error", ""),
                "error_at": st.get("at", ""),
                "name": inp.get("name", table),
                "title": inp.get("title", table),
                "icon": inp.get("icon", "table"),
                "source": "osquery",
                "enabled": inp.get("enabled") is not False,
                # the rule's own cadence, not a number written here
                "interval": f"{inp.get('interval', pipeline.DEFAULT_INTERVAL)} s",
                "collected_at": self._collected_at.get(table, ""),
                "hidden": bool(inp.get("hidden")),
                "stages": stages,
            })

        # --- the Tetragon entry point: log tail -> raw -> normalize -> events ---
        tet = next((i for i in inputs if str(i.get("kind", "")) == "tetragon"), None)
        if tet is not None:
            raw_n = ev_n = 0
            try:
                raw_n = self.events.fetch(
                    "SELECT count(*) FROM tetragon_raw")["rows"][0][0]
                ev_n = self.events.fetch(
                    "SELECT count(*) FROM events")["rows"][0][0]
            except Exception as e:  # noqa: BLE001
                self._set_status("_events", str(e).splitlines()[0])
            norm = eventstore.load_event_views()
            nname = norm[0].get("name", "events_norm") if norm else "events_norm"
            est = self._status.get("_events") or self._status.get("_retention") or {}
            flows.append({
                "error": est.get("error", ""),
                "error_at": est.get("at", ""),
                "name": tet.get("name", "tetragon_events"),
                "title": tet.get("title", "Tetragon runtime events"),
                "icon": tet.get("icon", "security-high"),
                "source": str(tet.get("source", "")),
                "enabled": self.reader.available(),
                "interval": "stream",
                "collected_at": self._events_at,
                "hidden": False,
                "stages": [
                    {"kind": "input", "name": tet.get("name", "tetragon_events"),
                     "title": tet.get("title", "Tetragon"), "detail": "eBPF stream",
                     "rows": -1, "ref": "inputs/tetragon"},
                    {"kind": "table", "name": "tetragon_raw", "title": "tetragon_raw",
                     "detail": "raw JSON", "rows": raw_n, "ref": ""},
                    {"kind": "view", "name": nname, "title": "normalization",
                     "detail": "SQL view", "rows": -1,
                     "ref": "events/normalize"},
                    {"kind": "table", "name": "events", "title": "events",
                     "detail": "materialized", "rows": ev_n, "ref": ""},
                ],
            })
        return flows

    # NB: cross-table JOIN and per-cell EDITING were v0 features that do not fit
    # v1 — state tables are whole-snapshot osquery replaces (a written cell is
    # gone next cycle), and table relations are expressed by SQL/the graph, not a
    # join builder. Their slots and UI were removed. Column-layout persistence is
    # a no-op for now (a real future setting), kept so the table can still call it.
    @Slot(str, "QVariant")
    def setTabColumns(self, table, colcfg):
        pass  # column layout persistence: to be wired to a setting later

    # ---------- SQL history (persisted JSON) ----------
    def _load_history(self):
        try:
            return json.loads(_SQL_HISTORY.read_text())
        except Exception:
            return []

    @Slot(result="QVariant")
    def sqlHistory(self):
        return self._load_history()[:30]

    @Slot(str)
    def rememberSql(self, sql):
        sql = (sql or "").strip()
        if not sql:
            return
        hist = [x for x in self._load_history() if x != sql]
        hist.insert(0, sql)
        try:
            _SQL_HISTORY.parent.mkdir(parents=True, exist_ok=True)
            _SQL_HISTORY.write_text(json.dumps(hist[:200]))
        except Exception:
            pass

    # ---------- saved queries (expertise/queries/*.yaml) ----------
    @Slot(result="QVariant")
    def savedQueries(self):
        out = []
        for d in load_yaml_dir(_QUERIES_DIR):
            f = Path(d["_file"])
            out.append({
                "name": d.get("name", f.stem),
                "title": d.get("title", d.get("name", f.stem)),
                "description": d.get("description", ""),
                "sql": d.get("sql", ""),
            })
        return out

    # ---------- expertise catalog (read-only for now) ----------
    @Slot(result="QVariant")
    def expertiseDirs(self):
        out = []
        for path, title in _EXP_CATS:
            if (_EXPERTISE / path).is_dir():
                out.append({"path": path, "title": title, "depth": 0})
        return out

    @Slot(str, result="QVariant")
    def expertiseElements(self, d):
        out = []
        for spec in load_yaml_dir(_EXPERTISE / (d or "")):
            f = Path(spec["_file"])
            rel = str(f.relative_to(_EXPERTISE))[:-5]  # drop .yaml
            out.append({
                "_id": rel,
                "id": spec.get("name", f.stem),
                "name": spec.get("name", f.stem),
                "title": spec.get("title", spec.get("name", f.stem)),
                "type": spec.get("type", ""),
                "version": str(spec.get("version", "")),
                "rel": rel,
                "path": rel,
            })
        return out

    @Slot(str, result=str)
    def readExpertise(self, rel):
        f = _EXPERTISE / (str(rel) + ".yaml")
        try:
            return f.read_text() if f.is_file() else ""
        except Exception as e:  # noqa: BLE001
            return "# " + str(e)

    @Slot(str, str, result=str)
    def saveExpertise(self, rel, text):
        """Write an edited expertise file. Validates YAML first (never persist a
        broken rule) and refuses paths escaping the expertise tree. Returns "" on
        success, else the error."""
        root = _EXPERTISE.resolve()
        f = (_EXPERTISE / (str(rel) + ".yaml")).resolve()
        if not str(f).startswith(str(root)):
            return "path outside expertise"
        try:
            yaml.safe_load(text)  # reject invalid YAML before touching the file
        except Exception as e:  # noqa: BLE001
            return "YAML error: " + str(e)
        try:
            f.write_text(text)
        except Exception as e:  # noqa: BLE001
            return str(e)
        # event views are applied at init; re-apply so an edit takes effect now
        if str(rel).startswith("events/"):
            try:
                # only the owner holds the database; a follower asks it to
                (self.events.apply_views() if self.owner
                 else self.events.hook("apply_event_views"))
            except Exception as e:  # noqa: BLE001
                return f"saved, but the rule was not applied: {e}"
        return ""

    @Slot(str, str, str, result=str)
    def saveQuery(self, title, sql, description):
        sql = (sql or "").strip()
        if not sql:
            return "empty query"
        name = _san_name(title or "query")
        spec = {
            "type": "query",
            "name": name,
            "title": (title or name).strip(),
            "version": "1.0.0",
            "description": (description or "").strip(),
            "sql": sql,
        }
        try:
            _QUERIES_DIR.mkdir(parents=True, exist_ok=True)
            (_QUERIES_DIR / f"{name}.yaml").write_text(
                yaml.safe_dump(spec, allow_unicode=True, sort_keys=False)
            )
            return ""
        except Exception as e:  # noqa: BLE001
            return str(e)

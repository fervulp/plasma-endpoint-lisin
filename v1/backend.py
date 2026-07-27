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

from core import pipeline, views
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
        self.store = Store()
        # events live in a SEPARATE DuckDB (stream vs snapshot); the reader tails
        # the root Tetragon export and lands raw JSON, normalized by a SQL view.
        self.events = EventStore()
        self.events.apply_views()
        self.reader = TetragonReader()
        self._events_at = ""
        self._collected_at: dict[str, str] = {}
        # per-table (columns, count) cache + the collection generation it is for
        self._tab_cache: dict[str, tuple] = {}
        self._gen = 0
        # last outcome per source: {table: {error, at, rows}} — read by the
        # Pipelines page, so a broken source is visible instead of silent
        self._status: dict[str, dict] = {}
        self._flows_cache = None      # pipelineFlows is expensive to build
        self._flows_gen = -1
        self._meta = self._load_meta()
        if not os.environ.get("LISIN_NO_COLLECT"):
            threading.Thread(target=self._scheduler, daemon=True).start()
            threading.Thread(target=self._event_loop, daemon=True).start()

    # ---------- metadata (table -> title/icon, from the YAML rules) ----------
    def _load_meta(self) -> dict:
        # `columns:` in a rule is the author saying WHICH FIELDS MATTER for that
        # table (the rest stay one click away); without it the engine measures
        # which columns are empty and hides those.
        m = {}
        for inp in pipeline.load_inputs():
            t = inp.get("table") or inp.get("name")
            m[t] = {"title": inp.get("title", t), "icon": inp.get("icon", "table"),
                    "hidden": bool(inp.get("hidden")),
                    "columns": inp.get("columns") or [],
                    "priority": inp.get("priority")}
        for v in views.load_views():
            n = v.get("name")
            m[n] = {"title": v.get("title", n), "icon": v.get("icon", "table"),
                    "hidden": bool(v.get("hidden")),
                    "columns": v.get("columns") or [],
                    "priority": v.get("priority")}
        return m

    # ---------- collection ----------
    def _scheduler(self):
        # hand over whatever the database already holds at once, then collect.
        # The tick is short; WHAT runs is decided per input by its own interval
        # (pipeline._due), so a fast source stays fresh without dragging every
        # slow inventory source along with it.
        pipeline.sweep_temp()      # leftovers from a previous run, if it was killed
        self._push_state()
        while True:
            self._run_all()
            time.sleep(5)

    def _run_all(self, force: bool = False):
        ran = []
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
                        self._status[x["table"]] = {
                            "error": x["error"], "at": now, "rows": 0}
                    else:
                        self._collected_at[x["table"]] = now
                        self._status[x["table"]] = {
                            "error": "", "at": now, "rows": x.get("rows", 0)}
            for v in st.get("derive", {}).get("views", []):
                if v.get("error"):
                    self._status[v["view"]] = {
                        "error": v["error"], "at": _iso_now(), "rows": 0}
        except Exception as e:  # noqa: BLE001
            self._status["_collector"] = {"error": str(e), "at": _iso_now(),
                                          "rows": 0}
        # the tick is every few seconds but most of them collect nothing (each
        # input has its own interval) — pushing a snapshot then would just make
        # every open page re-read for no new data.
        if ran or force:
            self._push_state()

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
            except Exception:
                pass
            try:
                if cycles % 20 == 0:  # ~every 60 s: bound the stream
                    self.events.prune()
            except Exception:
                pass
            time.sleep(3)

    def _events_tab(self) -> dict:
        """The Events tab, served like any other tab (uniform ownership). Its
        count/freshness come from the live event store; the curated column set is
        the default view (the full taxonomy is still offered in the picker)."""
        cnt, cols = 0, []
        try:
            with self.events._lock:
                cnt = self.events._con.execute(
                    "SELECT count(*) FROM events"
                ).fetchone()[0]
                cols = [c for c in self.events.columns("events") if c != "seq"]
        except Exception:
            pass
        # THE COLUMNS ARE THE TABLE'S REAL COLUMNS (so a field picker only ever
        # offers something that exists); the curated set is what is SHOWN by
        # default — everything else starts hidden and is one click away.
        if not cols:
            cols = list(_EVENTS_COLUMNS)
        shown = [c for c in _EVENTS_COLUMNS if c in cols]
        hidden = [c for c in cols if c not in shown]
        return {
            "name": "events", "title": "Events", "icon": "view-calendar-list",
            "builtin": True, "priority": 10,   # the stream comes first
            # curated first, then the rest — the default order reads as a phrase
            "columns": shown + hidden,
            "count": cnt, "collected_at": self._events_at,
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

    def _dead_columns(self, table: str, cols: list[str]) -> list[str]:
        """Columns that hold NO value at all in this table, right now.

        A column that is empty in every row is noise in a table view — it costs a
        column of width and tells the reader nothing. Rather than curate a list of
        "interesting" fields by hand (which would go stale the moment a source
        changes), the emptiness is MEASURED and those columns start hidden; they
        are one click away in the Columns panel, and they appear by themselves as
        soon as they carry data. One query per table, cached per collection."""
        if not cols or cols == ["empty"]:
            return []
        parts = ", ".join(
            f"sum(CASE WHEN {ident(c)} IS NULL OR CAST({ident(c)} AS VARCHAR) = ''"
            f" THEN 0 ELSE 1 END)"
            for c in cols
        )
        try:
            vals = self.store._con.execute(
                f"SELECT {parts} FROM {ident(table)}"
            ).fetchone()
        except Exception:  # noqa: BLE001
            return []
        return [c for c, v in zip(cols, vals) if not v]

    # ---------- snapshot ----------
    def _snapshot(self) -> dict:
        # A SNAPSHOT IS SENT EVERY FEW SECONDS, so it must be cheap. Counting rows
        # per table meant re-running count(*) on every table on every push — and
        # for a view (ports_owned) that re-executes its JOIN. Both the count and
        # the column list only change when the table is rewritten, so they are
        # cached and refreshed only when the collection timestamp moved.
        tabs = []
        with self.store._lock:
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
                    cached = (key, cols, self.store.row_count(name), hidden, order)
                    self._tab_cache[name] = cached
                tabs.append({
                    "name": name,
                    "title": meta.get("title", name),
                    "icon": meta.get("icon", "table"),
                    "priority": meta.get("priority"),
                    "builtin": True,
                    "columns": cached[1],
                    "count": cached[2],
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
        with self.store._lock:
            if name not in self.store.tables():
                return {"rows": [], "total": 0, "columns": [], "error": "unknown table"}
        return self._rows(self.store, name, where, order, limit, offset)

    def _rows(self, target, table, where, order, limit, offset,
              default_order="", id_col=None):
        """Shared table-page reader for both stores: count + a SELECT window, each
        row turned into a QML-friendly dict with a stable _id."""
        with target._lock:
            wh = f" WHERE {where}" if where else ""
            order = order or default_order
            try:
                total = target._con.execute(
                    f"SELECT count(*) FROM {ident(table)}{wh}"
                ).fetchone()[0]
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
        with target._lock:
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
                rows = target._con.execute(
                    f"SELECT {sel} FROM {ident(table)}{wh}{grp} "
                    f"ORDER BY {order} LIMIT 500"
                ).fetchall()
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
        with self.store._lock:
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

    # ---------- Pipelines: the data flows, built from the expertise itself ----------
    @Slot(result="QVariant")
    def pipelineFlows(self):
        """Cached per collection. Building this walks every rule file and counts
        every table and view — and counting a VIEW re-executes it, which for the
        dependency graph is a recursive CTE over twenty thousand edges. Measured
        at 781 ms, called from the GUI thread every time events arrived: with the
        Pipelines page open the window froze every few seconds. The flows can only
        change when a collection ran, so they are rebuilt only then."""
        if self._flows_cache is not None and self._flows_gen == self._gen:
            return self._flows_cache
        flows = self._build_flows()
        self._flows_cache, self._flows_gen = flows, self._gen
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
        with self.store._lock:
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
                with self.events._lock:
                    raw_n = self.events._con.execute(
                        "SELECT count(*) FROM tetragon_raw").fetchone()[0]
                    ev_n = self.events._con.execute(
                        "SELECT count(*) FROM events").fetchone()[0]
            except Exception:
                pass
            norm = self.events.load_views()
            nname = norm[0].get("name", "events_norm") if norm else "events_norm"
            flows.append({
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
                self.events.apply_views()
            except Exception:
                pass
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

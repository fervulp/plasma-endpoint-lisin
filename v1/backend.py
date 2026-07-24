"""Qt <-> v1 core bridge.

The v0 interface is copied verbatim; only the hood changes. So this backend
exposes the SAME contract the copied QML expects — the stateReady(snapshot)
signal and the Data-tab slots — but serves everything from the osquery/DuckDB
store instead of the old SQLite StateDB.

Snapshot shape (as v0): {os, tabs:[{name,title,icon,builtin,columns,count,
colcfg,collected_at}]}. tableRows(name, where, order, limit, offset) ->
{rows, total, columns, error}.

Sections other than Data are stubbed for now (empty results, no crash) and will
be wired to DuckDB incrementally.
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
from core.store import Store

_SQL_HISTORY = Path(os.path.expanduser("~/.local/share/lisin")) / "sql_history.json"
_QUERIES_DIR = Path(__file__).resolve().parent / "expertise" / "queries"


def _san_name(name: str) -> str:
    s = re.sub(r"[^0-9A-Za-z_Ѐ-ӿ-]+", "_", str(name).strip()).strip("_")
    return s or "query"

_FORBID = re.compile(
    r"\b(attach|detach|copy|install|load|pragma|insert|update|delete|drop|"
    r"alter|create|call|export|import)\b",
    re.I,
)


def _ident(name: str) -> str:
    return '"' + str(name).replace('"', "") + '"'


def _iso_now() -> str:
    return datetime.datetime.now().replace(microsecond=0).isoformat(sep=" ")


class Backend(QObject):
    stateReady = Signal("QVariant")
    collectingChanged = Signal()

    def __init__(self):
        super().__init__()
        self.store = Store()
        self.collecting = False
        self._collected_at: dict[str, str] = {}
        self._meta = self._load_meta()
        if not os.environ.get("LISIN_NO_COLLECT"):
            threading.Thread(target=self._scheduler, daemon=True).start()

    # ---------- metadata (table -> title/icon, from the YAML rules) ----------
    def _load_meta(self) -> dict:
        m = {}
        for inp in pipeline.load_inputs():
            t = inp.get("table") or inp.get("name")
            m[t] = {"title": inp.get("title", t), "icon": inp.get("icon", "table")}
        for v in views.load_views():
            n = v.get("name")
            m[n] = {"title": v.get("title", n), "icon": v.get("icon", "table")}
        return m

    # ---------- collection ----------
    def _scheduler(self):
        # hand over whatever the database already holds at once, then collect.
        self._push_state()
        while True:
            self._run_all()
            time.sleep(30)

    def _run_all(self):
        try:
            with self.store._lock:
                st = pipeline.run_all(self.store)
            now = _iso_now()
            for x in st.get("inputs", []):
                if not x.get("error"):
                    self._collected_at[x["table"]] = now
        except Exception:
            pass
        self._push_state()

    def _push_state(self):
        try:
            self.stateReady.emit(self._snapshot())
        except RuntimeError:
            pass  # the window is gone

    # ---------- snapshot ----------
    def _columns(self, name: str) -> list[str]:
        return [
            r[0]
            for r in self.store._con.execute(
                "SELECT column_name FROM information_schema.columns "
                "WHERE table_name = ? ORDER BY ordinal_position",
                [name],
            ).fetchall()
        ]

    def _snapshot(self) -> dict:
        tabs = []
        with self.store._lock:
            for name in self.store.tables():
                if name.startswith("_"):
                    continue
                meta = self._meta.get(name, {})
                tabs.append({
                    "name": name,
                    "title": meta.get("title", name),
                    "icon": meta.get("icon", "table"),
                    "builtin": True,
                    "columns": self._columns(name),
                    "count": self.store.row_count(name),
                    "colcfg": None,
                    "collected_at": self._collected_at.get(name, ""),
                })
        last = max(self._collected_at.values(), default="")
        return {"os": self._os_info(), "tabs": tabs, "collected_at": last}

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

    @Slot()
    def refresh(self):
        threading.Thread(target=self._run_all, daemon=True).start()

    @Slot()
    def collectNow(self):
        self.collecting = True
        self.collectingChanged.emit()

        def go():
            try:
                self._run_all()
            finally:
                self.collecting = False
                self.collectingChanged.emit()

        threading.Thread(target=go, daemon=True).start()

    @Slot(result=bool)
    def isCollecting(self):
        return self.collecting

    @Slot(str, str, str, int, int, result="QVariant")
    def tableRows(self, name, where="", order="", limit=0, offset=0):
        # "events" is a synthetic tab v0 always prepends; v1 has no events yet.
        if name == "events":
            return {"rows": [], "total": 0, "columns": [], "error": ""}
        with self.store._lock:
            if name not in self.store.tables():
                return {"rows": [], "total": 0, "columns": [], "error": "unknown table"}
            q = _ident(name)
            wh = f" WHERE {where}" if where else ""
            try:
                total = self.store._con.execute(
                    f"SELECT count(*) FROM {q}{wh}"
                ).fetchone()[0]
                sql = f"SELECT * FROM {q}{wh}"
                if order:
                    sql += f" ORDER BY {order}"
                if limit and int(limit) > 0:
                    sql += f" LIMIT {int(limit)} OFFSET {int(offset)}"
                cols, rows, _tr = self.store.query(sql, max_rows=1000)
                # every row needs a stable id: the UI keys selection on _id
                base = int(offset) if (limit and int(limit) > 0) else 0
                objs = []
                for i, r in enumerate(rows):
                    o = dict(zip(cols, r))
                    o["_id"] = str(base + i)
                    objs.append(o)
                return {"rows": objs, "total": total, "columns": cols, "error": ""}
            except Exception as e:  # noqa: BLE001
                return {"rows": [], "total": 0, "columns": [], "error": str(e)}

    @Slot(result="QVariant")
    def eventTaxonomy(self):
        # no events source in v1 yet
        return {"names": [], "groups": []}

    @Slot(str, str, result="QVariant")
    def stateGroups(self, table, field):
        # group-by counts for the filter panel; simple and safe over DuckDB
        if not re.fullmatch(r"[A-Za-z0-9_]+", field or ""):
            return []
        with self.store._lock:
            if table not in self.store.tables():
                return []
            try:
                rows = self.store._con.execute(
                    f"SELECT {_ident(field)} AS v, count(*) AS n "
                    f"FROM {_ident(table)} GROUP BY 1 ORDER BY n DESC LIMIT 200"
                ).fetchall()
                return [{"value": r[0], "count": r[1]} for r in rows]
            except Exception:
                return []

    # ---------- join stubs (no cross-table joins wired yet) ----------
    @Slot(str, result="QVariant")
    def joinTables(self, name):
        return []

    @Slot(str, str, result="QVariant")
    def joinSuggest(self, a, b):
        return {"left": "", "right": ""}

    @Slot(str, str, str, str, str, str, int, int, result="QVariant")
    def tableJoinRows(self, name, jt, jl, jr, where="", order="", limit=0, offset=0):
        return {"rows": [], "total": 0, "columns": [], "error": ""}

    # ---------- edits: v1 state tables are osquery snapshots (read-only) ----------
    @Slot(str, "QVariant", str, str)
    def setCell(self, table, rowid, col, val):
        pass  # snapshots are replaced each cycle; editing has no meaning here

    @Slot(str, "QVariant")
    def setTabColumns(self, table, colcfg):
        pass  # column layout persistence: to be wired to settings later

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
        if _QUERIES_DIR.is_dir():
            for f in sorted(_QUERIES_DIR.glob("*.yaml")):
                try:
                    d = yaml.safe_load(f.read_text()) or {}
                except Exception:
                    continue
                out.append({
                    "name": d.get("name", f.stem),
                    "title": d.get("title", d.get("name", f.stem)),
                    "description": d.get("description", ""),
                    "sql": d.get("sql", ""),
                })
        return out

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

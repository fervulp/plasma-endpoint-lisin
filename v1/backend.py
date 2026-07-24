"""Qt <-> v1 core bridge (pull model).

QML asks for the table list and a table's rows; a background collection runs the
pipeline and emits dataReady when a sweep finishes. All store access is
serialized on the store lock — one DuckDB connection, a background writer and UI
readers.

Slots return plain dict/list (rows as objects keyed by column) so QML consumes
them directly; SQL typed by the user is SELECT-only.
"""
from __future__ import annotations

import os
import re
import threading

from PySide6.QtCore import QObject, Signal, Slot

from core import pipeline
from core.store import Store

_SELECT_ONLY = re.compile(r"^\s*(select|with)\b", re.I)
_FORBID = re.compile(
    r"\b(attach|detach|copy|install|load|pragma|insert|update|delete|drop|"
    r"alter|create|call|export|import)\b",
    re.I,
)


def _q(name: str) -> str:
    return '"' + str(name).replace('"', "") + '"'


class Backend(QObject):
    dataReady = Signal()

    def __init__(self):
        super().__init__()
        self.store = Store()
        # LISIN_NO_COLLECT: run the UI against the existing database without the
        # collector touching it (offscreen render checks, synthetic data).
        if not os.environ.get("LISIN_NO_COLLECT"):
            threading.Thread(target=self._collect, daemon=True).start()

    def _collect(self):
        try:
            with self.store._lock:
                pipeline.run_all(self.store)
        finally:
            self.dataReady.emit()

    @Slot()
    def refresh(self):
        threading.Thread(target=self._collect, daemon=True).start()

    @Slot(result="QStringList")
    def tables(self):
        with self.store._lock:
            return [t for t in self.store.tables() if not t.startswith("_")]

    def _result(self, sql: str) -> dict:
        cols, rows, tr = self.store.query(sql, max_rows=1000)
        return {
            "columns": cols,
            "rows": [dict(zip(cols, r)) for r in rows],
            "truncated": tr,
            "error": "",
        }

    @Slot(str, result="QVariant")
    def tableRows(self, name: str):
        with self.store._lock:
            if name not in self.store.tables():
                return {"columns": [], "rows": [], "truncated": False, "error": "unknown table"}
            return self._result(f"SELECT * FROM {_q(name)}")

    @Slot(str, result="QVariant")
    def runQuery(self, sql: str):
        sql = sql or ""
        if not _SELECT_ONLY.match(sql) or _FORBID.search(sql):
            return {"columns": [], "rows": [], "truncated": False,
                    "error": "read-only: only SELECT is allowed"}
        with self.store._lock:
            try:
                return self._result(sql)
            except Exception as e:  # noqa: BLE001
                return {"columns": [], "rows": [], "truncated": False, "error": str(e)}

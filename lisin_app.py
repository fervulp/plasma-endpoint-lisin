#!/usr/bin/env python3
"""LiSin - a lightweight local EDR for Fedora. Kirigami GUI.

Start it (it is important to bypass a pip-installed PySide6 from the user site):
  PYTHONNOUSERSITE=1 QT_QUICK_CONTROLS_STYLE=org.kde.desktop python3 lisin_app.py

The Backend is assembled from MIXINS by section (agent/api/): state, events,
dashboards, expertise, system. Only the core stays here - the pipeline
scheduler, error collection and starting the window. To add a slot, edit the
relevant mixin, not this file.
"""
import sys
import threading
import time
from pathlib import Path

from PySide6.QtCore import QObject, QUrl, Signal, Slot
from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QQmlApplicationEngine

from agent.api import (DashboardApi, EventsApi, ExpertiseApi, StateApi,
                       SystemApi)
from agent.core.pipeline import StatePipeline
from agent.core.statedb import StateDB


class Backend(QObject, StateApi, EventsApi, DashboardApi, ExpertiseApi,
              SystemApi):
    """The QML <-> agent bridge. The slots themselves live in agent/api/*."""

    stateReady = Signal("QVariant")
    pipelineReady = Signal("QVariant")
    # whether an on-demand collection is running right now (the "Collect now" button)
    collectingChanged = Signal()

    def __init__(self):
        super().__init__()
        self.collecting = False
        self.db = StateDB()
        self.pipe = StatePipeline(self.db)
        import collections
        from agent.collect.metrics import Sampler
        self.sampler = Sampler()
        self.errors_log = collections.deque(maxlen=200)
        self._err_seen = set()
        self._last_sample = 0.0
        threading.Thread(target=self._scheduler, daemon=True).start()

    # -------- the input scheduler + the metrics sampler --------
    def _scheduler(self):
        while True:
            now = time.time()
            if now - self._last_sample >= 10:
                self._last_sample = now
                self.sampler.sample()
            if self.pipe.tick():
                self._collect_errors()
                self.stateReady.emit(self.db.snapshot())
                self._emit_pipe()
            time.sleep(2)

    def _collect_errors(self):
        # the error stream of the EDR modules: pipeline node errors + YAML parsing
        for (pipe, node), st in self.pipe.status.items():
            if st.get("error"):
                sig = (pipe, node, st["error"])
                if sig not in self._err_seen:
                    self._err_seen.add(sig)
                    self.errors_log.appendleft({
                        "time": st.get("ran_at", ""),
                        "module": f"{pipe}/{node}",
                        "error": st["error"]})
        for e in self.pipe.errors:
            if e not in self._err_seen:
                self._err_seen.add(e)
                self.errors_log.appendleft(
                    {"time": "", "module": "expertise", "error": e})

    @Slot()
    def refresh(self):
        threading.Thread(target=self._run_all, daemon=True).start()

    def _run_all(self):
        self.pipe.run_all()
        self.stateReady.emit(self.db.snapshot())
        self._emit_pipe()

    def _emit_pipe(self):
        self.pipelineReady.emit(self.pipe.pipelines_info())


def _acquire_single_instance() -> bool:
    """A single writer: a second instance does not start (it would clobber the DB)."""
    global _instance_lock
    import fcntl
    lock_path = Path.home() / ".local/share/lisin/lisin.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    _instance_lock = open(lock_path, "w")
    try:
        fcntl.flock(_instance_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return False
    return True


def main():
    if not _acquire_single_instance():
        sys.stderr.write("LiSin is already running - a second instance will not "
                         "start (to avoid clobbering the database). Close the first one.\n")
        sys.exit(1)

    app = QGuiApplication(sys.argv)
    app.setApplicationName("LiSin")
    app.setOrganizationName("lisin")
    app.setDesktopFileName("lisin")

    engine = QQmlApplicationEngine()
    backend = Backend()
    engine.rootContext().setContextProperty("backend", backend)
    qml = Path(__file__).parent / "ui" / "Main.qml"
    engine.load(QUrl.fromLocalFile(str(qml)))
    if not engine.rootObjects():
        sys.exit(1)
    sys.exit(app.exec())


if __name__ == "__main__":
    main()

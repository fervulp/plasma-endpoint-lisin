#!/usr/bin/env python3
"""LiSin — лёгкий локальный EDR для Fedora. Kirigami GUI.

Запуск (важно обойти pip-PySide6 из user site):
  PYTHONNOUSERSITE=1 QT_QUICK_CONTROLS_STYLE=org.kde.desktop python3 lisin_app.py

Backend собран из МИКСИНОВ по разделам (agent/api/): состояние, события,
дашборды, экспертиза, служебное. Здесь остаётся только ядро — планировщик
конвейера, сбор ошибок и запуск окна. Чтобы добавить слот, правь нужный
миксин, а не этот файл.
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
from agent.pipeline import StatePipeline
from agent.statedb import StateDB


class Backend(QObject, StateApi, EventsApi, DashboardApi, ExpertiseApi,
              SystemApi):
    """Мост QML ↔ агент. Сами слоты живут в миксинах agent/api/*."""

    stateReady = Signal("QVariant")
    pipelineReady = Signal("QVariant")
    # идёт ли сейчас сбор по требованию (кнопка «Collect now»)
    collectingChanged = Signal()

    def __init__(self):
        super().__init__()
        self.collecting = False
        self.db = StateDB()
        self.pipe = StatePipeline(self.db)
        import collections
        from agent.metrics import Sampler
        self.sampler = Sampler()
        self.errors_log = collections.deque(maxlen=200)
        self._err_seen = set()
        self._last_sample = 0.0
        threading.Thread(target=self._scheduler, daemon=True).start()

    # -------- планировщик точек входа + сэмплер метрик --------
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
        # поток ошибок модулей EDR: ошибки узлов конвейера + парсинга YAML
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
    """Единственный писатель: второй экземпляр не стартует (не затирает БД)."""
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
        sys.stderr.write("LiSin уже запущен — второй экземпляр не стартует "
                         "(во избежание затирания БД). Закройте первый.\n")
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

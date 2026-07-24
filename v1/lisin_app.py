#!/usr/bin/env python3
"""LiSin v1 — osquery + DuckDB, Kirigami GUI.

Run it (bypass a pip PySide6 in the user site so the system Kirigami loads):
  PYTHONNOUSERSITE=1 QT_QUICK_CONTROLS_STYLE=org.kde.desktop python3 lisin_app.py
or just ./lisin
"""
from __future__ import annotations

import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(_ROOT))  # so `core` and `backend` import

from PySide6.QtCore import QUrl  # noqa: E402
from PySide6.QtGui import QGuiApplication  # noqa: E402
from PySide6.QtQml import QQmlApplicationEngine  # noqa: E402

from backend import Backend  # noqa: E402
from core.store import data_path  # noqa: E402

_lock_handle = None


def _single_instance() -> bool:
    """One writer only (a second instance would fight over the DuckDB file).
    A separate lock from v0 so both can run side by side during the migration."""
    global _lock_handle
    import fcntl

    p = data_path().parent / "lisin-v1.lock"
    _lock_handle = open(p, "w")
    try:
        fcntl.flock(_lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return False
    return True


def main():
    if not _single_instance():
        sys.stderr.write("LiSin v1 is already running.\n")
        sys.exit(1)

    app = QGuiApplication(sys.argv)
    app.setApplicationName("LiSin")
    app.setOrganizationName("lisin")

    engine = QQmlApplicationEngine()
    backend = Backend()
    engine.rootContext().setContextProperty("backend", backend)
    engine.load(QUrl.fromLocalFile(str(_ROOT / "ui" / "Main.qml")))
    if not engine.rootObjects():
        sys.exit(1)
    sys.exit(app.exec())


if __name__ == "__main__":
    main()

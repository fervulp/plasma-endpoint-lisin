#!/usr/bin/env python3
"""LiSin — App manager. Control of what each flatpak application may do.

  PYTHONNOUSERSITE=1 QT_QUICK_CONTROLS_STYLE=org.kde.desktop python3 lisin_apps.py
"""
from __future__ import annotations

import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(_ROOT))

from PySide6.QtCore import QUrl  # noqa: E402
from PySide6.QtGui import QGuiApplication  # noqa: E402
from PySide6.QtQml import QQmlApplicationEngine  # noqa: E402

from backend import Backend  # noqa: E402


def main():
    app = QGuiApplication(sys.argv)
    app.setApplicationName("LiSin App manager")
    app.setOrganizationName("lisin")
    app.setDesktopFileName("lisin-apps")

    engine = QQmlApplicationEngine()
    backend = Backend()
    engine.rootContext().setContextProperty("backend", backend)
    engine.addImportPath(str(_ROOT / "ui"))
    engine.load(QUrl.fromLocalFile(str(_ROOT / "ui" / "Main.qml")))
    if not engine.rootObjects():
        sys.exit(1)
    sys.exit(app.exec())


if __name__ == "__main__":
    main()

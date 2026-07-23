#!/usr/bin/env bash
# LiSin launcher from the rpm: system PySide6 + Kirigami.
export PYTHONNOUSERSITE=1
export QT_QUICK_CONTROLS_STYLE=org.kde.desktop
exec python3 /usr/share/lisin/lisin_app.py "$@"

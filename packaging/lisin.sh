#!/usr/bin/env bash
# Лаунчер LiSin из rpm: системный PySide6 + Kirigami.
export PYTHONNOUSERSITE=1
export QT_QUICK_CONTROLS_STYLE=org.kde.desktop
exec python3 /usr/share/lisin/lisin_app.py "$@"

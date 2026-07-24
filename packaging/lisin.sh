#!/usr/bin/env bash
# LiSin launcher from the rpm: system PySide6 + Kirigami.
export PYTHONNOUSERSITE=1
export QT_QUICK_CONTROLS_STYLE=org.kde.desktop
APP=/usr/share/lisin/lisin_app.py

# Run inside a DEDICATED systemd user scope (lisin.scope) so the whole app AND
# every collection subprocess (bash/rpm/journalctl/ss and their children) share
# ONE cgroup. The eBPF collector skips that cgroup in the kernel, so the agent
# never records its own activity - the only self-noise filter that survives the
# fork-without-exec of shell $(...) / pipelines. Falls back to a plain run if
# systemd-run is unavailable (then the collector cannot skip self until LiSin
# runs in a scope).
if command -v systemd-run >/dev/null 2>&1 && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  exec systemd-run --user --scope --quiet --unit=lisin \
       --setenv=PYTHONNOUSERSITE=1 \
       --setenv=QT_QUICK_CONTROLS_STYLE=org.kde.desktop \
       python3 "$APP" "$@"
fi
exec python3 "$APP" "$@"

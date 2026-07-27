#!/usr/bin/env python3
"""Render the documentation screenshots — against INVENTED data, never this machine.

A screenshot of a working EDR is a screenshot of somebody's computer: process
names, installed software, remote addresses, user names, disk serials. The
repository is public, so the pictures in it are built from a synthetic database
instead: the app is pointed at a throwaway data directory (LISIN_DATA_DIR) with
collection disabled (LISIN_NO_COLLECT), and the tables are filled here.

Every value below is made up. Addresses come from the ranges RFC 5737 reserves
for documentation (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24), the host is
"workstation", the user is "analyst".

    cd v1 && PYTHONNOUSERSITE=1 python3 tests/screenshots.py
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile

V1 = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, V1)

SHOTS = os.path.join(V1, "docs", "screenshots")
SANDBOX = tempfile.mkdtemp(prefix="lisin-shots-")
os.environ["LISIN_DATA_DIR"] = SANDBOX      # a throwaway database, not the real one
os.environ["LISIN_NO_COLLECT"] = "1"        # and nothing is collected into it
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ.setdefault("QT_QUICK_CONTROLS_STYLE", "org.kde.desktop")

# --------------------------------------------------------------- invented data
PROCESSES = [
    # name, pid, ppid, user, cpu, mem, rss, elapsed, state, cmdline
    ("systemd", 1, 0, "root", "0.3", "0.1", "12058624", "86400", "S", "/usr/lib/systemd/systemd --system"),
    ("systemd-journald", 412, 1, "root", "0.6", "0.3", "31457280", "86390", "S", "/usr/lib/systemd/systemd-journald"),
    ("sshd", 780, 1, "root", "0.0", "0.1", "9437184", "86380", "S", "sshd: /usr/sbin/sshd -D"),
    ("NetworkManager", 802, 1, "root", "0.4", "0.2", "20971520", "86380", "S", "/usr/sbin/NetworkManager --no-daemon"),
    ("firefox", 3120, 1204, "analyst", "7.4", "4.1", "612368384", "5400", "S", "/usr/lib64/firefox/firefox"),
    ("code", 3300, 1204, "analyst", "3.1", "2.6", "402653184", "4800", "S", "/usr/share/code/code"),
    ("bash", 4102, 1204, "analyst", "0.0", "0.0", "4194304", "1800", "S", "-bash"),
    ("curl", 4310, 4102, "analyst", "0.1", "0.0", "6291456", "3", "R", "curl -s https://example.com/api"),
    ("nginx", 990, 1, "root", "0.2", "0.1", "11534336", "86000", "S", "nginx: master process"),
    ("postgres", 1050, 1, "postgres", "1.2", "1.4", "218103808", "85900", "S", "/usr/bin/postgres -D /var/lib/pgsql"),
]
SOCKETS = [
    # kind, process, pid, user, local, peer, proto, state, scope, family
    ("connected", "firefox", "3120", "analyst", "192.0.2.10:44212", "198.51.100.24:443", "tcp", "ESTABLISHED", "external", "ipv4"),
    ("connected", "code", "3300", "analyst", "192.0.2.10:44980", "198.51.100.71:443", "tcp", "ESTABLISHED", "external", "ipv4"),
    ("connected", "curl", "4310", "analyst", "192.0.2.10:45102", "203.0.113.9:443", "tcp", "SYN_SENT", "external", "ipv4"),
    ("listening", "sshd", "780", "root", "0.0.0.0:22", "", "tcp", "LISTEN", "", "ipv4"),
    ("listening", "nginx", "990", "root", "0.0.0.0:443", "", "tcp", "LISTEN", "", "ipv4"),
    ("listening", "postgres", "1050", "postgres", "127.0.0.1:5432", "", "tcp", "LISTEN", "", "ipv4"),
    ("unix", "systemd", "1", "root", "/run/systemd/private", "", "", "", "", "unix"),
    ("unix", "postgres", "1050", "postgres", "/run/postgresql/.s.PGSQL.5432", "", "", "", "", "unix"),
]
APPS = [
    # kind, name, version, own_mb, frees_mb, deps_freed, frees_with, required_by, deps_count, reason
    ("rpm", "firefox", "128.2.0", "241.6", "263.4", 2, "nss, mozilla-filesystem", 0, 38, "User"),
    ("rpm", "postgresql-server", "16.4", "198.2", "221.7", 3, "postgresql, libpq, postgresql-private-libs", 1, 22, "User"),
    ("rpm", "nginx", "1.26.1", "8.4", "12.9", 2, "nginx-filesystem, nginx-core", 0, 14, "User"),
    ("rpm", "glibc", "2.40", "7.2", "7.2", 0, "", 2181, 5, "Group"),
    ("rpm", "openssh-server", "9.8p1", "6.1", "6.1", 0, "", 3, 9, "Group"),
    ("pip", "requests", "2.32.3", "1.4", "1.4", 0, "", 0, 0, ""),
    ("npm", "typescript", "5.6.2", "23.2", "23.2", 0, "", 0, 0, ""),
    ("vscode", "ms-python.python", "2026.6.0", "57.8", "57.8", 0, "", 0, 0, ""),
]
USERS = [
    ("analyst", "1000", "regular", "1", "analyst", "/bin/bash", "/home/analyst", "1", "1"),
    ("root", "0", "root", "1", "root", "/bin/bash", "/root", "1", "1"),
    ("postgres", "26", "system", "0", "postgres", "/sbin/nologin", "/var/lib/pgsql", "1", "1"),
    ("nginx", "986", "system", "0", "nginx", "/sbin/nologin", "/var/lib/nginx", "1", "1"),
]
SERVICES = [
    ("sshd.service", "service", "active", "running", "enabled", "vendor", "", "OpenSSH server daemon"),
    ("nginx.service", "service", "active", "running", "enabled", "vendor", "nginx", "The nginx HTTP server"),
    ("postgresql.service", "service", "active", "running", "enabled", "vendor", "postgres", "PostgreSQL database"),
    ("NetworkManager.service", "service", "active", "running", "enabled", "vendor", "", "Network Manager"),
    ("dnf-makecache.timer", "timer", "active", "waiting", "enabled", "vendor", "", "dnf makecache timer"),
]

# Tetragon lines the real normalization rule will parse, so the events tab shows
# exactly what the rule produces — with invented processes and addresses.
def fake_events() -> list[str]:
    out = []
    base = "2026-07-27T09:%02d:%02dZ"
    def proc(binary, pid, args="", parent="/bin/bash"):
        return {"binary": binary, "pid": pid, "uid": 1000, "arguments": args,
                "cwd": "/home/analyst", "flags": "execve clone",
                "start_time": base % (10, 0), "auid": 1000,
                "exec_id": f"d29ya3N0YXRpb246{pid}", "tid": pid}
    steps = [
        ("exec", "/usr/bin/curl", 4310, "-s https://example.com/api"),
        ("exec", "/usr/bin/grep", 4311, "-i error"),
        ("exit", "/usr/bin/grep", 4311, ""),
        ("exec", "/usr/bin/systemctl", 4315, "restart nginx"),
    ]
    for i, (kind, binary, pid, args) in enumerate(steps):
        key = "process_exec" if kind == "exec" else "process_exit"
        out.append(json.dumps({
            key: {"process": proc(binary, pid, args),
                  "parent": proc("/bin/bash", 4102)},
            "node_name": "workstation", "time": base % (11, i)}))
    for i, (dst, port) in enumerate([("198.51.100.24", 443), ("203.0.113.9", 443),
                                     ("198.51.100.71", 443)]):
        out.append(json.dumps({
            "process_kprobe": {
                "process": proc("/usr/lib64/firefox/firefox", 3120),
                "parent": proc("/bin/bash", 4102),
                "function_name": "tcp_connect",
                "args": [{"sock_arg": {"family": "AF_INET", "protocol": "IPPROTO_TCP",
                                       "saddr": "192.0.2.10", "daddr": dst,
                                       "sport": 44212 + i, "dport": port,
                                       "state": "TCP_SYN_SENT"}}]},
            "node_name": "workstation", "time": base % (12, i)}))
    for i, path in enumerate(["/etc/shadow", "/etc/ssh/sshd_config", "/etc/sudoers"]):
        out.append(json.dumps({
            "process_kprobe": {
                "process": proc("/usr/sbin/sshd", 780),
                "parent": proc("/usr/lib/systemd/systemd", 1),
                "function_name": "security_file_permission",
                "args": [{"file_arg": {"path": path, "permission": "-rw-------"}},
                         {"int_arg": 4}]},
            "node_name": "workstation", "time": base % (13, i)}))
    return out * 12          # a page worth of rows


def build():
    from core.store import Store
    from core.eventstore import EventStore
    st = Store()
    def table(name, cols, rows):
        st.replace_table(name, [dict(zip(cols, r)) for r in rows])
    table("processes",
          ["name", "pid", "ppid", "user", "cpu_pct", "mem_pct", "rss",
           "elapsed_sec", "state", "cmdline"], PROCESSES)
    table("sockets",
          ["kind", "process", "pid", "user", "local", "peer", "protocol_name",
           "state", "remote_scope", "family_name"], SOCKETS)
    table("app_links",
          ["kind", "name", "version", "own_mb", "frees_mb", "deps_freed",
           "frees_with", "required_by", "deps_count", "reason"], APPS)
    table("users",
          ["username", "uid", "kind", "can_login", "primary_group", "shell",
           "home", "uid_shared", "home_exists"], USERS)
    table("services",
          ["id", "kind", "active_state", "sub_state", "unit_file_state",
           "origin", "run_as", "description"], SERVICES)
    st.close()

    ev = EventStore()
    ev.apply_views()
    ev.append(fake_events())
    ev.materialize()
    ev.close()


def shoot():
    from PySide6.QtGui import QGuiApplication
    from PySide6.QtQml import QQmlApplicationEngine
    from PySide6.QtQuick import QQuickWindow
    from PySide6.QtCore import QUrl, QTimer, QMetaObject, Qt, Q_ARG
    from backend import Backend

    os.makedirs(SHOTS, exist_ok=True)
    app = QGuiApplication(sys.argv)
    be = Backend()
    eng = QQmlApplicationEngine()
    eng.rootContext().setContextProperty("backend", be)
    eng.addImportPath(f"{V1}/ui")
    eng.load(QUrl.fromLocalFile(f"{V1}/ui/Main.qml"))
    win = eng.rootObjects()[0]
    win.resize(1400, 860)

    def nav(s):
        QMetaObject.invokeMethod(win, "open", Qt.DirectConnection,
                                 Q_ARG("QVariant", s))

    def shot(name):
        QQuickWindow.grabWindow(win).save(os.path.join(SHOTS, f"{name}.png"))
        print("  wrote", name + ".png")

    plan = [(700, lambda: nav("state")), (1500, lambda: shot("data")),
            (1800, lambda: nav("dashboards")), (2600, lambda: shot("dashboard")),
            (2900, lambda: nav("pipelines")), (3700, lambda: shot("pipelines")),
            (4000, lambda: nav("expertise")), (4800, lambda: shot("expertise")),
            (5100, app.quit)]
    for ms, fn in plan:
        QTimer.singleShot(ms, fn)
    app.exec()
    be.events.close()
    be.store.close()


if __name__ == "__main__":
    print(f"synthetic data in {SANDBOX}")
    try:
        build()
        shoot()
    finally:
        shutil.rmtree(SANDBOX, ignore_errors=True)
        print("sandbox removed — no data of this machine was involved")

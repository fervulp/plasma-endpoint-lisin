#!/usr/bin/env python3
"""Sentinel ingest pipeline: source → normalize (VRL) → SQLite.

Reads systemd-journal entries, normalizes each into the unified schema,
and writes them to the same SQLite `events` table the Qt app reads.

Normalization is defined once, in VRL (normalize.vrl). If the Vector/`vrl`
binary is installed it is used to run that program; otherwise a Python port
(`normalize_py`) that mirrors it exactly is used, so the pipeline works out
of the box and gains the real VRL engine when you install it.

Usage:
    ingest.py [--db PATH] [--since "-2 days"] [--follow]

    --follow   keep reading new entries (poll every 2s via a saved cursor)
"""
import argparse
import json
import os
import shutil
import subprocess
import sqlite3
import sys
import time

DEFAULT_DB = os.path.join(
    os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")),
    "sentinel", "sentinel.db")
HERE = os.path.dirname(os.path.abspath(__file__))
VRL_FILE = os.path.join(HERE, "normalize.vrl")

SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY, ts REAL, event_category TEXT, event_action TEXT,
    event_type TEXT, event_outcome TEXT, module TEXT, severity INTEGER,
    host TEXT, user_name TEXT, user_id TEXT, process_name TEXT,
    process_pid INTEGER, process_ppid INTEGER, process_exe TEXT,
    process_cmdline TEXT, parent_name TEXT, source_ip TEXT, source_port INTEGER,
    dest_ip TEXT, dest_port INTEGER, transport TEXT, direction TEXT,
    file_path TEXT, file_action TEXT, package_name TEXT, package_version TEXT,
    related_user TEXT, message TEXT, raw TEXT, dedup_key TEXT UNIQUE
);
CREATE INDEX IF NOT EXISTS ix_events_ts ON events(ts);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
"""

COLUMNS = ["ts", "event_category", "event_action", "event_type",
           "event_outcome", "module", "severity", "host", "user_name",
           "user_id", "process_name", "process_pid", "message", "raw",
           "dedup_key"]

PRIV = {"sudo", "pkexec", "su", "polkitd"}
SESSION = {"sshd", "systemd-logind", "login", "gdm", "sddm"}
IAM = {"useradd", "userdel", "usermod", "groupadd", "passwd"}
NET = {"NetworkManager", "wpa_supplicant", "systemd-resolved", "dhclient"}
PKG = {"dnf", "rpm", "packagekitd", "dnf5"}


def normalize_py(e):
    """Python mirror of normalize.vrl (used when Vector/vrl is absent)."""
    ident = str(e.get("SYSLOG_IDENTIFIER") or e.get("_COMM") or "")
    comm = str(e.get("_COMM") or e.get("SYSLOG_IDENTIFIER") or "")
    try:
        prio = int(e.get("PRIORITY", 6))
    except (ValueError, TypeError):
        prio = 6
    try:
        ts = int(e.get("_SOURCE_REALTIME_TIMESTAMP")
                 or e.get("__REALTIME_TIMESTAMP") or 0) / 1_000_000.0
    except (ValueError, TypeError):
        ts = time.time()

    category, action, severity = "process", "log", 10
    msg = str(e.get("MESSAGE") or "")
    if ident in PRIV:
        category, action, severity = "privilege", "privileged_command", 55
    elif ident in SESSION:
        category, action, severity = "session", "session_activity", 15
    elif ident in IAM:
        category, action, severity = "iam", "account_change", 45
    elif ident in NET:
        category, action, severity = "network", "network_activity", 15
    elif ident in PKG:
        category, action, severity = "package", "package_activity", 30
    elif ident in ("auditd", "kernel") and "denied" in msg:
        category, action, severity = "file", "access_denied", 50
    if prio <= 3:
        severity += 25

    try:
        pid = int(e.get("_PID", 0))
    except (ValueError, TypeError):
        pid = 0
    return {
        "ts": ts, "event_category": category, "event_action": action,
        "event_type": "info",
        "event_outcome": "failure" if prio <= 3 else "success",
        "module": "journal", "severity": severity,
        "host": str(e.get("_HOSTNAME") or ""), "user_name": "",
        "user_id": str(e.get("_UID") or ""), "process_name": comm,
        "process_pid": pid, "message": msg,
        "raw": json.dumps(e, ensure_ascii=False),
        "dedup_key": "%s|%s|%s" % (e.get("__CURSOR", ""), ident, ts),
    }


def vrl_binary():
    for name in ("vrl", "vector"):
        if shutil.which(name):
            return name
    return None


def normalize_vrl(events, binary):
    """Run normalize.vrl over events via the vrl/vector CLI, one JSON per line."""
    program = open(VRL_FILE).read()
    inp = "\n".join(json.dumps(e) for e in events)
    if binary == "vrl":
        cmd = ["vrl", "--program", VRL_FILE]
    else:  # vector vrl REPL-style is not scriptable; fall back
        return None
    try:
        out = subprocess.run(cmd, input=inp, capture_output=True,
                             text=True, timeout=30)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None
    if out.returncode != 0:
        sys.stderr.write("vrl failed, using Python normalizer: %s\n" % out.stderr[:200])
        return None
    res = []
    for line in out.stdout.splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                res.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return res


def read_journal(conn, since, follow_cursor):
    cmd = ["journalctl", "-o", "json", "--no-pager"]
    if follow_cursor:
        cmd += ["--after-cursor=" + follow_cursor]
    else:
        cmd += ["--since", since]
    try:
        raw = subprocess.run(cmd, capture_output=True, text=True,
                             timeout=60).stdout
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return [], follow_cursor
    events, last = [], follow_cursor
    for line in raw.splitlines():
        if not line.startswith("{"):
            continue
        try:
            j = json.loads(line)
        except json.JSONDecodeError:
            continue
        events.append(j)
        if "__CURSOR" in j:
            last = j["__CURSOR"]
    return events, last


def write_events(conn, rows):
    for r in rows:
        r.setdefault("dedup_key", None)
    cols = ",".join(COLUMNS)
    ph = ",".join("?" for _ in COLUMNS)
    data = [[r.get(c) for c in COLUMNS] for r in rows]
    cur = conn.executemany(
        "INSERT OR IGNORE INTO events(%s) VALUES(%s)" % (cols, ph), data)
    return cur.rowcount


def run_once(conn, since, binary):
    cursor = None
    row = conn.execute("SELECT value FROM meta WHERE key='journal_cursor'").fetchone()
    if row:
        cursor = row[0]
    events, last = read_journal(conn, since, cursor)
    if not events:
        return 0
    rows = normalize_vrl(events, binary) if binary else None
    if rows is None:
        rows = [normalize_py(e) for e in events]
    n = write_events(conn, rows)
    if last:
        conn.execute("INSERT INTO meta(key,value) VALUES('journal_cursor',?) "
                     "ON CONFLICT(key) DO UPDATE SET value=excluded.value", (last,))
    conn.commit()
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--since", default="-2 days")
    ap.add_argument("--follow", action="store_true")
    args = ap.parse_args()

    os.makedirs(os.path.dirname(args.db), exist_ok=True)
    conn = sqlite3.connect(args.db)
    conn.executescript(SCHEMA)
    binary = vrl_binary()
    engine = binary or "python (VRL mirror)"
    sys.stderr.write("normalizer: %s\n" % engine)

    n = run_once(conn, args.since, binary)
    print(json.dumps({"inserted": n, "engine": engine}))
    if args.follow:
        try:
            while True:
                time.sleep(2)
                n = run_once(conn, args.since, binary)
                if n:
                    print(json.dumps({"inserted": n}))
        except KeyboardInterrupt:
            pass
    conn.close()


if __name__ == "__main__":
    main()

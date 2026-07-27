"""Run osquery point-in-time queries and return rows as list[dict].

osquery IS "the system as SQL tables": one query returns clean, typed columns,
and joins across its virtual tables (processes ⋈ listening_ports on pid) are
done inside osquery — so much of v0's hand-written normalization disappears.

The binary is resolved from env / known locations, never hardcoded, so the same
code works for the vendored dev install, a system RPM, and a root deployment.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

_CANDIDATES = [
    os.environ.get("LISIN_OSQUERY"),
    os.path.expanduser("~/.local/opt/osquery/bin/osqueryi"),
    "/usr/bin/osqueryi",
    "/opt/osquery/bin/osqueryi",
]


def binary() -> str:
    for c in _CANDIDATES:
        if c and Path(c).exists():
            return c
    found = shutil.which("osqueryi")
    if found:
        return found
    raise RuntimeError(
        "osqueryi not found — set LISIN_OSQUERY or install osquery"
    )


_FLAGS = ["--json", "--disable_events", "--disable_audit"]


def run(sql: str, timeout: int = 30) -> list[dict]:
    """Execute one osquery SQL statement ephemerally (no daemon, no scheduled
    events) and return its rows. Convenient for tests and one-off reads; the
    collector uses run_to_file() instead — see below."""
    out = subprocess.run(
        [binary(), *_FLAGS, sql],
        capture_output=True, text=True, timeout=timeout,
    )
    if out.returncode != 0:
        raise RuntimeError(f"osquery error: {out.stderr.strip()[:500]}")
    txt = out.stdout.strip()
    return json.loads(txt) if txt else []


def run_to_file(sql: str, timeout: int = 30) -> str:
    """Same query, but osquery's JSON goes STRAIGHT TO A FILE and the path is
    returned — the rows are never built as Python objects.

    Why: the collector's job is to move a result set into DuckDB, and DuckDB can
    read that JSON itself. Parsing it in Python and inserting row by row cost
    ~4 s for 4000 rows; handing DuckDB the file costs ~26 ms (measured, 155x).
    With three dozen sources that was the difference between a 75 s collection
    cycle and a 13 s one. The caller deletes the file.
    """
    fd, path = tempfile.mkstemp(prefix="lisin-osq-", suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            out = subprocess.run(
                [binary(), *_FLAGS, sql],
                stdout=f, stderr=subprocess.PIPE, text=True, timeout=timeout,
            )
        if out.returncode != 0:
            raise RuntimeError(f"osquery error: {out.stderr.strip()[:500]}")
        return path
    except Exception:
        try:
            os.unlink(path)
        except OSError:
            pass
        raise

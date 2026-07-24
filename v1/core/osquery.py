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


def run(sql: str, timeout: int = 30) -> list[dict]:
    """Execute one osquery SQL statement ephemerally (no daemon, no scheduled
    events) and return its rows."""
    out = subprocess.run(
        [
            binary(),
            "--json",
            "--disable_events",
            "--disable_audit",
            sql,
        ],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if out.returncode != 0:
        raise RuntimeError(f"osquery error: {out.stderr.strip()[:500]}")
    txt = out.stdout.strip()
    return json.loads(txt) if txt else []

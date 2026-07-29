"""The second kind of entry point: a COMMAND that prints tab-separated rows.

osquery answers most questions about a Linux box, but not all of them: package
dependencies, `systemctl --user` units, firewalld zones and anything a vendor
tool alone knows have no osquery table. v0 collected those with shell commands,
and refusing to do so in v1 would mean losing real inventory to keep a rule
about the collector.

So an input may declare `kind: command` instead of an osquery query. The contract
is deliberately narrow, which is what keeps it fast and safe to parse:

    kind: command
    tsv_columns: [package, relation, name]   # names, in output order
    command: |
      rpm -qa --qf '[%{NAME}\trequires\t%{REQUIRENAME}\n]'

The command's stdout goes straight to a file and DuckDB reads it as TSV — the
rows never become Python objects, exactly as with the osquery path. The command
is expertise, so it is trusted the same way an osquery query is; it runs under
the collector's own user, with a timeout, and its stderr is only used for the
error message.
"""
from __future__ import annotations

import os
import subprocess
import tempfile


def run_to_file(command: str, timeout: int = 60) -> str:
    """Run a shell command, capture stdout to a temp file, return the path."""
    fd, path = tempfile.mkstemp(prefix="lisin-cmd-", suffix=".tsv")
    try:
        with os.fdopen(fd, "w") as f:
            out = subprocess.run(
                ["/bin/bash", "-c", command],
                stdout=f, stderr=subprocess.PIPE, text=True, timeout=timeout,
            )
        # A non-zero exit is NOT automatically a failure here: `grep` finding
        # nothing and a tool warning about one unreadable file both exit non-zero
        # while the output is perfectly good. Fail only when nothing was produced.
        if out.returncode != 0 and os.path.getsize(path) == 0:
            raise RuntimeError(
                f"command failed ({out.returncode}): {out.stderr.strip()[:400]}"
            )
        return path
    except Exception:
        try:
            os.unlink(path)
        except OSError:
            pass
        raise

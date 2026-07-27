"""Tail the Tetragon JSON export as a durable stream.

Tetragon (root systemd service) writes one JSON event per line to
/var/log/tetragon/tetragon.log and rotates it by size (10 MB x 5 backups). The
file IS the buffer: this reader keeps a byte cursor (offset + inode) so a restart
of our app resumes exactly where it left off — no events replayed, none skipped
during normal operation.

Boundary: the log is root-owned but world-readable (export-file-perm=644), which
is the only bridge our user-space app needs. When the app itself runs as root
(future, for enforcement) the perm no longer matters.

Rotation: detected by inode change or the file shrinking below the saved offset;
on either we resume from the head of the new active file. A tiny gap is possible
only if the app is DOWN across a rotation (the newest file's tail was drained on
the previous cycle, since we read every few seconds and rotation happens at
10 MB ~ tens of minutes of data) — noted honestly, not hidden.
"""
from __future__ import annotations

import json
import os
from pathlib import Path


def _log_path() -> str:
    return os.environ.get("LISIN_TETRAGON_LOG", "/var/log/tetragon/tetragon.log")


def _cursor_path() -> Path:
    base = os.environ.get("LISIN_DATA_DIR") or os.path.expanduser(
        "~/.local/share/lisin"
    )
    p = Path(base)
    p.mkdir(parents=True, exist_ok=True)
    return p / "tetragon.cursor"


class TetragonReader:
    def __init__(self, log_path: str | None = None, cursor_path: str | None = None):
        self.log = log_path or _log_path()
        self.cursor = Path(cursor_path) if cursor_path else _cursor_path()
        self.offset = 0
        self.inode = 0
        self._load_cursor()

    def _load_cursor(self) -> None:
        try:
            d = json.loads(self.cursor.read_text())
            self.offset = int(d.get("offset", 0))
            self.inode = int(d.get("inode", 0))
        except Exception:
            self.offset, self.inode = 0, 0

    def _save_cursor(self) -> None:
        try:
            self.cursor.write_text(
                json.dumps({"offset": self.offset, "inode": self.inode})
            )
        except Exception:
            pass

    def available(self) -> bool:
        return os.access(self.log, os.R_OK)

    def read_new(self, max_bytes: int = 8 * 1024 * 1024) -> list[str]:
        """Return complete new lines since the last cursor. A trailing partial
        line (mid-write) is NOT returned and the cursor stops before it, so it is
        re-read whole next time."""
        try:
            st = os.stat(self.log)
        except OSError:
            return []
        ino = st.st_ino

        # rotation / truncation -> resume from head of the current file
        if ino != self.inode or st.st_size < self.offset:
            self.offset = 0
            self.inode = ino

        if st.st_size <= self.offset:
            return []

        lines: list[str] = []
        try:
            with open(self.log, "rb") as f:
                f.seek(self.offset)
                chunk = f.read(max_bytes)
        except OSError:
            return []

        # keep only up to the last newline; stash position before any partial tail
        nl = chunk.rfind(b"\n")
        if nl < 0:
            return []  # no complete line yet
        consumed = nl + 1
        text = chunk[:consumed].decode("utf-8", "replace")
        for ln in text.splitlines():
            if ln.strip():
                lines.append(ln)

        self.offset += consumed
        self.inode = ino
        self._save_cursor()
        return lines

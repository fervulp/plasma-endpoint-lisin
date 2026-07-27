"""The query service: one process owns the databases, everyone else asks it.

WHY THIS EXISTS. DuckDB takes an EXCLUSIVE lock on a database file. Measured
here, not assumed: while a process holds a file read-write, a second process
cannot open it at all — not even read-only (multiple readers are fine, but only
when there is no writer). So "the agent writes and the interface reads" cannot be
two processes sharing a file; the owner has to answer for it.

That is what this is. The owner keeps the databases and listens on a Unix socket
in the data directory; anything else — a second window, the test suite, a script
— connects and asks. Measured cost of crossing the boundary: +0.1 ms on a count,
+0.3 ms on a page of the feed, +0.9 ms on the whole process list, +3 ms on a
1000-row page. That is inside one frame, which is why this is affordable at all.

JSON, NOT PICKLE, on the wire. Pickle was 3 ms faster on the largest payload and
is out of the question: unpickling executes code, so anything that could reach
the socket would run as this user. In a tool whose job is to notice that kind of
thing, the encoding does not get to be the hole.

The socket is created 0600 in the user's own data directory, and only SELECT-shape
reads are served (the same guard the SQL page uses); writes stay with the owner.
"""
from __future__ import annotations

import json
import os
import socket
import struct
import threading

from .db import DuckDB, data_dir, select_only

SOCKET_NAME = "query.sock"
# a reply is bounded so a runaway query cannot be turned into an allocation
MAX_FRAME = 256 * 1024 * 1024


def socket_path() -> str:
    return os.path.join(data_dir(), SOCKET_NAME)


def send(sock, payload: dict) -> None:
    blob = json.dumps(payload, default=str).encode()
    sock.sendall(struct.pack("!I", len(blob)) + blob)


def recv(sock) -> dict:
    head = _exact(sock, 4)
    (n,) = struct.unpack("!I", head)
    if n > MAX_FRAME:
        raise ValueError(f"frame of {n} bytes refused")
    return json.loads(_exact(sock, n))


def _exact(sock, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("the other side closed")
        buf += chunk
    return buf


class QueryService:
    """Serves reads of the owner's databases over a Unix socket.

    `stores` maps a name the client asks for ("state", "events") to the object
    that owns it. `hooks` are named callables the owner is willing to run on a
    client's behalf — used for the few things only the owner can do (re-applying
    an edited event rule), never for arbitrary code."""

    def __init__(self, stores: dict[str, DuckDB], hooks: dict | None = None,
                 path: str | None = None):
        self.stores = stores
        self.hooks = hooks or {}
        self.path = path or socket_path()
        self._srv: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self.error = ""

    # ---------------------------------------------------------------- serving
    def start(self) -> bool:
        """Bind and serve in a background thread. Returns whether it is up — a
        service that cannot bind is not fatal (the app still works, it is simply
        alone), so the reason is kept rather than raised."""
        try:
            # A socket left by a killed owner would otherwise block the bind
            # forever. Removing it is safe here: this process holds the DATABASE
            # lock, so no other owner can exist.
            if os.path.exists(self.path):
                os.unlink(self.path)
            srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            srv.bind(self.path)
            os.chmod(self.path, 0o600)
            srv.listen(8)
            self._srv = srv
        except OSError as e:
            self.error = str(e)
            return False
        self._thread = threading.Thread(target=self._accept, daemon=True)
        self._thread.start()
        return True

    def stop(self) -> None:
        if self._srv is not None:
            try:
                self._srv.close()
            except OSError:
                pass
            self._srv = None
        try:
            os.unlink(self.path)
        except OSError:
            pass

    def _accept(self) -> None:
        while self._srv is not None:
            try:
                conn, _ = self._srv.accept()
            except OSError:
                return                      # stopped
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _serve(self, conn) -> None:
        with conn:
            while True:
                try:
                    req = recv(conn)
                except Exception:           # noqa: BLE001 — client went away
                    return
                try:
                    reply = self.handle(req)
                except Exception as e:      # noqa: BLE001 — a bad request must
                    reply = {"error": str(e)}   # not take the owner down
                try:
                    send(conn, reply)
                except Exception:           # noqa: BLE001
                    return

    # --------------------------------------------------------------- requests
    def handle(self, req: dict) -> dict:
        op = str(req.get("op", ""))
        if op == "ping":
            return {"ok": True, "pid": os.getpid(),
                    "databases": sorted(self.stores)}
        if op == "hook":
            name = str(req.get("name", ""))
            fn = self.hooks.get(name)
            if fn is None:
                return {"error": f"no such hook: {name}"}
            return {"result": fn(*(req.get("args") or []))}
        db = self.stores.get(str(req.get("db", "state")))
        if db is None:
            return {"error": f"no such database: {req.get('db')}"}
        if op == "tables":
            return {"result": db.tables()}
        if op == "columns":
            return {"result": db.columns(str(req.get("name", "")))}
        if op == "row_count":
            return {"result": db.row_count(str(req.get("name", "")))}
        if op in ("fetch", "query"):
            sql = str(req.get("sql", ""))
            # THE SAME GUARD THE SQL PAGE USES. A client may read; it may not
            # write, and the owner is the only writer by construction.
            if not select_only(sql):
                return {"error": "only a single SELECT may be served"}
            args = list(req.get("args") or [])
            mx = req.get("max_rows", None)
            return db.fetch(sql, args, None if mx is None else int(mx))
        return {"error": f"unknown op: {op}"}

"""The client side of the query service: a database that lives in another process.

RemoteDB answers the same calls as the local store (tables, columns, row_count,
query, fetch), so whatever reads a store does not need to know which side of the
socket it is on. Everything else — collection, normalization, retention — stays
with the owner, because those are writes and there is exactly one writer.

The connection is per-thread. A socket is a stream: two threads writing requests
into the same one interleave their frames and each gets the other's answer. The
Qt slots and the refresh timer are different threads, so this is not theoretical.
"""
from __future__ import annotations

import socket
import threading

from .service import recv, send, socket_path


class ServiceUnavailable(RuntimeError):
    pass


def probe(path: str | None = None, timeout: float = 1.0) -> dict:
    """Is somebody serving? Returns the owner's answer, or {} if nobody is.
    Used to decide whether this process owns the databases or asks for them."""
    path = path or socket_path()
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(path)
        send(s, {"op": "ping"})
        reply = recv(s)
        s.close()
        return reply if reply.get("ok") else {}
    except (OSError, ValueError):
        return {}


class RemoteDB:
    """One of the owner's databases, reached over the socket."""

    def __init__(self, name: str, path: str | None = None, timeout: float = 30.0):
        self.name = name
        self.path = path or socket_path()
        self.timeout = timeout
        self._local = threading.local()

    # ------------------------------------------------------------- plumbing
    def _sock(self):
        s = getattr(self._local, "sock", None)
        if s is None:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(self.timeout)
            try:
                s.connect(self.path)
            except OSError as e:
                raise ServiceUnavailable(f"no agent to ask: {e}") from e
            self._local.sock = s
        return s

    def _ask(self, req: dict) -> dict:
        req = dict(req, db=self.name)
        for attempt in (1, 2):        # one retry: the owner may have restarted
            try:
                s = self._sock()
                send(s, req)
                reply = recv(s)
                break
            except (OSError, ValueError, ConnectionError) as e:
                self._drop()
                if attempt == 2:
                    raise ServiceUnavailable(str(e)) from e
        if reply.get("error"):
            raise RuntimeError(reply["error"])
        return reply

    def _drop(self) -> None:
        s = getattr(self._local, "sock", None)
        if s is not None:
            try:
                s.close()
            except OSError:
                pass
            self._local.sock = None

    # --------------------------------------------------- the store's surface
    def tables(self) -> list[str]:
        return list(self._ask({"op": "tables"})["result"])

    def columns(self, name: str) -> list[str]:
        return list(self._ask({"op": "columns", "name": name})["result"])

    def row_count(self, name: str) -> int:
        return int(self._ask({"op": "row_count", "name": name})["result"])

    def fetch(self, sql: str, args=None, max_rows=None) -> dict:
        return self._ask({"op": "fetch", "sql": sql, "args": list(args or []),
                          "max_rows": max_rows})

    def query(self, sql: str, params=None, max_rows: int = 1000):
        r = self.fetch(sql, params, max_rows)
        return r["columns"], r["rows"], r["truncated"]

    def hook(self, name: str, *args):
        """Ask the owner to do one of the few things only it can (re-applying an
        edited event rule). Named, not arbitrary — the list is the owner's."""
        return self._ask({"op": "hook", "name": name, "args": list(args)})["result"]

    def close(self) -> None:
        self._drop()

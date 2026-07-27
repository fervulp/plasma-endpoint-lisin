"""Shared DuckDB plumbing for the state store and the event store.

Both stores are a DuckDB connection guarded by one lock (a connection is not
thread-safe: the background collector writes while the UI reads). The identifier
quoting, the SELECT-only guard, the data directory, the YAML-rule loader and the
iterative view-application engine were each copied into store.py / eventstore.py
/ views.py / backend.py and drifted; they live here now so there is one of each.

Vendored duckdb is added to sys.path here (import core.db before duckdb), so it
loads even under PYTHONNOUSERSITE=1 — that flag only disables the automatic
user-site; an explicit path still works.
"""
from __future__ import annotations

import os
import re
import time
import sys
import threading
from pathlib import Path

_VENDOR = Path(__file__).resolve().parent.parent / "vendor"
if _VENDOR.is_dir() and str(_VENDOR) not in sys.path:
    sys.path.insert(0, str(_VENDOR))
import duckdb  # noqa: E402
import yaml  # noqa: E402


def data_dir() -> Path:
    """Where our on-disk state lives. Dev: XDG; root/RPM: LISIN_DATA_DIR. Never a
    hardcoded $HOME, so the RPM build and a root deployment reuse the same code."""
    base = os.environ.get("LISIN_DATA_DIR") or os.path.expanduser(
        "~/.local/share/lisin"
    )
    p = Path(base)
    p.mkdir(parents=True, exist_ok=True)
    return p


def ident(name: str) -> str:
    """Quote an identifier the SQL way: an embedded quote is DOUBLED, not deleted
    (deleting it silently pointed at a different, usually non-existent, column).
    Names come from our YAML, but a string is never trusted directly in SQL."""
    s = str(name)
    if not s:
        raise ValueError("empty identifier")
    return '"' + s.replace('"', '""') + '"'


# View / query bodies are trusted expertise, but guard anyway: one SELECT, no
# DDL/DML. (ATTACH/COPY/etc. are blocked even though the engine may attach
# internally — that path does not go through this guard.)
FORBIDDEN = re.compile(
    r"\b(attach|detach|copy|install|load|pragma|insert|update|delete|drop|"
    r"alter|call|export|import)\b",
    re.I,
)


def select_only(sql: str) -> bool:
    """True if sql is a single SELECT/WITH statement with no DDL/DML keywords.

    STRING LITERALS AND COMMENTS ARE REMOVED BEFORE THE KEYWORD SCAN. Without
    that, a perfectly good rule was refused because a VALUE contained a keyword
    (`THEN 'delete'`, `LIKE '%copy%'`) or because a literal held a semicolon — and
    the refusal was silent, so the rule simply stopped taking effect."""
    body = re.sub(r"/\*.*?\*/", " ", sql, flags=re.S)   # block comments
    body = re.sub(r"--[^\n]*", " ", body)               # line comments
    body = re.sub(r"'(?:''|[^'])*'", "''", body)        # string literals
    stmts = [s for s in body.split(";") if s.strip()]
    if len(stmts) != 1:
        return False
    head = stmts[0].strip().lower()
    if not (head.startswith("select") or head.startswith("with")):
        return False
    return FORBIDDEN.search(stmts[0]) is None


def load_yaml_dir(d: Path) -> list[dict]:
    """Load every *.yaml in a directory as a dict, each stamped with its _file
    path. A file that fails to parse becomes an empty dict rather than aborting
    the whole load."""
    out: list[dict] = []
    if d.is_dir():
        for f in sorted(d.glob("*.yaml")):
            try:
                spec = yaml.safe_load(f.read_text()) or {}
            except Exception:  # noqa: BLE001 — one bad file must not kill the rest
                spec = {}
            spec["_file"] = str(f)
            out.append(spec)
    return out


# A read the interface makes must not cost more than a few frames. Above this,
# the derivation is stored instead of recomputed (see apply_views).
SLOW_VIEW_MS = 60


def apply_views(con, specs: list[dict]) -> list[dict]:
    """CREATE OR REPLACE each {name, sql} view, in iterative passes so a view may
    reference another created later. Returns per-view status (numbers, not prose).

    AN EXPENSIVE DERIVATION IS STORED, NOT RECOMPUTED. A view is recomputed on
    every read, which is right for a join that costs nothing — but the dependency
    footprint walks the package graph with a recursive CTE, and measured on this
    machine that is 181 ms for a count and 171 ms for one page. Both run on the
    GUI thread, on every tab switch and every snapshot push, which is the
    stutter. So each derivation is TIMED as it is created, and a slow one is
    stored as a table instead (177 ms, once per collection cycle, on the
    collector's thread). No rule declares this and no name is special-cased: the
    engine measures, because a derivation's cost depends on the machine's data,
    not on what its author expected.

    A stored derivation is exactly as fresh as its inputs — every base table here
    is REPLACEd wholesale each cycle and the derivations are rebuilt right after,
    in the same lock. If the swap fails (another view already depends on this
    name), the view is kept and that is reported rather than hidden."""
    # Which names WE stored as tables on an earlier pass. Needed because
    # CREATE OR REPLACE VIEW refuses to replace a table, so a stored derivation
    # has to be dropped before it can be re-created — and only ours may be
    # dropped: a sensor's table must never be removed by the derivation layer,
    # whatever a rule happens to be called.
    con.execute("CREATE TABLE IF NOT EXISTS _derived (name VARCHAR PRIMARY KEY)")
    ours = {r[0] for r in con.execute("SELECT name FROM _derived").fetchall()}

    status: list[dict] = []
    pending = list(specs)
    for _ in range(len(pending) + 1):
        if not pending:
            break
        still = []
        for v in pending:
            name, sql = v.get("name"), v.get("sql", "")
            if not select_only(sql):
                status.append({"view": name, "error": "not a single SELECT"})
                continue
            try:
                # A name that appears in the derivation rules is owned by this
                # layer, so an existing table under it is our own earlier store
                # and may be replaced. (That inputs and derivations never share a
                # name is asserted in the tests, not assumed here.)
                # (DROP TABLE IF EXISTS is not enough: on a VIEW of the same
                # name DuckDB raises a type mismatch rather than skipping.)
                if con.execute("SELECT 1 FROM duckdb_tables() WHERE table_name = ?",
                               [name]).fetchone():
                    con.execute(f"DROP TABLE {ident(name)}")
                con.execute(f"CREATE OR REPLACE VIEW {ident(name)} AS {sql}")
                t0 = time.perf_counter()
                if name in ours:
                    # already known to be slow: build the table straight away
                    # rather than pay the measurement a second time every cycle
                    ms, stored = None, True
                else:
                    ms = None
                    rows = con.execute(
                        f"SELECT count(*) FROM {ident(name)}"
                    ).fetchone()[0]
                    ms = (time.perf_counter() - t0) * 1000
                    stored = ms >= SLOW_VIEW_MS
                if stored:
                    try:
                        con.execute(f"DROP VIEW IF EXISTS {ident(name)}")
                        con.execute(f"CREATE OR REPLACE TABLE {ident(name)} AS {sql}")
                        con.execute("INSERT OR REPLACE INTO _derived VALUES (?)", [name])
                    except Exception as e:  # noqa: BLE001 — a dependent object
                        con.execute(f"CREATE OR REPLACE VIEW {ident(name)} AS {sql}")
                        con.execute("DELETE FROM _derived WHERE name = ?", [name])
                        status.append({"view": name, "error": "", "stored": False,
                                       "note": f"cannot store: {e}"})
                        continue
                elif name in ours:
                    con.execute("DELETE FROM _derived WHERE name = ?", [name])
                rows = con.execute(f"SELECT count(*) FROM {ident(name)}").fetchone()[0]
                build = (time.perf_counter() - t0) * 1000
                status.append({"view": name, "error": "", "rows": rows,
                               "ms": round(ms if ms is not None else build),
                               "stored": stored})
            except Exception as e:  # noqa: BLE001 — maybe an unmet dependency
                v["_err"] = str(e)
                still.append(v)
        if len(still) == len(pending):  # no progress → report and stop
            status.extend(
                {"view": v.get("name"), "error": v.get("_err", "unresolved")}
                for v in still
            )
            break
        pending = still
    return status


class DuckDB:
    """A DuckDB connection guarded by one RLock. Subclasses add their own schema
    and write methods; the shared read path and lifecycle live here so the state
    store and the event store cannot drift."""

    # This is an agent on somebody's laptop, not a warehouse: DuckDB will happily
    # take most of the machine's RAM for buffers if left alone. A cap keeps the
    # app's footprint honest; queries still work, DuckDB just spills instead.
    # 256 MB looked like the right "lightweight agent" number and was wrong: it is
    # below what normalizing a backlog of events costs, so the ingest died with
    # OutOfMemory and events silently stopped. The cap is a CEILING for peaks, not
    # a target for steady state (which is far lower), and DuckDB may spill to the
    # temp directory rather than fail. 512 MB is far above what the steady
    # state needs (measured: 79 MB peak for a normalization pass over the
    # staging window) and above what one 5 000-row batch costs.
    MEMORY_LIMIT = os.environ.get("LISIN_DB_MEMORY", "512MB")
    THREADS = os.environ.get("LISIN_DB_THREADS", "2")

    def __init__(self, path: str):
        self.path = path
        self._con = duckdb.connect(path)
        # a DuckDB connection is not thread-safe; serialize every access.
        self._lock = threading.RLock()
        for stmt in (f"SET memory_limit='{self.MEMORY_LIMIT}'",
                     f"SET threads={self.THREADS}",
                     # A bulk INSERT ... SELECT buffers the whole result to keep
                     # the rows in their original order. Normalizing a backlog of
                     # events that way exceeded the memory cap and the ingest
                     # stopped with an OutOfMemory error. Nothing here depends on
                     # physical row order — every read is ORDER BY seq — so the
                     # buffering is pure cost.
                     "SET preserve_insertion_order=false",
                     # let a big operation spill instead of failing
                     f"SET temp_directory='{data_dir()}'"):
            try:
                self._con.execute(stmt)
            except Exception:  # noqa: BLE001 — an old DuckDB may not know a knob
                pass

    def close(self) -> None:
        with self._lock:
            self._con.close()

    def tables(self) -> list[str]:
        return [
            r[0]
            for r in self._con.execute(
                "SELECT table_name FROM information_schema.tables "
                "WHERE table_schema = 'main' ORDER BY table_name"
            ).fetchall()
        ]

    def columns(self, name: str) -> list[str]:
        return [
            r[0]
            for r in self._con.execute(
                "SELECT column_name FROM information_schema.columns "
                "WHERE table_name = ? ORDER BY ordinal_position",
                [name],
            ).fetchall()
        ]

    def row_count(self, name: str) -> int:
        return self._con.execute(
            f"SELECT count(*) FROM {ident(name)}"
        ).fetchone()[0]

    def query(self, sql: str, params=None, max_rows: int = 1000):
        """Run a read query for the UI. Returns (columns, rows, truncated)."""
        cur = self._con.cursor()
        cur.execute(sql, params or [])
        cols = [d[0] for d in cur.description]
        fetched = cur.fetchmany(max_rows + 1)
        truncated = len(fetched) > max_rows
        return cols, [list(r) for r in fetched[:max_rows]], truncated

"""DuckDB store for v1 — one embedded columnar database.

State tables are REPLACED wholesale on every collection (osquery returns the
full current state, so a snapshot is a whole-table replace, not an upsert diff).
The UI reads through read-only SQL. Enrichment is intended to be SQL VIEWS over
these base tables (declarative joins, no Python lookup tables) — that mechanism
is designed separately and is NOT implemented here yet.

DuckDB is vendored in v1/vendor so it stays importable under PYTHONNOUSERSITE=1
(that flag only disables the automatic user-site; an explicit sys.path entry
still works). Paths are resolved relative to the install root / env, never a
hardcoded $HOME — the RPM build and a root deployment (LISIN_DATA_DIR=
/var/lib/lisin) reuse the same code.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

# Vendored duckdb: add explicitly so it loads even with PYTHONNOUSERSITE=1.
_VENDOR = Path(__file__).resolve().parent.parent / "vendor"
if _VENDOR.is_dir() and str(_VENDOR) not in sys.path:
    sys.path.insert(0, str(_VENDOR))
import duckdb  # noqa: E402


def data_path() -> Path:
    """Where the DuckDB file lives. Dev: XDG; root/RPM: LISIN_DATA_DIR."""
    base = os.environ.get("LISIN_DATA_DIR") or os.path.expanduser(
        "~/.local/share/lisin"
    )
    p = Path(base)
    p.mkdir(parents=True, exist_ok=True)
    return p / "v1.duckdb"


def _ident(name: str) -> str:
    """Quote an identifier; strip stray quotes (names come from our YAML, but
    never trust a string in SQL text)."""
    return '"' + str(name).replace('"', "") + '"'


class Store:
    def __init__(self, path: str | None = None):
        self.path = path or str(data_path())
        self._con = duckdb.connect(self.path)

    def close(self) -> None:
        self._con.close()

    def replace_table(self, name: str, rows: list[dict]) -> int:
        """Replace a state table with the full current snapshot.

        Columns are inferred from the row keys (osquery returns every value as a
        string, so all columns are VARCHAR — no type guessing). An empty result
        legitimately empties the table (a table that went empty must read empty,
        not keep stale rows).
        """
        q = _ident(name)
        if not rows:
            self._con.execute(f"CREATE OR REPLACE TABLE {q} (empty VARCHAR)")
            self._con.execute(f"DELETE FROM {q}")
            return 0
        # union of keys, order preserved from the first row then any extras
        cols: list[str] = list(rows[0].keys())
        seen = set(cols)
        for r in rows:
            for k in r.keys():
                if k not in seen:
                    seen.add(k)
                    cols.append(k)
        coldefs = ", ".join(f"{_ident(c)} VARCHAR" for c in cols)
        self._con.execute(f"CREATE OR REPLACE TABLE {q} ({coldefs})")
        placeholders = ", ".join(["?"] * len(cols))
        data = [[r.get(c) for c in cols] for r in rows]
        self._con.executemany(
            f"INSERT INTO {q} VALUES ({placeholders})", data
        )
        return len(rows)

    def tables(self) -> list[str]:
        return [
            r[0]
            for r in self._con.execute(
                "SELECT table_name FROM information_schema.tables "
                "WHERE table_schema = 'main' ORDER BY table_name"
            ).fetchall()
        ]

    def row_count(self, name: str) -> int:
        return self._con.execute(f"SELECT count(*) FROM {_ident(name)}").fetchone()[0]

    def query(self, sql: str, params=None, max_rows: int = 1000):
        """Run a read query for the UI. Returns (columns, rows, truncated).

        SELECT-only enforcement lives at the API boundary (as in v0); this method
        stays generic so enrichment views can also be created through a dedicated
        path later.
        """
        cur = self._con.cursor()
        cur.execute(sql, params or [])
        cols = [d[0] for d in cur.description]
        fetched = cur.fetchmany(max_rows + 1)
        truncated = len(fetched) > max_rows
        return cols, [list(r) for r in fetched[:max_rows]], truncated

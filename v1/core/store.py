"""DuckDB state store — one embedded columnar database.

State tables are REPLACED wholesale on every collection (osquery returns the full
current state, so a snapshot is a whole-table replace, not an upsert diff). The
UI reads through read-only SQL. Enrichment is SQL VIEWS over these base tables
(see core/views.py). The shared connection plumbing lives in core/db.py.
"""
from __future__ import annotations

import os
from pathlib import Path

from .db import DuckDB, data_dir, ident


def data_path() -> Path:
    return data_dir() / "v1.duckdb"


class Store(DuckDB):
    def __init__(self, path: str | None = None):
        super().__init__(path or str(data_path()))

    def replace_table_from_json(self, name: str, path: str) -> int:
        """Replace a state table straight from an osquery JSON result FILE.

        DuckDB parses the JSON itself, so a result never becomes Python objects:
        measured 26 ms against ~4 s for the row-by-row insert of the same 4000
        rows. Everything is read as VARCHAR — osquery emits every value as a
        string, and a column that silently became a number would break the
        text filters the UI writes.

        An empty result ([]) legitimately empties the table: a source that went
        quiet must read empty, not keep yesterday's rows.
        """
        q = ident(name)
        # An empty result is NOT a special case to be clever about: osquery
        # prints "[\n\n]" for it, which is a valid array of no records — and
        # read_json refuses that ("expected records, but got non-record JSON").
        # Detect it by content, not by size.
        head = ""
        try:
            with open(path, "r") as f:
                head = f.read(4096)
        except OSError:
            pass
        if head.strip() in ("", "[]", "[\n\n]") or not head.strip().startswith("["):
            self._con.execute(f"CREATE OR REPLACE TABLE {q} (empty VARCHAR)")
            return 0
        if head.strip().lstrip("[").strip() == "]":     # "[  ]" in any spelling
            self._con.execute(f"CREATE OR REPLACE TABLE {q} (empty VARCHAR)")
            return 0
        self._con.execute(
            f"CREATE OR REPLACE TABLE {q} AS "
            f"SELECT * FROM read_json(?, format='array', records=true, "
            f"auto_detect=true, sample_size=-1, "
            f"map_inference_threshold=-1, field_appearance_threshold=0)",
            [path],
        )
        return self.row_count(name)

    def replace_table_from_tsv(self, name: str, path: str,
                               columns: list[str]) -> int:
        """Replace a state table from a TAB-SEPARATED file (a `kind: command`
        input). Same fast path as the JSON one — DuckDB reads the file itself —
        with the column names taken from the rule, since a command's output has
        no header. Everything is VARCHAR for the same reason as elsewhere."""
        q = ident(name)
        try:
            size = os.path.getsize(path)
        except OSError:
            size = 0
        if size == 0 or not columns:
            self._con.execute(f"CREATE OR REPLACE TABLE {q} (empty VARCHAR)")
            return 0
        spec = ", ".join(f"'{c}': 'VARCHAR'" for c in columns
                         if c.replace("_", "").isalnum())
        self._con.execute(
            f"CREATE OR REPLACE TABLE {q} AS SELECT * FROM read_csv(?, "
            f"delim='\t', header=false, columns={{{spec}}}, quote='', escape='', "
            f"nullstr='', ignore_errors=true)",
            [path],
        )
        return self.row_count(name)

    def replace_table(self, name: str, rows: list[dict]) -> int:
        """Replace a state table with the full current snapshot.

        Columns are inferred from the row keys (osquery returns every value as a
        string, so all columns are VARCHAR — no type guessing). An empty result
        legitimately empties the table (a table that went empty must read empty,
        not keep stale rows)."""
        q = ident(name)
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
        coldefs = ", ".join(f"{ident(c)} VARCHAR" for c in cols)
        self._con.execute(f"CREATE OR REPLACE TABLE {q} ({coldefs})")
        placeholders = ", ".join(["?"] * len(cols))
        data = [[r.get(c) for c in cols] for r in rows]
        self._con.executemany(f"INSERT INTO {q} VALUES ({placeholders})", data)
        return len(rows)

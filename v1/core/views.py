"""Declarative derivation layer: enrichment VIEWS, filters (WHERE inside a view)
and graph EDGES — all SQL over the base tables, no Python middle.

Contract:
- A view attaches columns by JOINing base tables. It is CREATE OR REPLACE VIEW,
  so it is live (never stale) and re-running is free; base rows are never mutated.
- The JOIN source must be a real table (from a sensor/input), never a literal
  list in YAML — that is what structurally prevents hardcoded lookups.
- An edge declares a fact relation between two real key columns and is valid ONLY
  if both columns exist. The graph reads declared edges; it never guesses.
- Genuine computation (CVSS, ASN, a process tree) belongs in an INPUT or a
  view-model that produces a table; this layer only joins.

The identifier quoting, the SELECT-only guard, the YAML loader and the iterative
view engine are shared from core/db.py.
"""
from __future__ import annotations

from pathlib import Path

from .db import apply_views, ident, load_yaml_dir, select_only

_EXP = Path(__file__).resolve().parent.parent / "expertise"
VIEWS_DIR = _EXP / "views"
EDGES_DIR = _EXP / "edges"


def load_views() -> list[dict]:
    return load_yaml_dir(VIEWS_DIR)


def load_edges() -> list[dict]:
    return load_yaml_dir(EDGES_DIR)


def _col_exists(con, table: str, col: str) -> bool:
    return (
        con.execute(
            "SELECT 1 FROM information_schema.columns "
            "WHERE table_name = ? AND column_name = ? LIMIT 1",
            [table, col],
        ).fetchone()
        is not None
    )


def validate_view(store, sql: str) -> dict:
    """Dry-run a view body: columns + row count, or the error. No install."""
    if not select_only(sql):
        return {"columns": [], "rows": 0, "error": "not a single SELECT"}
    try:
        cur = store._con.cursor()
        cur.execute(f"SELECT * FROM ({sql}) LIMIT 0")
        cols = [d[0] for d in cur.description]
        n = store._con.execute(f"SELECT count(*) FROM ({sql})").fetchone()[0]
        return {"columns": cols, "rows": n, "error": ""}
    except Exception as e:  # noqa: BLE001
        return {"columns": [], "rows": 0, "error": str(e)}


def _rebuild_edges(store) -> list[dict]:
    con = store._con
    con.execute(
        "CREATE OR REPLACE TABLE _edges ("
        "name VARCHAR, from_table VARCHAR, from_col VARCHAR, "
        "to_table VARCHAR, to_col VARCHAR, label VARCHAR, "
        "valid BOOLEAN, error VARCHAR)"
    )
    status = []
    for e in load_edges():
        try:
            ft, fc = str(e["from"]).split(".", 1)
            tt, tc = str(e["to"]).split(".", 1)
        except (KeyError, ValueError):
            status.append({"edge": e.get("name"), "error": "from/to must be table.column"})
            continue
        err = ""
        if not _col_exists(con, ft, fc):
            err = f"{e['from']} does not exist"
        elif not _col_exists(con, tt, tc):
            err = f"{e['to']} does not exist"
        con.execute(
            "INSERT INTO _edges VALUES (?,?,?,?,?,?,?,?)",
            [e.get("name"), ft, fc, tt, tc, e.get("label", ""), err == "", err],
        )
        status.append({"edge": e.get("name"), "error": err})
    return status


def apply(store) -> dict:
    """Create/replace all enrichment views, then rebuild the validated edge table.
    Returns per-object status (numbers, not prose). The caller holds store._lock
    (pipeline.run_all runs inside it)."""
    return {
        "views": apply_views(store._con, load_views()),
        "edges": _rebuild_edges(store),
    }


def run_tests(store) -> list[dict]:
    """Run each view's in-rule tests against the live store."""
    results = []
    for v in load_views():
        t = v.get("tests")
        if not t:
            continue
        r = {"view": v.get("name"), "passed": True, "detail": ""}
        val = validate_view(store, v.get("sql", ""))
        if val["error"]:
            r.update(passed=False, detail=val["error"])
            results.append(r)
            continue
        for c in t.get("expect_columns", []):
            if c not in val["columns"]:
                r.update(passed=False, detail=f"missing column {c}")
        mr = t.get("min_rows")
        if mr is not None and val["rows"] < mr:
            r.update(passed=False, detail=f"rows {val['rows']} < min_rows {mr}")
        results.append(r)
    return results

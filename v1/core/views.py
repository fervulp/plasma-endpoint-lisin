"""Declarative derivation layer: enrichment VIEWS, filters (WHERE inside a
view) and graph EDGES — all SQL over the base tables, no Python middle.

Approved contract:
- A view attaches columns by JOINing base tables. It is CREATE OR REPLACE VIEW,
  so it is live (never stale) and re-running is free; base rows are never
  mutated.
- The JOIN source must be a real table (from a sensor/input), never a literal
  list in YAML — that is what structurally prevents hardcoded lookups.
- An edge declares a fact relation between two real key columns and is valid
  ONLY if both columns exist. The graph reads declared edges; it never guesses
  from value overlap.
- Genuine computation (CVSS, ASN, …) belongs in an INPUT that produces a table;
  this layer only joins.
"""
from __future__ import annotations

import re
from pathlib import Path

import yaml

_EXP = Path(__file__).resolve().parent.parent / "expertise"
VIEWS_DIR = _EXP / "views"
EDGES_DIR = _EXP / "edges"

# Views are trusted expertise, but guard the body anyway: one SELECT, no DDL/DML.
_FORBIDDEN = re.compile(
    r"\b(attach|detach|copy|install|load|pragma|insert|update|delete|drop|"
    r"alter|create|call|export|import)\b",
    re.I,
)


def _ident(name: str) -> str:
    return '"' + str(name).replace('"', "") + '"'


def _select_only(sql: str) -> bool:
    body = re.sub(r"--[^\n]*", "", sql)  # strip line comments
    stmts = [s for s in body.split(";") if s.strip()]
    if len(stmts) != 1:
        return False
    head = stmts[0].strip().lower()
    if not (head.startswith("select") or head.startswith("with")):
        return False
    return _FORBIDDEN.search(stmts[0]) is None


def _load_dir(d: Path) -> list[dict]:
    out = []
    if not d.is_dir():
        return out
    for f in sorted(d.glob("*.yaml")):
        spec = yaml.safe_load(f.read_text()) or {}
        spec["_file"] = str(f)
        out.append(spec)
    return out


def load_views() -> list[dict]:
    return _load_dir(VIEWS_DIR)


def load_edges() -> list[dict]:
    return _load_dir(EDGES_DIR)


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
    if not _select_only(sql):
        return {"columns": [], "rows": 0, "error": "not a single SELECT"}
    try:
        cur = store._con.cursor()
        cur.execute(f"SELECT * FROM ({sql}) LIMIT 0")
        cols = [d[0] for d in cur.description]
        n = store._con.execute(f"SELECT count(*) FROM ({sql})").fetchone()[0]
        return {"columns": cols, "rows": n, "error": ""}
    except Exception as e:  # noqa: BLE001
        return {"columns": [], "rows": 0, "error": str(e)}


def _apply_views(store) -> list[dict]:
    con = store._con
    status: list[dict] = []
    pending = load_views()
    # iterative passes: a view may reference another view created later.
    for _ in range(len(pending) + 1):
        if not pending:
            break
        still = []
        for v in pending:
            name, sql = v.get("name"), v.get("sql", "")
            if not _select_only(sql):
                status.append({"view": name, "error": "not a single SELECT"})
                continue
            try:
                con.execute(f"CREATE OR REPLACE VIEW {_ident(name)} AS {sql}")
                status.append({"view": name, "error": ""})
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
    """Create/replace all enrichment views, then rebuild the validated edge
    table. Returns per-object status (numbers, not prose)."""
    return {"views": _apply_views(store), "edges": _rebuild_edges(store)}


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

"""Declarative derivation layer: enrichment VIEWS — SQL over the base tables,
with no Python in the middle.

Contract:
- A view attaches columns by JOINing base tables. It is CREATE OR REPLACE VIEW,
  so it is live (never stale) and re-running is free; base rows are never mutated.
- The JOIN source must be a real table (from a sensor/input), never a literal
  list in YAML — that is what structurally prevents hardcoded lookups.
- Genuine computation (CVSS, ASN, a process tree) belongs in an INPUT or a
  view-model that produces a table; this layer only joins.

WHAT WAS HERE AND IS NOT ANY MORE. A declared-edge layer wrote a table of
relations between tables on every collection, and a dry-run validator offered to
check a view's SQL without installing it. Nothing read either one: the relations
were for a graph that is not being built yet, and the validator was superseded by
core/ruletest.py, which runs a rule's own assertions against the live table.
Code that runs every cycle and is read by nobody is a cost with no answer
attached, so it is gone rather than kept "for later" — the history has it if the
graph comes back.

The identifier quoting, the SELECT-only guard, the YAML loader and the iterative
view engine (including storing a slow derivation as a table) are shared from
core/db.py.
"""
from __future__ import annotations

from pathlib import Path

from .db import apply_views, load_yaml_dir

_EXP = Path(__file__).resolve().parent.parent / "expertise"
VIEWS_DIR = _EXP / "views"


def load_views() -> list[dict]:
    return load_yaml_dir(VIEWS_DIR)


def apply(store) -> dict:
    """Create or replace every enrichment view. Returns per-view status (numbers,
    not prose). The caller holds store._lock (pipeline.run_all runs inside it)."""
    return {"views": apply_views(store._con, load_views())}

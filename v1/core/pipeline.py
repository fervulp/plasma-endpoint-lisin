"""v1 collection pipeline — the ONLY step wired for now is input → store.

An input is a self-contained YAML rule: an osquery query plus the destination
table. On each run the query executes and its full result replaces the table.
There is deliberately NO enrichment and NO filter stage yet — those are where
mistakes and hardcoding creep in, so their mechanism is being designed cleanly
(as SQL views / SQL WHERE over these base tables) before any rule is written.
"""
from __future__ import annotations

from pathlib import Path

import yaml

from . import osquery
from .store import Store

INPUTS_DIR = Path(__file__).resolve().parent.parent / "expertise" / "inputs"


def load_inputs() -> list[dict]:
    items = []
    for f in sorted(INPUTS_DIR.glob("*.yaml")):
        d = yaml.safe_load(f.read_text()) or {}
        d["_file"] = str(f)
        items.append(d)
    return items


def run_once(store: Store) -> list[dict]:
    """Run every enabled input once. Returns per-input status (numbers, not
    prose, so a run can be verified against v0)."""
    status = []
    for inp in load_inputs():
        if inp.get("enabled") is False:
            continue
        table = inp.get("table") or inp.get("name")
        try:
            rows = osquery.run(inp["query"])
            n = store.replace_table(table, rows)
            status.append({"table": table, "rows": n, "error": ""})
        except Exception as e:  # noqa: BLE001 — a bad rule must not kill the run
            status.append({"table": table, "rows": 0, "error": str(e)})
    return status

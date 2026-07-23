"""The event taxonomy - a single dictionary of fields (ECS-like).

The source of truth is expertise/taxonomy/events.yaml. Normalization and
correlation rules are written against THESE fields (the way sigma rules are
written against their own taxonomy). The schema of the event table is built
from here: add a field to the YAML and the column appears in the database on
the next start (columns are only added, nothing is removed automatically).
"""
from pathlib import Path

import yaml

TAXONOMY_FILE = (Path(__file__).resolve().parent.parent
                 / "expertise" / "taxonomy" / "events.yaml")

# taxonomy type -> SQLite column type
SQL_TYPE = {"text": "TEXT", "int": "INTEGER", "float": "REAL", "json": "TEXT"}


def load(path: Path = TAXONOMY_FILE) -> dict:
    """Reads the taxonomy. Returns {table, key, title, version, fields[]}."""
    d = yaml.safe_load(Path(path).read_text()) or {}
    fields = []
    seen = set()
    for f in d.get("fields") or []:
        name = str(f.get("name", "")).strip()
        if not name or name in seen:
            continue          # duplicate fields are ignored
        seen.add(name)
        fields.append({
            "name": name,
            "ecs": str(f.get("ecs") or ""),
            "type": str(f.get("type") or "text"),
            "index": bool(f.get("index")),
            "group": str(f.get("group") or "other"),
            "desc": str(f.get("desc") or ""),
        })
    return {"table": str(d.get("table") or "events"),
            "key": str(d.get("key") or "event_id"),
            "title": str(d.get("title") or "Events"),
            "version": str(d.get("version") or ""),
            "fields": fields}


def names(spec: dict) -> list:
    return [f["name"] for f in spec["fields"]]


def groups(spec: dict) -> list:
    """Fields grouped for the UI: [{group, fields:[...]}] in file order."""
    order, by = [], {}
    for f in spec["fields"]:
        g = f["group"]
        if g not in by:
            by[g] = []
            order.append(g)
        by[g].append(f)
    return [{"group": g, "fields": by[g]} for g in order]

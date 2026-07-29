"""Output points: a table declared by a rule, and created because it was declared.

Until now a table existed only as a SIDE EFFECT of collecting: a source ran, and
whatever shape its result happened to have became the table. That leaves no place
to say what a table IS — what the fields mean, what belongs in it, what it is for
— and it makes an empty table indistinguishable from a table that was never
created at all.

An output turns that around. It declares a table and its FIELDS, and the engine
creates the table the first time the output is applied — before anything writes
to it. So a table with no data yet still appears with its columns, its title and
its description, and the question "does this field exist" is answered by the
expertise rather than by whatever the last collection happened to produce.

    type: output
    name: policy_findings
    table: policy_findings
    title: Policy findings
    icon: security-medium
    description: >-
      What this table holds and why it exists.
    fields:
      - {name: when,   type: TIMESTAMP, description: when it was observed}
      - {name: rule,   type: VARCHAR,   description: which policy said so}
      - {name: object, type: VARCHAR,   description: what it was about}

GROWING IS SAFE, SHRINKING IS NOT. A field added to the rule is added to the
table; a field removed from the rule is LEFT IN PLACE. Dropping a column would
destroy data that the rule no longer describes but the machine may still have
produced, and that is not a decision an automatic apply should take.

The types are DuckDB's own, validated against a small list, because a type name
goes into DDL and nothing from a rule is pasted into SQL unchecked.
"""
from __future__ import annotations

from pathlib import Path

from .db import ident, load_yaml_dir

OUTPUTS_DIR = Path(__file__).resolve().parent.parent / "expertise" / "outputs"

# Everything a table here legitimately holds. A rule naming anything else is
# refused rather than passed to the database: a type is written into DDL, and the
# rules are the one place a user edits by hand.
TYPES = {
    "VARCHAR", "TEXT", "BIGINT", "INTEGER", "DOUBLE", "BOOLEAN",
    "TIMESTAMP", "DATE", "BLOB",
}
DEFAULT_TYPE = "VARCHAR"


def load_outputs() -> list[dict]:
    return load_yaml_dir(OUTPUTS_DIR)


def fields_of(rule: dict) -> list[tuple[str, str, str]]:
    """(name, type, description) per declared field, types normalised."""
    out = []
    for f in rule.get("fields") or []:
        if isinstance(f, str):
            out.append((f, DEFAULT_TYPE, ""))
            continue
        name = str(f.get("name") or "").strip()
        if not name:
            continue
        typ = str(f.get("type") or DEFAULT_TYPE).strip().upper()
        if typ not in TYPES:
            typ = DEFAULT_TYPE
        out.append((name, typ, str(f.get("description") or "")))
    return out


def apply(store) -> list[dict]:
    """Create every declared table that does not exist, and add fields that were
    declared since. Returns per-output status (numbers, not prose).

    Runs BEFORE collection: a source that writes into a declared table should
    find it there, and a table with no source at all should still exist."""
    status = []
    for rule in load_outputs():
        name = str(rule.get("table") or rule.get("name") or "").strip()
        if not name:
            status.append({"output": rule.get("name"), "error": "no table name"})
            continue
        fields = fields_of(rule)
        if not fields:
            status.append({"output": name, "error": "declares no fields"})
            continue
        try:
            with store._lock:
                existing = store.columns(name)
                if not existing:
                    cols = ", ".join(f"{ident(n)} {t}" for n, t, _d in fields)
                    store._con.execute(f"CREATE TABLE {ident(name)} ({cols})")
                    status.append({"output": name, "created": True,
                                   "fields": len(fields), "added": [], "error": ""})
                    continue
                # GROW ONLY. A field the rule no longer mentions stays: dropping
                # it would destroy data the rule stopped describing but the
                # machine may still have produced.
                added = []
                for n, t, _d in fields:
                    if n not in existing:
                        store._con.execute(
                            f"ALTER TABLE {ident(name)} ADD COLUMN {ident(n)} {t}")
                        added.append(n)
                status.append({"output": name, "created": False,
                               "fields": len(fields), "added": added, "error": ""})
        except Exception as e:  # noqa: BLE001 — one bad rule must not stop the rest
            status.append({"output": name, "error": str(e).splitlines()[0]})
    return status

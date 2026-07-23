"""Where things live on disk - computed in ONE place.

Every module used to derive the project root itself with a chain of `.parent`,
and the chain differed by how deep the module sat. Moving a module one directory
down silently broke the expertise path and the catalogue came up empty. One
definition cannot drift.
"""
from pathlib import Path

# agent/paths.py -> agent -> the project root
ROOT = Path(__file__).resolve().parent.parent
EXPERTISE = ROOT / "expertise"
TAXONOMY_FILE = EXPERTISE / "taxonomy" / "events.yaml"

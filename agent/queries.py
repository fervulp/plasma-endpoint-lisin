"""Сохранённые запросы поиска по событиям.

Живут в ЭКСПЕРТИЗЕ, но вне fedora: expertise/queries/<каталог>/<имя>.yaml.
Это пользовательские объекты — их удобно раскладывать по каталогам
(«Инциденты», «Сеть», «Логины»), делиться ими и держать под git, как и
остальную экспертизу. Тип объекта — `query`, поэтому он виден в разделе
«Экспертиза» наравне с правилами.
"""
import re
from pathlib import Path

import yaml

EXPERTISE = Path(__file__).resolve().parent.parent / "expertise"
ROOT = EXPERTISE / "queries"


def _san(name: str) -> str:
    s = re.sub(r"[^\w \-.]", "_", (name or "").strip(), flags=re.UNICODE)
    s = re.sub(r"\s+", "_", s).strip("._-")
    return s[:60] or "query"


def dirs() -> list:
    """Каталоги запросов (всегда есть хотя бы 'general')."""
    ROOT.mkdir(parents=True, exist_ok=True)
    out = sorted(p.name for p in ROOT.iterdir() if p.is_dir())
    return out or ["general"]


def make_dir(name: str) -> str:
    d = _san(name)
    (ROOT / d).mkdir(parents=True, exist_ok=True)
    return d


def save(directory: str, name: str, sql: str, description: str = "") -> str:
    """Сохраняет запрос. Возвращает ref (путь от корня экспертизы)."""
    d = _san(directory or "general")
    n = _san(name)
    (ROOT / d).mkdir(parents=True, exist_ok=True)
    f = ROOT / d / (n + ".yaml")
    f.write_text(yaml.safe_dump(
        {"name": n, "id": "LS-Q-" + n, "type": "query", "version": "1.0.0",
         "title": (name or n).strip(), "description": description,
         "target": "events", "sql": sql},
        allow_unicode=True, sort_keys=False))
    return str(f.relative_to(EXPERTISE))[:-5]


def listing() -> list:
    """Все сохранённые запросы: [{dir, name, title, sql, ref}]."""
    ROOT.mkdir(parents=True, exist_ok=True)
    out = []
    for f in sorted(ROOT.rglob("*.yaml")):
        try:
            d = yaml.safe_load(f.read_text()) or {}
        except Exception:
            continue
        if str(d.get("type", "")) != "query":
            continue
        out.append({"dir": f.parent.name,
                    "name": str(d.get("name", f.stem)),
                    "title": str(d.get("title", f.stem)),
                    "description": str(d.get("description", "")),
                    "sql": str(d.get("sql", "")),
                    "ref": str(f.relative_to(EXPERTISE))[:-5]})
    return out


def delete(ref: str) -> bool:
    p = (EXPERTISE / (ref + ".yaml")).resolve()
    if not p.is_relative_to(ROOT.resolve()) or not p.exists():
        return False
    p.unlink()
    return True

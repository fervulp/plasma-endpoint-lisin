"""Таксономия событий — единый словарь полей (ECS-подобный).

Источник истины — expertise/taxonomy/events.yaml. Под ЭТИ поля пишутся
правила нормализации и корреляции (как sigma-правила пишутся под свою
таксономию). Схема таблицы событий строится отсюда: добавил поле в YAML →
колонка появится в БД при следующем запуске (колонки только добавляются,
ничего не удаляется автоматически).
"""
from pathlib import Path

import yaml

TAXONOMY_FILE = (Path(__file__).resolve().parent.parent
                 / "expertise" / "taxonomy" / "events.yaml")

# тип таксономии → тип колонки SQLite
SQL_TYPE = {"text": "TEXT", "int": "INTEGER", "float": "REAL", "json": "TEXT"}


def load(path: Path = TAXONOMY_FILE) -> dict:
    """Читает таксономию. Возвращает {table, key, title, version, fields[]}."""
    d = yaml.safe_load(Path(path).read_text()) or {}
    fields = []
    seen = set()
    for f in d.get("fields") or []:
        name = str(f.get("name", "")).strip()
        if not name or name in seen:
            continue          # дубликаты полей игнорируем
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
    """Поля, сгруппированные для UI: [{group, fields:[...]}] в порядке файла."""
    order, by = [], {}
    for f in spec["fields"]:
        g = f["group"]
        if g not in by:
            by[g] = []
            order.append(g)
        by[g].append(f)
    return [{"group": g, "fields": by[g]} for g in order]

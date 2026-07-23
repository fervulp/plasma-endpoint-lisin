"""LiSin settings: JSON in ~/.config/lisin/settings.json."""
import json
from pathlib import Path

PATH = Path.home() / ".config/lisin/settings.json"


def load() -> dict:
    try:
        return json.loads(PATH.read_text())
    except Exception:
        return {}


def save(cfg: dict):
    PATH.parent.mkdir(parents=True, exist_ok=True)
    PATH.write_text(json.dumps(cfg, ensure_ascii=False, indent=2))


def get(key: str, default=None):
    return load().get(key, default)


def set_(key: str, value):
    cfg = load()
    cfg[key] = value
    save(cfg)

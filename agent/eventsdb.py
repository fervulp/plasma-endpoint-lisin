"""База СОБЫТИЙ: отдельная SQLite (events.db), схема из таксономии.

Почему отдельно от state.db: состояние — снимок «сейчас» (upsert, сотни
строк), события — поток (append-only, сотни тысяч строк, retention). Разные
профили нагрузки и свой WAL, чтобы объём событий не мешал состоянию.

Дедупликация: UNIQUE по ключу таксономии (event_id = журнальный курсор) +
INSERT OR IGNORE. Поэтому точка входа может собирать с ПЕРЕКРЫТИЕМ окна
(«за последние 35 секунд» при интервале 30) и ничего не задвоится — курсоры
хранить не нужно, схема самовосстанавливающаяся.
"""
import sqlite3
import time
from pathlib import Path

from . import taxonomy as tx

DB_PATH = Path.home() / ".local/share/lisin/events.db"
MAX_ROWS = 300_000          # retention: держим последние N событий


class EventsDB:
    def __init__(self, path: Path = DB_PATH, spec: dict = None):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.spec = spec or tx.load()
        self.table = self.spec["table"]
        self.key = self.spec["key"]
        self.unknown: set = set()      # поля от нормализатора вне таксономии
        self._ensure()

    def _con(self):
        con = sqlite3.connect(self.path, timeout=5.0)
        con.row_factory = sqlite3.Row
        return con

    # -------- схема из таксономии --------
    def _ensure(self):
        cols = self.spec["fields"]
        with self._con() as c:
            c.execute("PRAGMA journal_mode=WAL")
            coldef = ",".join(
                f'"{f["name"]}" {tx.SQL_TYPE.get(f["type"], "TEXT")}'
                for f in cols)
            c.execute(f'CREATE TABLE IF NOT EXISTS "{self.table}"'
                      f'(_id INTEGER PRIMARY KEY,{coldef})')
            # таксономия могла вырасти — доливаем недостающие колонки
            have = {r["name"] for r in
                    c.execute(f'PRAGMA table_info("{self.table}")')}
            for f in cols:
                if f["name"] not in have:
                    c.execute(f'ALTER TABLE "{self.table}" ADD COLUMN '
                              f'"{f["name"]}" {tx.SQL_TYPE.get(f["type"], "TEXT")}')
            # ключ дедупликации + индексы под фильтры/корреляцию
            if self.key in {f["name"] for f in cols}:
                c.execute(f'CREATE UNIQUE INDEX IF NOT EXISTS '
                          f'"ux_{self.table}_{self.key}" '
                          f'ON "{self.table}"("{self.key}")')
            for f in cols:
                if f["index"] and f["name"] != self.key:
                    c.execute(f'CREATE INDEX IF NOT EXISTS '
                              f'"ix_{self.table}_{f["name"]}" '
                              f'ON "{self.table}"("{f["name"]}")')

    # -------- запись --------
    def append(self, rows: list) -> int:
        """Добавляет события (INSERT OR IGNORE по ключу). Возвращает число
        реально вставленных (дубликаты не считаются)."""
        if not rows:
            return 0
        cols = [f["name"] for f in self.spec["fields"]]
        colset = set(cols)
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        names = ",".join(f'"{c}"' for c in cols)
        ph = ",".join("?" * len(cols))
        added = 0
        with self._con() as c:
            for row in rows:
                # ЧТО ОСТАЛОСЬ НЕРАЗОБРАННЫМ — пишем в саму запись, а не
                # только в память процесса. Поля, которые нормализатор вернул,
                # но которых нет в таксономии, иначе просто исчезали: колонки
                # для них нет, и понять, что правило чего-то не доработало,
                # было невозможно. Теперь их ИМЕНА попадают в not_normalized
                # (а раз оно непустое — рядом сохраняется и raw), поэтому
                # видно и что потеряно, и из чего это восстановить.
                extra = sorted(k for k in row if k not in colset)
                if extra:
                    self.unknown.update(extra)      # диагностика по процессу
                    have = str(row.get("not_normalized") or "").strip()
                    mark = "unmapped: " + ", ".join(extra[:20])
                    if len(extra) > 20:
                        mark += " (+%d)" % (len(extra) - 20)
                    row = {**row,
                           "not_normalized": (have + " · " + mark) if have else mark}
                if not row.get("ingested"):
                    row = {**row, "ingested": now}
                # RAW ХРАНИМ НЕ ВСЕГДА: если правило разобрало запись
                # полностью (not_normalized пуст), исходник — чистое
                # дублирование уже разложенных колонок. На реальной базе это
                # 42% файла. Оставляем raw там, где он реально нужен: когда
                # что-то НЕ разобрано (видно, что дорабатывать в правиле).
                if row.get("raw") and not str(row.get("not_normalized") or ""):
                    row = {**row, "raw": ""}
                vals = [self._val(row.get(k)) for k in cols]
                cur = c.execute(
                    f'INSERT OR IGNORE INTO "{self.table}"({names}) '
                    f'VALUES({ph})', vals)
                added += cur.rowcount or 0
        return added

    @staticmethod
    def _val(v):
        if v is None:
            return None
        if isinstance(v, bool):
            return 1 if v else 0
        if isinstance(v, (int, float, str)):
            return v
        import json
        return json.dumps(v, ensure_ascii=False)

    def prune(self, max_rows: int = MAX_ROWS):
        """Retention: оставляем последние max_rows событий."""
        with self._con() as c:
            n = c.execute(f'SELECT COUNT(*) AS n FROM "{self.table}"'
                          ).fetchone()["n"]
            if n > max_rows:
                c.execute(f'DELETE FROM "{self.table}" WHERE _id IN ('
                          f'SELECT _id FROM "{self.table}" ORDER BY _id ASC '
                          f'LIMIT {int(n - max_rows)})')

    # -------- чтение --------
    def recent(self, limit: int = 200, offset: int = 0,
               where: str = "", params: tuple = (), order: str = "") -> dict:
        """Последние события (новые сверху). where/order — уже проверенные
        фрагменты: имена полей сверяются с таксономией на слое API."""
        limit = max(1, min(int(limit), 1000))
        sql = f'SELECT * FROM "{self.table}"'
        if where:
            sql += f" WHERE {where}"
        sql += f" ORDER BY {order}" if order else " ORDER BY _id DESC"
        sql += f" LIMIT {limit} OFFSET {max(0, int(offset))}"
        with self._con() as c:
            rows = [dict(r) for r in c.execute(sql, params)]
        return {"rows": rows, "columns": [f["name"] for f in self.spec["fields"]]}

    def count(self, where: str = "", params: tuple = ()) -> int:
        sql = f'SELECT COUNT(*) AS n FROM "{self.table}"'
        if where:
            sql += f" WHERE {where}"
        with self._con() as c:
            return c.execute(sql, params).fetchone()["n"]

    def stats(self) -> dict:
        """Сводка для страницы событий: сколько, за какой период, по чему."""
        out = {"total": 0, "first": "", "last": "", "by_category": [],
               "by_module": [], "by_outcome": []}
        with self._con() as c:
            out["total"] = c.execute(
                f'SELECT COUNT(*) AS n FROM "{self.table}"').fetchone()["n"]
            if not out["total"]:
                return out
            r = c.execute(f'SELECT MIN(ts) AS a, MAX(ts) AS b '
                          f'FROM "{self.table}"').fetchone()
            out["first"], out["last"] = r["a"] or "", r["b"] or ""
            for field, dest in (("event_category", "by_category"),
                                ("event_module", "by_module"),
                                ("event_outcome", "by_outcome")):
                out[dest] = [
                    {"value": x[field] or "", "count": x["n"]}
                    for x in c.execute(
                        f'SELECT "{field}", COUNT(*) AS n FROM "{self.table}" '
                        f'GROUP BY "{field}" ORDER BY n DESC LIMIT 20')]
        return out

    def query(self, sql: str, args=(), max_rows: int = 0) -> dict:
        """Только чтение (mode=ro), лимит 1000 — как в SQL-странице состояния.

        args — параметры запроса. Значения ВСЕГДА передаются параметрами:
        склейка значения с текстом SQL ломается на кавычках и открывает
        инъекцию, даже когда база открыта только на чтение (можно вытащить
        то, что показывать не собирались).
        """
        try:
            con = sqlite3.connect(f"file:{self.path}?mode=ro", uri=True)
            con.row_factory = sqlite3.Row
            cur = con.execute(sql, args)
            cols = [d[0] for d in cur.description] if cur.description else []
            # max_rows поднимает предел для служебных вычислений (цепочки
            # смотрят окно в десятки тысяч событий). Раньше предел 1000 стоял
            # ЖЁСТКО, и цепочки физически видели только последнюю тысячу
            # событий: установка часовой давности в них не попадала вообще.
            LIMIT = int(max_rows) if max_rows else 1000
            raw = cur.fetchmany(LIMIT + 1)
            truncated = len(raw) > LIMIT      # честно сообщаем об обрезании
            rows = [{k: r[k] for k in cols} for r in raw[:LIMIT]]
            con.close()
            return {"columns": cols, "rows": rows, "error": "",
                    "truncated": truncated, "limit": LIMIT}
        except Exception as e:
            return {"columns": [], "rows": [], "error": str(e)}

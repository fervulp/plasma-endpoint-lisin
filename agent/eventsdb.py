"""The EVENT database: a separate SQLite (events.db), schema from the taxonomy.

Why separate from state.db: state is a snapshot of "now" (upsert, hundreds of
rows), events are a stream (append-only, hundreds of thousands of rows,
retention). Different load profiles and their own WAL, so that the volume of
events does not get in the way of the state.

Deduplication: UNIQUE on the taxonomy key (event_id = the journal cursor) +
INSERT OR IGNORE. That is why an input may collect with an OVERLAPPING window
("the last 35 seconds" at an interval of 30) and nothing is duplicated - there
is no need to store cursors, the schema heals itself.
"""
import sqlite3
import time
from pathlib import Path

from . import taxonomy as tx

DB_PATH = Path.home() / ".local/share/lisin/events.db"
MAX_ROWS = 300_000          # retention: keep the last N events


class EventsDB:
    def __init__(self, path: Path = DB_PATH, spec: dict = None):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.spec = spec or tx.load()
        self.table = self.spec["table"]
        self.key = self.spec["key"]
        self.unknown: set = set()      # fields from a normalizer outside the taxonomy
        self._ensure()

    def _con(self):
        con = sqlite3.connect(self.path, timeout=5.0)
        con.row_factory = sqlite3.Row
        return con

    # -------- schema from the taxonomy --------
    def _ensure(self):
        cols = self.spec["fields"]
        with self._con() as c:
            c.execute("PRAGMA journal_mode=WAL")
            coldef = ",".join(
                f'"{f["name"]}" {tx.SQL_TYPE.get(f["type"], "TEXT")}'
                for f in cols)
            c.execute(f'CREATE TABLE IF NOT EXISTS "{self.table}"'
                      f'(_id INTEGER PRIMARY KEY,{coldef})')
            # the taxonomy may have grown - top up the missing columns
            have = {r["name"] for r in
                    c.execute(f'PRAGMA table_info("{self.table}")')}
            for f in cols:
                if f["name"] not in have:
                    c.execute(f'ALTER TABLE "{self.table}" ADD COLUMN '
                              f'"{f["name"]}" {tx.SQL_TYPE.get(f["type"], "TEXT")}')
            # the deduplication key + indexes for filters/correlation
            if self.key in {f["name"] for f in cols}:
                c.execute(f'CREATE UNIQUE INDEX IF NOT EXISTS '
                          f'"ux_{self.table}_{self.key}" '
                          f'ON "{self.table}"("{self.key}")')
            for f in cols:
                if f["index"] and f["name"] != self.key:
                    c.execute(f'CREATE INDEX IF NOT EXISTS '
                              f'"ix_{self.table}_{f["name"]}" '
                              f'ON "{self.table}"("{f["name"]}")')

    # -------- writing --------
    def append(self, rows: list) -> int:
        """Adds events (INSERT OR IGNORE on the key). Returns the number of rows
        actually inserted (duplicates do not count)."""
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
                # WHAT WAS LEFT UNPARSED - we write it into the record itself,
                # not only into the memory of the process. Fields that the
                # normalizer returned but that are not in the taxonomy used to
                # simply vanish: there is no column for them, and there was no way
                # to tell that a rule had missed something. Now their NAMES go
                # into not_normalized (and since that is non-empty, raw is kept
                # too), so both what was lost and what to restore it from are visible.
                extra = sorted(k for k in row if k not in colset)
                if extra:
                    self.unknown.update(extra)      # per-process diagnostics
                    have = str(row.get("not_normalized") or "").strip()
                    mark = "unmapped: " + ", ".join(extra[:20])
                    if len(extra) > 20:
                        mark += " (+%d)" % (len(extra) - 20)
                    row = {**row,
                           "not_normalized": (have + " · " + mark) if have else mark}
                if not row.get("ingested"):
                    row = {**row, "ingested": now}
                # RAW IS NOT ALWAYS STORED: if a rule parsed the record
                # completely (not_normalized is empty), the original is pure
                # duplication of the columns already extracted. On a real database
                # that is 42% of the file. We keep raw where it is actually needed:
                # when something was NOT parsed (it shows what to improve in the rule).
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
        """Retention: keep the last max_rows events."""
        with self._con() as c:
            n = c.execute(f'SELECT COUNT(*) AS n FROM "{self.table}"'
                          ).fetchone()["n"]
            if n > max_rows:
                c.execute(f'DELETE FROM "{self.table}" WHERE _id IN ('
                          f'SELECT _id FROM "{self.table}" ORDER BY _id ASC '
                          f'LIMIT {int(n - max_rows)})')

    # -------- reading --------
    def recent(self, limit: int = 200, offset: int = 0,
               where: str = "", params: tuple = (), order: str = "") -> dict:
        """The latest events (newest first). where/order are already validated
        fragments: field names are checked against the taxonomy in the API layer."""
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
        """A summary for the events page: how many, over what period, by what."""
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
        """Read only (mode=ro), limit 1000 - as on the state SQL page.

        args are the query parameters. Values are ALWAYS passed as parameters:
        gluing a value into the SQL text breaks on quotes and opens an injection,
        even when the database is opened read only (one can pull out things that
        were never meant to be shown).
        """
        try:
            con = sqlite3.connect(f"file:{self.path}?mode=ro", uri=True)
            con.row_factory = sqlite3.Row
            cur = con.execute(sql, args)
            cols = [d[0] for d in cur.description] if cur.description else []
            # max_rows raises the limit for internal computations (chains look at
            # a window of tens of thousands of events). The limit of 1000 used to
            # be HARD, and chains physically saw only the last thousand events: an
            # installation an hour old did not get into them at all.
            LIMIT = int(max_rows) if max_rows else 1000
            raw = cur.fetchmany(LIMIT + 1)
            truncated = len(raw) > LIMIT      # we report truncation honestly
            rows = [{k: r[k] for k in cols} for r in raw[:LIMIT]]
            con.close()
            return {"columns": cols, "rows": rows, "error": "",
                    "truncated": truncated, "limit": LIMIT}
        except Exception as e:
            return {"columns": [], "rows": [], "error": str(e)}

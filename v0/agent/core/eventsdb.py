"""The events table, schema from the taxonomy - it lives in the SAME file as the
state (data.db, see StateDB). It used to be a separate events.db; merging the two
gives native events<->state joins and one file to VACUUM. EventsDB keeps its own
class because its needs differ from a state table: an append-only schema built
from the taxonomy, INSERT OR IGNORE dedup, and retention.

Deduplication: UNIQUE on the taxonomy key (event_id = the journal cursor) +
INSERT OR IGNORE. That is why an input may collect with an OVERLAPPING window
("the last 35 seconds" at an interval of 30) and nothing is duplicated - there
is no need to store cursors, the schema heals itself.
"""
import sqlite3
import threading
import time
from pathlib import Path

from . import taxonomy as tx
from .statedb import DB_PATH          # one file for state AND events (data.db)

# retention: keep the newest events up to EITHER a row ceiling OR a size budget,
# whichever bites first - so the store never exceeds the size the user allowed,
# but also holds as many events as fit. Both are configurable in Settings.
MAX_ROWS = 2_000_000        # row ceiling
MAX_MB = 1024               # size budget for the events data (MB)


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
        con.execute("PRAGMA synchronous=NORMAL")
        con.execute("PRAGMA temp_store=MEMORY")
        return con

    # a persistent read connection per thread (see StateDB._reader): reused for
    # the feed, the facets and the statistics rather than opened per call.
    _readers = threading.local()

    def _reader(self):
        con = getattr(self._readers, "con", None)
        if con is None:
            con = sqlite3.connect(f"file:{self.path}?mode=ro", uri=True,
                                  timeout=5.0, check_same_thread=False)
            con.row_factory = sqlite3.Row
            con.execute("PRAGMA temp_store=MEMORY")
            self._readers.con = con
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
            # AN INDEX THAT IS NO LONGER DECLARED IS DROPPED. The taxonomy is the
            # schema, and that has to work in both directions: adding index: true
            # creates the index, removing it takes the index away. Otherwise an
            # existing database keeps paying for every index it ever had - here
            # that was 26 indexes nobody filtered by.
            want = {f'ix_{self.table}_{f["name"]}' for f in cols if f["index"]}
            # the list is read out FIRST: dropping an index while walking the
            # cursor over sqlite_master locks the table under our own feet
            have_idx = [r["name"] for r in c.execute(
                "SELECT name FROM sqlite_master WHERE type='index' "
                "AND tbl_name=? AND name LIKE 'ix_%'", (self.table,))]
            dropped = 0
            for name in have_idx:
                if name not in want:
                    c.execute(f'DROP INDEX IF EXISTS "{name}"')
                    dropped += 1
        if dropped:
            # the pages an index used to occupy are freed, but the file keeps its
            # size until it is compacted. This happens once, right after the
            # schema changed - on 170 thousand events it took 2 s and gave back
            # 68 MB.
            try:
                con = sqlite3.connect(self.path, timeout=30)
                con.execute("VACUUM")
                con.close()
            except Exception:
                pass

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
                # RAW IS NOT STORED. The original text only duplicates the columns
                # already extracted; what a rule did NOT parse is still recorded by
                # NAME in not_normalized (tiny), so a rule that missed a field stays
                # visible without keeping the whole original blob for every event.
                if row.get("raw"):
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

    def prune(self, max_rows: int = None, max_mb: int = None):
        """Retention: keep the NEWEST events up to a row ceiling AND a size budget.

        Two limits, whichever bites first: the user asked to hold as many events
        as possible (millions) but never let the store exceed a size (~1 GB). The
        row cap is exact; the size cap estimates bytes-per-event from the live page
        usage and trims the oldest until the live event data fits the budget. Then
        VACUUM gives the freed pages back to the filesystem.
        """
        try:
            from agent.core import config
            if max_rows is None:
                max_rows = int(config.get("events_retention", MAX_ROWS))
            if max_mb is None:
                max_mb = int(config.get("events_max_mb", MAX_MB))
        except Exception:
            max_rows = max_rows or MAX_ROWS
            max_mb = max_mb or MAX_MB
        max_rows = max(1000, int(max_rows))
        max_mb = max(16, int(max_mb))
        with self._con() as c:
            n = c.execute(f'SELECT COUNT(*) AS n FROM "{self.table}"'
                          ).fetchone()["n"]
            # 1) the row ceiling (exact)
            if n > max_rows:
                c.execute(f'DELETE FROM "{self.table}" WHERE _id IN ('
                          f'SELECT _id FROM "{self.table}" ORDER BY _id ASC '
                          f'LIMIT {int(n - max_rows)})')
                n = max_rows
            # 2) the size budget: how many events actually fit in max_mb, from the
            # live page usage of the table + its indexes (dbstat, not the file size,
            # so the freelist left by earlier deletes does not skew the estimate)
            budget = max_mb * 1024 * 1024
            try:
                weight = c.execute(
                    "SELECT SUM(pgsize) AS b FROM dbstat WHERE name=? "
                    "OR name LIKE 'ix_' || ? || '_%' OR name LIKE 'ux_' || ? || '_%'",
                    (self.table, self.table, self.table)).fetchone()["b"] or 0
            except Exception:
                weight = 0
            if weight > budget and n > 1000:
                per = weight / max(n, 1)                 # bytes per event, live
                keep = max(1000, int(budget / max(per, 1)))
                if keep < n:
                    c.execute(f'DELETE FROM "{self.table}" WHERE _id IN ('
                              f'SELECT _id FROM "{self.table}" ORDER BY _id ASC '
                              f'LIMIT {int(n - keep)})')
        self._reclaim()

    def _reclaim(self, min_dead_mb: int = 50):
        """Give back the space the retention DELETEs leave behind. A DELETE only
        moves pages to the freelist; without VACUUM the file never shrinks - it
        had grown to 355 MB of which 244 MB was dead freelist. VACUUM rewrites the
        file, so it runs only when there is enough dead space to be worth it (the
        threshold means one big compaction, then nothing until it builds up again).
        VACUUM cannot run inside a transaction, hence a fresh autocommit connection.
        """
        try:
            con = sqlite3.connect(self.path, timeout=30)
            con.isolation_level = None
            free = con.execute("PRAGMA freelist_count").fetchone()[0]
            pgsz = con.execute("PRAGMA page_size").fetchone()[0]
            if free * pgsz > min_dead_mb * 1024 * 1024:
                con.execute("VACUUM")
            con.close()
        except Exception:
            pass

    # -------- reading --------
    def recent(self, limit: int = 200, offset: int = 0,
               where: str = "", params: tuple = (), order: str = "") -> dict:
        """The latest events (newest first). where/order are already validated
        fragments: field names are checked against the taxonomy in the API layer."""
        limit = max(1, min(int(limit), 1000))
        sql = f'SELECT * FROM "{self.table}"'
        if where:
            sql += f" WHERE {where}"
        # newest by EVENT TIME first (ts is sortable ISO-8601 UTC); _id breaks
        # ties and keeps pagination stable. eBPF converts nsecs->ts and appends in
        # batches, so insertion order (_id) is not the same as time order.
        sql += f" ORDER BY {order}" if order else " ORDER BY ts DESC, _id DESC"
        sql += f" LIMIT {limit} OFFSET {max(0, int(offset))}"
        c = self._reader()
        rows = [dict(r) for r in c.execute(sql, params)]
        return {"rows": rows, "columns": [f["name"] for f in self.spec["fields"]]}

    def count(self, where: str = "", params: tuple = ()) -> int:
        sql = f'SELECT COUNT(*) AS n FROM "{self.table}"'
        if where:
            sql += f" WHERE {where}"
        return self._reader().execute(sql, params).fetchone()["n"]

    def stats(self) -> dict:
        """A summary for the events page: how many, over what period, by what."""
        out = {"total": 0, "first": "", "last": "", "by_category": [],
               "by_module": [], "by_outcome": []}
        c = self._reader()
        if True:
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
            con = self._reader()
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
            return {"columns": cols, "rows": rows, "error": "",
                    "truncated": truncated, "limit": LIMIT}
        except Exception as e:
            return {"columns": [], "rows": [], "error": str(e)}

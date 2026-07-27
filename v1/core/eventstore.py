"""Event store — a SEPARATE DuckDB from the state store.

Why separate (decided with the user): state is a SNAPSHOT (whole-table REPLACE,
rebuilt every 30 s, disposable) while events are a STREAM (append-only, hundreds
of thousands, with retention). One file would couple the writer lock, the
checkpoint/bloat of a fast append+delete churn, and the reset/corruption
lifecycle of two very different workloads.

Pipeline: the reader lands RAW Tetragon JSON lines in `tetragon_raw`; a SQL VIEW
`events_norm` (defined in expertise, json_extract over the raw column) is the
normalization; the engine MATERIALIZES that view incrementally into a real table
`events`, and the UI queries the table.

Why materialize instead of querying the view directly: the view runs json_extract
over every raw row, so a scan is O(all rows). Measured on 300 k events:
count(*) 466 ms, a filtered count 1.5 s, a page 0.7 s — which froze the UI on
every tab switch and on every 3 s snapshot push. Against the real table the same
queries are 1-27 ms. Normalization stays SQL (the view); only the read path
changes. The plumbing/view-engine are shared from core/db.py.
"""
from __future__ import annotations

import hashlib
from pathlib import Path

from .db import DuckDB, apply_views as _apply_view_sql, data_dir, load_yaml_dir

EVENT_VIEWS_DIR = Path(__file__).resolve().parent.parent / "expertise" / "events"

# RETENTION, and the two things it applies to are NOT the same thing.
#
# `events` is the HISTORY — the normalized, queryable table the interface reads.
# MAX_ROWS bounds it, because a stream needs a bound.
#
# `tetragon_raw` is a STAGING BUFFER, not history: a line lives there until it has
# been normalized. Keeping every raw line for the whole retention window meant the
# same event was stored twice — measured on this machine, 300 000 events cost
# 586 MB, of which 362 MB was raw JSON text, against 21 MB for the entire system
# inventory. So raw is trimmed to a WINDOW behind the normalization watermark.
#
# The window is not zero on purpose: editing a normalization rule re-normalizes
# from raw, and that can only reach as far back as raw still goes. So the window
# is what "fix the rule and see the last few hours re-read correctly" costs.
# Beyond it, already-normalized events keep the normalization they were written
# with — that is the honest trade and it is stated in the UI's rule description.
MAX_ROWS = 300_000
# Deliberately SMALL. Editing a normalization rule re-normalizes from raw, and
# that can only reach as far back as raw still goes, so this window is what "fix
# the rule and watch the last few minutes be re-read" costs — no more.
RAW_WINDOW = 5_000
# HOW MUCH RAW JSON ONE NORMALIZATION PASS PARSES, IN BYTES — not in rows.
#
# Measured on this machine: the seq filter DOES push into the scan (profiled: a
# 500-row batch reads 500 rows, not the whole staging table), so the batch really
# is the unit of work. But parsing one raw line into thirty-three columns costs
# far more than the line: ~0.25 MB of transient JSON allocation per 2.8 KB line,
# and that allocation is charged to the memory limit while being INVISIBLE to
# duckdb_memory() — which is why the failure read as "487 MiB used" next to a
# store reporting 1 MB.
#
# A batch counted in ROWS is therefore the wrong invariant: lines here range from
# 200 bytes to 8 KB, so a fixed row count is a 40x range of actual work, and a run
# of long lines hit the cap and stopped the ingest (OutOfMemory on INSERT). The
# budget is bytes of raw JSON, which is what the cost is actually proportional to.
# 1 MB of JSON ≈ a third of the cap at the measured expansion — room to spare, and
# 11 500 lines of backlog still catch up in seconds.
BATCH_BYTES = 1_000_000
# a row ceiling as well, so a flood of tiny lines cannot make one statement huge
BATCH_ROWS = 5_000

def load_event_views() -> list[dict]:
    """The normalization rules, read from disk. NOT a database call: a follower
    process has no database of its own but reads the same expertise directory,
    so this must not sit behind the connection."""
    return load_yaml_dir(EVENT_VIEWS_DIR)


NORM_VIEW = "events_norm"   # normalization view, from expertise
EVENTS_TABLE = "events"     # materialized, queryable table (what the UI reads)


def events_data_path() -> Path:
    return data_dir() / "v1-events.duckdb"


class EventStore(DuckDB):
    def __init__(self, path: str | None = None):
        super().__init__(path or str(events_data_path()))
        # highest raw seq already normalized; None = read it back from the table
        self._watermark: int | None = None
        self._init_schema()

    def _init_schema(self) -> None:
        with self._lock:
            self._con.execute("CREATE SEQUENCE IF NOT EXISTS seq_events START 1")
            # raw lands as VARCHAR (not JSON) so a rare malformed line cannot abort
            # a whole batch; the normalize view guards with json_valid().
            self._con.execute(
                "CREATE TABLE IF NOT EXISTS tetragon_raw ("
                "seq BIGINT DEFAULT nextval('seq_events'), "
                "ingested_at TIMESTAMP DEFAULT now(), "
                "data VARCHAR)"
            )
            # migration: earlier versions kept `events` as a VIEW; it is a real
            # (materialized) table now. DROP VIEW IF EXISTS errors on a table (and
            # vice-versa), so drop the view only when `events` is actually a view.
            row = self._con.execute(
                "SELECT table_type FROM information_schema.tables "
                "WHERE table_name = 'events'"
            ).fetchone()
            if row and str(row[0]).upper() == "VIEW":
                self._con.execute("DROP VIEW events")

    # ---------- ingestion ----------
    def append(self, lines: list[str]) -> int:
        """Append raw JSON lines (one Tetragon event per line). Returns count."""
        rows = [[ln] for ln in lines if ln and ln.strip()]
        if not rows:
            return 0
        with self._lock:
            self._con.executemany(
                "INSERT INTO tetragon_raw (data) VALUES (?)", rows
            )
        return len(rows)

    def prune(self, max_rows: int = MAX_ROWS,
              raw_window: int = RAW_WINDOW) -> int:
        """Bound both tables, each by its own rule (see the note above), and give
        the freed space back to the filesystem. Returns rows deleted in total.

        RAW IS NEVER TRIMMED PAST THE WATERMARK: a line that has not been
        normalized yet must survive, or the event is lost."""
        with self._lock:
            hi = self._con.execute(
                "SELECT max(seq) FROM tetragon_raw"
            ).fetchone()[0]
            if hi is None:
                return 0
            gone = 0
            # 1. history: the newest max_rows normalized events
            ev_hi = self._con.execute(
                f"SELECT max(seq) FROM {EVENTS_TABLE}"
            ).fetchone()[0]
            if ev_hi is not None and ev_hi - max_rows > 0:
                cut = ev_hi - max_rows
                gone += self._con.execute(
                    f"SELECT count(*) FROM {EVENTS_TABLE} WHERE seq <= ?", [cut]
                ).fetchone()[0]
                self._con.execute(
                    f"DELETE FROM {EVENTS_TABLE} WHERE seq <= ?", [cut])
            # 2. staging: a window behind the watermark, never beyond it.
            # The watermark is normally set by materialize(); resolve it from the
            # table when prune runs first, otherwise raw is never trimmed at all
            # (which is exactly how it grew to 362 MB of JSON).
            if self._watermark is None:
                self._watermark = self._con.execute(
                    f"SELECT coalesce(max(seq), CAST(-1 AS BIGINT)) "
                    f"FROM {EVENTS_TABLE}"
                ).fetchone()[0]
            mark = self._watermark
            raw_cut = min(mark, hi) - raw_window
            if raw_cut > 0:
                gone += self._con.execute(
                    "SELECT count(*) FROM tetragon_raw WHERE seq <= ?", [raw_cut]
                ).fetchone()[0]
                self._con.execute(
                    "DELETE FROM tetragon_raw WHERE seq <= ?", [raw_cut])
            # DuckDB only returns the space on a checkpoint; without it the file
            # keeps the deleted pages and the "lightweight agent" is 586 MB.
            if gone:
                try:
                    self._con.execute("CHECKPOINT")
                except Exception:  # noqa: BLE001 — a busy checkpoint is not fatal
                    pass
            return gone

    def raw_count(self) -> int:
        with self._lock:
            return self._con.execute(
                "SELECT count(*) FROM tetragon_raw"
            ).fetchone()[0]

    # ---------- derivation: normalize view -> materialized table ----------
    def load_views(self) -> list[dict]:
        return load_event_views()

    def _cols(self, name: str) -> list[str]:
        return [
            r[0]
            for r in self._con.execute(
                "SELECT column_name FROM information_schema.columns "
                "WHERE table_name = ? ORDER BY ordinal_position",
                [name],
            ).fetchall()
        ]

    def apply_views(self) -> list[dict]:
        """Apply the normalization view(s) from expertise, then make the
        materialized `events` table match the CURRENT rule — recreating it empty
        when the view's columns OR its SQL changed. materialize() then refills it.
        Called at init and after an expertise edit.

        Rebuilding on a changed SQL (not just changed columns) matters: fixing a
        classifier without touching the column list would otherwise leave every
        already-materialized row on the OLD rule, mixing two normalizations in one
        table with nothing to tell them apart."""
        with self._lock:
            specs = self.load_views()
            status = _apply_view_sql(self._con, specs)
            vcols = self._cols(NORM_VIEW)
            sql_sig = hashlib.sha1(
                "".join(str(v.get("sql", "")) for v in specs).encode()
            ).hexdigest()
            self._con.execute(
                "CREATE TABLE IF NOT EXISTS _meta (k VARCHAR PRIMARY KEY, v VARCHAR)"
            )
            row = self._con.execute(
                "SELECT v FROM _meta WHERE k = 'norm_sql'"
            ).fetchone()
            changed = (row is None or row[0] != sql_sig)
            if vcols and (changed or self._cols(EVENTS_TABLE) != vcols):
                self._con.execute(f"DROP TABLE IF EXISTS {EVENTS_TABLE}")
                self._con.execute(
                    f"CREATE TABLE {EVENTS_TABLE} AS "
                    f"SELECT * FROM {NORM_VIEW} LIMIT 0"
                )
                self._watermark = -1        # refill from the start of the stream
                self._con.execute("DELETE FROM _meta WHERE k = 'norm_sql'")
                self._con.execute(
                    "INSERT INTO _meta VALUES ('norm_sql', ?)", [sql_sig]
                )
        return status

    def materialize(self) -> int:
        """Normalize raw rows not yet in `events` (incremental). Cheap in steady
        state (only the new rows); a one-time backlog catch-up on the first run
        after the table is (re)created. Returns rows actually inserted.

        The watermark is kept EXPLICITLY, not derived from max(seq) of the events
        table: the normalization view legitimately drops rows (json_valid), so if
        the newest raw row is one it drops, a derived watermark would never reach
        the raw maximum — every cycle would re-run the insert, report work, and
        push a fresh snapshot to the UI forever."""
        with self._lock:
            hi = self._con.execute(
                "SELECT coalesce(max(seq), CAST(-1 AS BIGINT)) FROM tetragon_raw"
            ).fetchone()[0]
            if self._watermark is None:      # first call: resume where we left off
                self._watermark = self._con.execute(
                    f"SELECT coalesce(max(seq), CAST(-1 AS BIGINT)) FROM {EVENTS_TABLE}"
                ).fetchone()[0]
            if hi <= self._watermark:
                return 0
            before = self._con.execute(
                f"SELECT count(*) FROM {EVENTS_TABLE}"
            ).fetchone()[0]
            # IN BATCHES, so the memory this needs does not depend on how far
            # behind it is. Normalizing a whole backlog in one statement means
            # parsing tens of megabytes of JSON into thirty columns at once —
            # that hit the memory cap and the ingest stopped with OutOfMemory,
            # i.e. a big enough backlog broke the pipeline permanently.
            while True:
                nxt = self._con.execute(
                    "WITH w AS (SELECT seq, sum(length(data)) OVER "
                    "  (ORDER BY seq ROWS UNBOUNDED PRECEDING) AS run "
                    "  FROM (SELECT seq, data FROM tetragon_raw WHERE seq > ? "
                    "        ORDER BY seq LIMIT ?)) "
                    # the second branch: a single line bigger than the whole
                    # budget still has to be normalized, or the stream stalls
                    "SELECT coalesce((SELECT max(seq) FROM w WHERE run <= ?), "
                    "                (SELECT min(seq) FROM w))",
                    [self._watermark, BATCH_ROWS, BATCH_BYTES],
                ).fetchone()[0]
                if nxt is None:
                    break
                self._con.execute(
                    f"INSERT INTO {EVENTS_TABLE} SELECT * FROM {NORM_VIEW} "
                    f"WHERE seq > ? AND seq <= ?", [self._watermark, nxt]
                )
                self._watermark = nxt
                if nxt >= hi:
                    break
            after = self._con.execute(
                f"SELECT count(*) FROM {EVENTS_TABLE}"
            ).fetchone()[0]
            return int(after - before)

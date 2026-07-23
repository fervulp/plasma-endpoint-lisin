"""The state database: SQLite, one tab = one table.

The tables are filled by the pipeline (agent/pipeline.py) through
ensure_table/upsert: upsert by the rule's key, user columns are left alone,
rows that disappeared are deleted. User tabs/columns are created from the UI.
Names are sanitised to word characters (Cyrillic is allowed on purpose, so that
a user can name their own tables in their own language), values go only through
parameters,
table names are checked against the _tabs registry.
"""
import re
import sqlite3
import time
from pathlib import Path

from ..collect import state as coll

DB_PATH = Path.home() / ".local/share/lisin/state.db"


def _san(name: str, prefix: str) -> str:
    # Cyrillic is kept in the character class deliberately: a user may name
    # their own tables and columns in their own language (see the module docstring)
    s = re.sub(r"[^a-zа-яё0-9_]", "_", name.strip().lower())
    s = re.sub(r"_+", "_", s).strip("_")
    if not s or s[0].isdigit() or s == "_id":
        s = f"{prefix}_{s}"
    return s[:40]


def _txt(v) -> str:
    if isinstance(v, bool):
        return "yes" if v else ""
    return "" if v is None else str(v)


class StateDB:
    def __init__(self, path: Path = DB_PATH):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self._con() as c:
            # WAL: one writer (the agent) + concurrent readers (the UI) with no
            # locks and no clobbering. Set once (it is stored in the file).
            c.execute("PRAGMA journal_mode=WAL")
            c.execute("CREATE TABLE IF NOT EXISTS _tabs("
                      "name TEXT PRIMARY KEY, title TEXT, icon TEXT,"
                      "builtin INTEGER, keys TEXT)")
            try:
                c.execute("ALTER TABLE _tabs ADD COLUMN colcfg TEXT DEFAULT ''")
            except sqlite3.OperationalError:
                pass    # the column already exists

    def _con(self):
        # timeout=busy_timeout: a short write lock is retried instead of failing
        con = sqlite3.connect(self.path, timeout=5.0)
        con.row_factory = sqlite3.Row
        return con

    def _valid(self, c, tab: str) -> bool:
        return bool(c.execute("SELECT 1 FROM _tabs WHERE name=?",
                              (tab,)).fetchone())

    def _columns(self, c, tab: str) -> list[str]:
        return [r["name"] for r in c.execute(f'PRAGMA table_info("{tab}")')
                if r["name"] not in ("_id", "_src")]

    # -------- called by the pipeline --------
    def _ensure_collected_col(self, c):
        """the collection-time column: added in place, old databases too"""
        have = [r[1] for r in c.execute('PRAGMA table_info("_tabs")')]
        if "collected_at" not in have:
            c.execute('ALTER TABLE "_tabs" ADD COLUMN collected_at TEXT')

    def mark_collected(self, name: str):
        """mark that the pipeline has just filled this table"""
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        with self._con() as c:
            self._ensure_collected_col(c)
            c.execute('UPDATE "_tabs" SET collected_at = ? WHERE name = ?', (ts, name))

    def ensure_table(self, name: str, title: str, icon: str, cols: list[str]):
        name = _san(name, "t")
        with self._con() as c:
            coldef = ",".join(f'"{_san(x, "c")}" TEXT' for x in cols)
            c.execute(f'CREATE TABLE IF NOT EXISTS "{name}"'
                      f'(_id INTEGER PRIMARY KEY,{coldef})')
            c.execute("INSERT OR IGNORE INTO _tabs(name,title,icon,builtin,keys)"
                      " VALUES(?,?,?,1,'')", (name, title, icon))
            # the normalization rule is the source of truth for title/icon
            c.execute("UPDATE _tabs SET title=?, icon=? WHERE name=?",
                      (title, icon, name))
            # _src: the writer tag (of an output) used for staleness. On the
            # FIRST insert we clear prehistoric rows without a tag - that is how
            # dead processes and other rubbish from before this mechanism go away.
            info = [r["name"] for r in c.execute(f'PRAGMA table_info("{name}")')]
            if "_src" not in info:
                c.execute(f'ALTER TABLE "{name}" ADD COLUMN "_src" TEXT DEFAULT \'\'')
                c.execute(f'DELETE FROM "{name}"')
            have = self._columns(c, name)
            for x in cols:
                x = _san(x, "c")
                if x not in have:
                    c.execute(f'ALTER TABLE "{name}" ADD COLUMN "{x}" TEXT')

    def clear_src(self, name: str, src: str):
        """Remove all rows of one writer: the source came back empty.

        Needed where an empty result is an answer rather than a failure: a
        vulnerability closed by a patch, a stopped container. Without this the
        table would keep showing what is no longer in the system.
        """
        name = _san(name, "t")
        with self._con() as c:
            if not self._valid(c, name):
                return
            if "_src" not in [r["name"] for r in
                              c.execute(f'PRAGMA table_info("{name}")')]:
                return
            c.execute(f'DELETE FROM "{name}" WHERE "_src"=?', (src,))

    def upsert(self, name: str, keys: list[str], cols: list[str],
               rows: list[dict], src: str = "") -> dict:
        """Write the rows and RETURN the difference from the previous state.

        upsert computed the difference before as well (which keys are new, which
        disappeared), but threw it away. Yet a transition is the most valuable
        thing we have: "a program appeared" is incomparably more informative than
        "a program exists". So now we return {added, removed, changed, was_empty},
        and the pipeline decides whether to turn that into events (see _walk).

        was_empty matters separately: if the table was empty, this is the FIRST
        INVENTORY, not a change. The machine existed before us, and we have no
        right to present 3000 "installations" as events.
        """
        name = _san(name, "t")
        diff = {"added": [], "removed": [], "changed": [], "was_empty": False,
                "table": name}
        with self._con() as c:
            if not self._valid(c, name):
                return diff
            # the first occurrence of a key is canonical; repeats (a legacy of old
            # code, e.g. per-line ssh keys) are deleted so the key stays unique
            have = {}
            prev = {}          # previous values - to see WHAT changed
            dup_ids = []
            for r in c.execute(f'SELECT * FROM "{name}"'):
                k = tuple(r[kk] for kk in keys)
                if k in have:
                    dup_ids.append(r["_id"])
                else:
                    have[k] = r["_id"]
                    prev[k] = {kk: r[kk] for kk in r.keys()
                               if not kk.startswith("_")}
            # an empty table means the first collection, not a change
            diff["was_empty"] = not have
            if dup_ids:
                c.executemany(f'DELETE FROM "{name}" WHERE _id=?',
                              [(i,) for i in dup_ids])
            alive = set()
            for row in rows:
                vals = {k: _txt(row.get(k)) for k in cols}
                key = tuple(vals[k] for k in keys)
                alive.add(key)
                if key in have:
                    old = prev.get(key, {})
                    ch = {k: [str(old.get(k, "")), vals[k]] for k in cols
                          if str(old.get(k, "")) != vals[k]}
                    if ch:
                        diff["changed"].append({"key": list(key), "fields": ch})
                    sets = ",".join(f'"{k}"=?' for k in cols)
                    c.execute(f'UPDATE "{name}" SET {sets},"_src"=? WHERE _id=?',
                              [*vals.values(), src, have[key]])
                else:
                    diff["added"].append({"key": list(key), "row": dict(vals)})
                    names = ",".join(f'"{k}"' for k in cols) + ',"_src"'
                    ph = ",".join("?" * (len(cols) + 1))
                    c.execute(f'INSERT INTO "{name}"({names}) VALUES({ph})',
                              [*vals.values(), src])
            # staleness by WRITER (_src): we delete the rows of THIS output that
            # are no longer in the live set (dead processes, closed sockets).
            # Other rules write into the same table under their own _src - their
            # rows are left alone.
            keycols = ",".join(f'"{k}"' for k in keys)
            stale = []
            for r in c.execute(
                    f'SELECT _id,{keycols} FROM "{name}" WHERE "_src"=?', (src,)):
                if tuple(r[kk] for kk in keys) not in alive:
                    stale.append(r["_id"])
            if stale:
                for r in c.execute(
                        f'SELECT _id,{keycols} FROM "{name}" WHERE "_src"=?',
                        (src,)):
                    if r["_id"] in stale:
                        diff["removed"].append(
                            {"key": [r[kk] for kk in keys],
                             "row": prev.get(tuple(r[kk] for kk in keys), {})})
                c.executemany(f'DELETE FROM "{name}" WHERE _id=?',
                              [(i,) for i in stale])
        return diff

    def prune(self, keep: set):
        """Deletes builtin tables that no longer have an active output - e.g. the
        orphaned `connections` after it was merged into `ports`. User tables
        (u_*, builtin=0) are left alone."""
        keep = {_san(k, "t") for k in keep}
        with self._con() as c:
            for r in c.execute("SELECT name FROM _tabs WHERE builtin=1").fetchall():
                n = r["name"]
                if n not in keep:
                    c.execute(f'DROP TABLE IF EXISTS "{n}"')
                    c.execute("DELETE FROM _tabs WHERE name=?", (n,))

    # -------- reading everything for the UI --------
    # rows of ONE table are fetched separately (see table_rows): a snapshot that
    # carried every row shipped 22.9 MB and 115 thousand rows to the interface on
    # EVERY refresh - the whole model was rebuilt and the window froze for a
    # second at a time. The snapshot is the map of the tables; the rows of the
    # one on screen are asked for by name.
    MAX_ROWS = 5000

    def table_rows(self, name: str, where: str = "", order: str = "",
                   limit: int = 0, offset: int = 0) -> dict:
        """ONE PAGE of one table: the condition, the order and the paging are the
        database's job.

        Measured cost of doing it the other way: handing the rows to the
        interface takes time proportional to the number of VALUES crossing the
        boundary - applications (3505 rows x 20 columns) took 1.5 s per tab
        switch, package_files 0.5 s, while small tables took 0.10 s. A page is 50
        rows, so the boundary crossing is constant no matter how large the table.

        The table name is checked against the registry and the ORDER BY column
        against the real columns; the condition is executed by a read-only
        connection, as everywhere else.
        """
        with self._con() as c:
            names = {r["name"] for r in c.execute("SELECT name FROM _tabs")}
            if name not in names:
                return {"rows": [], "total": 0, "error": "no such table"}
            cols = set(self._columns(c, name)) | {"_id"}
        sql = f'SELECT * FROM "{name}"'
        cnt = f'SELECT COUNT(*) FROM "{name}"'
        if where and where.strip():
            sql += " WHERE " + where
            cnt += " WHERE " + where
        if order:
            field, _, direction = order.partition(" ")
            if field in cols:
                sql += f' ORDER BY "{field}"'
                sql += " DESC" if direction.upper().startswith("DESC") else " ASC"
        if limit:
            sql += f" LIMIT {int(limit)} OFFSET {int(offset)}"
        try:
            con = sqlite3.connect(f"file:{self.path}?mode=ro", uri=True, timeout=5)
            con.row_factory = sqlite3.Row
            rows = [dict(r) for r in con.execute(sql)]
            total = con.execute(cnt).fetchone()[0]
            con.close()
        except Exception as e:
            return {"rows": [], "total": 0, "error": str(e)}
        return {"rows": rows, "total": total, "error": ""}

    def snapshot(self) -> dict:
        import json
        tabs = []
        with self._con() as c:
            for t in c.execute("SELECT * FROM _tabs"):
                cols = self._columns(c, t["name"])
                count = c.execute(
                    f'SELECT COUNT(*) FROM "{t["name"]}"').fetchone()[0]
                try:
                    colcfg = json.loads(t["colcfg"]) if t["colcfg"] else None
                except Exception:
                    colcfg = None
                tabs.append({"name": t["name"], "title": t["title"],
                             "icon": t["icon"], "builtin": bool(t["builtin"]),
                             "columns": cols, "count": count, "colcfg": colcfg,
                             # WHEN THIS TABLE WAS FILLED LAST TIME:
                             # without it "empty" cannot be told apart from
                             # "not collected for a long time"
                             "collected_at": (t["collected_at"]
                                              if "collected_at" in t.keys() else "")})
        return {"os": coll.os_info(), "tabs": tabs,
                "collected_at": time.strftime("%H:%M:%S")}

    # -------- SQL search (read only) --------
    def query(self, sql: str) -> dict:
        try:
            con = sqlite3.connect(f"file:{self.path}?mode=ro", uri=True)
            con.row_factory = sqlite3.Row
            cur = con.execute(sql)
            cols = [d[0] for d in cur.description] if cur.description else []
            # we read one row more than the limit so that we can HONESTLY say
            # the result was truncated: a query for 5000 rows used to return
            # 1000 silently, and the user assumed they saw everything
            LIMIT = 1000
            raw = cur.fetchmany(LIMIT + 1)
            truncated = len(raw) > LIMIT
            rows = [{k: _txt(r[k]) if not isinstance(r[k], (int, float))
                     else r[k] for k in cols} for r in raw[:LIMIT]]
            con.close()
            return {"columns": cols, "rows": rows, "error": "",
                    "truncated": truncated, "limit": LIMIT}
        except Exception as e:
            return {"columns": [], "rows": [], "error": str(e)}

    # -------- edits from the UI --------
    def add_column(self, tab: str, col: str):
        col = _san(col, "c")
        with self._con() as c:
            if self._valid(c, tab) and col not in self._columns(c, tab):
                c.execute(f'ALTER TABLE "{tab}" ADD COLUMN "{col}" TEXT')

    def create_tab(self, title: str):
        name = "u_" + _san(title, "t")
        with self._con() as c:
            if c.execute("SELECT 1 FROM _tabs WHERE name=?", (name,)).fetchone():
                return
            c.execute(f'CREATE TABLE "{name}"(_id INTEGER PRIMARY KEY,'
                      f'"name" TEXT)')
            c.execute("INSERT INTO _tabs(name,title,icon,builtin,keys)"
                      " VALUES(?,?,?,0,'')",
                      (name, title.strip() or name, "view-list-details"))

    def delete_tab(self, tab: str):
        with self._con() as c:
            if c.execute("SELECT 1 FROM _tabs WHERE name=? AND builtin=0",
                         (tab,)).fetchone():
                c.execute(f'DROP TABLE "{tab}"')
                c.execute("DELETE FROM _tabs WHERE name=?", (tab,))

    def set_cell(self, tab: str, rowid: int, col: str, value: str):
        with self._con() as c:
            if self._valid(c, tab) and col in self._columns(c, tab):
                c.execute(f'UPDATE "{tab}" SET "{col}"=? WHERE _id=?',
                          (value, rowid))

    def set_colcfg(self, tab: str, cfg: str):
        with self._con() as c:
            if self._valid(c, tab):
                c.execute("UPDATE _tabs SET colcfg=? WHERE name=?", (cfg, tab))

    def add_row(self, tab: str):
        with self._con() as c:
            if self._valid(c, tab):
                c.execute(f'INSERT INTO "{tab}" DEFAULT VALUES')

    def delete_row(self, tab: str, rowid: int):
        with self._con() as c:
            if self._valid(c, tab):
                c.execute(f'DELETE FROM "{tab}" WHERE _id=?', (rowid,))

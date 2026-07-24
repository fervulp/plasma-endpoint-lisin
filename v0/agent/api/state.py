"""State: the database snapshot, table edits, process details, SQL."""
from PySide6.QtCore import Slot


class StateApi:
    # A Backend mixin: the slots are registered in metaObject on
    # inheritance Backend(QObject, ...) - verified.

    @Slot()
    def reload(self):
        self.stateReady.emit(self.db.snapshot())

    @Slot(result=bool)
    def isCollecting(self):
        return bool(getattr(self, "collecting", False))

    @Slot()
    def collectNow(self):
        """COLLECT NOW - without waiting for the schedule.

        The sources have their own intervals (six hours for vulnerabilities, for
        instance), and after installing patches there is no point waiting half a
        day. The run happens in a separate thread: the interface does not freeze,
        and a fresh snapshot arrives when it finishes.
        """
        import threading

        def go():
            try:
                self.collecting = True
                self.collectingChanged.emit()
                self.pipe.run_pipeline("state")
            finally:
                self.collecting = False
                self.collectingChanged.emit()
                self.stateReady.emit(self.db.snapshot())

        threading.Thread(target=go, daemon=True).start()


    @Slot(result="QVariant")
    def eventTaxonomy(self):
        """The event taxonomy: ALL field names + the fields grouped by category.
        Feeds the events tab - every taxonomy field is offered in the query bar's
        SELECT (there are 107, not the 13 shown by default), and the Details
        sidebar groups the fields by category so an analyst orients faster."""
        from agent.core import taxonomy as tx
        spec = tx.load()
        return {
            "names": tx.names(spec),
            "groups": [{"group": g["group"],
                        "fields": [f["name"] for f in g["fields"]]}
                       for g in tx.groups(spec)],
        }

    @Slot(str, str, str, int, int, result="QVariant")
    def tableRows(self, table, where, order, limit, offset):
        """ONE PAGE of a state table: condition, order and paging done by the DB.

        A snapshot used to carry every row of every table - 115 thousand rows,
        22.9 MB - and the model was rebuilt on each refresh. Worse, the cost of
        handing rows to the interface grows with the number of VALUES crossing
        the boundary: a tab switch to applications (3505 rows x 20 columns) took
        1.5 s. A page is 50 rows, so the cost no longer depends on the size of
        the table.
        """
        try:
            # EVENTS live in a separate database (append-only, retention) but are
            # shown as just another Data tab, so route them to events.db here. The
            # order defaults to newest-first inside recent() when none is given.
            if str(table) == "events":
                ev = self.pipe.events()
                w = str(where or "").strip()
                lim = int(limit) if int(limit) > 0 else 1000
                res = ev.recent(limit=lim, offset=int(offset), where=w,
                                order=self._events_order(str(order or "")))
                return {"rows": res.get("rows", []),
                        "total": ev.count(w), "error": ""}
            return self.db.table_rows(str(table), str(where), str(order),
                                      int(limit), int(offset))
        except Exception as e:
            return {"rows": [], "total": 0, "error": str(e)}

    def _events_order(self, order):
        """Validate a sort fragment against the taxonomy: only known fields and
        ASC/DESC reach the SQL (an empty result -> recent() falls back to ts DESC)."""
        from agent.core import taxonomy as tx
        names = set(tx.names(tx.load())) | {"_id"}
        out = []
        for part in str(order or "").split(","):
            toks = part.strip().split()
            if toks and toks[0] in names:
                d = toks[1].upper() if len(toks) > 1 and toks[1].upper() in (
                    "ASC", "DESC") else "ASC"
                out.append('"%s" %s' % (toks[0], d))
        return ", ".join(out)

    # -------- JOIN in the query builder (state tables only) --------
    def _tab_cols(self):
        return {t["name"]: list(t.get("columns") or [])
                for t in self.db.snapshot().get("tabs", [])}

    @Slot(str, result="QVariant")
    def joinTables(self, base):
        """State tables that can be joined to `base` (events.db is a separate
        database, so it is excluded). Each carries its columns for the ON picker."""
        cols = self._tab_cols()
        return [{"name": n, "columns": [c for c in cs if not c.startswith("_")]}
                for n, cs in sorted(cols.items())
                if n not in (str(base), "events", "vulnerabilities")]

    @Slot(str, str, result="QVariant")
    def joinSuggest(self, base, join):
        """Suggest the ON pair for base<->join: first a DISCOVERED link (columns
        whose values actually overlap), else a column of the same name in both."""
        base, join = str(base), str(join)
        cols = self._tab_cols()
        # EVENTS (a separate database) joined to a state table: the link model is
        # over state.db only, so use well-known event->state keys.
        if base == "events":
            from agent.core import taxonomy as tx
            enames = set(tx.names(tx.load()))
            hints = {"processes": ("process_pid", "pid"),
                     "ports": ("destination_ip", "remote"),
                     "users": ("user_name", "name"),
                     "applications": ("package_name", "name"),
                     "services": ("service_name", "unit"),
                     "open_files": ("file_path", "path"),
                     "scheduled": ("service_name", "name"),
                     "unix_sockets": ("process_pid", "pid")}
            h = hints.get(join)
            if h and join in cols and h[0] in enames and h[1] in cols[join]:
                return {"left": h[0], "right": h[1]}
            return {"left": "", "right": ""}
        if base not in cols or join not in cols:
            return {"left": "", "right": ""}
        try:
            from agent.analysis import links
            for l in links.model(self.db).get("links", []):
                if l["from_table"] == base and l["to_table"] == join:
                    return {"left": l["from_col"], "right": l["to_col"]}
                if l["to_table"] == base and l["from_table"] == join:
                    return {"left": l["to_col"], "right": l["from_col"]}
        except Exception:
            pass
        common = [c for c in cols[base]
                  if c in cols[join] and not c.startswith("_")]
        # prefer meaningful keys over generic ones
        for pref in ("package", "name", "unit", "pid", "user", "path", "package"):
            if pref in common:
                return {"left": pref, "right": pref}
        return {"left": common[0], "right": common[0]} if common else {"left": "", "right": ""}

    @Slot(str, str, str, str, str, str, int, int, result="QVariant")
    def tableJoinRows(self, base, join, left, right, where, order, limit, offset):
        """ONE PAGE of `base` LEFT JOINed with `join` on base.left = join.right.

        The WHERE/ORDER/paging are applied to `base` in a SUBQUERY first, so an
        unqualified column in the condition can never be ambiguous; the join then
        just decorates each base row with the matching columns of `join` (prefixed
        `join.col`). State tables only - both live in the same database.
        """
        base, join = str(base), str(join)
        left, right = str(left), str(right)
        if base == "events":
            return self._events_join(join, left, right, where, order, limit, offset)
        cols = self._tab_cols()
        if base not in cols or join not in cols:
            return {"rows": [], "columns": [], "total": 0, "error": "unknown table"}
        if left not in cols[base] or right not in cols[join]:
            return {"rows": [], "columns": [], "total": 0, "error": "unknown ON field"}
        w = str(where or "").strip()
        # validate the sort against base columns
        oparts = []
        for part in str(order or "").split(","):
            toks = part.strip().split()
            if toks and toks[0] in cols[base]:
                d = toks[1].upper() if len(toks) > 1 and toks[1].upper() in (
                    "ASC", "DESC") else "ASC"
                oparts.append('"%s" %s' % (toks[0], d))
        sub = 'SELECT * FROM "%s"' % base
        if w:
            sub += " WHERE " + w
        if oparts:
            sub += " ORDER BY " + ", ".join(oparts)
        lim = int(limit) if int(limit) > 0 else 1000
        sub += " LIMIT %d OFFSET %d" % (lim, max(0, int(offset)))
        jcols = [c for c in cols[join] if not c.startswith("_")]
        jsel = ", ".join('j."%s" AS "%s.%s"' % (c, join, c) for c in jcols)
        sql = 'SELECT b.*%s FROM (%s) b LEFT JOIN "%s" j ON b."%s" = j."%s"' % (
            (", " + jsel) if jsel else "", sub, join, left, right)
        res = self.db.query(sql)
        # total = base rows matching the condition (paging is over base)
        try:
            cnt = self.db.query('SELECT COUNT(*) AS n FROM "%s"%s'
                                % (base, (" WHERE " + w) if w else ""))
            total = cnt.get("rows", [{}])[0].get("n", 0)
        except Exception:
            total = len(res.get("rows", []))
        columns = [c for c in cols[base] if not c.startswith("_")] + \
                  ["%s.%s" % (join, c) for c in jcols]
        return {"rows": res.get("rows", []), "columns": columns,
                "total": total, "error": res.get("error", "")}

    # curated events columns shown in a join result (same idea as the Events tab)
    _EVJOIN_COLS = ["ts", "event_module", "event_category", "event_action",
                    "event_outcome", "process_name", "process_pid", "user_name",
                    "destination_ip", "object_type", "object_name", "message"]

    def _events_join(self, join, left, right, where, order, limit, offset):
        """events LEFT JOINed with a STATE table. The subquery over events applies
        WHERE/ORDER/paging, then the state table decorates each event. Events and
        state live in ONE file (data.db) now, so this is a native join - no
        cross-database ATTACH."""
        from agent.core import taxonomy as tx
        cols = self._tab_cols()
        enames = set(tx.names(tx.load()))
        if join not in cols:
            return {"rows": [], "columns": [], "total": 0, "error": "unknown table"}
        if left not in enames or right not in cols[join]:
            return {"rows": [], "columns": [], "total": 0, "error": "unknown ON field"}
        w = str(where or "").strip()
        oparts = []
        for part in str(order or "").split(","):
            toks = part.strip().split()
            if toks and toks[0] in enames:
                d = toks[1].upper() if len(toks) > 1 and toks[1].upper() in (
                    "ASC", "DESC") else "ASC"
                oparts.append('"%s" %s' % (toks[0], d))
        lim = int(limit) if int(limit) > 0 else 1000
        sub = "SELECT * FROM events"
        if w:
            sub += " WHERE " + w
        sub += " ORDER BY " + (", ".join(oparts) if oparts else "ts DESC")
        sub += " LIMIT %d OFFSET %d" % (lim, max(0, int(offset)))
        ecur = ["_id"] + [c for c in self._EVJOIN_COLS if c in enames]
        jcols = [c for c in cols[join] if not c.startswith("_")]
        bsel = ", ".join('b."%s"' % c for c in ecur)
        jsel = ", ".join('j."%s" AS "%s.%s"' % (c, join, c) for c in jcols)
        sql = ('SELECT %s%s FROM (%s) b LEFT JOIN "%s" j ON b."%s" = j."%s"'
               % (bsel, (", " + jsel) if jsel else "", sub, join, left, right))
        try:
            # events and the state table are in ONE file now - a native join on
            # the shared read connection, no ATTACH
            con = self.db._reader()
            rows = [dict(r) for r in con.execute(sql)]
            tot = con.execute("SELECT COUNT(*) AS n FROM events%s"
                              % ((" WHERE " + w) if w else "")).fetchone()["n"]
        except Exception as e:
            return {"rows": [], "columns": [], "total": 0, "error": str(e)}
        columns = [c for c in ecur if c != "_id"] + \
                  ["%s.%s" % (join, c) for c in jcols]
        return {"rows": rows, "columns": columns, "total": tot, "error": ""}


    @Slot(str, str, str, result="QVariant")
    def stateGroups(self, table, fields, where):
        """Field values with counts - the left column of the grouping.

        The same mechanism as for events (`eventGroups`), only over a state table:
        the table name and every field are checked against the snapshot, so
        nothing foreign gets into the SQL.
        """
        table = (table or "").strip()
        # events live in events.db and are grouped there; their columns come from
        # the taxonomy, not the state snapshot.
        events = table == "events"
        if events:
            from agent.core import taxonomy as tx
            cols = set(tx.names(tx.load()))
        else:
            snap = self.db.snapshot()
            tab = next((t for t in snap.get("tabs", []) if t["name"] == table), None)
            if tab is None:
                return {"rows": [], "fields": [], "error": "unknown table"}
            cols = set(tab.get("columns") or [])
        fs = [f.strip() for f in str(fields or "").split(",") if f.strip()]
        fs = [f for f in fs if f in cols]
        if not fs:
            return {"rows": [], "fields": [], "error": "unknown field"}
        exprs = [f'''COALESCE("{f}", '')''' for f in fs]
        sel = ", ".join(f'{e} AS "v{i}"' for i, e in enumerate(exprs))
        sql = f'SELECT {sel}, COUNT(*) AS n FROM "{table}"'
        w = (where or "").strip()
        if w:
            sql += " WHERE " + w
        sql += " GROUP BY " + ", ".join(exprs) + " ORDER BY n DESC LIMIT 300"
        res = self.pipe.events().query(sql) if events else self.db.query(sql)
        rows = []
        for r in res.get("rows", []):
            parts = [str(r.get(f"v{i}") or "") for i in range(len(fs))]
            rows.append({"value": " · ".join(p if p else "(empty)" for p in parts),
                         "parts": parts, "n": r.get("n", 0)})
        return {"rows": rows, "fields": fs, "error": res.get("error", "")}


    # -------- pipelines --------

    # -------- the "State" dashboard --------
    @Slot(str, result="QVariant")
    def sqlQuery(self, sql):
        return self.db.query(sql)

    # -------- expertise --------
    @Slot(str, str)
    def addColumn(self, tab, col):
        self.db.add_column(tab, col)
        self.reload()

    @Slot(str)
    def createTab(self, title):
        self.db.create_tab(title)
        self.reload()

    @Slot(str)
    def deleteTab(self, tab):
        self.db.delete_tab(tab)
        self.reload()

    @Slot(str, str)
    def setTabColumns(self, tab, cfg):
        self.db.set_colcfg(tab, cfg)
        self.reload()

    @Slot(str, int, str, str)
    def setCell(self, tab, rowid, col, value):
        self.db.set_cell(tab, rowid, col, value)

    @Slot(str)
    def addRow(self, tab):
        self.db.add_row(tab)
        self.reload()

    @Slot(str, int)
    def deleteRow(self, tab, rowid):
        self.db.delete_row(tab, rowid)
        self.reload()


_instance_lock = None   # we keep the fd open for the whole life of the process



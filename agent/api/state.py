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
    def livePids(self):
        """The PIDs of processes that are STILL ALIVE (from the state snapshot).

        It is needed so that an event can offer a jump into the process graph:
        offering it for a long-dead process makes no sense. Computed once per page
        of events, not once per event.
        """
        snap = self.db.snapshot()
        tab = next((t for t in snap.get("tabs", []) if t["name"] == "processes"), None)
        out = {}
        for r in (tab.get("rows", []) if tab else []):
            pid = str(r.get("pid") or "").strip()
            if pid:
                out[pid] = str(r.get("command") or "")
        return out

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
            return self.db.table_rows(str(table), str(where), str(order),
                                      int(limit), int(offset))
        except Exception as e:
            return {"rows": [], "total": 0, "error": str(e)}

    @Slot(str, str, result="QVariant")
    def stateRows(self, table, where):
        """ROWS OF A STATE TABLE BY AN SQL CONDITION.

        The condition used to be parsed by QML: it split the string on " AND " and
        understood neither OR nor NOT nor MATCH (which turns into LIKE '%...%'), so
        part of the condition silently did not work. Now the database itself
        filters - one mechanism for both events and state.

        The table name is checked against the list of tables and the database is
        opened read only (StateDB.query), so nothing foreign gets into the SQL.
        """
        table = (table or "").strip()
        names = {t["name"] for t in self.db.snapshot().get("tabs", [])}
        if table not in names:
            return {"rows": [], "error": "unknown table"}
        sql = 'SELECT * FROM "%s"' % table
        w = (where or "").strip()
        if w:
            sql += " WHERE " + w
        res = self.db.query(sql)
        return {"rows": res.get("rows", []), "error": res.get("error", ""),
                "truncated": bool(res.get("truncated"))}

    @Slot(str, str, str, result="QVariant")
    def stateGroups(self, table, fields, where):
        """Field values with counts - the left column of the grouping.

        The same mechanism as for events (`eventGroups`), only over a state table:
        the table name and every field are checked against the snapshot, so
        nothing foreign gets into the SQL.
        """
        table = (table or "").strip()
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
        res = self.db.query(sql)
        rows = []
        for r in res.get("rows", []):
            parts = [str(r.get(f"v{i}") or "") for i in range(len(fs))]
            rows.append({"value": " · ".join(p if p else "(empty)" for p in parts),
                         "parts": parts, "n": r.get("n", 0)})
        return {"rows": rows, "fields": fs, "error": res.get("error", "")}

    @Slot(str, result="QVariant")
    def stateSearch(self, q):
        """SEARCH ACROSS THE WHOLE STATE: which table contains a value.

        An analyst usually does not search "in the process table" but simply for an
        address, a file name or a user - and wants to know where it exists at all.
        We walk every state table, look for the substring in any column and return
        the table, the number of matches and a few examples.
        """
        q = (q or "").strip()
        if len(q) < 2:
            return {"query": q, "tables": [], "total": 0, "error": ""}
        ql = q.lower()
        out, total = [], 0
        # THE STATE SNAPSHOT - the same one the interface sees: we search in
        # exactly what is shown, without a separate path to the database.
        snap = self.db.snapshot()
        for tab in snap.get("tabs", []):
            name = tab.get("name") or ""
            cols = [c for c in (tab.get("columns") or []) if not c.startswith("_")]
            hits = []
            for r in tab.get("rows", []):
                for c in cols:
                    if ql in str(r.get(c) or "").lower():
                        hits.append(r)
                        break
            if not hits:
                continue
            hit_cols = [c for c in cols
                        if any(ql in str(r.get(c) or "").lower() for r in hits[:50])]
            total += len(hits)
            out.append({"table": name, "title": tab.get("title") or name,
                        "icon": tab.get("icon") or "",
                        "n": len(hits), "columns": hit_cols[:4],
                        "sample": [{k: str(v) for k, v in r.items()
                                    if not k.startswith("_")} for r in hits[:3]]})
        out.sort(key=lambda d: -d["n"])
        return {"query": q, "tables": out, "total": total, "error": ""}

    # -------- pipelines --------
    @Slot(str, result="QVariant")
    def processDetails(self, pid):
        from agent.collect import procinfo
        rows = next((t["rows"] for t in self.db.snapshot()["tabs"]
                     if t["name"] == "processes"), [])
        return procinfo.details(pid, rows)

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



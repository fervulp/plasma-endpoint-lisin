"""Состояние: снимок БД, правки таблиц, детали процесса, SQL."""
from PySide6.QtCore import Slot


class StateApi:
    # Миксин Backend: слоты регистрируются в metaObject при
    # наследовании Backend(QObject, ...) — проверено.

    @Slot()
    def reload(self):
        self.stateReady.emit(self.db.snapshot())

    @Slot(result=bool)
    def isCollecting(self):
        return bool(getattr(self, "collecting", False))

    @Slot()
    def collectNow(self):
        """СОБРАТЬ СЕЙЧАС — не дожидаясь расписания.

        У источников свои интервалы (у уязвимостей, например, 6 часов), и
        после установки патчей ждать полдня незачем. Прогон идёт в отдельном
        потоке: интерфейс не замирает, а по окончании приходит свежий снимок.
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
        """PID процессов, которые ЕЩЁ ЖИВЫ (снимок состояния).

        Нужен, чтобы у события можно было предложить переход в граф процесса:
        предлагать его для давно умершего процесса бессмысленно. Считается
        один раз на страницу событий, а не на каждое событие.
        """
        snap = self.db.snapshot()
        tab = next((t for t in snap.get("tabs", []) if t["name"] == "processes"), None)
        out = {}
        for r in (tab.get("rows", []) if tab else []):
            pid = str(r.get("pid") or "").strip()
            if pid:
                out[pid] = str(r.get("command") or "")
        return out

    @Slot(str, str, result="QVariant")
    def stateRows(self, table, where):
        """СТРОКИ ТАБЛИЦЫ СОСТОЯНИЯ ПО SQL-УСЛОВИЮ.

        Раньше условие разбирал QML: он делил строку по « AND » и не понимал
        ни OR, ни NOT, ни MATCH (тот превращается в LIKE '%…%'), поэтому часть
        условий молча не работала. Теперь фильтрует сама база — один механизм
        и в событиях, и в состоянии.

        Имя таблицы сверяется со списком таблиц, база открыта только на
        чтение (StateDB.query), поэтому в SQL не попадает ничего чужого.
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
        """Значения полей с количествами — левая колонка группировки.

        Тот же механизм, что у событий (`eventGroups`), только по таблице
        состояния: имя таблицы и каждое поле сверяются со снимком, поэтому в
        SQL не попадает ничего постороннего.
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
        """ПОИСК ПО ВСЕМУ СОСТОЯНИЮ: в какой таблице встречается значение.

        Аналитик обычно ищет не «в таблице процессов», а просто адрес, имя
        файла или пользователя — и хочет знать, где это вообще есть. Идём по
        всем таблицам состояния, ищем подстроку в любой колонке, возвращаем
        таблицу, число совпадений и несколько примеров.
        """
        q = (q or "").strip()
        if len(q) < 2:
            return {"query": q, "tables": [], "total": 0, "error": ""}
        ql = q.lower()
        out, total = [], 0
        # СНИМОК СОСТОЯНИЯ — тот же, что видит интерфейс: ищем ровно в том,
        # что показано, без отдельного пути к базе.
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

    # -------- конвейеры --------
    @Slot(str, result="QVariant")
    def processDetails(self, pid):
        from agent import procinfo
        rows = next((t["rows"] for t in self.db.snapshot()["tabs"]
                     if t["name"] == "processes"), [])
        return procinfo.details(pid, rows)

    # -------- дашборд «Состояние» --------
    @Slot(str, result="QVariant")
    def sqlQuery(self, sql):
        return self.db.query(sql)

    # -------- экспертиза --------
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


_instance_lock = None   # держим fd открытым всю жизнь процесса



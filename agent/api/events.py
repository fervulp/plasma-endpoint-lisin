"""События: лента, SQL-условия, группировка, история и сохранённые запросы."""
import re

from PySide6.QtCore import Slot

# --- приём из RQL R-Vision: поиск по подсетям оператором IN ---
# В RQL пишут `sourceIp IN '192.0.2.0/24'`. SQLite про IP ничего не знает,
# поэтому переводим CIDR в префиксный LIKE (для /8, /16, /24 и /32).
_CIDR_RE = re.compile(
    r"""(?i)\b("?\w+"?)\s+(NOT\s+)?IN\s+'(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})'""")


def _rql_cidr(where: str) -> str:
    def sub(m):
        field, neg, ip, bits = m.group(1), (m.group(2) or ""), m.group(3), int(m.group(4))
        o = ip.split(".")
        if bits == 32:
            pat = ip
        elif bits == 24:
            pat = ".".join(o[:3]) + ".%"
        elif bits == 16:
            pat = ".".join(o[:2]) + ".%"
        elif bits == 8:
            pat = o[0] + ".%"
        else:
            return m.group(0)      # нестандартный префикс — оставляем как есть
        op = "NOT LIKE" if neg.strip() else "LIKE"
        return f"{field} {op} '{pat}'"
    return _CIDR_RE.sub(sub, where or "")


# сколько строк просматривает статистика полей: порог показывается в UI
SCAN_LIMIT = 20000


class EventsApi:
    # Миксин Backend: слоты регистрируются в metaObject при
    # наследовании Backend(QObject, ...) — проверено.

    # -------- цепочки событий --------
    # Отдельная запись почти ничего не значит; значение появляется, когда
    # видна последовательность. Цепочка связывает события родословной
    # процессов (а где процесса нет — по пользователю, и это помечается).
    @Slot(result="QVariant")
    def eventChains(self):
        from agent import chains
        try:
            return chains.build(self.pipe.events(), statedb=self.db)
        except Exception as e:
            return {"error": str(e), "chains": [], "total": 0}

    @Slot(str, result="QVariant")
    def chainDetail(self, cid):
        from agent import chains
        try:
            return chains.detail(self.pipe.events(), str(cid), statedb=self.db)
        except Exception as e:
            return {"error": str(e), "steps": []}

    @Slot(int, int, str, str, str, str, result="QVariant")
    def eventList(self, limit, offset, q, category, module, outcome):
        """Лента событий с фильтрами. Имена колонок — литералы из кода,
        значения — только через параметры (никакой склейки SQL из данных)."""
        db = self.pipe.events()
        where, params = [], []
        if q and q.strip():
            like = f"%{q.strip()}%"
            where.append("(message LIKE ? OR process_name LIKE ? OR "
                         "process_executable LIKE ? OR destination_ip LIKE ? OR "
                         "user_name LIKE ? OR event_action LIKE ?)")
            params += [like] * 6
        for col, val in (("event_category", category), ("event_module", module),
                         ("event_outcome", outcome)):
            if val:
                where.append(f'"{col}" = ?')
                params.append(val)
        w = " AND ".join(where)
        try:
            res = db.recent(limit=limit, offset=offset, where=w,
                            params=tuple(params))
            res["total"] = db.count(w, tuple(params))
            res["error"] = ""
            return res
        except Exception as e:
            return {"rows": [], "columns": [], "total": 0, "error": str(e)}

    @Slot(result="QVariant")
    def eventStats(self):
        try:
            return self.pipe.events().stats()
        except Exception as e:
            return {"total": 0, "error": str(e), "by_category": [],
                    "by_module": [], "by_outcome": []}

    # -------- события: SQL, группировка, история запросов --------
    @Slot(str, result="QVariant")
    def eventQuery(self, sql):
        """Произвольный SELECT к events.db (mode=ro). Только SELECT —
        всё остальное отклоняем ещё до открытия соединения."""
        s = (sql or "").strip().rstrip(";")
        if not re.match(r"(?is)^\s*select\b", s):
            return {"columns": [], "rows": [], "error": "Only SELECT is allowed"}
        if re.search(r"(?is)\b(attach|pragma|insert|update|delete|drop|alter|create)\b", s):
            return {"columns": [], "rows": [], "error": "Only SELECT is allowed"}
        res = self.pipe.events().query(s)
        if not res.get("error"):
            self._sql_hist_add(s)
        return res

    @Slot(str, int, int, str, result="QVariant")
    def eventRows(self, where, limit, offset, order=""):
        """Лента событий по SQL-условию WHERE (его строит панель фильтров:
        + добавляет значение, − исключает). База открыта только на чтение.

        order — порядок сортировки из запроса («ts DESC, user»). Имена полей
        СВЕРЯЮТСЯ С ТАКСОНОМИЕЙ, направление — только ASC/DESC: в SQL не
        попадает ничего постороннего.
        """
        db = self.pipe.events()
        w = _rql_cidr((where or "").strip())
        try:
            res = db.recent(limit=limit, offset=offset, where=w,
                            order=self._safe_order(order))
            res["total"] = db.count(w)
            res["error"] = ""
            return res
        except Exception as e:
            return {"rows": [], "columns": [], "total": 0, "error": str(e)}

    def _safe_order(self, order):
        """Разбор ORDER BY: только известные поля и ASC/DESC."""
        from agent import taxonomy as tx
        names = set(tx.names(tx.load())) | {"_id"}
        out = []
        for part in str(order or "").split(","):
            t = part.strip().split()
            if not t or t[0] not in names:
                continue
            d = "DESC" if len(t) > 1 and t[1].upper() == "DESC" else "ASC"
            out.append(f'"{t[0]}" {d}')
        return ", ".join(out)

    @Slot(str)
    def eventSqlRemember(self, sql):
        """Запомнить SQL-условие (WHERE), собранное кнопками +/− или набранное
        руками, чтобы оно попало в историю и в подсказки похожих."""
        s = (sql or "").strip()
        if s:
            self._sql_hist_add(s)

    def _sql_hist_add(self, sql: str):
        from agent import config
        hist = config.get("events_sql_history", []) or []
        hist = [h for h in hist if h != sql]
        hist.insert(0, sql)
        config.set_("events_sql_history", hist[:200])

    @Slot(int, result="QVariant")
    def eventSqlHistory(self, limit):
        from agent import config
        hist = config.get("events_sql_history", []) or []
        return hist[:max(1, int(limit or 10))]

    @Slot(str, int, result="QVariant")
    def eventSqlSuggest(self, text, limit):
        """Похожие запросы из ВСЕЙ истории (не только из топ-10): набрал
        что-то похожее на запрос 200 шагов назад — он и подскажется."""
        import difflib
        from agent import config
        t = (text or "").strip().lower()
        hist = config.get("events_sql_history", []) or []
        if not t:
            return hist[:max(1, int(limit or 5))]
        scored = []
        for h in hist:
            hl = h.lower()
            r = difflib.SequenceMatcher(None, t, hl).ratio()
            if t in hl:
                r = max(r, 0.85)
            scored.append((r, h))
        scored.sort(key=lambda x: -x[0])
        return [h for r, h in scored[:max(1, int(limit or 5))] if r >= 0.34]

    @Slot(str, str, result="QVariant")
    def eventGroups(self, field, where):
        """Значения колонки (или НЕСКОЛЬКИХ колонок) с количествами — левая
        колонка группировки.

        `field` — одно имя или несколько через запятую: группировка «по
        нескольким параметрам» ничем не отличается от SQL `GROUP BY a, b`.
        Каждое имя сверяется с таксономией, поэтому в SQL не попадает ничего
        постороннего. В ответе `value` — читаемая склейка значений, `parts`
        — сами значения по полям (из них строится условие фильтра).
        """
        from agent import taxonomy as tx
        names = set(tx.names(tx.load()))
        fields = [f.strip() for f in str(field or "").split(",") if f.strip()]
        fields = [f for f in fields if f in names]
        if not fields:
            return {"rows": [], "fields": [], "error": "unknown field"}
        # NULL и '' для пользователя — одна и та же «пустая» ячейка, но
        # GROUP BY делает из них ДВЕ группы, и счётчик перестаёт сходиться с
        # тем, что реально покажет таблица. Схлопываем их через COALESCE.
        exprs = [f"""COALESCE("{f}", '')""" for f in fields]
        cols = ", ".join(f'{e} AS "v{i}"' for i, e in enumerate(exprs))
        where = _rql_cidr(where or "")
        sql = f'SELECT {cols}, COUNT(*) AS n FROM events'
        if where and where.strip():
            sql += " WHERE " + where
        sql += " GROUP BY " + ", ".join(exprs) + " ORDER BY n DESC LIMIT 300"
        res = self.pipe.events().query(sql)
        rows = []
        for r in res.get("rows", []):
            parts = [str(r.get(f"v{i}") or "") for i in range(len(fields))]
            rows.append({"value": " · ".join(p if p else "(empty)" for p in parts),
                         "parts": parts, "n": r.get("n", 0)})
        return {"rows": rows, "fields": fields, "error": res.get("error", "")}

    @Slot(str, result="QVariant")
    def eventFieldStats(self, where):
        """СТАТИСТИКА ПО ВСЕМ ПОЛЯМ для текущей выборки.

        Отвечает на вопрос «какие поля вообще заполнены и чем» — то, с чего
        начинают разбор в зрелых SIEM. Считаем ОДНИМ проходом по выборке в
        Python, а не 98 запросами `COUNT(DISTINCT)`: так и быстрее, и порог
        выборки виден честно (поле `truncated`).
        """
        from agent import taxonomy as tx
        names = tx.names(tx.load())
        where = _rql_cidr(where or "")
        sql = "SELECT * FROM events"
        if where and where.strip():
            sql += " WHERE " + where
        res = self.pipe.events().query(sql + " ORDER BY ts DESC", max_rows=SCAN_LIMIT)
        if res.get("error"):
            return {"fields": [], "total": 0, "error": res["error"]}
        rows = res.get("rows", [])
        counts = {}          # поле -> {значение: сколько}
        filled = {}          # поле -> в скольких строках заполнено
        for r in rows:
            for k, v in r.items():
                if k not in names or v is None or v == "":
                    continue
                filled[k] = filled.get(k, 0) + 1
                d = counts.setdefault(k, {})
                sv = str(v)
                if len(d) < 5000 or sv in d:
                    d[sv] = d.get(sv, 0) + 1
        out = []
        total = len(rows)
        for f in names:
            n = filled.get(f, 0)
            if not n:
                continue
            vals = sorted(counts.get(f, {}).items(), key=lambda kv: -kv[1])
            out.append({
                "field": f,
                "filled": n,
                "percent": round(100.0 * n / total) if total else 0,
                "unique": len(counts.get(f, {})),
                "values": [{"value": v, "n": c} for v, c in vals[:12]],
            })
        # сверху — поля, у которых значений НЕМНОГО: по ним и фильтруют
        out.sort(key=lambda d: (d["unique"] > 1, d["unique"], -d["filled"]))
        return {"fields": out, "total": total,
                "truncated": bool(res.get("truncated")),
                "empty_fields": len([f for f in names if not filled.get(f)]),
                "all_fields": len(names), "error": ""}

    # -------- сохранённые запросы (expertise/queries/, вне fedora) --------
    @Slot(result="QVariant")
    def eventFields(self):
        # таксономия по группам — для панели деталей события
        from agent import taxonomy as tx
        try:
            return tx.groups(tx.load())
        except Exception:
            return []

    @Slot(result="QVariant")
    def savedQueries(self):
        from agent import queries
        try:
            return queries.listing()
        except Exception:
            return []

    @Slot(result="QVariant")
    def queryDirs(self):
        from agent import queries
        try:
            return queries.dirs()
        except Exception:
            return ["general"]

    @Slot(str, str, str, str, result=str)
    def saveQuery(self, directory, name, sql, description):
        from agent import queries
        try:
            ref = queries.save(directory, name, sql, description)
            self.pipe.reload()
            return ref
        except Exception as e:
            return "error: " + str(e)

    @Slot(str, result=str)
    def createQueryDir(self, name):
        from agent import queries
        try:
            return queries.make_dir(name)
        except Exception:
            return ""

    @Slot(str, result=bool)
    def deleteQuery(self, ref):
        from agent import queries
        try:
            ok = queries.delete(ref)
            if ok:
                self.pipe.reload()
            return ok
        except Exception:
            return False


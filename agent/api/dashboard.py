"""Дашборды и агрегация: сводка состояния, EDR-разбор процесса, инвентарь."""
from PySide6.QtCore import Slot


class DashboardApi:
    # Миксин Backend: слоты регистрируются в metaObject при
    # наследовании Backend(QObject, ...) — проверено.

    @Slot(result="QVariant")
    def dashboardState(self):
        from agent import dashboard
        try:
            return dashboard.build(self.db, self.pipe.events())
        except Exception as e:
            return {"error": str(e), "tiles": [], "graph": {"nodes": [], "edges": []},
                    "top_rss": [], "top_cpu": [], "top_deps": [], "top_dest": [],
                    "exposure": []}

    @Slot(str, result="QVariant")
    def processDeep(self, pid):
        """EDR-разбор процесса для дашборда: потребление, как запустился,
        что сделал, пакет и его зависимости, соседи бинарника, systemd-юнит."""
        from agent import dashboard
        try:
            return dashboard.process_detail(self.db, self.pipe.events(), pid)
        except Exception as e:
            return {"error": str(e)}

    # -------- Process context: агрегация процессов в сущности --------
    @Slot(result="QVariant")
    def processEntities(self):
        # схлопывает сырые процессы в СУЩНОСТИ (вендорский набор из 6
        # процессов → одна строка) с агрегированным контекстом из ports/
        # unix_sockets/persistence/config/applications. Open files — лениво.
        from agent import entities
        try:
            return entities.build(self.db)
        except Exception as e:
            return {"error": str(e)}

    @Slot("QVariant", result="QVariant")
    def entityFiles(self, pids):
        # ленивая догрузка открытых файлов сущности при разворачивании
        from agent import entities
        try:
            return entities.files_for([str(p) for p in pids])
        except Exception:
            return []

    # -------- события (таксономия + events.db) --------
    @Slot(result="QVariant")
    def programsInventory(self):
        # классификация applications на ПРОГРАММЫ vs зависимости
        # (3000 пакетов → ~200 программ, остальное — зависимости под ними)
        from agent import entities
        try:
            return entities.programs(self.db)
        except Exception as e:
            return {"error": str(e)}

    @Slot(result="QVariant")
    def systemFindings(self):
        """Находки: что в системе выглядит не так и что с этим делать."""
        from agent import findings
        try:
            # правила берём из ЭКСПЕРТИЗЫ, а не из кода: их видно в разделе
            # «Экспертиза» (категория «Находки») и можно править в YAML
            return findings.build(self.db, self.pipe.events(),
                                  self.pipe.objects.get("findings", {}))
        except Exception as e:
            return {"error": str(e), "findings": [], "total": 0,
                    "high": 0, "medium": 0, "low": 0}

    @Slot(result="QVariant")
    @Slot(str, result="QVariant")
    def vulnRows(self, where):
        """Бюллетени по SQL-условию — тем же способом, что лента событий.

        Фильтр больше не разбирается в интерфейсе: OR, NOT и MATCH там
        понимались неверно, и часть условий молча не срабатывала.
        """
        sql = ("SELECT status, severity, cvss_score, cvss_rating, cvss_vector, "
               "cvss_source, cvss_covered, advisory, packages, packages_count, "
               "installed_version, fixed_version, cve, cve_count, issued, "
               'title, action, risk, source, "references", description '
               "FROM vulnerabilities")
        w = (where or "").strip()
        if w:
            sql += " WHERE " + w
        sql += (" ORDER BY CASE status WHEN 'open' THEN 0 ELSE 1 END, "
                "CAST(cvss_score AS REAL) DESC, CASE severity "
                "WHEN 'Critical' THEN 1 WHEN 'Important' THEN 2 "
                "WHEN 'Moderate' THEN 3 ELSE 4 END, issued DESC")
        res = self.db.query(sql)
        return {"rows": res.get("rows", []), "error": res.get("error", "")}

    @Slot(result="QVariant")
    def vulnerabilities(self):
        """Уязвимости: и открытые, и уже закрытые патчем.

        Закрытые не выбрасываются намеренно. Пользователь обновил систему —
        он должен УВИДЕТЬ, что вопрос закрыт (и когда), а не обнаружить, что
        строки просто исчезли и непонятно, сработало обновление или сломался
        сбор данных. Сортировка — по баллу CVSS: он сравним между
        бюллетенями, в отличие от словесной критичности Fedora.
        """
        try:
            q = self.db.query(
                "SELECT status, severity, cvss_score, cvss_rating, cvss_vector, "
                "cvss_source, cvss_covered, advisory, packages, packages_count, "
                "installed_version, fixed_version, cve, cve_count, issued, "
                # references — ключевое слово SQL, поэтому в кавычках
                'title, action, risk, source, "references", description '
                "FROM vulnerabilities"
                " ORDER BY CASE status WHEN 'open' THEN 0 ELSE 1 END, "
                "CAST(cvss_score AS REAL) DESC, CASE severity "
                "WHEN 'Critical' THEN 1 WHEN 'Important' THEN 2 "
                "WHEN 'Moderate' THEN 3 ELSE 4 END, issued DESC")
            rows = q.get("rows", [])
            by, cvss, scored = {}, {}, []
            for r in rows:
                if r.get("status") == "open":
                    by[r.get("severity") or "—"] = by.get(r.get("severity") or "—", 0) + 1
                rt = r.get("cvss_rating") or ""
                if rt:
                    cvss[rt] = cvss.get(rt, 0) + 1
                try:
                    scored.append(float(r.get("cvss_score") or 0))
                except ValueError:
                    pass
            op = [r for r in rows if r.get("status") == "open"]
            # покрытие оценкой — честный признак «сколько ещё не оценено»
            have = sum(1 for s in scored if s > 0)
            return {"rows": rows, "total": len(rows), "open": len(op),
                    "closed": len(rows) - len(op), "by_severity": by,
                    "by_cvss": cvss, "scored": have,
                    "source": rows[0].get("source", "") if rows else "",
                    "error": ""}
        except Exception as e:
            return {"rows": [], "total": 0, "open": 0, "closed": 0,
                    "by_severity": {}, "by_cvss": {}, "scored": 0, "error": str(e)}

    # -------- связи между компонентами --------
    @staticmethod
    def _str_list(v):
        """Список строк из того, что пришло из QML.

        JS-массив приходит как QJSValue, а он НЕ итерируемый: попытка
        пройти по нему роняла слот, граф возвращал ошибку и карточка графа
        просто исчезала. Разворачиваем через toVariant().
        """
        if v is None:
            return []
        if hasattr(v, "toVariant"):
            v = v.toVariant()
        if isinstance(v, (str, bytes)):
            return [str(v)]
        try:
            return [str(x) for x in v]
        except TypeError:
            return []

    @Slot(str, result="QVariant")
    @Slot(str, "QVariantList", result="QVariant")
    @Slot(str, "QVariant", result="QVariant")
    def processLinks(self, pid, expanded=None):
        """Граф вокруг процесса; expanded — какие категории раскрыты."""
        from agent import links
        try:
            return links.around(self.db, self.pipe.events(), str(pid),
                                expanded=self._str_list(expanded))
        except Exception as e:
            return {"error": str(e), "nodes": [], "edges": []}

    @Slot(str, str, result="QVariant")
    @Slot(str, str, "QVariantList", result="QVariant")
    @Slot(str, str, "QVariant", result="QVariant")
    def anchorGraph(self, kind, val, expanded=None):
        """ПИВОТ: граф вокруг сущности любого типа (process|application|port|
        user|config|open_file). Раскладка в Python, expanded — раскрытые
        категории. Контракт возврата один и тот же для всех якорей."""
        from agent import links
        try:
            return links.anchor_graph(self.db, self.pipe.events(),
                                      str(kind), str(val),
                                      expanded=self._str_list(expanded))
        except Exception as e:
            return {"error": str(e), "nodes": [], "edges": []}

    @Slot("QVariant", result="QVariant")
    def nodeInfo(self, node):
        """ВСЁ об объекте узла графа — для боковой панели.

        Узел события ведёт в events и показывает ВСЕ непустые поля
        таксономии, сгруппированные как в разделе «События». Остальные узлы
        идут в links.node_detail (строка своей таблицы + связанные строки).
        """
        n = node.toVariant() if hasattr(node, "toVariant") else (node or {})
        if not isinstance(n, dict):
            return {"sections": [], "error": "node not recognised"}
        table = str(n.get("table") or "")
        if table == "events":
            return self._event_node_info(n)
        if not table:
            return {"sections": [], "error": "this node has no data source"}
        from agent import links
        return links.node_detail(self.db, self.pipe.events(), table,
                                 str(n.get("col") or ""), str(n.get("val") or ""))

    def _event_node_info(self, n):
        """Все поля конкретного события, сгруппированные по таксономии."""
        ev = self.pipe.events()
        if ev is None:
            return {"sections": [], "error": "event database is unavailable"}
        action = str(n.get("val") or "")
        pid = str(n.get("pid") or "")
        where, args = "event_action = ?", [action]
        if pid:
            where += " AND process_pid = ?"
            args.append(pid)
        rows = ev.query("SELECT * FROM events WHERE %s ORDER BY ts DESC LIMIT 1"
                        % where, tuple(args)).get("rows", [])
        if not rows:
            return {"sections": [], "error": "event not found"}
        row = rows[0]
        try:
            from agent import taxonomy
            spec = taxonomy.load()
            grouped = taxonomy.groups(spec)
        except Exception:
            grouped = []
        sections, shown = [], set()
        for g in grouped:
            items = []
            for f in g["fields"]:
                name = f["name"] if isinstance(f, dict) else str(f)
                v = row.get(name)
                if v is None or str(v).strip() == "":
                    continue
                shown.add(name)
                items.append({"k": name, "v": str(v)[:400]})
            if items:
                sections.append({"title": g["group"], "rows": items})
        # поля вне таксономии (диагностика контракта) — тоже показываем
        rest = [{"k": k, "v": str(v)[:400]} for k, v in row.items()
                if k not in shown and not k.startswith("_")
                and str(v or "").strip()]
        if rest:
            sections.append({"title": "other", "rows": rest})
        return {"sections": sections, "error": ""}

    @Slot(str, result="QVariant")
    def anchorList(self, kind):
        """Список сущностей выбранного типа для «view by» — чтобы выбрать,
        от чего строить граф. Только чтение, значения экранированы."""
        from agent import links
        SRC = {"process": ("processes", "pid", "command"),
               "application": ("applications", "name", "description"),
               "port": ("ports", "port", "process"),
               "user": ("users", "name", "privilege"),
               "config": ("app_config", "path", "scope"),
               "open_file": ("open_files", "path", "process")}
        k = str(kind)
        if k not in SRC:
            return {"items": []}
        # ПОРТЫ — это СОКЕТЫ, а не просто номера. Показываем адреса целиком
        # («tcp 192.0.2.10:33244 → 198.51.100.7:993 · thunderbird»),
        # иначе по IP в этом списке ничего не найти: раньше были только номер
        # порта и имя процесса.
        if k == "port":
            try:
                q = self.db.query(
                    "SELECT port AS v, proto, local, remote, process, exposure "
                    "FROM ports WHERE COALESCE(port,'')<>'' "
                    "ORDER BY (CASE WHEN COALESCE(remote,'')<>'' "
                    "          AND remote NOT LIKE '%*%' THEN 0 ELSE 1 END), "
                    "         CAST(port AS INTEGER) LIMIT 400")
                items = []
                for r in q.get("rows", []):
                    rem = str(r.get("remote") or "")
                    sub = "%s %s" % (str(r.get("proto") or "").upper(),
                                     r.get("local") or "")
                    if rem and "*" not in rem:
                        sub += " → " + rem
                    else:
                        sub += " · " + str(r.get("exposure") or "")
                    if r.get("process"):
                        sub += "  ·  " + str(r["process"])
                    items.append({"val": r["v"], "sub": sub})
                return {"items": items, "kind": k}
            except Exception as e:
                return {"items": [], "error": str(e)}
        table, keyc, subc = SRC[k]
        try:
            q = self.db.query(
                'SELECT DISTINCT "%s" AS v, "%s" AS s FROM "%s" '
                'WHERE COALESCE("%s",\'\')<>\'\' ORDER BY "%s" LIMIT 400'
                % (keyc, subc, table, keyc, keyc))
            return {"items": [{"val": r["v"], "sub": r.get("s") or ""}
                              for r in q.get("rows", [])], "kind": k}
        except Exception as e:
            return {"items": [], "error": str(e)}

    @Slot(str, str, str, result="QVariant")
    def nodeDetail(self, table, col, val):
        """Всё, что известно об объекте узла графа: своя строка + связанные
        таблицы (по обнаруженной карте связей) + его последние события."""
        from agent import links
        try:
            return links.node_detail(self.db, self.pipe.events(),
                                     str(table), str(col), str(val))
        except Exception as e:
            return {"sections": [], "error": str(e)}

    @Slot(result="QVariant")
    def linkModel(self):
        """Карта связей между таблицами — обнаруживается измерением
        пересечения значений колонок, а не зашита в коде."""
        from agent import links
        try:
            return links.model(self.db)
        except Exception as e:
            return {"error": str(e), "nodes": [], "links": []}
    # -------- тематические панели расследования --------
    @Slot(result="QVariant")
    def fileActivity(self):
        from agent import panels
        try:
            return panels.file_activity(self.db, self.pipe.events())
        except Exception as e:
            return {"error": str(e), "events": [], "by_action": [], "by_dir": []}

    @Slot(result="QVariant")
    def privescActivity(self):
        from agent import panels
        try:
            return panels.privesc_activity(self.db, self.pipe.events())
        except Exception as e:
            return {"error": str(e), "events": [], "vectors": []}

    @Slot(result="QVariant")
    def networkFlows(self):
        from agent import panels
        try:
            return panels.network_flows(self.db, self.pipe.events())
        except Exception as e:
            return {"error": str(e), "flows": [], "dns": []}

    @Slot(str, result="QVariant")
    def flowDetail(self, ip):
        """Клик по сессии: кто говорил, когда, чем и куда смотреть дальше."""
        from agent import panels
        try:
            return panels.flow_detail(self.db, self.pipe.events(), str(ip))
        except Exception as e:
            return {"ip": ip, "error": str(e), "events": [], "processes": []}

    @Slot(str, result="QVariant")
    def whoisLookup(self, ip):
        """Интерактивный WHOIS по клику на адрес."""
        from agent import ipintel
        try:
            return ipintel.whois_details(str(ip))
        except Exception as e:
            return {"ip": ip, "error": str(e)}

    @Slot(str, result="QVariant")
    def whoisLookup(self, ip):
        """Интерактивный WHOIS по клику на адрес."""
        from agent import ipintel
        try:
            return ipintel.whois_details(str(ip))
        except Exception as e:
            return {"ip": ip, "error": str(e)}

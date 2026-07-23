"""Dashboards and aggregation: the state summary, the EDR process breakdown, the inventory."""
from PySide6.QtCore import Slot


# ---- THE COST OF AN AGGREGATE IS PAID ONCE ----
# Every panel recomputes from scratch: the network one walks 104 thousand
# network events (468 ms), the dashboard rebuilds the process tree (145 ms).
# The interface asks for them on every state refresh - and a refresh now arrives
# once a second while the pipeline collects, so the window froze for half of
# every second.
#
# The answer only changes when the DATA changes, so it is cached by the
# modification time of the two databases plus a short ceiling: a repeat within
# the same second returns the previous answer, and a write invalidates it at
# once. Nothing is stored between runs - this is a memo, not a store.
_CACHE = {}
_TTL = 3.0


def _stamp(*paths):
    import os
    out = []
    for p in paths:
        try:
            out.append(os.path.getmtime(p))
        except OSError:
            out.append(0)
    return tuple(out)


def _memo(self, name, build):
    import time
    ev = getattr(self.pipe, "_events", None)
    sig = _stamp(self.db.path, getattr(ev, "path", "")) if ev else _stamp(self.db.path)
    hit = _CACHE.get(name)
    now = time.time()
    if hit and hit[0] == sig and now - hit[1] < _TTL:
        return hit[2]
    val = build()
    _CACHE[name] = (sig, now, val)
    return val


class DashboardApi:
    # A Backend mixin: the slots are registered in metaObject on
    # inheritance Backend(QObject, ...) - verified.

    @Slot(result="QVariant")
    def dashboardState(self):
        from agent.analysis import dashboard
        try:
            return _memo(self, "dashboard",
                         lambda: dashboard.build(self.db, self.pipe.events()))
        except Exception as e:
            return {"error": str(e), "tiles": [], "graph": {"nodes": [], "edges": []},
                    "top_rss": [], "top_cpu": [], "top_deps": [], "top_dest": [],
                    "exposure": []}

    @Slot(str, result="QVariant")
    def processDeep(self, pid):
        """The EDR breakdown of a process for the dashboard: consumption, how it
        started, what it did, the package and its dependencies, the systemd unit."""
        from agent.analysis import dashboard
        try:
            return dashboard.process_detail(self.db, self.pipe.events(), pid)
        except Exception as e:
            return {"error": str(e)}

    @Slot(str, result="QVariant")
    def processHistory(self, pid):
        """The process activity as a TIMELINE (sidebar sections grouped by day) -
        what the Activity-history block in the graph shows when clicked."""
        from agent.analysis import dashboard
        try:
            return dashboard.history_sections(self.pipe.events(), pid)
        except Exception as e:
            return {"sections": [], "error": str(e)}

    # -------- Process context: aggregating processes into entities --------
    @Slot(result="QVariant")
    def processEntities(self):
        # collapses raw processes into ENTITIES (a vendor set of 6 processes ->
        # one row) with aggregated context from ports/unix_sockets/persistence/
        # config/applications. Open files are loaded lazily.
        from agent.analysis import entities
        try:
            return entities.build(self.db)
        except Exception as e:
            return {"error": str(e)}

    @Slot("QVariant", result="QVariant")
    def entityFiles(self, pids):
        # lazy loading of the open files of an entity when it is expanded
        from agent.analysis import entities
        try:
            return entities.files_for([str(p) for p in pids])
        except Exception:
            return []

    # -------- events (the taxonomy + events.db) --------
    @Slot(result="QVariant")
    def programsInventory(self):
        # classifying applications into PROGRAMS vs dependencies
        # (3000 packages -> ~200 programs, the rest are dependencies under them)
        from agent.analysis import entities
        try:
            return entities.programs(self.db)
        except Exception as e:
            return {"error": str(e)}

    @Slot(result="QVariant")
    def systemFindings(self):
        """Findings: what looks wrong in the system and what to do about it."""
        from agent.analysis import findings
        try:
            # the rules come from the EXPERTISE, not from the code: they are visible
            # in the "Expertise" section (the "Findings" category) and editable in YAML
            return findings.build(self.db, self.pipe.events(),
                                  self.pipe.objects.get("findings", {}))
        except Exception as e:
            return {"error": str(e), "findings": [], "total": 0,
                    "high": 0, "medium": 0, "low": 0}

    @Slot(result="QVariant")
    @Slot(str, result="QVariant")
    def vulnRows(self, where):
        """Advisories by an SQL condition - the same way as the event feed.

        The filter is no longer parsed in the interface: OR, NOT and MATCH were
        understood incorrectly there, and part of a condition silently did not fire.
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
        """Vulnerabilities: both the open ones and the ones already closed by a patch.

        The closed ones are deliberately not dropped. If a user updated the system
        they must SEE that the question is closed (and when) rather than discover
        that the rows simply vanished, with no way to tell whether the update worked
        or the data collection broke. Sorted by the CVSS score: it is comparable
        between advisories, unlike the wording of the Fedora severity.
        """
        try:
            q = self.db.query(
                "SELECT status, severity, cvss_score, cvss_rating, cvss_vector, "
                "cvss_source, cvss_covered, advisory, packages, packages_count, "
                "installed_version, fixed_version, cve, cve_count, issued, "
                # references is an SQL keyword, hence the quotes
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
                # the scoring coverage - an honest measure of "how much is unscored"
            have = sum(1 for s in scored if s > 0)
            return {"rows": rows, "total": len(rows), "open": len(op),
                    "closed": len(rows) - len(op), "by_severity": by,
                    "by_cvss": cvss, "scored": have,
                    "source": rows[0].get("source", "") if rows else "",
                    "error": ""}
        except Exception as e:
            return {"rows": [], "total": 0, "open": 0, "closed": 0,
                    "by_severity": {}, "by_cvss": {}, "scored": 0, "error": str(e)}

    # -------- links between components --------
    @staticmethod
    def _str_list(v):
        """A list of strings out of whatever arrived from QML.

        A JS array arrives as a QJSValue, and that is NOT iterable: trying to walk
        it crashed the slot, the graph returned an error and the graph card simply
        disappeared. We unwrap it through toVariant().
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
        """The graph around a process; expanded is which categories are open."""
        from agent.analysis import links
        try:
            return links.around(self.db, self.pipe.events(), str(pid),
                                expanded=self._str_list(expanded))
        except Exception as e:
            return {"error": str(e), "nodes": [], "edges": []}

    @Slot(str, str, result="QVariant")
    @Slot(str, str, "QVariantList", result="QVariant")
    @Slot(str, str, "QVariant", result="QVariant")
    def anchorGraph(self, kind, val, expanded=None):
        """THE PIVOT: a graph around an entity of any type (process|application|port|
        user|config|open_file). The layout is computed in Python, expanded holds the
        open categories. The return contract is the same for every anchor."""
        from agent.analysis import links
        try:
            return links.anchor_graph(self.db, self.pipe.events(),
                                      str(kind), str(val),
                                      expanded=self._str_list(expanded))
        except Exception as e:
            return {"error": str(e), "nodes": [], "edges": []}

    @Slot("QVariant", result="QVariant")
    def nodeInfo(self, node):
        """EVERYTHING about the object of a graph node - for the side panel.

        An event node leads into events and shows ALL the non-empty taxonomy fields,
        grouped as in the "Events" section. The other nodes go to links.node_detail
        (the row of their own table + the related rows).
        """
        n = node.toVariant() if hasattr(node, "toVariant") else (node or {})
        if not isinstance(n, dict):
            return {"sections": [], "error": "node not recognised"}
        table = str(n.get("table") or "")
        if table == "events":
            return self._event_node_info(n)
        if not table:
            return {"sections": [], "error": "this node has no data source"}
        from agent.analysis import links
        return links.node_detail(self.db, self.pipe.events(), table,
                                 str(n.get("col") or ""), str(n.get("val") or ""))

    def _event_node_info(self, n):
        """All the fields of a specific event, grouped by the taxonomy."""
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
            from agent.core import taxonomy
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
        # fields outside the taxonomy (a diagnostic of the contract) are shown too
        rest = [{"k": k, "v": str(v)[:400]} for k, v in row.items()
                if k not in shown and not k.startswith("_")
                and str(v or "").strip()]
        if rest:
            sections.append({"title": "other", "rows": rest})
        return {"sections": sections, "error": ""}

    @Slot(str, result="QVariant")
    def anchorList(self, kind):
        """The list of entities of the chosen type for "view by" - to pick what to
        build the graph from. Read only, the values are escaped."""
        from agent.analysis import links
        SRC = {"process": ("processes", "pid", "command"),
               "application": ("applications", "name", "description"),
               "port": ("ports", "port", "process"),
               "user": ("users", "name", "privilege"),
               "config": ("app_config", "path", "scope"),
               "open_file": ("open_files", "path", "process")}
        k = str(kind)
        if k not in SRC:
            return {"items": []}
        # PORTS ARE SOCKETS, not just numbers. We show the addresses in full,
        # («tcp 192.0.2.10:33244 → 198.51.100.7:993 · thunderbird»),
        # otherwise nothing can be found by IP in this list: it used to hold only
        # the port number and the process name.
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
        """Everything known about the object of a graph node: its own row + the
        related tables (by the discovered link map) + its latest events."""
        from agent.analysis import links
        try:
            return links.node_detail(self.db, self.pipe.events(),
                                     str(table), str(col), str(val))
        except Exception as e:
            return {"sections": [], "error": str(e)}

    @Slot(result="QVariant")
    def linkModel(self):
        """The map of links between tables - discovered by measuring the overlap of
        column values, not hard-coded."""
        from agent.analysis import links
        try:
            return _memo(self, "linkmodel", lambda: links.model(self.db))
        except Exception as e:
            return {"error": str(e), "nodes": [], "links": []}
    # -------- thematic investigation panels --------
    @Slot(result="QVariant")
    def fileActivity(self):
        from agent.analysis import panels
        try:
            return _memo(self, "files",
                         lambda: panels.file_activity(self.db, self.pipe.events()))
        except Exception as e:
            return {"error": str(e), "events": [], "by_action": [], "by_dir": []}

    @Slot(result="QVariant")
    def privescActivity(self):
        from agent.analysis import panels
        try:
            return _memo(self, "privesc",
                         lambda: panels.privesc_activity(self.db, self.pipe.events()))
        except Exception as e:
            return {"error": str(e), "events": [], "vectors": []}

    @Slot(result="QVariant")
    def networkFlows(self):
        from agent.analysis import panels
        try:
            return _memo(self, "netflows",
                         lambda: panels.network_flows(self.db, self.pipe.events()))
        except Exception as e:
            return {"error": str(e), "flows": [], "dns": []}

    @Slot(str, result="QVariant")
    def flowDetail(self, ip):
        """A click on a session: who talked, when, with what and where to look next."""
        from agent.analysis import panels
        try:
            return panels.flow_detail(self.db, self.pipe.events(), str(ip))
        except Exception as e:
            return {"ip": ip, "error": str(e), "events": [], "processes": []}

    @Slot(str, result="QVariant")
    def whoisLookup(self, ip):
        """Interactive WHOIS on a click on an address."""
        from agent.collect import ipintel
        try:
            return ipintel.whois_details(str(ip))
        except Exception as e:
            return {"ip": ip, "error": str(e)}

    @Slot(str, result="QVariant")
    def whoisLookup(self, ip):
        """Interactive WHOIS on a click on an address."""
        from agent.collect import ipintel
        try:
            return ipintel.whois_details(str(ip))
        except Exception as e:
            return {"ip": ip, "error": str(e)}

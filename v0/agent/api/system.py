"""System: module errors, metrics, settings."""

from PySide6.QtCore import Slot


class SystemApi:
    # A Backend mixin: the slots are registered in metaObject on
    # inheritance Backend(QObject, ...) - verified.

    @Slot(result="QVariant")
    def errorsLog(self):
        self._collect_errors()
        return list(self.errors_log)

    @Slot()
    def clearErrors(self):
        self.errors_log.clear()
        self._err_seen.clear()

    @Slot(result="QVariant")
    def systemMetrics(self):
        from agent.collect import metrics
        return metrics.system_metrics(self.sampler.series)

    @Slot(result="QVariant")
    def resourceUsage(self):
        from agent.collect import metrics
        return metrics.resource_usage()

    # -------- settings --------
    @Slot(result="QVariant")
    def getSettings(self):
        from agent.core import config
        return config.load()

    @Slot(str, str)
    def setSetting(self, key, value):
        from agent.core import config
        config.set_(key, value)

    @Slot(result="QVariant")
    def dbSizes(self):
        """How much the databases and each table weigh - for Settings. Per-table
        bytes come from the dbstat virtual table (real page usage); if it is not
        available, the row count stands in."""
        import os
        from agent.core import eventsdb as _ev
        from agent.core import config
        out = {"databases": [], "tables": [], "retention": _ev.MAX_ROWS,
               "max_mb": _ev.MAX_MB, "events": 0, "normalized_pct": 0,
               "unmapped": 0, "per_hour": 0}
        try:
            out["retention"] = int(config.get("events_retention", _ev.MAX_ROWS))
            out["max_mb"] = int(config.get("events_max_mb", _ev.MAX_MB))
        except Exception:
            pass
        # normalization coverage + arrival rate - the questions an analyst asks of
        # the feed. Fully normalized = not_normalized is empty (a rule parsed
        # everything); the rest still stored, with the missed field names recorded.
        try:
            ec = self.pipe.events()._reader()
            n = ec.execute("SELECT COUNT(*) AS n FROM events").fetchone()["n"]
            unm = ec.execute("SELECT COUNT(*) AS n FROM events "
                             "WHERE COALESCE(not_normalized,'')<>''").fetchone()["n"]
            out["events"] = n
            out["unmapped"] = unm
            out["normalized_pct"] = round(100 * (n - unm) / n, 1) if n else 0
            # rate over the last hour by arrival time (ingested)
            out["per_hour"] = ec.execute(
                "SELECT COUNT(*) AS n FROM events WHERE ingested >= "
                "strftime('%Y-%m-%dT%H:%M:%SZ','now','-1 hour')").fetchone()["n"]
        except Exception:
            pass
        # ONE file now: state and events share data.db
        try:
            out["databases"].append({"name": "Data",
                                     "bytes": os.path.getsize(str(self.db.path))})
        except Exception:
            out["databases"].append({"name": "Data", "bytes": 0})

        def _weights(con):
            try:
                return {r["name"]: int(r["b"] or 0) for r in con.execute(
                    "SELECT name, SUM(pgsize) AS b FROM dbstat GROUP BY name")}
            except Exception:
                return {}
        try:
            con = self.db._reader()
            w = _weights(con)
            for t in self.db.snapshot().get("tabs", []):
                nm = t["name"]
                try:
                    rc = con.execute('SELECT COUNT(*) AS n FROM "%s"' % nm).fetchone()["n"]
                except Exception:
                    rc = 0
                out["tables"].append({"name": nm, "db": "Data", "rows": rc,
                                      "bytes": w.get(nm, 0)})
            # the events table lives in the same file - add it from the same dbstat
            try:
                rc = con.execute("SELECT COUNT(*) AS n FROM events").fetchone()["n"]
                out["tables"].append({"name": "events", "db": "Data", "rows": rc,
                                      "bytes": w.get("events", 0)})
            except Exception:
                pass
        except Exception:
            pass
        out["tables"].sort(key=lambda x: -(x["bytes"] or x["rows"]))
        out["tables"] = out["tables"][:20]
        return out

    # -------- SQL search over the state --------

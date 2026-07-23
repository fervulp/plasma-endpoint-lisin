"""LiSin pipelines: graphs made of expertise objects.

The expertise (expertise/):
  inputs/<os>/*.yaml   - inputs (command, interval, enabled)
  normalize/*.yaml     - normalization (a Python plugin: code -> normalize(text))
  filters/*.yaml       - filters (conditions: field/op/value)
  correlation/*.yaml   - detections
  outputs/*.yaml       - outputs (type: statedb; postgres/syslog later)
  pipelines/*.yaml     - pipelines: nodes (id, kind, ref, x, y) + edges

Execution: on the input's interval the command is run and the result travels
along the edges of the graph: normalize -> rows, filter -> selection,
output(statedb) -> upsert into the table of the normalization rule.
"""
import json
import re
import subprocess
import threading
import time
from pathlib import Path

import yaml



EXPERTISE = Path(__file__).resolve().parent.parent / "expertise"


_PY_CACHE = {}   # sha1(code) -> the compiled normalize(text)


def _plugin(code: str, fname: str):
    """Compiles a Python plugin from a YAML rule and pulls the function out of it.

    Cached by (hash of the code, function name); re/json are put into the
    namespace so that plugins stay short. A plugin is self-contained - a rule can
    be handed to another user as a contribution. TRUST: like the inputs (bash -c),
    the rule's code is executed - import and enable only expertise you trust.
    """
    import hashlib
    h = (hashlib.sha1(code.encode("utf-8")).hexdigest(), fname)
    fn = _PY_CACHE.get(h)
    if fn is None:
        # EXPERTISE - so that a plugin can read REFERENCE DATA from
        # expertise/reference/*.yaml (human names of ports, processes and so on)
        # without hard-coding the paths.
        ns = {"re": re, "json": json, "EXPERTISE": EXPERTISE}
        try:
            exec(compile(code, "<plugin>", "exec"), ns)
        except Exception as e:
            raise RuntimeError(f"plugin does not compile: {e}") from e
        fn = ns.get(fname)
        if not callable(fn):
            raise RuntimeError(f"code has no function {fname}()")
        _PY_CACHE[h] = fn
    return fn


def run_python(code: str, text: str) -> list[dict]:
    """A NORMALIZATION plugin: normalize(text) -> list[dict]."""
    rows = _plugin(code, "normalize")(text)
    if not isinstance(rows, list):
        raise RuntimeError("normalize(text) must return list[dict]")
    return rows


def run_enrich(code: str, rows: list) -> list[dict]:
    """An ENRICHMENT plugin: enrich(rows) -> list[dict] (the same rows + fields)."""
    out = _plugin(code, "enrich")(rows)
    if not isinstance(out, list):
        raise RuntimeError("enrich(rows) must return list[dict]")
    return out


# The category of an object is decided by the type field in the YAML, not by the
# directory. Directories (fedora, ...) are just packages of objects; you can
# create your own.
CATEGORIES = {
    "inputs": "Inputs",
    "normalize": "Normalization",
    "enrich": "Enrichment",
    "filters": "Filters",
    "correlation": "Correlation",
    "outputs": "Outputs",
    "taxonomy": "Taxonomy",
    "queries": "Queries",
    "reference": "Reference",
    "findings": "Findings",
}
TYPE2CAT = {"input": "inputs", "normalization_rule": "normalize",
            "enrichment": "enrich",
            "filter": "filters", "detection": "correlation",
            "correlation_rule": "correlation",
            "output": "outputs", "statedb": "outputs", "syslog": "outputs",
            # events: an output into events.db (schema from the taxonomy)
            "events": "outputs", "taxonomy": "taxonomy",
            # saved search queries (expertise/queries/<directory>/*.yaml)
            "query": "queries",
            # reference data for enrichment (reference/*.yaml)
            "reference": "reference",
            # finding rules (expertise/findings/*.yaml)
            "finding": "findings"}
KIND2CAT = {"input": "inputs", "normalize": "normalize", "enrich": "enrich",
            "filter": "filters", "correlation": "correlation",
            "correlation": "correlation", "output": "outputs"}

TYPE_BY_CAT = {"inputs": "input", "normalize": "normalization_rule",
               "filters": "filter", "correlation": "correlation_rule",
               "outputs": "output"}
ID_LETTER = {"inputs": "I", "normalize": "N", "filters": "F",
             "correlation": "C", "outputs": "O"}
TEMPLATES = {
    "inputs": "name: {n}\nid: {id}\ntype: input\nversion: 1.0.0\n"
              "title: {n}\ncommand: [\"echo\", \"hello\"]\n"
              "interval: 60\nenabled: true\n",
    "normalize": "name: {n}\nid: {id}\ntype: normalization_rule\n"
                 "version: 1.0.0\ntitle: {n}\n"
                 "# RULE CONTRACT (everything you need to write one):\n"
                 "#  * code is plain Python. It must define\n"
                 "#    normalize(text) -> list[dict]. text = stdout of the input.\n"
                 "#  * TABLE COLUMNS = keys of the returned dicts (order taken\n"
                 "#    from the first row). Nothing needs declaring.\n"
                 "#  * Table and key are set in the OUTPUT node, not here.\n"
                 "#  * re and json are already imported; you may import any\n"
                 "#    stdlib module.\n"
                 "#  * The Run button executes the rule against live input,\n"
                 "#    the Tests button runs the tests section below.\n"
                 "code: |\n"
                 "  def normalize(text):\n"
                 "      rows = []\n"
                 "      for line in text.splitlines():\n"
                 "          line = line.strip()\n"
                 "          if not line:\n"
                 "              continue\n"
                 "          rows.append({{\"name\": line}})\n"
                 "      return rows\n"
                 "# The test lives next to the rule: input + expectation.\n"
                 "# expect: rows (exact) | min_rows | contains {{...}} | row0 {{...}}\n"
                 "tests:\n"
                 "  - name: two non-empty lines\n"
                 "    input: |\n"
                 "      alpha\n"
                 "      beta\n"
                 "    expect:\n"
                 "      rows: 2\n"
                 "      contains: {{name: alpha}}\n",
    "filters": "name: {n}\nid: {id}\ntype: filter\nversion: 1.0.0\n"
               "title: {n}\n"
               "# conditions: a row passes when ALL of them are true.\n"
               "# op: eq | ne | contains | not_contains | regex | in | not_in\n"
               "conditions:\n"
               "  - field: name\n    op: contains\n    value: \"\"\n",
    "correlation": "name: {n}\nid: {id}\ntype: correlation_rule\nversion: 1.0.0\n"
                   "title: {n}\ntactic: 09_discovery\nseverity: low\n"
                   "description: \"\"\n"
                   "# detections are evaluated by the correlation engine\n",
    "outputs": "name: {n}\nid: {id}\ntype: statedb\nversion: 1.0.0\n"
               "title: {n}\ntable: {n}\nkey: [name]\n"
               "icon: view-list-details\n",
}


def _match(row: dict, cond: dict) -> bool:
    v = str(row.get(cond.get("field", ""), ""))
    op, ref = cond.get("op", "eq"), cond.get("value", "")
    if op == "eq":
        return v == str(ref)
    if op == "ne":
        return v != str(ref)
    if op == "contains":
        return str(ref) in v
    if op == "not_contains":
        return str(ref) not in v
    if op == "regex":
        return re.search(str(ref), v) is not None
    if op == "in":
        return v in [str(x) for x in ref]
    if op == "not_in":
        return v not in [str(x) for x in ref]
    return True


def _apply_templates(rows: list, templates: list) -> list:
    """A table of NOISE TEMPLATES: a row matching ANY template is either dropped
    (action: drop, the default) or only tagged (action: tag) - then it stays but
    with a mark in tags.

    A template: arbitrary event fields (except the service ones) are compared as a
    substring, while `match` is a regular expression over message. Empty fields of
    a template are ignored, so "provider: kwin_wayland" catches everything from it.
    """
    out = []
    for r in rows:
        hit = None
        for t in templates:
            if not isinstance(t, dict):
                continue
            ok = True
            for k, v in t.items():
                if k in ("action", "reason", "match", "name") or v in (None, ""):
                    continue
                if str(v).lower() not in str(r.get(k, "")).lower():
                    ok = False
                    break
            if ok and t.get("match"):
                try:
                    if not re.search(str(t["match"]), str(r.get("message", ""))):
                        ok = False
                except re.error:
                    ok = False
            if ok and (t.get("match") or any(
                    k not in ("action", "reason", "match", "name") and v
                    for k, v in t.items())):
                hit = t
                break
        if hit is None:
            out.append(r)
            continue
        if str(hit.get("action", "drop")).lower() == "tag":
            tags = str(r.get("tags", "") or "")
            mark = "noise:" + str(hit.get("reason") or hit.get("name") or "match")
            r["tags"] = (tags + "," + mark).strip(",")
            out.append(r)
        # action: drop -> the row simply does not get into out
    return out


class StatePipeline:
    def __init__(self, db):
        self.db = db
        self._events = None          # the event database is created on first output
        self.lock = threading.Lock()
        self.last: dict[tuple, float] = {}      # (pipe, node_id) -> ts
        self.status: dict[tuple, dict] = {}     # (pipe, node_id) -> {...}
        self.peek: dict[tuple, dict] = {}       # the last execution of a node
        self.errors: list[str] = []
        self.reload()

    # -------- loading the expertise --------
    def reload(self):
        self.objects: dict[str, dict] = {c: {} for c in CATEGORIES}
        self.errors = []
        for f in sorted(EXPERTISE.rglob("*.yaml")):
            rel = f.relative_to(EXPERTISE)
            if rel.parts[0] == "pipelines":
                continue
            ref = str(rel)[:-5]
            try:
                cfg = yaml.safe_load(f.read_text()) or {}
                cfg["_file"] = str(f)
                cat = TYPE2CAT.get(str(cfg.get("type", "")))
                if cat:
                    self.objects[cat][ref] = cfg
                else:
                    self.errors.append(
                        f"{ref}: unknown type {cfg.get('type', '')!r}")
            except Exception as e:
                self.errors.append(f"{ref}: {e}")
        self.pipelines: dict[str, dict] = {}
        for f in sorted((EXPERTISE / "pipelines").glob("*.yaml")):
            if f.name.endswith(".draft.yaml"):
                continue    # drafts are not executed
            try:
                p = yaml.safe_load(f.read_text()) or {}
                p.setdefault("nodes", [])
                p.setdefault("edges", [])
                p["_file"] = str(f)
                self.pipelines[p["name"]] = p
            except Exception as e:
                self.errors.append(f"pipelines/{f.stem}: {e}")
        # orphaned service tables (the source was removed, e.g. connections after
        # the merge into ports) are cleaned up; user tables are left alone
        keep = {o.get("table") for o in self.objects.get("outputs", {}).values()
                if o.get("table")}
        try:
            self.db.prune(keep)
        except Exception as e:
            self.errors.append(f"prune: {e}")

    # -------- schedule --------
    def due(self) -> list[tuple]:
        now = time.time()
        out = []
        for pn, pl in self.pipelines.items():
            for n in pl["nodes"]:
                if n["kind"] != "input":
                    continue
                cfg = self.objects["inputs"].get(n["ref"])
                if not cfg or not cfg.get("enabled", True):
                    continue
                if now - self.last.get((pn, n["id"]), 0) >= cfg.get("interval", 60):
                    out.append((pn, n["id"]))
        return out

    # -------- executing the graph --------
    def run_node(self, pipe: str, node_id: str):
        pl = self.pipelines.get(pipe)
        if not pl:
            return
        nodes = {n["id"]: n for n in pl["nodes"]}
        node = nodes.get(node_id)
        if not node or node["kind"] != "input":
            return
        cfg = self.objects["inputs"].get(node["ref"])
        st = {"rows": 0, "error": "", "ran_at": time.strftime("%H:%M:%S")}
        with self.lock:
            self.last[(pipe, node_id)] = time.time()
            try:
                if not cfg:
                    raise RuntimeError(f"no input {node['ref']!r}")
                cmd = cfg["command"]
                # the command is simply a shell string (a user does not have to
                # spell out an argv array); a list is supported as well
                if isinstance(cmd, str):
                    cmd = ["bash", "-c", cmd]
                text = subprocess.run(cmd, capture_output=True,
                                      text=True, timeout=60).stdout
                # the last execution of the input: its stdout
                self.peek[(pipe, node_id)] = {"out_text": text[:20000]}
                st["rows"] = self._walk(pl, nodes, node_id, pipe,
                                        {"text": text, "rows": None, "rule": None})
            except Exception as e:
                st["error"] = str(e)
        self.status[(pipe, node_id)] = st

    def events(self):
        """The event database (lazy): created only if there is a type:events output.
        The schema is built from the expertise/taxonomy/events.yaml taxonomy."""
        if self._events is None:
            from .eventsdb import EventsDB
            self._events = EventsDB()
        return self._events

    # the limit of change events per one run of one table: a mass update
    # (dnf upgrade over 200 packages) must not drown the feed.
    # Going over it is NOT hushed up - instead of rows a summary event is written.
    CHANGE_CAP = 150

    def _emit_changes(self, out: dict, table: str, keys: list, diff: dict) -> int:
        """State differences turned into events of the common taxonomy.

        One event = one transition: appeared / disappeared / changed.
        object_type = the table, object_name = the key of the row, so from an
        event one can always return to the state row, and from a row one can pull
        up its history. That is the "state <-> events" link.
        """
        import datetime
        if diff.get("was_empty"):
            return 0            # the first inventory is not a change
        # DERIVED COLUMNS ARE NOT A CHANGE OF THE SYSTEM.
        # deps_count/required_by and the like are computed by enrichment from
        # neighbouring rows: as soon as one package appears, dozens of other rows
        # are recomputed. On live data that produced "mass change, 22 changed" on
        # every run and drowned the real installation.
        # The list is declared in the OUTPUT (derived_columns), not in the code.
        derived = set(out.get("derived_columns") or [])
        items = []
        for kind, act, sev in (("added", "state_added", 30),
                               ("removed", "state_removed", 30),
                               ("changed", "state_changed", 25)):
            for it in diff.get(kind, []):
                if kind == "changed" and derived:
                    real = {k: v for k, v in (it.get("fields") or {}).items()
                            if k not in derived}
                    if not real:
                        continue          # only a computed value changed
                    it = {"key": it.get("key", []), "fields": real}
                items.append((kind, act, sev, it))
        if not items:
            return 0

        now = datetime.datetime.now(datetime.timezone.utc)
        ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")
        title = out.get("title", table)
        rows = []

        def base(act, sev, name, msg, detail=""):
            return {
                "ts": ts, "event_kind": "event", "event_category": "state",
                "event_type": "change", "event_action": act,
                "event_outcome": "success", "event_severity": sev,
                "event_module": "statediff", "event_dataset": table,
                "event_provider": "pipeline", "message": msg,
                "subject_type": "system", "subject_name": "system",
                "object_type": table, "object_name": name,
                # the deduplication key: the same change on a repeated run must
                # not produce a second record
                "event_id": "state:%s:%s:%s:%s" % (table, act, name,
                                                   detail or ts[:16]),
            }

        if len(items) > self.CHANGE_CAP:
            n_add = sum(1 for i in items if i[0] == "added")
            n_del = sum(1 for i in items if i[0] == "removed")
            n_chg = sum(1 for i in items if i[0] == "changed")
            bulk = base(
                "state_bulk_change", 35, title,
                "bulk change %r: %d added, %d removed, %d changed. "
                "Examples: %s (summarised — more than %d records)"
                % (title, n_add, n_del, n_chg,
                   "; ".join(" / ".join(str(x) for x in it.get("key", []))
                             for _, _, _, it in items[:8]),
                   self.CHANGE_CAP))
            # even a summary must show WHICH table it is about
            bulk.update({"change_table": table, "change_row": "",
                         "change_field": "", "change_old": "",
                         "change_new": ""})
            rows.append(bulk)
        else:
            for kind, act, sev, it in items:
                name = " / ".join(str(x) for x in it.get("key", []))
                if kind == "changed":
                    fields = it.get("fields", {})
                    # A SEPARATE EVENT PER FIELD: that way a transition reads
                    # structurally ("table X, field Y: was A, became B") and can
                    # be filtered and grouped by. As one line in message that was
                    # impossible.
                    for fld, val in list(fields.items())[:6]:
                        r = base(act, sev, name,
                                 "%s / %s - %s: %s -> %s"
                                 % (title, name, fld,
                                    (val[0] or "empty")[:60],
                                    (val[1] or "empty")[:60]), fld)
                        r.update({"change_table": table, "change_row": name,
                                  "change_field": fld,
                                  "change_old": val[0], "change_new": val[1]})
                        rows.append(r)
                else:
                    word = "added" if kind == "added" else "removed"
                    r = base(act, sev, name, "%s in \u00ab%s\u00bb: %s" % (word, title, name))
                    r.update({"change_table": table, "change_row": name,
                              "change_field": "", "change_old": "",
                              "change_new": ""})
                    rows.append(r)
        return self.events().append(rows)

    def _enrich(self, rows: list, enr: dict) -> list:
        """Enriching rows with columns from another state table (a link)."""
        table = enr.get("lookup_table", "")
        if not table or not rows:
            return rows
        lk_key = enr.get("lookup_key", "name")
        from_field = enr.get("from_field", "")
        pat = enr.get("extract", "")           # regex -> group 1 = the key
        add = enr.get("add", {})               # {new_column: column_in_lookup}
        # an index of the lookup table by its key
        idx = {}
        for r in self.db.query(f'SELECT * FROM "{table}"').get("rows", []):
            idx[str(r.get(lk_key, ""))] = r
        for row in rows:
            val = str(row.get(from_field, ""))
            if pat:
                m = re.search(pat, val)
                val = m.group(1) if m else ""
            hit = idx.get(val, {})
            for newcol, srccol in add.items():
                row[newcol] = hit.get(srccol, "")
        return rows

    def _walk(self, pl, nodes, nid, pipe, ctx) -> int:
        written = 0
        for a, b in pl["edges"]:
            if a != nid or b not in nodes:
                continue
            n = nodes[b]
            c = dict(ctx)
            # the last execution of the node: what arrived at its input
            peek = {"in_text": (ctx.get("text") or "")[:20000]
                    if ctx.get("rows") is None else None,
                    "in_rows": ctx.get("rows")[:200] if ctx.get("rows") else None}
            try:
                if n["kind"] == "normalize":
                    # normalization ONLY parses the input into rows of the right
                    # shape; which columns there are is decided by the rows
                    # themselves (the dict keys).
                    rule = self.objects["normalize"].get(n["ref"])
                    if not rule:
                        raise RuntimeError(f"no rule {n['ref']!r}")
                    # The normalization logic is a Python plugin right inside the
                    # YAML (the code field with a normalize(text)->list[dict]
                    # function). A rule is self-contained: metadata + code in one
                    # file, it can be shared as a community contribution.
                    # VRL/Vector is no longer used - all normalization is Python.
                    code = rule.get("code", "")
                    if not code.strip():
                        raise RuntimeError(
                            f"rule {rule['name']!r}: no Python plugin "
                            f"(code field with normalize(text))")
                    c["rows"] = run_python(code, c["text"])
                elif n["kind"] == "enrich":
                    # ENRICHMENT: adds columns from another table of the database
                    # by a link key. YAML: lookup_table, from_field, extract
                    # (regex for the key), lookup_key, add {new: lookup_column}
                    enr = self.objects["enrich"].get(n["ref"], {})
                    if c["rows"] is not None:
                        # two kinds of enrichment: a Python plugin (code:
                        # enrich(rows)) or a declarative link to a state table
                        ecode = enr.get("code", "")
                        if ecode.strip():
                            c["rows"] = run_enrich(ecode, c["rows"])
                        else:
                            c["rows"] = self._enrich(c["rows"], enr)
                elif n["kind"] == "filter":
                    # FILTER: conditions (ALL must be true) and/or templates - a
                    # table of noise templates: a row that matched ANY template is
                    # dropped (or marked in tags).
                    flt = self.objects["filters"].get(n["ref"], {})
                    conds = flt.get("conditions", [])
                    tmpls = flt.get("templates", [])
                    if c["rows"] is not None and conds:
                        c["rows"] = [r for r in c["rows"]
                                     if all(_match(r, cd) for cd in conds)]
                    if c["rows"] is not None and tmpls:
                        c["rows"] = _apply_templates(c["rows"], tmpls)
                elif n["kind"] == "correlation":
                    # CORRELATION: a rule looks at a window of events in events.db,
                    # not at the rows of this run - otherwise a "5 in 5 minutes"
                    # threshold cannot be assembled.
                    # ONE NODE = ONE RULE (by its ref). It used to run EVERY rule
                    # whatever the node pointed at, so four rules out of five hung
                    # in the catalogue as orphans while silently being executed -
                    # the graph did not show what was really running.
                    from . import correlate
                    all_rules = self.objects["correlation"]
                    rules = ({n["ref"]: all_rules[n["ref"]]}
                             if n.get("ref") in all_rules else all_rules)
                    rep = correlate.run(self.events(), rules)
                    peek["out_rows"] = rep["alerts"][:200]
                    peek["out_count"] = len(rep["alerts"])
                    if rep["errors"]:
                        peek["error"] = "; ".join(rep["errors"][:3])
                    written += rep["added"]
                elif n["kind"] == "output":
                    # the output decides the table/database/key; the columns are
                    # the union of the keys of all rows (order from the first)
                    out = self.objects["outputs"].get(n["ref"], {})
                    if out.get("type") == "events" and c["rows"]:
                        # EVENTS: append-only into events.db, schema from the
                        # taxonomy, dedup by the taxonomy key (INSERT OR IGNORE)
                        ev = self.events()
                        written += ev.append(c["rows"])
                        ev.prune()      # retention: keep the last N events
                    elif out.get("type") == "statedb" and c["rows"] is not None:
                        # IMPORTANT: an empty set of rows is NOT "nothing to do".
                        # The source may legitimately be empty (vulnerabilities
                        # closed by a patch, a stopped container, a closed socket)
                        # - and then the output must still reach upsert so that
                        # staleness deletes the old rows. This used to say
                        # `and c["rows"]`, and the data hung in the table forever:
                        # the user updated the system and the vulnerabilities kept
                        # being shown. A failing command does not reach here - it
                        # raises an exception above and does not touch the table.
                        table = out.get("table") or n["ref"].rsplit("/", 1)[-1]
                        cols = []
                        for r in c["rows"]:
                            for k in r:
                                if k not in cols:
                                    cols.append(k)
                        if not cols:
                            # only an empty set has no columns: we do not touch
                            # the schema but remove the dead rows of this output
                            self.db.clear_src(table, n["id"])
                            peek["out_rows"] = None
                            peek["out_count"] = 0
                            self.peek[(pipe, n["id"])] = peek
                            written += self._walk(pl, nodes, n["id"], pipe, c)
                            continue
                        key = out.get("key") or cols[:1]
                        # A column from the KEY must exist even if the rule does
                        # not return it: different normalizations write into one
                        # table (rpm has arch, pip does not), and without this the
                        # output failed with a KeyError on someone else's key.
                        for k in key:
                            if k not in cols:
                                cols.append(k)
                                for r in c["rows"]:
                                    r.setdefault(k, "")
                        self.db.ensure_table(
                            table, out.get("title", table),
                            out.get("icon", "view-list-details"), cols)
                        # src = the id of the output node: every output owns its
                        # share of the table's rows (several outputs -> one table)
                        diff = self.db.upsert(table, key, cols, c["rows"],
                                              src=n["id"])
                        # THE COLLECTION TIMESTAMP: it shows that the source
                        # really ran, and that an empty table means "empty" rather
                        # than "not collected for a long time"
                        self.db.mark_collected(table)
                        # STATE TRANSITION -> EVENT. Switched on by the
                        # track_changes flag in the output: fluid tables
                        # (processes, sockets) have their own event sources, and
                        # duplicating them with changes makes no sense.
                        if out.get("track_changes"):
                            written += self._emit_changes(out, table, key, diff)
                        written += len(c["rows"])
                    # the output: what arrived at it
                    peek["out_rows"] = c["rows"][:200] if c.get("rows") else None
                    peek["out_count"] = len(c["rows"]) if c.get("rows") else 0
                    self.peek[(pipe, n["id"])] = peek
                    # AFTER an output there may be a correlation node: the events
                    # are already written, so a detection sees them in the same run
                    written += self._walk(pl, nodes, n["id"], pipe, c)
                    continue
                    # normalization/filter: what came out of the node
                peek["out_rows"] = c["rows"][:200] if c.get("rows") else None
                peek["out_count"] = len(c["rows"]) if c.get("rows") else 0
                self.peek[(pipe, n["id"])] = peek
            except Exception as e:
                self.peek[(pipe, n["id"])] = {**peek, "error": str(e)}
                raise RuntimeError(f"{n['id']}: {e}") from e
            written += self._walk(pl, nodes, n["id"], pipe, c)
        return written

    def tick(self) -> bool:
        ran = self.due()
        for pn, nid in ran:
            self.run_node(pn, nid)
        return bool(ran)

    def run_pipeline(self, pipe: str):
        pl = self.pipelines.get(pipe)
        if pl:
            for n in pl["nodes"]:
                if n["kind"] == "input":
                    self.run_node(pipe, n["id"])

    def run_all(self):
        for pn in self.pipelines:
            self.run_pipeline(pn)

    # -------- data for the UI --------
    def _obj_title(self, kind: str, ref: str) -> dict:
        if not ref:
            return {"title": "(unbound)", "icon": "emblem-warning"}
        cfg = self.objects.get(KIND2CAT[kind], {}).get(ref)
        if not cfg:
            return {"title": ref + " (file missing)", "icon": "data-error"}
        icons = {"input": "document-import", "normalize": "code-context",
                 "enrich": "link", "filter": "view-filter",
                 "correlation": "police-badge", "output": "document-export"}
        return {"title": cfg.get("title", ref),
                "icon": cfg.get("icon", icons.get(kind, "view-list-details"))}

    def pipelines_info(self) -> list[dict]:
        out = []
        for pn, pl in self.pipelines.items():
            errs = [s["error"] for (p, _), s in self.status.items()
                    if p == pn and s.get("error")]
            out.append({"name": pn, "title": pl.get("title", pn),
                        "nodes": len(pl["nodes"]),
                        "inputs": sum(1 for n in pl["nodes"] if n["kind"] == "input"),
                        "error": errs[0] if errs else ""})
        return out

    def graph(self, pipe: str) -> dict:
        pl = self.pipelines.get(pipe)
        if not pl:
            return {"nodes": [], "edges": [], "title": pipe}
        nodes = []
        for n in pl["nodes"]:
            info = self._obj_title(n["kind"], n["ref"])
            st = self.status.get((pipe, n["id"]), {})
            nodes.append({**{k: n.get(k) for k in ("id", "kind", "ref", "x", "y")},
                          **info,
                          "rows": st.get("rows", -1), "error": st.get("error", ""),
                          "ran_at": st.get("ran_at", "")})
        return {"title": pl.get("title", pipe), "nodes": nodes,
                "edges": [list(e) for e in pl["edges"]]}

    def flows(self, pipe: str) -> list[dict]:
        """The pipeline as a LIST of data flows - one per input:
        input -> normalize -> [enrich/filter] -> output. Easier to read than the
        graph: one line = one state source with its stages and status.
        The graph editor stays for editing the topology; this is the showcase."""
        pl = self.pipelines.get(pipe)
        if not pl:
            return []
        nodes = {n["id"]: n for n in pl["nodes"]}
        adj: dict[str, list] = {}
        for a, b in pl["edges"]:
            adj.setdefault(a, []).append(b)
        order = {"input": 0, "normalize": 1, "enrich": 2, "filter": 3,
                 "output": 4}

        def stage_info(nid: str) -> dict:
            n = nodes[nid]
            info = self._obj_title(n["kind"], n.get("ref", ""))
            pk = self.peek.get((pipe, nid), {}) or {}
            out_rows = pk.get("out_rows")
            return {"id": nid, "kind": n["kind"], "ref": n.get("ref", ""),
                    "title": info["title"], "icon": info["icon"],
                    "rows": pk.get("out_count", len(out_rows) if out_rows else 0),
                    "error": pk.get("error", "")}

        out = []
        for n in pl["nodes"]:
            if n["kind"] != "input":
                continue
            # the set of forward-reachable nodes (usually a linear chain)
            seen, stack = set(), [n["id"]]
            while stack:
                cur = stack.pop()
                if cur in seen:
                    continue
                seen.add(cur)
                for nx in adj.get(cur, []):
                    if nx in nodes:
                        stack.append(nx)
            chain = sorted(seen, key=lambda i: (
                order.get(nodes[i]["kind"], 9),
                nodes[i].get("y", 0), nodes[i].get("x", 0)))
            stages = [stage_info(i) for i in chain]
            st = self.status.get((pipe, n["id"]), {})
            cfg = self.objects["inputs"].get(n.get("ref", ""), {})
            outs = [s for s in stages if s["kind"] == "output"]
            norm = next((s for s in stages if s["kind"] == "normalize"), None)
            table = ""
            for s in outs:
                table = (self.objects["outputs"].get(s["ref"], {}).get("table")
                         or table)
            head = outs[0] if outs else (norm or stages[0])
            out.append({
                "input": n["id"],
                "ref": n.get("ref", ""),
                "title": head["title"],
                "icon": head["icon"],
                "table": table,
                "interval": cfg.get("interval", 0),
                "enabled": bool(cfg.get("enabled", True)),
                "rows": st.get("rows", -1),
                "ran_at": st.get("ran_at", ""),
                "error": (st.get("error", "")
                          or next((s["error"] for s in stages if s["error"]), "")),
                "stages": stages,
            })
        out.sort(key=lambda f: f["title"].lower())
        return out

    # -------- pipeline drafts --------
    def _draft_path(self, pipe: str) -> Path:
        return EXPERTISE / "pipelines" / f"{pipe}.draft.yaml"

    def graph_draft(self, pipe: str) -> dict:
        """The graph for the editor: the draft if there is one, otherwise the current."""
        dp = self._draft_path(pipe)
        if not dp.exists():
            g = self.graph(pipe)
            g["draft"] = False
            return g
        try:
            pl = yaml.safe_load(dp.read_text()) or {}
        except Exception:
            g = self.graph(pipe)
            g["draft"] = False
            return g
        nodes = []
        for n in pl.get("nodes", []):
            info = self._obj_title(n["kind"], n.get("ref", ""))
            st = self.status.get((pipe, n["id"]), {})
            nodes.append({**{k: n.get(k) for k in ("id", "kind", "ref", "x", "y")},
                          **info,
                          "rows": st.get("rows", -1), "error": st.get("error", ""),
                          "ran_at": st.get("ran_at", "")})
        return {"title": pl.get("title", pipe) , "nodes": nodes,
                "edges": [list(e) for e in pl.get("edges", [])], "draft": True}

    def save_layout(self, pipe: str, pos: dict):
        """Update the x/y of the nodes in the working pipeline file without
        touching the topology.

        It is EXACTLY the file on disk that is edited (not only memory), otherwise
        the layout would be lost on the next load. Nodes absent from pos are left
        as they were.
        """
        pl = self.pipelines.get(pipe)
        if not pl:
            return
        path = Path(pl.get("_file") or (EXPERTISE / "pipelines" / f"{pipe}.yaml"))
        try:
            raw = yaml.safe_load(path.read_text()) or {}
        except OSError:
            return
        for n in raw.get("nodes", []):
            xy = pos.get(n.get("id"))
            if xy:
                n["x"], n["y"] = int(xy[0]), int(xy[1])
        for n in pl.get("nodes", []):
            xy = pos.get(n.get("id"))
            if xy:
                n["x"], n["y"] = int(xy[0]), int(xy[1])
        try:
            path.write_text(yaml.safe_dump(raw, allow_unicode=True,
                                           sort_keys=False, width=200))
        except OSError:
            pass

    def save_draft(self, pipe: str, nodes: list, edges: list):
        pl = self.pipelines.get(pipe)
        title = pl.get("title", pipe) if pl else pipe
        data = {"name": pipe, "title": title,
                "nodes": [{k: n[k] for k in ("id", "kind", "ref", "x", "y")}
                          for n in nodes],
                "edges": [list(e) for e in edges]}
        self._draft_path(pipe).write_text(
            yaml.safe_dump(data, allow_unicode=True, sort_keys=False))

    def apply_draft(self, pipe: str):
        dp = self._draft_path(pipe)
        pl = self.pipelines.get(pipe)
        if dp.exists() and pl:
            Path(pl["_file"]).write_text(dp.read_text())
            dp.unlink()
            self.reload()

    def discard_draft(self, pipe: str):
        dp = self._draft_path(pipe)
        if dp.exists():
            dp.unlink()

    def save_graph(self, pipe: str, nodes: list, edges: list):
        pl = self.pipelines.get(pipe)
        if not pl:
            return
        data = {"name": pipe, "title": pl.get("title", pipe),
                "nodes": [{k: n[k] for k in ("id", "kind", "ref", "x", "y")}
                          for n in nodes],
                "edges": [list(e) for e in edges]}
        Path(pl["_file"]).write_text(
            yaml.safe_dump(data, allow_unicode=True, sort_keys=False))
        self.reload()

    def create_pipeline(self, title: str) -> str:
        name = re.sub(r"[^a-zа-яё0-9_]", "_", title.strip().lower()) or "pipeline"
        f = EXPERTISE / "pipelines" / f"{name}.yaml"
        if not f.exists():
            f.write_text(yaml.safe_dump(
                {"name": name, "title": title.strip() or name,
                 "nodes": [], "edges": []},
                allow_unicode=True, sort_keys=False))
            self.reload()
        return name

    # -------- expertise for the UI --------
    def expertise_dirs(self) -> list[dict]:
        out = []
        for d in sorted(p for p in EXPERTISE.rglob("*")
                        if p.is_dir() and p.name != "pipelines"):
            rel = str(d.relative_to(EXPERTISE))
            out.append({"path": rel, "title": d.name,
                        "depth": rel.count("/")})
        return out

    def expertise_elements(self, dirpath: str) -> list[dict]:
        base = (EXPERTISE / dirpath).resolve()
        if not base.is_relative_to(EXPERTISE) or not base.is_dir():
            return []
        out = []
        for f in sorted(base.glob("*.yaml")):
            try:
                cfg = yaml.safe_load(f.read_text()) or {}
            except Exception as e:
                cfg = {"title": f"YAML error: {e}"}
            out.append({"rel": str(f.relative_to(EXPERTISE)),
                        "id": str(cfg.get("id", "")),
                        "name": str(cfg.get("name", f.stem)),
                        "title": str(cfg.get("title", "")),
                        "type": str(cfg.get("type", "")),
                        "version": str(cfg.get("version", ""))})
        return out

    def expertise_catalog(self, category: str) -> list[dict]:
        """Objects of a category (by the type field); ref is the path from the expertise root."""
        out = []
        for ref, cfg in sorted(self.objects.get(category, {}).items()):
            out.append({"ref": ref,
                        "id": str(cfg.get("id", "")),
                        "name": str(cfg.get("name", ref)),
                        "title": str(cfg.get("title", "")),
                        "type": str(cfg.get("type", "")),
                        "version": str(cfg.get("version", ""))})
        return out

    def next_id(self, category: str) -> str:
        letter = ID_LETTER.get(category, "X")
        mx = 0
        for cfg in self.objects.get(category, {}).values():
            m = re.match(rf"LS-{letter}-(\d+)", str(cfg.get("id", "")))
            if m:
                mx = max(mx, int(m.group(1)))
        return f"LS-{letter}-{mx + 1}"

    def parsed(self, rel: str) -> dict:
        p = (EXPERTISE / rel).resolve()
        if not p.is_relative_to(EXPERTISE) or not p.exists():
            return {}
        try:
            cfg = yaml.safe_load(p.read_text()) or {}
            return {k: v for k, v in cfg.items() if not k.startswith("_")}
        except Exception as e:
            return {"error": str(e)}

    def set_enabled(self, ref: str, enabled: bool):
        cfg = self.objects["inputs"].get(ref)
        if not cfg:
            return
        cfg["enabled"] = enabled
        clean = {k: v for k, v in cfg.items() if not k.startswith("_")}
        Path(cfg["_file"]).write_text(
            yaml.safe_dump(clean, allow_unicode=True, sort_keys=False))

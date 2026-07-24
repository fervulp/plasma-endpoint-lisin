# LiSin — map of the system

A document for someone seeing the project for the first time (a person, or
another Claude session). It answers "what is here, what is each part for, and
where do I look".

It was written by **measuring the running system**, not from memory; the
numbers are as of 2026-07-20 and will drift, the structure will not.

Rules that must not be broken are in `expertise/PRINCIPLES.md` — **check them
before any change**. The contract for an expertise author is
`expertise/HOWTO.md`.

---

## 1. What this is

A lightweight local EDR for Fedora on a single laptop. Python 3 (stdlib) +
PySide6/Qt Quick + Kirigami. No server, **no root**, no external services in
the main loop.

It answers three questions:

| Question | Where | Storage |
|---|---|---|
| What is in the system **now** | "State" | `state.db` (snapshot, upsert) |
| What **happened** | "Events" | `events.db` (stream, append-only) |
| What to **do** about it | "Dashboards" → findings, graph | computed on the fly |

Start it (`PYTHONNOUSERSITE=1` is mandatory, otherwise a pip-installed PySide6
does not see the system Kirigami):

```
PYTHONNOUSERSITE=1 QT_QUICK_CONTROLS_STYLE=org.kde.desktop python3 lisin_app.py
```

One instance only: `flock` on `~/.local/share/lisin/lisin.lock`.
**A pitfall that cost a lot of time:** an old running instance rewrites the
database with its own code every 2 seconds. When something "does not work",
first compare the process start time with the time of your edits.

---

## 2. The core idea: everything goes through the pipeline

```
input        →  normalization   →  enrichment      →  filter  →  output
(bash cmd)      (Python plugin)    (Python plugin)             (statedb|events)
```

Every node is an **expertise object**, a YAML file with code inside. The
application is an engine; all domain logic lives in `expertise/` and is edited
without opening the sources. This is principles 1–2, and the reason a new
source is added without a single line of Python.

- a normalization rule must define `normalize(text) -> list[dict]`;
- an enrichment must define `enrich(rows) -> rows`;
- table columns are derived from the dictionary keys, they are not declared;
- the table and the key are set in the **output**, not in the normalization.

**Trust:** the rule's code is executed, just like the shell command of an
input. Importing someone else's expertise means running their code.

---

## 3. Layout of the sources

```
lisin_app.py            the entry point: the scheduler, error collection, main()
agent/
  paths.py              where things live on disk - computed in ONE place
  core/                 the engine: pipeline, statedb, eventsdb, taxonomy, config
  analysis/             reading what was collected: links, entities, dashboard,
                        findings, correlate, chains, panels
  collect/              the few places that touch the live system directly:
                        procinfo, metrics, state, ipintel
  api/                  the slots QML calls, one module per section
  queries.py            saved queries as expertise objects
  ruletest.py           running and testing a rule from the UI
ui/
  Main.qml              the window and the navigation
  components/           reusable bricks: QueryBar, DataTable, FieldPicker,
                        SidePanel, GraphCanvas, Fmt.js
  pages/                the sections: State, Events, SQL, Pipelines, Expertise,
                        Dashboards, Settings, Process
  views/                what lives inside a section: DashboardView, VulnView,
                        NetFlowView, FileActivityView, PrivescView, FindingsView,
                        ErrorsView, GeneralSettings
expertise/              all the domain logic (see section 6)
packaging/              spec, launcher, RPM build, the access-extension script
```

The split of `agent/` follows what a module is allowed to do:

* **core** knows nothing about specific packages, ports or paths - it executes
  rules and stores rows;
* **analysis** is read-only with respect to the stores: it never collects
  anything, it only reads state.db and events.db;
* **collect** is the only place that touches the live system outside the
  pipeline, and it is deliberately small: an interactive WHOIS, the EDR
  breakdown of one process, the resource metrics of the application itself.

| Module | Lines | Responsible for | Key functions |
|---|---:|---|---|
| `core/pipeline.py` | 900 | **Pipeline engine**: loading expertise, scheduling inputs, walking the graph, running plugins, emitting events about state changes | `run_python`, `run_enrich`, `StatePipeline` |
| `analysis/links.py` | 980 | **Links and the investigation graph**: discovering links between tables, pivot graph around any entity | `model`, `anchor_graph`, `around`, `node_detail` |
| `analysis/entities.py` | 809 | Collapsing raw processes into **entities**; classifying the inventory into programs and dependencies | `build`, `programs`, `files_for` |
| `analysis/dashboard.py` | 565 | Data for the "State" dashboard: process tree with risk, EDR breakdown of one PID | `build`, `process_detail` |
| `analysis/chains.py` | 325 | **Event chains** (ancestry → socket → object → time). Hidden from the UI, the mechanism works | `build`, `detail` |
| `analysis/panels.py` | 312 | Investigation panels: file activity, privileges, network flows | `file_activity`, `privesc_activity`, `network_flows`, `flow_detail` |
| `core/statedb.py` | 283 | **State database** (SQLite WAL). Upsert by key, staleness, user columns | `ensure_table`, `upsert`, `snapshot`, `query` |
| `collect/ipintel.py` | 214 | Interactive WHOIS for one address from the interface. The bulk ASN lookup is a pipeline flow now | `whois_details` |
| `core/eventsdb.py` | 188 | **Event database** (append-only, WAL). The schema is built from the taxonomy, dedup by `event_id`, retention | `append`, `recent`, `stats`, `query` |
| `ruletest.py` | 158 | Running and testing a rule from the UI (the `tests:` section inside the rule) | `run_now`, `run_tests`, `input_for` |
| `collect/procinfo.py` | 127 | Details of a live process from `/proc` | `details` |
| `analysis/correlate.py` | 117 | **Correlation engine**: where → group_by → threshold → window; a hit produces an `event_kind=alert` event | `run` |
| `analysis/findings.py` | 115 | **Findings engine**: executes the SQL of the rules in `expertise/findings/` | `build` |
| `collect/metrics.py` | 85 | CPU/RAM sampler, disk usage | `system_metrics`, `resource_usage` |
| `queries.py` | 76 | Saved SQL queries as expertise objects | `save`, `listing`, `delete` |
| `core/taxonomy.py` | 58 | Loading the event taxonomy; **the schema of `events.db` is built from it** | `load`, `names`, `groups` |
| `collect/state.py` | 56 | `os_info()` for the system card | `os_info` |
| `core/config.py` | 27 | Settings in `~/.config/lisin/settings.json` | `get`, `set_` |

### Separating the engine from the data
`findings.py`, `correlate.py` and `pipeline.py` are **engines**: they know
nothing about specific packages, ports or paths. Every specific fact lives in
`expertise/`. Breaking this is the main defect to look for during a review.

## 4. The API for QML — `agent/api/`

`Backend(QObject, StateApi, EventsApi, DashboardApi, ExpertiseApi, SystemApi)`.
The mixins are plain classes; a `@Slot` inside them is registered on
inheritance. `lisin_app.py` contains only the scheduler, error collection and
`main()`.

| Mixin | Slots | About |
|---|---:|---|
| `expertise.py` | 28 | pipelines (graph, draft, run, peek), the expertise catalogue, CRUD, running rules |
| `dashboard.py` | 23 | dashboard, process breakdown, **graph and pivot**, findings, vulnerabilities, panels, WHOIS |
| `events.py` | 16 | feed, statistics, arbitrary SELECT, grouping, SQL history, saved queries, chains |
| `state.py` | 10 | state snapshot, table/cell edits, read-only SQL |
| `system.py` | 6 | errors, metrics, settings |

**Key graph slots** (the newest and the most fragile):
`processLinks(pid, expanded)`, `anchorGraph(kind, val, expanded)`,
`anchorList(kind)`, `nodeInfo(node)`.

> **A pitfall that already broke the dashboard once:** a JS array arrives from
> QML as a `QJSValue`, and it **is not iterable**. Unwrap it with
> `.toVariant()` (`DashboardApi._str_list`). A slot that QML calls must be
> **verified through QML**, not by calling it from Python with a list — from
> Python the bug does not reproduce.

---

## 5. Storage

`~/.local/share/lisin/`

| File | What | Model |
|---|---|---|
| `state.db` | 47 tables, the "what is here" snapshot | upsert by the rule's key, rows that disappeared are deleted |
| `events.db` | ~58 thousand events | append-only, dedup by `event_id`, retention 300k |
| `settings.json` | UI settings | — |
| `*.json` | caches (`filepkg`, `procpkg`, `appmeta`, `cvss`, `ipintel`…) | the key is the mtime of the rpm database |

**Largest state tables:** `open_files` 5760, `applications` 3493,
`app_config` 2977, `browser_history` 1465, `polkit_actions` 517,
`shell_history` 497, `processes` 446, `pam_config` 401, `ports` 234.

**Events by module:** netmon 31962, journal 11366, audit 8071,
procmon 5127, statediff 475, rpmdb 440, correlation 410, fim 92.

The schema of `events.db` is **generated from
`expertise/taxonomy/events.yaml`**: add a field to the YAML and the column
appears. Columns are only ever added.

---

## 6. Expertise — `expertise/`

| Type | Count | Purpose |
|---|---:|---|
| `input` | 57 | inputs: a shell command line plus an interval |
| `normalization_rule` | 58 | `normalize(text) -> list[dict]` |
| `statedb` | 51 | outputs: table, key, `track_changes`, `derived_columns` |
| `enrichment` | 21 | `enrich(rows) -> rows`; the linking columns come from here too |
| `finding` | 12 | "what is wrong and what to do" (SQL + why/action/basis) |
| `detection` | 5 | correlation → alert event |
| `filter` | 2 | conditions on fields |
| `query` | 2 | saved queries |
| `taxonomy` | 1 | 99 event fields, 10 groups |

Pipelines: `state` — 185 nodes / 135 edges; `events` — 17 / 16.
Pipeline descriptions (`expertise/pipelines/*.yaml`) have no `type` field —
they are graphs (`nodes`/`edges`), not catalogue objects; during an audit they
legitimately end up in the "no type" bucket.

**The universal enrichments the graph rests on:**
`attach_package` (gives the `package` column from a path/unit/module — this is
what makes `applications` a hub), `extract_pid`, `proc_purpose` (the purpose of
a process from the rpm database, unwrapping the interpreter:
`python3 -Es /usr/sbin/tuned` → package `tuned`), `app_deps`, `net_owner`,
`ip_intel`.

---

## 7. Interface — `ui/`

Sections: **State · Events · Dashboards · Pipelines · Expertise · SQL ·
Settings**. Navigation goes only through `root.open(name)`.

| File | Lines | Role |
|---|---:|---|
| `pages/EventsPage.qml` | 1330 | the event feed, filters expressed as SQL, grouping, saved queries |
| `views/DashboardView.qml` | 1285 | **the dashboard**: a switchable list (processes/applications/ports/users/configs/files), the graph, the process panel |
| `pages/PipelineGraphPage.qml` | 877 | the pipeline graph editor |
| `pages/StatePage.qml` | 750 | state tables, columns, filters |
| `pages/ExpertisePage.qml` | 644 | object catalogue, YAML editor, Run/Tests |
| `components/GraphCanvas.qml` | 412 | **the reusable graph canvas** |
| `views/NetFlowView.qml` | 430 | network flows, WHOIS |
| `pages/SqlPage.qml` | 372 | read-only SQL |
| `views/VulnView.qml` | 314 | vulnerabilities |
| others | — | `pages/ProcessPage`, `views/FindingsView`, `views/PrivescView`, `views/FileActivityView`, `components/SidePanel`, `components/QueryBar`, `components/DataTable`, `components/FieldPicker` |

### How the investigation graph works (the core of the UX)
- **Session & boot block**: every process graph carries the timeline it lives
  inside - when the computer was turned on, when the owning user logged in (with
  times), that user's services, and the process's working directory. So "when
  did this appear" is answered next to it.
- **The anchor** is an entity of any type: a process, an application, a port,
  a user, a config, an open file. One engine: `anchor_graph`.
- **A ladder**: the anchor on top, category blocks below it going down —
  application → service → network → files → configuration → …
- **A block collapses** into a meta node with a counter (more than 4 members).
  Expanding shows **all** members; edges start **at the block**.
- Type words ("process", "event") were removed — the type is read from the
  block's icon.
- Buttons on a node: make it the centre (pivot), open in "State", events,
  WHOIS. There is a full-screen mode and pivot breadcrumbs.
- **The layout (x/y) is computed in Python**, QML only draws it — otherwise
  nodes jump between repaints.

---

## 7a. What the speed rests on

Measured, not assumed - each of these was a number before it was a change:

| Where | What it was | What it is |
|---|---|---|
| A full sweep of the 57 inputs | 41.7 s, one input at a time | **20.3 s**, four at a time (our own CPU 2.1 s - an input mostly waits) |
| The state snapshot handed to the interface | 195 ms, 22.9 MB, every row of every table | **7 ms, 12.6 KB** - the map of the tables |
| Rows of the table on screen | the whole table crossed into QML | **one page of 50**, selected/sorted/paged by SQLite |
| Switching to applications (3505 rows) | 1.5 s | **0.41 s** |
| upsert of 93 thousand unchanged rows | 0.68 s (93k UPDATEs) | **0.06 s** (a set fingerprint skips the whole compare) |
| Indexes on events | 45, of which 26 were never filtered by - 107 MB | **19**, database 314 -> 246 MB |
| Appending events | - | **20 000 events/s** |
| Panels (network walks 104k events) | 468 ms on every refresh | **0 ms** on a repeat (memoised by the mtime of the databases) |
| The engine's own memory for previews | 8.6 MB | **4.4 MB** |

The rules behind them:

* **an input waits, so let inputs overlap.** The lock guards the write, not the
  run; four workers is deliberately modest - this is an agent on a laptop.
* **do not carry data across a boundary you do not need to cross.** The cost of
  handing rows to QML grows with the number of VALUES, not rows.
* **a row that did not change is not written.** In WAL mode a write is a real page.
* **an index is a write on every insert.** Index what is filtered, nothing else;
  the taxonomy is the schema, so removing `index: true` drops the index.

Two more, added later:

* **the same set costs one integer.** A collector re-reads the same inventory
  every run; a per-output fingerprint (count XOR per-row hash) short-circuits the
  whole read-compare-write when nothing changed. Our own CPU for a full state
  sweep 1.63 s -> 0.94 s.
* **skip work the run does not need.** Only 4 of 50 outputs turn a change into an
  event; the other 46 pass `want_diff=False` and never build the old row.

Sections are built once and kept (pageCache), so returning to one is instant
(0.25 s against 1-2 s of rebuilding it) and the page's query and scroll survive
leaving it. A kept page that is not shown does not refresh - a hidden dashboard
used to recompute on every tick. malloc_trim(0) after a collection returns the
freed C heap to the OS so the resident set does not drift upward.

Animations stay small and local - row and tile fades, hover and selection
easing, graph transitions - all on the render thread. There is no page-level
fade: animating the opacity of a whole section forces an offscreen render of
hundreds of rows every frame, which was the jerk.

## 7b. SQLite: reuse the connection, tune what is safe

The two databases are SQLite in WAL mode - one writer (the agent, under a lock)
and many concurrent readers (the UI), which WAL allows without either blocking
the other.

* **A read reuses a per-thread connection.** Opening a fresh connection for
  every read cost 5.4 ms - the setup dominates a small query. A persistent
  read-only connection kept in `threading.local` (StateDB._reader,
  EventsDB._reader) is reused: the UI reads on the main thread, so it reuses one;
  a worker thread gets its own. Read-only and in autocommit, so every SELECT
  starts a new WAL read transaction and always sees fresh data without holding
  back a checkpoint. Measured: table_rows 5.4 ms -> 0.69 ms (the old code opened
  two connections), a feed page 5.4 ms -> 2.1 ms.
* **synchronous=NORMAL** - with WAL this is the documented safe setting: no
  corruption on an app crash, only the last transaction is at risk on a power
  cut, and a write stops waiting on an extra fsync.
* **temp_store=MEMORY** - the temp b-trees a GROUP BY/ORDER BY builds stay in
  RAM instead of a scratch file.
* **cache_size was tried and dropped.** A few MB per connection added ~150 MB of
  resident set and did not move the read times (connection reuse was the win,
  not the cache), so it is left at the default.

## 8. How to verify (mandatory before calling something done)

Compiling QML and rendering offscreen **do not catch** errors in slots and
bindings. The minimum set:

1. `python3 -m py_compile lisin_app.py agent/*.py agent/api/*.py`
2. compile **all** of `ui/*.qml` at once (`QQmlComponent` in a loop);
3. **run through QML**: load the view into a `QQuickView`
   (`setResizeMode(SizeRootObjectToView)` — otherwise the window is resized to
   fit the root object and the geometry lies), call its functions, collect the
   warnings through `qInstallMessageHandler`;
4. run the pipeline — there must be no node errors;
5. `bash packaging/build-rpm.sh`.

The harnesses live in the session scratchpad (`qml_all.py`, `dash_flow.py`,
`ladder.py`, `fullscreen.py`) — recreating them is cheaper than looking for
them.

---

## 9. Known limits and debts — honestly

**Limits by nature (not bugs):**
- Without root: `/proc/<pid>/exe` of a foreign process cannot be read; there
  are no kernel audit rules; traffic volume in bytes is unavailable — we count
  **sessions**, and that is stated in the interface.
- `open_files` is a **snapshot of what is open**, not a log of accesses. A
  process that reads a file and immediately closes it will not show up between
  snapshots.
- Polling: short-lived processes and connections shorter than the interval are
  missed.
- The "session → process" link goes through `tty`/`user` and is marked as
  probable.

**Debts (they break the principles and are not closed):**
- **`c2_contact` is a dead detection.** Its condition is
  `threat_indicator <> ''`, but the `ip_threat` enrichment was removed together
  with the feeds. There are 0 matches and there never will be. It creates a
  false sense of "we catch C2" — either bring the source back or remove it.
- **`chains.py`** — the linking rules live in the code, not in the expertise
  (principle 2). The mechanism works, it is hidden from the UI.
- **`ipintel.py`** reaches the network from an enrichment plugin, bypassing the
  pipeline (principle 1): the input is invisible, it cannot be switched off or
  run by hand.
- `proc_cmd_risk` — regex markers inside an enrichment; they belong in
  `detections/`.
- The `containers` table is empty (docker/podman are not running) — the source
  has not been verified against live data.
- ~20 tables of the `item/value` shape (`system`, `cpu`, `memory`, `boot`,
  `security`, `swap_info`) are **deliberately** not linked: they are properties
  of the machine as a whole, they have no entity to link to. Pulling them in
  would be a lie.

**Recurring pitfalls (all of them have already happened):**
- `%{NAME}` inside an rpm array iteration is not expanded — you need `%{=NAME}`.
- YAML: a regex with parentheses inside double quotes breaks the parser — use
  single quotes only.
- QML: `Kirigami.Dialog` is a Popup, it is opened with `open()`, not with a
  `visible` binding; a second `Component.onCompleted` in a file is an error;
  take `availableWidth` from the id of the `ScrollView` itself.
- One quantity shown in two places must be computed by **one** query: different
  `LIMIT`s already produced "110 files in the graph, 60 in the panel".
- Any `LIMIT` that can actually trigger must be visible in the interface.

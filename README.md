# LiSin — a lightweight endpoint agent for Fedora

LiSin answers three questions about the machine it runs on:

* **What is here?** — a live inventory of the system: processes, sockets,
  packages, services, scheduled jobs, logins, configuration, persistence.
* **What happened?** — a stream of normalised events: process starts, network
  connections, file changes, package installs, audit records.
* **What should I look at?** — findings and detections that explain *why*
  something matters and *what to do*, with the evidence attached.

It is a desktop application (Python + PySide6 + Kirigami), not a server. One
laptop, one database, no agent-to-console protocol, no cloud.

**Supported platform: Fedora 44.** That is not a marketing line — the data
collectors call `dnf`, `rpm`, `systemctl`, `journalctl` and friends with the
options those versions provide. On another distribution the application will
start and the interface will work, but most collectors will return nothing.
Porting is a matter of editing YAML, not code: see *Adding a source* below.

Everything runs as your normal user. No root, no kernel module, no daemon.

---

## How it works

The whole system is one pipeline, and every piece of it is an object in
`expertise/` — a YAML file you can read and edit:

```
input  ──▶  normalization  ──▶  enrichment  ──▶  filter  ──▶  output
(a shell     (Python plugin      (adds context    (drops    (state.db
 command)     inside the YAML)    from other       noise)    or events.db)
                                  tables)
```

* **Input** — a shell command and how often to run it
  (`expertise/fedora/inputs/*.yaml`). Example: `ss -tunapn` every 20 seconds.
* **Normalization** — a Python function `normalize(text) -> list[dict]`
  written *inside the YAML rule* (`code:` field). Columns are the keys of the
  returned dictionaries; nothing is declared twice.
* **Enrichment** — `enrich(rows) -> rows`, also inside the YAML. This is where
  rows get their context: which package owns a binary, who owns a socket,
  which process an event belongs to, which boot session it happened in.
* **Filter** — conditions that drop known noise. Real actions (process
  starts, external connections, file changes) are never filtered.
* **Output** — where rows land: `state.db` (a snapshot table) or `events.db`
  (an append-only stream shaped by the event taxonomy).

Two databases, on purpose:

* `state.db` — **what is**, a snapshot. Rows are upserted by key; rows that
  disappeared from the system are deleted. ~50 tables.
* `events.db` — **what happened**, append-only, ~100 fields of an ECS-like
  taxonomy defined in `expertise/taxonomy/events.yaml`. Add a field there and
  the column appears in the database.

State and events are linked both ways: an event carries the process it belongs
to (written by enrichment at ingest time), and a state row can be opened as a
graph showing its processes, files, sockets, packages and events around it.

---

## Sections of the interface

| Section | What it is for |
|---|---|
| **State** | ~50 inventory tables with one query bar: quick search across all fields, SELECT/WHERE/GROUP BY/ORDER BY, or plain SQL. |
| **Events** | The event feed with the same query bar, grouping, field statistics, saved queries and history. |
| **Dashboards** | The process tree, a pivot graph around any entity, findings, network flows, file activity, privilege use. |
| **Vulnerabilities** | Fedora security advisories matched against installed packages, with CVSS computed from the vector. |
| **Pipelines** | The pipeline graph: every input, rule, enrichment and output, with the last run of each node. |
| **Expertise** | The YAML objects themselves — read, edit, run, test. |

---

## Running from source

```bash
sudo dnf install python3-pyside6 kf6-kirigami kf6-kirigami-addons python3-pyyaml
PYTHONNOUSERSITE=1 QT_QUICK_CONTROLS_STYLE=org.kde.desktop python3 lisin_app.py
```

`PYTHONNOUSERSITE=1` matters: a pip-installed PySide6 in the user site does not
load the system Kirigami.

## Building an RPM

```bash
./packaging/build-rpm.sh          # → ~/rpmbuild/RPMS/noarch/lisin-*.rpm
sudo dnf install --nogpgcheck ~/rpmbuild/RPMS/noarch/lisin-*.rpm
```

The package is unsigned. To sign it, see `packaging/sign-rpm.sh`.

---

## Adding a source

Nothing about a data source lives in the application code. To collect
something new, add three small YAML files and wire them into the pipeline:

1. **Input** — `expertise/fedora/inputs/my_source.yaml`

```yaml
name: my_source
id: LS-I-90
type: input
version: 1.0.0
title: My source
command: my-command --some-flag
interval: 300
enabled: true
```

2. **Normalization** — `expertise/fedora/normalize/my_source.yaml`

```yaml
name: my_source
id: LS-N-90
type: normalization_rule
version: 1.0.0
title: My source
code: |
  def normalize(text):
      rows = []
      for line in text.splitlines():
          parts = line.split()
          if len(parts) >= 2:
              rows.append({"name": parts[0], "value": parts[1]})
      return rows
tests:
  - name: one line becomes one row
    input: "alpha 42\n"
    rows: 1
    row0: { name: alpha, value: "42" }
```

3. **Output** — `expertise/fedora/outputs/my_source.yaml`

```yaml
name: out_my_source
id: LS-O-90
type: statedb
version: 1.0.0
title: My source
table: my_source
key: [name]
icon: view-list-details
```

Then connect `input → normalize → output` in the pipeline graph
(**Pipelines** section), press **Run** on the rule in **Expertise** to see the
parsed rows, and **Tests** to run the `tests:` section.

Porting to another distribution usually means changing the `command:` line and
the parser in `code:` — the application, the database schema and the interface
stay as they are.

`expertise/HOWTO.md` is the full contract for rule authors.

---

## Trust and privacy

* **The rule's code is executed.** A normalization plugin is Python, and an
  input is a shell command. Importing expertise from someone else means
  running their code — read it first.
* **Data stays on the machine.** The only outbound requests are: CVE scores
  for the advisories that affect *your* packages (NVD/OSV, CVE identifiers
  only), and, when you ask for it, ASN/WHOIS lookups for a public address.
  Private addresses are never sent anywhere.
* **No personal data in this repository.** Home paths, user names, real
  addresses and identifiers never belong in the code — see principle 18 in
  `expertise/PRINCIPLES.md`.

---

## Documentation

* `ARCHITECTURE.md` — the map of the system: modules, storage, UI, how to
  verify, known limits and debts.
* `expertise/PRINCIPLES.md` — the rules the project is held to. Read before
  changing anything.
* `expertise/HOWTO.md` — how to write an expertise object.

## Licence

GPL-3.0-or-later.

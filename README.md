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

## Adding a source — a worked example

Nothing about a data source lives in the application code. The four files below
are **real and shipped**: `expertise/examples/`, wired into the state pipeline.
They run on this machine, on a handful of rows, and you can watch every step in
the interface.

**The question the example answers:** which shells can be used to log in, and
which package does each of them come from — including the ones that come from no
package at all, because those were put there by hand.

### 1. Input — where the data comes from

`expertise/examples/input_login_shells.yaml`

```yaml
name: example_login_shells
id: LS-X-1
type: input
version: 1.0.0
title: "Example 1/4: login shells (input)"
command: |
  grep -v '^#' /etc/shells 2>/dev/null | grep -v '^$'
  true
interval: 3600
enabled: true
```

A shell command, nothing more. `/etc/shells` is the list the system itself
considers usable for logging in, so nothing is invented here. Its stdout:

```
/bin/sh
/bin/bash
/usr/bin/sh
/usr/bin/bash
/usr/bin/tmux
/bin/tmux
/bin/dash
```

### 2. Normalization — text becomes rows

`expertise/examples/normalize_login_shells.yaml`

```yaml
type: normalization_rule
code: |
  def normalize(text):
      rows = []
      for line in text.splitlines():
          path = line.strip()
          if not path.startswith("/"):
              continue
          rows.append({"path": path, "shell": path.rsplit("/", 1)[-1]})
      return rows
tests:
  - name: a path becomes a row with the shell name
    input: "/bin/bash\n/usr/bin/zsh\n"
    expect:
      rows: 2
      row0: {path: /bin/bash, shell: bash}
```

The columns of the table are the keys of the dictionaries — they are not
declared anywhere else. The `tests:` section lives next to the rule; the
**Tests** button runs it and shows pass/fail.

### 3. Enrichment — the interesting part

`expertise/examples/enrich_login_shells.yaml`

```yaml
type: enrichment
code: |
  def enrich(rows):
      import os, sqlite3
      from pathlib import Path
      db = str(Path.home() / ".local/share/lisin/state.db")
      idx = {}
      con = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=5)
      for path, pkg in con.execute("SELECT path, package FROM package_files"):
          idx[path] = pkg
      con.close()

      for r in rows:
          pkg = idx.get(r["path"], "") or idx.get(os.path.realpath(r["path"]), "")
          r["package"] = pkg
          r["packaged"] = "yes" if pkg else "no"
      return rows
```

This adds nothing of its own and **asks the system nothing**. It joins our rows
with another table that a *different* flow has already collected —
`package_files` (path → package), filled by
`expertise/fedora/inputs/package_files.yaml`.

That division is the rule for every enrichment: **collecting is the job of an
input, linking is the job of an enrichment.** If this plugin ran `rpm -qf`
itself, the source would be invisible in the pipeline, could not be switched off
and could not be run by hand to see what came back.

One detail worth keeping: a package records `/usr/bin/bash`, while `/etc/shells`
lists `/bin/bash` — the same file through the merged-`/usr` symlink. Resolving
the path is what turns 3 resolved rows into 7.

### 4. Output — where the rows land

`expertise/examples/output_login_shells.yaml`

```yaml
type: statedb
table: example_login_shells
key: [path]
icon: utilities-terminal
```

The key is what makes a row *updated* rather than duplicated on the next run,
and what makes a row that disappeared from the system get deleted.

### What you get

A table `example_login_shells` in **State**, 7 rows on this machine:

| path | shell | package | packaged |
|---|---|---|---|
| /bin/bash | bash | bash | yes |
| /bin/dash | dash | dash | yes |
| /bin/sh | sh | bash | yes |
| /bin/tmux | tmux | tmux | yes |
| /usr/bin/bash | bash | bash | yes |
| /usr/bin/sh | sh | bash | yes |
| /usr/bin/tmux | tmux | tmux | yes |

Read it as a sentence: `/bin/sh` is a login shell, and it is provided by the
**bash** package — not by a package called "sh". A row with `packaged = no`
would mean a login shell that no package installed, which is worth a look.

Because the table now carries a `package` column, it also joins the rest of the
graph by itself: the investigation graph discovers links by measuring how column
values overlap, so this table links to `applications`, and through it to
processes, services and vulnerabilities — without a line of code being changed.

### Wiring it up

Connect `input → normalize → enrich → output` in the **Pipelines** graph, press
**Run** on the rule in **Expertise** to see the parsed rows, and **Tests** to
run the `tests:` section.

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

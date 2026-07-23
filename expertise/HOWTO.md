# How to write LiSin expertise

Everything you need in order to add a new data source is here. You do not
have to look into the application code. What you write can be checked with the
**Run** and **Tests** buttons in the "Expertise" section.

An expertise object is a single YAML file. Its category is decided by the
`type` field, not by the directory. A directory is just a folder (`fedora/` is
ours; you can create your own next to it).

---

## Data flow

```
input     →  normalization  →  [enrichment]  →  [filter]    →  output
(bash)       (python)          (python)         (conditions)   (table/events)
```

Nodes are connected in a pipeline (`expertise/pipelines/*.yaml`).

---

## 1. Input — `type: input`

Just a shell command. Its stdout is passed to the normalization.

```yaml
name: myservice
id: LS-I-99
type: input
version: 1.0.0
title: My service state
command: systemctl show myservice --property=ActiveState,MainPID
interval: 60          # seconds
enabled: true
```

`command` is a string (executed as `bash -c`). Write it so that it **never
fails**: add `2>/dev/null` and `|| true`, otherwise the node will go red on
machines where the utility is missing.

---

## 2. Normalization — `type: normalization_rule`

The main object. Inside it is ordinary Python.

**The contract:**

* there must be a function `normalize(text) -> list[dict]`;
* `text` is the stdout of the input;
* **the table columns are the keys of the returned dicts** (the order comes
  from the first row). Columns are not declared anywhere;
* the table and the key are set in the **output**, not here;
* `re` and `json` are already imported; any stdlib module can be imported
  inside the function;
* to drop a row, simply do not add it to the list.

```yaml
name: myservice
id: LS-N-99
type: normalization_rule
version: 1.0.0
title: My service
code: |
  def normalize(text):
      rows = []
      for line in text.splitlines():
          if "=" not in line:
              continue
          k, _, v = line.partition("=")
          rows.append({"item": k.strip(), "value": v.strip()})
      return rows

tests:
  - name: two lines
    input: |
      ActiveState=active
      MainPID=1234
    expect:
      rows: 2
      contains: {item: ActiveState, value: active}
```

### Rule tests

They live next to the rule and are executed by the **Tests** button. The kinds
of expectation:

| key | meaning |
|---|---|
| `rows: N` | exactly N rows |
| `min_rows: N` | no fewer than N |
| `contains: {field: value}` | such a row exists among the results |
| `row0: {field: value}` | check a row by index (`row0`, `row1`, …) |

The **Run** button executes the rule against the **live** input (it runs the
input's command) and shows the parsed rows and columns — useful when the
output format of a utility is not known in advance.

---

## 3. Output

For state (a snapshot table) — `type: statedb`:

```yaml
name: db_myservice
id: LS-O-myservice
type: statedb
version: 1.0.0
title: My service
table: myservice
key: [item]           # rows are updated by these fields instead of duplicated
icon: view-list-details
```

For events (a stream) — `type: events`. There the table and the key come from
the **taxonomy** (`expertise/taxonomy/events.yaml`), so the output itself does
not have to name them.

---

## 4. Events: write to the taxonomy

If a rule produces **events**, return fields from the taxonomy
(`expertise/taxonomy/events.yaml`, 88 fields, ECS-like names). The minimum:

```python
{
  "ts": "2026-07-19T15:33:06Z",      # ISO-8601 UTC
  "event_id": "unique",              # deduplication key
  "event_category": "process",       # process|network|file|authentication|...
  "event_type": "start",
  "event_action": "process_started",
  "event_outcome": "success",
  "event_severity": 30,              # 0..100
  "event_module": "my_source",
  "message": "human readable",
}
```

Fill `not_normalized` with the names of the fields of the source record that
you did **not** parse — it immediately shows what else could be extracted.

Deduplication: `event_id` is unique and the insert is `INSERT OR IGNORE`. That
is why an input may collect **with an overlapping window** — there will be no
duplicates.

---

## 5. Enrichment — `type: enrichment`

Adds columns to rows that have already been parsed.

```yaml
name: my_enrich
id: LS-E-99
type: enrichment
version: 1.0.0
title: My enrichment
code: |
  def enrich(rows):
      for r in rows:
          r["extra"] = r.get("name", "").upper()
      return rows
```

A plugin may read the state database (`~/.local/share/lisin/state.db`,
read-only) — that is how `fedora/enrich/app_deps` works.

---

## 6. Filter — `type: filter`

Either conditions (a row passes when **all** of them are true):

```yaml
conditions:
  - field: event_category
    op: eq            # eq|ne|contains|not_contains|regex|in|not_in
    value: process
```

Or a table of noise templates — a row that matches **any** template is dropped
(`action: drop`) or tagged (`action: tag`):

```yaml
templates:
  - name: log spam
    event_provider: kwin_wayland
    match: "TypeError"       # a regular expression over message
    action: drop
```

---

## 7. Wiring it into a pipeline

`expertise/pipelines/state.yaml` (state) or `events.yaml` (events):

```yaml
nodes:
  - {id: in_myservice,  kind: input,     ref: fedora/inputs/myservice,    x: 40,  y: 4000}
  - {id: no_myservice,  kind: normalize, ref: fedora/normalize/myservice, x: 360, y: 4000}
  - {id: out_myservice, kind: output,    ref: fedora/outputs/myservice,   x: 680, y: 4000}
edges:
  - [in_myservice, no_myservice]
  - [no_myservice, out_myservice]
```

`ref` is the path from the expertise root **without** `.yaml`.

---

## The order of work

1. Create the object with the **Element…** button — you get a ready template
   with comments and a test skeleton.
2. Write the `command` and press **Run** — you will see the raw input and what
   was parsed out of it.
3. Edit `normalize` until the columns are what you need.
4. Freeze the result in `tests:` and press **Tests**.
5. Add the nodes to a pipeline.

## Trust

The rule's code **is executed** (so is the `command` of an input). Import
expertise from other people only from sources you trust.

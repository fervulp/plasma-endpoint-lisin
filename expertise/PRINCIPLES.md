# LiSin principles

These are not wishes, they are the frame. **Check this file before any
change.** If a change breaks a principle, then either the change is wrong or
the principle has to be discussed and changed EXPLICITLY, not worked around in
silence.

---

## 1. All data goes through the pipeline

    input → normalization → enrichment → filter → output

No exceptions:

- **Input** is the only place where data appears: a system command, reading a
  file, a network request. If something reaches the internet bypassing an
  input, that is a violation (it is invisible in the pipeline, it cannot be
  switched off, and it cannot be run by hand to see what came back).
- **Normalization** is the only place where raw text becomes rows. Columns are
  the keys of the dictionary.
- **Enrichment** only links data that has already been collected with
  reference data and other tables. It never goes to the network.
- **Output** is where the data landed: state, events, or an external source.

Sign of a violation: a value appears in the interface, but you cannot point at
the input that brought it.

## 2. The logic lives in the expertise, not under the hood

A user must be able to read and edit a rule without opening the application
sources. Everything that is KNOWLEDGE ABOUT THE SYSTEM lives in
`expertise/*.yaml`: how to collect it, how to parse it, how to link it, what
counts as a finding, what counts as noise.

Only the ENGINE stays in the application code: how to execute a rule, where to
put the result, how to show it.

Sign of a violation: adding a check requires editing a `.py` file.

## 3. No hand-written data

Lists of "important ports", "dangerous processes", "administrative groups",
"correct sysctl values" are forbidden. Such a list is true only on the machine
where it was written and silently lies on every other one.

Instead of a list — a source inside the system itself:

| What you need to know | The source in the system |
|---|---|
| which package owns a file | the rpm database |
| what a port is | `/etc/services` + the owner of the socket |
| which shell is interactive | `/etc/shells` |
| which group is administrative | polkit rules, permissions on root's sockets |
| what a sysctl value should be | `/usr/lib/sysctl.d`, `/etc/sysctl.d` |
| what counts as a browser | a desktop entry with `x-scheme-handler/http` |

If there is no source, write an input — do not hard-code the value.

An exception that has to be marked explicitly: **detection rules** (signatures,
noise templates). That is not data about the system but knowledge about
attacks — and even that lives in the expertise, not in the code.

## 4. The focus is inventory and observation of our own system

We describe THIS machine: what is installed, where it came from, what is
running, what changed. External feeds are auxiliary and secondary: a generic
list of someone else's addresses goes stale within hours and only catches what
is already common knowledge.

We look for the signal in a MISMATCH inside our own system: an extension
declared as a system one but installed from `/tmp`; a kernel value that
diverges from what the configuration declares; a process started from a binary
no package knows about.

## 5. Noise is filtered, useful data never is

Events that carry no information (first of all the ones produced by the agent
itself) are dropped by templates in the expertise. After EVERY batch of
filters a before/after check by classes of useful data is mandatory: process
starts, external connections, file events, authentication, sudo commands. If
the useful data dropped, the filter is wrong — not the data.

## 6. Output exists so that something can be done

Every element on screen must answer four questions:

1. **What** happened or was found;
2. **When** — the time is mandatory, without it nothing can be investigated;
3. **How we know** — the source, so that the conclusion can be checked;
4. **What to do** — a concrete action or where to look next.

A dashboard that only answers "how many of each" is useless.

## 7. Never present a guess as a fact

If the data is unavailable without root, say so instead of substituting
something approximate. If the assessment is incomplete, show the coverage
("scored 3 of 9"). If two sources disagree, show which one was used.

## 8. State is only about this computer

State holds the machine: processes, ports, packages, files, users. Downloaded
reference data belongs to external sources, in a separate database and a
separate section. Mixing them is forbidden: otherwise half of the "state"
turns out not to be about us.

## 9. A detection rule describes a METHOD, not a specific instance

Correlations and findings are built on a **well-known methodology** — "this
must not happen" or "this must be so" — and on a structural mismatch inside the
system. A rule has to survive a change of version, name and address.

Forbidden in rules:

- a specific version ("if openssh 9.9p2 then vulnerable") — versions are
  compared by the vendor advisory, not by us;
- a specific address, domain, hash, file name or process name as an indicator
  of threat — malware will call itself something else, an address changes
  tomorrow;
- a list of "bad" names of any kind.

Allowed and correct:

- **a mismatch of facts inside the system**: an extension declared as a system
  one but installed from `/tmp`; a binary that is running but belongs to no
  package; a kernel value that diverges from the configuration;
- **a well-known methodology** with an explicit reference to it: a MITRE
  ATT&CK technique, a CIS recommendation, a requirement of a standard. The
  reference is written into a field of the rule so that the conclusion can be
  checked and disputed;
- **thresholds and windows** (N events in M minutes) — that is a method, not an
  instance.

A rule does not pass judgement, it **highlights** and explains which
methodology fired. The decision is made by a human.

Sign of a violation: the rule will stop working after a package update, a file
rename or a change of address.

## 10. Verify against facts, not against belief

A change counts as done when it has been run on the live system and the result
has been shown. Referring to memory instead of a source is forbidden (it has
already produced an invented "reference value"). Normalization rules have a
`tests:` section. Interface layout must be verified by RENDERING: compiling QML
catches neither empty cards nor a wrong width.

## 11. Many elements of the same shape means a TABLE

If there are more than a few elements and they have the same shape, they must
be shown as a table — the same way "Events" and "State" do it. Cards with free
layout do not work for that: each of them gets its own height, the columns do
not line up, buttons drift, and rows cannot be compared by eye.

Rules of a table:

- **One description of the columns** (key, header, width, alignment) that is
  read BOTH by the header AND by the rows. Two independent lists inevitably
  drift apart.
- A row has a fixed height. A long description, a list of CVEs, a stack trace
  do NOT go into the row but into a detail panel below or beside the table.
- Numbers are right-aligned and monospaced, text is left-aligned.
- Status and severity are a colour accent (a stripe on the left, an icon), not
  an extra line of text inside a card: that breaks the uniform height.
- An empty value is shown as emptiness, not as a placeholder dash.
- Long lists use `reuseItems: true`, otherwise the interface stalls while
  recreating delegates.

## 12. Follow the KDE Human Interface Guidelines

The application lives in Plasma and must look like a part of it, not like a
home-made tool. Check against `develop.kde.org/hig`, in particular:

- **Capitalisation:** Title Case for buttons, headings and menu items ("Open
  Graph", "Full Screen"); sentence case for tooltips, placeholders and
  explanations ("Show the graph full screen").
- The real ellipsis character "…" (U+2026), not three dots.
- Units spelled out and separated by a space: "512 MB", "200 milliseconds".
- Margins are multiples of `Kirigami.Units`; the vertical rhythm is set by the
  container's `spacing`, not by individual margins on every row.
- Identical actions have an identical shape and sit in the same place in every
  list.
- The language of the interface is English; the user's own data is not
  translated.

## 13. Verify EVERY change, every time

Not "usually I verify" but every time, before saying "done". The minimum:

1. `python3 -m py_compile lisin_app.py agent/*.py agent/api/*.py`;
2. compile ALL of `ui/*.qml` at once;
3. **run through QML**: the view is loaded into a `QQuickView`, its functions
   are called, warnings are collected through `qInstallMessageHandler`. A slot
   that QML calls must be verified THROUGH QML — calling it from Python does
   not reproduce a whole class of errors (a `QJSValue` has already broken the
   dashboard);
4. run the pipeline — there must be no node errors;
5. build the RPM.

State the result in numbers, not in words: "was 4120 ms, now 177 ms",
"crossings 363 -> 50". If something has not been verified, say so plainly.

## 14. When a bug is found, fix the GENERAL logic, not the special case

A bug is almost never unique: if something is not shown for one program, the
same thing is not shown for dozens of others. Fix the mechanism, not the
symptom.

- A patch "for openvpn" is forbidden: a rule must rely on a STRUCTURAL property
  ("the argument is an existing file", "the address stands as a separate token
  in the command line"), and then it works for any program. Verify by coverage:
  it fired on N processes, not on one.
- If an invariant is broken (blocks overlap, a counter lies), it must be
  enforced in ONE place and applied always — on load, on change, not only when
  a button is pressed.
- A value must be written in ONE place. A duplicated write drifts apart sooner
  or later (a node position was written both into the card and into the model —
  the model received a copy, and the edges were drawn at the old coordinates).
- After the fix, measure the coverage and name the number: "fired on 47
  processes", "overlaps 16 -> 0", not "it got better".

## 15. Identical behaviour means one component, not a copy in every section

Search, filters, column selection and the side panel used to be written from
scratch in every section: State, Events, Vulnerabilities, SQL — four
implementations of the same thing, which diverged on every edit.

The rule: if an interface element appears a second time, it is extracted into a
shared component, and the sections USE it instead of copying it.

The ready templates:

- **`ui/QueryBar.qml`** — the single query bar. Two ways to express a query:
  TYPE the SQL by hand or CLICK it together in the builder (the WHERE filter,
  SELECT fields, GROUP BY, ORDER BY, DISTINCT, a calculated field). Switching
  between the modes does not lose the query. The component executes nothing —
  it emits the specification and the SQL through the `applied` signal, and the
  section decides whether to apply it to the database or to an in-memory list.
- **`ui/DataTable.qml`** — the template table: one description of the columns
  for the header and the rows, a choice of visible columns and their order, a
  pinned header, zebra striping, `reuseItems`, a click on a row → a signal (the
  section opens a sidebar), "+"/"−" on a cell add a condition to the query.
- **`ui/GraphCanvas.qml`** — the template graph canvas: category blocks with
  collapsing, dragging nodes with push-away and snapping to the grid, edges
  that follow the node, routing through free corridors, a click → the side
  panel, a double click → a pivot.

A new section with multi-field elements MUST be built on these templates. Its
own table or its own search bar in a new section is a defect.

Every section that shows rows is on them now: State, Events, SQL,
Vulnerabilities, Findings, Privilege use, File activity, Network activity. A
facet button does not filter on the side - it writes a condition into the same
query bar, where it is visible and can be edited.

## 15a. Never assign to a bound property, and never name a file in a string

Two QML traps that both hide from every check that does not RENDER:

- **An assignment kills the binding.** `colOrder = ...` on a property declared as
  `property var colOrder: <expression over cur>` silently freezes it at that
  value forever. The state table did exactly this: the columns froze at the
  first table opened, every other table drew those columns, and since its rows
  have no such fields the table showed the right number of rows with every cell
  empty - "State shows nothing", while the rows were never the problem. What a
  view chooses goes into its OWN property; what depends on the data stays a
  binding.
- **A file named in a string is not checked by the compiler.**
  `Qt.resolvedUrl("DashboardView.qml")` resolves against the file it is written
  in, so moving a view left six Loaders pointing at nothing - and a Loader that
  finds nothing stays silent. Every dashboard was blank while every check passed.
  The verification now resolves each `Qt.resolvedUrl()` in ui/ and requires the
  file to exist.

Sign of both: the interface is empty or stale, and there is no error anywhere.
Neither compiling QML nor loading the window reports them; only opening the
section and looking at what is drawn does.

## 16. Layout hygiene: nothing overlaps and nothing escapes

A component counts as finished only if it withstands REAL data: a long package
name, a 200-character path, an empty value, 400 rows.

- **Text is elided, it does not stretch the container.** Every label has
  `elide` and a width limit (`Layout.maximumWidth` or a fixed column). A graph
  node with a long label used to stretch and cover its neighbours and the
  edges.
- **Nothing overlaps.** Elements in a row of fixed height are positioned by a
  layout, not by absolute coordinates; an overlap is a sign that the height was
  guessed.
- **One shape for elements of the same kind.** Some graph nodes were drawn as
  ovals and some as blocks — the inconsistency read as "these are different
  entities", although the type is already shown by the icon and the colour. The
  type is encoded by the icon and the colour, the shape stays the same.
- **Decorative inserts repeat the geometry of the parent.** An accent stripe
  with square corners stuck out of a rounded frame — it must have the same
  corner radius.
- **An empty value is shown as emptiness**, not as a placeholder dash.
- Verify by RENDERING on live data: compiling catches neither an overlap nor
  something escaping its frame.


## 17. A section with a table looks and works like "Events"

"Events" is the reference, not a special case. Any section that shows a table
repeats its design so that the skill transfers without relearning:

- **One query bar** (`ui/QueryBar.qml`), and it is minimalist: on the left a
  quick search ACROSS ALL FIELDS (the main action is "find anything" without
  knowing SQL), on the right the parts of the query as COMPACT ICONS with a
  counter (fields, conditions, grouping, sorting). The details live in their
  own popups: 20 fields and 5 conditions never fit into one line, while a
  counter is read instantly. There must be no separate "filter" field next to
  it: two ways to select the same thing are two places to get it wrong.
- **The condition is executed by the DATABASE**, not by parsing a string in the
  interface. Parsing in QML has already produced a silently wrong answer twice:
  it understood only `AND`, while `OR`, `NOT` and `MATCH` (which expands into
  `LIKE '%…%'`) it did not.
- **Only the fields of THIS table are offered.** There is no common list of
  fields: every state table has its own set. Free text is also expanded into a
  condition over the columns of the current table.
- **The selection defines the visible columns** for the current view; a
  permanent column setup is a separate panel, and that is what persists. One
  narrow query must not reshape the view forever.
- **Long lists collapse**: if the chips (fields, conditions, sorts, groupings)
  take more than two lines, the rest goes behind "…", and the full list opens
  in a separate popup with the same actions.
- **Grouping** is a panel on the left: exactly as many columns as there are
  fields in `GROUP BY`, widths fit the content and can be dragged at the edge
  of the header, the `count` column is always visible, grouped fields are
  removed from the table.
- **The table styling is one**: a pinned header with column names and
  click-to-sort (a direction icon), zebra striping, a fixed row height,
  `reuseItems`, a click on a row opens a sidebar with all the fields, a double
  click on a value copies it, `+`/`−` on a cell append a condition.
- **Saving and query history only where it is justified.** "Events" has them
  (an investigation lives long); in other sections the query bar is the same
  but without saved templates and history.

Sign of a violation: a section grew ITS OWN search field or its own condition
parser. That means the template was bypassed, and sooner or later it will
answer incorrectly.



## 18. Personal data never enters the repository

The repository is public. Anything that gets into the code, the history or the
examples is visible to everyone and stays in the git history forever —
"we will delete it later" does not work.

- **Nothing personal is hard-coded**: home paths (`/home/name/...`), user
  names, machine names, real IP addresses and domains the machine talked to,
  MAC addresses, serial numbers, browser extension identifiers, e-mail
  addresses, keys and tokens.
- **Data is taken FROM THE SYSTEM at run time**, not written into the code: the
  home path through `Path.home()`/`$HOME`, the user name from the system,
  addresses from the state tables. If an example needs an address, use a
  documentation range (RFC 5737: `192.0.2.0/24`, `198.51.100.0/24`,
  `203.0.113.0/24`) or `example.com`.
- **Working journals are not published.** Files with the history of the work
  and observations about a specific machine (`CLAUDE.md`, `WISHES.md`) do not
  go into git: they are full of real paths, addresses and names. What is useful
  to other people is the documentation (`README.md`, `ARCHITECTURE.md`,
  `expertise/HOWTO.md`), not a diary.
- **Before every commit — a check**, not memory: grep the repository for home
  paths, e-mail addresses, non-public addresses. If something is found, fix it
  before committing.

Sign of a violation: a line in the code that is true only on this machine.


---

## How to check yourself before a commit

- [ ] Did the new data arrive through an input?
- [ ] Can the logic be edited in YAML without touching a `.py` file?
- [ ] Is there a list in the rule that I invented myself?
- [ ] Does the output have a time, a source and an action?
- [ ] Does the rule describe a method rather than a specific version/name/address?
- [ ] Has it been run on the live system, with the result stated in NUMBERS?
- [ ] Are many same-shaped elements shown as a table with a shared column description?
- [ ] Capitalisation, "…", margins — per the KDE HIG?
- [ ] Have all five verification steps been done (py_compile, QML, through QML, pipeline, RPM)?
- [ ] Was the MECHANISM fixed rather than a special case? Was the coverage measured?
- [ ] Are the table/search/graph taken from the shared templates instead of written anew?
- [ ] Verified on long values: is the text elided, does nothing overlap?
- [ ] Are same-kind elements of one shape, and related entities in ONE block?
- [ ] Does the table section repeat "Events": one query bar, the condition executed
      by the database, fields only from that table, long lists behind "…"?
- [ ] Is there NOTHING personal in the commit: home paths, names, real addresses, keys?
      Verified by grep, not from memory?

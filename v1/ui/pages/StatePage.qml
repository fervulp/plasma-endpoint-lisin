import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components/Fmt.js" as Fmt
import "../components/Sev.js" as Sev
import "../components"
import "../views"
import "."

// The "Data" section: read-only tables (state snapshots + the events stream),
// each read/filtered/grouped through the shared QueryBar and rendered by the
// shared DataTable. Right sidebars (details, columns) are full height.
Kirigami.Page {
    // no page title: the section is "Data" in the drawer; a header just wastes space
    id: page
    objectName: "statePage"
    title: ""
    padding: 0

    // grey canvas, so the white panels read as floating cards above it
    background: PageBackground {}

    property var s: root.sysState
    // EVENTS is just another Data tab. It is served by the backend like every
    // other tab (its rows come from the separate event store via
    // tableRows("events", ...), its curated default columns + count come in the
    // snapshot); this page no longer fabricates it. tabPrio sorts it first.
    // THE EVENT TAXONOMY: all field names + the fields grouped by category.
    // Loaded once (the taxonomy is static). Used for the events tab: every field
    // is offered in the query bar SELECT, and the Details sidebar groups by category.
    readonly property var eventTax: backend.eventTaxonomy()
    readonly property bool onEvents: cur && cur.name === "events"
    // the fields the Details sidebar shows, in SECTIONS: for events, grouped by
    // taxonomy category; for any other table, one unnamed section of its columns
    // the field-search term for the Details sidebar
    property string detailFilter: ""
    // the "…" SQL menu: picker items (history / saved), and the picked saved query
    property var pickItems: []
    property string pickMode: ""
    property var selectedQuery: null
    property var detailSections: {
        if (!lastSel || !cur) return []
        if (onEvents && eventTax.groups && eventTax.groups.length)
            return eventTax.groups
        return [{ group: "", fields: cur.columns }]
    }
    // THE READING ORDER COMES FROM THE RULES. Each source declares `priority:`
    // in its own YAML (lower first), so adding a source no longer means editing a
    // list of table names in the interface. A table without one sorts after those
    // that have one, alphabetically. Events is served with its own priority too.
    property var tabsModel: {
        var arr = (s ? s.tabs : []).slice()
        arr.sort(function (a, b) {
            // NB: `prio || 99` is wrong here — events has priority 0, and 0 is
            // falsy, so it would fall through to 99 and sort LAST. Check for
            // undefined explicitly.
            // NB: an explicit undefined check, not `|| big` — priority 0 is a
            // legal value and would be swallowed by a falsy test.
            var pa = a.priority; if (pa === undefined || pa === null) pa = 1e9
            var pb = b.priority; if (pb === undefined || pb === null) pb = 1e9
            return pa !== pb ? pa - pb
                             : String(a.title || a.name).localeCompare(String(b.title || b.name))
        })
        return arr
    }
    property int tabIndex: 0
    // THE ROWS OF THE CURRENT TABLE, fetched by name. The snapshot used to carry
    // the rows of all 50 tables - 115 thousand of them, 22.9 MB - and it is
    // rebuilt on every refresh, which froze the window for a second at a time.
    // Now the snapshot is the map of the tables and only what is on screen is
    // fetched (7 ms instead of 195 ms per refresh).
    property var curRows: []          // ONE page, as the database returned it
    property int curTotal: 0          // how many rows the condition matches in total
    property string rowsError: ""
    function loadRows() {
        if (!cur) { curRows = []; curTotal = 0; rowsError = ""; return }
        var where = page.whereSql()
        var order = sortCol !== "" ? (sortCol + (sortAsc ? " ASC" : " DESC")) : ""
        var lim = pageLimit > 0 ? pageLimit : 0
        var off = pageLimit > 0 ? pageIndex * pageLimit : 0
        var r = backend.tableRows(cur.name, where, order, lim, off)
        curRows = r.rows || []
        curTotal = r.total || 0
        rowsError = r.error || ""
    }
    // filtering the list of tables by name
    property string tabFilter: ""

    // the counter in the tab list alternates between the row count and how full
    // the table is; fifteen seconds each, so neither has to be hunted for
    property bool showFill: false
    Timer {
        running: page.visible
        interval: 15000
        repeat: true
        onTriggered: page.showFill = !page.showFill
    }
    readonly property var shownTabs: {
        if (tabFilter === "") return tabsModel
        var q = tabFilter.toLowerCase()
        return tabsModel.filter(t => String(t.name).toLowerCase().indexOf(q) >= 0
                                  || String(t.title).toLowerCase().indexOf(q) >= 0)
    }
    // pick a table by name (the list may be filtered - indexes would lie)
    function openTable(name) {
        for (var i = 0; i < tabsModel.length; i++)
            if (tabsModel[i].name === name) { tabIndex = i; return }
    }

    property var cur: tabIndex >= 0 && tabIndex < tabsModel.length
                      ? tabsModel[tabIndex] : null

    // the columns to render: the current table's own columns
    property var listCols: cur ? cur.columns : []
    property var colOrder: {
        if (!cur) return listCols
        const cfg = cur.colcfg
        if (cfg && cfg.order && cfg.order.length) {      // a saved order wins
            const base = cfg.order.filter(c => listCols.includes(c))
            for (const c of listCols) if (!base.includes(c)) base.push(c)
            return base
        }
        return page.interestOrder(listCols)              // else: analyst-first
    }
    // ANALYST-FIRST default column order for every Data tab: what a row IS
    // (name/command) and WHY it matters (risk/exposure/action/network) come first;
    // long/technical columns go last. Only the DEFAULT - a user-saved order (and
    // per-table tuned defaults like processes) still wins above.
    readonly property var interestKeys: [
        "ts", "name", "command", "title", "unit", "action", "outcome",
        "risk", "exposure", "severity", "threat", "status", "nopasswd", "cvss",
        "category", "module", "destination", "remote", "source", "address",
        "ip", "port", "proto", "user", "owner", "subject", "object",
        "path", "file", "exe", "package", "vector", "changed", "enabled",
        "purpose", "message", "pid", "kind", "version"]
    readonly property var lateKeys: ["content", "description", "code", "vrl", "raw"]
    function colScore(c) {
        var lc = String(c).toLowerCase()
        if (lc.charAt(0) === "_") return 2000
        for (var i = 0; i < lateKeys.length; i++)
            if (lc.indexOf(lateKeys[i]) >= 0) return 1000 + i
        for (var j = 0; j < interestKeys.length; j++)
            if (lc.indexOf(interestKeys[j]) >= 0) return j
        return 500
    }
    function interestOrder(cols) {
        // decorate-sort-undecorate keeps it stable for equal scores (columns of
        // the same rank keep their natural order)
        var dec = cols.map(function (c, i) { return [page.colScore(c), i, c] })
        dec.sort(function (a, b) { return a[0] - b[0] || a[1] - b[1] })
        return dec.map(function (x) { return x[2] })
    }
    readonly property var longCols: ["content", "description", "code"]
    // "key" is NOT masked: no private material is stored in the database (for
    // private keys the value is empty), and public keys are open by definition -
    // we show their content directly. Only real secrets are masked.
    readonly property var sensitiveCols: ["secret", "private", "token", "password"]
    // WHICH COLUMNS ARE SHOWN BY DEFAULT: all of them except the long ones
    // (content, description, vrl) and the secret ones.
    //
    // Capping the default at eight, as Events does with its 98 taxonomy fields,
    // saved 0.17 s per tab switch and cost the point of the table: for processes
    // it hid `command`, which is the column people come to that table for. A
    // table is read by its columns; the cheap thing to cut was the number of
    // objects per cell, and that is cut.
    property var hiddenCols: cur && cur.colcfg && cur.colcfg.hidden
                             ? cur.colcfg.hidden
                             : listCols.filter(c => longCols.includes(c)
                                                    || sensitiveCols.includes(c))
    // A selection made in the query bar wins, but only for the columns this table
    // actually has - so it can never outlive the table it was made for.
    // THE TABLE'S OWN COLUMN SET, before any hand-picked SELECT. Keeping this
    // separate breaks a two-way loop that caused a family of bugs: the selection
    // was derived from the shown columns while the shown columns were derived
    // from the selection, so which one won depended on the order two bindings
    // happened to re-evaluate. Now the base is one-directional (rule -> shown),
    // the query bar's DEFAULT is the base, and a hand-picked SELECT overrides
    // what is shown without ever feeding back into the default.
    property var baseCols: {
        var out = colOrder.filter(c => !hiddenCols.includes(c))
        if (groupBy.length || groupKeys.length)
            out = out.filter(c => groupBy.indexOf(c) < 0 && groupKeys.indexOf(c) < 0)
        return out
    }
    property var visibleCols: {
        var mine = selectCols.filter(c => listCols.includes(c))
        var out = mine.length ? mine : baseCols
        // A COLUMN GROUPED BY IS NOT REPEATED IN THE TABLE. The group panel on the
        // left already says which value this is; showing the same value again in
        // every row of the right-hand table is a column of one repeated word.
        // Both lists: groupBy is what the user just typed (so the column vanishes
        // immediately, without waiting for the database round trip), groupKeys is
        // what the database confirmed as a key — an aggregate among the terms is
        // not a column and is not in either.
        if (groupBy.length || groupKeys.length)
            out = out.filter(c => groupBy.indexOf(c) < 0 && groupKeys.indexOf(c) < 0)
        return out
    }

    property var savedWidths: cur && cur.colcfg && cur.colcfg.widths
                              ? cur.colcfg.widths : ({})
    property var liveWidths: ({})
    // The view (selection/sorting/filters/page) is reset ONLY when the tab
    // changes (curName), not on every automatic data refresh - otherwise the user
    // loses the selected row and the position on every tick.
    property string curName: cur ? cur.name : ""
    readonly property var src: cur && cur.source ? cur.source : null
    readonly property bool srcFailed: !!(src && String(src.error || "") !== "")
    // one sentence, in the order the question is asked: what made these rows,
    // how, how often, and how old this copy is
    readonly property string provenance: {
        if (!src) return ""
        if (srcFailed)
            return "the last run of " + src.rule + " failed: " + src.error
                   + (src.error_at ? " (" + Fmt.maybeLocal(src.error_at) + ")" : "")
        var parts = ["rule " + src.rule + ", " + src.how]
        if (src.interval > 0)
            parts.push("every " + (src.interval >= 60
                                   ? Math.round(src.interval / 60) + " min"
                                   : src.interval + " s"))
        if (cur && cur.collected_at)
            parts.push("collected " + Fmt.localHM(cur.collected_at))
        if (cur && cur.count !== undefined)
            parts.push(cur.count + " rows")
        if (src.tests) parts.push("has its own tests")
        if (src.enabled === false) parts.push("disabled")
        return parts.join(" · ")
    }
    // ONE TABLE REBUILD PER TAB SWITCH. Each of these assignments feeds a binding
    // the table is built from (rows, columns), and every one of them used to
    // rebuild the delegates: loading first and resetting after cost three full
    // rebuilds (measured: ~0.5 s each on a 21-column page). So: tear the table
    // down cheaply first (empty rows), reset everything while it is empty, and
    // load ONCE at the end. _switching keeps onCurChanged from loading again.
    property bool _switching: false
    // EMPTY THE TABLE BEFORE THE COLUMNS CHANGE. tabIndex feeds `cur`, which feeds
    // the column set; if the old rows are still in place when the columns change,
    // every row delegate is rebuilt against the new columns and then thrown away
    // (measured: that rebuild is the bulk of a tab switch). Clearing here, on the
    // index itself, means the column change lands on an empty table and the rows
    // are built exactly once, by loadRows below.
    onTabIndexChanged: { curRows = []; curTotal = 0; rowsError = "" }
    onCurNameChanged: {
        _switching = true
        curRows = []; curTotal = 0; rowsError = ""
        page.queryText = ""; page.queryError = ""; page.selectCols = []
        if (typeof qbar !== "undefined") qbar.clearAll()
        liveWidths = ({}); selRows = []; selAnchor = -1; pageIndex = 0
        sortCol = ""; sortAsc = true; lastSel = null; selName = ""
        allSelected = false
        groupBy = []; groupKeys = []; groupMeasures = []   // a grouping is per table
        groupPicked = false; groupVal = ""; groupParts = []
        syncColumns()          // the new table's columns, built once
        // and only THEN the selection, from the columns that were just computed —
        // otherwise the bar is cleared against the previous table's column list
        if (typeof qbar !== "undefined") qbar.setSelection(page.baseCols)
        page.loadRows()
        // AND AGAIN once the event loop has settled. The bar re-derives its own
        // selection from bindings that re-evaluate after this handler returns, so
        // an assignment made here alone was overwritten a moment later — the
        // SELECT then listed the whole table instead of the shown columns.
        Qt.callLater(function () {
            if (typeof qbar !== "undefined" && !page._switching)
                qbar.setSelection(page.baseCols)
        })
        _switching = false
    }
    // The same tab, fresh data: we re-point the selection and the details row at
    // the NEW row objects by _id (so that they show the current values).
    onCurChanged: {
        // a tab SWITCH is handled by onCurNameChanged (one rebuild); this handler
        // is only for fresh data of the SAME table
        if (_switching) return
        // fresh data for the same table: re-read the rows, then re-point the
        // selection at the new objects
        if (cur && cur.name === curName && curRows.length === 0) page.loadRows()
        if (!cur || cur.name !== selName) return
        const byId = ({})
        for (const r of curRows) byId[r._id] = r
        selRows = selRows.map(r => byId[r._id]).filter(r => r !== undefined)
        lastSel = lastSel ? (byId[lastSel._id] || null) : null
        if (!lastSel && detailsPanel.open) detailsPanel.open = false
    }
    // "Explore" from an event: open the right tab and put the condition into the
    // query bar - the SAME mechanism the user types into, executed by the
    // database (principle 17). It used to set a per-column filter evaluated in
    // JS; once the rows started arriving already selected by the database, that
    // filter quietly stopped doing anything and the jump landed on an unfiltered
    // table.
    // The order matters: first the tab (changing it clears the query), then the
    // condition.
    function applyFocus() {
        var f = root ? root.stateFocus : null
        if (!f) return
        for (var i = 0; i < tabsModel.length; i++) {
            if (tabsModel[i].name === f.table) { tabIndex = i; break }
        }
        // a raw WHERE (a jump into the Events tab from a dashboard/graph): a raw
        // condition already has operators, so applyQuery passes it straight to the
        // events query. An empty raw just opens the tab.
        if (f.raw !== undefined) {
            page.applyQuery(String(f.raw || ""))
            return
        }
        if (typeof qbar !== "undefined") {
            qbar.clearAll()
            qbar.addCondition(f.col, "=", String(f.val))
            qbar.apply()
        }
    }
    Component.onCompleted: {
        // if the first tab (Events) is genuinely empty, open the first one that
        // has rows so Data does not come up blank.
        if (page.tabIndex === 0 && page.cur && (page.cur.count || 0) === 0)
            for (var i = 0; i < page.tabsModel.length; i++)
                if ((page.tabsModel[i].count || 0) > 0) { page.tabIndex = i; break }
        page.syncColumns(); page.loadRows(); applyFocus()
        if (dtable) dtable.scrollToTop()   // a different table starts at its top
    }

    // FRESH DATA WITHOUT THRASHING. A snapshot arrives whenever events are
    // ingested (seconds apart) or a collection ran. Re-reading the table on every
    // one of them would keep the list rebuilding under the cursor, so:
    //   * only the table ON SCREEN is re-read, and only when the page is visible;
    //   * a snapshot that carries no NEW COLLECTION (`gen` unchanged) cannot have
    //     changed a state table — only the events stream grows, so only the
    //     Events tab re-reads;
    //   * and the reads are coalesced by a short timer.
    property int _seenGen: -1
    onSChanged: {
        if (!page.visible) return
        var g = s && s.gen !== undefined ? s.gen : -1
        var isEvents = cur && cur.name === "events"
        if (g === _seenGen && !isEvents) return
        _seenGen = g
        rowsTimer.restart()
    }
    onVisibleChanged: if (visible) rowsTimer.restart()
    Timer {
        id: rowsTimer
        interval: 400
        onTriggered: page.loadRows()
    }
    Connections {
        target: root
        function onStateFocusChanged() { page.applyFocus() }
    }

    function colWidth(c) { return liveWidths[c] || savedWidths[c] || 160 }
    // ONE row height for BOTH tables (the group panel and the DataTable), so
    // grouped rows are exactly as tall as the rows on the right. The probe is a
    // hidden ItemDelegate built like a table row - default padding + a default
    // font Label - so its implicitHeight IS the table's natural row height.
    readonly property real rowHeight: _rowProbe.implicitHeight
    QQC2.ItemDelegate {
        id: _rowProbe
        visible: false
        contentItem: QQC2.Label { text: "Ag" }
    }
    function setColWidth(c, w) {
        const o = Object.assign({}, liveWidths)
        o[c] = Math.max(60, w)
        liveWidths = o
        _widthVer++          // the column signature changed -> rebuild the widths
        syncColumns()
    }
    function persistWidths() {
        if (!cur) return
        saveColCfg(colOrder, hiddenCols, Object.assign({}, savedWidths, liveWidths))
    }
    function saveColCfg(order, hidden, widths) {
        if (!cur) return
        backend.setTabColumns(cur.name, JSON.stringify(
            { order: order, hidden: hidden,
              widths: widths || Object.assign({}, savedWidths, liveWidths) }))
    }
    function moveCol(name, dir) {
        const o = colOrder.slice()
        const i = o.indexOf(name), j = i + dir
        if (i < 0 || j < 0 || j >= o.length) return
        o[i] = o[j]; o[j] = name
        saveColCfg(o, hiddenCols)
    }
    function toggleCol(name) {
        let h = hiddenCols.slice()
        if (h.includes(name)) h = h.filter(x => x !== name)
        else h.push(name)
        saveColCfg(colOrder, h)
    }

    // sort + filters + pagination
    property string sortCol: ""
    property bool sortAsc: true
    function toggleSort(c) {
        if (sortCol === c) {
            if (sortAsc) sortAsc = false
            else { sortCol = ""; sortAsc = true }   // the third click resets it
        } else { sortCol = c; sortAsc = true }
        pageIndex = 0
        page.loadRows()          // ORDER BY is the database's job
        if (dtable) dtable.scrollToTop()   // a new order is a new reading
    }
    // not during a tab switch: that handler resets pageIndex BEFORE the sort, so
    // this fired an extra query carrying the previous table's ORDER BY (which the
    // new table has no such column for), and defeated the one-rebuild rule.
    onPageIndexChanged: if (!_switching) { page.loadRows(); if (dtable) dtable.scrollToTop() }
    onPageLimitChanged: { pageIndex = 0; page.loadRows() }
    // ---- THE SINGLE SEARCH, AS IN EVENTS ----
    // The condition is executed by the DATABASE (stateRows), not by parsing a
    // string in the interface: that way MATCH, OR and NOT work, and the mechanism
    // is one for every section.
    property string queryText: ""
    property string queryError: ""
    // THE SELECTION SETS THE COLUMNS for the current view; the permanent setup is
    // the "Columns" panel, and that is what persists (otherwise one query would
    // reshape the view forever)
    // THE COLUMNS CHOSEN BY THE QUERY live in their OWN property.
    //
    // This used to assign colOrder and hiddenCols directly - and an assignment
    // to a bound property DESTROYS the binding. Both were bound to the current
    // table, so after the first query (the query bar applies one as soon as the
    // page is built) the columns froze at whatever table was open then. Every
    // other table kept drawing those columns, and since its rows have no such
    // fields, the table showed the right number of rows with every cell empty -
    // "State shows nothing". The rows were never the problem.
    property var selectCols: []
    function applySelectCols(sel) {
        if (!sel || !sel.length || !cur) return
        var all = cur.columns.filter(c => !c.startsWith("_"))
        var keep = sel.filter(c => all.indexOf(c) >= 0)
        if (!keep.length) return
        selectCols = keep
    }

    // THE RISK COLOUR IN A ROW: the severity is visible at once, without reading
    // the columns. Risk columns are named differently in different tables, so we
    // look at whichever exist: severity/cvss_rating (vulnerabilities), risk
    // (privesc), exposure (sockets), status (kernel_params).
    // CELL TEXT: an ISO-8601 timestamp is shown as readable LOCAL time (not the
    // raw "…T12:03:57Z"); everything else as-is. Applies to every table, so any
    // time column reads nicely.
    function cellDisplay(r, k) {
        var v = r[k]
        if (v === undefined || v === null) return ""
        return String(Fmt.maybeLocal(v))
    }
    // the severity accent: the ONE shared mapping (Sev.js), so a row in "Data"
    // gets the same colour for the same severity as every dashboard table
    function rowAccent(r) { return Sev.stateAccent(r) }

    // THE TYPE OF AN EVENT AT A GLANCE (icon): network / file / process /
    // correlation (a detection is an alert) / aggregate / raw. Only used on the
    // Events tab; other tables have no event_category.
    readonly property var eventIcons: ({
        network: "network-connect",
        file: "document-edit-symbolic",       // monochrome file-ops icon
        process: "system-run", authentication: "dialog-password",
        iam: "dialog-password", driver: "drive-harddisk",
        package: "package-x-generic", session: "system-users",
        configuration: "document-properties", intrusion_detection: "security-high"
    })
    function eventIcon(r) {
        if (!r) return ""
        // a detection (correlation) always reads as an alert
        if (String(r.event_kind || "") === "alert") return "security-high"
        // THE ICON IS DRIVEN BY event_category: an eBPF exec has category=process,
        // so it gets the process icon (not a "raw" one).
        var c = String(r.event_category || "")
        if (c && page.eventIcons[c]) return page.eventIcons[c]
        if (String(r.event_kind || "") === "aggregate") return "gnumeric-object-list"
        if (String(r.raw || "") !== "" || String(r.not_normalized || "") !== "")
            return "text-x-generic"
        return "view-list-details"
    }
    function eventIconTip(r) {
        if (!r) return ""
        var k = String(r.event_kind || "")
        if (k === "alert") return "Detection (correlation)"
        if (k === "aggregate") return "Aggregate of " + (r.event_count || "?") + " events"
        return String(r.event_category || "event")
              + (String(r.raw || "") !== "" ? " · has raw" : "")
    }

    // ---- GROUPING (as in "Events") ----
    property var groupBy: []
    property var groupParts: []
    property string groupVal: ""
    property bool groupPicked: false
    property var groupRows: []
    // reload groups whenever the grouping changes (not only via applyQuery), so
    // the values always show
    onGroupByChanged: reloadGroups()
    function reloadGroups() {
        if (!cur || !groupBy.length) {
            // clearing the grouping must also forget its keys — they hide their
            // columns from the table, and a stale key kept a column hidden after
            // the grouping was removed.
            groupRows = []; groupKeys = []; groupMeasures = []; groupError = ""
            return
        }
        // JSON, not a comma-joined string: a grouping term may itself be an
        // expression containing commas (substr(path,1,12)) and joining would cut
        // it in half.
        var r = backend.stateGroups(cur.name, JSON.stringify(groupBy),
                                    page.baseWhere())
        groupRows = r.rows || []
        // the split into keys and measures is the database's answer, not a guess
        // made here: an aggregate term becomes a measure column, the rest keys
        groupKeys = r.keys || []
        groupMeasures = r.measures || []
        groupError = r.error || ""
    }
    property string groupError: ""
    // ---- the group panel as the SHARED DataTable (same formatting/functionality) ----
    // widths of the group columns, resizable exactly like the main table's
    property var groupWidths: ({})
    function groupColWidth(k) {
        return groupWidths[k] !== undefined ? groupWidths[k]
                                            : (k === "_count" ? 70 : 150)
    }
    function setGroupColWidth(k, w) {
        var o = Object.assign({}, groupWidths); o[k] = Math.max(40, w)
        groupWidths = o
    }
    // COUNT IS THE POINT OF A GROUPING, so it must always be on screen. It used
    // to sit after a `fill` column whose minimum width is wider than this panel —
    // the fill pushed the count past the right edge and it could only be reached
    // by scrolling. No fill here: every column has a real width and the panel
    // scrolls if the values are long.
    // the keys and the measures the database actually used, as it reported them
    property var groupKeys: []
    property var groupMeasures: []
    readonly property var groupColumns: {
        var out = [{ k: "_count", t: "count",
                     w: groupColWidth("_count") / Kirigami.Units.gridUnit,
                     right: true }]
        for (var i = 0; i < groupKeys.length; i++)
            out.push({ k: "g" + i, t: groupKeys[i],
                       w: groupColWidth("g" + i) / Kirigami.Units.gridUnit })
        // an aggregate the user asked for (sum(own_mb), avg(...)) is a COLUMN of
        // the grouping, not a key — numbers to the right, like any measure
        for (var j = 0; j < groupMeasures.length; j++)
            out.push({ k: "m" + j, t: groupMeasures[j],
                       w: groupColWidth("m" + j) / Kirigami.Units.gridUnit,
                       right: true })
        return out
    }
    readonly property var groupTableRows: {
        var out = []
        for (var i = 0; i < groupRows.length; i++) {
            var gr = groupRows[i]
            var parts = gr.parts || [String(gr.value)]
            var o = { _id: String(i), _count: gr.n, _gval: gr.value, _gparts: parts }
            for (var j = 0; j < groupKeys.length; j++)
                o["g" + j] = j < parts.length ? String(parts[j]) : ""
            var ms = gr.measures || []
            for (var k = 0; k < ms.length; k++)
                o["m" + k] = String(ms[k])
            out.push(o)
        }
        return out
    }
    // format the key columns exactly like the main table; count and the measures
    // are numbers and are shown as they came back
    function groupCellDisplay(row, key) {
        if (key === "_count") return String(row._count)
        var val = row[key]
        if (key.charAt(0) === "m") return val === undefined ? "" : String(val)
        if (val === "" || val === undefined) return "(empty)"
        var idx = parseInt(key.substring(1))
        var name = page.groupKeys[idx]
        if (name === undefined) return String(val)
        var pseudo = {}; pseudo[name] = val
        return page.cellDisplay(pseudo, name)
    }
    function isGroupSel(row) {
        return page.groupPicked && page.groupVal === String(row._gval || "")
    }
    function toggleGroup(row) {
        var v = String(row._gval || "")
        if (page.groupPicked && page.groupVal === v) {
            page.groupPicked = false; page.groupVal = ""; page.groupParts = []
        } else {
            page.groupPicked = true; page.groupVal = v
            page.groupParts = row._gparts || [v]
        }
        page.applyQuery(page.queryText)
    }
    // the condition without the group - the groups themselves are counted by it
    // (time filtering is done by adding a `ts` condition in the query bar - the
    // QueryBar already understands ts and "last N days")
    function baseWhere() {
        if (queryText === "") return ""
        return hasOperator(queryText) ? queryText : freeText(queryText)
    }
    // A grouping term is either a plain column or an expression, and the two are
    // written into SQL differently: a column name is QUOTED as an identifier, an
    // expression must be passed through as it is (quoting substr(path,1,12) would
    // ask for a column with that name).
    function groupTerm(f) {
        return /^[A-Za-z0-9_]+$/.test(f) ? '"' + f + '"' : f
    }
    // the condition of the selected group: AND over all its terms
    function groupCond() {
        if (!groupKeys.length || !groupPicked) return ""
        var parts = []
        for (var i = 0; i < groupKeys.length; i++) {
            var t = groupTerm(groupKeys[i])
            var v = i < groupParts.length ? String(groupParts[i]) : ""
            if (v === "")
                parts.push('(' + t + ' IS NULL OR ' + t + ' = \'\')')
            else
                parts.push(t + ' = \'' + v.replace(/'/g, "''") + '\'')
        }
        return parts.length > 1 ? "(" + parts.join(" AND ") + ")" : parts[0]
    }

    // does the string contain an operator - then it is a condition, otherwise free text
    function hasOperator(q) {
        return /(=|<>|<|>|LIKE|IS NULL|IS NOT NULL)/i.test(q)
    }
    // FREE TEXT IS SEARCHED ONLY OVER THE COLUMNS OF THIS TABLE: every state
    // table has its own set of fields, there is no common list.
    function freeText(q) {
        if (!cur) return ""
        var cols = cur.columns.filter(c => !c.startsWith("_"))
        var e = String(q).replace(/'/g, "''")
        var parts = []
        for (var i = 0; i < cols.length; i++)
            parts.push('CAST("' + cols[i] + "\" AS TEXT) LIKE '%" + e + "%'")
        return parts.length ? "(" + parts.join(" OR ") + ")" : ""
    }
    // THE CONDITION IS ASSEMBLED IN ONE PLACE and executed by the database: the
    // text of the query (or a free-text search over the columns of this table)
    // plus the group picked on the left.
    function whereSql() {
        var w = queryText === "" ? ""
              : (hasOperator(queryText) ? queryText : freeText(queryText))
        var g = groupCond()
        if (g) w = w ? "(" + w + ") AND " + g : g
        return w
    }
    // COPY: table cells are plain Labels (not selectable), so copying went through
    // nothing. A hidden TextEdit is the portable clipboard bridge (no Clipboard
    // type in plain QtQuick). copyText copies a value; copyRow copies the visible
    // columns of a row as tab-separated text.
    function copyText(s) {
        clipHelper.text = String(s === null || s === undefined ? "" : s)
        clipHelper.selectAll()
        clipHelper.copy()
        clipHelper.deselect()
    }
    function copyRow(r) {
        var parts = []
        for (var i = 0; i < page.visibleCols.length; i++)
            parts.push(String(r[page.visibleCols[i]] === undefined
                              ? "" : r[page.visibleCols[i]]))
        copyText(parts.join("\t"))
    }
    TextEdit { id: clipHelper; visible: false }
    property var menuRow: null
    QQC2.Menu {
        id: rowMenu
        QQC2.MenuItem {
            text: "Copy row"
            icon.name: "edit-copy"
            onTriggered: if (page.menuRow) page.copyRow(page.menuRow)
        }
    }
    function applyQuery(sql) {
        queryText = (sql || "").trim()
        pageIndex = 0
        allSelected = false            // the matching set changed
        reloadGroups()
        page.loadRows()
        queryError = page.rowsError
    }
    property int pageLimit: 50
    property int pageIndex: 0
    property int pageCount: pageLimit > 0
        ? Math.max(1, Math.ceil(curTotal / pageLimit)) : 1
    property var pagedRows: curRows

    property var selRows: []           // the selected rows (_id objects)
    // "Select all" selects EVERY matching record across ALL pages, not just the
    // loaded page. We keep a flag (not 36k row objects - that would kill the
    // per-row isSel check); actions read allSelected + the current filter.
    property bool allSelected: false
    property var lastSel: null         // the last clicked one - for the details sidebar
    property int selAnchor: -1         // the index for a shift range
    property string selName: ""        // the tab the selection belongs to
    // A MAP, NOT A SCAN. isSel is called for every row (twice: highlight and
    // checkbox) on every rebuild, and it used to walk the whole selection — with a
    // page selected that is rows x selection comparisons for one repaint.
    readonly property var _selIds: {
        var m = ({})
        for (var i = 0; i < selRows.length; i++)
            if (selRows[i] && selRows[i]._id !== undefined) m[selRows[i]._id] = true
        return m
    }
    function isSel(r) {
        if (allSelected) return true
        return r._id !== undefined && _selIds[r._id] === true
    }
    // how many are selected, honouring the all-pages flag
    property int selCount: allSelected ? curTotal : selRows.length
    function clickRow(r, index, mods) {
    selName = cur ? cur.name : ""    // the selection belongs to this tab
    page.allSelected = false          // a specific click leaves all-pages mode
        if (mods & Qt.ShiftModifier && selAnchor >= 0) {
            const a = Math.min(selAnchor, index), b = Math.max(selAnchor, index)
            selRows = pagedRows.slice(a, b + 1)
        } else if (mods & Qt.ControlModifier) {
            selRows = isSel(r) ? selRows.filter(x => x._id !== r._id)
                               : selRows.concat([r])
            selAnchor = index
        } else {
            selRows = isSel(r) && selRows.length === 1 ? [] : [r]
            selAnchor = index
        }
        if (selRows.length === 1) {          // one row - show the details
            lastSel = selRows[0]
            detailsPanel.open = true
        } else {                              // none or several - nothing
            lastSel = null
            detailsPanel.open = false
        }
    }
    // a tristate select-all: empty -> current page (half) -> all pages (full)
    property int headerCheckState: allSelected ? Qt.Checked
        : selRows.length > 0 ? Qt.PartiallyChecked
        : Qt.Unchecked
    function togglePageSelect() {
        if (allSelected) {                    // full -> off
            allSelected = false; selRows = []
        } else if (selRows.length > 0) {      // half (page) -> full (all pages)
            allSelected = true; selRows = []
        } else {                              // off -> current page (half)
            selRows = pagedRows.slice()
        }
    }
    // THE COLUMN DESCRIPTORS for the shared DataTable: a checkbox column, an
    // event-type icon column (Events tab only), then the visible data columns
    // with their widths (colWidth is in pixels, the template wants gridUnits).
    //
    // NOT A BINDING — AND THAT IS THE POINT. Every collection push hands the page
    // a fresh snapshot, so `cur` (and with it listCols/colOrder/visibleCols) is a
    // NEW object even when nothing about the table changed. As a binding this list
    // was therefore rebuilt every few seconds, and a new column list tears down
    // and recreates every cell in the table — the whole table flickering on a
    // timer. Now it is rebuilt only when its SIGNATURE really changes.
    // the field list handed to the query bar — rebuilt with the columns, i.e.
    // only when the table (or its column set) actually changed
    property var qbarFields: []
    property var dtColumns: []
    property string _colSig: ""
    property int _widthVer: 0          // bumped by a column resize
    function syncColumns() {
        var cols = visibleCols
        var sig = (cur ? cur.name : "") + "|" + cols.join("") + "|" + _widthVer
        if (sig === _colSig) return
        _colSig = sig
        var out = [{ k: "_check", kind: "check", w: 2 }]
        if (cur && cur.name === "events")
            out.push({ k: "_icon", kind: "icon", w: 1.6 })
        for (var i = 0; i < cols.length; i++)
            out.push({ k: cols[i], t: cols[i],
                       w: colWidth(cols[i]) / Kirigami.Units.gridUnit })
        dtColumns = out
        // THE FIELDS ARE THE CURRENT TABLE'S FIELDS — nothing else. Offering the
        // whole event taxonomy here meant a picker full of names this table does
        // not have: pick one and the query came back "no such column", or it was
        // silently dropped. What a table has is what the database says it has.
        qbarFields = listCols.filter(function (c) { return !c.startsWith("_") })
                             .map(function (c) { return { name: c } })
    }
    onVisibleColsChanged: syncColumns()
    // resizing fires continuously while dragging; persist once it settles
    Timer { id: persistTimer; interval: 400; onTriggered: page.persistWidths() }


    // The page-level footer was split into the cards themselves: data freshness
    // sits at the bottom of the tabs card, pagination + selection at the bottom
    // of the table card, so each card carries the information about its own
    // content.

    // -------- page body: main column + full-height right sidebars --------
    RowLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.largeSpacing

        // -------- the vertical state tabs (resized by the right edge) --------
        Item {
            id: tabsPanel
            property real panelW: Kirigami.Units.gridUnit * 12
            Layout.preferredWidth: panelW
            Layout.fillHeight: true

            FloatCard { anchors.fill: parent }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Kirigami.Units.smallSpacing
                spacing: 0
                // SEARCH BY TABLE NAME: type "release" and only the tables where
                // it occurs are left. There are almost fifty tables.
                Kirigami.SearchField {
                    id: tabSearch
                    Layout.fillWidth: true
                    Layout.margins: Kirigami.Units.smallSpacing
                    placeholderText: "find a table…"
                    onTextChanged: page.tabFilter = text
                }
                QQC2.Label {
                    visible: page.tabFilter !== ""
                    Layout.leftMargin: Kirigami.Units.smallSpacing
                    text: page.shownTabs.length + " of " + page.tabsModel.length
                    opacity: 0.6
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.topMargin: 10         // gap between the search and the list
                ListView {
                    model: page.shownTabs
                    clip: true
                    delegate: QQC2.ItemDelegate {
                        id: tabItem
                        required property var modelData
                        width: ListView.view.width
                        highlighted: page.cur && page.cur.name === modelData.name
                        onClicked: page.openTable(modelData.name)
                        // the selected tab lights up smoothly
                        background: Rectangle {
                            radius: 3
                            color: tabItem.highlighted
                                   ? Qt.alpha(Kirigami.Theme.highlightColor, 0.18)
                                   : tabItem.hovered
                                     ? Qt.alpha(Kirigami.Theme.textColor, 0.05)
                                     : "transparent"
                            Behavior on color {
                                ColorAnimation { duration: Kirigami.Units.shortDuration }
                            }
                        }
                        contentItem: RowLayout {
                            spacing: Kirigami.Units.smallSpacing
                            Kirigami.Icon {
                                source: modelData.icon
                                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                            }
                            QQC2.Label {
                                text: modelData.title
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                            // THE COUNTER ALTERNATES: fifteen seconds of "how
                            // many rows", then fifteen of "how full" — the share
                            // of cells that hold a value. A source that keeps
                            // returning its rows while a column has gone empty is
                            // invisible in the count alone; that is how the
                            // browser tab sat at a tenth of this machine's
                            // extensions. Both numbers are about the same table,
                            // so they take the same place rather than a new column.
                            QQC2.Label {   // the counter is always visible on the right
                                text: page.showFill && modelData.fill !== undefined
                                                    && modelData.fill !== null
                                      ? Math.round(modelData.fill * 100) + "%"
                                      : modelData.count
                                color: page.showFill && modelData.fill !== undefined
                                                     && modelData.fill !== null
                                       ? (modelData.fill < 0.5
                                          ? Kirigami.Theme.negativeTextColor
                                          : Kirigami.Theme.textColor)
                                       : Kirigami.Theme.textColor
                                opacity: 0.55
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                QQC2.ToolTip.visible: tabCountHover.hovered
                                QQC2.ToolTip.delay: 400
                                QQC2.ToolTip.text: modelData.count + " rows"
                                    + (modelData.fill !== undefined && modelData.fill !== null
                                       ? ", " + Math.round(modelData.fill * 100)
                                         + "% of the cells hold a value" : "")
                                HoverHandler { id: tabCountHover }
                            }
                        }
                    }
                }
            }

            // data freshness, at the bottom of the tabs card
            QQC2.Label {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                opacity: 0.45
                elide: Text.ElideRight
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                visible: page.s && page.s.collected_at
                text: "updated " + Fmt.localHM(page.s ? page.s.collected_at : "")
            }
            }

            MouseArea {   // the resize handle of the tab panel
                width: 8
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                cursorShape: Qt.SplitHCursor
                preventStealing: true
                property real sx
                property real sw
                onPressed: m => { sx = m.x; sw = tabsPanel.panelW }
                onPositionChanged: m => {
                    if (pressed)
                        tabsPanel.panelW = Math.max(Kirigami.Units.gridUnit * 7,
                            Math.min(Kirigami.Units.gridUnit * 25, sw + (m.x - sx)))
                }
            }
        }

        FloatCard {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Kirigami.Units.smallSpacing
                spacing: 0

            // THE SINGLE QUERY BAR - the same component as in "Events"
            QueryBar {
                id: qbar
                objectName: "queryBar"
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                // the fields offered in the pickers = THIS table's columns. For
                // EVENTS it is the WHOLE taxonomy (not just the columns shown by
                // default) - any field can be added to SELECT / a condition.
                // built from the STABLE column list, not straight off the
                // snapshot: bound to listCols this rebuilt ~100 field objects on
                // every push (and with them the bar's derived name lists), for
                // pickers that are almost always closed.
                fields: page.qbarFields
                defaultSelect: page.baseCols
                placeholder: "type SQL, or plain text to search this table"
                onApplied: function (spec, sql) {
                    page.applySelectCols(spec.select)
                    var g = spec.groupBy.slice()
                    if (g.join(",") !== page.groupBy.join(",")) {
                        page.groupBy = g
                        page.groupVal = ""; page.groupParts = []
                        page.groupPicked = false
                    }
                    page.applyQuery(sql)
                    // remember a hand-typed SQL so it appears in the "…" history
                    if (!qbar.builderMode && qbar.manualText.trim() !== "")
                        backend.rememberSql(qbar.manualText)
                }
                onSaveToExpertise: function (sql) {
                    saveQueryDialog.sql = sql
                    saveQueryTitle.text = ""
                    saveQueryDesc.text = ""
                    saveQueryError.text = ""
                    saveQueryDialog.open()
                }
                onHistoryRequested: {
                    page.pickMode = "history"
                    page.pickItems = backend.sqlHistory()
                    pickQueryDialog.open()
                }
                onUseExpertiseRequested: {
                    page.pickMode = "saved"
                    page.pickItems = backend.savedQueries()
                    pickQueryDialog.open()
                }
            }

            // (Select page / Select all / Clear and the "Selected: N rows" count
            // moved out of here into the bottom bar, next to the page controls -
            // the space goes to the table)

            // ---- groups on the left + the table on the right (as in "Events") ----
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.topMargin: 10         // gap between the search and the table
                spacing: 0

            // ---- THE GROUP PANEL: the SHARED DataTable, so it has the same
            //      formatting and functionality as the main table ----
            Item {
                visible: page.groupBy.length > 0
                // wide enough for the columns as they are actually sized (so the
                // count is never cut off), but never more than half the page
                Layout.preferredWidth: {
                    var w = Kirigami.Units.smallSpacing * 2
                    for (var i = 0; i < page.groupColumns.length; i++)
                        w += page.groupColumns[i].w * Kirigami.Units.gridUnit
                             + Kirigami.Units.smallSpacing
                    return Math.min(page.width * 0.5, w + Kirigami.Units.gridUnit)
                }
                Layout.fillHeight: true
                DataTable {
                    anchors.fill: parent
                    rowHeight: page.rowHeight
                    resizable: true          // drag a column edge, as in the table
                    columns: page.groupColumns
                    rows: page.groupTableRows
                    formatter: page.groupCellDisplay
                    isSelected: page.isGroupSel
                    onRowClicked: function (row, index, mods) { page.toggleGroup(row) }
                    onColumnResized: function (key, w) { page.setGroupColWidth(key, w) }
                }
            }
            Kirigami.Separator {
                visible: page.groupBy.length > 0
                Layout.fillHeight: true
                Layout.preferredWidth: 1
            }

            // table (the shared DataTable template - principle 15/17)
            //
            // AN ITEM ON ANCHORS, NOT A LAYOUT. The table and the "Empty"
            // placeholder are both anchored to this item; turning it into a
            // ColumnLayout to add the provenance line above the table left BOTH
            // of them layout-managed, their anchors ignored, and every tab came
            // up with a zero-sized table. The line is anchored to the top and the
            // table starts below it instead.
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                // WHERE THESE ROWS COME FROM. A table used to appear with no
                // account of itself: which rule produced it, how that rule reads
                // the machine, how often it runs, when this copy was collected,
                // and whether the last run failed. All of that existed — in the
                // Pipelines page, in the source — but not where the rows are
                // read, which is where the question is asked.
                RowLayout {
                    id: provRow
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Kirigami.Units.smallSpacing
                    anchors.rightMargin: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing
                    visible: page.src !== null

                    Kirigami.Icon {
                        source: page.srcFailed ? "dialog-error" : "documentinfo"
                        implicitWidth: Kirigami.Units.iconSizes.small
                        implicitHeight: Kirigami.Units.iconSizes.small
                    }
                    QQC2.Label {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        opacity: page.srcFailed ? 1 : 0.65
                        color: page.srcFailed ? Kirigami.Theme.negativeTextColor
                                              : Kirigami.Theme.textColor
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        text: page.provenance
                    }
                    QQC2.ToolButton {
                        visible: page.src !== null && String(page.src.ref) !== ""
                        text: "The rule"
                        icon.name: "document-properties"
                        display: QQC2.AbstractButton.TextBesideIcon
                        onClicked: root.openExpertise(page.src.ref)
                        QQC2.ToolTip.visible: hovered
                        QQC2.ToolTip.text: "Open the rule that produced this table"
                    }
                }

                DataTable {
                    id: dtable
                    anchors.top: provRow.visible ? provRow.bottom : parent.top
                    anchors.topMargin: provRow.visible ? 2 : 0
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    rowHeight: page.rowHeight
                    resizable: true
                    externalSort: true          // Data owns the 3-click sort
                    columns: page.dtColumns
                    rows: page.pagedRows
                    formatter: page.cellDisplay
                    accent: page.rowAccent
                    isSelected: page.isSel
                    isChecked: page.isSel
                    iconFor: page.eventIcon
                    iconTip: page.eventIconTip
                    headerCheckState: page.headerCheckState
                    sortCol: page.sortCol
                    sortDesc: !page.sortAsc
                    onSortRequested: function (field, desc) { page.toggleSort(field) }
                    onConditionRequested: function (field, op, value) {
                        qbar.addCondition(field, op, value)
                    }
                    onRowClicked: function (row, index, mods) {
                        page.clickRow(row, index, mods)
                    }
                    onCheckToggled: function (row, index) {
                        page.clickRow(row, index, Qt.ControlModifier)
                    }
                    onHeaderCheckClicked: page.togglePageSelect()
                    onColumnResized: function (key, w) {
                        page.setColWidth(key, w); persistTimer.restart()
                    }
                    onRowRightClicked: function (row, index) {
                        page.clickRow(row, index, 0)
                        page.menuRow = row
                        rowMenu.popup()
                    }
                }
                // AN EMPTY TABLE AND A FAILED QUERY LOOK NOTHING ALIKE. The error
                // used to be stored and never shown, so a query the database
                // refused read as "there is nothing here" — the worst possible
                // answer for an analyst.
                Kirigami.PlaceholderMessage {
                    anchors.centerIn: parent
                    width: parent.width - Kirigami.Units.gridUnit * 4
                    visible: page.pagedRows.length === 0
                    icon.name: page.rowsError !== "" ? "dialog-error" : ""
                    text: page.rowsError !== "" ? "The query failed" : "Empty"
                    explanation: page.rowsError
                }
            }
            }

            // ---- the table's OWN footer: selection + pagination ----
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                QQC2.Label {
                    visible: page.selCount > 0
                    opacity: 0.6
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    text: page.allSelected ? "all " + page.curTotal + " selected"
                                           : page.selRows.length + " selected"
                }
                Item { Layout.fillWidth: true }
                QQC2.ToolButton {
                    icon.name: "go-previous"
                    flat: true
                    enabled: page.pageIndex > 0
                    onClicked: page.pageIndex--
                }
                // the page range; a click reveals rows-per-page + go-to-page
                QQC2.ToolButton {
                    flat: true
                    text: page.curTotal === 0 ? "0"
                          : (page.pageIndex * page.pageLimit + 1) + "–"
                            + Math.min((page.pageIndex + 1) * page.pageLimit, page.curTotal)
                            + " of " + page.curTotal
                    onClicked: pagePopup.open()
                    QQC2.Popup {
                        id: pagePopup
                        y: -height - Kirigami.Units.smallSpacing
                        x: parent.width - width                 // open at the bottom-right
                        padding: Kirigami.Units.largeSpacing + 2   // +2px all sides
                        ColumnLayout {
                            spacing: Kirigami.Units.smallSpacing
                            QQC2.Label {
                                Layout.alignment: Qt.AlignHCenter
                                text: "Rows per page"
                                opacity: 0.6
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                            Flow {
                                Layout.alignment: Qt.AlignHCenter
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 7
                                spacing: 2
                                Repeater {
                                    model: [50, 100, 200, 500, 1000, 0]
                                    QQC2.Button {
                                        flat: true
                                        checkable: true
                                        implicitHeight: Kirigami.Units.gridUnit * 1.5
                                        text: modelData === 0 ? "all" : "" + modelData
                                        checked: modelData === 0 ? page.pageLimit >= 100000
                                                                 : page.pageLimit === modelData
                                        onClicked: {
                                            page.pageLimit = modelData > 0 ? modelData : 100000
                                            page.pageIndex = 0
                                        }
                                    }
                                }
                            }
                            QQC2.Label {
                                Layout.alignment: Qt.AlignHCenter
                                text: "Go to page"
                                opacity: 0.6
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                            RowLayout {
                                Layout.alignment: Qt.AlignHCenter
                                spacing: Kirigami.Units.smallSpacing
                                QQC2.SpinBox {
                                    implicitHeight: Kirigami.Units.gridUnit * 1.6
                                    // narrow: content width (page digits + steppers)
                                    Layout.preferredWidth: Kirigami.Units.gridUnit * 5
                                    from: 1
                                    to: Math.max(1, page.pageCount)
                                    value: page.pageIndex + 1
                                    onValueModified: page.pageIndex = value - 1
                                }
                                QQC2.Label {
                                    opacity: 0.6
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    text: "of " + Math.max(1, page.pageCount)
                                }
                            }
                        }
                    }
                }
                QQC2.ToolButton {
                    icon.name: "go-next"
                    flat: true
                    enabled: page.pageIndex < page.pageCount - 1
                    onClicked: page.pageIndex++
                }
            }
        }
        }



        // -------- details sidebar (full height) --------
        SidePanel {
            id: detailsPanel
            title: "Details"
            iconName: "documentinfo"
            panelWidth: Kirigami.Units.gridUnit * 22
            onCloseRequested: open = false
            // the field search lives in the panel header now, aligned with the
            // other search bars (its collapse button is right beside it)
            searchPlaceholder: "find a field…"
            onSearchTextChanged: page.detailFilter = searchText

            // built only while open (see the Columns panel for why)
            Loader {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.topMargin: 10         // gap between the search and the fields
                active: detailsPanel.open
                sourceComponent: QQC2.ScrollView {
                ColumnLayout {
                    width: detailsPanel.panelWidth - Kirigami.Units.largeSpacing * 2
                    spacing: Kirigami.Units.smallSpacing
                    // A DETECTION (alert): jump to the events that triggered it.
                    QQC2.Button {
                        Layout.fillWidth: true
                        icon.name: "view-list-details"
                        text: "Show the events that triggered this"
                        visible: page.lastSel
                                 && String(page.lastSel.event_kind || "") === "alert"
                                 && String(page.lastSel.related_events || "") !== ""
                        onClicked: {
                            var ids = String(page.lastSel.related_events || "").trim()
                                        .split(/\s+/).filter(function (x) { return x !== "" })
                            if (ids.length) {
                                var inl = ids.map(function (id) {
                                    return "'" + id.replace(/'/g, "''") + "'" }).join(",")
                                root.focusEvents("event_id IN (" + inl + ")")
                            }
                        }
                    }
                    // FIELDS BY CATEGORY (events): each taxonomy group is a titled
                    // section, so an analyst orients faster than in one long list.
                    // Other tables have no taxonomy, so they show one plain section.
                    Repeater {
                        model: page.detailSections
                        delegate: ColumnLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: 1
                            // only the non-empty fields of this group
                            readonly property var nonEmpty: (modelData.fields || [])
                                .filter(function (f) {
                                    if (!page.lastSel
                                        || String(page.lastSel[f] ?? "") === "")
                                        return false
                                    if (page.detailFilter === "") return true
                                    // match the field NAME or its VALUE
                                    var flt = page.detailFilter.toLowerCase()
                                    return f.toLowerCase().indexOf(flt) >= 0
                                        || String(page.lastSel[f] ?? "")
                                               .toLowerCase().indexOf(flt) >= 0
                                })
                            visible: nonEmpty.length > 0
                            // the category header (events only - the plain section
                            // for a state table has an empty group name)
                            QQC2.Label {
                                visible: String(modelData.group || "") !== ""
                                text: modelData.group
                                font.bold: true
                                opacity: 0.7
                                Layout.topMargin: Kirigami.Units.smallSpacing
                                Layout.fillWidth: true
                            }
                            Repeater {
                                model: parent.nonEmpty
                                delegate: DetailField {
                                    label: modelData
                                    value: page.lastSel ? (page.lastSel[modelData] ?? "") : ""
                                    mono: page.longCols.includes(modelData)
                                    sensitive: page.sensitiveCols.includes(modelData)
                                }
                            }
                        }
                    }
                }
                }
            }
        }


        // -------- columns sidebar (full height) --------
        SidePanel {
            id: colPanel
            title: "Columns"
            iconName: "view-table-of-contents-ltr"
            panelWidth: Kirigami.Units.gridUnit * 14
            onCloseRequested: open = false

            // BUILT ONLY WHILE OPEN. A closed panel is still a live object tree in
            // QML (`visible` only skips painting), so this list used to build five
            // Controls per column — a hundred of them for `processes` — and rebuild
            // them on every tab switch, for a panel nobody was looking at.
            Loader {
                Layout.fillWidth: true
                Layout.fillHeight: true
                active: colPanel.open
                sourceComponent: QQC2.ScrollView {
                    ColumnLayout {
                        width: colPanel.panelWidth - Kirigami.Units.largeSpacing * 2
                        spacing: 0
                        Repeater {
                            model: page.colOrder
                            delegate: RowLayout {
                                required property var modelData
                                required property int index
                                Layout.fillWidth: true
                                spacing: 0
                                QQC2.CheckBox {
                                    checked: !page.hiddenCols.includes(modelData)
                                    onToggled: page.toggleCol(modelData)
                                }
                                QQC2.Label {
                                    text: modelData
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    opacity: page.hiddenCols.includes(modelData) ? 0.5 : 1
                                }
                                QQC2.ToolButton {
                                    icon.name: "go-up"
                                    enabled: index > 0
                                    onClicked: page.moveCol(modelData, -1)
                                }
                                QQC2.ToolButton {
                                    icon.name: "go-down"
                                    enabled: index < page.colOrder.length - 1
                                    onClicked: page.moveCol(modelData, 1)
                                }
                            }
                        }
                    }
                }
            }
        }

        // -------- the picked saved query (right sidebar) --------
        SidePanel {
            id: querySidebar
            title: "Query"
            iconName: "code-context"
            panelWidth: Kirigami.Units.gridUnit * 22
            onCloseRequested: open = false
            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                ColumnLayout {
                    width: querySidebar.panelWidth - Kirigami.Units.largeSpacing * 2
                    spacing: Kirigami.Units.smallSpacing
                    Kirigami.Heading {
                        level: 3
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: page.selectedQuery ? page.selectedQuery.title : ""
                    }
                    QQC2.Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        opacity: 0.7
                        visible: !!(page.selectedQuery && page.selectedQuery.description)
                        text: page.selectedQuery ? page.selectedQuery.description : ""
                    }
                    Kirigami.Separator { Layout.fillWidth: true }
                    QQC2.Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WrapAnywhere
                        font.family: "monospace"
                        text: page.selectedQuery ? page.selectedQuery.sql : ""
                    }
                    QQC2.Button {
                        Layout.fillWidth: true
                        icon.name: "media-playback-start"
                        text: "Run this query"
                        onClicked: if (page.selectedQuery) qbar.setSql(page.selectedQuery.sql)
                    }
                }
            }
        }
    }

    // -------- save the current SQL to expertise --------
    Kirigami.Dialog {
        id: saveQueryDialog
        property string sql: ""
        title: "Save query to expertise"
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        padding: Kirigami.Units.largeSpacing
        preferredWidth: Kirigami.Units.gridUnit * 24
        onAccepted: {
            var err = backend.saveQuery(saveQueryTitle.text, saveQueryDialog.sql,
                                        saveQueryDesc.text)
            if (err) { saveQueryError.text = err; open() }
        }
        ColumnLayout {
            spacing: Kirigami.Units.smallSpacing
            QQC2.Label { text: "Title"; opacity: 0.7 }
            QQC2.TextField {
                id: saveQueryTitle
                Layout.fillWidth: true
                placeholderText: "a name for this query"
            }
            QQC2.Label { text: "Description"; opacity: 0.7 }
            QQC2.TextField {
                id: saveQueryDesc
                Layout.fillWidth: true
                placeholderText: "what it finds (optional)"
            }
            QQC2.Label { text: "SQL"; opacity: 0.7 }
            QQC2.Label {
                Layout.fillWidth: true
                wrapMode: Text.WrapAnywhere
                font.family: "monospace"
                opacity: 0.8
                text: saveQueryDialog.sql
            }
            QQC2.Label {
                id: saveQueryError
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: Kirigami.Theme.negativeTextColor
                visible: text !== ""
            }
        }
    }

    // -------- pick a query: SQL history or saved queries --------
    Kirigami.Dialog {
        id: pickQueryDialog
        title: page.pickMode === "history" ? "SQL history" : "Saved queries"
        standardButtons: Kirigami.Dialog.Cancel
        preferredWidth: Kirigami.Units.gridUnit * 30
        preferredHeight: Kirigami.Units.gridUnit * 22
        ListView {
            clip: true
            model: page.pickItems
            delegate: QQC2.ItemDelegate {
                width: ListView.view.width
                contentItem: ColumnLayout {
                    spacing: 0
                    QQC2.Label {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        font.bold: page.pickMode === "saved"
                        text: page.pickMode === "history" ? modelData
                                                          : (modelData.title || "")
                    }
                    QQC2.Label {
                        Layout.fillWidth: true
                        visible: page.pickMode === "saved"
                        elide: Text.ElideRight
                        opacity: 0.6
                        font.family: "monospace"
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        text: page.pickMode === "saved" ? (modelData.sql || "") : ""
                    }
                }
                onClicked: {
                    if (page.pickMode === "history") {
                        qbar.setSql(modelData)
                    } else {
                        qbar.setSql(modelData.sql)
                        page.selectedQuery = modelData
                        querySidebar.open = true
                    }
                    pickQueryDialog.close()
                }
            }
            QQC2.Label {
                anchors.centerIn: parent
                visible: page.pickItems.length === 0
                opacity: 0.6
                text: page.pickMode === "history" ? "No history yet"
                                                  : "No saved queries yet"
            }
        }
    }

}

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components/Fmt.js" as Fmt
import "../components/Sev.js" as Sev
import "../components"
import "../views"
import "."

// System state: read-only tables view. Table/field/record management
// lives in the SQL tab. Right sidebars (details, columns) are full height.
Kirigami.Page {
    // no page title: the section is "Data" in the drawer; a header just wastes space
    id: page
    title: ""
    padding: 0

    property var s: root.sysState
    // Vulnerabilities live in a separate tab of the "Dashboards" section: that is
    // not an inventory of the system but a list of tasks, "what to patch".
    // EVENTS is just another Data tab now (no separate menu). It lives in
    // events.db, so the backend routes tableRows("events", ...) there; here it is
    // a synthetic tab with a curated column set (the full field set is in the
    // Details sidebar and via SQL). colcfg is an empty object so all its columns
    // show by default.
    property int eventsTotal: 0        // all events in events.db (for the tab count)
    function refreshEventsTotal() {
        var r = backend.tableRows("events", "", "", 1, 0)
        page.eventsTotal = r.total || 0
    }
    readonly property var eventsTab: ({
        name: "events", title: "Events", icon: "view-list-details",
        builtin: true, count: page.eventsTotal, collected_at: "",
        // hidden-by-default (still available in the Columns picker)
        colcfg: ({ hidden: ["user_name", "event_module", "process_pid",
                            "subject_name"] }),
        columns: ["ts", "event_module", "event_category", "event_action",
                  "event_outcome", "subject_name", "process_name", "process_pid",
                  "user_name", "destination_ip", "object_type", "object_name",
                  "message"]
    })
    // THE EVENT TAXONOMY: all 107 field names + the fields grouped by category.
    // Loaded once (the taxonomy is static). Used for the events tab: every field
    // is offered in the query bar SELECT, and the Details sidebar groups by category.
    readonly property var eventTax: backend.eventTaxonomy()
    readonly property bool onEvents: cur && cur.name === "events"
    // the fields the Details sidebar shows, in SECTIONS: for events, grouped by
    // taxonomy category; for any other table, one unnamed section of its columns
    property var detailSections: {
        if (!lastSel || !cur) return []
        if (onEvents && eventTax.groups && eventTax.groups.length)
            return eventTax.groups
        return [{ group: "", fields: cur.columns }]
    }
    // priority of the state tables (Events is always first, then Processes, then
    // the rest by how central they are to an investigation).
    readonly property var tabPrio: ({
        processes: 1, ports: 2, applications: 3, services: 4, scheduled: 5,
        persistence: 6, open_files: 7, app_config: 8, config_files: 9,
        privesc: 10, suid_binaries: 11, users: 12, network: 13, dns: 14,
        unix_sockets: 15, net_config: 16, browser_extensions: 17,
        browser_history: 18, shell_history: 19, logins: 20, kernel_modules: 21,
        mounts: 22, security: 23, firewall: 24, unpackaged_config: 25
    })
    property var tabsModel: {
        var t = (s ? s.tabs : []).filter(function (x) {
            return x.name !== "vulnerabilities"
        })
        var arr = t.slice()
        arr.sort(function (a, b) {
            var pa = page.tabPrio[a.name] || 99, pb = page.tabPrio[b.name] || 99
            return pa !== pb ? pa - pb
                             : String(a.title || a.name).localeCompare(String(b.title || b.name))
        })
        return [page.eventsTab].concat(arr)
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
    // JOIN state: when joinTable is set, the current table is LEFT JOINed with it
    // on joinLeft = joinRight and the joined columns appear (prefixed) after it.
    property string joinTable: ""
    property string joinLeft: ""
    property string joinRight: ""
    property var joinCols: []         // columns the join query returned (base + join.*)
    function loadRows() {
        if (!cur) { curRows = []; curTotal = 0; rowsError = ""; return }
        var where = page.whereSql()
        var order = sortCol !== "" ? (sortCol + (sortAsc ? " ASC" : " DESC")) : ""
        var lim = pageLimit > 0 ? pageLimit : 0
        var off = pageLimit > 0 ? pageIndex * pageLimit : 0
        var r
        if (page.joinTable !== "" && page.joinLeft !== "" && page.joinRight !== "") {
            r = backend.tableJoinRows(cur.name, page.joinTable, page.joinLeft,
                                      page.joinRight, where, order, lim, off)
            page.joinCols = r.columns || []
        } else {
            r = backend.tableRows(cur.name, where, order, lim, off)
            page.joinCols = []
        }
        curRows = r.rows || []
        curTotal = r.total || 0
        rowsError = r.error || ""
    }
    property var joinTablesList: []   // tables that can be joined to the current one
    function fetchJoinTables() {
        // works for events too: it joins state tables (cross-database)
        joinTablesList = cur ? (backend.joinTables(cur.name) || []) : []
    }
    function setJoinTable(t) {
        joinTable = String(t || "")
        if (joinTable === "") { joinLeft = ""; joinRight = "" }
        else {
            var s = backend.joinSuggest(cur.name, joinTable)   // suggest the ON pair
            joinLeft = s.left || ""; joinRight = s.right || ""
        }
        pageIndex = 0
        loadRows()
    }
    function joinTableColumns() {
        for (var i = 0; i < joinTablesList.length; i++)
            if (joinTablesList[i].name === joinTable)
                return joinTablesList[i].columns || []
        return []
    }
    // filtering the list of tables by name
    property string tabFilter: ""
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

    // the columns to render: the join result's columns when a join is active,
    // otherwise the current table's own columns
    property var listCols: (joinTable !== "" && joinCols.length)
                           ? joinCols : (cur ? cur.columns : [])
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
    // Events are append-only (events.db), not an editable state table: the row
    // editor and cell writes are disabled for that tab (setCell would target a
    // non-existent state table). Details/filtering/sorting still work.
    readonly property bool curEditable: !(cur && cur.name === "events")
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
    property var visibleCols: {
        var mine = selectCols.filter(c => listCols.includes(c))
        return mine.length ? mine : colOrder.filter(c => !hiddenCols.includes(c))
    }

    property var savedWidths: cur && cur.colcfg && cur.colcfg.widths
                              ? cur.colcfg.widths : ({})
    property var liveWidths: ({})
    // The view (selection/sorting/filters/page) is reset ONLY when the tab
    // changes (curName), not on every automatic data refresh - otherwise the user
    // loses the selected row and the position on every tick.
    property string curName: cur ? cur.name : ""
    onCurNameChanged: {
        // A DIFFERENT TABLE HAS DIFFERENT FIELDS: both the selection and the
        // condition of the previous table are meaningless here - reset them with the view.
        page.loadRows()
        page.queryText = ""; page.queryError = ""; page.selectCols = []
        if (typeof qbar !== "undefined") qbar.clearAll()
        liveWidths = ({}); selRows = []; selAnchor = -1; pageIndex = 0
        sortCol = ""; sortAsc = true; lastSel = null; selName = ""
        allSelected = false
        joinTable = ""; joinLeft = ""; joinRight = ""; joinCols = []
        fetchJoinTables()
    }
    // The same tab, fresh data: we re-point the selection and the details row at
    // the NEW row objects by _id (so that they show the current values).
    onCurChanged: {
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
        page.loadRows(); page.refreshEventsTotal(); page.fetchJoinTables(); applyFocus()
    }

    // FRESH DATA WITHOUT THRASHING. The snapshot arrives while the pipeline
    // collects (once a second at most), and re-reading the table on every one of
    // them would keep the list rebuilding under the cursor. We coalesce them: one
    // read shortly after the last snapshot, and only for the table on screen.
    onSChanged: rowsTimer.restart()
    Timer {
        id: rowsTimer
        interval: 400
        onTriggered: { page.loadRows(); page.refreshEventsTotal() }
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

    // whether an on-demand collection is running
    property bool collecting: false
    Connections {
        target: backend
        function onCollectingChanged() { page.collecting = backend.isCollecting() }
    }

    function setQuick(t) { qbar.quickText = t; qbar.apply() }
    // for verification by rendering
    function setGroupBy(fs) {
        qbar.addClause("group"); qbar.spec.groupBy = fs; qbar.touch(); qbar.apply()
    }
    function pickGroup(row) {
        page.groupPicked = true
        page.groupVal = String(row.value || "")
        page.groupParts = row.parts || []
        page.applyQuery(page.queryText)
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
    }
    onPageIndexChanged: page.loadRows()
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
    function accentOf(r) { return String(page.rowAccent(r)) }
    // CELL TEXT: an ISO-8601 timestamp is shown as readable LOCAL time (not the
    // raw "…T12:03:57Z"); everything else as-is. Applies to every table, so any
    // time column reads nicely.
    function cellDisplay(r, k) {
        var v = r[k]
        if (v === undefined || v === null) return ""
        var s = String(v)
        if (/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}/.test(s)) return Fmt.local(s)
        return s
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
    function reloadGroups() {
        if (!cur || !groupBy.length) { groupRows = []; return }
        var r = backend.stateGroups(cur.name, groupBy.join(","), page.baseWhere())
        groupRows = r.rows || []
    }
    // the condition without the group - the groups themselves are counted by it
    // (time filtering is done by adding a `ts` condition in the query bar - the
    // QueryBar already understands ts and "last N days")
    function baseWhere() {
        if (queryText === "") return ""
        return hasOperator(queryText) ? queryText : freeText(queryText)
    }
    // the condition of the selected group: AND over all its fields
    function groupCond() {
        if (!groupBy.length || !groupPicked) return ""
        var parts = []
        for (var i = 0; i < groupBy.length; i++) {
            var f = groupBy[i]
            var v = i < groupParts.length ? String(groupParts[i]) : ""
            if (v === "")
                parts.push('("' + f + '" IS NULL OR "' + f + '" = \'\')')
            else
                parts.push('"' + f + '" = \'' + v.replace(/'/g, "''") + '\'')
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
    // The rows arrive already selected, sorted and paged by the database, so
    // there is nothing left to do here. Filtering in JS meant carrying every row
    // of the table across the QML boundary, and that cost grew with the size of
    // the table: 1.5 s per switch to applications, 0.5 s to package_files.
    property var filteredRows: curRows
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
    function isSel(r) {
        if (allSelected) return true
        return r._id !== undefined && selRows.some(x => x._id === r._id)
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
    // the tristate "select the whole page" header checkbox, and its toggle
    property int headerCheckState: allSelected ? Qt.Checked
        : selRows.length === 0 ? Qt.Unchecked
        : (pagedRows.length && pagedRows.every(r => isSel(r)))
          ? Qt.Checked : Qt.PartiallyChecked
    function togglePageSelect() {
        if (allSelected || pagedRows.every(r => isSel(r))) {
            allSelected = false; selRows = []
        } else {
            selRows = pagedRows.slice()
        }
    }
    // THE COLUMN DESCRIPTORS for the shared DataTable: a checkbox column, an
    // event-type icon column (Events tab only), then the visible data columns
    // with their widths (colWidth is in pixels, the template wants gridUnits).
    property var dtColumns: {
        var out = [{ k: "_check", kind: "check", w: 2 }]
        if (cur && cur.name === "events")
            out.push({ k: "_icon", kind: "icon", w: 1.6 })
        var cols = visibleCols
        for (var i = 0; i < cols.length; i++)
            out.push({ k: cols[i], t: cols[i],
                       w: colWidth(cols[i]) / Kirigami.Units.gridUnit })
        return out
    }
    // resizing fires continuously while dragging; persist once it settles
    Timer { id: persistTimer; interval: 400; onTriggered: page.persistWidths() }


    // -------- bottom toolbar --------
    footer: QQC2.ToolBar {
        RowLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing
            QQC2.ToolButton {
                icon.name: "view-refresh"
                text: "Refresh"
                display: QQC2.AbstractButton.IconOnly
                QQC2.ToolTip.text: "Re-read the collected data"
                QQC2.ToolTip.visible: hovered
                onClicked: backend.refresh()
            }
            // COLLECT NOW: the sources have their own intervals (six hours for
            // vulnerabilities), and after changing the system there is no point waiting.
            QQC2.ToolButton {
                icon.name: "download"
                text: page.collecting ? "Collecting…" : "Collect now"
                display: QQC2.AbstractButton.TextBesideIcon
                enabled: !page.collecting
                QQC2.ToolTip.text: "Run every state source right now"
                QQC2.ToolTip.visible: hovered
                onClicked: { page.collecting = true; backend.collectNow() }
            }
            QQC2.BusyIndicator {
                running: page.collecting
                visible: page.collecting
                Layout.preferredHeight: Kirigami.Units.gridUnit * 1.4
                Layout.preferredWidth: Kirigami.Units.gridUnit * 1.4
            }
            // when this table was filled last
            QQC2.Label {
                visible: page.cur && page.cur.collected_at
                text: "collected " + Fmt.local(page.cur ? page.cur.collected_at : "")
                opacity: 0.6
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
            QQC2.Label {
                Layout.leftMargin: Kirigami.Units.smallSpacing
                opacity: 0.6
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                text: page.s ? "Updated: " + page.s.collected_at : "Collecting…"
            }
            Item { Layout.fillWidth: true }
            // HOW MANY ROWS ARE SELECTED — shown at the bottom, next to the page
            // controls, so the count sits with the pagination it belongs to.
            QQC2.Label {
                visible: page.selCount > 0
                opacity: 0.7
                text: page.allSelected
                      ? "Selected: all " + page.curTotal + " rows"
                      : "Selected: " + page.selRows.length +
                        (page.selRows.length === 1 ? " row" : " rows")
            }
            // SELECT ALL — every matching record across ALL pages. Toggles with
            // Clear.
            QQC2.ToolButton {
                visible: page.curTotal > 0
                readonly property bool anySel: page.allSelected || page.selRows.length > 0
                icon.name: anySel ? "edit-clear" : "edit-select-all-layers"
                text: anySel ? "Clear" : "Select all (" + page.curTotal + ")"
                onClicked: {
                    page.selRows = []
                    page.allSelected = !anySel
                }
            }
            QQC2.Label {
                opacity: 0.7
                // "1–50 of <matching>"; on Events, when a filter narrows the set,
                // also show the grand total so the effect is obvious.
                text: page.curTotal === 0 ? "0 rows"
                      : (page.pageIndex * page.pageLimit + 1) + "–" +
                        Math.min((page.pageIndex + 1) * page.pageLimit, page.curTotal) +
                        " of " + page.curTotal +
                        (page.cur && page.cur.name === "events"
                         && page.curTotal < page.eventsTotal
                         ? " · " + page.eventsTotal + " total" : "")
            }
            QQC2.ToolButton {
                icon.name: "go-previous"
                enabled: page.pageIndex > 0
                onClicked: page.pageIndex--
            }
            QQC2.ToolButton {
                icon.name: "go-next"
                enabled: page.pageIndex < page.pageCount - 1
                onClicked: page.pageIndex++
            }
            QQC2.ComboBox {
                // how many rows to show; "all" = no limit
                model: [{ t: "50", v: 50 }, { t: "100", v: 100 }, { t: "200", v: 200 },
                        { t: "500", v: 500 }, { t: "1000", v: 1000 },
                        { t: "all", v: 0 }]
                textRole: "t"
                valueRole: "v"
                implicitWidth: Kirigami.Units.gridUnit * 6
                onActivated: { page.pageLimit = currentValue > 0 ? currentValue : 100000; page.pageIndex = 0 }
            }
            // THE COLUMN CHOICE WAS REMOVED: the columns are set by SELECT in the query bar
        }
    }

    // -------- page body: main column + full-height right sidebars --------
    RowLayout {
        anchors.fill: parent
        spacing: 0

        // -------- the vertical state tabs (resized by the right edge) --------
        Item {
            id: tabsPanel
            property real panelW: Kirigami.Units.gridUnit * 12
            Layout.preferredWidth: panelW
            Layout.fillHeight: true

            ColumnLayout {
                anchors.fill: parent
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
                            QQC2.Label {   // the counter is always visible on the right
                                text: modelData.count
                                opacity: 0.55
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                        }
                    }
                }
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

        Kirigami.Separator { Layout.fillHeight: true }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // THE SINGLE QUERY BAR - the same component as in "Events"
            QueryBar {
                id: qbar
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                // the fields offered in the pickers = THIS table's columns (and the
                // joined table's columns once a JOIN is made). For EVENTS it is the
                // WHOLE taxonomy (107 fields), not just the 13 shown by default -
                // any field can be added to SELECT / a condition.
                fields: (page.onEvents && page.joinTable === ""
                         && page.eventTax.names && page.eventTax.names.length
                         ? page.eventTax.names
                         : page.listCols.filter(c => !c.startsWith("_")))
                                     .map(function (c) { return { name: c } })
                defaultSelect: page.visibleCols
                placeholder: "type SQL, or plain text to search this table"
                // JOIN button lives in the bar; the page owns the state + backend.
                // Events joins a state table across databases (ATTACH).
                joinTables: page.joinTablesList
                joinTable: page.joinTable
                joinLeft: page.joinLeft
                joinRight: page.joinRight
                onJoinTableChosen: function (t) { page.setJoinTable(t) }
                onJoinFieldsChosen: function (l, r) {
                    page.joinLeft = l; page.joinRight = r
                    page.pageIndex = 0; page.loadRows()
                }
                onApplied: function (spec, sql) {
                    page.applySelectCols(spec.select)
                    var g = spec.groupBy.slice()
                    if (g.join(",") !== page.groupBy.join(",")) {
                        page.groupBy = g
                        page.groupVal = ""; page.groupParts = []
                        page.groupPicked = false
                    }
                    page.applyQuery(sql)
                }
            }

            // (JOIN now lives as a button IN the query bar toolbar above, next to
            // Group by / Sort - see the QueryBar join* bindings)

            // (Select page / Select all / Clear and the "Selected: N rows" count
            // moved out of here into the bottom bar, next to the page controls -
            // the space goes to the table)

            // ---- groups on the left + the table on the right (as in "Events") ----
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

            // ---- THE GROUP PANEL ----
            Item {
                visible: page.groupBy.length > 0
                Layout.preferredWidth: Math.min(page.width * 0.45,
                                                Kirigami.Units.gridUnit * (8 + 9 * page.groupBy.length))
                Layout.fillHeight: true
                ColumnLayout {
                    anchors.fill: parent
                    spacing: 0
                    // the header - the same as the table's
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: gProbe.implicitHeight
                                                + Kirigami.Units.smallSpacing * 2
                        color: Kirigami.Theme.alternateBackgroundColor
                        QQC2.Label { id: gProbe; visible: false; text: "Ag"; font.bold: true }
                        // value column(s) fill the width, count sits right after -
                        // no empty gap, borders between columns, like the main table
                        RowLayout {
                            anchors.fill: parent
                            spacing: 0
                            Repeater {
                                model: page.groupBy
                                delegate: Item {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    QQC2.Label {
                                        anchors.fill: parent
                                        verticalAlignment: Text.AlignVCenter
                                        leftPadding: Kirigami.Units.smallSpacing
                                        text: modelData
                                        font.bold: true
                                        elide: Text.ElideRight
                                    }
                                    Kirigami.Separator {
                                        anchors { right: parent.right; top: parent.top
                                                  bottom: parent.bottom }
                                        opacity: 0.25
                                    }
                                }
                            }
                            QQC2.Label {
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 5
                                Layout.fillHeight: true
                                horizontalAlignment: Text.AlignRight
                                verticalAlignment: Text.AlignVCenter
                                rightPadding: Kirigami.Units.largeSpacing
                                text: "count"
                                font.bold: true
                            }
                        }
                        Kirigami.Separator {
                            anchors.bottom: parent.bottom
                            width: parent.width
                            opacity: 0.35
                        }
                    }
                    QQC2.ScrollView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        ListView {
                            model: page.groupRows
                            reuseItems: true
                            delegate: QQC2.ItemDelegate {
                                id: gRow
                                required property var modelData
                                required property int index
                                width: ListView.view.width
                                height: page.rowHeight
                                padding: 0
                                highlighted: page.groupPicked
                                             && page.groupVal === String(modelData.value || "")
                                onClicked: {
                                    var v = String(modelData.value || "")
                                    if (page.groupPicked && page.groupVal === v) {
                                        page.groupPicked = false
                                        page.groupVal = ""; page.groupParts = []
                                    } else {
                                        page.groupPicked = true
                                        page.groupVal = v
                                        page.groupParts = modelData.parts || [v]
                                    }
                                    page.applyQuery(page.queryText)
                                }
                                // THE SAME COLOURS AS THE TABLE: otherwise two
                                // tables side by side look like different programs
                                background: Rectangle {
                                    // EXACTLY the table's row colours (highlight /
                                    // hover / zebra) + the same fade, so the two
                                    // tables side by side read as one program
                                    color: gRow.highlighted
                                           ? Qt.alpha(Kirigami.Theme.highlightColor, 0.20)
                                           : gRow.hovered
                                             ? Qt.alpha(Kirigami.Theme.textColor, 0.05)
                                             : gRow.index % 2 === 0
                                               ? Kirigami.Theme.backgroundColor
                                               : Kirigami.Theme.alternateBackgroundColor
                                    Behavior on color {
                                        ColorAnimation { duration: Kirigami.Units.shortDuration }
                                    }
                                    Kirigami.Separator {
                                        anchors.bottom: parent.bottom
                                        width: parent.width
                                        opacity: 0.35
                                    }
                                    Rectangle {
                                        anchors { left: parent.left; top: parent.top
                                                  bottom: parent.bottom }
                                        width: 3
                                        visible: gRow.highlighted
                                        color: Kirigami.Theme.highlightColor
                                    }
                                }
                                contentItem: RowLayout {
                                    spacing: 0
                                    Repeater {
                                        model: modelData.parts
                                               ? modelData.parts : [String(modelData.value)]
                                        delegate: Item {
                                            required property var modelData
                                            Layout.fillWidth: true
                                            Layout.fillHeight: true
                                            QQC2.Label {
                                                anchors.fill: parent
                                                verticalAlignment: Text.AlignVCenter
                                                leftPadding: Kirigami.Units.smallSpacing
                                                rightPadding: Kirigami.Units.largeSpacing
                                                text: String(modelData) === "" ? "(empty)"
                                                                              : String(modelData)
                                                opacity: String(modelData) === "" ? 0.5 : 1
                                                elide: Text.ElideRight
                                            }
                                            Kirigami.Separator {
                                                anchors { right: parent.right; top: parent.top
                                                          bottom: parent.bottom }
                                                opacity: 0.25
                                            }
                                        }
                                    }
                                    QQC2.Label {
                                        text: modelData.n
                                        opacity: 0.75
                                        horizontalAlignment: Text.AlignRight
                                        verticalAlignment: Text.AlignVCenter
                                        rightPadding: Kirigami.Units.largeSpacing
                                        Layout.preferredWidth: Kirigami.Units.gridUnit * 5
                                        Layout.fillHeight: true
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Kirigami.Separator {
                visible: page.groupBy.length > 0
                Layout.fillHeight: true
            }

            // table (the shared DataTable template - principle 15/17)
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                DataTable {
                    id: dtable
                    anchors.fill: parent
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
                Kirigami.PlaceholderMessage {
                    anchors.centerIn: parent
                    visible: page.pagedRows.length === 0
                    text: "Empty"
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

            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
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
                                    return page.lastSel
                                        && String(page.lastSel[f] ?? "") !== "" })
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


        // -------- columns sidebar (full height) --------
        SidePanel {
            id: colPanel
            title: "Columns"
            iconName: "view-table-of-contents-ltr"
            panelWidth: Kirigami.Units.gridUnit * 14
            onCloseRequested: open = false

            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                ColumnLayout {
                    width: colPanel.panelWidth - Kirigami.Units.largeSpacing * 2
                    spacing: 0
                    Repeater {
                    model: page.colOrder
                    delegate: RowLayout {
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

    // -------- row editor (double click / Edit) --------
    Kirigami.Dialog {
        id: editDialog
        title: "Record — " + (page.cur ? page.cur.title : "")
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        padding: Kirigami.Units.largeSpacing
        preferredWidth: Kirigami.Units.gridUnit * 24

        property var row: null
        function openFor(r) { row = r; open() }

        onAccepted: {
            const cols = page.cur.columns
            for (let i = 0; i < cols.length; i++) {
                const v = fieldsRep.itemAt(i).text
                if (v !== String(editDialog.row[cols[i]] ?? ""))
                    backend.setCell(page.cur.name, editDialog.row._id, cols[i], v)
            }
            backend.reload()
        }

        Kirigami.FormLayout {
            Repeater {
                id: fieldsRep
                model: editDialog.row && page.cur ? page.cur.columns : []
                QQC2.TextField {
                    Kirigami.FormData.label: modelData
                    text: editDialog.row ? String(editDialog.row[modelData] ?? "") : ""
                }
            }
        }
    }
}

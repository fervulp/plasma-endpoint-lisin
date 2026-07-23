import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "Fmt.js" as Fmt

// Events: ONE window for ALL inputs (normalization brings them to a common
// taxonomy). Filtering is expressed in SQL: hovering a cell gives + and -, they
// assemble a WHERE that is visible and editable by hand. Plus grouping (the
// values of a group on the left, the rows on the right) and SQL history with a
Kirigami.Page {
    id: page
    title: "Events"
    padding: 0

    // The "Feed / Chains" switch. The feed answers "what happened", the chains
    // answer "what story is behind it": a connected sequence from a process start
    // to an outbound connection.
    actions: [
        // THE CHAINS ARE TEMPORARILY HIDDEN. The mechanism works (87 chains, 100%
        // coverage), but it is too early to use: first we finish state and events.
        // The code, the slots and the tab stay - it is enough to set visible: true.
        Kirigami.Action {
            visible: false
            text: "Feed"
            icon.name: "view-list-details"
            checkable: true
            checked: page.mode === "feed"
            onTriggered: page.mode = "feed"
        },
        Kirigami.Action {
            visible: false
            text: "Chains"
            icon.name: "distribute-graph-directed"
            checkable: true
            checked: page.mode === "chains"
            onTriggered: {
                page.mode = "chains"
                if (!page.chains) page.chains = backend.eventChains()
            }
        },
        Kirigami.Action {
            text: "Refresh chains"
            icon.name: "view-refresh"
            visible: false
            onTriggered: {
                page.chains = backend.eventChains()
                if (page.chainId !== "")
                    page.chainSteps = backend.chainDetail(page.chainId)
            }
        }
    ]

    property var stats: ({ total: 0, by_category: [], by_module: [], by_outcome: [] })
    property var feed: ({ rows: [], total: 0, error: "" })
    property var fieldGroups: []
    property var sel: null
    property int pageIndex: 0
    property int pageLimit: 50

    // filters expressed in SQL
    property var conds: []           // [{col, op, val}] - kept for compatibility
    // THE SINGLE QUERY from the shared bar (principle 15). It may be an SQL
    // condition or just text - then we search it over the meaningful fields.
    property string queryText: ""
    // eventFields() returns taxonomy GROUPS [{group, fields:[{name,...}]}], while
    // the builder needs flat NAMES - otherwise objects end up in the ComboBox
    // («Unable to assign QVariantMap to QString»).
    property var allFields: {
        var out = []
        var g = backend.eventFields() || []
        for (var i = 0; i < g.length; i++) {
            var ff = g[i].fields || []
            for (var j = 0; j < ff.length; j++)
                if (ff[j] && ff[j].name) out.push(ff[j].name)
        }
        return out.length ? out : ["ts", "event_action", "message"]
    }
    property string whereText: ""
    // the mode of the section: the feed of separate events or CHAINS (linked stories)
    property string mode: "feed"
    property var chains: null
    property string chainId: ""
    property var chainSteps: null
    // GROUPING BY SEVERAL FIELDS: like `GROUP BY a, b` in SQL.
    // groupBy is the list of fields, groupParts holds the chosen values of each.
    property var groupBy: []
    property var groupParts: []
    property string groupVal: ""
    property bool groupPicked: false     // whether a group is picked (an empty value is a choice too)
    // The time limit is NO LONGER A SEPARATE STATE: the range is pinned as an
    // ordinary `ts >= ...` condition in the query bar (pinPeriod). A sliding
    // window produced a different set on every refresh.
    property var groupRows: []
    // all the groups as the database returned them: the size threshold was removed -
    // hiding small groups means hiding the rare, and the rare is exactly what matters
    readonly property var shownGroups: groupRows

    // ---- columns ----
    property var allCols: []
    property var colOrder: []
    property var hiddenCols: []
    property var widths: ({})
    // EXACTLY 8 columns that answer "what happened":
    // when - who - what they did - over what (type+name) - how it ended -
    // which area it belongs to - the details. The other 84 fields are available
    // through "Columns" and in the details panel - but they do not disturb reading.
    readonly property var defaultCols: ["ts", "subject_name", "event_action",
        "object_type", "object_name", "event_outcome", "event_category", "message"]
    readonly property int cfgVersion: 2      // the default set changed
    // IF WE GROUPED, these fields are removed from the table: inside a group they
    // are the same in every row and only take space (the value is visible on the
    // left, in the group itself).
    property var visibleCols: colOrder.filter(
        c => !hiddenCols.includes(c) && groupBy.indexOf(c) < 0)
    // the search in the column chooser panel
    property string colSearch: ""
    readonly property var shownColChoices: {
        if (colSearch === "") return colOrder
        var q = colSearch.toLowerCase()
        return colOrder.filter(c => c.toLowerCase().indexOf(q) >= 0)
    }
    // A snapshot of the original selection: "Reset" in the query bar returns to it.
    // Exactly a SNAPSHOT and not visibleCols - otherwise applying a selection would
    // change what to reset to as well.
    property var baseSelect: []

    // An event field -> where to "explore" in the "State" section
    readonly property var exploreMap: ({
        "process_pid":        { table: "processes",    col: "pid" },
        "parent_pid":         { table: "processes",    col: "pid" },
        "process_name":       { table: "processes",    col: "command" },
        "process_executable": { table: "processes",    col: "command" },
        "user_name":          { table: "users",        col: "name" },
        "user_id":            { table: "users",        col: "uid" },
        "destination_ip":     { table: "ports",        col: "remote" },
        "source_ip":          { table: "ports",        col: "remote" },
        "related_ip":         { table: "ports",        col: "remote" },
        "destination_port":   { table: "ports",        col: "port" },
        "service_name":       { table: "services",     col: "unit" },
        "package_name":       { table: "applications", col: "name" }
    })
    property var savedList: []
    function reloadSaved() { savedList = backend.savedQueries() }
    // the directories of saved queries (created by the user)
    property var dirsList: ["general"]
    function reloadDirs() {
        var d = backend.queryDirs()
        dirsList = (d && d.length) ? d : ["general"]
    }

    function esc(v) { return String(v).replace(/'/g, "''") }
    function condSql(c) {
        // an empty cell may be both NULL and '' - we account for both
        if (c.op === "IS NULL")
            return '("' + c.col + '" IS NULL OR "' + c.col + '" = \'\')'
        if (c.op === "IS NOT NULL")
            return '("' + c.col + '" IS NOT NULL AND "' + c.col + '" <> \'\')'
        if (c.op === "IN")
            return '"' + c.col + '" IN \'' + esc(c.val) + '\''
        if (c.op === "LIKE" || c.op === "NOT LIKE")
            return '"' + c.col + '" ' + c.op + " '%" + esc(c.val) + "%'"
        // for < > <= >= the numeric value is passed WITHOUT quotes, otherwise
        // SQLite compares as text ('9' > '40') and the threshold works incorrectly
        var num = (c.op === ">" || c.op === "<" || c.op === ">=" || c.op === "<=")
                  && c.val !== "" && !isNaN(Number(c.val))
        if (num) return '"' + c.col + '" ' + c.op + " " + c.val
        return '"' + c.col + '" ' + c.op + " '" + esc(c.val) + "'"
    }
    // the common condition builder
    function assemble(parts) { return parts.join(" AND ") }
    // The condition of the selected group. An empty cell in SQLite may be both NULL
    // and '', and GROUP BY makes them DIFFERENT groups, so `= ''` caught the wrong
    // rows (the counter showed 300 while the table stayed empty).
    function groupCond() {
        if (!groupBy.length || !groupPicked) return ""
        var parts = []
        for (var i = 0; i < groupBy.length; i++) {
            var f = groupBy[i]
            var v = i < groupParts.length ? String(groupParts[i]) : ""
            // an empty cell in SQLite may be both NULL and '' - we catch both
            if (v === "") parts.push('("' + f + '" IS NULL OR "' + f + '" = \'\')')
            else parts.push('"' + f + '" = \'' + esc(v) + '\'')
        }
        return parts.length > 1 ? "(" + parts.join(" AND ") + ")" : parts[0]
    }
    // the WHERE without the group condition - the group counters are computed by it
    // so that they match what the table will actually show.
    // The text from the shared bar: if it looks like an SQL condition we take it as
    // is, otherwise we expand it into a search over the meaningful fields. That way
    // one bar works both for "type it" and for "just find it".
    function queryPart() {
        var q = String(page.queryText || "").trim()
        if (q === "") return ""
        if (/[<>=]|LIKE|IS NULL|IS NOT NULL/i.test(q)) return "(" + q + ")"
        var lk = "'%" + esc(q) + "%'"
        return "(message LIKE " + lk + " OR process_name LIKE " + lk +
               " OR process_executable LIKE " + lk +
               " OR destination_ip LIKE " + lk +
               " OR user_name LIKE " + lk +
               " OR event_action LIKE " + lk + ")"
    }
    function whereNoGroup() {
        var parts = []
        var qp = queryPart()
        if (qp !== "") parts.push(qp)
        return assemble(parts)
    }
    function buildWhere() {
        var parts = []
        var qp = queryPart()
        if (qp !== "") parts.push(qp)
        var gc = groupCond()
        if (gc !== "") parts.push(gc)
        return assemble(parts)
    }
    // The "+"/"-" buttons on a cell append a condition to the SHARED query bar and
    // not to a list of their own - there must be a single source of the query.
    function addCond(col, op, val) { qbar.addCondition(col, op, String(val)) }
    function dropCond(i) {
        var c = conds.slice(); c.splice(i, 1); conds = c; syncWhere()
    }
    function syncWhere() { whereText = buildWhere(); pageIndex = 0; reload() }

    // COPYING TO THE CLIPBOARD. QML has no direct access to the clipboard, so we
    // use a hidden TextEdit: put the text in, select it, copy().
    property string copied: ""
    function copyValue(v) {
        if (v === undefined || v === null || v === "") return
        clipHelper.text = String(v)
        clipHelper.selectAll()
        clipHelper.copy()
        page.copied = String(v)
        copiedTimer.restart()
    }
    TextEdit { id: clipHelper; visible: false }
    Timer { id: copiedTimer; interval: 1600; onTriggered: page.copied = "" }

    // ---- FIELD STATISTICS: what is filled at all and with what ----
    // THE NAME DIFFERS from `stats`: that one holds the feed facets, this one the
    property var fieldStats: null
    property string statsFilter: ""
    // the list of values as a column; a long one expands in the panel
    // THE WIDTH OF A GROUP PANEL COLUMN FOLLOWS ITS LONGEST VALUE (and the field
    // name in the header), with a ceiling: what does not fit is elided.
    // It is computed in one place, the header and the rows read it from here,
    // otherwise the columns drift apart.
    readonly property int grpCountWidth: Kirigami.Units.gridUnit * 5
    readonly property int grpColMin: Kirigami.Units.gridUnit * 5
    readonly property int grpColMax: Kirigami.Units.gridUnit * 20
    FontMetrics { id: grpFm }
    readonly property var grpColWidths: {
        var out = []
        for (var i = 0; i < groupBy.length; i++) {
            var longest = String(groupBy[i])
            for (var j = 0; j < groupRows.length; j++) {
                var parts = groupRows[j].parts
                var v = parts && parts.length > i ? String(parts[i]) : ""
                if (v.length > longest.length) longest = v
            }
            var w = grpFm.advanceWidth(longest) + Kirigami.Units.gridUnit * 2.2
            out.push(Math.round(Math.max(grpColMin, Math.min(grpColMax, w))))
        }
        return out
    }
    // a manual column width overrides the computed one (the key is the field name
    // so that it is not lost when the grouping order changes)
    property var grpColUser: ({})
    // the desired width: manual, otherwise by content
    function grpColWish(i) {
        var f = i < groupBy.length ? groupBy[i] : ""
        if (grpColUser[f] !== undefined) return grpColUser[f]
        return i < grpColWidths.length ? grpColWidths[i] : grpColMin
    }
    // THE ACTUAL width: if the panel is narrower than the sum of the desired ones,
    // the columns shrink PROPORTIONALLY - the counter must not fall off the edge,
    // whatever happens to the panel width. We do not squeeze below the minimum.
    property int grpPanelWidth: 0
    readonly property var grpColFit: {
        var wish = [], sum = 0
        for (var i = 0; i < groupBy.length; i++) {
            var w = grpColWish(i); wish.push(w); sum += w
        }
        var free = grpPanelWidth - grpCountWidth - Kirigami.Units.smallSpacing * 3
        if (free <= 0 || sum <= free) return wish
        var k = free / sum
        var out = []
        for (var j = 0; j < wish.length; j++)
            out.push(Math.max(Kirigami.Units.gridUnit * 3, Math.floor(wish[j] * k)))
        return out
    }
    function grpColWidth(i) {
        if (i === undefined) i = 0
        return i < grpColFit.length ? grpColFit[i] : grpColMin
    }
    function setGrpColWidth(i, w) {
        var f = i < groupBy.length ? groupBy[i] : ""
        if (!f) return
        var o = Object.assign({}, grpColUser)
        o[f] = Math.max(grpColMin, Math.round(w))
        grpColUser = o
    }
    function resetGrpColWidth(i) {
        var f = i < groupBy.length ? groupBy[i] : ""
        var o = Object.assign({}, grpColUser)
        delete o[f]
        grpColUser = o
    }
    // how much the panel needs in total - and how much the user set by dragging
    readonly property int grpNaturalWidth: {
        // the manual widths count too, otherwise after stretching a column the
        // counter moves beyond the edge of the panel
        var _ = grpColUser
        var w = grpCountWidth + Kirigami.Units.gridUnit * 2
        for (var i = 0; i < groupBy.length; i++) w += grpColWish(i)
        return w
    }
    property int grpUserWidth: 0

    readonly property int longValues: 1000
    function valuesText(f) {
        if (!f || !f.values) return ""
        var out = []
        for (var i = 0; i < f.values.length; i++)
            out.push(f.values[i].value + "  (" + f.values[i].n + ")")
        return out.join("\n")
    }

    // the field selected in the statistics table and its values
    property string statsField: ""
    readonly property var statsValues: {
        if (!fieldStats || !fieldStats.fields) return []
        for (var i = 0; i < fieldStats.fields.length; i++)
            if (fieldStats.fields[i].field === statsField)
                return fieldStats.fields[i].values
        return []
    }
    readonly property int statsMax: {
        var m = 1
        for (var i = 0; i < statsValues.length; i++)
            if (statsValues[i].n > m) m = statsValues[i].n
        return m
    }
    // for verification by rendering
    function openStats() { statsDlg.open() }

    function loadStats() {
        page.fieldStats = backend.eventFieldStats(page.whereText)
        // by default the first field is expanded - the window does not look empty
        page.statsField = ""   // the panel opens on a click, not by itself
    }
    readonly property var statsRows: {
        var stats = page.fieldStats
        if (!stats || !stats.fields) return []
        var q = statsFilter.toLowerCase()
        if (!q) return stats.fields
        var out = []
        for (var i = 0; i < stats.fields.length; i++) {
            var f = stats.fields[i]
            if (f.field.toLowerCase().indexOf(q) >= 0) { out.push(f); continue }
            for (var j = 0; j < f.values.length; j++)
                if (String(f.values[j].value).toLowerCase().indexOf(q) >= 0) { out.push(f); break }
        }
        return out
    }

    // PIN THE RANGE: the bound is computed NOW and written as an absolute time.
    // "For the last hour" stays that very hour instead of sliding along with the
    // clock - otherwise a second look would show a different set.
    // for verification from a harness: run the current query, like the Run button
    function runQuery() { qbar.apply() }
    function setQuick(t) { qbar.quickText = t; qbar.apply() }
    // for verification from a harness
    function qbarChanged() { return qbar.changed }
    function editCond0() { qbar.editCondition(0) }
    // for verification by rendering
    function selectMany(fs) { qbar.spec.select = fs; qbar.touch(); qbar.apply() }
    function qbarHeight() { return qbar.height }
    function openMore(kind) { qbar.showMore(kind) }
    function moveSelectField(i, d) { qbar.moveSelect(i, d) }
    function specSelect() { return qbar.spec.select.join(",") }
    // for verification: set the grouping and pick a group
    function setGroup(fs) {
        qbar.addClause("group")
        qbar.spec.groupBy = fs
        qbar.touch(); qbar.apply()
    }
    function pickGroup(row) {
        page.groupPicked = true
        page.groupVal = String(row.value || "")
        page.groupParts = row.parts || []
        page.syncWhere()
    }
    function openCal() { qbar.openCalendar("from") }
    function openSaved() { page.reloadSaved(); page.reloadDirs(); savedPanel.open = true }
    function openHistory() { histPopup.show("") }
    function setUpper(f, iso) { qbar.setUpperBound(f, iso) }
    function resetQuery() { qbar.clearAll() }
    function dropField(n) { qbar.toggleField(n) }
    function addCondition2(f, o, v) { qbar.addCondition(f, o, v) }

    // ---- LINKING AN EVENT WITH A LIVE PROCESS ----
    // The "pid -> command" map is taken ONCE PER PAGE (50 events by default).
    // There is no point computing it per event, and even less for the whole
    // database: the process of yesterday's event has long been dead.
    property var livePids: ({})
    function reloadLive() { livePids = backend.livePids() }
    function liveCommandOf(pid) { return page.liveCommand(pid) }
    function liveCommand(pid) {
        var p = String(pid || "")
        return p !== "" && livePids[p] !== undefined ? livePids[p] : ""
    }

    // ---- sorting by a click on the header ----
    // The order comes FROM THE QUERY (the builder or the typed SQL) - a single
    // source of truth, so the header and the query text always agree.
    property string orderText: ""
    property string sortCol: ""
    property bool sortDesc: false
    function sortBy(col) {
        if (sortCol === col) sortDesc = !sortDesc
        else { sortCol = col; sortDesc = false }
        qbar.addSort(col, sortDesc)     // it lands both in the SQL text and in the builder
        qbar.apply()
    }
    // and type a query by hand, as in SQL mode
    function manualQuery(t) {
        qbar.builderMode = false
        qbar.manualText = t
        qbar.apply()
    }

    // the default time window: one day, pinned with an absolute bound
    readonly property int defaultWindowMs: 86400000
    property bool timeSeeded: false
    function seedPeriod() {
        if (timeSeeded) return
        timeSeeded = true
        // WE ARE BACK IN THE SECTION AND THE QUERY IS STILL THERE. The page is
        // recreated when navigating between sections, so the query is stored in the
        // settings and restored together with its result.
        var st = backend.getSettings()
        if (st && st.events_query && qbar.importState(st.events_query)) return
        pinPeriod(defaultWindowMs)
        qbar.apply()
        // THIS IS THE ORIGINAL QUERY: the 8 feed columns + a day of events
        qbar.markBaseline()
    }
    function saveQueryState() {
        // we save only meaningful state: before the columns are initialised apply()
        // fires for nothing and would write an empty query
        if (!timeSeeded || !qbar.spec.select.length) return
        backend.setSetting("events_query", qbar.exportState())
    }

    function pinPeriod(ms) {
        var from = new Date(Date.now() - ms)
        // events are stored in UTC - the condition is in UTC too. We keep the
        // offset: on a reset the bound is recomputed from the current moment
        // instead of returning to the date the section was opened with.
        qbar.addCondition("ts", ">=",
                          from.toISOString().replace(/\.\d+Z$/, "Z"), "AND", ms)
    }

    // An external jump (from the network dashboard: "Events by address"). The
    // condition is ready, so we put it straight into the shared bar - there it is
    // visible and can be corrected by hand.
    function applyEventFocus() {
        if (!root.eventFocus) return
        qbar.builderMode = false
        qbar.manualText = root.eventFocus.where
        page.queryText = root.eventFocus.where
        page.pageIndex = 0
        page.syncWhere()
    }
    Connections {
        target: root
        function onEventFocusChanged() { page.applyEventFocus() }
        // arrival from "Changes": open the required chain at once
        function onChainFocusChanged() { page.applyChainFocus() }
    }

    function applyChainFocus() {
        if (!root.chainFocus) return
        page.mode = "chains"
        if (!page.chains) page.chains = backend.eventChains()
        page.chainId = root.chainFocus.id
        var d = backend.chainDetail(page.chainId)
        page.feed = { rows: d.steps || [], total: d.count || 0, error: "" }
        page.sel = null
    }


    function colWidth(c) {
        if (widths[c]) return widths[c]
        if (c === "ts") return 150
        if (c === "message" || c === "process_command_line" || c === "raw") return 330
        if (c === "object_name") return 230
        if (c === "subject_name" || c === "event_action") return 150
        if (c === "object_type" || c === "event_outcome") return 90
        if (c === "event_severity" || c === "process_pid"
            || c === "destination_port" || c === "parent_pid") return 70
        return 130
    }
    property int tableWidth: {
        var w = 8
        for (var i = 0; i < visibleCols.length; i++) w += colWidth(visibleCols[i])
        return w
    }
    function setWidth(c, w) {
        var o = Object.assign({}, widths); o[c] = Math.max(50, w); widths = o
    }
    function toggleCol(c) {
        var h = hiddenCols.slice()
        if (h.includes(c)) h = h.filter(x => x !== c); else h.push(c)
        hiddenCols = h; saveCfg()
    }
    function moveCol(c, dir) {
        var o = colOrder.slice()
        var i = o.indexOf(c), j = i + dir
        if (i < 0 || j < 0 || j >= o.length) return
        o[i] = o[j]; o[j] = c; colOrder = o; saveCfg()
    }
    function saveCfg() {
        backend.setSetting("events_colcfg", JSON.stringify(
            { v: page.cfgVersion, order: colOrder,
              hidden: hiddenCols, widths: widths }))
    }
    function initCols() {
        var groups = backend.eventFields()
        page.fieldGroups = groups
        var all = []
        for (var g = 0; g < groups.length; g++)
            for (var i = 0; i < groups[g].fields.length; i++)
                all.push(groups[g].fields[i].name)
        page.allCols = all
        var cfg = null
        var s = backend.getSettings()
        if (s && s.events_colcfg) {
            try { cfg = JSON.parse(s.events_colcfg) } catch (e) { cfg = null }
            // an old saved set must not override the new default
            if (cfg && (cfg.v || 0) < page.cfgVersion) cfg = null
        }
        var order = []
        if (cfg && cfg.order) order = cfg.order.filter(c => all.includes(c))
        for (var k = 0; k < all.length; k++)
            if (!order.includes(all[k])) order.push(all[k])
        page.colOrder = order
        page.hiddenCols = (cfg && cfg.hidden)
            ? cfg.hidden.filter(c => all.includes(c))
            : all.filter(c => !page.defaultCols.includes(c))
        page.widths = (cfg && cfg.widths) ? cfg.widths : ({})
        page.baseSelect = order.filter(c => !page.hiddenCols.includes(c))
        page.seedPeriod()
    }

    // THE SELECTION SETS THE COLUMNS: what is listed in SELECT is what the feed
    // shows, in the same order. An empty selection does not touch the columns.
    function applySelect(sel) {
        if (!sel || !sel.length) return
        var keep = sel.filter(c => page.allCols.includes(c))
        if (!keep.length) return
        var rest = page.colOrder.filter(c => !keep.includes(c))
        page.colOrder = keep.concat(rest)
        page.hiddenCols = rest
        // WE DO NOT SAVE IT: the selection in a query is a one-off look at the data,
        // not a setting of the view. Otherwise one narrow query would reshape the
        // table forever with no way to bring the old columns back. The permanent
        // column setup is done in the "Columns" panel - and that is what persists.
    }

    function reload() {
        page.feed = backend.eventRows(whereText, pageLimit,
                                      pageIndex * pageLimit, page.orderText)
        // the map of live processes - for the same page
        page.reloadLive()
        page.stats = backend.eventStats()
        if (groupBy.length) {
            var g = backend.eventGroups(groupBy.join(","), whereNoGroup())
            page.groupRows = g.rows || []
        } else {
            page.groupRows = []
        }
    }
    Component.onCompleted: {
        initCols()
        // an external jump (from the network dashboard) is applied INSTEAD of the
        // ordinary load: otherwise the condition would be overwritten by an empty filter
        if (root.eventFocus) applyEventFocus()
        else reload()
    }
    Connections {
        target: backend
        // Reload only on the first page and no more than once every few
        // seconds: the pipeline ticks every 2 s and a full reload on each tick
        // made scrolling stutter.
        property real lastReload: 0
        function onStateReady(s) {
            if (page.pageIndex !== 0) return
            var now = Date.now()
            if (now - lastReload < 5000) return
            lastReload = now
            page.reload()
        }
    }

    function sevColor(v) {
        var n = parseInt(v) || 0
        if (n >= 70) return "#e74c3c"
        if (n >= 45) return "#e67e22"
        if (n >= 25) return "#f1c40f"
        return Kirigami.Theme.disabledTextColor
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            // KDE HIG: one vertical rhythm for the whole column instead of
            // per-row margins — toolbars used to sit at different distances
            // from each other and from the page edge.
            spacing: Kirigami.Units.smallSpacing
            Layout.topMargin: Kirigami.Units.smallSpacing

            // ---- search + grouping ----
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.largeSpacing
                Layout.rightMargin: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.smallSpacing
                QueryBar {
                    id: qbar
                    Layout.fillWidth: true
                    // the taxonomy fields - the builder is made of them
                    fields: {
                        var out = []
                        var f = page.allFields
                        for (var i = 0; i < f.length; i++) out.push({ name: f[i] })
                        return out
                    }
                    // the selection starts with the 8 columns the feed shows
                    defaultSelect: page.baseSelect
                    // ---- working with queries: to the left of Run and Build ----
                    hostTools: [
                        QQC2.ToolButton {
                            icon.name: "document-save"
                            enabled: page.whereText.trim() !== ""
                            QQC2.ToolTip.text: "Save this query"
                            QQC2.ToolTip.visible: hovered
                            onClicked: { page.reloadDirs(); saveDialog.open() }
                        },
                        QQC2.ToolButton {
                            icon.name: "view-history"
                            QQC2.ToolTip.text: "Queries you ran before"
                            QQC2.ToolTip.visible: hovered
                            onClicked: histPopup.show("")
                        },
                        QQC2.ToolButton {
                            icon.name: "bookmarks"
                            QQC2.ToolTip.text: "Run a saved query"
                            QQC2.ToolTip.visible: hovered
                            onClicked: {
                                page.reloadSaved(); page.reloadDirs()
                                savedPanel.open = !savedPanel.open
                            }
                        }
                    ]
                    placeholder: "type SQL, or plain text to search everywhere"
                    onApplied: function (spec, sql) {
                        page.applySelect(spec.select)
                        // remember the query in the history (empty ones are not stored)
                        if (sql && sql.trim() !== "") backend.eventSqlRemember(sql)
                        page.orderText = qbar.orderText()
                        // the grouping is set in the query itself (GROUP BY)
                        var g = spec.groupBy.slice()
                        if (g.join(",") !== page.groupBy.join(",")) {
                            page.groupBy = g
                            page.groupVal = ""; page.groupParts = []
                            page.groupPicked = false
                        }
                        page.queryText = sql
                        page.pageIndex = 0
                        page.syncWhere()
                        page.saveQueryState()
                    }
                }
            }

            // ---- the WHERE expressed in SQL: built with + / -, editable by hand ----

            // ---- the chips of the active conditions ----

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.largeSpacing
                Layout.rightMargin: Kirigami.Units.largeSpacing
                visible: (page.feed.error || "") !== ""
                type: Kirigami.MessageType.Error
                text: page.feed.error || ""
            }

            // ---- the grouping on the left + the table on the right ----
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                Item {
                    visible: page.groupBy.length > 0
                    // THERE ARE AS MANY COLUMNS AS GROUPING FIELDS:
                    // the width of the panel grows with them
                    Layout.preferredWidth: page.grpUserWidth > 0
                        ? page.grpUserWidth
                        : Math.min(page.width * 0.6, page.grpNaturalWidth)
                    onWidthChanged: page.grpPanelWidth = width
                    Component.onCompleted: page.grpPanelWidth = width
                    Layout.fillHeight: true
                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 0
                        // THE HEADER IS THE SAME AS THE MAIN TABLE'S: the same
                        // background, the same height, the same column separators.
                        Rectangle {
                            id: grpHeadBar
                            Layout.fillWidth: true
                            Layout.preferredHeight: grpProbe.implicitHeight
                                                    + Kirigami.Units.smallSpacing * 2
                            color: Kirigami.Theme.alternateBackgroundColor
                            // the height measure: the same as the main table header
                            QQC2.Label { id: grpProbe; visible: false; text: "Ag"; font.bold: true }
                            Row {
                                id: grpHead
                                anchors.left: parent.left
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                Item { width: Kirigami.Units.smallSpacing; height: 1 }
                                Repeater {
                                    model: page.groupBy
                                    delegate: Item {
                                        required property var modelData
                                        required property int index
                                        width: page.grpColWidth(index)
                                        // A CELL THE FULL HEIGHT OF THE HEADER: the
                                        // resize handle used to be a thin 17 px strip
                                        // and it was impossible to hit
                                        height: grpHeadBar.height
                                        QQC2.Label {
                                            id: grpHeadLbl
                                            anchors.fill: parent
                                            leftPadding: Kirigami.Units.smallSpacing
                                            rightPadding: Kirigami.Units.largeSpacing
                                            verticalAlignment: Text.AlignVCenter
                                            text: modelData
                                            font.bold: true
                                            elide: Text.ElideRight
                                        }
                                        Kirigami.Separator {
                                            anchors.right: parent.right
                                            anchors.top: parent.top
                                            anchors.bottom: parent.bottom
                                            opacity: 0.35
                                        }
                                    }
                                }
                            }
                            // COLUMN RESIZING IS DONE BY ONE STRIP OVER THE HEADER.
                            // Separate handles inside the cells received no events
                            // (the layout covered them), while here the boundary is
                            // computed from the cursor coordinate.
                            MouseArea {
                                id: grpResize
                                anchors.fill: parent
                                z: 5
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton
                                property int edge: -1        // the boundary under the cursor
                                property real sx: 0
                                property real sw: 0
                                function edgeAt(x) {
                                    var acc = Kirigami.Units.smallSpacing
                                    for (var i = 0; i < page.groupBy.length; i++) {
                                        acc += page.grpColWidth(i)
                                        if (Math.abs(x - acc) <= 6) return i
                                    }
                                    return -1
                                }
                                cursorShape: (edge >= 0 || pressed) ? Qt.SplitHCursor
                                                                    : Qt.ArrowCursor
                                onPositionChanged: m => {
                                    if (pressed && edge >= 0) {
                                        page.setGrpColWidth(edge, sw + (m.x - sx))
                                        return
                                    }
                                    edge = edgeAt(m.x)
                                }
                                onPressed: m => {
                                    edge = edgeAt(m.x)
                                    sx = m.x
                                    sw = edge >= 0 ? page.grpColWish(edge) : 0
                                }
                                onDoubleClicked: m => {
                                    var e = edgeAt(m.x)
                                    if (e >= 0) page.resetGrpColWidth(e)
                                }
                                onExited: edge = -1
                                // highlighting the boundary that can be dragged
                                Rectangle {
                                    visible: grpResize.edge >= 0
                                    width: 2
                                    height: parent.height
                                    color: Kirigami.Theme.highlightColor
                                    x: {
                                        var acc = Kirigami.Units.smallSpacing
                                        for (var i = 0; i <= grpResize.edge
                                             && i < page.groupBy.length; i++)
                                            acc += page.grpColWidth(i)
                                        return acc - 1
                                    }
                                }
                            }
                            QQC2.Label {
                                anchors.right: parent.right
                                z: 6
                                // exactly above the numbers: the list has a scrollbar
                                // that the header did not know about - plus a margin
                                // from the edge, otherwise "n" sticks to the border
                                // exactly at the right edge of the list: the header has
                                // its own width, the list has its own (the scrollbar)
                                anchors.rightMargin: Math.max(0, grpHeadBar.width
                                                               - grpList.width)
                                anchors.verticalCenter: parent.verticalCenter
                                rightPadding: Kirigami.Units.smallSpacing
                                width: page.grpCountWidth
                                text: "count"
                                QQC2.ToolTip.text: page.shownGroups.length + " groups"
                                QQC2.ToolTip.visible: hovered
                                font.bold: true
                                horizontalAlignment: Text.AlignHCenter
                            }
                            Kirigami.Separator {
                                anchors.bottom: parent.bottom
                                width: parent.width
                                opacity: 0.35
                            }
                        }
                        QQC2.ScrollView {
                            id: grpScroll
                            // the scrollbar width: the header leaves exactly as much
                            // room for it as the list takes
                            readonly property int barW: QQC2.ScrollBar.vertical
                                && QQC2.ScrollBar.vertical.visible
                                ? QQC2.ScrollBar.vertical.width : 0
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            ListView {
                                id: grpList
                                model: page.shownGroups
                                delegate: QQC2.ItemDelegate {
                                    id: grpRow
                                    required property var modelData
                                    required property int index
                                    width: ListView.view.width
                                    // THE SAME SHAPE AS THE MAIN TABLE: the row height,
                                    // the zebra, the separator, the selection mark on
                                    // the right - otherwise two tables side by side
                                    // read as different applications.
                                    height: Kirigami.Units.gridUnit * 2.3
                                    padding: 0
                                    highlighted: page.groupPicked
                                                 && page.groupVal === String(modelData.value || "")
                                    background: Rectangle {
                                        color: grpRow.highlighted
                                               ? Qt.alpha(Kirigami.Theme.highlightColor, 0.20)
                                               : (grpRow.hovered
                                                  ? Qt.alpha(Kirigami.Theme.textColor, 0.07)
                                                  : (grpRow.index % 2 === 0
                                                     ? Kirigami.Theme.backgroundColor
                                                     : Kirigami.Theme.alternateBackgroundColor))
                                        Kirigami.Separator {
                                            anchors.bottom: parent.bottom
                                            width: parent.width
                                            opacity: 0.35
                                        }
                                        // the mark of the selected group is on the LEFT,
                                        // like the severity stripe in the feed: on the
                                        // right it was cut off by the scrollbar and the
                                        // selection looked crooked
                                        Rectangle {
                                            anchors { left: parent.left; top: parent.top
                                                      bottom: parent.bottom }
                                            width: 3
                                            visible: grpRow.highlighted
                                            color: Kirigami.Theme.highlightColor
                                        }
                                    }
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
                                        page.syncWhere()
                                    }
                                    contentItem: RowLayout {
                                        spacing: 0
                                        // one column per grouping field
                                        Repeater {
                                            model: modelData.parts
                                                   ? modelData.parts
                                                   : [String(modelData.value)]
                                            delegate: QQC2.Label {
                                                required property var modelData
                                                required property int index
                                                Layout.preferredWidth: page.grpColWidth(index)
                                                // air inside the cell, otherwise the
                                                // text runs into the border
                                                leftPadding: Kirigami.Units.smallSpacing
                                                rightPadding: Kirigami.Units.largeSpacing
                                                horizontalAlignment: Text.AlignLeft
                                                // THE SAME FORMATTING AS IN THE FEED:
                                                // the time in the local zone, addresses
                                                // and time in a monospaced font
                                                text: String(modelData) === ""
                                                    ? "(empty)"
                                                    : (page.groupBy[index] === "ts"
                                                       ? Fmt.local(String(modelData))
                                                       : String(modelData))
                                                opacity: String(modelData) === "" ? 0.5 : 1
                                                elide: Text.ElideRight
                                                font.family: (page.groupBy[index] === "ts"
                                                              || String(page.groupBy[index]).indexOf("_ip") >= 0)
                                                             ? "monospace"
                                                             : Kirigami.Theme.defaultFont.family
                                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                            }
                                        }
                                        Item { Layout.fillWidth: true }
                                        QQC2.Label {
                                            text: modelData.n
                                            opacity: 0.75
                                            horizontalAlignment: Text.AlignHCenter
                                            rightPadding: Kirigami.Units.smallSpacing
                                            Layout.preferredWidth: page.grpCountWidth
                                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                // THE BOUNDARY IS DRAGGABLE: how much space goes to the groups and how
                // much to the feed is decided by the user. A double click returns the
                // width "by content".
                Item {
                    visible: page.groupBy.length > 0
                    Layout.fillHeight: true
                    Layout.preferredWidth: Kirigami.Units.smallSpacing * 2
                    Kirigami.Separator {
                        anchors.horizontalCenter: parent.horizontalCenter
                        height: parent.height
                    }
                    MouseArea {
                        anchors.fill: parent
                        anchors.leftMargin: -3
                        anchors.rightMargin: -3
                        cursorShape: Qt.SplitHCursor
                        preventStealing: true
                        property real sx: 0
                        property int sw: 0
                        onPressed: m => {
                            sx = mapToItem(page, m.x, 0).x
                            sw = page.grpUserWidth > 0 ? page.grpUserWidth
                                 : Math.min(page.width * 0.6, page.grpNaturalWidth)
                        }
                        onPositionChanged: m => {
                            if (!pressed) return
                            var dx = mapToItem(page, m.x, 0).x - sx
                            page.grpUserWidth = Math.max(
                                Kirigami.Units.gridUnit * 8,
                                Math.min(page.width - Kirigami.Units.gridUnit * 12, sw + dx))
                        }
                        onDoubleClicked: page.grpUserWidth = 0
                    }
                }

                // ---- THE "STATISTICS" MODE: the same area as the feed ----
                ColumnLayout {
                    visible: page.mode === "stats"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                QQC2.TextField {
                    Layout.fillWidth: true
                    placeholderText: "search a field or a value…"
                    text: page.statsFilter
                    onTextChanged: page.statsFilter = text
                }
                QQC2.ToolButton {
                    icon.name: "view-refresh"
                    QQC2.ToolTip.text: "Recount for the current query"
                    QQC2.ToolTip.visible: hovered
                    onClicked: page.loadStats()
                }
            }
            QQC2.Label {
                Layout.fillWidth: true
                opacity: 0.7
                wrapMode: Text.Wrap
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                text: {
                    if (!page.fieldStats) return "…"
                    var t = page.statsRows.length + " fields filled in of "
                            + page.fieldStats.all_fields + "  ·  " + page.fieldStats.total + " events"
                    // THERE IS NO SILENT TRUNCATION: if we hit the threshold, we say so
                    if (page.fieldStats.truncated) t += "  ·  counted over the latest " + page.fieldStats.total
                    if (page.whereText) t += "  ·  query applied"
                    return t
                }
            }
            // THE STATISTICS ARE ONE TABLE: a row = a field, the second column holds
            // the values themselves in a column. A long list does not unfold over the
            // whole page: a click on a row opens a panel where it is shown in full.
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: Kirigami.Units.gridUnit * 24
                spacing: 0

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 0
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.rightMargin: Kirigami.Units.largeSpacing
                        spacing: Kirigami.Units.smallSpacing
                        QQC2.Label {
                            text: "Field"; font.bold: true; opacity: 0.6
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 12
                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                        }
                        QQC2.Label {
                            text: "Values"; font.bold: true; opacity: 0.6
                            Layout.fillWidth: true
                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                        }
                        QQC2.Label {
                            text: "Filled"; font.bold: true; opacity: 0.6
                            horizontalAlignment: Text.AlignRight
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                        }
                        QQC2.Label {
                            text: "Unique"; font.bold: true; opacity: 0.6
                            horizontalAlignment: Text.AlignRight
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                        }
                    }
                    Kirigami.Separator { Layout.fillWidth: true }
                    QQC2.ScrollView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        ListView {
                            model: page.statsRows
                            reuseItems: true
                            delegate: QQC2.ItemDelegate {
                                required property var modelData
                                required property int index
                                width: ListView.view.width
                                height: Math.max(Kirigami.Units.gridUnit * 2,
                                                 Math.min(Kirigami.Units.gridUnit * 5,
                                                          valsLbl.contentHeight
                                                          + Kirigami.Units.smallSpacing * 2))
                                onClicked: page.statsField = modelData.field
                                QQC2.ToolTip.text: page.valuesText(modelData).length > page.longValues
                                    ? "Click to see all values" : ""
                                QQC2.ToolTip.visible: hovered && QQC2.ToolTip.text !== ""
                                background: Rectangle {
                                    color: page.statsField === modelData.field
                                        ? Qt.alpha(Kirigami.Theme.highlightColor, 0.25)
                                        : (index % 2 ? Kirigami.Theme.alternateBackgroundColor
                                                     : Kirigami.Theme.backgroundColor)
                                }
                                contentItem: RowLayout {
                                    spacing: Kirigami.Units.smallSpacing
                                    QQC2.Label {
                                        Layout.preferredWidth: Kirigami.Units.gridUnit * 12
                                        Layout.alignment: Qt.AlignTop
                                        text: modelData.field
                                        elide: Text.ElideRight
                                        font.family: "monospace"
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                    // THE VALUES IN A COLUMN right inside the row
                                    QQC2.Label {
                                        id: valsLbl
                                        Layout.fillWidth: true
                                        Layout.alignment: Qt.AlignTop
                                        text: page.valuesText(modelData)
                                        maximumLineCount: 4
                                        elide: Text.ElideRight
                                        wrapMode: Text.NoWrap
                                        opacity: 0.85
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                    QQC2.Label {
                                        Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                                        Layout.alignment: Qt.AlignTop
                                        horizontalAlignment: Text.AlignRight
                                        text: modelData.percent + "%"
                                        opacity: 0.8
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                    QQC2.Label {
                                        Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                                        Layout.rightMargin: Kirigami.Units.largeSpacing
                                        Layout.alignment: Qt.AlignTop
                                        horizontalAlignment: Text.AlignRight
                                        text: modelData.unique
                                        opacity: 0.8
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                }
                            }
                        }
                    }
                }

                // ---- the field panel: all the values in full ----
                Kirigami.Separator {
                    Layout.fillHeight: true
                    visible: page.statsField !== ""
                }
                ColumnLayout {
                    visible: page.statsField !== ""
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 20
                    Layout.fillHeight: true
                    spacing: 0
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.margins: Kirigami.Units.smallSpacing
                        QQC2.Label {
                            Layout.fillWidth: true
                            text: page.statsField
                            font.bold: true
                            font.family: "monospace"
                            elide: Text.ElideRight
                        }
                        QQC2.ToolButton {
                            icon.name: "window-close"
                            onClicked: page.statsField = ""
                        }
                    }
                    Kirigami.Separator { Layout.fillWidth: true }
                    QQC2.ScrollView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        ListView {
                            model: page.statsValues
                            reuseItems: true
                            delegate: QQC2.ItemDelegate {
                                required property var modelData
                                required property int index
                                width: ListView.view.width
                                height: Kirigami.Units.gridUnit * 2
                                QQC2.ToolTip.text: "Add to the query"
                                QQC2.ToolTip.visible: hovered
                                onClicked: {
                                    qbar.addCondition(page.statsField, "=",
                                                      String(modelData.value))
                                }
                                background: Rectangle {
                                    color: index % 2 ? Kirigami.Theme.alternateBackgroundColor
                                                     : Kirigami.Theme.backgroundColor
                                }
                                contentItem: RowLayout {
                                    spacing: Kirigami.Units.smallSpacing
                                    QQC2.Label {
                                        Layout.fillWidth: true
                                        text: modelData.value
                                        elide: Text.ElideRight
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                    QQC2.Label {
                                        Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                                        Layout.rightMargin: Kirigami.Units.largeSpacing
                                        horizontalAlignment: Text.AlignRight
                                        text: modelData.n
                                        opacity: 0.8
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

                Flickable {
                    id: hflick
                    visible: page.mode !== "stats"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentWidth: Math.max(width, page.tableWidth)
                    flickableDirection: Flickable.HorizontalFlick
                    clip: true
                    QQC2.ScrollBar.horizontal: QQC2.ScrollBar {}

                    ListView {
                        id: tableView
                        width: hflick.contentWidth
                        height: hflick.height
                        model: page.feed.rows
                        // delegate recycling: the feed is reloaded on every
                        // refresh, and without reuse scrolling stutters
                        reuseItems: true
                        cacheBuffer: Kirigami.Units.gridUnit * 40
                        clip: true
                        headerPositioning: ListView.OverlayHeader
                        QQC2.ScrollBar.vertical: QQC2.ScrollBar {}

                        Kirigami.PlaceholderMessage {
                            anchors.centerIn: parent
                            width: parent.width - Kirigami.Units.gridUnit * 4
                            visible: tableView.count === 0
                            icon.name: "view-calendar-list"
                            text: "No events match"
                            explanation: "Every input whose output is type:events lands here."
                        }

                        header: Rectangle {
                            z: 3
                            width: tableView.width
                            height: hrow.implicitHeight + Kirigami.Units.smallSpacing * 2
                            color: Kirigami.Theme.alternateBackgroundColor
                            Row {
                                id: hrow
                                anchors.verticalCenter: parent.verticalCenter
                                Item { width: 8; height: 1 }
                                Repeater {
                                    model: page.visibleCols
                                    Item {
                                        width: page.colWidth(modelData)
                                        height: hlbl.implicitHeight
                                        property string col: modelData
                                        QQC2.Label {
                                            id: hlbl
                                            anchors.fill: parent
                                            anchors.rightMargin: sortIcon.visible ? 26 : 10
                                            leftPadding: Kirigami.Units.largeSpacing
                                            text: col
                                            font.bold: true
                                            elide: Text.ElideRight
                                        }
                                        // THE SORT DIRECTION AS AN ICON, as is
                                        // customary in tables: an arrow is read
                                        // faster than a character in the text.
                                        Kirigami.Icon {
                                            id: sortIcon
                                            anchors.right: parent.right
                                            anchors.rightMargin: Kirigami.Units.smallSpacing + 4
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: Kirigami.Units.iconSizes.small
                                            height: Kirigami.Units.iconSizes.small
                                            visible: page.sortCol === parent.col
                                            source: page.sortDesc ? "view-sort-descending"
                                                                  : "view-sort-ascending"
                                        }
                                        // THE SORTING GOES INTO THE QUERY: a click on
                                        // the header appends ORDER BY - both to the
                                        // typed SQL and to the builder.
                                        TapHandler {
                                            onTapped: page.sortBy(parent.col)
                                        }
                                        Kirigami.Separator {
                                            anchors.right: parent.right
                                            anchors.top: parent.top
                                            anchors.bottom: parent.bottom
                                            opacity: 0.35
                                        }
                                        MouseArea {
                                            width: 12
                                            anchors.right: parent.right
                                            anchors.top: parent.top
                                            anchors.bottom: parent.bottom
                                            cursorShape: Qt.SplitHCursor
                                            preventStealing: true
                                            property real sx
                                            property real sw
                                            onPressed: m => { sx = m.x; sw = page.colWidth(parent.col) }
                                            onPositionChanged: m => {
                                                if (pressed) page.setWidth(parent.col, sw + (m.x - sx))
                                            }
                                            onReleased: page.saveCfg()
                                        }
                                    }
                                }
                            }
                            Kirigami.Separator {
                                anchors.bottom: parent.bottom
                                width: parent.width
                            }
                        }

                        delegate: QQC2.ItemDelegate {
                            id: rowDel
                            width: tableView.width
                            height: Kirigami.Units.gridUnit * 2.3
                            property var rowData: modelData
                            highlighted: page.sel && page.sel._id === modelData._id
                            onClicked: page.sel = modelData
                            background: Rectangle {
                                // SELECTION BY THE HIGHLIGHT COLOUR, not grey:
                                // grey over the zebra was almost unreadable
                                color: rowDel.highlighted
                                       ? Qt.alpha(Kirigami.Theme.highlightColor, 0.20)
                                       : (rowDel.hovered
                                          ? Qt.alpha(Kirigami.Theme.textColor, 0.07)
                                          : (index % 2 === 0 ? Kirigami.Theme.backgroundColor
                                                             : Kirigami.Theme.alternateBackgroundColor))
                                Kirigami.Separator {
                                    anchors.bottom: parent.bottom
                                    width: parent.width
                                    opacity: 0.35
                                }
                                // THE SELECTED ROW is marked with a stripe of the
                                // highlight colour: a fill of its own competes with
                                // the zebra and with the severity stripe on the left.
                                Rectangle {
                                    anchors { right: parent.right; top: parent.top
                                              bottom: parent.bottom }
                                    width: 3
                                    visible: rowDel.highlighted
                                    color: Kirigami.Theme.highlightColor
                                }
                            }
                            contentItem: Row {
                                Rectangle {
                                    width: 8
                                    height: rowDel.height
                                    color: page.sevColor(rowDel.rowData.event_severity)
                                    opacity: 0.85
                                }
                                Repeater {
                                    model: page.visibleCols
                                    Item {
                                        id: cell
                                        width: page.colWidth(modelData)
                                        height: rowDel.height
                                        property string col: modelData
                                        property string val: String(rowDel.rowData[modelData] ?? "")
                                        // WE SHOW the local time, while val keeps
                                        // UTC: the WHERE conditions are built from it
                                        // and the database stores UTC
                                        property string display: cell.col === "ts"
                                                                 ? Fmt.local(cell.val) : cell.val
                                        QQC2.Label {
                                            anchors.fill: parent
                                            // air inside the cell
                                            anchors.rightMargin: cellHover.hovered
                                                                 ? 40 : Kirigami.Units.largeSpacing
                                            verticalAlignment: Text.AlignVCenter
                                            leftPadding: Kirigami.Units.largeSpacing
                                            text: cell.display
                                            elide: Text.ElideRight
                                            font.family: (cell.col === "ts"
                                                          || cell.col.indexOf("_ip") >= 0)
                                                         ? "monospace"
                                                         : Kirigami.Theme.defaultFont.family
                                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                                            color: cell.col === "event_outcome" && cell.val === "failure"
                                                   ? Kirigami.Theme.negativeTextColor
                                                   : Kirigami.Theme.textColor
                                        }
                                        HoverHandler { id: cellHover }
                                        // A click on a CELL selects the row - the
                                        // selection used to depend on whether the
                                        // click missed the content.
                                        // A double click COPIES the value.
                                        TapHandler {
                                            acceptedButtons: Qt.LeftButton
                                            onSingleTapped: page.sel = rowDel.rowData
                                            onDoubleTapped: {
                                                page.sel = rowDel.rowData
                                                page.copyValue(cell.val)
                                            }
                                        }
                                        // + adds the value to the filter, - excludes it
                                        // CELL ACTIONS ARE LAZY.
                                        // Each cell used to build three
                                        // buttons and a ten-item Menu up
                                        // front: 50 rows x 8 columns is
                                        // ~4000 objects, and that is what
                                        // made reload() take seconds.
                                        // Now nothing exists until hover.
                                        Loader {
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.rightMargin: 2
                                            active: cellHover.hovered && cell.val !== ""
                                            visible: active
                                            sourceComponent: Component {
                                            Row {
                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                anchors.rightMargin: 2
                                                spacing: 1
                                                QQC2.ToolButton {
                                                    implicitWidth: Kirigami.Units.gridUnit * 1.1
                                                    implicitHeight: Kirigami.Units.gridUnit * 1.1
                                                    text: "+"
                                                    QQC2.ToolTip.text: "Include " + cell.col + " = " + cell.val
                                                    QQC2.ToolTip.visible: hovered
                                                    onClicked: page.addCond(cell.col, "=", cell.val)
                                                }
                                                QQC2.ToolButton {
                                                    implicitWidth: Kirigami.Units.gridUnit * 1.1
                                                    implicitHeight: Kirigami.Units.gridUnit * 1.1
                                                    text: "−"
                                                    QQC2.ToolTip.text: "Exclude " + cell.col + " = " + cell.val
                                                    QQC2.ToolTip.visible: hovered
                                                    onClicked: page.addCond(cell.col, "<>", cell.val)
                                                }
                                                // the other comparison operators (as in RQL)
                                                QQC2.ToolButton {
                                                    implicitWidth: Kirigami.Units.gridUnit * 1.1
                                                    implicitHeight: Kirigami.Units.gridUnit * 1.1
                                                    text: "⋯"
                                                    QQC2.ToolTip.text: "More operators"
                                                    QQC2.ToolTip.visible: hovered
                                                    onClicked: opMenu.popup()
                                                    QQC2.Menu {
                                                        id: opMenu
                                                        QQC2.MenuItem {
                                                            text: "contains  (LIKE)"
                                                            onTriggered: page.addCond(cell.col, "LIKE", cell.val)
                                                        }
                                                        QQC2.MenuItem {
                                                            text: "not contains  (NOT LIKE)"
                                                            onTriggered: page.addCond(cell.col, "NOT LIKE", cell.val)
                                                        }
                                                        QQC2.MenuSeparator {}
                                                        QQC2.MenuItem {
                                                            text: "greater  >"
                                                            onTriggered: page.addCond(cell.col, ">", cell.val)
                                                        }
                                                        QQC2.MenuItem {
                                                            text: "less  <"
                                                            onTriggered: page.addCond(cell.col, "<", cell.val)
                                                        }
                                                        QQC2.MenuItem {
                                                            text: "greater or equal  >="
                                                            onTriggered: page.addCond(cell.col, ">=", cell.val)
                                                        }
                                                        QQC2.MenuItem {
                                                            text: "less or equal  <="
                                                            onTriggered: page.addCond(cell.col, "<=", cell.val)
                                                        }
                                                        QQC2.MenuSeparator {}
                                                        QQC2.MenuItem {
                                                            text: "is empty  (IS NULL)"
                                                            onTriggered: page.addCond(cell.col, "IS NULL", "")
                                                        }
                                                        QQC2.MenuItem {
                                                            text: "is not empty  (IS NOT NULL)"
                                                            onTriggered: page.addCond(cell.col, "IS NOT NULL", "")
                                                        }
                                                        QQC2.MenuSeparator {}
                                                        QQC2.MenuItem {
                                                            // a subnet: the RQL idiom `ip IN '192.0.2.0/24'`
                                                            text: "same /24 subnet"
                                                            enabled: cell.col.indexOf("_ip") >= 0
                                                            onTriggered: {
                                                                var o = cell.val.split(".")
                                                                if (o.length === 4)
                                                                    page.addCond(cell.col, "IN",
                                                                        o[0] + "." + o[1] + "." + o[2] + ".0/24")
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                            }
                                        }
                                        Kirigami.Separator {
                                            anchors.right: parent.right
                                            anchors.top: parent.top
                                            anchors.bottom: parent.bottom
                                            opacity: 0.25
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ---- the footer ----
            QQC2.ToolBar {
                Layout.fillWidth: true
                RowLayout {
                    anchors.fill: parent
                    spacing: Kirigami.Units.smallSpacing
                    QQC2.Label {
                        opacity: 0.7
                        text: page.feed.total + " events" +
                              (page.stats.total ? "  of " + page.stats.total : "")
                    }
                    Item { Layout.fillWidth: true }
                    QQC2.ToolButton {
                        icon.name: "go-previous"; enabled: page.pageIndex > 0
                        onClicked: { page.pageIndex--; page.reload() }
                    }
                    QQC2.Label {
                        text: (page.pageIndex + 1) + " / " +
                              Math.max(1, Math.ceil(page.feed.total / page.pageLimit))
                    }
                    QQC2.ToolButton {
                        icon.name: "go-next"
                        enabled: (page.pageIndex + 1) * page.pageLimit < page.feed.total
                        onClicked: { page.pageIndex++; page.reload() }
                    }
                    QQC2.ComboBox {
                        // how many rows to show; "all" = no limit
                model: [{ t: "50", v: 50 }, { t: "100", v: 100 }, { t: "200", v: 200 },
                        { t: "500", v: 500 }, { t: "1000", v: 1000 },
                        { t: "all", v: 0 }]
                textRole: "t"
                valueRole: "v"
                        implicitWidth: Kirigami.Units.gridUnit * 6
                        QQC2.ToolTip.text: "Rows per page"
                        QQC2.ToolTip.visible: hovered
                        onActivated: {
                            page.pageLimit = currentValue > 0 ? currentValue : 100000
                            page.pageIndex = 0
                            page.reload()
                        }
                    }
                    QQC2.ToolButton {
                        icon.name: "view-refresh"; onClicked: page.reload()
                        QQC2.ToolTip.text: "Refresh"; QQC2.ToolTip.visible: hovered
                    }
                    QQC2.ToolButton {
                        icon.name: page.mode === "stats" ? "view-list-details"
                                                         : "office-chart-bar"
                        text: page.mode === "stats" ? "Events" : "Statistics"
                        display: QQC2.AbstractButton.TextBesideIcon
                        checkable: true
                        checked: page.mode === "stats"
                        QQC2.ToolTip.text: page.mode === "stats"
                            ? "Back to the event list"
                            : "Which fields are filled in, and with what — for this query"
                        QQC2.ToolTip.visible: hovered
                        onClicked: {
                            // THE STATISTICS ARE A MODE OF THE SAME TABLE, not a window
                            // on top: the query is one, only the view changes.
                            if (page.mode === "stats") { page.mode = "feed"; return }
                            page.mode = "stats"
                            page.loadStats()
                        }
                    }
            // THE COLUMN CHOICE WAS REMOVED: the columns are set by SELECT in the query bar
                }
            }
        }

        // ---- SAVED QUERIES ----
        SidePanel {
            id: savedPanel
            title: "Saved queries"
            iconName: "bookmarks"
            panelWidth: Kirigami.Units.gridUnit * 30
            open: false
            onCloseRequested: open = false

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                // the directory tree: "All" + the expertise directories
                ColumnLayout {
                    // the width is fixed, otherwise the column ate the whole panel and
                    // the queries themselves were left without room
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 11
                    Layout.maximumWidth: Kirigami.Units.gridUnit * 11
                    Layout.fillWidth: false
                    Layout.fillHeight: true
                    spacing: 0
                    QQC2.ItemDelegate {
                        Layout.fillWidth: true
                        height: Kirigami.Units.gridUnit * 2
                        highlighted: page.savedDir === ""
                        onClicked: page.savedDir = ""
                        contentItem: RowLayout {
                            Kirigami.Icon {
                                source: "folder-open"
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                            }
                            QQC2.Label {
                                Layout.fillWidth: true
                                text: "All queries"
                                elide: Text.ElideRight
                            }
                            QQC2.Label {
                                text: page.savedCount("")
                                opacity: 0.6
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                        }
                    }
                    QQC2.ScrollView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        ListView {
                            model: page.dirsList
                            reuseItems: true
                            delegate: QQC2.ItemDelegate {
                                required property var modelData
                                width: ListView.view.width
                                height: Kirigami.Units.gridUnit * 2
                                highlighted: page.savedDir === String(modelData)
                                onClicked: page.savedDir = String(modelData)
                                contentItem: RowLayout {
                                    Kirigami.Icon {
                                        source: "folder"
                                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                    }
                                    QQC2.Label {
                                        Layout.fillWidth: true
                                        text: modelData
                                        elide: Text.ElideRight
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                    QQC2.Label {
                                        text: page.savedCount(String(modelData))
                                        opacity: 0.6
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                }
                            }
                        }
                    }
                }
                Kirigami.Separator { Layout.fillHeight: true }

                // the queries of the selected directory (or of all of them)
                QQC2.ScrollView {
                    Layout.fillWidth: true
                    Layout.minimumWidth: Kirigami.Units.gridUnit * 12
                    Layout.fillHeight: true
                    clip: true
                    ListView {
                        model: page.savedShown
                        reuseItems: true
                        section.property: page.savedDir === "" ? "dir" : ""
                        section.delegate: Kirigami.ListSectionHeader {
                            required property string section
                            width: ListView.view.width
                            label: section
                        }
                        delegate: QQC2.ItemDelegate {
                            required property var modelData
                            required property int index
                            width: ListView.view.width
                            height: Kirigami.Units.gridUnit * 3
                            onClicked: {
                                page.whereText = modelData.sql
                                qbar.builderMode = false
                                qbar.manualText = modelData.sql
                                page.queryText = modelData.sql
                                page.pageIndex = 0
                                page.reload()
                                savedPanel.open = false
                            }
                            background: Rectangle {
                                color: index % 2 ? Kirigami.Theme.alternateBackgroundColor
                                                 : Kirigami.Theme.backgroundColor
                            }
                            contentItem: RowLayout {
                                spacing: Kirigami.Units.smallSpacing
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0
                                    QQC2.Label {
                                        Layout.fillWidth: true
                                        text: modelData.title
                                        elide: Text.ElideRight
                                    }
                                    QQC2.Label {
                                        Layout.fillWidth: true
                                        text: modelData.sql
                                        elide: Text.ElideRight
                                        opacity: 0.6
                                        font.family: "monospace"
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                    }
                                }
                                QQC2.ToolButton {
                                    icon.name: "edit-delete"
                                    implicitWidth: Kirigami.Units.gridUnit * 1.8
                                    implicitHeight: Kirigami.Units.gridUnit * 1.8
                                    QQC2.ToolTip.text: "Delete"
                                    QQC2.ToolTip.visible: hovered
                                    onClicked: {
                                        backend.deleteQuery(modelData.ref)
                                        page.reloadSaved()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // ---- the event details ----
        SidePanel {
            id: details
            title: "Event"
            iconName: "view-calendar-list"
            panelWidth: Kirigami.Units.gridUnit * 24
            open: page.sel !== null && !colPanel.open
            onCloseRequested: page.sel = null

            // THE PROCESS OF THE EVENT IS STILL ALIVE - it can be looked at in the
            // graph: who started it, what it opened, where it goes.
            QQC2.Button {
                Layout.fillWidth: true
                visible: page.sel && page.eventProcess(page.sel).alive
                icon.name: "distribute-graph-directed"
                text: "Open process graph"
                QQC2.ToolTip.text: page.sel
                    ? "PID " + page.sel.process_pid + " — "
                      + page.liveCommand(page.sel.process_pid)
                    : ""
                QQC2.ToolTip.visible: hovered
                onClicked: root.focusProcess(page.sel.process_pid)
            }
            QQC2.Label {
                Layout.fillWidth: true
                visible: page.sel && String(page.sel.process_pid || "") !== ""
                         && !page.eventProcess(page.sel).alive
                text: "Process " + (page.sel ? page.sel.process_pid : "")
                      + (page.sel && page.sel.process_name
                         ? " (" + page.sel.process_name + ")" : "") + " is gone"
                opacity: 0.6
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }

            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                ColumnLayout {
                    width: details.panelWidth - Kirigami.Units.largeSpacing * 2
                    spacing: Kirigami.Units.smallSpacing
                    Repeater {
                        model: page.fieldGroups
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            property var filled: {
                                var r = []
                                if (!page.sel) return r
                                for (var i = 0; i < modelData.fields.length; i++) {
                                    var f = modelData.fields[i]
                                    var v = page.sel[f.name]
                                    if (v !== undefined && v !== null && String(v) !== "") {
                                        // we show the local time (UTC in the database)
                                        var sv = (f.name === "ts" || f.name === "ingested")
                                                 ? Fmt.local(v) : String(v)
                                        r.push({ n: f.name, v: sv, e: f.ecs })
                                    }
                                }
                                return r
                            }
                            visible: filled.length > 0
                            Kirigami.ListSectionHeader {
                                Layout.fillWidth: true
                                label: modelData.group
                            }
                            Repeater {
                                model: parent.filled
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.smallSpacing
                                    QQC2.Label {
                                        text: modelData.n
                                        opacity: 0.6
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                                        Layout.alignment: Qt.AlignTop
                                        elide: Text.ElideRight
                                        QQC2.ToolTip.text: modelData.e ? "ECS: " + modelData.e : modelData.n
                                        QQC2.ToolTip.visible: fieldHover.hovered
                                        HoverHandler { id: fieldHover }
                                    }
                                    QQC2.Label {
                                        Layout.fillWidth: true
                                        text: modelData.v
                                        wrapMode: Text.WrapAnywhere
                                        font.family: "monospace"
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                    // "Explore": a jump into State with a filter
                                    QQC2.ToolButton {
                                        visible: page.exploreMap[modelData.n] !== undefined
                                        icon.name: "search"
                                        implicitWidth: Kirigami.Units.gridUnit * 1.4
                                        implicitHeight: Kirigami.Units.gridUnit * 1.4
                                        QQC2.ToolTip.visible: hovered
                                        QQC2.ToolTip.text: {
                                            var m = page.exploreMap[modelData.n]
                                            return m ? "Explore in State → " + m.table : ""
                                        }
                                        onClicked: {
                                            var m = page.exploreMap[modelData.n]
                                            if (m) root.focusState(m.table, m.col, modelData.v)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // ---- the column chooser ----
        SidePanel {
            id: colPanel
            title: "Columns"
            iconName: "view-table-of-contents-ltr"
            panelWidth: Kirigami.Units.gridUnit * 16
            onCloseRequested: open = false

            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                ColumnLayout {
                    width: colPanel.panelWidth - Kirigami.Units.largeSpacing * 2
                    spacing: 0
                    Kirigami.SearchField {
                        Layout.fillWidth: true
                        placeholderText: "search a field…"
                        text: page.colSearch
                        onTextChanged: page.colSearch = text
                    }
                    QQC2.Label {
                        Layout.fillWidth: true
                        text: page.visibleCols.length + " of " + page.allCols.length + " shown"
                              + (page.colSearch !== ""
                                 ? "  ·  " + page.shownColChoices.length + " found" : "")
                        opacity: 0.6
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                    Repeater {
                        model: page.shownColChoices
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
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                opacity: page.hiddenCols.includes(modelData) ? 0.5 : 1
                            }
                            QQC2.ToolButton {
                                icon.name: "go-up"
                                // the order is computed over the FULL list: while
                                // searching an index in the filtered one means nothing
                                enabled: page.colOrder.indexOf(modelData) > 0
                                onClicked: page.moveCol(modelData, -1)
                            }
                            QQC2.ToolButton {
                                icon.name: "go-down"
                                enabled: page.colOrder.indexOf(modelData)
                                         < page.colOrder.length - 1
                                onClicked: page.moveCol(modelData, 1)
                            }
                        }
                    }
                }
            }
        }

        // ---- CHAINS: the list on the left, the EVENTS OF THE CHAIN on the right ----
        // The events are shown by the same table and the same side panel as the
        // ordinary feed: a chain is not a separate "cheap" list but the same view of
        // events, only filtered by a story.
        ColumnLayout {
            visible: page.mode === "chains"
            Layout.preferredWidth: Kirigami.Units.gridUnit * 22
            Layout.fillHeight: true
            spacing: 0

            QQC2.Label {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                wrapMode: Text.WordWrap
                opacity: 0.75
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                text: page.chains
                      ? (page.chains.total + " chains · linked "
                         + page.chains.covered_pct + "% of events, strong links "
                         + page.chains.strong_pct + "%")
                      : ""
            }
            QQC2.ScrollView {
                id: chainScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                ListView {
                    model: page.chains ? (page.chains.chains || []) : []
                    spacing: 2
                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        width: chainScroll.availableWidth
                        height: chCol.implicitHeight + Kirigami.Units.smallSpacing
                        color: page.chainId === modelData.id
                               ? Qt.alpha(Kirigami.Theme.highlightColor, 0.3)
                               : (index % 2 ? Kirigami.Theme.alternateBackgroundColor
                                            : Kirigami.Theme.backgroundColor)
                        Rectangle {
                            width: 4; height: parent.height
                            color: page.sevColor(modelData.severity)
                        }
                        ColumnLayout {
                            id: chCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.leftMargin: Kirigami.Units.largeSpacing
                            anchors.margins: 3
                            spacing: 0
                            RowLayout {
                                Layout.fillWidth: true
                                QQC2.Label {
                                    Layout.fillWidth: true
                                    text: modelData.title
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                                QQC2.Label {
                                    text: modelData.count + " ev."
                                    opacity: 0.7
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                }
                            }
                            QQC2.Label {
                                Layout.fillWidth: true
                                opacity: 0.65
                                elide: Text.ElideRight
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                text: "from " + String(modelData.start).replace("T", " ").substring(0, 16)
                                      + " · " + (modelData.categories || []).join(", ")
                            }
                            QQC2.Label {
                                Layout.fillWidth: true
                                opacity: 0.5
                                elide: Text.ElideRight
                                font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                // WHAT the events are linked by: the reliability is visible
                                text: {
                                    var l = modelData.links || {}, p = []
                                    for (var k in l) p.push(k + " " + l[k])
                                    return "link: " + p.join(", ")
                                }
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                page.chainId = modelData.id
                                var d = backend.chainDetail(modelData.id)
                                // we replace the feed with the events of the chain: the
                                // same table, the same columns, the same details panel
                                page.feed = { rows: d.steps || [],
                                              total: d.count || 0, error: "" }
                                page.sel = null
                            }
                        }
                    }
                }
            }
        }

        Kirigami.Separator {
            visible: page.mode === "chains"
            Layout.fillHeight: true
        }


    }

    // ---- the SQL history: the last 10, and while typing the similar ones from the WHOLE history ----
    QQC2.Popup {
        id: histPopup
        // in the same place as the saved ones: the left corner under the query bar
        x: 0
        y: Kirigami.Units.gridUnit * 9
        width: Math.min(page.width * 0.6, Kirigami.Units.gridUnit * 40)
        padding: 2
        property var items: []
        property bool filtered: false      // a list of similar ones, not just recent
        function show(text) {
            var t = (text || "").trim()
            filtered = t !== ""
            items = t === "" ? backend.eventSqlHistory(10)
                             : backend.eventSqlSuggest(t, 8)
            if (items && items.length > 0) open(); else close()
        }
        contentItem: ColumnLayout {
            spacing: 0
            QQC2.Label {
                Layout.fillWidth: true
                Layout.margins: 4
                text: histPopup.filtered ? "Similar queries" : "Recent queries"
                opacity: 0.6
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
            Repeater {
                model: histPopup.items
                QQC2.ItemDelegate {
                    Layout.fillWidth: true
                    contentItem: QQC2.Label {
                        text: modelData
                        elide: Text.ElideRight
                        font.family: "monospace"
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                    onClicked: {
                        page.whereText = modelData
                        qbar.builderMode = false
                        qbar.manualText = modelData
                        page.queryText = modelData
                        histPopup.close()
                        page.pageIndex = 0
                        page.reload()
                    }
                }
            }
        }
    }

    // ---- saving a query: a name + a directory (a directory can be created here) ----
    Kirigami.Dialog {
        id: saveDialog
        title: "Save query"
        preferredWidth: Kirigami.Units.gridUnit * 26
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        onAccepted: {
            var d = (newDir.text.trim() !== "") ? newDir.text.trim()
                                                : String(dirBox.currentText || "general")
            var ref = backend.saveQuery(d, saveName.text, page.whereText, saveDesc.text)
            if (String(ref).indexOf("error:") !== 0) {
                page.reloadSaved()
                newDir.text = ""
            }
        }
        ColumnLayout {
            spacing: Kirigami.Units.smallSpacing
            QQC2.Label {
                Layout.fillWidth: true
                text: "Stored in expertise/queries/<folder>/ — outside fedora, yours to edit."
                opacity: 0.7
                wrapMode: Text.WordWrap
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
            QQC2.TextField {
                id: saveName
                Layout.fillWidth: true
                placeholderText: "Query name"
            }
            QQC2.TextField {
                id: saveDesc
                Layout.fillWidth: true
                placeholderText: "Description (optional)"
            }
            RowLayout {
                Layout.fillWidth: true
                QQC2.ComboBox {
                    id: dirBox
                    Layout.fillWidth: true
                    model: page.dirsList
                }
                QQC2.TextField {
                    id: newDir
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                    placeholderText: "or new folder"
                }
            }
            QQC2.Label {
                Layout.fillWidth: true
                text: page.whereText
                font.family: "monospace"
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                opacity: 0.75
                wrapMode: Text.WrapAnywhere
            }
        }
    }

    // ---- SAVED QUERIES - THE SIDE PANEL ----
    // These are expertise objects (expertise/queries/<directory>), so we show them
    // as expertise: the directory tree on the left, the queries on the right.
    // A click on the ROOT shows the queries of every directory at once.
    property string savedDir: ""          // "" = all directories
    readonly property var savedShown: {
        if (savedDir === "") return savedList
        var out = []
        for (var i = 0; i < savedList.length; i++)
            if (String(savedList[i].dir) === savedDir) out.push(savedList[i])
        return out
    }
    function savedCount(dir) {
        if (dir === "") return savedList.length
        var n = 0
        for (var i = 0; i < savedList.length; i++)
            if (String(savedList[i].dir) === dir) n++
        return n
    }


    // ---- picking a grouping field with search (87 fields, a plain list is awkward) ----



    // An investigation starts not by reading the feed but with the question "which
    // fields are filled at all and with what values" - that is how mature SIEMs do
    // it. It is computed RELATIVE TO THE CURRENT QUERY, so narrowing the selection
    // recomputes the statistics for it. A click on a value adds it to the condition.



    // A COPY CONFIRMATION: without it a double click looks like nothing happened.

    Kirigami.InlineMessage {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Kirigami.Units.gridUnit * 3
        z: 100
        width: Math.min(parent.width * 0.6, Kirigami.Units.gridUnit * 30)
        visible: page.copied !== ""
        type: Kirigami.MessageType.Positive
        text: "Copied: " + page.copied
    }

}

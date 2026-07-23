import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components/Fmt.js" as Fmt
import "../components"
import "../views"
import "."

// System state: read-only tables view. Table/field/record management
// lives in the SQL tab. Right sidebars (details, columns) are full height.
Kirigami.Page {
    id: page
    title: "State"
    padding: 0

    property var s: root.sysState
    // Vulnerabilities live in a separate tab of the "Dashboards" section: that is
    // not an inventory of the system but a list of tasks, "what to patch".
    property var tabsModel: {
        var t = s ? s.tabs : []
        return t.filter(function (x) { return x.name !== "vulnerabilities" })
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
        var r = backend.tableRows(cur.name, where, order,
                                  pageLimit > 0 ? pageLimit : 0,
                                  pageLimit > 0 ? pageIndex * pageLimit : 0)
        curRows = r.rows || []
        curTotal = r.total || 0
        rowsError = r.error || ""
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

    property var listCols: cur ? cur.columns : []
    property var colOrder: {
        if (!cur) return listCols
        const cfg = cur.colcfg
        const base = cfg && cfg.order ? cfg.order.filter(c => listCols.includes(c)) : []
        for (const c of listCols) if (!base.includes(c)) base.push(c)
        return base
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
        if (typeof qbar !== "undefined") {
            qbar.clearAll()
            qbar.addCondition(f.col, "=", String(f.val))
            qbar.apply()
        }
    }
    Component.onCompleted: { page.loadRows(); applyFocus() }

    // FRESH DATA WITHOUT THRASHING. The snapshot arrives while the pipeline
    // collects (once a second at most), and re-reading the table on every one of
    // them would keep the list rebuilding under the cursor. We coalesce them: one
    // read shortly after the last snapshot, and only for the table on screen.
    onSChanged: rowsTimer.restart()
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
    property int tableWidth: {
        let w = Math.round(Kirigami.Units.gridUnit * 2)   // the checkbox column
        for (const c of visibleCols) w += colWidth(c)
        return w
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

    // ---- search across all state tables ----
    property bool searchAll: false
    property var globalHits: ({ tables: [], total: 0 })
    // for verification by rendering
    function setSearchText(t) { search.text = t }
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

    function runGlobalSearch() {
        globalHits = backend.stateSearch(search.text)
    }
    // a click on a found table: open it and keep the same text as the filter
    function openHit(hit) {
        for (var i = 0; i < tabsModel.length; i++)
            if (tabsModel[i].name === hit.table) { tabIndex = i; break }
        page.searchAll = false
        page.pageIndex = 0
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
    function rowAccent(r) {
        if (!r) return ""
        var sev = String(r.severity || r.cvss_rating || "").toLowerCase()
        if (sev.indexOf("critical") >= 0) return Kirigami.Theme.negativeTextColor
        if (sev.indexOf("important") >= 0 || sev.indexOf("high") >= 0)
            return Kirigami.Theme.neutralTextColor
        var risk = String(r.risk || "").toLowerCase()
        if (risk === "high") return Kirigami.Theme.negativeTextColor
        if (risk === "medium") return Kirigami.Theme.neutralTextColor
        var exp = String(r.exposure || "")
        if (exp.indexOf("OPEN") >= 0) return Kirigami.Theme.negativeTextColor
        if (exp.indexOf("filtered") >= 0) return Kirigami.Theme.neutralTextColor
        var st = String(r.status || "").toLowerCase()
        if (st === "open" || st === "differs") return Kirigami.Theme.neutralTextColor
        if (String(r.deleted || "") === "yes") return Kirigami.Theme.negativeTextColor
        return ""
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
    function applyQuery(sql) {
        queryText = (sql || "").trim()
        pageIndex = 0
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
    property var lastSel: null         // the last clicked one - for the details sidebar
    property int selAnchor: -1         // the index for a shift range
    property string selName: ""        // the tab the selection belongs to
    function isSel(r) {
        return r._id !== undefined && selRows.some(x => x._id === r._id)
    }
    function clickRow(r, index, mods) {
    selName = cur ? cur.name : ""    // the selection belongs to this tab
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
            QQC2.Label {
                opacity: 0.7
                text: page.curTotal === 0 ? "0 rows"
                      : (page.pageIndex * page.pageLimit + 1) + "–" +
                        Math.min((page.pageIndex + 1) * page.pageLimit, page.curTotal) +
                        " of " + page.curTotal
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
                        required property var modelData
                        width: ListView.view.width
                        highlighted: page.cur && page.cur.name === modelData.name
                        onClicked: page.openTable(modelData.name)
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
                fields: page.cur
                    ? page.cur.columns.filter(c => !c.startsWith("_"))
                                      .map(function (c) { return { name: c } })
                    : []
                defaultSelect: page.visibleCols
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
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing
                // THE "filter this table" FIELD WAS REMOVED: this table is searched
                // by the query bar above. What is left here is only what it cannot
                // do - a search ACROSS ALL state tables at once.
                Kirigami.SearchField {
                    id: search
                    visible: page.searchAll
                    Layout.fillWidth: true
                    placeholderText: "search across all state tables…"
                    onTextChanged: {
                        page.pageIndex = 0
                        if (page.searchAll) page.runGlobalSearch()
                    }
                }
                Item { Layout.fillWidth: true; visible: !page.searchAll }
                // SEARCH ACROSS THE WHOLE STATE: an analyst looks for an address or
                // a name without knowing which table holds it. The switch changes
                // the scope of the search: this table or all of them at once.
                QQC2.ToolButton {
                    icon.name: "edit-find"
                    display: QQC2.AbstractButton.IconOnly
                    checkable: true
                    checked: page.searchAll
                    QQC2.ToolTip.text: "Search across every state table"
                    QQC2.ToolTip.visible: hovered
                    onClicked: {
                        page.searchAll = checked
                        if (checked) page.runGlobalSearch()
                    }
                }
            }

            // ---- the results of the search across all tables ----
            QQC2.ScrollView {
                visible: page.searchAll && search.text.length > 1
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(page.height * 0.5,
                                                 Kirigami.Units.gridUnit * 18)
                clip: true
                ListView {
                    model: page.globalHits.tables || []
                    reuseItems: true
                    delegate: QQC2.ItemDelegate {
                        required property var modelData
                        required property int index
                        width: ListView.view.width
                        height: Kirigami.Units.gridUnit * 3
                        onClicked: page.openHit(modelData)
                        background: Rectangle {
                            color: index % 2 ? Qt.alpha(Kirigami.Theme.textColor, 0.03)
                                             : "transparent"
                        }
                        contentItem: RowLayout {
                            spacing: Kirigami.Units.smallSpacing
                            Kirigami.Icon {
                                source: modelData.icon || "view-list-details"
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                QQC2.Label {
                                    text: modelData.title
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                QQC2.Label {
                                    text: (modelData.columns || []).join(", ")
                                    opacity: 0.6
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                    font.family: "monospace"
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                }
                            }
                            QQC2.Label {
                                text: modelData.n
                                opacity: 0.75
                                horizontalAlignment: Text.AlignRight
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 3
                            }
                        }
                    }
                }
            }

            // selection helpers
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing
                visible: page.filteredRows.length > 0
                QQC2.ToolButton {
                    text: "Select page"
                    icon.name: "edit-select-all"
                    onClicked: page.selRows = page.pagedRows.slice()
                }
                QQC2.ToolButton {
                    text: "Select all (" + page.filteredRows.length + ")"
                    icon.name: "edit-select-all-layers"
                    onClicked: page.selRows = page.filteredRows.slice()
                }
                QQC2.ToolButton {
                    text: "Clear"
                    icon.name: "edit-clear"
                    visible: page.selRows.length > 0
                    onClicked: page.selRows = []
                }
                Item { Layout.fillWidth: true }
            }

            // selected row actions
            RowLayout {
                visible: page.selRows.length > 0
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing
                QQC2.Label {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    opacity: 0.7
                    text: page.selRows.length === 1
                          ? "Selected: " + page.visibleCols.slice(0, 3)
                                .map(c => page.selRows[0][c]).filter(v => v).join(" · ")
                          : "Selected: " + page.selRows.length + " rows " +
                            "(Ctrl/Shift+click to extend)"
                }
                QQC2.Button {
                    text: "Explore"
                    icon.name: "view-list-tree"
                    visible: page.cur && page.cur.name === "processes" &&
                             page.selRows.length === 1
                    onClicked: root.pageStack.layers.push(
                        Qt.resolvedUrl("ProcessPage.qml"),
                        { pid: String(page.selRows[0].pid) })
                }
                QQC2.Button {
                    text: "Edit"
                    icon.name: "document-edit"
                    visible: page.selRows.length === 1
                    onClicked: editDialog.openFor(page.selRows[0])
                }
            }

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
                        Row {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            Item { width: Kirigami.Units.smallSpacing; height: 1 }
                            Repeater {
                                model: page.groupBy
                                delegate: QQC2.Label {
                                    required property var modelData
                                    width: Kirigami.Units.gridUnit * 8
                                    height: parent.height
                                    verticalAlignment: Text.AlignVCenter
                                    leftPadding: Kirigami.Units.smallSpacing
                                    text: modelData
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                            }
                        }
                        QQC2.Label {
                            anchors.right: parent.right
                            anchors.rightMargin: Kirigami.Units.largeSpacing
                            anchors.verticalCenter: parent.verticalCenter
                            text: "count"
                            font.bold: true
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
                                height: Kirigami.Units.gridUnit * 2.3
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
                                    color: gRow.highlighted
                                           ? Qt.alpha(Kirigami.Theme.highlightColor, 0.20)
                                           : (gRow.index % 2 === 0
                                              ? Kirigami.Theme.backgroundColor
                                              : Kirigami.Theme.alternateBackgroundColor)
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
                                        delegate: QQC2.Label {
                                            required property var modelData
                                            Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                                            leftPadding: Kirigami.Units.smallSpacing
                                            rightPadding: Kirigami.Units.largeSpacing
                                            text: String(modelData) === "" ? "(empty)"
                                                                          : String(modelData)
                                            opacity: String(modelData) === "" ? 0.5 : 1
                                            elide: Text.ElideRight
                                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        }
                                    }
                                    Item { Layout.fillWidth: true }
                                    QQC2.Label {
                                        text: modelData.n
                                        opacity: 0.75
                                        horizontalAlignment: Text.AlignRight
                                        rightPadding: Kirigami.Units.largeSpacing
                                        Layout.preferredWidth: Kirigami.Units.gridUnit * 5
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
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

            // table
            Flickable {
                id: hflick
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
                    model: page.pagedRows
                    // delegate recycling: rows are rebuilt on every
                    // refresh, and without reuse the view stutters
                    reuseItems: true
                    clip: true
                    headerPositioning: ListView.OverlayHeader
                    QQC2.ScrollBar.vertical: QQC2.ScrollBar {}

                    header: Rectangle {
                        z: 3
                        width: tableView.width
                        height: hcolumn.implicitHeight + Kirigami.Units.smallSpacing * 2
                        color: Kirigami.Theme.alternateBackgroundColor
                        Column {
                        id: hcolumn
                        anchors.verticalCenter: parent.verticalCenter
                        Row {
                            id: headerRow
                            QQC2.CheckBox {   // select the whole page
                                width: Kirigami.Units.gridUnit * 2
                                tristate: true
                                checkState: page.selRows.length === 0 ? Qt.Unchecked
                                            : page.pagedRows.every(r => page.isSel(r))
                                              ? Qt.Checked : Qt.PartiallyChecked
                                onClicked: {
                                    if (page.pagedRows.every(r => page.isSel(r)))
                                        page.selRows = []
                                    else
                                        page.selRows = page.pagedRows.slice()
                                }
                            }
                            Repeater {
                                model: page.visibleCols
                                Item {
                                    width: page.colWidth(modelData)
                                    height: hlbl.implicitHeight
                                    property string col: modelData
                                    QQC2.Label {
                                        id: hlbl
                                        anchors.fill: parent
                                        anchors.rightMargin: 10
                                        leftPadding: Kirigami.Units.smallSpacing
                                        text: col + (page.sortCol === col
                                                     ? (page.sortAsc ? "  ↑" : "  ↓") : "")
                                        font.bold: true
                                        elide: Text.ElideRight
                                    }
                                    MouseArea {   // a click sorts
                                        anchors.fill: parent
                                        anchors.rightMargin: 14
                                        onClicked: page.toggleSort(col)
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
                                        onPressed: m => { sx = m.x; sw = page.colWidth(col) }
                                        onPositionChanged: m => {
                                            if (pressed) page.setColWidth(col, sw + (m.x - sx))
                                        }
                                        onReleased: page.persistWidths()
                                    }
                                    Kirigami.Separator {
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        anchors.bottom: parent.bottom
                                    }
                                }
                            }
                        }
                        // THE PER-COLUMN FILTER ROW WAS REMOVED: the selection is
                        // set by the query bar (principle 17: one mechanism)

                        }
                        Kirigami.Separator {
                            anchors.bottom: parent.bottom
                            width: parent.width
                        }
                    }

                    delegate: QQC2.ItemDelegate {
                        id: rowDel
                        property var rowData: modelData
                        width: tableView.width
                        highlighted: page.isSel(rowData)
                        // zebra: white/grey + a bottom border on the row
                        background: Rectangle {
                            color: rowDel.highlighted
                                   ? Qt.alpha(Kirigami.Theme.highlightColor, 0.20)
                                   : index % 2 === 0
                                     ? Kirigami.Theme.backgroundColor
                                     : Kirigami.Theme.alternateBackgroundColor
                            Kirigami.Separator {
                                anchors.bottom: parent.bottom
                                width: parent.width
                                opacity: 0.35
                            }
                            // THE SEVERITY STRIPE ON THE LEFT, as in the event feed:
                            // what matters is visible without reading the columns
                            Rectangle {
                                anchors { left: parent.left; top: parent.top
                                          bottom: parent.bottom }
                                width: 4
                                visible: page.rowAccent(rowDel.rowData) !== ""
                                color: page.rowAccent(rowDel.rowData) || "transparent"
                                opacity: 0.9
                            }
                        }
                        property int rowIndex: index
                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton
                            onClicked: m => page.clickRow(rowDel.rowData,
                                                          rowDel.rowIndex,
                                                          m.modifiers)
                            onDoubleClicked: editDialog.openFor(rowDel.rowData)
                        }
                        contentItem: Row {
                            QQC2.CheckBox {
                                width: Kirigami.Units.gridUnit * 2
                                anchors.verticalCenter: parent.verticalCenter
                                checked: page.isSel(rowDel.rowData)
                                onClicked: page.clickRow(rowDel.rowData,
                                                         rowDel.rowIndex,
                                                         Qt.ControlModifier)
                            }
                            // ONE OBJECT PER CELL. There used to be three - a
                            // wrapper Item, a Label and a Separator - so a page
                            // of 50 rows by 19 columns created about 2850 items
                            // and every page change froze for 0.4 s. The column
                            // separators are now drawn once for the whole table
                            // (see the overlay below the list), not per cell.
                            Repeater {
                                model: page.visibleCols
                                QQC2.Label {
                                    width: page.colWidth(modelData)
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: String(rowDel.rowData[modelData] ?? "")
                                    elide: Text.ElideRight
                                    leftPadding: Kirigami.Units.smallSpacing
                                    rightPadding: Kirigami.Units.smallSpacing
                                }
                            }
                        }
                    }

                    // the column separators for the whole table: one line per
                    // column instead of one per cell
                    Item {
                        anchors.fill: parent
                        z: 2
                        Repeater {
                            model: page.visibleCols
                            Kirigami.Separator {
                                required property int index
                                x: {
                                    var w = Kirigami.Units.gridUnit * 2
                                    for (var i = 0; i <= index; i++)
                                        w += page.colWidth(page.visibleCols[i])
                                    return w - 1
                                }
                                y: 0
                                height: tableView.height
                                opacity: 0.25
                            }
                        }
                    }

                    Kirigami.PlaceholderMessage {
                        anchors.centerIn: parent
                        visible: tableView.count === 0
                        text: "Empty"
                    }
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
                    Repeater {
                        model: page.lastSel && page.cur ? page.cur.columns : []
                        delegate: ColumnLayout {
                            spacing: 1
                            Layout.fillWidth: true
                            visible: String(page.lastSel[modelData] ?? "") !== ""
                            property bool sensitive: page.sensitiveCols.includes(modelData)
                            property bool revealed: false
                            RowLayout {
                                Layout.fillWidth: true
                                QQC2.Label {
                                    text: modelData
                                    opacity: 0.55
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    Layout.fillWidth: true
                                }
                                QQC2.ToolButton {   // the eye for secret fields
                                    visible: parent.parent.sensitive
                                    icon.name: parent.parent.revealed ? "view-hidden" : "view-visible"
                                    implicitHeight: Kirigami.Units.gridUnit * 1.4
                                    implicitWidth: Kirigami.Units.gridUnit * 1.4
                                    onClicked: parent.parent.revealed = !parent.parent.revealed
                                }
                            }
                            QQC2.TextArea {
                                Layout.fillWidth: true
                                readOnly: true
                                wrapMode: TextEdit.Wrap
                                text: (parent.sensitive && !parent.revealed)
                                      ? "•••••••••  (click the eye to reveal)"
                                      : String(page.lastSel[modelData] ?? "")
                                font.family: (page.longCols.includes(modelData)
                                              || parent.sensitive)
                                             ? "monospace" : Kirigami.Theme.defaultFont.family
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                background: Rectangle {
                                    color: Kirigami.Theme.alternateBackgroundColor
                                    radius: 4
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

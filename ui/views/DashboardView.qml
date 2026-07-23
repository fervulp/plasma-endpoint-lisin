import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components/Fmt.js" as Fmt
import "../components"
import "../pages"
import "."

// The "State" dashboard: in one window what is otherwise scattered across the
// tables - the process launch graph (as in a SIEM/EDR), consumption,
// dependencies, network.
Item {
    id: view

    property var d: ({ tiles: [],
                       top_rss: [], top_cpu: [], top_deps: [], top_dest: [],
                       exposure: [] })
    property var selNode: null
    property var deep: null          // the EDR breakdown of the selected process
    property var plinks: null        // the links around the selected process
    // ---- THE PIVOT: the graph anchor (any entity) + the expanded categories ----
    property string anchorKind: "process"
    property string anchorVal: ""
    property var expandedCats: []    // which categories are expanded
    property var pivotStack: []      // the pivot breadcrumbs

    function rebuildGraph() {
        if (view.anchorVal === "") return
        view.plinks = view.anchorKind === "process"
            ? backend.processLinks(view.anchorVal, view.expandedCats)
            : backend.anchorGraph(view.anchorKind, view.anchorVal, view.expandedCats)
    }
    // arrival from "Events": show this process in the graph
    Connections {
        target: root
        function onProcessFocusChanged() {
            if (!root.processFocus) return
            view.setAnchor("process", String(root.processFocus.pid), false)
            openTimer.restart()
        }
    }
    function setAnchor(kind, val, pushCrumb) {
        if (pushCrumb && view.anchorVal !== "")
            view.pivotStack = view.pivotStack.concat(
                [{ kind: view.anchorKind, val: view.anchorVal }])
        view.anchorKind = kind
        view.anchorVal = String(val)
        view.expandedCats = []
        view.sideNode = null; view.sideInfo = null
        // THE PROCESS PANEL is only for a process; otherwise we clear it so as not
        // to show the previous process under a new anchor (port/application/user)
        view.deep = kind === "process" ? backend.processDeep(String(val)) : null
        view.rebuildGraph()
    }
    function popPivot(i) {
        var s = view.pivotStack.slice(0, i)
        var target = view.pivotStack[i]
        view.pivotStack = s
        view.anchorKind = target.kind; view.anchorVal = target.val
        view.expandedCats = []
        view.sideNode = null; view.sideInfo = null
        view.deep = target.kind === "process"
            ? backend.processDeep(target.val) : null
        view.rebuildGraph()
    }
    function anchorKindOf(n) {
        var t = n.table
        return t === "processes" ? "process"
             : t === "applications" ? "application"
             : t === "ports" ? "port"
             : t === "users" ? "user"
             : (t === "app_config" || t === "config_files") ? "config"
             : t === "open_files" ? "open_file" : ""
    }
    // ---- graph handlers: shared by the embedded and the full-screen canvas ----
    function graphNodeActivated(n) {
        view.sideNode = n
        // EVERYTHING about the object of a node: for an event all of its fields by
        // taxonomy, for a config/service/package its own row + the related ones
        view.sideInfo = backend.nodeInfo(n)
    }
    function graphToggle(cat) {
        var e = view.expandedCats.slice()
        var i = e.indexOf(cat)
        if (i >= 0) e.splice(i, 1); else e.push(cat)
        view.expandedCats = e
        view.rebuildGraph()
    }
    function graphAnchor(n) {
        var k = view.anchorKindOf(n)
        if (k) view.setAnchor(k, n.val, true)
    }
    function graphDrill(action, n) {
        if (action === "state" && n.table && n.table !== "events")
            root.focusState(n.table, n.col, n.val)
        else if (action === "events") {
            var w = view.eventsWhere(n)
            if (w !== "") root.focusEvents(w)
        } else if (action === "whois") {
            var wi = backend.whoisLookup(n.val)
            view.sideNode = n
            var rows = []
            for (var key in wi)
                if (wi[key] && key !== "raw") rows.push({ k: key, v: String(wi[key]) })
            view.sideInfo = { sections: [{ title: "WHOIS " + n.val, rows: rows }] }
        }
    }
    function openFullGraph() { fullGraph.open() }
    function eventsWhere(n) {
        // on an event node val is the ACTION, while the pid is a separate field
        if (n.category === "events") {
            var parts = []
            if (n.pid) parts.push("process_pid='" + n.pid + "'")
            if (n.val) parts.push("event_action='" + n.val + "'")
            return parts.join(" AND ")
        }
        if (n.table === "processes") return "process_pid='" + n.val + "'"
        if (n.table === "open_files" || n.table === "app_config"
            || n.table === "config_files") return "file_path='" + n.val + "'"
        if (n.table === "users") return "user_name='" + n.val + "'"
        return ""
    }
    property var sideNode: null      // the node selected on the canvas
    property var sideInfo: null      // everything known about it from the state
    property bool busy: false
    // an on-demand collection is running
    property bool collecting: false
    Connections {
        target: backend
        function onCollectingChanged() {
            view.collecting = backend.isCollecting()
            if (!view.collecting) view.refresh()
        }
    }
    property var collapsed: ({})     // pid -> the branch is collapsed
    function toggleCollapse(pid) {
        var c = Object.assign({}, collapsed)
        if (c[pid]) delete c[pid]; else c[pid] = true
        collapsed = c
    }
    // ---- PROCESS TABLE GEOMETRY AND FORMATTING ----
    // One source of truth for the columns: the header and every row read the
    // same list, so widths can never drift apart.
    readonly property var procCols: [
        { k: "pid",      t: "PID",     w: 4.0, mono: true },
        { k: "user",     t: "User",    w: 6.0 },
        { k: "rss",      t: "Memory",  w: 5.0, bar: true },
        { k: "subtree",  t: "Branch",  w: 5.0 },
        { k: "cpu",      t: "CPU",     w: 4.2, bar: true },
        { k: "elapsed",  t: "Uptime",  w: 4.6, mono: true },
        { k: "files",    t: "Files",   w: 3.6 },
        { k: "ports",    t: "Sockets", w: 4.2 }
    ]
    // filtering → the list is flat, so tree indent must not be applied
    readonly property bool filtering: procFilter.text.trim() !== ""

    function fmtMB(v) {
        var n = Number(v) || 0
        if (n <= 0) return ""
        return n >= 1024 ? (n / 1024).toFixed(1) + " GB" : Math.round(n) + " MB"
    }
    function cellText(p, k) {
        if (k === "pid") return String(p.pid)
        if (k === "user") return p.user || ""
        if (k === "rss") return view.fmtMB(p.rss)
        if (k === "subtree") return (p.subtree || 0) > (p.rss || 0)
                                    ? view.fmtMB(p.subtree) : ""
        if (k === "cpu") return (p.cpu || 0) > 0 ? p.cpu + "%" : ""
        if (k === "elapsed") return p.elapsed || ""
        if (k === "files") return (p.files || 0) > 0 ? String(p.files) : ""
        if (k === "ports") {
            var n = (p.ports || 0) + (p.unix || 0)
            return n > 0 ? String(n) : ""
        }
        return ""
    }
    // share of the heaviest row — the bar is comparative, not absolute
    function barFrac(p, k) {
        var v = k === "rss" ? (p.rss || 0) : (p.cpu || 0)
        var max = k === "rss" ? (view.d.max_rss || 0) : 100
        if (!(v > 0) || !(max > 0)) return 0
        return Math.min(1, v / max)
    }

    // how "interesting" a row is: sockets, ports, exposure, risk.
    // We return a background colour - the eye immediately sees where to look.
    function rowTint(p) {
        if (p.exposure === "OPEN (exposed)") return Qt.rgba(0.90, 0.30, 0.24, 0.20)
        if (p.risk >= 5) return Qt.rgba(0.90, 0.30, 0.24, 0.13)
        if (p.risk >= 3) return Qt.rgba(0.90, 0.49, 0.13, 0.13)
        if (p.ports > 0) return Qt.rgba(0.16, 0.50, 0.73, 0.13)
        if (p.unix > 0) return Qt.rgba(0.64, 0.28, 0.73, 0.10)
        if (p.risk > 0) return Qt.rgba(0.95, 0.77, 0.06, 0.10)
        return "transparent"
    }

    // ---- WHAT THE LEFT LIST SHOWS ----
    // A dashboard does not have to be only about processes: the same list picks
    // applications, ports, users, configs, open files. A click on a row builds
    // the FULL graph around that entity (processes will be there too - they
    // arrive through the links).
    property string listKind: "process"
    property var listItems: []
    function setListKind(k) {
        view.listKind = k
        if (k === "process") { view.listItems = []; return }
        var r = backend.anchorList(k)
        view.listItems = (r && r.items) ? r.items : []
    }
    // the same filter as for processes
    property var listShown: {
        var q = procFilter.text.trim().toLowerCase()
        var src = view.listItems || []
        if (q === "") return src
        var out = []
        for (var i = 0; i < src.length; i++) {
            var it = src[i]
            if ((String(it.val) + " " + String(it.sub)).toLowerCase().indexOf(q) >= 0)
                out.push(it)
        }
        return out
    }

    // The full list of processes with facets. Without a facet it is TREE order
    // (parent -> children, the indent shows the origin); with a facet it is by
    // RISK, so that something small but dangerous is at the top.
    property var procShown: {
        var t = (d && d.tree) ? d.tree : []
        var q = procFilter.text.trim().toLowerCase()
        var out = []
        for (var i = 0; i < t.length; i++) {
            var p = t[i]
            // THE SEARCH ALSO COVERS ADDRESSES: "198.51.100.7" or "993" finds the
            // process that has such a session or such a listening port
            if (q !== "" && (p.name + " " + p.command + " " + p.user + " "
                             + p.pid + " " + (p.addrs || ""))
                              .toLowerCase().indexOf(q) < 0) continue
            out.push(p)
        }
        // WHILE SEARCHING we do NOT apply collapsing: the found process lies deep
        // (btop was at the 4th level), and if a collapsed node happened to be
        // above it in the list, the match simply vanished - the search "found
        // nothing" although the process is there.
        if (q !== "") return out

        // tree mode: hide the descendants of collapsed nodes. The tree is in DFS
        // order, so it is enough to remember the depth of the collapsed node and
        // skip everything deeper until we return to the same level.
        var res = [], skip = -1
        for (var j = 0; j < out.length; j++) {
            var p2 = out[j]
            if (skip >= 0 && p2.depth > skip) continue
            skip = -1
            res.push(p2)
            if (collapsed[p2.pid] && p2.children > 0) skip = p2.depth
        }
        return res
    }

    // A COLLAPSIBLE SIDEBAR SECTION - the same logic as the graph blocks:
    // a header with a counter, a click expands it and shows ALL the rows.
    component InfoSection: ColumnLayout {
        id: isec
        property string title
        property int count: 0
        property bool shown: false
        default property alias body: ibody.data
        Layout.fillWidth: true
        spacing: 1
        Kirigami.Separator { Layout.fillWidth: true }
        QQC2.ItemDelegate {
            Layout.fillWidth: true
            implicitHeight: Kirigami.Units.gridUnit * 1.4
            onClicked: isec.shown = !isec.shown
            contentItem: RowLayout {
                spacing: Kirigami.Units.smallSpacing
                Kirigami.Icon {
                    source: isec.shown ? "go-down" : "go-next"
                    implicitWidth: Kirigami.Units.iconSizes.small
                    implicitHeight: Kirigami.Units.iconSizes.small
                }
                QQC2.Label {
                    Layout.fillWidth: true
                    text: isec.title + "  (" + isec.count + ")"
                    font.bold: true
                    elide: Text.ElideRight
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
            }
        }
        ColumnLayout {
            id: ibody
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.largeSpacing
            spacing: 1
            visible: isec.shown
        }
    }

    // a key-value pair on one line
    component KV: RowLayout {
        property string k
        property string v
        visible: v !== ""
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing
        QQC2.Label {
            text: k; opacity: 0.6
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            Layout.preferredWidth: Kirigami.Units.gridUnit * 6
        }
        QQC2.Label {
            text: v; Layout.fillWidth: true
            elide: Text.ElideMiddle
            font.pointSize: Kirigami.Theme.smallFont.pointSize
        }
    }
    // a mini section with a list of monospaced lines
    component Mini: ColumnLayout {
        property string heading
        property var lines: []
        Layout.fillWidth: true
        Layout.preferredWidth: 1
        Layout.alignment: Qt.AlignTop
        spacing: 1
        visible: lines.length > 0
        QQC2.Label {
            text: heading + "  (" + lines.length + ")"
            font.bold: true
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            opacity: 0.8
        }
        Repeater {
            model: parent.lines
            QQC2.Label {
                Layout.fillWidth: true
                text: modelData
                elide: Text.ElideRight
                font.family: "monospace"
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                opacity: 0.85
            }
        }
    }

    // the geometry of the graph

    property real lastRefresh: 0
    property bool stale: false
    readonly property int refreshMinMs: 6000
    // when the page becomes visible again, catch up once
    onVisibleChanged: if (visible && stale) refresh()

    function refresh() {
        view.busy = true
        // WE REMEMBER THE POSITION: the model is replaced wholesale, and the list
        // jumped to the start on every tick - scrolling a long tree was impossible.
        var keepY = procList ? procList.contentY : 0
        view.d = backend.dashboardState()
        view.lastRefresh = Date.now()
        view.stale = false
        view.busy = false
        // THE GRAPH IMMEDIATELY, without a mandatory click: the graph card used to
        // be hidden until the first process was chosen, and that read as "there
        // are no graphs". We take the most notable process (the highest risk).
        if (view.anchorVal === "" && view.d && view.d.tree && view.d.tree.length) {
            var best = view.d.tree[0]
            for (var i = 0; i < view.d.tree.length; i++)
                if ((view.d.tree[i].risk || 0) > (best.risk || 0)) best = view.d.tree[i]
            view.setAnchor("process", best.pid, false)
        }
        if (procList) {
            // restore it after the ListView has recomputed the height
            restoreScroll.target = keepY
            restoreScroll.restart()
        }
    }
    Timer {
        id: restoreScroll
        property real target: 0
        interval: 1
        onTriggered: if (procList) procList.contentY =
                     Math.min(target, Math.max(0, procList.contentHeight - procList.height))
    }
    Component.onCompleted: {
        refresh()
        // we came from an event - put its process into the centre of the graph at once
        if (root.processFocus) {
            view.setAnchor("process", String(root.processFocus.pid), false)
            openTimer.start()
        }
    }
        // the graph is opened on the next frame: before that it is not built yet
    Timer {
        id: openTimer
        interval: 250
        onTriggered: view.openFullGraph()
    }
    Connections {
        target: backend
        // REFRESH ONLY WHEN SHOWN. The page is kept alive; a hidden one
        // still receives every tick, and recomputing a dashboard the user is not
        // looking at burns CPU and stalls the animation of the page they ARE
        // opening. We mark it stale and catch up when it becomes visible.
        function onStateReady(s) { if (view.visible) view.refresh(); else view.stale = true }
    }

    component Bars: ColumnLayout {
        property string heading
        property var items: []
        property string suffix: ""
        Layout.fillWidth: true
        Layout.preferredWidth: 1
        spacing: 2
        Kirigami.Heading { level: 4; text: heading }
        Kirigami.Separator { Layout.fillWidth: true }
        Repeater {
            model: items
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                QQC2.Label {
                    text: modelData.name + (modelData.kind ? "  (" + modelData.kind + ")" : "")
                    elide: Text.ElideRight
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 9
                }
                Rectangle {
                    Layout.fillWidth: true
                    height: Kirigami.Units.gridUnit * 0.8
                    radius: 2
                    color: Qt.alpha(Kirigami.Theme.textColor, 0.08)
                    Rectangle {
                        anchors.left: parent.left
                        height: parent.height
                        radius: 2
                        color: Kirigami.Theme.highlightColor
                        width: {
                            var mx = 0
                            for (var i = 0; i < items.length; i++)
                                mx = Math.max(mx, items[i].value)
                            return mx > 0 ? parent.width * (modelData.value / mx) : 0
                        }
                    }
                }
                QQC2.Label {
                    text: modelData.value + suffix
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    opacity: 0.75
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                    horizontalAlignment: Text.AlignRight
                }
            }
        }
        QQC2.Label {
            visible: items.length === 0
            opacity: 0.5; text: "no data"
            font.pointSize: Kirigami.Theme.smallFont.pointSize
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- the header: choosing a dashboard ----
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing
            // the dashboard chooser was removed: it had a single item
            Item { Layout.fillWidth: true }
            QQC2.BusyIndicator { running: view.busy; visible: view.busy
                                 Layout.preferredHeight: Kirigami.Units.gridUnit }
            QQC2.ToolButton {
                icon.name: "view-refresh"; onClicked: view.refresh()
                QQC2.ToolTip.text: "Re-read the collected data"
                QQC2.ToolTip.visible: hovered
            }
            // COLLECT NOW - run every state source without waiting for its
            // schedule (some sources have an interval of hours).
            QQC2.ToolButton {
                icon.name: "download"
                text: view.collecting ? "Collecting…" : "Collect now"
                display: QQC2.AbstractButton.TextBesideIcon
                enabled: !view.collecting
                QQC2.ToolTip.text: "Run every state source right now"
                QQC2.ToolTip.visible: hovered
                onClicked: { view.collecting = true; backend.collectNow() }
            }
        }

        QQC2.ScrollView {
            id: scroller
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: availableWidth

            ColumnLayout {
                width: scroller.availableWidth
                spacing: Kirigami.Units.largeSpacing

                // ---- tiles ----
                Flow {
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.smallSpacing
                    Layout.rightMargin: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing
                    Repeater {
                        model: view.d.tiles
                        Kirigami.AbstractCard {
                            id: tile
                            required property var modelData
                            required property int index
                            width: Kirigami.Units.gridUnit * 9
                            // the tiles rise into place one after another when the
                            // dashboard loads - a staggered fade, all on the render
                            // thread
                            opacity: 0
                            Component.onCompleted: tileIn.start()
                            SequentialAnimation {
                                id: tileIn
                                PauseAnimation { duration: Math.min(tile.index, 6) * 40 }
                                ParallelAnimation {
                                    OpacityAnimator { target: tile; from: 0; to: 1
                                        duration: Kirigami.Units.longDuration
                                        easing.type: Easing.OutCubic }
                                    NumberAnimation { target: tile; property: "y"
                                        from: Kirigami.Units.gridUnit; to: 0
                                        duration: Kirigami.Units.longDuration
                                        easing.type: Easing.OutCubic }
                                }
                            }
                            contentItem: RowLayout {
                                spacing: Kirigami.Units.smallSpacing
                                Kirigami.Icon {
                                    source: modelData.icon
                                    Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                                    Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                                    color: modelData.alert ? "#e74c3c" : Kirigami.Theme.textColor
                                }
                                ColumnLayout {
                                    spacing: 0
                                    Kirigami.Heading {
                                        level: 2; text: modelData.value
                                        color: modelData.alert ? "#e74c3c"
                                                               : Kirigami.Theme.textColor
                                    }
                                    QQC2.Label {
                                        text: modelData.label; opacity: 0.65
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                }
                            }
                        }
                    }
                }

                // ---- ALL PROCESSES: the tree + a risk score ----
                // The dangerous thing is usually small, so "the top by memory" is no
                // good: we show ALL processes as a tree and lift them by RISK.
                Kirigami.AbstractCard {
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.smallSpacing
                    Layout.rightMargin: Kirigami.Units.smallSpacing
                    contentItem: ColumnLayout {
                        spacing: Kirigami.Units.smallSpacing
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing
                            Kirigami.Heading {
                                level: 3
                                text: listKindBox.currentIndex >= 0
                                      ? listKindBox.model[listKindBox.currentIndex].t
                                      : "Processes"
                            }
                            // THE LIST SOURCE SWITCH
                            QQC2.ComboBox {
                                id: listKindBox
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 10
                                model: [{ k: "process", t: "Processes" },
                                        { k: "application", t: "Applications" },
                                        { k: "port", t: "Ports" },
                                        { k: "user", t: "Users" },
                                        { k: "config", t: "Configs" },
                                        { k: "open_file", t: "Open Files" }]
                                textRole: "t"
                                onActivated: view.setListKind(model[currentIndex].k)
                            }
                            QQC2.Label {
                                visible: view.listKind !== "process"
                                opacity: 0.6
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                text: view.listShown.length + " · click to build a graph"
                            }
                            QQC2.Label {
                                visible: view.listKind === "process"
                                opacity: 0.6
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                // AN HONEST COUNTER: there used to be fewer rows
                                // than processes because identical children were
                                // collapsed into "name xN" - and "214 of 439" read
                                // as "half the processes are lost".
                                // the tree is complete: as many rows as processes,
                                // nothing is collapsed and nothing is hidden
                                text: view.procShown.length + " processes"
                                      + (view.d.proc_total
                                         && view.procShown.length < view.d.proc_total
                                         ? " (of " + view.d.proc_total + ")" : "")
                                      + "   ·   " + (view.d.risky_count || 0) + " at risk"
                            }
                            Item { Layout.fillWidth: true }
                            Kirigami.SearchField {
                                id: procFilter
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 14
                                placeholderText: view.listKind === "process"
                                    ? "name, PID, user or IP address…" : "Filter…"
                            }
                        }

                        Kirigami.Separator { Layout.fillWidth: true }

                        // COLUMN HEADER. Widths come from view.colW so the
                        // header and every row use the SAME geometry — this is
                        // what keeps numbers aligned and stops the selection
                        // from shifting when the list changes.
                        RowLayout {
                            visible: view.listKind === "process"
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.smallSpacing
                            Layout.rightMargin: Kirigami.Units.smallSpacing
                            spacing: Kirigami.Units.smallSpacing
                            QQC2.Label {
                                Layout.fillWidth: true
                                text: "Process"
                                opacity: 0.6
                                font.bold: true
                                font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                            }
                            Repeater {
                                model: view.procCols
                                delegate: QQC2.Label {
                                    required property var modelData
                                    Layout.preferredWidth: Kirigami.Units.gridUnit * modelData.w
                                    text: modelData.t
                                    opacity: 0.6
                                    font.bold: true
                                    horizontalAlignment: Text.AlignRight
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                }
                            }
                        }
                        Kirigami.Separator {
                            Layout.fillWidth: true
                            visible: view.listKind === "process"
                        }

                        ListView {
                            id: procList
                            visible: view.listKind === "process"
                            Layout.fillWidth: true
                            Layout.preferredHeight: Kirigami.Units.gridUnit * 18
                            clip: true
                            model: view.procShown
                            // delegate recycling: without it every tick rebuilt
                            // ~470 delegates and the view stuttered
                            reuseItems: true
                            cacheBuffer: Kirigami.Units.gridUnit * 40
                            QQC2.ScrollBar.vertical: QQC2.ScrollBar { id: procScroll }

                            delegate: QQC2.ItemDelegate {
                                id: procRow
                                required property var modelData
                                width: ListView.view.width
                                height: Kirigami.Units.gridUnit * 1.7
                                highlighted: view.selNode && view.selNode.pid === modelData.pid
                                onClicked: {
                                    view.selNode = modelData
                                    view.pivotStack = []
                                    view.setAnchor("process", modelData.pid, false)
                                }
                                background: Rectangle {
                                    color: procRow.highlighted
                                           ? Qt.alpha(Kirigami.Theme.highlightColor, 0.30)
                                           : (procRow.hovered
                                              ? Qt.alpha(Kirigami.Theme.textColor, 0.06)
                                              : view.rowTint(procRow.modelData))
                                    // risk reads as a left accent bar, so type
                                    // and severity stay visually separate
                                    Rectangle {
                                        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                                        width: 3
                                        visible: procRow.modelData.risk > 0
                                        color: procRow.modelData.risk >= 5 ? "#e74c3c"
                                             : procRow.modelData.risk >= 3 ? "#e67e22" : "#f1c40f"
                                    }
                                }

                                contentItem: RowLayout {
                                    spacing: Kirigami.Units.smallSpacing

                                    // Indent shows tree depth. While filtering the
                                    // list is flat, so the indent is dropped — it
                                    // used to stay and pushed the row sideways.
                                    Item {
                                        Layout.preferredWidth: view.filtering ? 0
                                            : Math.min(procRow.modelData.depth, 8)
                                              * Kirigami.Units.gridUnit
                                    }
                                    // Fixed-width slot: the chevron and its empty
                                    // placeholder are the SAME width, so rows with
                                    // and without children line up exactly.
                                    Item {
                                        Layout.preferredWidth: Kirigami.Units.gridUnit * 1.3
                                        Layout.preferredHeight: Kirigami.Units.gridUnit * 1.3
                                        visible: !view.filtering
                                        QQC2.ToolButton {
                                            anchors.fill: parent
                                            visible: procRow.modelData.children > 0
                                            padding: 0
                                            icon.name: view.collapsed[procRow.modelData.pid]
                                                       ? "go-next-symbolic" : "go-down-symbolic"
                                            onClicked: view.toggleCollapse(procRow.modelData.pid)
                                        }
                                    }
                                    Kirigami.Icon {
                                        source: procRow.modelData.kernel ? "cpu" : "system-run"
                                        opacity: procRow.modelData.kernel ? 0.45 : 0.75
                                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                    }
                                    QQC2.Label {
                                        Layout.fillWidth: true
                                        text: procRow.modelData.name
                                        elide: Text.ElideRight
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                    // network badge — only when it means something
                                    Rectangle {
                                        visible: procRow.modelData.external
                                        Layout.preferredWidth: extLbl.implicitWidth + 8
                                        Layout.preferredHeight: extLbl.implicitHeight + 2
                                        radius: 3
                                        color: Qt.alpha("#e67e22", 0.25)
                                        QQC2.Label {
                                            id: extLbl
                                            anchors.centerIn: parent
                                            text: "external"
                                            color: "#e67e22"
                                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 2
                                        }
                                    }

                                    Repeater {
                                        model: view.procCols
                                        delegate: Item {
                                            required property var modelData
                                            Layout.preferredWidth: Kirigami.Units.gridUnit * modelData.w
                                            Layout.preferredHeight: Kirigami.Units.gridUnit * 1.2
                                            // memory and CPU get a subtle bar so
                                            // the heavy rows are findable by eye
                                            Rectangle {
                                                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                                                visible: modelData.bar === true
                                                         && view.barFrac(procRow.modelData, modelData.k) > 0
                                                width: parent.width * view.barFrac(procRow.modelData, modelData.k)
                                                height: Kirigami.Units.gridUnit * 0.85
                                                radius: 2
                                                color: Qt.alpha(Kirigami.Theme.highlightColor, 0.20)
                                            }
                                            QQC2.Label {
                                                anchors.fill: parent
                                                horizontalAlignment: Text.AlignRight
                                                verticalAlignment: Text.AlignVCenter
                                                rightPadding: 2
                                                text: view.cellText(procRow.modelData, modelData.k)
                                                opacity: text === "" ? 0 : 0.85
                                                elide: Text.ElideRight
                                                font.family: modelData.mono === true
                                                             ? "monospace" : Kirigami.Theme.defaultFont.family
                                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // ---- THE LIST OF ENTITIES (not processes) ----
                        // Applications, ports, users, configs, open files. A click
                        // on a row builds the FULL graph around it - with the
                        // processes and all the rest of the context.
                        ListView {
                            id: entList
                            visible: view.listKind !== "process"
                            Layout.fillWidth: true
                            Layout.preferredHeight: Kirigami.Units.gridUnit * 18
                            clip: true
                            model: view.listShown
                            QQC2.ScrollBar.vertical: QQC2.ScrollBar {}
                            delegate: QQC2.ItemDelegate {
                                required property var modelData
                                width: entList.width
                                height: Kirigami.Units.gridUnit * 2.1
                                highlighted: view.anchorVal === String(modelData.val)
                                onClicked: {
                                    view.pivotStack = []
                                    view.setAnchor(view.listKind, modelData.val, false)
                                }
                                contentItem: RowLayout {
                                    spacing: Kirigami.Units.smallSpacing
                                    Kirigami.Icon {
                                        source: view.listKind === "application" ? "package-x-generic"
                                              : view.listKind === "port" ? "network-server"
                                              : view.listKind === "user" ? "user-identity"
                                              : view.listKind === "config" ? "document-properties"
                                              : "document-open"
                                        implicitWidth: Kirigami.Units.iconSizes.small
                                        implicitHeight: Kirigami.Units.iconSizes.small
                                        opacity: 0.8
                                    }
                                    ColumnLayout {
                                        spacing: 0
                                        Layout.fillWidth: true
                                        QQC2.Label {
                                            Layout.fillWidth: true
                                            text: modelData.val
                                            elide: Text.ElideMiddle
                                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        }
                                        QQC2.Label {
                                            Layout.fillWidth: true
                                            text: modelData.sub || ""
                                            visible: text !== ""
                                            opacity: 0.6
                                            elide: Text.ElideRight
                                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                        }
                                    }
                                    Kirigami.Icon {
                                        source: "distribute-graph-directed"
                                        implicitWidth: Kirigami.Units.iconSizes.small
                                        implicitHeight: Kirigami.Units.iconSizes.small
                                        opacity: 0.45
                                    }
                                }
                            }
                        }

                        Kirigami.PlaceholderMessage {
                            Layout.fillWidth: true
                            visible: view.listKind !== "process" && view.listShown.length === 0
                            text: "Nothing found"
                        }

                    }
                }


                // ---- THE GRAPH OF THE SELECTED PROCESS ----
                // The surroundings of the process: the user, the package, the
                // parent and the children, the ports, the OPEN FILES and the
                // events. A click on a node shows the details on the right; a
                // click on a process moves the graph focus onto it.
                Rectangle {
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.smallSpacing
                    Layout.rightMargin: Kirigami.Units.smallSpacing
                    Layout.preferredHeight: Kirigami.Units.gridUnit * 5
                    visible: !(view.plinks && !view.plinks.error
                               && (view.plinks.nodes || []).length > 1)
                    radius: 4
                    color: Kirigami.Theme.alternateBackgroundColor
                    QQC2.Label {
                        anchors.centerIn: parent
                        opacity: 0.6
                        horizontalAlignment: Text.AlignHCenter
                        text: "Select a process to see its graph\n"
                              + "user, package, ports, open files, events"
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.smallSpacing
                    Layout.rightMargin: Kirigami.Units.smallSpacing
                    Layout.bottomMargin: Kirigami.Units.largeSpacing
                    Layout.preferredHeight: Kirigami.Units.gridUnit * 30
                    visible: view.plinks !== null && !view.plinks.error
                             && (view.plinks.nodes || []).length > 1
                    radius: 4
                    color: Kirigami.Theme.alternateBackgroundColor

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: Kirigami.Units.smallSpacing
                        spacing: Kirigami.Units.smallSpacing

                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: 2

                            // ---- "VIEW BY" + THE PIVOT BREADCRUMBS ----
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing
                                // "View by" was removed: the source is chosen by
                                // the LIST switch on the left, one mechanism.
                                // breadcrumbs: the pivot path, a click goes back
                                Repeater {
                                    model: view.pivotStack
                                    delegate: RowLayout {
                                        required property var modelData
                                        required property int index
                                        spacing: 1
                                        QQC2.ToolButton {
                                            text: String(modelData.val).substring(0, 14)
                                            flat: true
                                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                            onClicked: view.popPivot(index)
                                        }
                                        QQC2.Label { text: "▸"; opacity: 0.4 }
                                    }
                                }
                                Item { Layout.fillWidth: true }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                QQC2.Label {
                                    font.bold: true
                                    text: view.plinks && view.plinks.anchor
                                          ? (view.plinks.anchor.label || view.anchorKind)
                                          : "Graph"
                                    elide: Text.ElideRight
                                    Layout.maximumWidth: Kirigami.Units.gridUnit * 16
                                }
                                // which element we entered the process graph
                                // through - otherwise it is unclear why clicking a
                                // port opened a process
                                QQC2.Label {
                                    visible: !!(view.plinks && view.plinks.entered_via)
                                    opacity: 0.75
                                    elide: Text.ElideMiddle
                                    Layout.maximumWidth: Kirigami.Units.gridUnit * 18
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    text: view.plinks && view.plinks.entered_via
                                          ? "← entered via " + view.plinks.entered_via.val : ""
                                }
                                QQC2.Label {
                                    opacity: 0.65
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    text: view.plinks
                                          ? (view.plinks.nodes.length + " objects · "
                                             + (view.plinks.categories
                                                ? view.plinks.categories.length + " categories" : ""))
                                          : ""
                                }
                                Item { Layout.fillWidth: true }
                                // THE TYPE LEGEND WAS REMOVED: the words "process",
                                // "event", "package" duplicated what is already
                                // visible from the node icon, the category colour
                                // stripe and the label of the ladder block.
                                QQC2.ToolButton {
                                    icon.name: "view-fullscreen"
                                    text: "Full Screen"
                                    display: QQC2.AbstractButton.TextBesideIcon
                                    QQC2.ToolTip.text: "Show the graph full screen"
                                    QQC2.ToolTip.visible: hovered
                                    onClicked: fullGraph.open()
                                }
                            }
                            GraphCanvas {
                                id: linkCanvas
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                graph: view.plinks ? view.plinks : ({ nodes: [], edges: [] })
                                onNodeActivated: function (n) { view.graphNodeActivated(n) }
                                onToggleCategory: function (cat) { view.graphToggle(cat) }
                                onAnchorRequested: function (n) { view.graphAnchor(n) }
                                onDrillRequested: function (a, n) { view.graphDrill(a, n) }
                            }
                        }

                        // ---- THE FULL PROCESS PANEL (on the right, expandable) ----
                        // A click on a process in the tree/graph -> ALL the state
                        // information about it here: how it started, the package,
                        // the open files, the sockets, the events, the children.
                        // The sections collapse; the lists scroll. Separately - the
                        // detail of the node selected on the canvas (view.sideInfo).
                        Rectangle {
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 20
                            Layout.fillHeight: true
                            visible: view.deep !== null || view.sideNode !== null
                            color: Kirigami.Theme.backgroundColor
                            radius: 4

                            QQC2.ScrollView {
                                id: sideScroll
                                anchors.fill: parent
                                anchors.margins: Kirigami.Units.smallSpacing
                                clip: true
                                contentWidth: availableWidth

                                ColumnLayout {
                                    width: sideScroll.availableWidth
                                    spacing: Kirigami.Units.smallSpacing

                                    // --- the process header ---
                                    Kirigami.Heading {
                                        Layout.fillWidth: true
                                        level: 3
                                        elide: Text.ElideRight
                                        visible: view.deep && !view.deep.error
                                        text: view.deep ? view.deep.name : ""
                                    }
                                    QQC2.Label {
                                        Layout.fillWidth: true
                                        wrapMode: Text.WordWrap
                                        opacity: 0.8
                                        visible: view.deep && !view.deep.error
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        text: view.deep
                                              ? ("pid " + view.deep.pid + " · " + view.deep.user
                                                 + " · " + view.deep.rss + " MB · CPU " + view.deep.cpu
                                                 + "% · uptime " + view.deep.elapsed)
                                              : ""
                                    }
                                    QQC2.Label {
                                        Layout.fillWidth: true
                                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                        opacity: 0.6
                                        visible: view.deep && !view.deep.error
                                        font.family: "monospace"
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                        text: view.deep ? view.deep.command : ""
                                    }

                                    // the collapsible section component
                                    component Section: ColumnLayout {
                                        id: sec
                                        property string title
                                        property int count: 0
                                        property bool openByDefault: false
                                        property bool shown: openByDefault
                                        default property alias body: inner.data
                                        Layout.fillWidth: true
                                        spacing: 1
                                        visible: count > 0
                                        Kirigami.Separator { Layout.fillWidth: true }
                                        QQC2.ItemDelegate {
                                            Layout.fillWidth: true
                                            onClicked: sec.shown = !sec.shown
                                            contentItem: RowLayout {
                                                Kirigami.Icon {
                                                    source: sec.shown ? "go-down" : "go-next"
                                                    implicitWidth: Kirigami.Units.iconSizes.small
                                                    implicitHeight: Kirigami.Units.iconSizes.small
                                                }
                                                QQC2.Label {
                                                    Layout.fillWidth: true
                                                    text: sec.title + "  (" + sec.count + ")"
                                                    font.bold: true
                                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                                }
                                            }
                                        }
                                        ColumnLayout {
                                            id: inner
                                            Layout.fillWidth: true
                                            Layout.leftMargin: Kirigami.Units.largeSpacing
                                            spacing: 1
                                            visible: sec.shown
                                        }
                                    }

                                    // --- how it started ---
                                    Section {
                                        title: "How It Started"
                                        count: view.deep && !view.deep.error ? 1 : 0
                                        openByDefault: true
                                        QQC2.Label {
                                            Layout.fillWidth: true
                                            wrapMode: Text.WordWrap
                                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                            text: view.deep
                                                  ? ("chain: " + (view.deep.ancestry || []).map(function(a){
                                                        return a.name }).join(" -> "))
                                                  : ""
                                        }
                                        QQC2.Label {
                                            Layout.fillWidth: true
                                            wrapMode: Text.WordWrap
                                            visible: view.deep && view.deep.unit
                                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                            text: view.deep
                                                  ? ("unit: " + view.deep.unit + " — " + view.deep.unit_desc
                                                     + (view.deep.unit_enabled ? " · " + view.deep.unit_enabled : ""))
                                                  : ""
                                        }
                                    }

                                    // --- the package ---
                                    Section {
                                        title: "Package"
                                        count: view.deep && view.deep.package ? 1 : 0
                                        openByDefault: true
                                        QQC2.Label {
                                            Layout.fillWidth: true
                                            wrapMode: Text.WordWrap
                                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                            text: view.deep
                                                  ? (view.deep.package + " " + (view.deep.package_version||"")
                                                     + " · " + (view.deep.package_kind||"")
                                                     + "\ndependencies: " + (view.deep.deps_count||0)
                                                     + " · required by " + (view.deep.required_by||0) + " packages")
                                                  : ""
                                        }
                                    }

                                    // --- the open files (ALL of them, scrollable) ---
                                    Section {
                                        title: "Open Files"
                                        count: view.deep ? (view.deep.files || []).length : 0
                                        Repeater {
                                            model: view.deep ? (view.deep.files || []) : []
                                            delegate: QQC2.Label {
                                                required property var modelData
                                                Layout.fillWidth: true
                                                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                                color: modelData.deleted ? "#c0392b" : Kirigami.Theme.textColor
                                                font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                                text: modelData.path
                                                      + (modelData.fds > 1 ? "  ×" + modelData.fds : "")
                                                      + (modelData.deleted ? "  DELETED" : "")
                                            }
                                        }
                                    }

                                    // --- the sockets ---
                                    Section {
                                        title: "Sockets"
                                        count: view.deep ? (view.deep.sockets || []).length : 0
                                        Repeater {
                                            model: view.deep ? (view.deep.sockets || []) : []
                                            delegate: QQC2.Label {
                                                required property var modelData
                                                Layout.fillWidth: true
                                                elide: Text.ElideRight
                                                font.family: "monospace"
                                                font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                                text: modelData.proto + " " + modelData.local
                                                      + (modelData.remote ? " -> " + modelData.remote : "")
                                                      + (modelData.exposure ? "  [" + modelData.exposure + "]" : "")
                                            }
                                        }
                                    }

                                    // --- the events ---
                                    Section {
                                        // if we hit the ceiling - we say so plainly
                                        // instead of showing a slice as "everything"
                                        title: view.deep && view.deep.events_truncated
                                               ? "Events (last 200)" : "Events"
                                        count: view.deep ? (view.deep.events || []).length : 0
                                        Repeater {
                                            model: view.deep ? (view.deep.events || []) : []
                                            delegate: QQC2.Label {
                                                required property var modelData
                                                Layout.fillWidth: true
                                                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                                font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                                text: Fmt.localTime(modelData.ts)
                                                      + "  " + (modelData.event_action || "")
                                                      + "  " + String(modelData.message || "").substring(0,60)
                                            }
                                        }
                                    }

                                    // --- the children ---
                                    Section {
                                        title: "Child Processes"
                                        count: view.deep ? (view.deep.children || []).length : 0
                                        Repeater {
                                            model: view.deep ? (view.deep.children || []) : []
                                            delegate: QQC2.Label {
                                                required property var modelData
                                                Layout.fillWidth: true
                                                elide: Text.ElideRight
                                                font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                                text: "pid " + modelData.pid + "  " + (modelData.command || "")
                                            }
                                        }
                                    }

                                    // --- the detail of the node selected ON THE CANVAS ---
                                    Kirigami.Separator {
                                        Layout.fillWidth: true
                                        visible: view.sideNode !== null
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        visible: view.sideNode !== null
                                        Rectangle {
                                            width: 10; height: 10; radius: 5
                                            color: view.sideNode ? linkCanvas.colorFor(view.sideNode.kind) : "transparent"
                                        }
                                        QQC2.Label {
                                            Layout.fillWidth: true
                                            text: view.sideNode ? view.sideNode.label : ""
                                            font.bold: true
                                            elide: Text.ElideRight
                                        }
                                        QQC2.Button {
                                            visible: view.sideNode && view.sideNode.table !== ""
                                            icon.name: "search"
                                            flat: true
                                            QQC2.ToolTip.text: "Show in State"
                                            QQC2.ToolTip.visible: hovered
                                            onClicked: root.focusState(view.sideNode.table,
                                                                      view.sideNode.col, view.sideNode.val)
                                        }
                                    }
                                    Repeater {
                                        model: view.sideInfo ? (view.sideInfo.sections || []) : []
                                        delegate: InfoSection {
                                            required property var modelData
                                            required property int index
                                            title: modelData.title
                                            count: (modelData.rows || []).length
                                            // the first section ("What this is") is
                                            // open, the rest on a click, like graph blocks
                                            shown: index === 0
                                            Repeater {
                                                model: modelData.rows || []
                                                delegate: QQC2.Label {
                                                    required property var modelData
                                                    Layout.fillWidth: true
                                                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                                    font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                                    text: modelData.k + ": " + modelData.v
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }



            }
        }
    }

    // ---- THE GRAPH FULL SCREEN ----
    // The same canvas and the same handlers, only over the whole window area: a
    // long ladder (2000 px for systemd) otherwise has to be examined in a quarter
    // of the screen. The node side panel is right here, on the right.
    QQC2.Popup {
        id: fullGraph
        parent: QQC2.Overlay.overlay
        x: 0; y: 0
        width: parent ? parent.width : 1200
        height: parent ? parent.height : 800
        modal: true
        padding: 0
        onOpened: fullCanvas.fit()
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing
            RowLayout {
                Layout.fillWidth: true
                Kirigami.Heading {
                    level: 4
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                    text: view.plinks && view.plinks.anchor
                          ? (view.plinks.anchor.label || "") : ""
                }
                QQC2.Label {
                    opacity: 0.65
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    text: view.plinks ? (view.plinks.nodes.length + " objects") : ""
                }
                QQC2.ToolButton {
                    icon.name: "window-close"
                    onClicked: fullGraph.close()
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Kirigami.Units.smallSpacing
                GraphCanvas {
                    id: fullCanvas
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    graph: view.plinks ? view.plinks : ({ nodes: [], edges: [] })
                    onNodeActivated: function (n) { view.graphNodeActivated(n) }
                    onToggleCategory: function (cat) { view.graphToggle(cat) }
                    onAnchorRequested: function (n) { view.graphAnchor(n) }
                    onDrillRequested: function (a, n) { view.graphDrill(a, n) }
                }
                // the details of the selected node right in full-screen mode
                Rectangle {
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 22
                    Layout.fillHeight: true
                    visible: view.sideNode !== null
                    color: Kirigami.Theme.backgroundColor
                    radius: 4
                    QQC2.ScrollView {
                        id: fullSide
                        anchors.fill: parent
                        anchors.margins: Kirigami.Units.smallSpacing
                        clip: true
                        contentWidth: availableWidth
                        ColumnLayout {
                            width: fullSide.availableWidth
                            spacing: 2
                            RowLayout {
                                Layout.fillWidth: true
                                Rectangle {
                                    width: 10; height: 10; radius: 5
                                    color: view.sideNode
                                           ? fullCanvas.colorFor(view.sideNode.kind) : "transparent"
                                }
                                QQC2.Label {
                                    Layout.fillWidth: true
                                    font.bold: true
                                    elide: Text.ElideRight
                                    text: view.sideNode ? view.sideNode.label : ""
                                }
                            }
                            QQC2.Label {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                opacity: 0.6
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                visible: view.sideInfo && view.sideInfo.error
                                text: view.sideInfo ? (view.sideInfo.error || "") : ""
                            }
                            Repeater {
                                model: view.sideInfo ? (view.sideInfo.sections || []) : []
                                delegate: InfoSection {
                                    required property var modelData
                                    required property int index
                                    title: modelData.title
                                    count: (modelData.rows || []).length
                                    shown: index === 0
                                    Repeater {
                                        model: modelData.rows || []
                                        delegate: RowLayout {
                                            required property var modelData
                                            Layout.fillWidth: true
                                            spacing: Kirigami.Units.smallSpacing
                                            QQC2.Label {
                                                text: modelData.k
                                                opacity: 0.6
                                                Layout.preferredWidth: Kirigami.Units.gridUnit * 7
                                                elide: Text.ElideRight
                                                font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                            }
                                            QQC2.Label {
                                                text: modelData.v
                                                Layout.fillWidth: true
                                                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                                font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ---- CHOOSING AN ENTITY for "view by" ----
    // The list comes from backend.anchorList(kind); a choice builds a graph from it.
}

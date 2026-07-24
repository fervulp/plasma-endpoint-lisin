import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "pages"

Kirigami.ApplicationWindow {
    id: root
    title: "LiSin"
    width: 1100
    height: 720

    // no top header bar / separator — the cards float directly on the canvas
    pageStack.globalToolBar.style: Kirigami.ApplicationHeaderStyle.None

    property var sysState: null
    property string section: ""

    Connections {
        target: backend
        function onStateReady(s) { root.sysState = s }
    }
    Component.onCompleted: {
        backend.reload()          // input scheduling lives in the backend
        open("state")             // the first section goes through the cache too
    }

    // The "explore in state" jump: an event -> the right State table, filtered by
    // the value. The counter n is needed so that clicking the same value again
    // also changes the property and the handler fires.
    property var stateFocus: null
    function focusState(table, col, val) {
        stateFocus = { table: table, col: col, val: String(val),
                       n: (stateFocus ? stateFocus.n + 1 : 1) }
        open("state")
    }

    // A jump into the Events TAB (now part of Data) with a ready WHERE condition.
    // Events is no longer a separate section - it is the first Data tab - so this
    // reuses the state-focus mechanism with the "events" table and a raw WHERE.
    function focusEvents(where) {
        stateFocus = { table: "events", raw: String(where),
                       n: (stateFocus ? stateFocus.n + 1 : 1) }
        open("state")
    }

    // SHOW AN ENTITY IN THE GRAPH. From an event (or anywhere) to the dashboard
    // with this entity at the centre. The graph engine anchors on any kind -
    // process, address, application, port, user, config, open_file - so an event
    // can be looked at by its process OR by the address it talked to. The n
    // counter makes a repeat click on the same value still fire the handler.
    property var graphFocus: null
    function focusGraph(kind, val) {
        graphFocus = { kind: String(kind), val: String(val),
                       n: (graphFocus ? graphFocus.n + 1 : 1) }
        open("dashboards")
    }
    // A SECTION IS BUILT ON EVERY NAVIGATION, from its Component.
    //
    // Caching the created pages and pushing the same object again was faster on
    // paper (Events 1.04 s -> 0.09 s), but a PageRow sizes and owns the pages it
    // creates itself; handing it an item created elsewhere is not the same thing,
    // and the section came up blank. A second of building a page is cheaper than
    // a section that does not show. What was gained honestly stays: the rows come
    // from the database a page at a time, a cell is one object, the panels are
    // memoised.
    //
    // A SECTION IS BUILT ONCE AND KEPT. Every navigation used to clear() the
    // stack and push() a fresh page - and clear() does NOT destroy the old page
    // (measured: the StatePage count went 1, 2, 3 over three visits, ~200 MB a
    // round). Building a page also costs real time, which is why sections were
    // slow to open. Now each page is created once, held in pageCache, and swapped
    // in with replace(): memory is bounded to seven pages and a re-visit is
    // instant. Its query, scroll position and selection survive leaving it -
    // which an investigation wants anyway.
    property var pageCache: ({})
    property var pageComps: ({
        state: statePageComp, dashboards: dashboardPageComp,
        sql: sqlPageComp, pipeline: pipelinePageComp, expertise: expertisePageComp,
        settings: settingsPageComp })
    function pageFor(name) {
        if (pageCache[name] === undefined) {
            var comp = pageComps[name] || placeholder
            pageCache[name] = comp.createObject(root)
        }
        return pageCache[name]
    }
    function open(name) {
        if (root.section === name)
            return
        root.section = name
        while (root.pageStack.layers.depth > 1)   // close fullscreen layers
            root.pageStack.layers.pop()
        var it = pageFor(name)
        // the kept page is removed from the row by clear() but NOT destroyed,
        // because pageCache holds a reference - so a re-visit is instant and the
        // resident set is one page per section, not a fresh one every time
        root.pageStack.clear()
        root.pageStack.push(it)
        // NO PAGE-LEVEL FADE. Animating the opacity of a whole section (a tree of
        // hundreds of rows, a graph) forces the compositor to render it offscreen
        // every frame - that was the "jerky" animation. The smoothness lives in
        // the small, local animations instead: rows and tiles fade, hover and
        // selection ease, the graph eases. The section itself just appears.
    }

    globalDrawer: Kirigami.GlobalDrawer {
        id: drawer
        modal: false
        collapsible: true
        // the default "Close Sidebar" button is replaced by a cleaner footer toggle
        collapseButtonVisible: false
        // keep the header (and the menu icons) in place when collapsed, and give
        // the collapsed rail a little more width
        showHeaderWhenCollapsed: true
        collapsedSize: Kirigami.Units.gridUnit * 3
        // a grey sidebar (Window palette)
        Kirigami.Theme.colorSet: Kirigami.Theme.Window
        Kirigami.Theme.inherit: false
        // plain background (the default one draws the edge separator) — no border
        background: Rectangle { color: Kirigami.Theme.backgroundColor }

        // a subtle, icon-only collapse arrow — raised off the very bottom so it
        // sits about the level of the tabs card's 'updated' line
        footer: Item {
            implicitHeight: collapseBtn.implicitHeight + Kirigami.Units.largeSpacing
            QQC2.ToolButton {
                id: collapseBtn
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Kirigami.Units.largeSpacing
                flat: true
                opacity: hovered ? 0.9 : 0.3
                icon.name: drawer.collapsed ? "sidebar-expand-left-symbolic"
                                            : "sidebar-collapse-left-symbolic"
                onClicked: drawer.collapsed = !drawer.collapsed
                QQC2.ToolTip.text: drawer.collapsed ? "Expand sidebar" : "Collapse sidebar"
                QQC2.ToolTip.visible: hovered
            }
        }

        header: Rectangle {
            Kirigami.Theme.colorSet: Kirigami.Theme.Window
            Kirigami.Theme.inherit: false
            color: Kirigami.Theme.backgroundColor
            // compact, with a stable height (so collapse does not shift the menu)
            implicitHeight: Kirigami.Units.gridUnit * 3.0
            RowLayout {
                id: logoRow
                anchors.fill: parent
                anchors.leftMargin: Kirigami.Units.largeSpacing
                anchors.rightMargin: Kirigami.Units.smallSpacing
                anchors.topMargin: Kirigami.Units.smallSpacing
                anchors.bottomMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing
                Kirigami.Icon {
                    source: "view-visible"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    visible: !drawer.collapsed          // hide the title when collapsed
                    Kirigami.Heading { level: 2; text: "LiSin" }
                    QQC2.Label {
                        text: "Endpoint Detection and Response"
                        opacity: 0.6
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                }
            }
        }

        // set the logo off from the sections with a subtle divider
        topContent: [
            Kirigami.Separator {
                Layout.fillWidth: true
                Layout.bottomMargin: Kirigami.Units.smallSpacing
                opacity: 0.3
            }
        ]

        actions: [
            Kirigami.Action {
                text: "Dashboards"
                icon.name: "office-chart-bar"
                checked: root.section === "dashboards"
                onTriggered: root.open("dashboards")
            },
            Kirigami.Action {
                text: "Data"
                icon.name: "computer"
                checked: root.section === "state"
                onTriggered: root.open("state")
            },
            Kirigami.Action {
                text: "Expertise"
                icon.name: "document-edit"
                checked: root.section === "expertise"
                onTriggered: root.open("expertise")
            },
            Kirigami.Action {
                text: "Pipelines"
                icon.name: "distribute-graph-directed"
                checked: root.section === "pipeline"
                onTriggered: root.open("pipeline")
            },
            Kirigami.Action { separator: true },
            Kirigami.Action {
                text: "Settings"
                icon.name: "configure"
                checked: root.section === "settings"
                onTriggered: root.open("settings")
            }
        ]
    }

    pageStack.initialPage: placeholder

    Component { id: statePageComp; StatePage {} }
    Component { id: dashboardPageComp; DashboardPage {} }
    Component { id: sqlPageComp; SqlPage {} }
    Component { id: pipelinePageComp; PipelinePage {} }

    Component { id: expertisePageComp; ExpertisePage {} }
    Component { id: settingsPageComp; SettingsPage {} }

    Component {
        id: placeholder
        Kirigami.Page {
            id: ph
            title: "Events"
            Kirigami.PlaceholderMessage {
                anchors.centerIn: parent
                width: parent.width - Kirigami.Units.gridUnit * 4
                icon.name: "applications-development"
                text: ph.title
                explanation: "Under construction"
            }
        }
    }
}

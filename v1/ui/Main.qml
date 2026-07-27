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

    // The "explore in state" jump: a value -> the right Data tab, filtered. The
    // counter n makes a repeat click on the same value still change the property
    // so the handler fires. Set by focusEvents; read by StatePage.applyFocus.
    property var stateFocus: null

    // A jump into the Events tab with a ready WHERE condition (e.g. from a
    // dashboard) — reuses the state-focus mechanism with the "events" table.
    function focusEvents(where) {
        stateFocus = { table: "events", raw: String(where),
                       n: (stateFocus ? stateFocus.n + 1 : 1) }
        open("state")
    }

    // Open a rule in Expertise (from a pipeline stage). Same counter trick so a
    // repeat click on the same rule still fires the handler.
    property var expertiseFocus: null
    function openExpertise(ref) {
        if (!ref) return
        expertiseFocus = { ref: String(ref),
                           n: (expertiseFocus ? expertiseFocus.n + 1 : 1) }
        open("expertise")
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
        pipelines: pipelinesPageComp, expertise: expertisePageComp })
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
                text: "Pipelines"
                icon.name: "distribute-graph-directed"
                checked: root.section === "pipelines"
                onTriggered: root.open("pipelines")
            },
            Kirigami.Action {
                text: "Expertise"
                icon.name: "document-edit"
                checked: root.section === "expertise"
                onTriggered: root.open("expertise")
            }
            // Settings (with the SQL and Errors sub-views) was a v0 page copied
            // whole but never wired to the v1 backend — every button called a slot
            // that does not exist. It returns when built for v1; the reference
            // implementation still lives under v0/.
        ]
    }

    pageStack.initialPage: placeholder

    Component { id: statePageComp; StatePage {} }
    Component { id: dashboardPageComp; DashboardPage {} }
    Component { id: pipelinesPageComp; PipelinesPage {} }
    Component { id: expertisePageComp; ExpertisePage {} }

    // shown for a moment at startup before open("state") swaps in the first
    // section (also the fallback for an unknown page name)
    Component {
        id: placeholder
        Kirigami.Page {
            title: "LiSin"
            Kirigami.PlaceholderMessage {
                anchors.centerIn: parent
                width: parent.width - Kirigami.Units.gridUnit * 4
                icon.name: "view-visible"
                text: "LiSin"
                explanation: "Loading…"
            }
        }
    }
}

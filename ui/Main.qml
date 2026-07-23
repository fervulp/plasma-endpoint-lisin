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

    // A jump into "Events" with a ready WHERE condition. The counter n is needed
    // for the same reason as in focusState: clicking the same value again would
    // not change the property and the handler would not fire.
    property var eventFocus: null
    function focusEvents(where) {
        eventFocus = { where: String(where),
                       n: (eventFocus ? eventFocus.n + 1 : 1) }
        open("events")
    }

    // A jump into a SPECIFIC chain: show what was happening around this state
    // transition.
    property var chainFocus: null
    function focusChain(cid) {
        chainFocus = { id: String(cid), n: (chainFocus ? chainFocus.n + 1 : 1) }
        open("events")
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
    // kept for callers that jump straight to a process (the check that it is
    // alive is done by the caller via livePids)
    property var processFocus: null
    function focusProcess(pid) { focusGraph("process", pid) }

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
        state: statePageComp, dashboards: dashboardPageComp, events: eventsPageComp,
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
        modal: false
        collapsible: true
        // a grey background over the full height (the Window palette), the content stays light
        Kirigami.Theme.colorSet: Kirigami.Theme.Window
        Kirigami.Theme.inherit: false

        header: Rectangle {
            Kirigami.Theme.colorSet: Kirigami.Theme.Window
            Kirigami.Theme.inherit: false
            color: Kirigami.Theme.backgroundColor
            implicitHeight: logoRow.implicitHeight + Kirigami.Units.largeSpacing * 2
            RowLayout {
                id: logoRow
                anchors.fill: parent
                anchors.margins: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.smallSpacing
                Kirigami.Icon {
                    source: "view-visible"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Kirigami.Heading { level: 1; text: "LiSin" }
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
        actions: [
            Kirigami.Action {
                text: "State"
                icon.name: "computer"
                checked: root.section === "state"
                onTriggered: root.open("state")
            },
            Kirigami.Action {
                text: "Dashboards"
                icon.name: "office-chart-bar"
                checked: root.section === "dashboards"
                onTriggered: root.open("dashboards")
            },
            Kirigami.Action {
                text: "Events"
                icon.name: "view-list-details"
                checked: root.section === "events"
                onTriggered: root.open("events")
            },
            Kirigami.Action {
                text: "Pipelines"
                icon.name: "distribute-graph-directed"
                checked: root.section === "pipeline"
                onTriggered: root.open("pipeline")
            },
            Kirigami.Action {
                text: "Expertise"
                icon.name: "document-edit"
                checked: root.section === "expertise"
                onTriggered: root.open("expertise")
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

    Component { id: eventsPageComp; EventsPage {} }
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

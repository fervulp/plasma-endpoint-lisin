import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Kirigami.ApplicationWindow {
    id: root
    title: "LiSin"
    width: 1100
    height: 720

    property var sysState: null
    property string section: "state"

    Connections {
        target: backend
        function onStateReady(s) { root.sysState = s }
    }
    Component.onCompleted: backend.reload()   // input scheduling lives in the backend

    // Переход «исследовать в состоянии»: событие → нужная таблица State,
    // отфильтрованная по значению. Счётчик n нужен, чтобы повторный клик по
    // тому же значению тоже менял свойство и обработчик сработал.
    property var stateFocus: null
    function focusState(table, col, val) {
        stateFocus = { table: table, col: col, val: String(val),
                       n: (stateFocus ? stateFocus.n + 1 : 1) }
        open("state")
    }

    // Переход в «События» с готовым условием WHERE. Счётчик n нужен по той
    // же причине, что и в focusState: повторный клик по тому же значению не
    // менял бы свойство, и обработчик не сработал бы.
    property var eventFocus: null
    function focusEvents(where) {
        eventFocus = { where: String(where),
                       n: (eventFocus ? eventFocus.n + 1 : 1) }
        open("events")
    }

    // Переход в КОНКРЕТНУЮ цепочку (из раздела «Изменения»): показать, что
    // происходило вокруг этого перехода состояния.
    property var chainFocus: null
    function focusChain(cid) {
        chainFocus = { id: String(cid), n: (chainFocus ? chainFocus.n + 1 : 1) }
        open("events")
    }

    // Переход «показать процесс в графе»: из события — к дашборду, где этот
    // процесс стоит в центре. Работает, только пока процесс жив; проверку
    // делает вызывающая сторона (livePids).
    property var processFocus: null
    function focusProcess(pid) {
        processFocus = { pid: String(pid),
                         n: (processFocus ? processFocus.n + 1 : 1) }
        open("dashboards")
    }

    function open(name) {
        if (root.section === name)
            return
        root.section = name
        while (root.pageStack.layers.depth > 1)   // close fullscreen layers
            root.pageStack.layers.pop()
        root.pageStack.clear()                    // drop leftover columns
        root.pageStack.push(name === "state" ? statePageComp
                          : name === "dashboards" ? dashboardPageComp
                          : name === "events" ? eventsPageComp
                          : name === "sql" ? sqlPageComp
                          : name === "pipeline" ? pipelinePageComp
                          : name === "expertise" ? expertisePageComp
                          : name === "settings" ? settingsPageComp
                          : placeholder)
    }

    globalDrawer: Kirigami.GlobalDrawer {
        modal: false
        collapsible: true
        // серый фон на всю высоту (Window-палитра), белым остаётся контент
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

    pageStack.initialPage: statePageComp

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

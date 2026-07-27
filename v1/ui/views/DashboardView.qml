import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components"

// The PROCESS dashboard: the process tree (parent -> children), in the app's
// table style. The columns answer the three questions that matter most for a
// process: how much it consumes now (CPU, RSS), how much its WHOLE BRANCH
// consumes together (Σ branch), and how long it has been running (Uptime).
// The tree, the branch totals and the ordering are computed in the backend
// (processTree); this view only renders and filters.
Item {
    id: view

    property var allRows: []
    property string filter: ""

    // the three questions that matter come FIRST (consumption, whole-branch
    // consumption, how long it has run); PID/User trail at the end.
    readonly property var cols: [
        { k: "name",      t: "Process",      fill: true },
        { k: "cpu",       t: "CPU %",        w: 6, right: true },
        { k: "rss_mb",    t: "RSS MB",       w: 7, right: true },
        { k: "branch_mb", t: "Σ branch MB",  w: 9, right: true },
        { k: "uptime",    t: "Uptime",       w: 8, right: true },
        { k: "pid",       t: "PID",          w: 6, right: true },
        { k: "user",      t: "User",         w: 7 }
    ]

    function reload() { view.allRows = backend.processTree() || [] }

    // indent the process name by its depth so the parent -> child tree is visible
    function cellText(row, key) {
        if (key === "name") {
            var ind = ""
            for (var i = 0; i < (row.depth || 0); i++) ind += "    "
            return ind + row.name
        }
        return undefined   // other columns: show the raw value
    }

    // a plain text filter across name / pid / user
    readonly property var shownRows: {
        if (filter === "") return allRows
        var f = filter.toLowerCase()
        return allRows.filter(function (row) {
            return String(row.name).toLowerCase().indexOf(f) >= 0
                || String(row.pid).indexOf(f) >= 0
                || String(row.user).toLowerCase().indexOf(f) >= 0
        })
    }

    Connections {
        target: backend
        // ONLY WHILE VISIBLE, AND COALESCED. Pages are kept alive in Main's cache,
        // so without this the process tree was rebuilt in Python (a full scan of
        // `processes`, on the GUI thread, under the store lock) on every push for
        // the rest of the session — even while the user was in another section.
        function onStateReady() { if (view.visible) reloadTimer.restart() }
    }
    Timer { id: reloadTimer; interval: 500; onTriggered: view.reload() }
    onVisibleChanged: if (visible) reload()
    Component.onCompleted: reload()

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing
        spacing: Kirigami.Units.smallSpacing

        Kirigami.SearchField {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            placeholderText: "search a process by name, PID or user…"
            onTextChanged: view.filter = text
        }

        DataTable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.topMargin: 10        // same search-to-content gap as Data
            resizable: true
            columns: view.cols
            rows: view.shownRows
            formatter: view.cellText
        }
    }
}

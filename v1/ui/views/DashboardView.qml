import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components"

// The process dashboard — a process table in the app's table style, with a
// plain search across all its columns (no SQL, no tiles, no entity picker).
// Kept deliberately simple for now; the tree/graph come later.
Item {
    id: view

    property var allRows: []
    property var cols: []
    property string filter: ""

    // a sensible, readable column order (osquery hands the keys back
    // alphabetically, which puts cgroup_path/cmdline first)
    readonly property var colOrder: ["name", "pid", "ppid", "state", "uid",
        "euid", "gid", "threads", "nice", "rss", "start_time", "cgroup_path",
        "path", "cmdline"]

    function reload() {
        var r = backend.tableRows("processes", "", "ppid", 0, 0)
        var keys = r.columns || []
        var ordered = view.colOrder.filter(function (k) { return keys.indexOf(k) >= 0 })
            .concat(keys.filter(function (k) { return view.colOrder.indexOf(k) < 0 }))
        view.cols = ordered.map(function (k) {
            return { k: k, t: k,
                     w: (k === "cmdline" ? 24 : k === "name" ? 12
                         : k === "cgroup_path" ? 14 : 7) }
        })
        view.allRows = r.rows || []
    }

    // a plain text filter across every column of every row
    readonly property var shownRows: {
        if (filter === "") return allRows
        var f = filter.toLowerCase()
        return allRows.filter(function (row) {
            for (var k in row)
                if (String(row[k]).toLowerCase().indexOf(f) >= 0)
                    return true
            return false
        })
    }

    Connections {
        target: backend
        function onStateReady() { view.reload() }
    }
    Component.onCompleted: reload()

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing
        spacing: Kirigami.Units.smallSpacing

        Kirigami.SearchField {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            placeholderText: "search across all components…"
            onTextChanged: view.filter = text
        }

        DataTable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.topMargin: 10        // same search-to-content gap as Data
            resizable: true
            columns: view.cols
            rows: view.shownRows
        }
    }
}

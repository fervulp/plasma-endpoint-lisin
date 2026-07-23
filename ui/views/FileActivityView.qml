import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components"
import "../components/Fmt.js" as Fmt

// FILE ACTIVITY: what was created, changed, deleted - and by whom.
//
// Built on the shared templates (principle 17): one query bar, one table, one
// side panel. The facets on the left were replaced by the query bar: a facet is
// just a condition, and having two ways to select the same thing means two
// places to get it wrong. A click on a cell still narrows the list - it writes
// the condition into the same bar, where it is visible and editable.
Item {
    id: view
    property var d: ({ events: [], by_action: [], by_dir: [], by_package: [], total: 0 })
    property var sel: null
    property string query: ""

    readonly property var cols: [
        { k: "ts", t: "Time", w: 11, mono: true },
        { k: "event_action", t: "Action", w: 10 },
        { k: "file_path", t: "File", w: 30, fill: true, mono: true },
        { k: "package_name", t: "Package", w: 12 },
        { k: "changed_by", t: "Changed by", w: 12 },
        { k: "file_mode", t: "Mode", w: 6, mono: true },
        { k: "file_owner", t: "Owner", w: 8 }
    ]
    property var hiddenCols: []

    function refresh() { view.d = backend.fileActivity() }
    Component.onCompleted: refresh()
    Connections {
        target: backend
        function onStateReady(s) { view.refresh() }
    }

    function fmt(row, key) {
        if (key === "ts") return Fmt.local(row.ts)
        // WHO, AND HOW WE KNOW. rpm -Va records the divergence but not the
        // author of the change - then we say so instead of guessing.
        if (key === "changed_by")
            return row.changed_by ? row.changed_by
                 : (row.who_source ? "" : "not recorded")
        return undefined
    }
    function rowAccent(r) {
        if (!r) return ""
        var s = Number(r.event_severity || 0)
        return s >= 70 ? "#e74c3c" : s >= 45 ? "#e67e22" : s >= 25 ? "#f1c40f" : ""
    }

    readonly property var rows: d.events || []
    readonly property var shown: {
        var q = (view.query || "").trim()
        if (q === "") return view.rows
        var m = q.match(/^\s*(\w+)\s*(=|<>|!=|LIKE|NOT LIKE)\s*'?([^']*)'?\s*$/i)
        var out = []
        for (var i = 0; i < view.rows.length; i++) {
            var r = view.rows[i]
            if (m) {
                var v = String(r[m[1]] === undefined ? "" : r[m[1]]).toLowerCase()
                var want = m[3].toLowerCase(), op = m[2].toUpperCase()
                var hit = op === "=" ? v === want
                        : (op === "<>" || op === "!=") ? v !== want
                        : op === "LIKE" ? v.indexOf(want.replace(/%/g, "")) >= 0
                        : v.indexOf(want.replace(/%/g, "")) < 0
                if (hit) out.push(r)
            } else {
                var hay = ""
                for (var k in r) hay += " " + r[k]
                if (hay.toLowerCase().indexOf(q.toLowerCase()) >= 0) out.push(r)
            }
        }
        return out
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.largeSpacing
                Kirigami.Heading { level: 3; text: "File activity" }
                // the most frequent actions as shortcuts - each writes a
                // condition into the query bar, nothing is filtered locally
                Repeater {
                    model: (view.d.by_action || []).slice(0, 5)
                    QQC2.ToolButton {
                        required property var modelData
                        text: modelData.value + "  " + modelData.n
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        onClicked: qbar.addCondition("event_action", "=", modelData.value)
                    }
                }
                Item { Layout.fillWidth: true }
                QQC2.Label {
                    text: view.shown.length + " of " + view.rows.length
                    opacity: 0.6
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
                QQC2.ToolButton { icon.name: "view-refresh"; onClicked: view.refresh() }
            }

            QueryBar {
                id: qbar
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                fields: view.cols.map(function (c) { return { name: c.k } })
                defaultSelect: view.cols.map(function (c) { return c.k })
                placeholder: "file_path LIKE '%sudoers%'   ·   or just type text to search"
                onApplied: function (spec, sql) {
                    var hide = []
                    if (spec.select.length)
                        for (var i = 0; i < view.cols.length; i++)
                            if (spec.select.indexOf(view.cols[i].k) < 0)
                                hide.push(view.cols[i].k)
                    view.hiddenCols = hide
                    view.query = qbar.builderMode ? qbar.buildSql() : qbar.manualWhere()
                }
            }
            Kirigami.Separator { Layout.fillWidth: true }

            DataTable {
                Layout.fillWidth: true
                Layout.fillHeight: true
                columns: view.cols
                rows: view.shown
                hidden: view.hiddenCols
                accent: view.rowAccent
                formatter: view.fmt
                onRowActivated: function (row) { view.sel = row }
                onConditionRequested: function (field, op, value) {
                    qbar.addCondition(field, op, value)
                }
            }

            Kirigami.PlaceholderMessage {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.largeSpacing
                visible: view.rows.length === 0
                icon.name: "folder"
                text: "No file events yet"
                explanation: "Integrity checks compare packaged files with the package " +
                             "reference; the author of a change needs kernel audit rules."
            }
        }

        SidePanel {
            id: side
            Layout.fillHeight: true
            open: view.sel !== null
            title: view.sel ? (view.sel.file_name || view.sel.file_path || "") : ""
            iconName: "document-edit"
            onCloseRequested: view.sel = null

            QQC2.ScrollView {
                id: scroller
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                ColumnLayout {
                    width: scroller.availableWidth
                    spacing: 2
                    Repeater {
                        model: view.sel ? Object.keys(view.sel) : []
                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            visible: String(view.sel[modelData] || "") !== ""
                            spacing: Kirigami.Units.smallSpacing
                            QQC2.Label {
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 9
                                text: modelData
                                opacity: 0.6
                                elide: Text.ElideRight
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                            QQC2.Label {
                                Layout.fillWidth: true
                                text: modelData === "ts" ? Fmt.local(view.sel.ts)
                                                         : String(view.sel[modelData])
                                wrapMode: Text.WrapAnywhere
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                        }
                    }
                    QQC2.Button {
                        Layout.fillWidth: true
                        visible: view.sel && view.sel.package_name
                        text: "Show the package in State"
                        icon.name: "search"
                        onClicked: root.focusState("applications", "name", view.sel.package_name)
                    }
                }
            }
        }
    }
}

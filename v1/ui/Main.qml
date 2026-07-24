import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "components"

// v1 — Data section. A left list of DuckDB tables (base tables + enrichment
// views), the shared DataTable on the right, and a read-only SQL box.
Kirigami.ApplicationWindow {
    id: root
    title: "LiSin"
    width: Kirigami.Units.gridUnit * 60
    height: Kirigami.Units.gridUnit * 40

    property var tableList: []
    property string currentTable: ""
    property var current: ({ columns: [], rows: [], error: "", truncated: false })

    function reloadTables() {
        tableList = backend.tables()
        if (currentTable === "" && tableList.length > 0)
            openTable(tableList[0])
        else if (currentTable !== "")
            openTable(currentTable)
    }
    function openTable(name) {
        currentTable = name
        sqlBox.text = ""
        current = backend.tableRows(name)
    }
    function runSql() {
        if (sqlBox.text.trim() === "") { openTable(currentTable); return }
        current = backend.runQuery(sqlBox.text)
    }

    Connections {
        target: backend
        function onDataReady() { root.reloadTables() }
    }
    Component.onCompleted: reloadTables()

    pageStack.initialPage: Kirigami.Page {
        title: "Data"
        padding: 0

        RowLayout {
            anchors.fill: parent
            spacing: 0

            // ---- left: table / view list ----
            QQC2.ScrollView {
                Layout.preferredWidth: Kirigami.Units.gridUnit * 12
                Layout.fillHeight: true
                QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff
                ListView {
                    model: root.tableList
                    delegate: QQC2.ItemDelegate {
                        required property string modelData
                        width: ListView.view.width
                        text: modelData
                        highlighted: modelData === root.currentTable
                        onClicked: root.openTable(modelData)
                    }
                }
            }
            Kirigami.Separator { Layout.fillHeight: true }

            // ---- right: query box + table ----
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    Layout.margins: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing
                    QQC2.TextField {
                        id: sqlBox
                        Layout.fillWidth: true
                        placeholderText: "SELECT … (read-only) — empty shows the whole table"
                        onAccepted: root.runSql()
                    }
                    QQC2.Button {
                        text: "Run"
                        icon.name: "system-run"
                        onClicked: root.runSql()
                    }
                }

                QQC2.Label {
                    visible: !!(root.current.error && root.current.error.length)
                    text: root.current.error || ""
                    color: Kirigami.Theme.negativeTextColor
                    Layout.leftMargin: Kirigami.Units.smallSpacing
                    Layout.bottomMargin: Kirigami.Units.smallSpacing
                }

                DataTable {
                    id: dt
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    resizable: true
                    columns: (root.current.columns || []).map(function (k) {
                        return { k: k, t: k, w: 12 }
                    })
                    rows: root.current.rows || []
                }
            }
        }

        footer: QQC2.ToolBar {
            RowLayout {
                anchors.fill: parent
                QQC2.Label {
                    text: root.currentTable === "" ? ""
                        : root.currentTable + " · " + (root.current.rows
                            ? root.current.rows.length : 0) + " rows"
                            + (root.current.truncated ? " (first 1000)" : "")
                }
                Item { Layout.fillWidth: true }
                QQC2.Button {
                    text: "Refresh"
                    icon.name: "view-refresh"
                    onClicked: backend.refresh()
                }
            }
        }
    }
}

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

// SQL workbench: read-only queries over the state DB + table management
// (create tables/fields/records, delete). Bottom toolbar holds the
// management buttons and pagination.
Kirigami.Page {
    id: page
    title: "SQL"
    padding: 0

    property bool embedded: false     // inside Settings -> without its own actions/footer
    property var s: root.sysState
    property var tabsModel: s ? s.tabs : []
    property var result: null      // {columns, rows, error}
    property int pageLimit: 50
    property int pageIndex: 0

    property var rows: result ? result.rows : []
    property var selRow: null
    property var cols: result ? result.columns : []
    property int pageCount: Math.max(1, Math.ceil(rows.length / pageLimit))
    property var pagedRows: rows.slice(pageIndex * pageLimit,
                                       (pageIndex + 1) * pageLimit)

    // the current table for the control buttons
    property string curTable: tableBox.currentIndex >= 0 && tabsModel.length
                              ? tabsModel[tableBox.currentIndex].name : ""
    property bool curBuiltin: tableBox.currentIndex >= 0 && tabsModel.length
                              ? tabsModel[tableBox.currentIndex].builtin : true

    // The query from the shared bar: in manual mode this is ready SQL, in builder
    // mode only the condition, which is appended to the current table.
    function applyQuery(sql) {
        var q = String(sql || "").trim()
        if (q === "") return
        if (q.toUpperCase().indexOf("SELECT") === 0) { runQuery(q); return }
        if (!curTable) return
        runQuery('SELECT * FROM "' + curTable + '" WHERE ' + q)
    }
    function runCurrent() { applyQuery(qbar.builderMode ? qbar.buildSql()
                                                        : qbar.manualText) }

    function runQuery(q) {
        result = backend.sqlQuery(q)
        pageIndex = 0
    }
    function selectTable() {
        if (curTable !== "")
            runQuery('SELECT * FROM "' + curTable + '"')
    }

    actions: [
        Kirigami.Action {
            icon.name: "system-run"; text: "Run"
            visible: !page.embedded
            onTriggered: page.runQuery(sqlField.text)
        }
    ]

    // the table control panel (a component - so that it can be shown embedded too)
    Component {
        id: tableTools
        Row {
            spacing: Kirigami.Units.smallSpacing
            QQC2.Button {
                text: "Table…"; icon.name: "tab-new"
                onClicked: { tabName.text = ""; tabDialog.open() }
            }
            QQC2.Button {
                text: "Field…"; icon.name: "edit-table-insert-column-right"
                enabled: page.curTable !== ""
                onClicked: { fieldName.text = ""; fieldDialog.open() }
            }
            QQC2.Button {
                text: "Record"; icon.name: "list-add"
                enabled: page.curTable !== ""
                onClicked: { backend.addRow(page.curTable); page.selectTable() }
            }
            QQC2.Button {
                text: "Drop table"; icon.name: "tab-close"
                enabled: page.curTable !== "" && !page.curBuiltin
                onClicked: { backend.deleteTab(page.curTable); page.result = null }
            }
        }
    }

    footer: QQC2.ToolBar {
        RowLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing
            Loader {                       // table controls in the footer (standalone)
                active: !page.embedded
                sourceComponent: page.embedded ? null : tableTools
            }
            Item { Layout.fillWidth: true }
            QQC2.Label {
                opacity: 0.7
                text: page.rows.length === 0 ? "0 rows"
                      : (page.pageIndex * page.pageLimit + 1) + "–" +
                        Math.min((page.pageIndex + 1) * page.pageLimit,
                                 page.rows.length) + " of " + page.rows.length
            }
            // HONEST ABOUT INCOMPLETENESS (principle 7): the result used to be cut
            // to 1000 rows silently, and "of 1000" read as "that is everything".
            QQC2.Label {
                visible: page.result && page.result.truncated === true
                color: "#e67e22"
                text: page.result && page.result.limit
                      ? ("showing first " + page.result.limit
                         + " — narrow the query (LIMIT/WHERE); these are not all rows")
                      : ""
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
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            QQC2.ComboBox {
                id: tableBox
                Layout.preferredWidth: Kirigami.Units.gridUnit * 12
                model: page.tabsModel.map(t => t.title + " (" + t.name + ")")
                onActivated: page.selectTable()
            }
            QQC2.Button {
                text: "Run"
                icon.name: "system-run"
                onClicked: page.runCurrent()
            }
        }

        // THE SHARED QUERY BAR (principle 15). On this page manual SQL input is
        // the default, but the same builder is available on a button - the rules
        // are the same everywhere in the application.
        QueryBar {
            id: qbar
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.largeSpacing
            Layout.rightMargin: Kirigami.Units.largeSpacing
            builderMode: false
            manualText: page.curTable
                        ? 'SELECT * FROM "' + page.curTable + '"' : ""
            fields: page.cols.map(function (c) { return { name: c } })
            // the selection starts with the fields the table shows right now
            defaultSelect: page.cols
            placeholder: "SELECT * FROM ports WHERE port = '22'"
            onApplied: function (spec, sql) {
                // SELECT from the builder = which columns to show.
                // Filters and sorting are built RELATIVE to these fields.
                var hide = []
                if (spec.select.length)
                    for (var i = 0; i < page.cols.length; i++)
                        if (spec.select.indexOf(page.cols[i]) < 0)
                            hide.push(page.cols[i])
                sqlTable.hidden = hide
                page.applyQuery(sql)
            }
        }

        Loader {                           // table controls on top (embedded)
            active: page.embedded
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.bottomMargin: Kirigami.Units.smallSpacing
            sourceComponent: page.embedded ? tableTools : null
        }

        QQC2.Label {
            visible: page.result !== null && page.result.error !== ""
            Layout.leftMargin: Kirigami.Units.smallSpacing
            color: Kirigami.Theme.negativeTextColor
            text: page.result ? "Error: " + page.result.error : ""
        }

        // result table + details sidebar
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

        // THE SHARED TABLE (principle 15): there used to be a local implementation
        // here with 170 px columns and its own header. Now it is the same
        // component as in the other sections: column choice, order, zebra
        // striping, recycling, a click on a row -> the side panel.
        DataTable {
            id: sqlTable
            Layout.fillWidth: true
            Layout.fillHeight: true
            columns: {
                var out = []
                for (var i = 0; i < page.cols.length; i++)
                    out.push({ k: page.cols[i], t: page.cols[i],
                               w: 8, fill: i === page.cols.length - 1 })
                return out
            }
            rows: page.pagedRows
            onRowActivated: function (row) { page.lastSel = row }
            // a click on the header appends ORDER BY to the same query
            onSortRequested: function (field, desc) {
                qbar.addSort(field, desc)
                qbar.apply()
            }
            onConditionRequested: function (field, op, value) {
                // "+" on a cell appends a condition to the query - as in events
                qbar.addCondition(field, op, value)
            }
        }

        SidePanel {
            id: sqlDetails
            title: "Details"
            iconName: "documentinfo"
            panelWidth: Kirigami.Units.gridUnit * 22
            onCloseRequested: open = false

            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                ColumnLayout {
                    width: sqlDetails.panelWidth - Kirigami.Units.largeSpacing * 2
                    spacing: Kirigami.Units.smallSpacing
                    Repeater {
                        model: page.selRow ? page.cols.filter(c => c !== "_id") : []
                        delegate: ColumnLayout {
                            spacing: 1
                            Layout.fillWidth: true
                            visible: String(page.selRow[modelData] ?? "") !== ""
                            QQC2.Label {
                                text: modelData
                                opacity: 0.55
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                            QQC2.TextArea {
                                Layout.fillWidth: true
                                readOnly: true
                                wrapMode: TextEdit.Wrap
                                text: String(page.selRow[modelData] ?? "")
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
        }
    }

    // -------- dialogs --------
    Kirigami.Dialog {
        id: editDialog
        title: "Record — " + page.curTable
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        padding: Kirigami.Units.largeSpacing
        preferredWidth: Kirigami.Units.gridUnit * 24

        property var row: null
        property var cols: []
        function openFor(r) {
            row = r
            cols = page.cols.filter(c => c !== "_id")
            open()
        }
        customFooterActions: [
            Kirigami.Action {
                text: "Delete record"
                icon.name: "edit-delete"
                onTriggered: {
                    backend.deleteRow(page.curTable, editDialog.row._id)
                    editDialog.close()
                    page.selectTable()
                }
            }
        ]
        onAccepted: {
            for (let i = 0; i < cols.length; i++) {
                const v = fieldsRep.itemAt(i).text
                if (v !== String(row[cols[i]] ?? ""))
                    backend.setCell(page.curTable, row._id, cols[i], v)
            }
            backend.reload()
            page.selectTable()
        }
        Kirigami.FormLayout {
            Repeater {
                id: fieldsRep
                model: editDialog.cols
                QQC2.TextField {
                    Kirigami.FormData.label: modelData
                    text: editDialog.row ? String(editDialog.row[modelData] ?? "") : ""
                }
            }
        }
    }

    Kirigami.PromptDialog {
        id: tabDialog
        title: "New table"
        subtitle: "Creates a new state tab (table)"
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        onAccepted: if (tabName.text.trim()) backend.createTab(tabName.text)
        QQC2.TextField { id: tabName; placeholderText: "Name"; onAccepted: tabDialog.accept() }
    }

    Kirigami.PromptDialog {
        id: fieldDialog
        title: "New field"
        subtitle: "Add a column to “" + page.curTable + "”"
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        onAccepted: if (fieldName.text.trim()) {
            backend.addColumn(page.curTable, fieldName.text)
            page.selectTable()
        }
        QQC2.TextField { id: fieldName; placeholderText: "field_name"; onAccepted: fieldDialog.accept() }
    }
}

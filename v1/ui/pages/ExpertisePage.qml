import QtQuick
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components"
import "../views"
import "."

// Expertise: directories (including custom ones) -> the table of objects
// (ID, title, type, version) -> a click on a row = the YAML code.
Kirigami.Page {
    id: page
    title: "Expertise"
    padding: 0

    background: PageBackground {}

    // PLAIN STATE, NOT BINDINGS. These used to be bound (`allElements:
    // backend.expertiseElements(curDir)`) AND assigned imperatively in three
    // places. The first assignment destroys a binding, so after pressing Refresh
    // once, choosing another catalog no longer changed the list — the previous
    // catalog's rules stayed on screen. Reproduced before the change and after.
    // One writer now: reload(), which the directory change also goes through.
    property var dirs: []
    property string curDir: "inputs"
    property var allElements: []
    onCurDirChanged: reload()
    property int typeFilter: 0    // 0 = all
    readonly property var typeNames: ["All types", "Inputs", "Normalization",
                                      "Enrichment", "Filters", "Correlation", "Outputs"]
    readonly property var typeVals: [[], ["input"], ["normalization_rule"],
                                     ["enrichment"], ["filter"], ["detection"],
                                     ["output", "statedb", "syslog"]]
    property string fltId: ""
    property string fltTitle: ""
    property string fltVersion: ""
    property int pageLimit: 50
    property int pageIndex: 0
    property var elements: allElements.filter(e =>
        (typeFilter === 0 || typeVals[typeFilter].includes(e.type)) &&
        (fltId === "" || e.id.toLowerCase().includes(fltId.toLowerCase())) &&
        (fltVersion === "" || e.version.includes(fltVersion)) &&
        (fltTitle === "" || (e.title + " " + e.name).toLowerCase()
                              .includes(fltTitle.toLowerCase())))
    // click-to-sort, like the Data table
    property string sortField: ""
    property bool sortDesc: false
    function setSort(f) {
        if (sortField === f) sortDesc = !sortDesc
        else { sortField = f; sortDesc = false }
    }
    property var sortedElements: {
        if (sortField === "") return elements
        var arr = elements.slice(), f = sortField, d = sortDesc ? -1 : 1
        arr.sort(function (a, b) {
            var av = String(a[f] === undefined ? "" : a[f])
            var bv = String(b[f] === undefined ? "" : b[f])
            return (av < bv ? -1 : av > bv ? 1 : 0) * d
        })
        return arr
    }
    property int pageCount: Math.max(1, Math.ceil(elements.length / pageLimit))
    property var pagedElements: sortedElements.slice(pageIndex * pageLimit,
                                                     (pageIndex + 1) * pageLimit)
    onElementsChanged: pageIndex = 0
    // columns for the shared DataTable (same as Data's tables)
    readonly property var expColumns: [
        { k: "id", t: "ID", w: 10 },
        { k: "title", t: "Title", fill: true },
        { k: "type", t: "Type", w: 8 },
        { k: "version", t: "Version", w: 6, right: true }
    ]
    property string editing: ""      // the relative path of the open file
    property var selEl: null         // the row shown in the detail sidebar
    property var testResult: null    // what the rule's own tests just answered
    readonly property int testsFailed: {
        if (!testResult || !testResult.results) return 0
        var n = 0
        for (var i = 0; i < testResult.results.length; i++)
            if (!testResult.results[i].passed) n++
        return n
    }
    function runTests() {
        if (!selEl) return
        testResult = backend.ruleTests(String(selEl.name || selEl.id || ""))
    }
    onSelElChanged: testResult = null      // a result belongs to the rule it ran on
    property string detailContent: ""// its YAML content (read-only preview)
    property string saveError: ""    // set by the editor's Save button


    property var collapsed: []          // collapsed directories
    function hasChildren(path) {
        return dirs.some(d => d.path.startsWith(path + "/"))
    }
    function toggleCollapse(path) {
        collapsed = collapsed.includes(path)
            ? collapsed.filter(x => x !== path)
            : collapsed.concat([path])
    }

    function reload() {                 // the ONLY writer of allElements
        allElements = backend.expertiseElements(curDir)
    }

    function refresh() {
        dirs = backend.expertiseDirs()
        reload()
    }

    // A JUMP FROM A PIPELINE STAGE: root.expertiseFocus carries a rule ref like
    // "inputs/processes" — open that catalog and show the rule in the sidebar.
    function applyFocus() {
        var f = root ? root.expertiseFocus : null
        if (!f || !f.ref) return
        var ref = String(f.ref)
        var dir = ref.indexOf("/") > 0 ? ref.slice(0, ref.indexOf("/")) : ref
        if (dir !== page.curDir)
            page.curDir = dir          // onCurDirChanged reloads the list
        for (var i = 0; i < page.allElements.length; i++) {
            if (page.allElements[i].rel === ref) {
                page.selEl = page.allElements[i]
                page.detailContent = backend.readExpertise(ref)
                detailPanel.open = true
                return
            }
        }
    }
    Connections {
        target: root
        function onExpertiseFocusChanged() { page.applyFocus() }
    }
    Component.onCompleted: { refresh(); applyFocus() }

    actions: [
        Kirigami.Action {
            icon.name: "view-filter"; text: "Filter"
            checkable: true
            checked: filterPanel.open
            onTriggered: filterPanel.open = checked
        }
        // A "Columns" chooser (colMenu) was inert here — the catalog columns are a
        // fixed set — so it was removed. Folder / Element / Import / Export / Run /
        // Tests were v0 authoring actions wired to backend slots that do not exist
        // in v1; viewing and editing existing expertise works (row -> sidebar ->
        // Edit -> Save), authoring will return when its backend is built.
    ]

    footer: QQC2.ToolBar {
        RowLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing
            QQC2.Label {
                Layout.leftMargin: Kirigami.Units.smallSpacing
                opacity: 0.6
                text: "elements: " + page.elements.length
            }
            Item { Layout.fillWidth: true }
            QQC2.Label {
                opacity: 0.7
                text: page.elements.length === 0 ? "0"
                      : (page.pageIndex * page.pageLimit + 1) + "–" +
                        Math.min((page.pageIndex + 1) * page.pageLimit,
                                 page.elements.length) + " of " + page.elements.length
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

    RowLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.largeSpacing

        // -------- directories (collapsible) --------
        FloatCard {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 13
            Layout.fillHeight: true
            QQC2.ScrollView {
                anchors.fill: parent
                anchors.margins: Kirigami.Units.smallSpacing
                ListView {
                // hide the children of collapsed directories
                model: page.dirs.filter(d => {
                    for (const c of page.collapsed)
                        if (d.path !== c && d.path.startsWith(c + "/")) return false
                    return true
                })
                clip: true
                delegate: QQC2.ItemDelegate {
                    width: ListView.view.width
                    leftPadding: Kirigami.Units.smallSpacing
                                 + Kirigami.Units.largeSpacing * modelData.depth
                    highlighted: page.curDir === modelData.path
                    onClicked: {
                        page.curDir = modelData.path
                        page.editing = ""

                    }
                    contentItem: RowLayout {
                        spacing: 2
                        QQC2.ToolButton {   // the collapse/expand triangle
                            visible: page.hasChildren(modelData.path)
                            icon.name: page.collapsed.includes(modelData.path)
                                       ? "arrow-right" : "arrow-down"
                            implicitWidth: Kirigami.Units.gridUnit * 1.3
                            implicitHeight: Kirigami.Units.gridUnit * 1.3
                            onClicked: page.toggleCollapse(modelData.path)
                        }
                        Item {
                            visible: !page.hasChildren(modelData.path)
                            implicitWidth: Kirigami.Units.gridUnit * 1.3
                        }
                        Kirigami.Icon {
                            source: "folder"
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        }
                        QQC2.Label {
                            text: modelData.title
                            font.bold: modelData.depth === 0
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }
                }
            }
            }
        }

        // -------- the table of objects --------
        FloatCard {
            visible: page.editing === ""
            Layout.fillWidth: true
            Layout.fillHeight: true
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Kirigami.Units.smallSpacing
                spacing: 0

            DataTable {
                Layout.fillWidth: true
                Layout.fillHeight: true
                resizable: true
                columns: page.expColumns
                rows: page.pagedElements
                sortCol: page.sortField
                sortDesc: page.sortDesc
                onSortRequested: function (field, desc) { page.setSort(field) }
                onRowClicked: function (row, index, mods) {
                    // a click SHOWS the element in the sidebar (as in Data);
                    // editing starts from the Edit button there.
                    page.selEl = row
                    page.detailContent = backend.readExpertise(row.rel)
                    detailPanel.open = true
                }
            }
            }
        }

        // -------- filter sidebar (full height) --------
        SidePanel {
            id: filterPanel
            title: "Filter"
            iconName: "view-filter"
            panelWidth: Kirigami.Units.gridUnit * 15
            onCloseRequested: open = false

                Kirigami.FormLayout {
                    Layout.fillWidth: true
                    QQC2.ComboBox {
                        Kirigami.FormData.label: "Type"
                        Layout.fillWidth: true
                        model: page.typeNames
                        currentIndex: page.typeFilter
                        onActivated: i => page.typeFilter = i
                    }
                    QQC2.TextField {
                        Kirigami.FormData.label: "ID"
                        Layout.fillWidth: true
                        text: page.fltId
                        onTextChanged: page.fltId = text
                    }
                    QQC2.TextField {
                        Kirigami.FormData.label: "Title"
                        Layout.fillWidth: true
                        text: page.fltTitle
                        onTextChanged: page.fltTitle = text
                    }
                    QQC2.TextField {
                        Kirigami.FormData.label: "Version"
                        Layout.fillWidth: true
                        text: page.fltVersion
                        onTextChanged: page.fltVersion = text
                    }
                }
                QQC2.Label {
                    Layout.leftMargin: Kirigami.Units.smallSpacing
                    opacity: 0.6
                    text: "elements: " + page.elements.length
                }
                QQC2.Button {
                    Layout.leftMargin: Kirigami.Units.smallSpacing
                    text: "Reset"
                    icon.name: "edit-clear-all"
                    onClicked: {
                        page.typeFilter = 0
                        page.fltId = ""; page.fltTitle = ""; page.fltVersion = ""
                    }
                }
        }

        // -------- element detail sidebar (content + Edit) --------
        SidePanel {
            id: detailPanel
            title: page.selEl ? (page.selEl.title || page.selEl.id) : "Element"
            iconName: "dialog-information"
            panelWidth: Kirigami.Units.gridUnit * 26
            onCloseRequested: open = false

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                QQC2.Label {
                    Layout.fillWidth: true
                    opacity: 0.7
                    elide: Text.ElideRight
                    text: page.selEl
                          ? (page.selEl.id + "  ·  " + page.selEl.type
                             + "  ·  v" + page.selEl.version) : ""
                }
                // RUN WHAT THE RULE CLAIMS, WHERE THE RULE IS EDITED. A rule
                // that states what it must produce is only worth writing if the
                // answer is one click from where it is written; otherwise the
                // statement is decoration and drifts from the table.
                QQC2.Button {
                    text: "Tests"
                    icon.name: "checkmark"
                    enabled: page.selEl !== null
                    onClicked: page.runTests()
                }
                QQC2.Button {
                    text: "Edit"
                    icon.name: "document-edit"
                    enabled: page.selEl !== null
                    onClicked: {
                        page.editing = page.selEl.rel
                        page.saveError = ""
                        editor.text = backend.readExpertise(page.selEl.rel)
                        detailPanel.open = false
                    }
                }
            }

            // the outcome, in the panel rather than a dialog: the rule stays on
            // screen next to what it claimed
            ColumnLayout {
                Layout.fillWidth: true
                visible: page.testResult !== null
                spacing: 2

                RowLayout {
                    Layout.fillWidth: true
                    Kirigami.Icon {
                        source: page.testsFailed > 0 ? "dialog-error" : "dialog-ok"
                        implicitWidth: Kirigami.Units.iconSizes.small
                        implicitHeight: Kirigami.Units.iconSizes.small
                    }
                    QQC2.Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: {
                            var r = page.testResult
                            if (!r) return ""
                            if (r.error) return r.error
                            if (r.note) return r.note
                            return page.testsFailed > 0
                                   ? page.testsFailed + " of " + (r.results || []).length
                                     + " assertions fail"
                                   : "all " + (r.results || []).length + " assertions hold"
                        }
                        color: page.testsFailed > 0 ? Kirigami.Theme.negativeTextColor
                                                    : Kirigami.Theme.textColor
                    }
                }
                // ONE label, not a Repeater over the results: the list is a
                // dozen lines at most, and a Repeater here produced no rows at
                // all — twice, silently, in two different panels. A joined text
                // cannot fail that way and reads the same.
                QQC2.Label {
                    Layout.fillWidth: true
                    visible: text !== ""
                    wrapMode: Text.WordWrap
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    textFormat: Text.PlainText
                    text: {
                        var r = page.testResult
                        if (!r || !r.results) return ""
                        var out = []
                        for (var i = 0; i < r.results.length; i++) {
                            var x = r.results[i]
                            out.push((x.passed ? "✓ " : "✗ ") + x.test
                                     + (x.detail ? " — " + x.detail : ""))
                        }
                        return out.join("\n")
                    }
                }
                Kirigami.Separator { Layout.fillWidth: true; Layout.topMargin: 4 }
            }
            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                QQC2.TextArea {
                    text: page.detailContent
                    readOnly: true
                    font.family: "monospace"
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    wrapMode: TextEdit.NoWrap
                }
            }
        }

        // -------- the code editor --------
        FloatCard {
            visible: page.editing !== ""
            Layout.fillWidth: true
            Layout.fillHeight: true
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Kirigami.Units.smallSpacing
                spacing: 0

            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                QQC2.ToolButton {
                    icon.name: "go-previous"
                    QQC2.ToolTip.text: "Back to list"
                    QQC2.ToolTip.visible: hovered
                    onClicked: { page.editing = ""; page.refresh() }
                }
                Kirigami.Heading {
                    level: 3
                    text: page.editing
                    Layout.fillWidth: true
                    elide: Text.ElideLeft
                }
                QQC2.Label {
                    text: page.saveError
                    color: Kirigami.Theme.negativeTextColor
                    elide: Text.ElideRight
                }
                QQC2.Button {
                    text: "Save"
                    icon.name: "document-save"
                    onClicked: {
                        page.saveError = backend.saveExpertise(page.editing, editor.text)
                        if (page.saveError === "") page.refresh()
                    }
                }
            }
            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                QQC2.TextArea {
                    id: editor
                    font.family: "monospace"
                    wrapMode: TextEdit.NoWrap
                    tabStopDistance: 20
                }
            }
            }
        }
    }


}

import QtQuick
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

// Expertise: directories (including custom ones) -> the table of objects
// (ID, title, type, version) -> a click on a row = the YAML code.
Kirigami.Page {
    id: page
    title: "Expertise"
    padding: 0

    property var dirs: backend.expertiseDirs()
    property string curDir: "fedora"
    property var allElements: backend.expertiseElements(curDir)
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
    property int pageCount: Math.max(1, Math.ceil(elements.length / pageLimit))
    property var pagedElements: elements.slice(pageIndex * pageLimit,
                                               (pageIndex + 1) * pageLimit)
    onElementsChanged: pageIndex = 0
    property string editing: ""      // the relative path of the open file
    // "Run now" and "Tests" for the open rule
    property var runResult: null
    function refOf(rel) { return rel.slice(-5) === ".yaml" ? rel.slice(0, -5) : rel }
    property string saveError: ""

    // the columns of the object table: visibility and widths (resized by dragging)
    property var colW: ({ id: 90, type: 160, version: 60 })
    property var colHide: ({ id: false, type: false, version: false })
    function setW(c, w) {
        const o = Object.assign({}, colW); o[c] = Math.max(50, w); colW = o
    }
    function toggleC(c) {
        const o = Object.assign({}, colHide); o[c] = !o[c]; colHide = o
    }

    property var collapsed: []          // collapsed directories
    function hasChildren(path) {
        return dirs.some(d => d.path.startsWith(path + "/"))
    }
    function toggleCollapse(path) {
        collapsed = collapsed.includes(path)
            ? collapsed.filter(x => x !== path)
            : collapsed.concat([path])
    }

    function refresh() {
        dirs = backend.expertiseDirs()
        allElements = backend.expertiseElements(curDir)
    }

    actions: [
        Kirigami.Action {
            icon.name: "view-filter"; text: "Filter"
            checkable: true
            checked: filterPanel.open
            onTriggered: filterPanel.open = checked
        },
        Kirigami.Action {
            icon.name: "view-table-of-contents-ltr"; text: "Columns"
            onTriggered: colMenu.popup()
        },
        Kirigami.Action {
            icon.name: "folder-new"; text: "Folder…"
            onTriggered: { dirName.text = ""; dirDialog.open() }
        },
        Kirigami.Action {
            icon.name: "edit-delete"; text: "Delete folder"
            visible: page.curDir !== "fedora"
            onTriggered: delDirDialog.open()
        },
        Kirigami.Action {
            icon.name: "document-new"; text: "Element…"
            onTriggered: { createName.text = ""; createError.text = ""; createDialog.open() }
        },
        Kirigami.Action {
            icon.name: "media-playback-start"; text: "Run"
            tooltip: "Run the rule against live input and show the result"
            visible: page.editing !== ""
            onTriggered: {
                page.runResult = backend.ruleRun(page.refOf(page.editing), "")
                runSheet.open()
            }
        },
        Kirigami.Action {
            icon.name: "checkbox"; text: "Tests"
            tooltip: "Run the tests: section inside the rule"
            visible: page.editing !== ""
            onTriggered: {
                page.runResult = backend.ruleTests(page.refOf(page.editing))
                runSheet.open()
            }
        },
        Kirigami.Action {
            icon.name: "document-import"; text: "Import…"
            onTriggered: importDialog.open()
        },
        Kirigami.Action {
            icon.name: "document-export"; text: "Export"
            visible: page.editing !== ""
            onTriggered: {
                exportDialog.currentFile = "file:///" + page.editing.split("/").pop()
                exportDialog.open()
            }
        }
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
        spacing: 0

        // -------- directories (collapsible) --------
        QQC2.ScrollView {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 13
            Layout.fillHeight: true
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
                        page.allElements = backend.expertiseElements(modelData.path)
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
                            source: modelData.depth === 0 ? "folder-favorites" : "folder"
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

        Kirigami.Separator { Layout.fillHeight: true }

        // -------- the table of objects --------
        ColumnLayout {
            visible: page.editing === ""
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                spacing: 0

                component HCol: Item {
                    property string label
                    property string key
                    implicitHeight: hl.implicitHeight
                    visible: !page.colHide[key]
                    QQC2.Label {
                        id: hl
                        anchors.fill: parent
                        anchors.rightMargin: 8
                        text: parent.label
                        font.bold: true
                        elide: Text.ElideRight
                    }
                    MouseArea {   // the resize handle
                        width: 10
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        cursorShape: Qt.SplitHCursor
                        property real sx
                        onPressed: m => sx = m.x
                        onPositionChanged: m => {
                            if (pressed) page.setW(parent.key, page.colW[parent.key] + (m.x - sx))
                        }
                    }
                }

                HCol { label: "ID"; key: "id"; Layout.preferredWidth: page.colW.id }
                QQC2.Label { text: "Title"; font.bold: true; Layout.fillWidth: true; elide: Text.ElideRight }
                HCol { label: "Type"; key: "type"; Layout.preferredWidth: page.colW.type }
                HCol { label: "Version"; key: "version"; Layout.preferredWidth: page.colW.version }
            }
            Kirigami.Separator { Layout.fillWidth: true }

            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                ListView {
                    model: page.pagedElements
                    clip: true
                    delegate: QQC2.ItemDelegate {
                        width: ListView.view.width
                        background: Rectangle {
                            color: index % 2 === 0
                                   ? Kirigami.Theme.backgroundColor
                                   : Kirigami.Theme.alternateBackgroundColor
                            Kirigami.Separator {
                                anchors.bottom: parent.bottom
                                width: parent.width
                                opacity: 0.35
                            }
                        }
                        onClicked: {
                            page.editing = modelData.rel
                            page.saveError = ""
                            editor.text = backend.readExpertise(modelData.rel)
                        }
                        contentItem: RowLayout {
                            spacing: 0
                            QQC2.Label {
                                visible: !page.colHide.id
                                text: modelData.id || "—"
                                font.family: "monospace"
                                elide: Text.ElideRight
                                rightPadding: 8
                                Layout.preferredWidth: page.colW.id
                            }
                            ColumnLayout {
                                spacing: 0
                                Layout.fillWidth: true
                                QQC2.Label {
                                    text: modelData.title || modelData.name
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                QQC2.Label {
                                    text: modelData.name
                                    opacity: 0.6
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                            }
                            QQC2.Label {
                                visible: !page.colHide.type
                                text: modelData.type || "—"
                                opacity: 0.8
                                elide: Text.ElideRight
                                rightPadding: 8
                                Layout.preferredWidth: page.colW.type
                            }
                            QQC2.Label {
                                visible: !page.colHide.version
                                text: modelData.version || "—"
                                elide: Text.ElideRight
                                Layout.preferredWidth: page.colW.version
                            }
                        }
                    }
                    Kirigami.PlaceholderMessage {
                        anchors.centerIn: parent
                        visible: parent.count === 0
                        text: "Folder is empty"
                        explanation: "Use “Element…” to create from a template"
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

        // -------- the code editor --------
        ColumnLayout {
            visible: page.editing !== ""
            Layout.fillWidth: true
            Layout.fillHeight: true
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

    // -------- dialogs --------
    Kirigami.PromptDialog {
        id: dirDialog
        title: "New folder"
        subtitle: "Will be created inside “" + page.curDir + "”"
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        onAccepted: {
            if (dirName.text.trim()) {
                backend.createExpertiseDir(page.curDir, dirName.text)
                page.refresh()
            }
        }
        QQC2.TextField { id: dirName; placeholderText: "folder_name" }
    }

    Kirigami.PromptDialog {
        id: delDirDialog
        title: "Delete folder?"
        subtitle: "“" + page.curDir + "” and all elements in it will be removed permanently"
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        onAccepted: {
            const err = backend.deleteExpertiseDir(page.curDir)
            if (err === "") { page.curDir = "fedora"; page.refresh() }
            else page.saveError = err
        }
    }

    QQC2.Menu {
        id: colMenu
        QQC2.MenuItem {
            text: "ID"; checkable: true
            checked: !page.colHide.id
            onTriggered: page.toggleC("id")
        }
        QQC2.MenuItem {
            text: "Type"; checkable: true
            checked: !page.colHide.type
            onTriggered: page.toggleC("type")
        }
        QQC2.MenuItem {
            text: "Version"; checkable: true
            checked: !page.colHide.version
            onTriggered: page.toggleC("version")
        }
    }

    Kirigami.Dialog {
        id: createDialog
        title: "New element in “" + page.curDir + "”"
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        padding: Kirigami.Units.largeSpacing
        preferredWidth: Kirigami.Units.gridUnit * 20

        property var cats: ["inputs", "normalize", "enrich", "filters", "correlation", "outputs"]

        onAccepted: {
            const err = backend.createExpertise(page.curDir,
                            cats[createType.currentIndex], createName.text)
            if (err) { createError.text = err; open() }
            else page.refresh()
        }
        Kirigami.FormLayout {
            QQC2.ComboBox {
                id: createType
                Kirigami.FormData.label: "Element type"
                model: ["Input", "Normalization", "Filter", "Correlation", "Output"]
            }
            QQC2.TextField {
                id: createName
                Kirigami.FormData.label: "File name"
                placeholderText: "my_source"
            }
            QQC2.Label { id: createError; color: Kirigami.Theme.negativeTextColor }
        }
    }

    FileDialog {
        id: importDialog
        title: "Import YAML into “" + page.curDir + "”"
        nameFilters: ["YAML (*.yaml *.yml)"]
        onAccepted: {
            const err = backend.importExpertise(page.curDir, selectedFile.toString())
            if (err === "") page.refresh()
            else page.saveError = err
        }
    }
    FileDialog {
        id: exportDialog
        title: "Export YAML"
        fileMode: FileDialog.SaveFile
        nameFilters: ["YAML (*.yaml *.yml)"]
        onAccepted: {
            const err = backend.exportExpertise(page.editing, selectedFile.toString())
            if (err !== "") page.saveError = err
        }
    }

    // ---- the result of "Run" / "Tests" ----
    Kirigami.Dialog {
        id: runSheet
        title: "Rule run"
        preferredWidth: Kirigami.Units.gridUnit * 40
        preferredHeight: Kirigami.Units.gridUnit * 28
        standardButtons: Kirigami.Dialog.Close
        QQC2.ScrollView {
            anchors.fill: parent
            clip: true
            ColumnLayout {
                width: runSheet.preferredWidth - Kirigami.Units.gridUnit * 3
                spacing: Kirigami.Units.smallSpacing

                Kirigami.InlineMessage {
                    Layout.fillWidth: true
                    visible: page.runResult && (page.runResult.error || "") !== ""
                    type: Kirigami.MessageType.Error
                    text: page.runResult ? (page.runResult.error || "") : ""
                }
                QQC2.Label {
                    Layout.fillWidth: true
                    visible: page.runResult && (page.runResult.hint || "") !== ""
                    wrapMode: Text.WordWrap
                    opacity: 0.75
                    text: page.runResult ? (page.runResult.hint || "") : ""
                }

                // --- the Run result ---
                QQC2.Label {
                    Layout.fillWidth: true
                    visible: page.runResult && page.runResult.count !== undefined
                    wrapMode: Text.WordWrap
                    text: page.runResult
                          ? "Input: " + (page.runResult.source || "") + "   ·   input lines: "
                            + (page.runResult.input_lines || 0)
                            + "\nParsed rows: " + (page.runResult.count || 0)
                            + "   ·   columns: " + ((page.runResult.columns || []).length)
                          : ""
                }
                QQC2.Label {
                    Layout.fillWidth: true
                    visible: page.runResult && (page.runResult.columns || []).length > 0
                    wrapMode: Text.WordWrap
                    font.family: "monospace"
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    text: page.runResult ? "columns: " + (page.runResult.columns || []).join(", ") : ""
                }
                Repeater {
                    model: page.runResult && page.runResult.rows ? page.runResult.rows.slice(0, 15) : []
                    QQC2.Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WrapAnywhere
                        font.family: "monospace"
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        text: JSON.stringify(modelData)
                    }
                }

                // --- the Tests result ---
                QQC2.Label {
                    Layout.fillWidth: true
                    visible: page.runResult && page.runResult.total !== undefined
                    font.bold: true
                    text: page.runResult
                          ? "Tests passed: " + (page.runResult.passed || 0)
                            + " of " + (page.runResult.total || 0) : ""
                }
                Repeater {
                    model: page.runResult && page.runResult.tests ? page.runResult.tests : []
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        Rectangle {
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 3
                            Layout.preferredHeight: Kirigami.Units.gridUnit
                            radius: 3
                            color: modelData.passed ? "#27ae60" : "#e74c3c"
                            QQC2.Label {
                                anchors.centerIn: parent
                                text: modelData.passed ? "PASS" : "FAIL"
                                color: "#ffffff"
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            QQC2.Label {
                                Layout.fillWidth: true
                                text: modelData.name + "   (rows: " + modelData.got + ")"
                                elide: Text.ElideRight
                            }
                            QQC2.Label {
                                Layout.fillWidth: true
                                visible: !modelData.passed
                                text: modelData.detail
                                wrapMode: Text.WordWrap
                                color: Kirigami.Theme.negativeTextColor
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                        }
                    }
                }
            }
        }
    }
}

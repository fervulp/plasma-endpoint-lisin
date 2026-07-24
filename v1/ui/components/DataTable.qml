import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "."

// THE TEMPLATE TABLE for every section (principle 11/17).
//
// One implementation of the table so the sections do not each grow their own
// and drift apart. It carries everything "Events"/"State" need, gated by
// optional properties so the simpler dashboard views pay for nothing:
//   * ONE description of the columns, read by the header AND the rows;
//   * optional CHECKBOX and ICON columns (via a column's `kind`), for the rich
//     multi-select table in "Data";
//   * multi-selection driven by the OWNER through `isSelected`, with modifier
//     aware row clicks (Ctrl/Shift);
//   * click-to-sort, resizable columns (optional), a column chooser;
//   * a pinned header, zebra striping (the reference bg/altBg), vertical column
//     separators, a fixed row height, `reuseItems`;
//   * a click on a row = a signal outwards (the owner opens the sidebar);
//   * hovering a cell gives "+"/"-" - add/exclude the value in the query;
//   * a double click on a cell copies its value.
//
// The component knows nothing about where the rows came from: an SQL result or
// a list computed in Python.
Item {
    id: table

    // [{ k, t, w, fill, right, mono, kind }] - key, header, width in gridUnit.
    // kind: "check" (a checkbox column), "icon" (a leading icon column), or
    // absent/"text" for an ordinary value column.
    property var columns: []
    property var rows: []
    property var selected: null
    property int rowHeight: Kirigami.Units.gridUnit * 2.4

    // ---- optional rich-table hooks (null/off by default) ----
    // multi-selection: if set, the row highlight uses isSelected(row) instead of
    // `selected === row`, so the owner can keep a list of selected rows
    property var isSelected: null
    // checkbox column (kind:"check"): isChecked(row) -> bool; the header checkbox
    // reflects headerCheckState and clicking it emits headerCheckClicked()
    property var isChecked: null
    property int headerCheckState: Qt.Unchecked
    property bool showHeaderCheck: true
    // icon column (kind:"icon"): iconFor(row) -> icon name; iconTip(row) -> text
    property var iconFor: null
    property var iconTip: null
    // draggable column edges (the value column of kind text)
    property bool resizable: false

    // the keys of the hidden columns and the order - the state of the view
    property var hidden: []
    property var order: []
    // an optional formatter: function(row, key) -> string
    property var formatter: null
    // an optional accent colour on the left: function(row) -> color | ""
    property var accent: null

    signal rowActivated(var row)
    // a click carrying the row index and the keyboard modifiers, for Ctrl/Shift
    // multi-selection managed by the owner
    signal rowClicked(var row, int index, int modifiers)
    // a right click on a row - the owner may open a context menu
    signal rowRightClicked(var row, int index)
    signal valueCopied(string value)
    signal headerCheckClicked()
    signal checkToggled(var row, int index)
    signal columnResized(string key, real w)
    // a click on the header: the owner decides how to apply the order (SQL or list)
    signal sortRequested(string field, bool desc)
    signal conditionRequested(string field, string op, string value)

    // the current sorting - shown by an icon in the header
    property string sortCol: ""
    property bool sortDesc: false
    // when the owner manages the sort itself (e.g. a three-click cycle with a
    // reset, as in "Data"), sortBy only EMITS - the owner binds sortCol/sortDesc.
    // Assigning them here as well would kill that binding (principle 15a).
    property bool externalSort: false
    function sortBy(k) {
        if (externalSort) { table.sortRequested(k, sortDesc); return }
        if (sortCol === k) sortDesc = !sortDesc
        else { sortCol = k; sortDesc = false }
        table.sortRequested(sortCol, sortDesc)
    }

    // ---- geometry: one source, so header/rows/separators cannot drift ----
    readonly property real gu: Kirigami.Units.gridUnit
    function colW(cd) {
        if (cd.fill === true) return fillW
        return (cd.w || 6) * gu
    }
    readonly property real fixedW: {
        var w = 0
        for (var i = 0; i < shownCols.length; i++)
            if (shownCols[i].fill !== true) w += (shownCols[i].w || 6) * gu
        return w
    }
    readonly property bool hasFill: {
        for (var i = 0; i < shownCols.length; i++)
            if (shownCols[i].fill === true) return true
        return false
    }
    property real viewportW: width
    readonly property real fillW: Math.max(gu * 12, viewportW - fixedW
                                           - shownCols.length * Kirigami.Units.smallSpacing)
    readonly property real contentW: hasFill ? Math.max(viewportW, fixedW + fillW)
                                             : Math.max(viewportW, fixedW)

    readonly property var shownCols: {
        var byKey = {}, out = []
        for (var i = 0; i < columns.length; i++) byKey[columns[i].k] = columns[i]
        var seq = order.length ? order : columns.map(function (c) { return c.k })
        for (var j = 0; j < seq.length; j++) {
            var c = byKey[seq[j]]
            if (c && hidden.indexOf(c.k) < 0) out.push(c)
        }
        return out
    }
    function cellText(row, key) {
        // A FORMATTER HANDLES ONLY THE COLUMNS IT CARES ABOUT. Returning
        // undefined means "show the raw value" - otherwise every view would have
        // to repeat the default branch, and a formatter that forgot one column
        // silently assigned undefined to a QString.
        if (formatter) {
            var f = formatter(row, key)
            if (f !== undefined && f !== null) return String(f)
        }
        var v = row[key]
        return (v === undefined || v === null) ? "" : String(v)
    }
    // QML has no direct access to the clipboard - we go through a hidden TextEdit
    function copyValue(v) {
        if (v === undefined || v === null || v === "") return
        clip.text = String(v); clip.selectAll(); clip.copy()
        table.valueCopied(String(v))
    }
    TextEdit { id: clip; visible: false }

    function toggleColumn(k) {
        var h = hidden.slice()
        var i = h.indexOf(k)
        if (i >= 0) h.splice(i, 1); else h.push(k)
        hidden = h
    }
    function moveColumn(k, delta) {
        var seq = (order.length ? order : columns.map(function (c) { return c.k })).slice()
        var i = seq.indexOf(k)
        if (i < 0) return
        var j = i + delta
        if (j < 0 || j >= seq.length) return
        seq.splice(i, 1); seq.splice(j, 0, k)
        order = seq
    }
    function rowSelected(row) {
        return table.isSelected ? table.isSelected(row) : (table.selected === row)
    }

    // A VERTICAL SCROLLBAR FIXED AT THE RIGHT EDGE. The rows live in a
    // content-wide ListView inside a horizontal Flickable, so a scrollbar
    // attached to the list rides along with the horizontal scroll and ends up
    // among the values. This one is anchored to the table edge instead.
    QQC2.ScrollBar {
        id: vbar
        orientation: Qt.Vertical
        anchors.right: parent.right
        y: hflick.y
        height: hflick.height
        z: 20
        policy: list.visibleArea.heightRatio < 1
                ? QQC2.ScrollBar.AlwaysOn : QQC2.ScrollBar.AlwaysOff
        size: list.visibleArea.heightRatio
        position: list.visibleArea.yPosition
        onPositionChanged: if (pressed) list.contentY = position * list.contentHeight
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- header ----
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: hdrProbe.implicitHeight + Kirigami.Units.smallSpacing * 2
            color: Kirigami.Theme.backgroundColor
            clip: true
            QQC2.Label { id: hdrProbe; visible: false; text: "Ag"; font.bold: true }
            Row {
                id: hdrRow
                x: -hflick.contentX + Kirigami.Units.smallSpacing   // scrolls with the rows
                height: parent.height
                spacing: Kirigami.Units.smallSpacing
                Repeater {
                    model: table.shownCols
                    delegate: Item {
                        id: hcell
                        required property var modelData
                        width: table.colW(modelData)
                        height: hdrRow.height
                        readonly property string kind: modelData.kind || "text"

                        // checkbox column: a tristate "select the page" box
                        QQC2.CheckBox {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: hcell.kind === "check" && table.showHeaderCheck
                            tristate: true
                            checkState: table.headerCheckState
                            onClicked: table.headerCheckClicked()
                        }
                        // value column: label + sort direction
                        QQC2.Label {
                            id: hdrLbl
                            anchors.fill: parent
                            anchors.rightMargin: hdrSort.visible ? 20 : 0
                            visible: hcell.kind === "text"
                            text: modelData.t || ""
                            opacity: 0.7
                            font.bold: true
                            elide: Text.ElideRight
                            verticalAlignment: Text.AlignVCenter
                            horizontalAlignment: modelData.right === true
                                ? Text.AlignRight : Text.AlignLeft
                        }
                        Kirigami.Icon {
                            id: hdrSort
                            anchors.right: parent.right
                            anchors.rightMargin: 3
                            anchors.verticalCenter: parent.verticalCenter
                            width: Kirigami.Units.iconSizes.small
                            height: Kirigami.Units.iconSizes.small
                            visible: hcell.kind === "text" && table.sortCol === modelData.k
                            source: table.sortDesc ? "view-sort-descending"
                                                   : "view-sort-ascending"
                        }
                        MouseArea {   // a click on the label sorts
                            anchors.fill: parent
                            anchors.rightMargin: table.resizable ? 8 : 0
                            enabled: hcell.kind === "text"
                            onClicked: table.sortBy(modelData.k)
                        }
                        // the column resize handle (optional)
                        MouseArea {
                            visible: table.resizable && hcell.kind === "text"
                            width: 8
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            cursorShape: Qt.SplitHCursor
                            preventStealing: true
                            property real sx
                            property real sw
                            onPressed: m => { sx = m.x; sw = table.colW(modelData) }
                            onPositionChanged: m => {
                                if (pressed)
                                    table.columnResized(modelData.k,
                                        Math.max(table.gu * 2, sw + (m.x - sx)))
                            }
                        }
                        Kirigami.Separator {
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                        }
                    }
                }
            }
            Kirigami.Separator {
                anchors.bottom: parent.bottom
                width: parent.width
            }
        }

        // ---- rows ----
        Flickable {
            id: hflick
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: table.contentW
            contentHeight: height
            flickableDirection: Flickable.HorizontalFlick
            boundsBehavior: Flickable.StopAtBounds
            QQC2.ScrollBar.horizontal: QQC2.ScrollBar { policy: table.contentW > hflick.width
                                                        ? QQC2.ScrollBar.AsNeeded
                                                        : QQC2.ScrollBar.AlwaysOff }
            onWidthChanged: table.viewportW = width

            ListView {
                id: list
                width: table.contentW
                height: hflick.height
                model: table.rows
                reuseItems: true
                add: Transition {
                    OpacityAnimator { from: 0; to: 1; duration: Kirigami.Units.shortDuration }
                }
                cacheBuffer: Kirigami.Units.gridUnit * 40
                // vertical scrollbar is a fixed bar at the table's right edge
                // (see vbar) — not one that rides along the horizontal scroll

                delegate: Item {
                    id: row
                    required property var modelData
                    required property int index
                    width: table.contentW
                    height: table.rowHeight

                    // background: the reference bg/altBg zebra + highlight + hover
                    Rectangle {
                        anchors.fill: parent
                        color: table.rowSelected(row.modelData)
                               ? Qt.alpha(Kirigami.Theme.highlightColor, 0.20)
                               : rowMouse.containsMouse
                                 ? Qt.alpha(Kirigami.Theme.textColor, 0.06)
                                 : row.index % 2 === 0
                                   ? Kirigami.Theme.backgroundColor
                                   : Kirigami.Theme.alternateBackgroundColor
                        Behavior on color {
                            ColorAnimation { duration: Kirigami.Units.shortDuration }
                        }
                        Kirigami.Separator {
                            anchors.bottom: parent.bottom
                            width: parent.width
                            opacity: 0.35
                        }
                        // the severity/type accent stripe on the left
                        Rectangle {
                            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                            width: 4
                            visible: table.accent && table.accent(row.modelData) !== ""
                            color: table.accent ? (table.accent(row.modelData) || "transparent")
                                                : "transparent"
                            opacity: 0.9
                        }
                    }

                    // ONE MouseArea for the whole row: single click selects (with
                    // modifiers), double click copies the cell under the cursor.
                    // The small +/- hover buttons live above it and take their own
                    // clicks. This is the single interaction model for every view.
                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        function colAt(px) {
                            var x = px + hflick.contentX - Kirigami.Units.smallSpacing
                            for (var i = 0; i < table.shownCols.length; i++) {
                                var w = table.colW(table.shownCols[i])
                                if (x < w) return table.shownCols[i]
                                x -= w + Kirigami.Units.smallSpacing
                            }
                            return null
                        }
                        onClicked: m => {
                            if (m.button === Qt.RightButton) {
                                table.selected = row.modelData
                                table.rowRightClicked(row.modelData, row.index)
                                return
                            }
                            table.selected = row.modelData
                            table.rowClicked(row.modelData, row.index, m.modifiers)
                            table.rowActivated(row.modelData)
                        }
                        onDoubleClicked: m => {
                            var cd = colAt(m.x)
                            if (cd && cd.kind !== "check" && cd.kind !== "icon")
                                table.copyValue(table.cellText(row.modelData, cd.k))
                        }
                    }

                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: Kirigami.Units.smallSpacing
                        spacing: Kirigami.Units.smallSpacing
                        Repeater {
                            model: table.shownCols
                            delegate: Item {
                                id: cell
                                required property var modelData
                                property var colDef: modelData
                                readonly property string kind: modelData.kind || "text"
                                width: table.colW(colDef)
                                height: table.rowHeight
                                property string val: kind === "text"
                                    ? table.cellText(row.modelData, colDef.k) : ""

                                // checkbox
                                QQC2.CheckBox {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: cell.kind === "check"
                                    checked: table.isChecked ? table.isChecked(row.modelData) : false
                                    onClicked: table.checkToggled(row.modelData, row.index)
                                }
                                // leading type icon
                                Kirigami.Icon {
                                    anchors.centerIn: parent
                                    visible: cell.kind === "icon"
                                    width: Kirigami.Units.iconSizes.small
                                    height: Kirigami.Units.iconSizes.small
                                    source: (cell.kind === "icon" && table.iconFor)
                                            ? table.iconFor(row.modelData) : ""
                                    QQC2.ToolTip.text: (cell.kind === "icon" && table.iconTip)
                                                       ? table.iconTip(row.modelData) : ""
                                    QQC2.ToolTip.visible: iconHov.hovered
                                                          && QQC2.ToolTip.text !== ""
                                    HoverHandler { id: iconHov }
                                }
                                // value cell
                                QQC2.Label {
                                    anchors.fill: parent
                                    anchors.leftMargin: Kirigami.Units.smallSpacing
                                    anchors.rightMargin: cellHover.hovered
                                                         ? 34 : Kirigami.Units.smallSpacing
                                    visible: cell.kind === "text"
                                    verticalAlignment: Text.AlignVCenter
                                    horizontalAlignment: colDef.right === true
                                        ? Text.AlignRight : Text.AlignLeft
                                    text: cell.val
                                    elide: Text.ElideRight
                                    opacity: text === "" ? 0 : 0.9
                                    font.family: colDef.mono === true
                                        ? "monospace" : Kirigami.Theme.defaultFont.family
                                }
                                HoverHandler { id: cellHover; enabled: cell.kind === "text" }
                                // the cell +/- actions are built LAZILY: creating
                                // them for every cell means thousands of objects and
                                // a stall on refresh.
                                Loader {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    active: cell.kind === "text" && cellHover.hovered
                                            && cell.val !== ""
                                    visible: active
                                    sourceComponent: Row {
                                        spacing: 1
                                        QQC2.ToolButton {
                                            implicitWidth: Kirigami.Units.gridUnit
                                            implicitHeight: Kirigami.Units.gridUnit
                                            text: "+"
                                            QQC2.ToolTip.text: "Add to the query"
                                            QQC2.ToolTip.visible: hovered
                                            onClicked: table.conditionRequested(
                                                colDef.k, "=", cell.val)
                                        }
                                        QQC2.ToolButton {
                                            implicitWidth: Kirigami.Units.gridUnit
                                            implicitHeight: Kirigami.Units.gridUnit
                                            text: "−"
                                            QQC2.ToolTip.text: "Exclude from the query"
                                            QQC2.ToolTip.visible: hovered
                                            onClicked: table.conditionRequested(
                                                colDef.k, "<>", cell.val)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // the vertical column separators for the whole table: one line per
                // column boundary instead of one per cell (as in State/Events)
                Item {
                    anchors.fill: parent
                    z: 2
                    Repeater {
                        model: table.shownCols
                        Kirigami.Separator {
                            required property int index
                            x: {
                                var w = Kirigami.Units.smallSpacing - hflick.contentX
                                for (var i = 0; i <= index; i++)
                                    w += table.colW(table.shownCols[i])
                                          + Kirigami.Units.smallSpacing
                                return w - Kirigami.Units.smallSpacing - 1
                            }
                            y: 0
                            height: list.height
                            opacity: 0.25
                        }
                    }
                }
            }
        }
    }

    // ---- column chooser ----
    QQC2.Menu {
        id: colMenu
        Repeater {
            model: table.columns
            delegate: QQC2.MenuItem {
                required property var modelData
                visible: (modelData.kind || "text") === "text"
                height: visible ? implicitHeight : 0
                text: modelData.t
                checkable: true
                checked: table.hidden.indexOf(modelData.k) < 0
                onTriggered: table.toggleColumn(modelData.k)
            }
        }
        QQC2.MenuSeparator {}
        QQC2.MenuItem {
            text: "Show All Columns"
            onTriggered: table.hidden = []
        }
    }
}

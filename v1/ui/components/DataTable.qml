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

    // THE SCROLL POSITION SURVIVES A DATA REFRESH.
    // The rows are replaced wholesale every few seconds (a snapshot arrives and
    // the page re-reads its page of the table), and replacing a ListView's model
    // puts it back at the top — so reading anything below the first screen was
    // impossible: every ten seconds the table threw you back to row one.
    // The position is therefore saved before the model changes and put back
    // after, bounded to whatever the new content allows. Going to the top is
    // still right when the table itself changes — a different tab, another page,
    // a new sort — and that is the caller's decision, made with scrollToTop().
    property real _keepY: 0
    onRowsChanged: {
        _keepY = list.contentY
        keepScroll.restart()
    }
    Timer {
        id: keepScroll
        interval: 0                      // after the view has taken the new model
        onTriggered: {
            var maxY = Math.max(0, list.contentHeight - list.height)
            list.contentY = Math.min(table._keepY, maxY)
        }
    }
    function scrollToTop() {
        table._keepY = 0
        list.contentY = 0
        hflick.contentX = 0
    }
    property var selected: null
    // ONE natural row height for EVERY table that uses this template, computed the
    // same way (a hidden ItemDelegate built like a row: default padding + a
    // default-font Label), so Data, Expertise and the group panel cannot drift.
    // A caller may still override it.
    property real rowHeight: _rowProbe.implicitHeight
    QQC2.ItemDelegate {
        id: _rowProbe
        visible: false
        contentItem: QQC2.Label { text: "Ag" }
    }

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

    // an optional formatter: function(row, key) -> string
    property var formatter: null
    // an optional accent colour on the left: function(row) -> color | ""
    property var accent: null

    // a click carrying the row index and the keyboard modifiers, for Ctrl/Shift
    // multi-selection managed by the owner
    signal rowClicked(var row, int index, int modifiers)
    // a right click on a row - the owner may open a context menu
    signal rowRightClicked(var row, int index)
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

    // the columns to draw. Owners pass an already-ordered, already-filtered list
    // (Data computes its visible columns in its own Columns sidebar), so this is
    // simply the columns as given.
    // theme values resolved ONCE for the table instead of per cell (a cell is a
    // plain Text, so it needs them handed down)
    readonly property color textColor: Kirigami.Theme.textColor
    readonly property color separatorColor: Kirigami.Theme.textColor
    readonly property string fontFamily: Kirigami.Theme.defaultFont.family
    readonly property real fontSize: Kirigami.Theme.defaultFont.pointSize

    readonly property var shownCols: columns
    // the leading special columns (checkbox / type icon) and the ordinary value
    // columns, split once for the row delegate — so a value cell is one Label and
    // pays nothing for machinery it does not use. Special columns are leading, so
    // lead + text keeps the shownCols order (widths/hit-testing stay valid).
    readonly property var leadCols: columns.filter(function (c) {
        return (c.kind || "text") !== "text"
    })
    readonly property var textCols: columns.filter(function (c) {
        return (c.kind || "text") === "text"
    })
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
    }
    TextEdit { id: clip; visible: false }

    function rowSelected(row) {
        return table.isSelected ? table.isSelected(row) : (table.selected === row)
    }

    // ---- ONE hover overlay for the whole table (instead of per-cell objects) ----
    property var hoverRow: null       // the row under the cursor
    property int hoverColIdx: -1      // which column
    property real hoverRowY: 0        // its y inside the list content
    // x of a column's right edge in content coordinates (guarded: the index can
    // outlive a column set that shrank, and a binding evaluates even when hidden)
    function colRight(idx) {
        var x = Kirigami.Units.smallSpacing
        var n = Math.min(idx, shownCols.length - 1)
        for (var i = 0; i <= n; i++)
            x += colW(shownCols[i]) + Kirigami.Units.smallSpacing
        return x - Kirigami.Units.smallSpacing
    }
    function colIndexAt(cx) {
        var x = cx - Kirigami.Units.smallSpacing
        for (var i = 0; i < shownCols.length; i++) {
            var w = colW(shownCols[i])
            if (x < w) return i
            x -= w + Kirigami.Units.smallSpacing
        }
        return -1
    }
    function setHover(rowData, rowY, cx) {
        hoverRow = rowData; hoverRowY = rowY; hoverColIdx = colIndexAt(cx)
    }
    function clearHover() { hoverRow = null; hoverColIdx = -1 }

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

                        // checkbox column: a tristate "select the page" box.
                        // A CheckBox toggles its OWN checkState on click, which
                        // breaks the binding to headerCheckState; a MouseArea on
                        // top drives the state through the owner instead, so the
                        // box always reflects headerCheckState.
                        QQC2.CheckBox {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: hcell.kind === "check" && table.showHeaderCheck
                            tristate: true
                            checkState: table.headerCheckState
                            MouseArea {
                                anchors.fill: parent
                                onClicked: table.headerCheckClicked()
                            }
                        }
                        // value column: label + sort direction
                        QQC2.Label {
                            id: hdrLbl
                            anchors.fill: parent
                            anchors.rightMargin: hdrSort.visible ? 20 : 0
                            visible: hcell.kind === "text"
                            text: modelData.t || ""
                            // WHAT THE FIELD MEANS, where the field is. A rule
                            // that declares its fields says what each one holds;
                            // that sentence belongs on the column, not only in
                            // the file nobody has open.
                            QQC2.ToolTip.visible: hdrHover.hovered
                                                  && String(modelData.doc || "") !== ""
                            QQC2.ToolTip.text: String(modelData.doc || "")
                            QQC2.ToolTip.delay: 400
                            HoverHandler { id: hdrHover }
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
                // NO `add:` transition. The rows are replaced wholesale on every
                // data refresh, so every row counted as "added" and ~50 opacity
                // animations ran at once — the table blinked on a timer.
                // a modest look-ahead: a big cacheBuffer creates delegates far off
                // screen, which is paid in full on every rebuild (tab switch)
                cacheBuffer: Kirigami.Units.gridUnit * 8
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
                        // a plain Rectangle, not Kirigami.Separator: this is created
                        // once per row and a Kirigami type costs more to build
                        Rectangle {
                            anchors.bottom: parent.bottom
                            width: parent.width
                            height: 1
                            color: table.separatorColor
                            opacity: 0.35
                        }
                        // the severity/type accent stripe on the left (computed
                        // ONCE per row: it used to call accent() twice, and that
                        // function walks a dozen fields)
                        Rectangle {
                            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                            width: 4
                            readonly property string accentColor:
                                table.accent ? String(table.accent(row.modelData) || "") : ""
                            visible: accentColor !== ""
                            color: accentColor !== "" ? accentColor : "transparent"
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
                        // NB: this MouseArea lives inside the ListView, which is the
                        // Flickable's CONTENT item — so m.x is already a content
                        // coordinate. Adding contentX here shifted every hit test
                        // right by the scroll amount: once scrolled, "+" inserted a
                        // condition on a different column and a double click copied
                        // a different cell.
                        function colAt(px) {
                            var i = table.colIndexAt(px)
                            return i < 0 ? null : table.shownCols[i]
                        }
                        // feed the single hover overlay (no per-cell hover objects)
                        onPositionChanged: m => table.setHover(row.modelData, row.y, m.x)
                        onExited: table.clearHover()
                        onClicked: m => {
                            if (m.button === Qt.RightButton) {
                                table.selected = row.modelData
                                table.rowRightClicked(row.modelData, row.index)
                                return
                            }
                            table.selected = row.modelData
                            table.rowClicked(row.modelData, row.index, m.modifiers)
                        }
                        onDoubleClicked: m => {
                            var cd = colAt(m.x)
                            if (cd && cd.kind !== "check" && cd.kind !== "icon")
                                table.copyValue(table.cellText(row.modelData, cd.k))
                        }
                    }

                    // ONE OBJECT PER CELL. A cell used to be an Item wrapping a
                    // Loader, a Label and a HoverHandler (plus a CheckBox and a
                    // Kirigami.Icon in EVERY cell, merely hidden) — with 21 columns
                    // that is ~1500 objects per page, and the table is rebuilt
                    // several times per tab switch, which cost seconds.
                    // Now: the leading special columns (checkbox / type icon) are
                    // their own small Repeater, and an ordinary value cell is just
                    // a Label. Hover actions come from one table-level overlay.
                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: Kirigami.Units.smallSpacing
                        spacing: Kirigami.Units.smallSpacing
                        Repeater {
                            model: table.leadCols
                            delegate: Item {
                                id: lead
                                required property var modelData
                                readonly property string kind: modelData.kind || "text"
                                width: table.colW(modelData)
                                height: table.rowHeight
                                QQC2.CheckBox {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: lead.kind === "check"
                                    checked: table.isChecked
                                             ? table.isChecked(row.modelData) : false
                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: table.checkToggled(row.modelData, row.index)
                                    }
                                }
                                Loader {
                                    anchors.fill: parent
                                    active: lead.kind === "icon"
                                    // ASYNC: a Kirigami.Icon costs a theme lookup,
                                    // and there is one per row. Loading it off the
                                    // critical path lets the table appear at once —
                                    // the icons fill in a frame later.
                                    asynchronous: true
                                    sourceComponent: Kirigami.Icon {
                                        anchors.centerIn: parent
                                        width: Kirigami.Units.iconSizes.small
                                        height: Kirigami.Units.iconSizes.small
                                        source: table.iconFor ? table.iconFor(row.modelData) : ""
                                        QQC2.ToolTip.text: table.iconTip
                                                           ? table.iconTip(row.modelData) : ""
                                        QQC2.ToolTip.visible: iconHov.hovered
                                                              && QQC2.ToolTip.text !== ""
                                        HoverHandler { id: iconHov }
                                    }
                                }
                            }
                        }
                        Repeater {
                            model: table.textCols
                            // a plain Text, not a QQC2.Label: Label carries the
                            // control/palette machinery, and this is the single
                            // most-created object in the app (columns x rows). The
                            // colour/font come from the table-level cached values.
                            delegate: Text {
                                required property var modelData
                                width: table.colW(modelData)
                                height: table.rowHeight
                                leftPadding: Kirigami.Units.smallSpacing
                                rightPadding: Kirigami.Units.smallSpacing
                                verticalAlignment: Text.AlignVCenter
                                horizontalAlignment: modelData.right === true
                                    ? Text.AlignRight : Text.AlignLeft
                                text: table.cellText(row.modelData, modelData.k)
                                elide: Text.ElideRight
                                color: table.textColor
                                opacity: text === "" ? 0 : 0.9
                                font.family: modelData.mono === true
                                    ? "monospace" : table.fontFamily
                                font.pointSize: table.fontSize
                            }
                        }
                    }
                }

                // ONE line per column boundary for the whole table (not one per
                // cell). This Item is a child of the ListView, i.e. of the
                // Flickable's CONTENT: coordinates here are content coordinates, so
                // the lines must NOT subtract contentX (they used to drift away
                // from the columns as soon as the table was scrolled sideways), and
                // they must span the whole content height, not one viewport (they
                // used to vanish after scrolling down a screen).
                Item {
                    anchors.fill: parent
                    z: 2
                    Repeater {
                        model: table.shownCols
                        Rectangle {
                            required property int index
                            x: table.colRight(index) - 1
                            y: 0
                            width: 1
                            height: list.contentHeight
                            color: table.separatorColor
                            opacity: 0.25
                        }
                    }
                }

                // THE SINGLE "+/-" OVERLAY: one instance for the whole table,
                // moved to whichever cell the cursor is over. Replaces a
                // HoverHandler plus a Loader in every cell.
                Row {
                    id: hoverOverlay
                    z: 5
                    spacing: 1
                    readonly property var cd: (table.hoverColIdx >= 0
                                               && table.hoverColIdx < table.shownCols.length)
                                              ? table.shownCols[table.hoverColIdx] : null
                    readonly property string val: (cd && (cd.kind || "text") === "text"
                                                   && table.hoverRow)
                                                  ? table.cellText(table.hoverRow, cd.k) : ""
                    visible: val !== ""
                    x: (table.hoverColIdx >= 0 ? table.colRight(table.hoverColIdx) : 0)
                       - width - 2
                    y: table.hoverRowY + (table.rowHeight - height) / 2
                    QQC2.ToolButton {
                        implicitWidth: Kirigami.Units.gridUnit
                        implicitHeight: Kirigami.Units.gridUnit
                        text: "+"
                        QQC2.ToolTip.text: "Add to the query"
                        QQC2.ToolTip.visible: hovered
                        onClicked: if (hoverOverlay.cd)
                            table.conditionRequested(hoverOverlay.cd.k, "=", hoverOverlay.val)
                    }
                    QQC2.ToolButton {
                        implicitWidth: Kirigami.Units.gridUnit
                        implicitHeight: Kirigami.Units.gridUnit
                        text: "−"
                        QQC2.ToolTip.text: "Exclude from the query"
                        QQC2.ToolTip.visible: hovered
                        onClicked: if (hoverOverlay.cd)
                            table.conditionRequested(hoverOverlay.cd.k, "<>", hoverOverlay.val)
                    }
                }
            }
        }
    }

}

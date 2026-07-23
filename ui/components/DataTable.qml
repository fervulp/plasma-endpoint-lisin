import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "."

// THE TEMPLATE TABLE for all sections of the application.
//
// Principle 11: many elements of the same shape means a table. Every section
// used to write its own: its own columns, its own header, its own sidebar - and
// they drifted apart. Here is one implementation, in which:
//   * ONE description of the columns is read by the header and the rows - the
//     widths cannot drift;
//   * a choice of visible columns and their order (the "Columns" button);
//   * a pinned header, zebra striping, a fixed row height;
//   * `reuseItems` - without it a long list stalls while recreating delegates;
//   * a click on a row = selection and a signal outwards (the owner opens the
//     sidebar);
//   * hovering a cell gives "+"/"-" - add the value to the query.
//
// The component knows nothing about where the rows came from: it may be an SQL
// result or a list computed in Python.
Item {
    id: table

    // [{ k, t, w, fill, right, mono }] - key, header, width in gridUnit
    //
    // HORIZONTAL SCROLL, LIKE STATE AND EVENTS. Views with many columns (the
    // network panel has nine) do not fit the width; without a scroll the fill
    // column collapsed to "/..." and the rest was squeezed. The header and the
    // rows share one contentWidth and scroll together, so a dashboard table
    // looks and behaves exactly like the State and Events tables.
    property var columns: []
    property var rows: []
    property var selected: null
    property int rowHeight: Kirigami.Units.gridUnit * 2.4
    // the fixed part of the width; the fill column takes whatever is left of the
    // viewport, and if the fixed part already exceeds it the table scrolls
    readonly property real gu: Kirigami.Units.gridUnit
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
    function colW(cd) { return cd.fill === true ? fillW : (cd.w || 6) * gu }
    // the keys of the hidden columns and the order - the state of the view
    property var hidden: []
    property var order: []
    // an optional formatter: function(row, key) -> string
    property var formatter: null
    // an optional accent colour on the left: function(row) -> color | ""
    property var accent: null

    signal rowActivated(var row)
    signal valueCopied(string value)
    // a click on the header: the owner decides how to apply the order (SQL or list)
    signal sortRequested(string field, bool desc)

    // the current sorting - shown by an icon in the header
    property string sortCol: ""
    property bool sortDesc: false
    function sortBy(k) {
        if (sortCol === k) sortDesc = !sortDesc
        else { sortCol = k; sortDesc = false }
        table.sortRequested(sortCol, sortDesc)
    }
    signal conditionRequested(string field, string op, string value)

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
        // silently assigned undefined to a QString ("Unable to assign
        // [undefined] to QString" on every cell of that column).
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

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- header ----
        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: hdrRow.implicitHeight
            clip: true
            Row {
                id: hdrRow
                x: -hflick.contentX          // scrolls in step with the rows
                leftPadding: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing
                Repeater {
                    model: table.shownCols
                    delegate: Item {
                        required property var modelData
                        width: table.colW(modelData)
                        height: hdrLbl.implicitHeight
                        QQC2.Label {
                            id: hdrLbl
                            anchors.fill: parent
                            anchors.rightMargin: hdrSort.visible ? 20 : 0
                            text: modelData.t
                            opacity: 0.6
                            font.bold: true
                            elide: Text.ElideRight
                            horizontalAlignment: modelData.right === true
                                ? Text.AlignRight : Text.AlignLeft
                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                        }
                        Kirigami.Icon {
                            id: hdrSort
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            width: Kirigami.Units.iconSizes.small
                            height: Kirigami.Units.iconSizes.small
                            visible: table.sortCol === modelData.k
                            source: table.sortDesc ? "view-sort-descending"
                                                   : "view-sort-ascending"
                        }
                        TapHandler { onTapped: table.sortBy(modelData.k) }
                    }
                }
            }
        }
        Kirigami.Separator { Layout.fillWidth: true }

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
                // new rows fade in rather than appearing abruptly; the animator
                // runs on the render thread and does not touch scrolling cost
                add: Transition {
                    OpacityAnimator { from: 0; to: 1; duration: Kirigami.Units.shortDuration }
                }
                displaced: Transition {
                    NumberAnimation { property: "y"; duration: Kirigami.Units.shortDuration
                                      easing.type: Easing.OutCubic }
                }
                cacheBuffer: Kirigami.Units.gridUnit * 40
                QQC2.ScrollBar.vertical: QQC2.ScrollBar {}

                delegate: QQC2.ItemDelegate {
                    id: row
                    required property var modelData
                    required property int index
                    width: table.contentW
                    height: table.rowHeight
                    padding: 0
                    leftPadding: Kirigami.Units.smallSpacing
                    onClicked: { table.selected = modelData; table.rowActivated(modelData) }
                    background: Rectangle {
                        color: table.selected === row.modelData
                               ? Qt.alpha(Kirigami.Theme.highlightColor, 0.20)
                               : (row.hovered
                                  ? Qt.alpha(Kirigami.Theme.textColor, 0.06)
                                  : (row.index % 2
                                     ? Qt.alpha(Kirigami.Theme.textColor, 0.03)
                                     : "transparent"))
                        // hover and selection fade instead of snapping; a colour
                        // Behavior is cheap even on a full page of reused rows
                        Behavior on color {
                            ColorAnimation { duration: Kirigami.Units.shortDuration }
                        }
                        Rectangle {
                            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                            width: 3
                            visible: table.accent && table.accent(row.modelData) !== ""
                            color: table.accent ? table.accent(row.modelData) : "transparent"
                        }
                    }
                    contentItem: Row {
                        spacing: Kirigami.Units.smallSpacing
                        Repeater {
                            model: table.shownCols
                            delegate: Item {
                                required property var modelData
                                property var colDef: modelData
                                width: table.colW(colDef)
                                height: table.rowHeight
                                property string val: table.cellText(row.modelData, colDef.k)

                                QQC2.Label {
                                    anchors.fill: parent
                                    // AIR INSIDE A CELL: the text must not lie
                                    // right against the column separator
                                    anchors.leftMargin: Kirigami.Units.smallSpacing
                                    anchors.rightMargin: cellHover.hovered
                                                         ? 34 : Kirigami.Units.smallSpacing
                                    verticalAlignment: Text.AlignVCenter
                                    horizontalAlignment: colDef.right === true
                                        ? Text.AlignRight : Text.AlignLeft
                                    text: parent.val
                                    elide: Text.ElideRight
                                    opacity: text === "" ? 0 : 0.9
                                    font.family: colDef.mono === true
                                        ? "monospace" : Kirigami.Theme.defaultFont.family
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                }
                                HoverHandler { id: cellHover }
                                // A click on a cell selects the row, a double click
                                // copies the value (as in the event feed).
                                TapHandler {
                                    acceptedButtons: Qt.LeftButton
                                    onSingleTapped: {
                                        table.selected = row.modelData
                                        table.rowActivated(row.modelData)
                                    }
                                    onDoubleTapped: table.copyValue(parent.val)
                                }
                                // The cell actions are created LAZILY: building them
                                // for every cell at once means thousands of objects
                                // and a noticeable stall on refresh.
                                Loader {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    active: cellHover.hovered && parent.val !== ""
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
                                                colDef.k, "=", table.cellText(row.modelData, colDef.k))
                                        }
                                        QQC2.ToolButton {
                                            implicitWidth: Kirigami.Units.gridUnit
                                            implicitHeight: Kirigami.Units.gridUnit
                                            text: "−"
                                            QQC2.ToolTip.text: "Exclude from the query"
                                            QQC2.ToolTip.visible: hovered
                                            onClicked: table.conditionRequested(
                                                colDef.k, "<>", table.cellText(row.modelData, colDef.k))
                                        }
                                    }
                                }
                            }
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

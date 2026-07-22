import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

// ШАБЛОННАЯ ТАБЛИЦА для всех разделов приложения.
//
// Положение 11: много однотипных элементов — это таблица. Раньше каждый
// раздел писал свою: свои колонки, своя шапка, свой sidebar — и они
// разъезжались. Здесь одна реализация, у которой:
//   * ОДНО описание колонок читают и шапка, и строки — ширины не разъедутся;
//   * выбор видимых колонок и их порядка (кнопка «Columns»);
//   * закреплённая шапка, зебра, фиксированная высота строки;
//   * `reuseItems` — без него длинный список подвисает на пересоздании;
//   * клик по строке = выбор и сигнал наружу (хозяин открывает sidebar);
//   * наведение на ячейку даёт «+»/«−» — добавить значение в запрос.
//
// Компонент ничего не знает о том, откуда пришли строки: это может быть
// SQL-выборка или список, посчитанный в Python.
Item {
    id: table

    // [{ k, t, w, fill, right, mono }] — ключ, заголовок, ширина в gridUnit
    property var columns: []
    property var rows: []
    property var selected: null
    property int rowHeight: Kirigami.Units.gridUnit * 2.4
    // ключи скрытых колонок и порядок — состояние вида
    property var hidden: []
    property var order: []
    // необязательный форматтер: function(row, key) -> string
    property var formatter: null
    // необязательный цвет акцента слева: function(row) -> color | ""
    property var accent: null

    signal rowActivated(var row)
    signal valueCopied(string value)
    // клик по заголовку: хозяин решает, как применить порядок (SQL или список)
    signal sortRequested(string field, bool desc)

    // текущая сортировка — показывается иконкой в шапке
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
        if (formatter) return formatter(row, key)
        var v = row[key]
        return (v === undefined || v === null) ? "" : String(v)
    }
    // В QML нет прямого доступа к буферу обмена — кладём через скрытый TextEdit
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
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing
            Repeater {
                model: table.shownCols
                delegate: Item {
                    required property var modelData
                    Layout.preferredWidth: modelData.fill === true
                        ? -1 : Kirigami.Units.gridUnit * (modelData.w || 6)
                    Layout.fillWidth: modelData.fill === true
                    Layout.preferredHeight: hdrLbl.implicitHeight
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
            // ВЫБОР КОЛОНОК УБРАН: колонки задаёт SELECT в строке запроса
        }
        Kirigami.Separator { Layout.fillWidth: true }

        // ---- rows ----
        QQC2.ScrollView {
            id: scroller
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            ListView {
                id: list
                model: table.rows
                reuseItems: true
                cacheBuffer: Kirigami.Units.gridUnit * 40
                QQC2.ScrollBar.vertical: QQC2.ScrollBar {}

                delegate: QQC2.ItemDelegate {
                    id: row
                    required property var modelData
                    required property int index
                    width: ListView.view.width
                    height: table.rowHeight
                    onClicked: { table.selected = modelData; table.rowActivated(modelData) }
                    background: Rectangle {
                        color: table.selected === row.modelData
                               ? Qt.alpha(Kirigami.Theme.highlightColor, 0.20)
                               : (row.hovered
                                  ? Qt.alpha(Kirigami.Theme.textColor, 0.06)
                                  : (row.index % 2
                                     ? Qt.alpha(Kirigami.Theme.textColor, 0.03)
                                     : "transparent"))
                        Rectangle {
                            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                            width: 3
                            visible: table.accent && table.accent(row.modelData) !== ""
                            color: table.accent ? table.accent(row.modelData) : "transparent"
                        }
                    }
                    contentItem: RowLayout {
                        spacing: Kirigami.Units.smallSpacing
                        Repeater {
                            model: table.shownCols
                            delegate: Item {
                                required property var modelData
                                property var colDef: modelData
                                Layout.preferredWidth: colDef.fill === true
                                    ? -1 : Kirigami.Units.gridUnit * (colDef.w || 6)
                                Layout.fillWidth: colDef.fill === true
                                Layout.preferredHeight: table.rowHeight
                                property string val: table.cellText(row.modelData, colDef.k)

                                QQC2.Label {
                                    anchors.fill: parent
                                    // ВОЗДУХ В ЯЧЕЙКЕ: текст не должен лежать
                                    // вплотную к разделителю колонок
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
                                // Клик по ячейке выделяет строку, двойной —
                                // копирует значение (как в ленте событий).
                                TapHandler {
                                    acceptedButtons: Qt.LeftButton
                                    onSingleTapped: {
                                        table.selected = row.modelData
                                        table.rowActivated(row.modelData)
                                    }
                                    onDoubleTapped: table.copyValue(parent.val)
                                }
                                // Действия ячейки создаются ЛЕНИВО: строить их
                                // для каждой ячейки сразу — это тысячи объектов
                                // и заметное подвисание при обновлении.
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

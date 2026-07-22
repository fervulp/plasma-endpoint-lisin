import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

// ВЫБОР ПОЛЯ С ПОИСКОМ.
//
// Обычный выпадающий список годится на десяток пунктов; у событий полей 98,
// и листать их мышью — мучение. Поэтому: кнопка -> всплывающий список с
// строкой поиска, отбор по подстроке, Enter берёт первое совпадение.
//
// Два режима:
//   * одиночный (checkMode: false) — выбрали поле, список закрылся;
//   * множественный (checkMode: true) — отметки, список остаётся открытым
//     (так набирается выборка SELECT).
Item {
    id: fp

    property var fields: []            // список имён (строки)
    property string current: ""        // выбранное (одиночный режим)
    property bool checkMode: false
    property var checked: []           // отмеченные (множественный режим)
    property string label: "field"     // подпись, когда ничего не выбрано
    property string iconName: "view-list-details"
    property bool flatButton: false
    // ПОДСТАВИТЬ ТЕКУЩЕЕ ИМЯ В ПОИСК: так поле можно не выбирать заново, а
    // ПОПРАВИТЬ написание — строка уже заполнена и выделена.
    property bool prefillCurrent: false
    // поля, которые стоит предложить в первую очередь (у нас — те, что в
    // SELECT): помечаются в списке, но выбрать можно любое
    property var preferred: []

    signal picked(string name)

    implicitWidth: btn.implicitWidth
    implicitHeight: btn.implicitHeight

    readonly property var filtered: {
        var q = searchField.text.toLowerCase()
        if (!q) return fields
        var out = []
        for (var i = 0; i < fields.length; i++)
            if (String(fields[i]).toLowerCase().indexOf(q) >= 0) out.push(fields[i])
        return out
    }

    function open() { pop.open() }

    QQC2.Button {
        id: btn
        anchors.fill: parent
        text: fp.checkMode ? fp.label : (fp.current || fp.label)
        icon.name: fp.iconName
        flat: fp.flatButton
        display: (fp.checkMode && fp.label === "")
                 ? QQC2.AbstractButton.IconOnly
                 : QQC2.AbstractButton.TextBesideIcon
        onClicked: pop.open()
    }

    QQC2.Popup {
        id: pop
        y: btn.height
        width: Math.max(fp.width, Kirigami.Units.gridUnit * 16)
        height: Kirigami.Units.gridUnit * 18
        padding: Kirigami.Units.smallSpacing
        onOpened: {
            searchField.text = fp.prefillCurrent ? fp.current : ""
            searchField.forceActiveFocus()
            searchField.selectAll()
        }

        ColumnLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            QQC2.TextField {
                id: searchField
                Layout.fillWidth: true
                placeholderText: "search a field…"
                onAccepted: {
                    if (fp.filtered.length) {
                        fp.picked(String(fp.filtered[0]))
                        if (!fp.checkMode) pop.close(); else text = ""
                    }
                }
            }
            QQC2.Label {
                Layout.fillWidth: true
                opacity: 0.6
                text: fp.filtered.length + " of " + fp.fields.length
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                ListView {
                    model: fp.filtered
                    reuseItems: true
                    delegate: QQC2.ItemDelegate {
                        required property var modelData
                        width: ListView.view.width
                        height: Kirigami.Units.gridUnit * 2
                        onClicked: {
                            fp.picked(String(modelData))
                            if (!fp.checkMode) pop.close()
                        }
                        contentItem: RowLayout {
                            spacing: Kirigami.Units.smallSpacing
                            // Галочка ТОЛЬКО у выбранных: пустые квадратики
                            // у всей сотни полей — шум, а не информация.
                            Kirigami.Icon {
                                visible: fp.checkMode && fp.checked.indexOf(modelData) >= 0
                                source: "checkmark"
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                            }
                            Item {
                                visible: fp.checkMode && fp.checked.indexOf(modelData) < 0
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: 1
                            }
                            QQC2.Label {
                                Layout.fillWidth: true
                                text: modelData
                                elide: Text.ElideRight
                                font.family: "monospace"
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                            QQC2.Label {
                                visible: fp.preferred.indexOf(modelData) >= 0
                                text: "in SELECT"
                                opacity: 0.55
                                font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                            }
                        }
                    }
                }
            }
        }
    }
}

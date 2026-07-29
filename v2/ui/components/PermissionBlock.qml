import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

// ONE PERMISSION FAMILY, AS A BLOCK.
//
// A permission list reads badly as prose: forty entries in seven families, some
// granted, some taken away, and the eye has nowhere to rest. As blocks it reads
// as an inventory — each family is a box you can take in at a glance, and every
// entry inside is a chip you either see or do not.
//
// THE STATE IS IN THE CHIP, not in a column heading, because a permission has
// three states that must never be confused: GRANTED (the sandbox will give it),
// DENIED HERE (this machine took it away, and the application still asks for it),
// and NOT ASKED FOR (absent entirely — shown as nothing at all, because an empty
// space is the honest picture of a permission nobody wants).
//
// The count in the header is the one number that answers "is this family open or
// closed" without reading a single chip.
Item {
    id: block

    property string title: ""
    property string icon: "dialog-information"
    property string why: ""
    property var granted: []
    property var denied: []
    // a family that carries the sandbox escape is not comparable to the others,
    // and the block says so rather than leaving it as one chip among many
    property bool alarming: false

    implicitHeight: body.implicitHeight + Kirigami.Units.largeSpacing * 2

    Rectangle {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing / 2
        radius: Kirigami.Units.smallSpacing
        color: Kirigami.Theme.backgroundColor
        border.width: 1
        border.color: block.alarming
                      ? Qt.alpha(Kirigami.Theme.negativeTextColor, 0.5)
                      : Qt.alpha(Kirigami.Theme.textColor, 0.12)

        ColumnLayout {
            id: body
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.smallSpacing

            // ---- header: what this family is, and how open it is
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Icon {
                    source: block.icon
                    implicitWidth: Kirigami.Units.iconSizes.smallMedium
                    implicitHeight: Kirigami.Units.iconSizes.smallMedium
                    color: block.alarming ? Kirigami.Theme.negativeTextColor
                                          : Kirigami.Theme.textColor
                }
                QQC2.Label {
                    text: block.title
                    font.bold: true
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                // the number first, the word after it: "3 granted" scans, "granted: 3"
                // makes the eye read a label before it reaches the fact
                QQC2.Label {
                    text: block.granted.length + " granted"
                    opacity: block.granted.length ? 0.75 : 0.4
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
                QQC2.Label {
                    visible: block.denied.length > 0
                    text: "· " + block.denied.length + " denied"
                    color: Kirigami.Theme.negativeTextColor
                    opacity: 0.9
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
            }

            // ---- the chips themselves, wrapping to the block's width
            Flow {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                visible: block.granted.length > 0 || block.denied.length > 0

                Repeater {
                    model: block.granted
                    delegate: PermChip {
                        required property var modelData
                        text: String(modelData)
                        state_: "granted"
                        alarming: block.alarming
                    }
                }
                Repeater {
                    model: block.denied
                    delegate: PermChip {
                        required property var modelData
                        text: String(modelData)
                        state_: "denied"
                    }
                }
            }

            // NOTHING IS A RESULT TOO, and it is the result this application is
            // being built to produce — so it is stated rather than left as a gap
            // that reads like a page that failed to load.
            QQC2.Label {
                Layout.fillWidth: true
                visible: block.granted.length === 0 && block.denied.length === 0
                text: "nothing — the application never asked for this"
                opacity: 0.45
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }

            QQC2.Label {
                Layout.fillWidth: true
                text: block.why
                visible: text !== ""
                wrapMode: Text.WordWrap
                opacity: 0.5
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
        }
    }
}

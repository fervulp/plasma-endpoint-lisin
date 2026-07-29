import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

// ONE PERMISSION, AS A CHIP.
//
// The state is carried by the chip's own appearance, not by which column it sits
// in — so a screenshot of half the page is still readable, and so the two states
// cannot be confused when the page is scrolled:
//
//   granted   a filled chip: the sandbox will hand this over
//   denied    outlined, struck through, in the negative colour: this machine took
//             it away, and the application is still asking for it
//
// `state_` rather than `state` because `state` is taken by QML itself and
// assigning to it silently drives the item's state machine instead.
Rectangle {
    id: chip

    property string text: ""
    property string state_: "granted"
    property bool alarming: false

    readonly property bool denied: state_ === "denied"

    implicitWidth: label.implicitWidth + Kirigami.Units.largeSpacing
                   + (mark.visible ? mark.width + Kirigami.Units.smallSpacing : 0)
    implicitHeight: label.implicitHeight + Kirigami.Units.smallSpacing
    radius: Kirigami.Units.smallSpacing / 2

    color: denied
           ? "transparent"
           : Qt.alpha(alarming ? Kirigami.Theme.negativeTextColor
                               : Kirigami.Theme.highlightColor, 0.18)
    border.width: denied ? 1 : 0
    border.color: Qt.alpha(Kirigami.Theme.negativeTextColor, 0.6)

    Row {
        anchors.centerIn: parent
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Icon {
            id: mark
            visible: chip.denied || chip.alarming
            source: chip.denied ? "lock" : "dialog-warning"
            width: Kirigami.Units.iconSizes.small
            height: Kirigami.Units.iconSizes.small
            anchors.verticalCenter: parent.verticalCenter
            color: Kirigami.Theme.negativeTextColor
        }
        QQC2.Label {
            id: label
            text: chip.text
            anchors.verticalCenter: parent.verticalCenter
            color: chip.denied ? Kirigami.Theme.negativeTextColor
                               : Kirigami.Theme.textColor
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            font.strikeout: chip.denied
            font.family: "monospace"      // these are machine words, not prose
        }
    }

    // The permission's own name is what flatpak calls it; the chip shows that
    // verbatim, and the tooltip says what it means in the sandbox.
    HoverHandler { id: hh }
    QQC2.ToolTip.visible: hh.hovered
    QQC2.ToolTip.delay: 400
    QQC2.ToolTip.text: chip.denied
                       ? chip.text + " — asked for by the application, denied on "
                         + "this machine. It takes effect on the next launch."
                       : chip.text + " — the sandbox will grant this."
}

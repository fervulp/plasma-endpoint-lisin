import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "Fmt.js" as Fmt

// ONE field row for EVERY sidebar. The "Data" Details panel is the reference
// (principle 17: the sidebars look alike everywhere): a dimmed field name, the
// value below on a subtle rounded panel, a copy button, and - the same as the
// tables - an ISO timestamp shown in LOCAL time, not raw UTC. Long or secret
// values are monospaced; a secret is masked until the eye is clicked.
ColumnLayout {
    id: field
    property string label: ""
    property var value: ""
    property bool mono: false
    property bool sensitive: false
    property bool copyable: true
    property bool revealed: false

    Layout.fillWidth: true
    spacing: 1
    visible: String(value === undefined || value === null ? "" : value) !== ""

    // format ISO timestamps exactly as the tables do (Fmt.maybeLocal); anything
    // else is shown as-is
    readonly property string shown:
        String(Fmt.maybeLocal(value === undefined || value === null ? "" : value))

    RowLayout {
        Layout.fillWidth: true
        QQC2.Label {
            text: field.label
            opacity: 0.55
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            Layout.fillWidth: true
            elide: Text.ElideRight
        }
        QQC2.ToolButton {
            icon.name: "edit-copy"
            visible: field.copyable && (!field.sensitive || field.revealed)
            implicitHeight: Kirigami.Units.gridUnit * 1.4
            implicitWidth: Kirigami.Units.gridUnit * 1.4
            QQC2.ToolTip.text: "Copy value"
            QQC2.ToolTip.visible: hovered
            onClicked: { clip.text = field.shown; clip.selectAll(); clip.copy() }
        }
        QQC2.ToolButton {   // the eye for secret fields
            visible: field.sensitive
            icon.name: field.revealed ? "view-hidden" : "view-visible"
            implicitHeight: Kirigami.Units.gridUnit * 1.4
            implicitWidth: Kirigami.Units.gridUnit * 1.4
            onClicked: field.revealed = !field.revealed
        }
    }
    QQC2.TextArea {
        Layout.fillWidth: true
        readOnly: true
        wrapMode: TextEdit.Wrap
        text: (field.sensitive && !field.revealed)
              ? "•••••••••  (click the eye to reveal)" : field.shown
        font.family: (field.mono || field.sensitive)
                     ? "monospace" : Kirigami.Theme.defaultFont.family
        font.pointSize: Kirigami.Theme.smallFont.pointSize
        background: Rectangle {
            color: Kirigami.Theme.alternateBackgroundColor
            radius: 4
        }
    }
    TextEdit { id: clip; visible: false }
}

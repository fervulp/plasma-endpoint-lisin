import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components"
import "../pages"
import "."

// EDR module error stream — surfaces failing inputs / normalization /
// expertise YAML so modules can be tracked and fixed.
ColumnLayout {
    id: view
    spacing: 0
    property var log: backend.errorsLog()

    Timer {
        interval: 5000; running: view.visible; repeat: true
        onTriggered: view.log = backend.errorsLog()
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.margins: Kirigami.Units.smallSpacing
        Kirigami.Heading { level: 3; text: "Module errors"; Layout.fillWidth: true }
    }
    Kirigami.Separator { Layout.fillWidth: true }

    QQC2.ScrollView {
        Layout.fillWidth: true
        Layout.fillHeight: true
        ListView {
            model: view.log
            clip: true
            spacing: 1
            delegate: Kirigami.AbstractCard {
                width: ListView.view.width
                contentItem: RowLayout {
                    spacing: Kirigami.Units.smallSpacing
                    Kirigami.Icon {
                        source: "dialog-error"
                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                    }
                    ColumnLayout {
                        spacing: 0
                        Layout.fillWidth: true
                        QQC2.Label {
                            text: modelData.module + (modelData.time ? "  ·  " + modelData.time : "")
                            font.bold: true
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                        QQC2.Label {
                            text: modelData.error
                            color: Kirigami.Theme.negativeTextColor
                            wrapMode: Text.Wrap
                            Layout.fillWidth: true
                        }
                    }
                }
            }
            Kirigami.PlaceholderMessage {
                anchors.centerIn: parent
                width: parent.width - Kirigami.Units.gridUnit * 4
                visible: view.log.length === 0
                icon.name: "checkmark"
                text: "No errors"
                explanation: "Failing inputs, normalization rules and\nexpertise YAML will appear here."
            }
        }
    }

    Kirigami.Separator { Layout.fillWidth: true }
    RowLayout {   // controls at the bottom
        Layout.fillWidth: true
        Layout.margins: Kirigami.Units.smallSpacing
        QQC2.Label {
            opacity: 0.6
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            text: view.log.length + (view.log.length === 1 ? " error" : " errors")
        }
        Item { Layout.fillWidth: true }
        QQC2.ToolButton {
            icon.name: "view-refresh"; text: "Refresh"
            display: QQC2.AbstractButton.IconOnly
            QQC2.ToolTip.text: "Refresh"; QQC2.ToolTip.visible: hovered
            onClicked: view.log = backend.errorsLog()
        }
        QQC2.ToolButton {
            icon.name: "edit-clear-all"; text: "Clear"
            display: QQC2.AbstractButton.IconOnly
            QQC2.ToolTip.text: "Clear"; QQC2.ToolTip.visible: hovered
            onClicked: { backend.clearErrors(); view.log = [] }
        }
    }
}

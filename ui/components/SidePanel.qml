import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "."

// Unified right sidebar: View-tinted background, icon header, collapse
// button and slide animation. Usage:
//   SidePanel { id: p; title: "AI"; iconName: "help-hint"
//               onCloseRequested: p.open = false;  ...content... }
Rectangle {
    id: panel

    property string title: ""
    property string iconName: ""
    property bool open: false
    property real panelWidth: Kirigami.Units.gridUnit * 20
    signal closeRequested()
    default property alias content: body.data

    Kirigami.Theme.colorSet: Kirigami.Theme.View
    Kirigami.Theme.inherit: false
    color: Kirigami.Theme.backgroundColor

    Layout.fillHeight: true
    Layout.preferredWidth: open ? panelWidth : 0
    // IMPORTANT: visibility is tied to open, not only to Layout.preferredWidth.
    // The attached layout property may not have been computed yet at the moment
    // the binding is evaluated - the panel then stayed invisible with open=true
    // (an event was selected but the sidebar did not appear). A width > 1 is only
    // needed so that the panel does not flicker during the closing animation.
    visible: open || Layout.preferredWidth > 1
    clip: true

    Behavior on Layout.preferredWidth {
        NumberAnimation {
            duration: Kirigami.Units.longDuration
            easing.type: Easing.OutCubic
        }
    }

    Kirigami.Separator {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
    }

    MouseArea {   // resizing the sidebar by its left edge
        width: 8
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        z: 10
        cursorShape: Qt.SplitHCursor
        preventStealing: true
        property real sx
        property real sw
        onPressed: m => { sx = m.x; sw = panel.panelWidth }
        onPositionChanged: m => {
            if (pressed)
                panel.panelWidth = Math.max(Kirigami.Units.gridUnit * 10,
                    Math.min(Kirigami.Units.gridUnit * 40, sw - (m.x - sx)))
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing
        anchors.leftMargin: Kirigami.Units.smallSpacing * 2
        spacing: Kirigami.Units.smallSpacing
        width: panel.panelWidth

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            Kirigami.Icon {
                source: panel.iconName
                visible: panel.iconName !== ""
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
            }
            Kirigami.Heading {
                level: 3
                text: panel.title
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
            QQC2.ToolButton {
                icon.name: "sidebar-collapse-right"
                QQC2.ToolTip.text: "Collapse"
                QQC2.ToolTip.visible: hovered
                onClicked: panel.closeRequested()
            }
        }
        Kirigami.Separator { Layout.fillWidth: true }

        ColumnLayout {
            id: body
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Kirigami.Units.smallSpacing
        }
    }
}

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components"
import "../views"
import "."

Kirigami.ScrollablePage {
    id: page
    title: "Pipelines"

    property var pipelines: backend.pipelinesInfo()

    Connections {
        target: backend
        function onPipelineReady(info) { page.pipelines = info }
    }

    actions: [
        Kirigami.Action {
            icon.name: "list-add"
            text: "New pipeline"
            onTriggered: { newName.text = ""; newDialog.open() }
        }
    ]

    ListView {
        model: page.pipelines
        spacing: Kirigami.Units.smallSpacing

        delegate: Kirigami.AbstractCard {
            width: ListView.view.width
            contentItem: RowLayout {
                spacing: Kirigami.Units.largeSpacing

                // Status accent: a failing pipeline used to add a third line of
                // red text, which made every card a different height and moved
                // the buttons around. State is now an icon, the message a
                // tooltip, so all cards keep one shape.
                Kirigami.Icon {
                    source: modelData.error !== "" ? "dialog-error" : "view-flow"
                    color: modelData.error !== ""
                           ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
                    Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                    QQC2.ToolTip.text: modelData.error
                    QQC2.ToolTip.visible: errHover.hovered && modelData.error !== ""
                    HoverHandler { id: errHover }
                }
                ColumnLayout {
                    spacing: 0
                    Layout.fillWidth: true
                    Kirigami.Heading { level: 3; text: modelData.title }
                    QQC2.Label {
                        opacity: 0.7
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        color: modelData.error !== ""
                               ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
                        text: modelData.error !== ""
                              ? "failed — " + modelData.error
                              : "elements: " + modelData.nodes
                                + " · inputs: " + modelData.inputs
                    }
                }

                // One action area, both buttons the same shape and always in
                // the same place — they used to be an icon-only ToolButton next
                // to a text Button, so they never lined up between rows.
                RowLayout {
                    spacing: Kirigami.Units.smallSpacing
                    QQC2.Button {
                        text: "Run"
                        icon.name: "media-playback-start"
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 6
                        QQC2.ToolTip.text: "Run every input of this pipeline now"
                        QQC2.ToolTip.visible: hovered
                        onClicked: backend.runPipeline(modelData.name)
                    }
                    QQC2.Button {
                        text: "Open Graph"
                        icon.name: "distribute-graph-directed"
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 9
                        onClicked: root.pageStack.layers.push(
                                       graphComp, { pipeName: modelData.name })
                    }
                }
            }
        }

        Kirigami.PlaceholderMessage {
            anchors.centerIn: parent
            visible: parent.count === 0
            text: "No pipelines"
        }
    }

    Component { id: graphComp; PipelineGraphPage {} }

    // open a pipeline's graph editor by name (used by the Open Graph buttons and
    // by the documentation screenshots)
    function openGraph(name) {
        root.pageStack.layers.push(graphComp, { pipeName: name })
    }

    Kirigami.PromptDialog {
        id: newDialog
        title: "New pipeline"
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        onAccepted: if (newName.text.trim()) backend.createPipeline(newName.text)
        QQC2.TextField { id: newName; placeholderText: "Title" }
    }
}

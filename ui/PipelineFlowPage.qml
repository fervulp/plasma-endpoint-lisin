import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

// Витрина конвейера: список потоков данных (по одному на источник) вместо
// графа. Читать удобно — одна строка = источник → normalize → [enrich] →
// output со статусом. Правка топологии осталась в графе-редакторе (кнопка
// «Graph editor»), поэтому переключиться обратно можно в один клик.
Kirigami.ScrollablePage {
    id: page
    property string pipeName: ""
    property var flows: backend.pipelineFlows(pipeName)
    title: "Pipeline: " + pipeName

    // человекочитаемые названия стадий + иконки для чипов
    readonly property var kindName: ({ input: "input", normalize: "normalize",
        enrich: "enrich", filter: "filter", correlation: "detect", output: "output" })
    readonly property var kindIcon: ({ input: "document-import",
        normalize: "code-context", enrich: "link", filter: "view-filter",
        correlation: "police-badge", output: "document-export" })

    function refresh() { page.flows = backend.pipelineFlows(pipeName) }

    Connections {
        target: backend
        function onPipelineReady(info) { page.refresh() }
    }

    actions: [
        Kirigami.Action {
            icon.name: "go-previous"; text: "Back"
            onTriggered: root.pageStack.layers.pop()
        },
        Kirigami.Action {
            icon.name: "media-playback-start"; text: "Run now"
            onTriggered: backend.runPipeline(pipeName)
        },
        Kirigami.Action {
            icon.name: "distribute-graph-directed"; text: "Graph editor"
            tooltip: "Edit pipeline topology as a node graph"
            onTriggered: root.pageStack.layers.push(graphComp, { pipeName: page.pipeName })
        },
        Kirigami.Action {
            icon.name: "view-refresh"; text: "Refresh"
            onTriggered: page.refresh()
        }
    ]

    Component { id: graphComp; PipelineGraphPage {} }

    // ---- диалог «Last run» узла: вход/выход последнего выполнения ----
    Kirigami.Dialog {
        id: peekDialog
        title: "Last run"
        preferredWidth: Kirigami.Units.gridUnit * 34
        standardButtons: Kirigami.Dialog.Close
        property var data: ({})
        ColumnLayout {
            spacing: Kirigami.Units.smallSpacing
            QQC2.Label {
                visible: (peekDialog.data.error || "") !== ""
                color: Kirigami.Theme.negativeTextColor
                Layout.fillWidth: true; wrapMode: Text.Wrap
                text: "⚠ " + (peekDialog.data.error || "")
            }
            QQC2.Label {
                visible: peekDialog.data.has === false
                opacity: 0.6; text: "This stage has not run yet."
            }
            QQC2.Label {
                visible: (peekDialog.data.in_text || peekDialog.data.in_rows) ? true : false
                text: "Input"; font.bold: true
            }
            QQC2.TextArea {
                visible: (peekDialog.data.in_text || peekDialog.data.in_rows) ? true : false
                Layout.fillWidth: true
                Layout.preferredHeight: Kirigami.Units.gridUnit * 7
                readOnly: true; font.family: "monospace"
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                text: peekDialog.data.in_rows || peekDialog.data.in_text || ""
                wrapMode: TextEdit.NoWrap
            }
            QQC2.Label {
                visible: (peekDialog.data.out_rows || peekDialog.data.out_text) ? true : false
                text: "Output"; font.bold: true
            }
            QQC2.TextArea {
                visible: (peekDialog.data.out_rows || peekDialog.data.out_text) ? true : false
                Layout.fillWidth: true
                Layout.preferredHeight: Kirigami.Units.gridUnit * 9
                readOnly: true; font.family: "monospace"
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                text: peekDialog.data.out_rows || peekDialog.data.out_text || ""
                wrapMode: TextEdit.NoWrap
            }
        }
    }
    function openPeek(nodeId) {
        peekDialog.data = backend.nodePeek(page.pipeName, nodeId)
        peekDialog.open()
    }

    // ---- один чип стадии: иконка + название стадии + число строк ----
    component StageChip: QQC2.AbstractButton {
        id: chip
        property var stage
        implicitHeight: Kirigami.Units.gridUnit * 2
        implicitWidth: chipRow.implicitWidth + Kirigami.Units.largeSpacing * 2
        hoverEnabled: true
        background: Rectangle {
            radius: Kirigami.Units.smallSpacing
            color: chip.stage && chip.stage.error
                   ? Qt.alpha(Kirigami.Theme.negativeTextColor, 0.18)
                   : (chip.hovered ? Kirigami.Theme.hoverColor
                                   : Qt.alpha(Kirigami.Theme.textColor, 0.07))
            border.width: 1
            border.color: Qt.alpha(Kirigami.Theme.textColor, 0.12)
        }
        contentItem: RowLayout {
            id: chipRow
            spacing: Kirigami.Units.smallSpacing
            Kirigami.Icon {
                source: page.kindIcon[chip.stage.kind] || "code-context"
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
            }
            QQC2.Label {
                text: page.kindName[chip.stage.kind] || chip.stage.kind
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
            QQC2.Label {
                visible: chip.stage.kind !== "input"
                opacity: 0.6
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                text: chip.stage.rows
            }
        }
        QQC2.ToolTip.text: chip.stage.title + " — click for last run"
        QQC2.ToolTip.visible: hovered
        onClicked: page.openPeek(chip.stage.id)
    }

    ListView {
        model: page.flows
        spacing: Kirigami.Units.smallSpacing

        Kirigami.PlaceholderMessage {
            anchors.centerIn: parent
            visible: parent.count === 0
            text: "No data flows in this pipeline"
        }

        delegate: Kirigami.AbstractCard {
            width: ListView.view.width
            contentItem: ColumnLayout {
                spacing: Kirigami.Units.smallSpacing

                // --- шапка потока: иконка, заголовок, статус, вкл/выкл ---
                RowLayout {
                    spacing: Kirigami.Units.largeSpacing
                    Layout.fillWidth: true
                    Kirigami.Icon {
                        source: modelData.icon || "view-list-details"
                        Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                        Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                        opacity: modelData.enabled ? 1.0 : 0.4
                    }
                    ColumnLayout {
                        spacing: 0
                        Layout.fillWidth: true
                        Kirigami.Heading {
                            level: 4; text: modelData.title
                            opacity: modelData.enabled ? 1.0 : 0.5
                        }
                        QQC2.Label {
                            opacity: 0.7
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            text: (modelData.table ? "→ " + modelData.table : "") +
                                  "   ·   every " + modelData.interval + "s" +
                                  (modelData.ran_at ? "   ·   last " + modelData.ran_at : "")
                        }
                    }
                    // счётчик строк, записанных потоком
                    Kirigami.Chip {
                        visible: modelData.rows >= 0
                        checkable: false
                        text: modelData.rows + " rows"
                    }
                    QQC2.Switch {
                        checked: modelData.enabled
                        onToggled: backend.setInputEnabled(modelData.ref, checked)
                        QQC2.ToolTip.text: checked ? "Source enabled" : "Source disabled"
                        QQC2.ToolTip.visible: hovered
                    }
                }

                // --- стадии как цепочка чипов со стрелками ---
                Flow {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    Repeater {
                        id: stagesRep
                        model: modelData.stages
                        RowLayout {
                            spacing: Kirigami.Units.smallSpacing
                            StageChip { stage: modelData }
                            QQC2.Label {
                                visible: index < stagesRep.count - 1
                                text: "→"; opacity: 0.4
                            }
                        }
                    }
                }

                Kirigami.InlineMessage {
                    Layout.fillWidth: true
                    visible: modelData.error !== ""
                    type: Kirigami.MessageType.Error
                    text: modelData.error
                }
            }
        }
    }
}

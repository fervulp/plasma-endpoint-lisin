import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components"
import "."

// PIPELINES — the data flows, one card per ENTRY POINT.
//
// Reading 3 flows is easier as a list of chips than as a canvas of boxes, so a
// flow is drawn as  [entry point] -> [table] -> [view] ...  with the live row
// count under each stage. Nothing here is hardcoded: the flows are derived in
// the backend from the expertise files themselves, so a new input appears here
// by itself. A click on a stage opens that rule in Expertise.
Kirigami.Page {
    id: page
    title: "Pipelines"
    padding: 0
    background: PageBackground {}

    property var flows: []
    readonly property int failing: {
        var n = 0
        for (var i = 0; i < flows.length; i++)
            if (String(flows[i].error || "") !== "") n++
        return n
    }
    property string filter: ""
    function reload() { page.flows = backend.pipelineFlows() || [] }

    readonly property var shownFlows: {
        if (filter === "") return flows
        var f = filter.toLowerCase()
        return flows.filter(function (fl) {
            if (String(fl.title).toLowerCase().indexOf(f) >= 0) return true
            for (var i = 0; i < fl.stages.length; i++)
                if (String(fl.stages[i].title).toLowerCase().indexOf(f) >= 0) return true
            return false
        })
    }

    Connections {
        target: backend
        function onStateReady() { if (page.visible) reloadTimer.restart() }
    }
    // coalesce the 3 s pushes: one reload shortly after the last one
    Timer { id: reloadTimer; interval: 500; onTriggered: page.reload() }
    Component.onCompleted: reload()

    function stageIcon(kind) {
        return kind === "input" ? "document-import"
             : kind === "view"  ? "view-filter"
             : "table"
    }

    RowLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.largeSpacing

        FloatCard {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                Kirigami.SearchField {
                    Layout.fillWidth: true
                    Layout.margins: Kirigami.Units.smallSpacing
                    placeholderText: "search an entry point or a table…"
                    onTextChanged: page.filter = text
                }

                QQC2.ScrollView {
                    id: scroller
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.topMargin: 10          // same search-to-content gap as Data
                    clip: true

                    ListView {
                        model: page.shownFlows
                        spacing: Kirigami.Units.largeSpacing
                        reuseItems: true

                        delegate: Item {
                            required property var modelData
                            width: ListView.view.width
                            implicitHeight: flowCol.implicitHeight
                                            + Kirigami.Units.largeSpacing * 2

                            Rectangle {          // the flow card
                                anchors.fill: parent
                                anchors.margins: Kirigami.Units.smallSpacing
                                radius: Kirigami.Units.smallSpacing
                                color: Kirigami.Theme.alternateBackgroundColor
                                opacity: modelData.enabled ? 1 : 0.55
                                // a source that FAILED is marked on the card, not
                                // left looking like one nobody refreshed lately
                                border.width: String(modelData.error || "") !== "" ? 1 : 0
                                border.color: Kirigami.Theme.negativeTextColor
                            }

                            ColumnLayout {
                                id: flowCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.margins: Kirigami.Units.largeSpacing
                                spacing: Kirigami.Units.smallSpacing

                                // ---- header: what this entry point is ----
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.smallSpacing
                                    Kirigami.Icon {
                                        source: modelData.icon
                                        Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                                        Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                                    }
                                    QQC2.Label {
                                        text: modelData.title
                                        font.bold: true
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }
                                    QQC2.Label {
                                        text: modelData.source
                                        opacity: 0.6
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                    QQC2.Label {
                                        visible: !modelData.enabled
                                        text: "disabled"
                                        opacity: 0.7
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                    Kirigami.Icon {
                                        visible: String(modelData.error || "") !== ""
                                        source: "dialog-error"
                                        color: Kirigami.Theme.negativeTextColor
                                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                    }
                                }
                                // WHAT WENT WRONG, in words, on the card itself
                                QQC2.Label {
                                    visible: String(modelData.error || "") !== ""
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    color: Kirigami.Theme.negativeTextColor
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    text: "failed " + modelData.error_at + " — "
                                          + String(modelData.error || "")
                                }

                                // ---- the flow itself: stage -> stage -> stage ----
                                Flow {
                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.smallSpacing

                                    Repeater {
                                        model: modelData.stages
                                        delegate: Row {
                                            required property var modelData
                                            required property int index
                                            spacing: Kirigami.Units.smallSpacing

                                            QQC2.Label {          // the arrow
                                                visible: index > 0
                                                text: "→"
                                                opacity: 0.45
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                            QQC2.Control {        // the stage chip
                                                padding: Kirigami.Units.smallSpacing
                                                background: Rectangle {
                                                    radius: 4
                                                    color: Kirigami.Theme.backgroundColor
                                                    border.width: 1
                                                    border.color: Qt.alpha(Kirigami.Theme.textColor, 0.18)
                                                }
                                                contentItem: RowLayout {
                                                    spacing: Kirigami.Units.smallSpacing
                                                    Kirigami.Icon {
                                                        source: page.stageIcon(modelData.kind)
                                                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                                    }
                                                    ColumnLayout {
                                                        spacing: 0
                                                        QQC2.Label { text: modelData.title }
                                                        QQC2.Label {
                                                            text: modelData.detail
                                                                  + (modelData.rows >= 0
                                                                     ? " · " + modelData.rows + " rows" : "")
                                                            opacity: 0.6
                                                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                                                        }
                                                    }
                                                }
                                                MouseArea {
                                                    anchors.fill: parent
                                                    enabled: String(modelData.ref) !== ""
                                                    cursorShape: enabled ? Qt.PointingHandCursor
                                                                         : Qt.ArrowCursor
                                                    onClicked: root.openExpertise(modelData.ref)
                                                }
                                            }
                                        }
                                    }
                                }

                                // ---- footer: when it last produced data ----
                                QQC2.Label {
                                    Layout.fillWidth: true
                                    opacity: 0.6
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    text: (modelData.interval === "stream"
                                           ? "continuous stream"
                                           : "every " + modelData.interval)
                                          + (String(modelData.collected_at) !== ""
                                             ? "   ·   last data " + modelData.collected_at : "")
                                }
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.leftMargin: Kirigami.Units.smallSpacing
                    Layout.bottomMargin: Kirigami.Units.smallSpacing
                    QQC2.Label {
                        opacity: 0.6
                        text: "entry points: " + page.flows.length
                    }
                    QQC2.Label {   // silence is the enemy: say it out loud
                        visible: page.failing > 0
                        color: Kirigami.Theme.negativeTextColor
                        text: "· " + page.failing + " failing"
                    }
                }
            }
        }
    }
}

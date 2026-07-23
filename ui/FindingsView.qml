import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

// The "What is wrong" dashboard: not "how many of each" but concrete problems -
// why they matter and what to do about them. Clicking a finding leads into
// "State", to the right table with a filter, so that the analyst sees the data.
Item {
    id: view
    property var d: ({ findings: [], total: 0, high: 0, medium: 0, low: 0 })
    property string openTitle: ""
    property string sevFilter: ""

    function refresh() { view.d = backend.systemFindings() }
    Component.onCompleted: refresh()
    Connections {
        target: backend
        function onStateReady(s) { view.refresh() }
    }
    function sevColor(s) {
        return s === "high" ? "#e74c3c" : s === "medium" ? "#e67e22" : "#f1c40f"
    }
    property var shown: {
        var f = d.findings || []
        if (sevFilter === "") return f
        var o = []
        for (var i = 0; i < f.length; i++) if (f[i].severity === sevFilter) o.push(f[i])
        return o
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing
            Kirigami.Heading { level: 3; text: "Needs Attention" }
            Item { Layout.fillWidth: true }
            Repeater {
                model: [{ k: "high", t: "critical" }, { k: "medium", t: "important" },
                        { k: "low", t: "worth a look" }]
                QQC2.ToolButton {
                    checkable: true
                    checked: view.sevFilter === modelData.k
                    onClicked: view.sevFilter = (view.sevFilter === modelData.k ? "" : modelData.k)
                    contentItem: RowLayout {
                        spacing: Kirigami.Units.smallSpacing
                        Rectangle {
                            width: Kirigami.Units.gridUnit * 0.7; height: width; radius: 3
                            color: view.sevColor(modelData.k)
                        }
                        QQC2.Label {
                            text: modelData.t + "  " +
                                  (modelData.k === "high" ? view.d.high
                                   : modelData.k === "medium" ? view.d.medium : view.d.low)
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                    }
                }
            }
            QQC2.ToolButton { icon.name: "view-refresh"; onClicked: view.refresh() }
        }
        Kirigami.Separator { Layout.fillWidth: true }

        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: view.shown
            spacing: Kirigami.Units.smallSpacing
            QQC2.ScrollBar.vertical: QQC2.ScrollBar {}

            Kirigami.PlaceholderMessage {
                anchors.centerIn: parent
                width: parent.width - Kirigami.Units.gridUnit * 4
                visible: parent.count === 0
                icon.name: "checkmark"
                text: "Nothing suspicious found"
                explanation: "Checks exposed ports, privilege escalation, persistence, " +
                             "unpackaged processes, file integrity and kernel parameters."
            }

            delegate: Kirigami.AbstractCard {
                width: ListView.view.width
                readonly property bool isOpen: view.openTitle === modelData.title
                contentItem: ColumnLayout {
                    spacing: Kirigami.Units.smallSpacing

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        TapHandler { onTapped: view.openTitle = isOpen ? "" : modelData.title }
                        Rectangle {
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 0.5
                            Layout.preferredHeight: Kirigami.Units.gridUnit * 1.6
                            radius: 2
                            color: view.sevColor(modelData.severity)
                        }
                        Kirigami.Heading {
                            level: 4; text: modelData.title
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                        }
                        QQC2.Button {
                            visible: modelData.table !== ""
                            text: "Show"
                            icon.name: "search"
                            onClicked: root.focusState(modelData.table, modelData.col,
                                                       modelData.val)
                        }
                        Kirigami.Icon {
                            source: isOpen ? "go-up" : "go-down"
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                            opacity: 0.6
                        }
                    }
                    QQC2.Label {
                        Layout.fillWidth: true
                        text: modelData.why
                        wrapMode: Text.WordWrap
                        opacity: 0.8
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        visible: isOpen
                        Kirigami.Icon {
                            source: "dialog-ok-apply"
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        }
                        QQC2.Label {
                            Layout.fillWidth: true
                            text: modelData.action
                            wrapMode: Text.WordWrap
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: Kirigami.Units.gridUnit
                        visible: isOpen
                        spacing: 1
                        Repeater {
                            model: modelData.evidence
                            QQC2.Label {
                                Layout.fillWidth: true
                                text: "· " + modelData
                                elide: Text.ElideRight
                                font.family: "monospace"
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                opacity: 0.85
                            }
                        }
                    }
                }
            }
        }
    }
}

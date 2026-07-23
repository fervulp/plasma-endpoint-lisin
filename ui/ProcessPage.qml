import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

// EDR-style process drill-down: everything related to one PID —
// lineage, sockets, owning package + deps, open files.
Kirigami.ScrollablePage {
    id: page
    property string pid: ""
    property var d: backend.processDetails(pid)
    title: "Process context"

    actions: [
        Kirigami.Action {
            icon.name: "go-previous"; text: "Back"
            onTriggered: root.pageStack.layers.pop()
        }
    ]

    // Pinned at the top: the identity of the process + what started it (the unit).
    header: QQC2.ToolBar {
        contentItem: RowLayout {
            spacing: Kirigami.Units.largeSpacing
            Kirigami.Icon {
                source: "system-run"
                Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                Layout.preferredHeight: Kirigami.Units.iconSizes.medium
            }
            ColumnLayout {
                spacing: 0
                Layout.fillWidth: true
                Kirigami.Heading {
                    level: 3
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: "PID " + page.pid +
                          (page.d && page.d.command
                           ? " · " + page.d.command.split(" ")[0].split("/").pop() : "")
                }
                QQC2.Label {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    opacity: 0.7
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    text: (page.d && page.d.unit ? "started by " + page.d.unit : "") +
                          (page.d && page.d.user ? "   ·   " + page.d.user : "")
                }
            }
            Kirigami.Chip {
                visible: page.d && (page.d.env_flags || []).length > 0
                text: "LD_PRELOAD"
                checkable: false
            }
        }
    }

    footer: QQC2.ToolBar {
        RowLayout {
            anchors.fill: parent
            Item { Layout.fillWidth: true }
            QQC2.ToolButton {
                icon.name: "view-refresh"
                text: "Refresh"
                QQC2.ToolTip.text: "Refresh"
                QQC2.ToolTip.visible: hovered
                onClicked: page.d = backend.processDetails(page.pid)
            }
        }
    }

    component Section: Kirigami.AbstractCard {
        property string heading
        property string icon2
        default property alias inner: box.data
        Layout.fillWidth: true
        contentItem: ColumnLayout {
            spacing: Kirigami.Units.smallSpacing
            RowLayout {
                spacing: Kirigami.Units.smallSpacing
                Kirigami.Icon {
                    source: icon2
                    Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                }
                Kirigami.Heading { level: 3; text: heading }
            }
            Kirigami.Separator { Layout.fillWidth: true }
            ColumnLayout { id: box; spacing: 2; Layout.fillWidth: true }
        }
    }
    component KV: RowLayout {
        property string k
        property string v
        visible: v !== ""
        Layout.fillWidth: true
        QQC2.Label {
            text: k
            opacity: 0.6
            Layout.preferredWidth: Kirigami.Units.gridUnit * 6
        }
        QQC2.Label {
            text: v
            Layout.fillWidth: true
            wrapMode: Text.WrapAnywhere
        }
    }

    ColumnLayout {
        spacing: Kirigami.Units.largeSpacing

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: page.d && !page.d.alive
            type: Kirigami.MessageType.Warning
            text: "Process is no longer running — showing last known data."
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: page.d && (page.d.env_flags || []).length > 0
            type: Kirigami.MessageType.Warning
            text: "Preload/env override on live process:\n" +
                  (page.d.env_flags || []).join("\n")
        }

        // "How it started" - the chain from init down to the process, pinned at the top.
        Section {
            heading: "Launch timeline"
            icon2: "chronometer"
            Repeater {
                model: page.d.lineage || []
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    property bool last: index === (page.d.lineage || []).length - 1
                    QQC2.Label {
                        text: last ? "◆" : "│"
                        opacity: last ? 1.0 : 0.4
                        Layout.preferredWidth: Kirigami.Units.gridUnit
                    }
                    ColumnLayout {
                        spacing: 0
                        Layout.fillWidth: true
                        Layout.leftMargin: index * Kirigami.Units.smallSpacing
                        QQC2.Label {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            font.bold: parent.parent.last
                            font.family: "monospace"
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            text: modelData.pid + "  " + modelData.command
                        }
                        QQC2.Label {
                            opacity: 0.55
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            text: modelData.started + "   ·   " + modelData.user
                        }
                    }
                }
            }
            QQC2.Label {
                visible: (page.d.lineage || []).length === 0
                opacity: 0.5
                text: "Ancestry unavailable"
            }
        }

        Section {
            heading: "Process"
            icon2: "system-run"
            KV { k: "PID"; v: page.pid }
            KV { k: "User"; v: page.d.user || "" }
            KV { k: "Started"; v: page.d.started || "" }
            KV { k: "CPU / MEM"; v: page.d.cpu ? page.d.cpu + " % / " + page.d.mem + " %" : "" }
            KV { k: "Command"; v: page.d.command || "" }
            KV { k: "Executable"; v: page.d.exe || "" }
            KV { k: "Working dir"; v: page.d.cwd || "" }
            KV { k: "Started by"; v: page.d.unit || "" }
        }

        Section {
            heading: "Children (" + (page.d.children || []).length + ")"
            icon2: "view-list-tree"
            Repeater {
                model: page.d.children || []
                KV { k: index === 0 ? "Children" : ""; v: modelData.pid + " · " + modelData.command }
            }
            QQC2.Label {
                visible: (page.d.children || []).length === 0
                opacity: 0.5
                text: "No child processes"
            }
        }

        Section {
            heading: "Network (" + (page.d.sockets || []).length + ")"
            icon2: "network-connect"
            Repeater {
                model: page.d.sockets || []
                QQC2.Label {
                    Layout.fillWidth: true
                    font.family: "monospace"
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    text: modelData.proto + "  " + modelData.state +
                          "  " + modelData.local + " → " + modelData.peer
                    elide: Text.ElideMiddle
                }
            }
            QQC2.Label {
                visible: (page.d.sockets || []).length === 0
                opacity: 0.5
                text: "No open sockets"
            }
        }

        Section {
            heading: "Unix sockets (" + (page.d.unix || []).length + ")"
            icon2: "network-connect"
            Repeater {
                model: page.d.unix || []
                QQC2.Label {
                    Layout.fillWidth: true
                    font.family: "monospace"
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    text: modelData
                    elide: Text.ElideMiddle
                }
            }
            QQC2.Label {
                visible: (page.d.unix || []).length === 0
                opacity: 0.5
                text: "No unix-domain sockets"
            }
        }

        Section {
            heading: "Package"
            icon2: "package"
            KV { k: "Owner"; v: page.d.package || "(not from an rpm package)" }
            QQC2.Label {
                visible: (page.d.deps || []).length > 0
                opacity: 0.6
                text: "Dependencies:"
            }
            QQC2.Label {
                visible: (page.d.deps || []).length > 0
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                text: (page.d.deps || []).join(" · ")
            }
        }

        Section {
            heading: "Open files (" + (page.d.files || []).length + ")"
            icon2: "document-open"
            Repeater {
                model: page.d.files || []
                QQC2.Label {
                    Layout.fillWidth: true
                    font.family: "monospace"
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    text: modelData
                    elide: Text.ElideMiddle
                }
            }
            QQC2.Label {
                visible: (page.d.files || []).length === 0
                opacity: 0.5
                text: "No regular files open"
            }
        }
    }
}

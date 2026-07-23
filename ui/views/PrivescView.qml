import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components/Fmt.js" as Fmt
import "../components"
import "../pages"
import "."

// Privilege escalation: both the EVENTS (who did what through sudo, failed
// logins) and the STANDING VECTORS (capabilities, NOPASSWD, SUID, polkit).
// One is useless without the other: events say "what happened", vectors say
// "what else could be used".
Item {
    id: view
    property var d: ({ events: [], vectors: [], suid: [], admins: [],
                       polkit: [], auth_failures: [], sudo_commands: [], total: 0 })
    property string tab: "events"
    function refresh() { view.d = backend.privescActivity() }
    Component.onCompleted: refresh()
    Connections { target: backend; function onStateReady(s) { view.refresh() } }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing
            Kirigami.Heading { level: 3; text: "Privilege Escalation" }
            Item { Layout.fillWidth: true }
            Repeater {
                model: [{ k: "events", t: "Events" }, { k: "vectors", t: "Vectors" },
                        { k: "suid", t: "SUID" }, { k: "admins", t: "Admins" },
                        { k: "polkit", t: "Polkit" }]
                QQC2.ToolButton {
                    text: modelData.t + "  " + (
                        modelData.k === "events" ? view.d.events.length
                        : modelData.k === "vectors" ? view.d.vectors.length
                        : modelData.k === "suid" ? view.d.suid.length
                        : modelData.k === "admins" ? view.d.admins.length
                                                   : view.d.polkit.length)
                    checkable: true
                    checked: view.tab === modelData.k
                    onClicked: view.tab = modelData.k
                }
            }
            QQC2.ToolButton { icon.name: "view-refresh"; onClicked: view.refresh() }
        }
        Kirigami.Separator { Layout.fillWidth: true }

        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            QQC2.ScrollBar.vertical: QQC2.ScrollBar {}
            model: view.tab === "events" ? view.d.events
                 : view.tab === "vectors" ? view.d.vectors
                 : view.tab === "suid" ? view.d.suid
                 : view.tab === "admins" ? view.d.admins : view.d.polkit
            Kirigami.PlaceholderMessage {
                anchors.centerIn: parent
                visible: parent.count === 0
                text: "Nothing to show"
            }
            delegate: QQC2.ItemDelegate {
                width: ListView.view.width
                height: Kirigami.Units.gridUnit * 2.4
                contentItem: RowLayout {
                    spacing: Kirigami.Units.smallSpacing
                    // THE TIME IN THE FIRST COLUMN (principle 6): a vector or an
                    // event without a date cannot be tied to an incident. For a
                    // vector that is the mtime of its carrier, for an event its time.
                    QQC2.Label {
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                        Layout.alignment: Qt.AlignVCenter
                        font.family: "monospace"
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        opacity: 0.8
                        text: {
                            var t = view.tab === "events"
                                    ? String(modelData.ts || "")
                                    : String(modelData.changed || "")
                            if (t === "") return "—"
                            return Fmt.localShort(t)
                        }
                    }
                    QQC2.Label {
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                        Layout.alignment: Qt.AlignVCenter
                        opacity: 0.55
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        visible: view.tab === "vectors"
                        text: modelData.age_days ? (modelData.age_days + " d") : ""
                    }
                    Rectangle {
                        Layout.preferredWidth: 4; Layout.fillHeight: true
                        color: (modelData.risk === "high" || modelData.event_outcome === "failure"
                                || (parseInt(modelData.event_severity) || 0) >= 55)
                               ? "#e74c3c" : Kirigami.Theme.disabledTextColor
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        QQC2.Label {
                            Layout.fillWidth: true
                            elide: Text.ElideMiddle
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            text: view.tab === "events"
                                  ? ((modelData.subject_name || "?") + " → " +
                                     (modelData.event_action || "") +
                                     (modelData.object_name ? " → " + modelData.object_name : ""))
                                  : view.tab === "vectors"
                                  ? (modelData.kind + ": " + modelData.name)
                                  : view.tab === "suid" ? modelData.path
                                  : view.tab === "admins"
                                  ? (modelData.name + "  [" + (modelData.admin_groups || "") + "]")
                                  : modelData.action
                        }
                        QQC2.Label {
                            Layout.fillWidth: true
                            opacity: 0.65
                            elide: Text.ElideRight
                            font.family: "monospace"
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            text: view.tab === "events" ? (modelData.process_command_line
                                                           || modelData.message || "")
                                : view.tab === "vectors" ? (modelData.detail || "")
                                : view.tab === "suid" ? (modelData.owner + " " + modelData.perms)
                                : view.tab === "admins" ? (modelData.shell || "")
                                : (modelData.title || "")
                        }
                    }
                }
            }
        }
    }
}

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

// The "Dashboards" section - a separate top-level tab (not inside State).
// There may be several dashboards; the default one is "State".
Kirigami.Page {
    id: page
    title: "Dashboards"
    padding: 0

    property string current: "state"

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // the list of dashboards on the left - like the tabs in "State"
        Item {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 11
            Layout.fillHeight: true
            QQC2.ScrollView {
                anchors.fill: parent
                ListView {
                    clip: true
                    model: [{ id: "state", title: "State", icon: "computer" },
                            { id: "findings", title: "Findings", icon: "emblem-warning" },
                            { id: "vulns", title: "Vulnerabilities", icon: "security-low" },
                            { id: "files", title: "File activity", icon: "document-edit" },
                            { id: "privesc", title: "Privilege use", icon: "security-high" },
                            { id: "net", title: "Network flows", icon: "network-connect" }]
                    delegate: QQC2.ItemDelegate {
                        width: ListView.view.width
                        highlighted: page.current === modelData.id
                        onClicked: page.current = modelData.id
                        contentItem: RowLayout {
                            spacing: Kirigami.Units.smallSpacing
                            Kirigami.Icon {
                                source: modelData.icon
                                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                            }
                            QQC2.Label {
                                text: modelData.title
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }
                        }
                    }
                }
            }
        }
        Kirigami.Separator { Layout.fillHeight: true }

        Loader {
            Layout.fillWidth: true
            Layout.fillHeight: true
            active: page.current !== ""
            source: page.current === "state" ? Qt.resolvedUrl("DashboardView.qml")
                  : page.current === "findings" ? Qt.resolvedUrl("FindingsView.qml")
                  : page.current === "vulns" ? Qt.resolvedUrl("VulnView.qml")
                  : page.current === "files" ? Qt.resolvedUrl("FileActivityView.qml")
                  : page.current === "privesc" ? Qt.resolvedUrl("PrivescView.qml")
                  : page.current === "net" ? Qt.resolvedUrl("NetFlowView.qml") : ""
        }
    }
}

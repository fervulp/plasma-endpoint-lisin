import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components"
import "../views"
import "."

// The "Dashboards" section - a separate top-level tab (not inside State).
// There may be several dashboards; the default one is "State".
Kirigami.Page {
    id: page
    title: "Dashboards"
    padding: 0

    // grey canvas so the panels read as floating cards above it
    background: Rectangle {
        Kirigami.Theme.colorSet: Kirigami.Theme.Window
        Kirigami.Theme.inherit: false
        color: Kirigami.Theme.backgroundColor
    }

    property string current: "state"

    RowLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.largeSpacing

        // the list of dashboards on the left - like the tabs in "State"
        Item {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 11
            Layout.fillHeight: true
            FloatCard { anchors.fill: parent }
            QQC2.ScrollView {
                anchors.fill: parent
                anchors.margins: Kirigami.Units.smallSpacing
                ListView {
                    clip: true
                    model: [{ id: "state", title: "State", icon: "computer" }]
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
        // A PATH, NOT A TYPE NAME: Qt.resolvedUrl resolves against the file it is
        // written in, so after the views moved to ui/views/ these urls pointed at
        // ui/pages/ and the Loader silently loaded nothing - the dashboards were
        // blank with no error anywhere. Compiling QML does not catch it: the file
        // is named in a string, not imported as a type.
        FloatCard {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Loader {
                anchors.fill: parent
                // the view provides its own smallSpacing inset; no extra margin
                // here, so its search bar sits at the same height as Data's
                active: page.current !== ""
                source: page.current === "state" ? Qt.resolvedUrl("../views/DashboardView.qml") : ""
            }
        }
    }
}

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components"
import "../views"
import "."

// Settings hub with technical sub-sections (General / SQL / Errors),
// following KDE HIG: sidebar-style section list on the left.
Kirigami.Page {
    id: page
    title: "Settings"
    padding: 0

    background: Rectangle {
        Kirigami.Theme.colorSet: Kirigami.Theme.View
        Kirigami.Theme.inherit: false
        color: Kirigami.Theme.backgroundColor
    }

    property int section: 0

    RowLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.largeSpacing

        // section list (KDE settings-style)
        FloatCard {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 11
            Layout.fillHeight: true
            QQC2.ScrollView {
                anchors.fill: parent
                anchors.margins: Kirigami.Units.smallSpacing
                ListView {
                model: [
                    { t: "General", i: "configure" },
                    { t: "SQL", i: "server-database" },
                    { t: "Errors", i: "dialog-error" }
                ]
                clip: true
                delegate: QQC2.ItemDelegate {
                    width: ListView.view.width
                    icon.name: modelData.i
                    text: modelData.t
                    highlighted: page.section === index
                    onClicked: page.section = index
                }
            }
            }
        }

        FloatCard {
            Layout.fillWidth: true
            Layout.fillHeight: true
            StackLayout {
                anchors.fill: parent
                anchors.margins: Kirigami.Units.smallSpacing
                currentIndex: page.section

                GeneralSettings {}
                SqlPage { embedded: true }
                ErrorsView {}
            }
        }
    }
}

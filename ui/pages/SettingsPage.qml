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

    property int section: 0

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // section list (KDE settings-style)
        QQC2.ScrollView {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 11
            Layout.fillHeight: true
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

        Kirigami.Separator { Layout.fillHeight: true }

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: page.section

            GeneralSettings {}
            SqlPage { embedded: true }
            ErrorsView {}
        }
    }
}

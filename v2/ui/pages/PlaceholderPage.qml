import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components"
import "."

// A SECTION THAT EXISTS BUT IS NOT BUILT YET.
//
// An empty room, deliberately: the place is decided, so what belongs in it is a
// question with an address — and nothing has to land in Data by default just
// because there was nowhere else to put it. It says what it is for, because a
// blank page reads as a broken one, and it says plainly that nothing is defined
// yet rather than implying something failed to load.
Kirigami.Page {
    id: page
    padding: 0
    background: PageBackground {}

    property string section: ""
    property string icon: "documentinfo"
    property string explanation: ""

    title: section

    Kirigami.PlaceholderMessage {
        anchors.centerIn: parent
        width: Math.min(parent.width - Kirigami.Units.gridUnit * 4,
                        Kirigami.Units.gridUnit * 28)
        icon.name: page.icon
        text: page.section
        explanation: page.explanation
    }
}

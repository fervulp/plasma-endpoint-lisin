import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

// PICKING A FIELD WITH SEARCH.
//
// An ordinary drop-down is fine for a dozen items; events have 98 fields, and
// scrolling them with the mouse is torture. So: a button -> a popup list with a
// search line, filtering by substring, Enter takes the first match.
//
// Two modes:
//   * single (checkMode: false) - you pick a field and the list closes;
//   * multiple (checkMode: true) - checkmarks, the list stays open
//     (that is how a SELECT list is assembled).
Item {
    id: fp

    property var fields: []            // the list of names (strings)
    property string current: ""        // the selected one (single mode)
    property bool checkMode: false
    property var checked: []           // the checked ones (multiple mode)
    property string label: "field"     // the label when nothing is selected
    property string iconName: "view-list-details"
    property bool flatButton: false
    // PUT THE CURRENT NAME INTO THE SEARCH: that way a field does not have to be
    // picked again but can be CORRECTED - the line is already filled and selected.
    property bool prefillCurrent: false
    // the fields worth offering first (for us - the ones in SELECT): they are
    // marked in the list, but any field can be picked
    property var preferred: []

    signal picked(string name)

    implicitWidth: btn.implicitWidth
    implicitHeight: btn.implicitHeight

    readonly property var filtered: {
        var q = searchField.text.toLowerCase()
        if (!q) return fields
        var out = []
        for (var i = 0; i < fields.length; i++)
            if (String(fields[i]).toLowerCase().indexOf(q) >= 0) out.push(fields[i])
        return out
    }

    function open() { pop.open() }

    QQC2.Button {
        id: btn
        anchors.fill: parent
        text: fp.checkMode ? fp.label : (fp.current || fp.label)
        icon.name: fp.iconName
        flat: fp.flatButton
        display: (fp.checkMode && fp.label === "")
                 ? QQC2.AbstractButton.IconOnly
                 : QQC2.AbstractButton.TextBesideIcon
        onClicked: pop.open()
    }

    QQC2.Popup {
        id: pop
        y: btn.height
        width: Math.max(fp.width, Kirigami.Units.gridUnit * 16)
        height: Kirigami.Units.gridUnit * 18
        padding: Kirigami.Units.smallSpacing
        onOpened: {
            searchField.text = fp.prefillCurrent ? fp.current : ""
            searchField.forceActiveFocus()
            searchField.selectAll()
        }

        ColumnLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            QQC2.TextField {
                id: searchField
                Layout.fillWidth: true
                placeholderText: "search a field…"
                onAccepted: {
                    if (fp.filtered.length) {
                        fp.picked(String(fp.filtered[0]))
                        if (!fp.checkMode) pop.close(); else text = ""
                    }
                }
            }
            QQC2.Label {
                Layout.fillWidth: true
                opacity: 0.6
                text: fp.filtered.length + " of " + fp.fields.length
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                ListView {
                    model: fp.filtered
                    reuseItems: true
                    delegate: QQC2.ItemDelegate {
                        required property var modelData
                        width: ListView.view.width
                        height: Kirigami.Units.gridUnit * 2
                        onClicked: {
                            fp.picked(String(modelData))
                            if (!fp.checkMode) pop.close()
                        }
                        contentItem: RowLayout {
                            spacing: Kirigami.Units.smallSpacing
                            // A checkmark ONLY on the selected ones: empty boxes
                            // next to a hundred fields are noise, not information.
                            Kirigami.Icon {
                                visible: fp.checkMode && fp.checked.indexOf(modelData) >= 0
                                source: "checkmark"
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                            }
                            Item {
                                visible: fp.checkMode && fp.checked.indexOf(modelData) < 0
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: 1
                            }
                            QQC2.Label {
                                Layout.fillWidth: true
                                text: modelData
                                elide: Text.ElideRight
                                font.family: "monospace"
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                            QQC2.Label {
                                visible: fp.preferred.indexOf(modelData) >= 0
                                text: "in SELECT"
                                opacity: 0.55
                                font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                            }
                        }
                    }
                }
            }
        }
    }
}

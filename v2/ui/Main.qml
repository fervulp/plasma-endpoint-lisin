import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "pages"
import "components"

// LiSin — App manager. The same shape as the endpoint agent (a drawer on the
// left, one section at a time, a side panel for detail) because it is the same
// hand and the same habits — but a different question: not "what is on this
// machine" but "what is each application allowed to do".
Kirigami.ApplicationWindow {
    id: root
    title: "LiSin — App manager"
    width: 1400
    height: 880

    property string section: "applications"
    property var apps: []

    Component.onCompleted: {
        root.apps = backend.applications()
        open("applications")
    }

    Connections {
        target: backend
        function onAppsReady(list) { root.apps = list }
    }

    // A SECTION IS BUILT ONCE AND KEPT. Rebuilding a page on every visit throws
    // away the selection and the scroll with it; keeping one instance per
    // section costs a page and makes going back instant.
    property var pageCache: ({})
    property var pageComps: ({
        applications: applicationsComp, profiles: placeholderProfiles,
        policies: placeholderPolicies })
    function pageFor(name) {
        if (pageCache[name] === undefined) {
            var comp = pageComps[name] || placeholderProfiles
            pageCache[name] = comp.createObject(root)
        }
        return pageCache[name]
    }
    function open(name) {
        if (root.section === name && root.pageStack.depth > 0)
            return
        root.section = name
        while (root.pageStack.layers.depth > 1)
            root.pageStack.layers.pop()
        var it = pageFor(name)
        root.pageStack.clear()
        root.pageStack.push(it)
    }

    globalDrawer: Kirigami.GlobalDrawer {
        id: drawer
        modal: false
        collapsible: true
        collapsed: true
        showHeaderWhenCollapsed: true
        Kirigami.Theme.colorSet: Kirigami.Theme.Window
        Kirigami.Theme.inherit: false

        header: RowLayout {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            Kirigami.Icon {
                source: "application-x-executable"
                Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                Layout.preferredHeight: Kirigami.Units.iconSizes.medium
            }
            ColumnLayout {
                spacing: 0
                visible: !drawer.collapsed
                Kirigami.Heading { text: "LiSin"; level: 3 }
                QQC2.Label {
                    text: "App manager"
                    opacity: 0.6
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
            }
        }

        actions: [
            Kirigami.Action {
                text: "Applications"
                icon.name: "application-x-executable"
                checked: root.section === "applications"
                onTriggered: root.open("applications")
            },
            Kirigami.Action {
                text: "Profiles"
                icon.name: "preferences-desktop-user"
                checked: root.section === "profiles"
                onTriggered: root.open("profiles")
            },
            Kirigami.Action {
                text: "Policies"
                icon.name: "security-medium"
                checked: root.section === "policies"
                onTriggered: root.open("policies")
            }
        ]
    }

    Component { id: applicationsComp; ApplicationsPage {} }
    Component { id: placeholderProfiles; PlaceholderPage {
        section: "Profiles"
        icon: "preferences-desktop-user"
        explanation: "A named set of grants — \"can use ssh\", \"can print\", "
                   + "\"can reach the network\" — applied to an application in one "
                   + "click, on top of a baseline that denies everything else. "
                   + "Not built yet."
    } }
    Component { id: placeholderPolicies; PlaceholderPage {
        section: "Policies"
        icon: "security-medium"
        explanation: "Rules that decide what an application may be granted at "
                   + "all, and what should be reported when its permissions "
                   + "change. Not built yet."
    } }
}

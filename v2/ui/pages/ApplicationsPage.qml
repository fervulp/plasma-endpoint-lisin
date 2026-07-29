import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components"
import "."

// APPLICATIONS — one row per installed flatpak application, and everything it
// is allowed to do beside it.
//
// The page is built around ONE distinction, because it is the distinction the
// system itself makes and nothing else shows: what the application ASKED FOR
// when it was built, and what it will ACTUALLY GET on the next launch after this
// machine's overrides. A list of permissions that does not separate the two
// cannot answer "did my denial take effect".
Kirigami.Page {
    id: page
    title: "Applications"
    padding: 0
    background: PageBackground {}

    property var apps: root.apps || []
    property string selectedId: apps.length ? apps[0].id : ""
    property var detail: null
    property string filter: ""

    function reload() {
        if (selectedId !== "")
            page.detail = backend.application(selectedId)
    }
    onSelectedIdChanged: reload()
    onAppsChanged: if (selectedId === "" && apps.length) selectedId = apps[0].id
    Component.onCompleted: reload()

    readonly property var shown: {
        if (filter === "") return apps
        var f = filter.toLowerCase()
        return apps.filter(a => String(a.name).toLowerCase().indexOf(f) >= 0
                             || String(a.id).toLowerCase().indexOf(f) >= 0)
    }

    RowLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.largeSpacing

        // ---------------------------------------------------- the applications
        FloatCard {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 20
            Layout.fillHeight: true

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                Kirigami.SearchField {
                    Layout.fillWidth: true
                    placeholderText: "search an application…"
                    onTextChanged: page.filter = text
                }
                QQC2.Label {
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.smallSpacing
                    visible: page.apps.length === 0
                    wrapMode: Text.WordWrap
                    opacity: 0.7
                    text: backend.flatpakAvailable()
                          ? "No flatpak applications are installed."
                          : "flatpak is not installed on this machine."
                }
                QQC2.ScrollView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    ListView {
                        model: page.shown
                        reuseItems: true
                        delegate: QQC2.ItemDelegate {
                            required property var modelData
                            width: ListView.view.width
                            highlighted: page.selectedId === modelData.id
                            onClicked: page.selectedId = modelData.id
                            contentItem: RowLayout {
                                spacing: Kirigami.Units.smallSpacing
                                Kirigami.Icon {
                                    source: "application-x-executable"
                                    Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                                    Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0
                                    QQC2.Label {
                                        text: modelData.name
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }
                                    QQC2.Label {
                                        text: modelData.size + " · "
                                              + modelData.permissions + " granted"
                                              + (modelData.denials
                                                 ? " · " + modelData.denials + " denied" : "")
                                        opacity: 0.55
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                }
                                // the two facts worth seeing without opening it
                                Kirigami.Icon {
                                    source: "network-connect"
                                    visible: modelData.network
                                    opacity: 0.6
                                    implicitWidth: Kirigami.Units.iconSizes.small
                                    implicitHeight: Kirigami.Units.iconSizes.small
                                }
                                Kirigami.Icon {
                                    source: "dialog-warning"
                                    visible: modelData.escapes
                                    implicitWidth: Kirigami.Units.iconSizes.small
                                    implicitHeight: Kirigami.Units.iconSizes.small
                                }
                            }
                        }
                    }
                }
            }
        }

        // ------------------------------------------------------- the detail
        FloatCard {
            Layout.fillWidth: true
            Layout.fillHeight: true

            QQC2.ScrollView {
                id: scroller
                anchors.fill: parent
                anchors.margins: Kirigami.Units.smallSpacing
                clip: true

                ColumnLayout {
                    width: scroller.availableWidth
                    spacing: Kirigami.Units.smallSpacing

                    RowLayout {
                        Layout.fillWidth: true
                        Kirigami.Heading {
                            text: page.detail ? page.detail.id : ""
                            level: 3
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }
                    QQC2.Label {
                        Layout.fillWidth: true
                        visible: text !== ""
                        wrapMode: Text.WordWrap
                        text: page.detail ? String(page.detail.summary || "") : ""
                    }
                    QQC2.Label {
                        Layout.fillWidth: true
                        opacity: 0.65
                        wrapMode: Text.WordWrap
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        text: {
                            if (!page.detail) return ""
                            var d = page.detail
                            var bits = []
                            if (d.version) bits.push("version " + d.version)
                            if (d.size) bits.push(d.size + " installed")
                            if (d.origin) bits.push("from " + d.origin)
                            if (d.license) bits.push(d.license)
                            if (d.installation) bits.push(d.installation + " installation")
                            return bits.join("  ·  ")
                        }
                    }

                    // SANDBOX ESCAPE, ON ITS OWN. An application that may talk to
                    // flatpak runs anything on the host; showing that as one line
                    // among forty would be lying by arrangement.
                    Kirigami.InlineMessage {
                        Layout.fillWidth: true
                        visible: !!(page.detail && page.detail.escapes)
                        type: Kirigami.MessageType.Error
                        text: "This application can talk to flatpak itself, which "
                            + "means it can run anything on the host, outside the "
                            + "sandbox. Every other permission below is a formality "
                            + "until that is taken away."
                    }

                    // WHAT IT WEIGHS, honestly: its own size, and the runtime it
                    // shares with everything else built on the same platform.
                    Kirigami.Separator { Layout.fillWidth: true; Layout.topMargin: 4 }
                    QQC2.Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        font.bold: true
                        text: "Weight and dependencies"
                    }
                    QQC2.Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        opacity: 0.75
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        text: {
                            if (!page.detail) return ""
                            var w = page.detail.weight || {}
                            var s = "Itself: " + (w.own || "unknown") + "."
                            var sh = w.shared || []
                            if (sh.length) {
                                var names = []
                                for (var i = 0; i < sh.length; i++)
                                    names.push(sh[i].id + " (" + sh[i].size + ")")
                                s += " Runs on " + names.join(", ")
                                   + " — shared with every other application built "
                                   + "on the same platform, so removing this one "
                                   + "frees it only if nothing else needs it."
                            }
                            return s
                        }
                    }
                    QQC2.Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        opacity: 0.75
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        visible: text !== ""
                        text: page.detail && page.detail.depends
                              ? "Depends on: " + page.detail.depends.join(", ") : ""
                    }

                    // ---- permissions, by category
                    Kirigami.Separator { Layout.fillWidth: true; Layout.topMargin: 4 }
                    QQC2.Label {
                        Layout.fillWidth: true
                        font.bold: true
                        text: "Permissions"
                    }
                    QQC2.Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        opacity: 0.65
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        text: "What the application asked for when it was built, and "
                            + "what it will actually get on its next launch after "
                            + "this machine's overrides. An override never applies "
                            + "to a running instance."
                    }
                    // THE FAMILIES AS BLOCKS, two across when there is room.
                    // Seven families of permissions read badly as a list — the eye
                    // has nowhere to rest and every entry looks like every other.
                    // As blocks each family is one object you take in at a glance,
                    // and the chips inside carry their own state, so half a page is
                    // still readable.
                    GridLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: Kirigami.Units.smallSpacing
                        columns: scroller.availableWidth > Kirigami.Units.gridUnit * 46
                                 ? 2 : 1
                        columnSpacing: Kirigami.Units.smallSpacing
                        rowSpacing: Kirigami.Units.smallSpacing

                        Repeater {
                            model: page.detail ? page.detail.categories : []
                            delegate: PermissionBlock {
                                required property var modelData
                                Layout.fillWidth: true
                                Layout.preferredWidth: 1     // equal columns
                                title: modelData.title
                                icon: modelData.icon
                                why: modelData.why
                                granted: modelData.granted || []
                                denied: modelData.denied || []
                                alarming: !!modelData.alarming
                            }
                        }
                    }

                    // ---- what the portals granted, which no override mentions
                    Kirigami.Separator { Layout.fillWidth: true; Layout.topMargin: 4 }
                    QQC2.Label {
                        Layout.fillWidth: true
                        font.bold: true
                        text: "Granted at runtime by the portals"
                    }
                    QQC2.Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        opacity: 0.7
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        text: {
                            if (!page.detail) return ""
                            var p = page.detail.portals || []
                            if (!p.length)
                                return "Nothing. When you pick a file in a dialog "
                                     + "the application is given that file without "
                                     + "any override saying so — those grants would "
                                     + "appear here."
                            var out = []
                            for (var i = 0; i < p.length; i++)
                                out.push(p[i].table + " / " + p[i].object + ": "
                                         + p[i].permissions)
                            return out.join("\n")
                        }
                    }
                    Item { Layout.fillHeight: true }
                }
            }
        }
    }
}

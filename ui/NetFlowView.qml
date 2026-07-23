import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "Fmt.js" as Fmt

// Who the machine talks to: directions by the number of SESSIONS (the volume in
// bytes is unavailable without root - we say so honestly in the caption), the
// network owner from the ASN, the DNS name. A click on an address - WHOIS.
Item {
    id: view
    property var d: ({ flows: [], dns: [], by_asn: [], live: [], resolvers: [],
                       series: [], by_process: [], rare: 0,
                       total: 0, external: 0, unit: "" })
    property bool extOnly: false
    property bool rareOnly: false
    property var whois: null
    property var detail: null
    function refresh() { view.d = backend.networkFlows() }
    Component.onCompleted: refresh()
    Connections { target: backend; function onStateReady(s) { view.refresh() } }

    property int maxSessions: {
        var m = 1, f = d.flows || []
        for (var i = 0; i < f.length; i++) m = Math.max(m, f[i].sessions)
        return m
    }
    property var shown: {
        var f = d.flows || [], o = []
        for (var i = 0; i < f.length; i++) {
            if (extOnly && f[i].direction !== "external") continue
            if (rareOnly && !f[i].rare) continue
            o.push(f[i])
        }
        return o
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing
            Kirigami.Heading { level: 3; text: "Network Activity" }
            QQC2.Label {
                opacity: 0.7
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                text: view.d.total + " addresses · " + view.d.external + " external · " + view.d.unit
            }
            Item { Layout.fillWidth: true }
            QQC2.ToolButton {
                text: "External Only"; checkable: true; checked: view.extOnly
                onToggled: view.extOnly = checked
            }
            // RARE SESSIONS. Bulk traffic is visible anyway; the inconspicuous -
            // a few connections, an unknown owner, a narrow window - is exactly
            // what gets lost in a common list.
            QQC2.ToolButton {
                text: "Unusual (" + view.d.rare + ")"
                checkable: true; checked: view.rareOnly
                enabled: view.d.rare > 0
                onToggled: view.rareOnly = checked
            }
            QQC2.ToolButton { icon.name: "view-refresh"; onClicked: view.refresh() }
        }

        // THE SESSION CHART BY HOUR. An even rhythm means automation (polling,
        // synchronisation), a spike means one-off activity. The layout is computed
        // in Python, the interface only draws it - the points do not jump.
        Rectangle {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            Layout.preferredHeight: Kirigami.Units.gridUnit * 5
            visible: (view.d.series || []).length > 1
            color: Kirigami.Theme.alternateBackgroundColor
            radius: 3

            Canvas {
                id: chart
                anchors.fill: parent
                anchors.margins: Kirigami.Units.smallSpacing
                property var pts: view.d.series || []
                onPtsChanged: requestPaint()
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    var n = pts.length
                    if (n < 2) return
                    var mx = 1
                    for (var i = 0; i < n; i++)
                        mx = Math.max(mx, pts[i].n)
                    var w = width / n
                    for (var j = 0; j < n; j++) {
                        var h = (pts[j].n / mx) * (height - 12)
                        var he = (pts[j].ext / mx) * (height - 12)
                        ctx.fillStyle = Qt.rgba(0.4, 0.5, 0.6, 0.45)
                        ctx.fillRect(j * w + 1, height - h, w - 2, h)
                        // external on top, in a different colour: the outbound share is visible
                        ctx.fillStyle = "#e67e22"
                        ctx.fillRect(j * w + 1, height - he, w - 2, he)
                    }
                }
            }
            QQC2.Label {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.margins: Kirigami.Units.smallSpacing
                opacity: 0.6
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                text: "sessions per hour · orange means outbound"
            }
        }
        Kirigami.Separator { Layout.fillWidth: true }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // ---- directions ----
            ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: view.shown
                QQC2.ScrollBar.vertical: QQC2.ScrollBar {}
                Kirigami.PlaceholderMessage {
                    anchors.centerIn: parent
                    visible: parent.count === 0
                    text: "No network events yet"
                }
                delegate: QQC2.ItemDelegate {
                    width: ListView.view.width
                    height: Kirigami.Units.gridUnit * 3
                    onClicked: {
                        // Kirigami.Dialog is a Popup: it is opened by calling
                        // open(). The binding `visible: detail !== null` did not
                        // fire, so a click on a session did not open the
                        // breakdown - hence "I click and cannot look at it".
                        // the graph answers "who sent this" directly, which
                        // the old text dialog could not
                        view.openAddress(modelData.ip)
                    }
                    contentItem: ColumnLayout {
                        spacing: 1
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing
                            Rectangle {
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 0.6
                                Layout.preferredHeight: Kirigami.Units.gridUnit * 0.6
                                radius: 3
                                color: modelData.threat ? "#c0392b"
                                     : modelData.direction === "external" ? "#2980b9" : "#7f8c8d"
                            }
                            QQC2.Label {
                                text: modelData.ip
                                font.family: "monospace"
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 9
                            }
                            QQC2.Label {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                opacity: 0.8
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                text: (modelData.domain || modelData.as_org || "")
                                      + (modelData.country ? "  (" + modelData.country + ")" : "")
                                      + (modelData.threat ? "   ⚠ " + modelData.threat : "")
                            }
                            QQC2.Label {
                                text: modelData.sessions + " sessions"
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                opacity: 0.75
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing
                            Rectangle {          // the frequency bar
                                // IMPORTANT: the width is computed from a fixed base
                                // and not from parent.width - otherwise the Layout
                                // recomputes itself in a circle ("recursive rearrange").
                                Layout.preferredWidth: Math.max(2,
                                    Kirigami.Units.gridUnit * 18
                                    * modelData.sessions / view.maxSessions)
                                Layout.preferredHeight: Kirigami.Units.gridUnit * 0.5
                                radius: 2
                                color: modelData.direction === "external"
                                       ? Kirigami.Theme.highlightColor : "#95a5a6"
                                opacity: 0.7
                            }
                            Item { Layout.fillWidth: true }
                            QQC2.Label {
                                opacity: 0.6
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                text: (modelData.process_name
                                       ? "opened by: " + modelData.process_name
                                         + (modelData.process_source
                                            ? " (" + modelData.process_source + ")" : "")
                                         + "  ·  "
                                       : "owner unknown  ·  ")
                                      + "ports " + modelData.ports
                                      + "  ·  " + (modelData.last_seen || "").replace("T", " ").replace("Z", "")
                            }
                        }
                    }
                }
            }
        }
    }

    // ---- WHOIS on a click on an address ----
    // ---- WHO TALKED TO THIS ADDRESS ----
    // The same investigation graph as on the process dashboard, only anchored
    // on the remote address: live sockets plus network events, so a connection
    // that has already closed is still attributed to its process.
    property var addrGraph: null
    property string addrVal: ""
    property var addrExpanded: []
    property var addrNode: null
    property var addrInfo: null
    function openAddress(ip) {
        view.addrVal = ip
        view.addrExpanded = ["tree", "network"]
        view.addrGraph = backend.anchorGraph("address", ip, view.addrExpanded)
        view.addrNode = null; view.addrInfo = null
        addrDlg.open()
    }
    Kirigami.Dialog {
        id: addrDlg
        title: "Traffic with " + view.addrVal
        preferredWidth: Kirigami.Units.gridUnit * 60
        preferredHeight: Kirigami.Units.gridUnit * 38
        standardButtons: Kirigami.Dialog.Close
        RowLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing
            GraphCanvas {
                id: addrCanvas
                Layout.fillWidth: true
                Layout.fillHeight: true
                graph: view.addrGraph ? view.addrGraph : ({ nodes: [], edges: [] })
                onNodeActivated: function (n) {
                    view.addrNode = n
                    view.addrInfo = backend.nodeInfo(n)
                }
                onToggleCategory: function (cat) {
                    var e = view.addrExpanded.slice()
                    var i = e.indexOf(cat)
                    if (i >= 0) e.splice(i, 1); else e.push(cat)
                    view.addrExpanded = e
                    view.addrGraph = backend.anchorGraph("address", view.addrVal, e)
                }
                onAnchorRequested: function (n) {
                    // pivot onto a process keeps the analyst inside the graph
                    if (n.table === "processes") {
                        view.addrGraph = backend.processLinks(n.val, [])
                        view.addrVal = n.label
                    }
                }
                onDrillRequested: function (action, n) {
                    if (action === "state" && n.table && n.table !== "events")
                        root.focusState(n.table, n.col, n.val)
                    else if (action === "events")
                        root.focusEvents("destination_ip='" + view.addrVal + "'")
                    else if (action === "whois")
                        view.whois = backend.whoisLookup(n.val.split(":")[0])
                }
            }
            QQC2.ScrollView {
                id: addrSide
                Layout.preferredWidth: Kirigami.Units.gridUnit * 18
                Layout.fillHeight: true
                visible: view.addrNode !== null
                clip: true
                contentWidth: availableWidth
                ColumnLayout {
                    width: addrSide.availableWidth
                    spacing: 2
                    QQC2.Label {
                        Layout.fillWidth: true
                        font.bold: true
                        elide: Text.ElideRight
                        text: view.addrNode ? view.addrNode.label : ""
                    }
                    Repeater {
                        model: view.addrInfo ? (view.addrInfo.sections || []) : []
                        delegate: ColumnLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: 1
                            Kirigami.Separator { Layout.fillWidth: true }
                            QQC2.Label {
                                text: modelData.title
                                font.bold: true
                                opacity: 0.75
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                            Repeater {
                                model: modelData.rows || []
                                delegate: QQC2.Label {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                    text: modelData.k + ": " + modelData.v
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Kirigami.Dialog {
        id: whoisDlg
        title: "WHOIS " + (view.whois ? view.whois.ip : "")
        visible: view.whois !== null
        preferredWidth: Kirigami.Units.gridUnit * 32
        preferredHeight: Kirigami.Units.gridUnit * 22
        standardButtons: Kirigami.Dialog.Close
        onVisibleChanged: if (!visible) view.whois = null
        QQC2.ScrollView {
            anchors.fill: parent
            clip: true
            ColumnLayout {
                width: Kirigami.Units.gridUnit * 29
                spacing: 2
                QQC2.Label {
                    Layout.fillWidth: true
                    visible: view.whois && view.whois.note
                    wrapMode: Text.WordWrap
                    text: view.whois ? (view.whois.note || "") : ""
                }
                Repeater {
                    model: ["organization", "netname", "descr", "country", "range",
                            "as_number", "as_org", "prefix", "rdns", "abuse", "updated"]
                    RowLayout {
                        Layout.fillWidth: true
                        visible: view.whois && view.whois[modelData]
                        QQC2.Label {
                            text: modelData
                            opacity: 0.6
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 7
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                        QQC2.Label {
                            Layout.fillWidth: true
                            text: view.whois ? String(view.whois[modelData] || "") : ""
                            wrapMode: Text.WrapAnywhere
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                    }
                }
            }
        }
    }

    // THE BREAKDOWN OF A DIRECTION on a click. A dashboard must answer not "how
    // many" but "what to do": who talked, when, through which process and where
    // to go next - jumps, not the advice "go and look yourself".
    Kirigami.Dialog {
        id: detailDlg
        title: view.detail ? ("Traffic with " + view.detail.ip) : ""
        preferredWidth: Kirigami.Units.gridUnit * 40
        preferredHeight: Kirigami.Units.gridUnit * 30
        standardButtons: Kirigami.Dialog.Close
        onRejected: view.detail = null
        onClosed: view.detail = null

        QQC2.ScrollView {
            id: dScroll
            anchors.fill: parent
            clip: true
            ColumnLayout {
                width: dScroll.availableWidth
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Heading { level: 4; text: "Who Communicated" }
                Repeater {
                    model: view.detail ? (view.detail.processes || []) : []
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        QQC2.Label {
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 10
                            text: modelData.name
                            font.bold: true
                            elide: Text.ElideRight
                        }
                        QQC2.Label {
                            Layout.fillWidth: true
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            opacity: 0.8
                            wrapMode: Text.WordWrap
                            text: modelData.sessions + " sessions · "
                                  + String(modelData.first_seen).replace("T", " ").substring(0, 16)
                                  + " … "
                                  + String(modelData.last_seen).replace("T", " ").substring(0, 16)
                                  + (modelData.how ? "  (" + modelData.how + ")" : "")
                        }
                    }
                }

                Kirigami.Heading {
                    level: 4
                    text: "Which Application"
                    visible: view.detail && (view.detail.packages || []).length > 0
                }
                Repeater {
                    model: view.detail ? (view.detail.packages || []) : []
                    delegate: QQC2.Label {
                        required property var modelData
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        text: "PID " + modelData.pid + " · " + modelData.user
                              + " · package: " + (modelData.package || "unpackaged")
                              + (modelData.purpose ? " — " + modelData.purpose : "")
                              + "\n" + modelData.command
                    }
                }

                Kirigami.Heading { level: 4; text: "Where to Look" }
                Flow {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    Repeater {
                        model: view.detail ? (view.detail.explore || []) : []
                        delegate: QQC2.Button {
                            required property var modelData
                            text: modelData.label
                            // the icon hints WHERE the jump leads
                            icon.name: modelData.kind === "events"
                                       ? "view-calendar-list" : "search"
                            onClicked: {
                                if (modelData.kind === "events")
                                    root.focusEvents(modelData.where)
                                else
                                    root.focusState(modelData.table,
                                                    modelData.col, modelData.val)
                                view.detail = null
                                detailDlg.close()
                            }
                        }
                    }
                    QQC2.Button {
                        text: "WHOIS"
                        icon.name: "documentinfo"
                        onClicked: view.whois = backend.whoisLookup(view.detail.ip)
                    }
                }

                Kirigami.Heading { level: 4; text: "Event Feed" }
                Repeater {
                    model: view.detail ? (view.detail.events || []).slice(0, 40) : []
                    delegate: QQC2.Label {
                        required property var modelData
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        font.family: "monospace"
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        text: Fmt.local(modelData.ts)
                              + "  " + modelData.event_action
                              + "  " + (modelData.process_name || "?")
                              + "  :" + (modelData.destination_port || "")
                              + "  " + (modelData.network_protocol || "")
                    }
                }
            }
        }
    }
}

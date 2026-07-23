import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components/Fmt.js" as Fmt
import "../components/QueryMatch.js" as QM
import "../components"
import "../pages"
import "."

// Who the machine talks to: directions by the number of SESSIONS (the volume in
// bytes is unavailable without root - we say so honestly in the caption), the
// network owner from the ASN, the DNS name. A click on an address - WHOIS.
Item {
    id: view
    property var d: ({ flows: [], dns: [], by_asn: [], live: [], resolvers: [],
                       series: [], by_process: [], rare: 0,
                       total: 0, external: 0, unit: "" })
    property var whois: null
    property var sel: null
    property string query: ""
    property var qconds: []
    property string qquick: ""
    property var hiddenCols: []

    // one description of the columns, read by the header and by the rows
    readonly property var cols: [
        { k: "last_seen", t: "Last seen", w: 11, mono: true },
        { k: "ip", t: "Address", w: 14, mono: true },
        { k: "as_org", t: "Network owner", w: 22, fill: true },
        { k: "country", t: "Country", w: 5 },
        { k: "process_name", t: "Process", w: 12, mono: true },
        { k: "protocol", t: "Protocol", w: 7 },
        { k: "sessions", t: "Sessions", w: 6, right: true, mono: true },
        { k: "direction", t: "Direction", w: 8 },
        { k: "rare", t: "Unusual", w: 14 }
    ]
    function fmt(row, key) {
        if (key === "last_seen") return Fmt.local(row.last_seen)
        if (key === "as_org" && !row.as_org)
            return row.direction === "internal" ? "(private network)" : ""
        return undefined
    }
    function rowAccent(r) {
        if (!r) return ""
        if (r.threat) return "#e74c3c"
        if (r.rare) return "#e67e22"
        return r.direction === "external" ? "#f1c40f" : ""
    }
    function refresh() { view.d = backend.networkFlows() }
    Component.onCompleted: refresh()
    property bool _stale: false
    onVisibleChanged: if (view.visible && view._stale) { view._stale = false; view.refresh() }
    Connections { target: backend
        function onStateReady(s) { if (view.visible) view.refresh(); else view._stale = true } }

    readonly property var rows: d.flows || []
    // The condition is evaluated here: the flows are aggregated in Python and
    // there is no table to hand an SQL string to. The syntax is the one the
    // shared query bar produces.
    readonly property var shown: {
        var _ = [view.qconds, view.qquick, view.rows]
        if (!view.qquick && (!view.qconds || !view.qconds.length)) return view.rows
        var out = []
        for (var i = 0; i < view.rows.length; i++)
            if (QM.rowMatches(view.rows[i], view.qconds, view.qquick, view.cols))
                out.push(view.rows[i])
        return out
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
            // A FACET IS A CONDITION, so it writes into the same query bar
            // instead of filtering on the side: two ways to select the same
            // thing are two places to get it wrong (principle 17).
            QQC2.ToolButton {
                text: "External only"
                onClicked: qbar.addCondition("direction", "=", "external")
            }
            // RARE SESSIONS. Bulk traffic is visible anyway; the inconspicuous -
            // a few connections, an unknown owner, a narrow window - is exactly
            // what gets lost in a common list.
            QQC2.ToolButton {
                text: "Unusual (" + view.d.rare + ")"
                enabled: view.d.rare > 0
                onClicked: qbar.addCondition("rare", "<>", "")
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

        QueryBar {
            id: qbar
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            fields: view.cols.map(function (c) { return { name: c.k } })
            defaultSelect: view.cols.map(function (c) { return c.k })
            placeholder: "direction = 'external'   \u00b7   or just type an address or a name"
            onApplied: function (spec, sql) {
                var hide = []
                if (spec.select.length)
                    for (var i = 0; i < view.cols.length; i++)
                        if (spec.select.indexOf(view.cols[i].k) < 0)
                            hide.push(view.cols[i].k)
                view.hiddenCols = hide
                view.qquick = qbar.builderMode ? qbar.quickText : ""
                view.qconds = qbar.builderMode ? (spec.where || [])
                                               : QM.parseWhere(qbar.manualWhere())
            }
        }
        Kirigami.Separator { Layout.fillWidth: true }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            DataTable {
                Layout.fillWidth: true
                Layout.fillHeight: true
                columns: view.cols
                rows: view.shown
                hidden: view.hiddenCols
                accent: view.rowAccent
                formatter: view.fmt
                onRowActivated: function (row) {
                    view.sel = row
                    view.whois = null
                }
                onConditionRequested: function (field, op, value) {
                    qbar.addCondition(field, op, value)
                }
            }

            SidePanel {
                id: side
                Layout.fillHeight: true
                open: view.sel !== null
                title: view.sel ? view.sel.ip : ""
                iconName: "network-connect"
                onCloseRequested: { view.sel = null; view.whois = null }

                QQC2.ScrollView {
                    id: scroller
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    ColumnLayout {
                        width: scroller.availableWidth
                        spacing: Kirigami.Units.smallSpacing

                        // WHAT TO DO NEXT - transitions, not the advice "go and
                        // look yourself" (principle 6).
                        QQC2.Button {
                            Layout.fillWidth: true
                            text: "Who talked to this address"
                            icon.name: "distribute-graph-directed"
                            onClicked: view.openAddress(view.sel.ip)
                        }
                        QQC2.Button {
                            Layout.fillWidth: true
                            text: "Events for this address"
                            icon.name: "view-list-details"
                            onClicked: root.focusEvents("destination_ip='" + view.sel.ip + "'")
                        }
                        QQC2.Button {
                            Layout.fillWidth: true
                            text: "WHOIS"
                            icon.name: "documentinfo"
                            onClicked: view.whois = backend.whoisLookup(view.sel.ip)
                        }
                        Kirigami.Separator { Layout.fillWidth: true }

                        Repeater {
                            model: view.sel ? Object.keys(view.sel) : []
                            delegate: RowLayout {
                                required property var modelData
                                Layout.fillWidth: true
                                visible: String(view.sel[modelData] || "") !== ""
                                spacing: Kirigami.Units.smallSpacing
                                QQC2.Label {
                                    Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                                    text: modelData
                                    opacity: 0.6
                                    elide: Text.ElideRight
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                }
                                QQC2.Label {
                                    Layout.fillWidth: true
                                    text: (modelData === "last_seen" || modelData === "first_seen")
                                          ? Fmt.local(view.sel[modelData])
                                          : String(view.sel[modelData])
                                    wrapMode: Text.WrapAnywhere
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                }
                            }
                        }

                        Kirigami.Separator { Layout.fillWidth: true; visible: view.whois !== null }
                        Repeater {
                            model: view.whois ? Object.keys(view.whois) : []
                            delegate: RowLayout {
                                required property var modelData
                                Layout.fillWidth: true
                                visible: String(view.whois[modelData] || "") !== ""
                                spacing: Kirigami.Units.smallSpacing
                                QQC2.Label {
                                    Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                                    text: modelData
                                    opacity: 0.6
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                }
                                QQC2.Label {
                                    Layout.fillWidth: true
                                    text: String(view.whois[modelData])
                                    wrapMode: Text.WrapAnywhere
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                }
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

}

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "Fmt.js" as Fmt
import "."

// THE GRAPH CANVAS - a reusable investigation component.
//
// Assembled from the studied practice of mature EDRs (SentinelOne Storyline,
// Defender, Elastic, Cortex, Chronicle) plus graph visualisation:
// (Cambridge Intelligence combos, DEPCOMM):
//   * CATEGORY CLUSTERS: related things are grouped; a large group is collapsed
//     into a meta node with a counter and expands in place (a click) - a
//     "starburst" does not bury the canvas;
//   * the colour of the STRIPE = the category, colour+icon+shape = the entity
//     type, a red frame = risk (type and risk are orthogonal, as in Defender);
//   * hovering highlights the neighbours and dims the rest (focus+context);
//   * ACTION BUTTONS on a node: drill into State/Events, make it the centre
//     (pivot), WHOIS - "drill deeper" in one gesture;
//   * a zoom panel + "fit everything".
//
// The layout (x/y) and the collapse/expand decision arrive READY from Python;
// QML only draws and emits signals. Node ids are stable -> animation is free.
Item {
    id: canvasRoot

    property var graph: ({ nodes: [], edges: [], categories: [] })
    property string selectedId: ""
    property string hoveredId: ""
    property real zoom: 1.0
    // the scale changes smoothly: an abrupt jump breaks orientation
    Behavior on zoom { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    property int worldW: graph && graph.width ? graph.width : 1100
    property int worldH: graph && graph.height ? graph.height : 780

    signal nodeActivated(var node)          // a click on a node -> the side panel
    signal toggleCategory(string category)  // a click on a meta node -> expand
    signal anchorRequested(var node)        // "make it the centre" (pivot)
    signal drillRequested(string action, var node)  // drill down

    // EVERY TYPE HAS ITS OWN FIXED COLOUR - it does not change between graphs, so
    // "orange = a remote address" is memorised and read without a legend.
    // Processes are deliberately GREY: there are more of them on the canvas than
    // anything else, and what should stand out is what is around them.
    function colorFor(kind) {
        return kind === "process"   ? "#6e7276"   // grey - there are more of them
             : kind === "user"      ? "#2980b9"   // blue
             : kind === "package"   ? "#27ae60"   // green
             : kind === "service"   ? "#2471a3"   // dark blue
             : kind === "remote"    ? "#e67e22"   // orange
             : kind === "listen"    ? "#c0392b"   // red
             : kind === "socket"    ? "#8e44ad"   // violet
             : kind === "config"    ? "#16a085"   // teal
             : kind === "file"      ? "#5d6d7e"   // slate
             : kind === "dir"       ? "#34495e"   // dark slate
             : kind === "action"    ? "#b7950b"   // olive
             : kind === "vuln"      ? "#922b21"   // dark red
             : kind === "persist"   ? "#6c3483"   // dark violet
             : kind === "suid"      ? "#d35400"   // pumpkin
             : kind === "privesc"   ? "#a04000"   // brown orange
             : kind === "scheduled" ? "#148f77"   // dark teal
             : kind === "kmod"      ? "#7d3c98"   // lilac
             : kind === "group"     ? "#4a5158"   // neutral, a block header
             : kind === "warning"   ? "#cb4335"   // bright red
             : Kirigami.Theme.disabledTextColor
    }
    function iconFor(kind) {
        return kind === "process"   ? "system-run"
             : kind === "user"      ? "user-identity"
             : kind === "package"   ? "package-x-generic"
             : kind === "remote"    ? "network-connect"
             : kind === "listen"    ? "network-server"
             : kind === "socket"    ? "network-wireless"
             : kind === "action"    ? "view-calendar-list"
             : kind === "config"    ? "document-properties"
             : kind === "vuln"      ? "security-low"
             : kind === "persist"   ? "system-reboot"
             : kind === "suid"      ? "security-medium"
             : kind === "privesc"   ? "dialog-warning"
             : kind === "scheduled" ? "chronometer"
             : kind === "service"   ? "applications-system"
             : kind === "kmod"      ? "cpu"
             : kind === "file"      ? "document-open"
             : kind === "dir"       ? "folder"
             : kind === "group"     ? "folder-open"
             : "dialog-information"
    }
    // the category colour comes from the data (Python sends color on the node); a fallback by name
    function categoryColor(node) {
        if (node && node.color) return node.color
        return canvasRoot.colorFor(node ? node.kind : "")
    }

    // ---- MOVING NODES ----
    // Position is written in ONE place, straight into the model, so the edges
    // (drawn from the same array) follow immediately. Writing to modelData
    // would hit a copy and the lines would lag behind.
    readonly property int grid: 40
    signal nodeMoved(string id, int x, int y)
    function snapG(v) { return Math.max(grid, Math.round(v / grid) * grid) }

    function nodeAt(id) {
        var ns = graph.nodes || []
        for (var i = 0; i < ns.length; i++) if (ns[i].id === id) return ns[i]
        return null
    }
    // Keep a clear gap between cards: a dropped node is pushed to the nearest
    // free slot instead of landing on top of another one.
    function freeSlot(id, x, y) {
        var W = 190, H = 70, pad = grid
        var ns = graph.nodes || []
        function busy(px, py) {
            for (var i = 0; i < ns.length; i++) {
                var n = ns[i]
                if (n.id === id) continue
                if (px < n.x + W + pad && px + W + pad > n.x
                    && py < n.y + H + pad && py + H + pad > n.y) return true
            }
            return false
        }
        if (!busy(x, y)) return { x: x, y: y }
        for (var r = 1; r <= 10; r++)
            for (var dy = -r; dy <= r; dy++)
                for (var dx = -r; dx <= r; dx++) {
                    if (Math.abs(dx) !== r && Math.abs(dy) !== r) continue
                    var nx = Math.max(grid, x + dx * grid)
                    var ny = Math.max(grid, y + dy * grid)
                    if (!busy(nx, ny)) return { x: nx, y: ny }
                }
        return { x: x, y: y }
    }
    function setNodePos(id, nx, ny) {
        var n = nodeAt(id)
        if (!n) return
        n.x = nx; n.y = ny
        wires.requestPaint()
    }

    function isNeighbour(id) {
        if (hoveredId === "" || id === hoveredId) return true
        var e = graph.edges || []
        for (var i = 0; i < e.length; i++)
            if ((e[i].a === hoveredId && e[i].b === id)
                || (e[i].b === hoveredId && e[i].a === id)) return true
        return false
    }

    function fit() {
        if (!graph || !graph.nodes || graph.nodes.length === 0) return
        var z = Math.min(width / worldW, height / worldH) * 0.92
        canvasRoot.zoom = Math.max(0.35, Math.min(1.5, z))
        flick.contentX = 0; flick.contentY = 0
    }
    // Fit ONLY when the anchor changes. It used to run on every graph
    // update, and expanding a category rebuilds the graph — so each click
    // re-zoomed the canvas and the view kept drifting out.
    property string fittedAnchor: ""
    onGraphChanged: {
        var a = (graph && graph.anchor) ? String(graph.anchor.val) : ""
        if (a !== fittedAnchor) { fittedAnchor = a; fit() }
        repaintPulse.restart()
    }

    // the edges are drawn on a Canvas; while the nodes animate they must be repainted
    Timer {
        id: repaintPulse
        interval: 16; repeat: true
        property int ticks: 0
        onTriggered: { wires.requestPaint(); ticks++; if (ticks > 22) { stop(); ticks = 0 } }
        onRunningChanged: if (running) ticks = 0
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: world.width * canvasRoot.zoom
        contentHeight: world.height * canvasRoot.zoom
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Item {
            id: world
            width: canvasRoot.worldW
            height: canvasRoot.worldH
            transform: Scale {
                origin.x: 0; origin.y: 0
                xScale: canvasRoot.zoom; yScale: canvasRoot.zoom
            }

            // Same faint grid as the pipeline editor: it gives the eye a
            // reference for alignment without competing with the content.
            Canvas {
                id: gridLayer
                anchors.fill: parent
                z: -1
                opacity: 0.5
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                Component.onCompleted: requestPaint()
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    var g = 40
                    ctx.lineWidth = 1
                    for (var x = g; x < width; x += g) {
                        ctx.strokeStyle = Qt.alpha(Kirigami.Theme.textColor,
                                                   (x / g) % 4 === 0 ? 0.10 : 0.05)
                        ctx.beginPath(); ctx.moveTo(x + 0.5, 0)
                        ctx.lineTo(x + 0.5, height); ctx.stroke()
                    }
                    for (var y = g; y < height; y += g) {
                        ctx.strokeStyle = Qt.alpha(Kirigami.Theme.textColor,
                                                   (y / g) % 4 === 0 ? 0.10 : 0.05)
                        ctx.beginPath(); ctx.moveTo(0, y + 0.5)
                        ctx.lineTo(width, y + 0.5); ctx.stroke()
                    }
                }
            }

            Canvas {
                id: wires
                anchors.fill: parent
                antialiasing: true
                property var g: canvasRoot.graph
                property string hov: canvasRoot.hoveredId
                onGChanged: requestPaint()
                onHovChanged: requestPaint()
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    if (!g || !g.nodes) return
                    var pos = {}
                    for (var i = 0; i < g.nodes.length; i++)
                        pos[g.nodes[i].id] = g.nodes[i]
                    var edges = g.edges || []
                    ctx.font = "10px sans-serif"
                    ctx.lineCap = "round"
                    for (var j = 0; j < edges.length; j++) {
                        var e = edges[j]
                        var a = pos[e.a], b = pos[e.b]
                        if (!a || !b) continue
                        var lit = hov === "" || e.a === hov || e.b === hov
                        var member = e.rel === "member"
                        var conn = e.rel === "connected"
                        // the edge colour follows the meaning of the link
                        var col = conn ? Qt.rgba(0.90, 0.49, 0.13, lit ? 0.75 : 0.2)
                                       : Qt.alpha(Kirigami.Theme.textColor, lit ? 0.5 : 0.1)
                        ctx.strokeStyle = col
                        ctx.fillStyle = col
                        // THE LINES ARE SOLID AND SMOOTH. The dashes on meta edges
                        // were removed (they shimmered and read as "the link is not
                        // real"); the thickness still tells a bundle from a single link.
                        ctx.lineWidth = member ? Math.min(5, 1.6 + (e.count || 1) / 5)
                                               : (lit && hov !== "" ? 2.2 : 1.5)
                        ctx.setLineDash([])
                        // A cubic curve with the control points ALONG the main
                        // direction: the line leaves and enters tangentially, so the
                        // bend is soft whatever the mutual position of the nodes
                        // (the ladder goes down, the tree goes sideways).
                        // Python may hand us a routing corridor: a free
                        // vertical band between the process tree and the
                        // category column. Going through it keeps the curve
                        // off the cards it would otherwise cross.
                        if (e.via_x && e.via_x > 0) {
                            ctx.beginPath()
                            ctx.moveTo(a.x, a.y)
                            ctx.bezierCurveTo(e.via_x, a.y, e.via_x, b.y, b.x, b.y)
                            ctx.stroke()
                            if (member && e.count) {
                                ctx.fillStyle = Kirigami.Theme.textColor
                                ctx.fillText("×" + e.count, e.via_x - 6,
                                             (a.y + b.y) / 2 - 2)
                                ctx.fillStyle = col
                            }
                            continue
                        }
                        var ddx = b.x - a.x, ddy = b.y - a.y
                        var vert = Math.abs(ddy) >= Math.abs(ddx)
                        var sx = ddx < 0 ? -1 : 1, sy = ddy < 0 ? -1 : 1
                        var c1x, c1y, c2x, c2y
                        if (vert) {
                            var dv = Math.max(38, Math.abs(ddy) * 0.42)
                            c1x = a.x; c1y = a.y + sy * dv
                            c2x = b.x; c2y = b.y - sy * dv
                        } else {
                            var dh = Math.max(38, Math.abs(ddx) * 0.42)
                            c1x = a.x + sx * dh; c1y = a.y
                            c2x = b.x - sx * dh; c2y = b.y
                        }
                        ctx.beginPath()
                        ctx.moveTo(a.x, a.y)
                        ctx.bezierCurveTo(c1x, c1y, c2x, c2y, b.x, b.y)
                        ctx.stroke()
                        // the arrow follows the tangent at the end (from the second
                        // control point to the node) - not for meta edges, the bundle is collapsed there
                        if (!member) {
                            var ang = Math.atan2(b.y - c2y, b.x - c2x)
                            var hx = b.x - Math.cos(ang) * 17, hy = b.y - Math.sin(ang) * 17
                            ctx.beginPath()
                            ctx.moveTo(hx, hy)
                            ctx.lineTo(hx - Math.cos(ang - 0.4) * 7, hy - Math.sin(ang - 0.4) * 7)
                            ctx.lineTo(hx - Math.cos(ang + 0.4) * 7, hy - Math.sin(ang + 0.4) * 7)
                            ctx.closePath(); ctx.fill()
                        }
                        // the middle of the curve (t=0.5) - that is where the label goes
                        var lx = 0.125 * a.x + 0.375 * c1x + 0.375 * c2x + 0.125 * b.x
                        var ly = 0.125 * a.y + 0.375 * c1y + 0.375 * c2y + 0.125 * b.y
                        // the label: xN on a meta edge always; the relation - on hover
                        if (member && e.count) {
                            ctx.fillStyle = Kirigami.Theme.textColor
                            ctx.fillText("×" + e.count, lx - 6, ly - 2)
                        } else if (lit && hov !== "" && e.label) {
                            ctx.fillStyle = Kirigami.Theme.textColor
                            ctx.fillText(e.label, lx - 8, ly - 2)
                        }
                    }
                }
            }

            Repeater {
                model: canvasRoot.graph ? (canvasRoot.graph.nodes || []) : []
                delegate: Rectangle {
                    id: chip
                    required property var modelData
                    property bool isGroup: modelData.kind === "group"
                    property bool dim: !canvasRoot.isNeighbour(modelData.id)
                    property real scaleF: modelData.focus ? 1.14 : (isGroup ? 1.05 : 1.0)

                    color: Qt.alpha(canvasRoot.colorFor(modelData.kind), dim ? 0.16 : 0.9)
                    border.width: canvasRoot.selectedId === modelData.id ? 3
                                  : modelData.focus ? 3 : (modelData.risk ? 2 : 1)
                    border.color: canvasRoot.selectedId === modelData.id
                                  ? Kirigami.Theme.highlightColor
                                  : modelData.focus ? "#f1c40f"
                                  : modelData.risk ? "#e74c3c"
                                  : Qt.alpha(Kirigami.Theme.textColor, 0.4)
                    // ONE SHAPE FOR ALL NODES: a rectangle with square corners.
                    // Ovals mixed with blocks read as "different entities",
                    // although the type is already shown by the icon and the colour.
                    radius: 0
                    opacity: dim ? 0.4 : 1.0
                    Behavior on opacity { NumberAnimation { duration: 140 } }
                    Behavior on x { NumberAnimation { duration: 190; easing.type: Easing.OutCubic } }
                    Behavior on y { NumberAnimation { duration: 190; easing.type: Easing.OutCubic } }
                    // the width is limited: a long label used to stretch the node
                    // and it covered its neighbours and the edges
                    // the width is NO MORE than the layout step (200 px in Python),
                    // otherwise neighbouring nodes overlap
                    readonly property int maxW: 184
                    width: Math.min(maxW, (rowc.implicitWidth + 20) * scaleF)
                    height: (rowc.implicitHeight + 8) * scaleF
                    x: modelData.x - width / 2
                    y: modelData.y - height / 2
                    onXChanged: repaintPulse.restart()

                    RowLayout {
                        id: rowc
                        anchors.centerIn: parent
                        anchors.horizontalCenterOffset: 2
                        spacing: Kirigami.Units.smallSpacing
                        Kirigami.Icon {
                            // a block gets the icon of its contents (processes,
                            // events, files), otherwise unnamed blocks cannot be
                            // told apart
                            source: canvasRoot.iconFor(
                                chip.isGroup && modelData.icon_kind
                                ? modelData.icon_kind : modelData.kind)
                            color: "white"
                            Layout.preferredWidth: chip.isGroup
                                ? Kirigami.Units.iconSizes.smallMedium : Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Layout.preferredWidth
                        }
                        ColumnLayout {
                            spacing: 0
                            QQC2.Label {
                                text: modelData.label || ""
                                font.bold: true
                                color: "white"
                                elide: Text.ElideRight
                                Layout.maximumWidth: chip.maxW - Kirigami.Units.gridUnit * 2
                                font.pointSize: chip.isGroup
                                    ? Kirigami.Theme.smallFont.pointSize
                                    : Kirigami.Theme.smallFont.pointSize
                            }
                            QQC2.Label {
                                // THE TIME is in the local zone: events are stored
                                // in UTC, the UI boundary converts them (Fmt.js)
                                text: {
                                    var s = modelData.sub || ""
                                    var w = modelData.when || ""
                                    if (!w) return s
                                    var t = Fmt.localHM(w)
                                    return s ? s + " · " + t : t
                                }
                                visible: text !== ""
                                color: Qt.alpha("white", 0.85)
                                elide: Text.ElideRight
                                Layout.maximumWidth: chip.maxW - Kirigami.Units.gridUnit * 2
                                font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                            }
                            QQC2.Label {
                                text: modelData.counts || ""
                                visible: text !== ""
                                color: Qt.alpha("white", 0.95)
                                elide: Text.ElideRight
                                Layout.maximumWidth: chip.maxW - Kirigami.Units.gridUnit * 2
                                font.bold: true
                                font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                            }
                        }
                        // the counter on a category meta node
                        Rectangle {
                            visible: chip.isGroup && modelData.count > 0
                            radius: height / 2
                            color: Qt.alpha("white", 0.25)
                            Layout.preferredWidth: cntl.implicitWidth + 8
                            Layout.preferredHeight: cntl.implicitHeight + 2
                            QQC2.Label {
                                id: cntl
                                anchors.centerIn: parent
                                text: modelData.count ? String(modelData.count) : ""
                                color: "white"; font.bold: true
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                        }
                    }

                    // the risk/status badge in the corner (OPEN, DELETED, +N...)
                    Rectangle {
                        visible: (modelData.badge || "") !== "" && !chip.isGroup
                        anchors { right: parent.right; top: parent.top; margins: -4 }
                        radius: 3
                        color: modelData.risk ? "#c0392b" : "#e67e22"
                        width: bl.implicitWidth + 6; height: bl.implicitHeight + 2
                        QQC2.Label {
                            id: bl; anchors.centerIn: parent
                            text: modelData.badge || ""; color: "white"
                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 2
                        }
                    }

                    HoverHandler {
                        onHoveredChanged: canvasRoot.hoveredId = hovered ? modelData.id : ""
                    }
                    // Nodes can be dragged: the layout is presentation, and an
                    // analyst rearranges it while reading. Edges follow live
                    // because the position goes into the model.
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        drag.target: chip
                        drag.threshold: 5
                        propagateComposedEvents: true
                        onPressed: function (mouse) { mouse.accepted = false }
                        onPositionChanged: if (drag.active)
                            canvasRoot.setNodePos(modelData.id,
                                                  Math.round(chip.x + chip.width / 2),
                                                  Math.round(chip.y + chip.height / 2))
                        onReleased: {
                            if (!drag.active) return
                            var pos = canvasRoot.freeSlot(
                                modelData.id,
                                canvasRoot.snapG(chip.x + chip.width / 2),
                                canvasRoot.snapG(chip.y + chip.height / 2))
                            canvasRoot.setNodePos(modelData.id, pos.x, pos.y)
                            canvasRoot.nodeMoved(modelData.id, pos.x, pos.y)
                        }
                    }
                    TapHandler {
                        onTapped: {
                            if (chip.isGroup) {
                                canvasRoot.toggleCategory(modelData.category)
                            } else {
                                canvasRoot.selectedId = modelData.id
                                canvasRoot.nodeActivated(modelData)
                            }
                        }
                    }
                    // a double click on an anchor entity = pivot (make it the centre)
                    TapHandler {
                        acceptedButtons: Qt.LeftButton
                        onDoubleTapped: {
                            if (!chip.isGroup && modelData.drill === "reanchor")
                                canvasRoot.anchorRequested(modelData)
                        }
                    }

                    // ---- ACTION BUTTONS (drill), shown on the selected/hovered node ----
                    Row {
                        z: 20
                        anchors { bottom: parent.top; right: parent.right; bottomMargin: 1 }
                        spacing: 1
                        visible: !chip.isGroup && (canvasRoot.selectedId === modelData.id
                                                   || canvasRoot.hoveredId === modelData.id)
                        QQC2.ToolButton {
                            width: 22; height: 22
                            icon.name: "draw-arrow-forward"
                            visible: modelData.drill === "reanchor"
                            QQC2.ToolTip.text: "Make this the centre of the graph"
                            QQC2.ToolTip.visible: hovered
                            onClicked: canvasRoot.anchorRequested(modelData)
                        }
                        QQC2.ToolButton {
                            width: 22; height: 22
                            icon.name: "network-connect"
                            visible: modelData.drill === "whois"
                            QQC2.ToolTip.text: "WHOIS for this address"
                            QQC2.ToolTip.visible: hovered
                            onClicked: canvasRoot.drillRequested("whois", modelData)
                        }
                        QQC2.ToolButton {
                            width: 22; height: 22
                            icon.name: "view-calendar-list"
                            visible: modelData.drill === "events"
                            QQC2.ToolTip.text: "Events for this"
                            QQC2.ToolTip.visible: hovered
                            onClicked: canvasRoot.drillRequested("events", modelData)
                        }
                        QQC2.ToolButton {
                            width: 22; height: 22
                            icon.name: "view-list-details"
                            visible: (modelData.table || "") !== ""
                            QQC2.ToolTip.text: "Show in State"
                            QQC2.ToolTip.visible: hovered
                            onClicked: canvasRoot.drillRequested("state", modelData)
                        }
                    }
                }
            }
        }

        // A PINCH ON THE TOUCHPAD: two fingers diagonally - zoom towards the point
        // between them. It works together with Ctrl+wheel (a mouse has no pinch).
        PinchHandler {
            target: null
            property real startZoom: 1
            onActiveChanged: if (active) startZoom = canvasRoot.zoom
            onScaleChanged: {
                if (!active) return
                var next = Math.max(0.35, Math.min(2.2, startZoom * activeScale))
                var c = centroid.position
                var fx = (flick.contentX + c.x) / canvasRoot.zoom
                var fy = (flick.contentY + c.y) / canvasRoot.zoom
                canvasRoot.zoom = next
                flick.contentX = Math.max(0, fx * next - c.x)
                flick.contentY = Math.max(0, fy * next - c.y)
            }
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            z: 50
            onWheel: function (w) {
                if (w.modifiers & Qt.ControlModifier) {
                    var old = canvasRoot.zoom
                    var next = Math.max(0.35, Math.min(2.2,
                                        old * (w.angleDelta.y > 0 ? 1.12 : 0.89)))
                    var fx = (flick.contentX + w.x) / old, fy = (flick.contentY + w.y) / old
                    canvasRoot.zoom = next
                    flick.contentX = Math.max(0, fx * next - w.x)
                    flick.contentY = Math.max(0, fy * next - w.y)
                } else {
                    // Give the wheel back to the page when the graph has
                    // nothing left to scroll in that direction. It used to
                    // swallow every wheel event, so hovering the graph froze
                    // the dashboard's own scrolling.
                    var maxY = Math.max(0, flick.contentHeight - flick.height)
                    var atTop = flick.contentY <= 0
                    var atBottom = flick.contentY >= maxY - 0.5
                    var up = w.angleDelta.y > 0
                    if (maxY <= 0 || (up && atTop) || (!up && atBottom)) {
                        w.accepted = false          // let the page scroll
                        return
                    }
                    flick.contentY = Math.max(0, Math.min(maxY,
                                              flick.contentY - w.angleDelta.y))
                }
            }
        }
    }

    // ---- the zoom panel ----
    Row {
        anchors { right: parent.right; top: parent.top; margins: Kirigami.Units.smallSpacing }
        spacing: 2
        QQC2.ToolButton {
            icon.name: "zoom-in"; onClicked: canvasRoot.zoom = Math.min(2.2, canvasRoot.zoom * 1.15)
            QQC2.ToolTip.text: "Zoom in"; QQC2.ToolTip.visible: hovered
        }
        QQC2.ToolButton {
            icon.name: "zoom-out"; onClicked: canvasRoot.zoom = Math.max(0.35, canvasRoot.zoom * 0.87)
            QQC2.ToolTip.text: "Zoom out"; QQC2.ToolTip.visible: hovered
        }
        QQC2.ToolButton {
            icon.name: "zoom-fit-best"; onClicked: canvasRoot.fit()
            QQC2.ToolTip.text: "Fit to view"; QQC2.ToolTip.visible: hovered
        }
    }

    QQC2.Label {
        anchors { right: parent.right; bottom: parent.bottom; margins: Kirigami.Units.smallSpacing }
        opacity: 0.5
        font.pointSize: Kirigami.Theme.smallFont.pointSize
        text: "click a group to expand · double-click to re-centre · Ctrl+wheel to zoom "
              + Math.round(canvasRoot.zoom * 100) + "%"
    }
}

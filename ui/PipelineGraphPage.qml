import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

// The full-screen pipeline graph editor: a space with zoom (Ctrl+wheel),
// panning, live edges while dragging and a preview panel for the expertise
// object.
Kirigami.Page {
    id: page
    property string pipeName: ""
    property var graph: ({ title: "", nodes: [], edges: [] })
    property string selected: ""
    property string connectFrom: ""
    property real zoom: 1.0
    // the canvas size follows the outermost nodes (+ a margin) so that it scrolls to the end
    property real worldW: {
        let m = 900
        for (const n of graph.nodes) m = Math.max(m, n.x + 400)
        return m
    }
    property real worldH: {
        let m = 700
        for (const n of graph.nodes) m = Math.max(m, n.y + 200)
        return m
    }
    title: "Pipeline: " + graph.title +
           (editMode ? "  [editing]" : isDraft ? "  [draft]" : "")
    padding: 0

    readonly property var kindOrder: ({ input: 0, normalize: 1, enrich: 2,
                                        filter: 3, correlation: 3, output: 4 })
    readonly property var kindNames: ({ input: "input", normalize: "normalization",
                                        enrich: "enrichment", filter: "filter",
                                        correlation: "correlation", output: "output" })
    readonly property var kindCats: ({ input: "inputs", normalize: "normalize",
                                       enrich: "enrich", filter: "filters",
                                       correlation: "correlation", output: "outputs" })

    Component.onCompleted: reloadGraph()

    property bool isDraft: false
    property bool editMode: false
    function reloadGraph() {
        graph = backend.pipelineGraphDraft(pipeName)
        isDraft = graph.draft === true
        // the layout must be correct ALWAYS, not only after pressing
        // "Arrange"
        if (enforceLayout() > 0) savePos()
        canvas.requestPaint()
    }
    function save() {   // edits only in edit mode -> into the draft
        if (!editMode) return
        backend.savePipelineDraft(pipeName, JSON.stringify(
            { nodes: graph.nodes, edges: graph.edges }))
        isDraft = true
    }
    // A node position is PRESENTATION, not configuration: the topology (edges,
    // bindings) does not change when dragging. So the layout is saved straight
    // into the working file and does not force you to enter edit mode and then
    // "apply the configuration" just for it.
    // ---- GRID ----
    // Cards are grid-sized (6 x 2 cells) and every gap is exactly two cells,
    // so blocks can never touch or overlap. The grid itself is drawn very
    // faintly: it explains where things snap without competing for attention.
    readonly property int grid: 40
    readonly property int cardW: grid * 6          // 240
    readonly property int cardH: grid * 2          // 80
    readonly property int stepX: cardW + grid * 2  // card + two cells
    readonly property int stepY: cardH + grid * 2
    function snap(v) { return Math.max(grid, Math.round(v / grid) * grid) }

    // THE ONLY PLACE where a node position changes.
    // The card used to write `modelData.x = x`, but modelData in a Repeater over
    // a JS array is a COPY, and the model did not change: the edges were drawn at
    // the old coordinates, so the arrows "did not follow". Now the position is
    // written into the array itself by id, and the layout and snapping use it too.
    function setNodePos(id, nx, ny) {
        for (var i = 0; i < graph.nodes.length; i++) {
            if (graph.nodes[i].id === id) {
                graph.nodes[i].x = nx
                graph.nodes[i].y = ny
                canvas.requestPaint()
                return
            }
        }
    }

    // THE INVARIANT: there are always at least two grid cells between cards.
    // It is enforced not only while dragging but on EVERY load: a saved layout
    // could have been made earlier (a different card size, manual coordinates)
    // and arrived with overlaps.
    function enforceLayout() {
        // Iteratively: moving one node may touch an already placed one, so we
        // repeat until the layout stops changing. A single pass left overlaps.

        var total = 0
        for (var pass = 0; pass < 8; pass++) {
            var moved = 0
            for (var i = 0; i < graph.nodes.length; i++) {
                var n = graph.nodes[i]
                var pos = placeFree(n.id, snap(n.x), snap(n.y))
                if (pos.x !== n.x || pos.y !== n.y) {
                    n.x = pos.x; n.y = pos.y
                    moved++
                }
            }
            total += moved
            if (moved === 0) break
        }
        if (total > 0) { graphChanged(); canvas.requestPaint() }
        return total
    }

    // Is this slot free, counting a two-cell margin around every other card?
    function slotFree(id, x, y) {
        var pad = grid * 2
        for (var i = 0; i < graph.nodes.length; i++) {
            var n = graph.nodes[i]
            if (n.id === id) continue
            if (x < n.x + cardW + pad && x + cardW + pad > n.x
                && y < n.y + cardH + pad && y + cardH + pad > n.y) return false
        }
        return true
    }
    // Nearest free slot, searched outwards in grid steps so the card lands
    // close to where it was dropped rather than jumping across the canvas.
    function placeFree(id, x, y) {
        if (slotFree(id, x, y)) return { x: x, y: y }
        for (var r = 1; r <= 12; r++) {
            for (var dy = -r; dy <= r; dy++) {
                for (var dx = -r; dx <= r; dx++) {
                    if (Math.abs(dx) !== r && Math.abs(dy) !== r) continue
                    var nx = Math.max(grid, x + dx * grid)
                    var ny = Math.max(grid, y + dy * grid)
                    if (slotFree(id, nx, ny)) return { x: nx, y: ny }
                }
            }
        }
        // Ring search can fail in a dense column. Falling back to the original
        // position left cards overlapping, so instead walk DOWN the same
        // column until a slot is free — a free row always exists below.
        for (var k = 1; k <= 400; k++) {
            var fy = y + k * grid
            if (slotFree(id, x, fy)) return { x: x, y: fy }
        }
        return { x: x, y: y }
    }

    // A free "corridor" for an edge: if the straight path crosses cards, we look
    // for the nearest horizontal ABOVE or BELOW them that can be passed through.
    // Returns the Y offset for the control points of the curve (0 - the path is clear).
    function channelFor(a, b) {
        var y1 = a.y + cardH / 2, y2 = b.y + cardH / 2
        var xa = a.x + cardW, xb = b.x
        if (xb <= xa) return 0                     // backwards - we do not route
        var hit = []
        for (var i = 0; i < graph.nodes.length; i++) {
            var n = graph.nodes[i]
            if (n.id === a.id || n.id === b.id) continue
            if (n.x + cardW < xa || n.x > xb) continue      // not between them
            // does the straight line cross the vertical range of the card
            var t = (n.x + cardW / 2 - xa) / Math.max(1, xb - xa)
            var yAt = y1 + (y2 - y1) * t
            if (yAt > n.y - 6 && yAt < n.y + cardH + 6) hit.push(n)
        }
        if (!hit.length) return 0
        // we go around towards the nearest edge of the obstructing cards
        var top = hit[0].y, bot = hit[0].y + cardH
        for (var j = 1; j < hit.length; j++) {
            top = Math.min(top, hit[j].y)
            bot = Math.max(bot, hit[j].y + cardH)
        }
        var mid = (y1 + y2) / 2
        var up = top - grid - mid, down = bot + grid - mid
        return Math.abs(up) <= Math.abs(down) ? up : down
    }

    function tidyLayout() {
        var order = { input: 0, normalize: 1, enrich: 2,
                      filter: 3, correlation: 3, output: 4 }
        var nodes = page.graph.nodes, edges = page.graph.edges

        // --- 1. columns by kind ---
        var cols = {}, colOf = {}
        for (var i = 0; i < nodes.length; i++) {
            var c = order[nodes[i].kind] !== undefined ? order[nodes[i].kind] : 5
            colOf[nodes[i].id] = c
            if (!cols[c]) cols[c] = []
            cols[c].push(nodes[i])
        }

        // --- 2. UNTANGLE THE EDGES (barycentre / Sugiyama ordering) ---
        // Without this, a normalize node in row 3 connects to an input in row
        // 40 and the canvas turns into a web. Each node is pulled towards the
        // average row of the nodes it is joined to, sweeping left-to-right and
        // back; a few passes is enough and it is deterministic.
        var succ = {}, pred = {}
        for (var e = 0; e < edges.length; e++) {
            var a = edges[e][0], b = edges[e][1]
            if (!succ[a]) succ[a] = []
            if (!pred[b]) pred[b] = []
            succ[a].push(b); pred[b].push(a)
        }
        var keys = Object.keys(cols).map(Number).sort(function (x, y) { return x - y })
        var pos = {}
        function reindex() {
            for (var ci = 0; ci < keys.length; ci++) {
                var arr = cols[keys[ci]]
                for (var r = 0; r < arr.length; r++) pos[arr[r].id] = r
            }
        }
        reindex()
        function bary(id, rel) {
            var ns = rel[id]
            if (!ns || !ns.length) return pos[id]
            var sum = 0, cnt = 0
            for (var j = 0; j < ns.length; j++)
                if (pos[ns[j]] !== undefined) { sum += pos[ns[j]]; cnt++ }
            return cnt ? sum / cnt : pos[id]
        }
        for (var pass = 0; pass < 4; pass++) {
            var fwd = pass % 2 === 0
            var seq = fwd ? keys.slice() : keys.slice().reverse()
            for (var s2 = 0; s2 < seq.length; s2++) {
                var arr2 = cols[seq[s2]]
                var rel2 = fwd ? pred : succ
                arr2.sort(function (m, n2) {
                    return bary(m.id, rel2) - bary(n2.id, rel2)
                })
                reindex()
            }
        }

        // --- 3. ALIGN EACH NODE WITH ITS CONNECTIONS ---
        // Ordering alone still left a node several rows away from what it is
        // joined to, so the arrows looked random. Here every node is pulled to
        // the ROW of its neighbours (median of their y), and only then pushed
        // apart to keep the two-cell gap. A node joined to one predecessor
        // ends up on exactly its line, so that edge becomes horizontal.
        for (var ck = 0; ck < keys.length; ck++) {
            var col0 = keys[ck], list0 = cols[col0]
            for (var rr = 0; rr < list0.length; rr++) {
                list0[rr].x = page.grid + col0 * page.stepX
                list0[rr].y = page.grid + rr * page.stepY
            }
        }
        function medianY(ids) {
            var ys = []
            for (var i = 0; i < ids.length; i++) {
                var n = nodeById(ids[i])
                if (n) ys.push(n.y)
            }
            if (!ys.length) return -1
            ys.sort(function (a, b) { return a - b })
            return ys[Math.floor(ys.length / 2)]
        }
        // two sweeps: forward aligns to predecessors, backward to successors
        for (var sweep = 0; sweep < 3; sweep++) {
            var order2 = sweep % 2 === 0 ? keys.slice() : keys.slice().reverse()
            for (var oi = 0; oi < order2.length; oi++) {
                var lst = cols[order2[oi]]
                for (var q = 0; q < lst.length; q++) {
                    var want = medianY(sweep % 2 === 0
                                       ? (pred[lst[q].id] || [])
                                       : (succ[lst[q].id] || []))
                    if (want >= 0) lst[q].y = want
                }
                // restore the minimum gap without changing the order
                lst.sort(function (a, b) { return a.y - b.y })
                for (var w2 = 1; w2 < lst.length; w2++)
                    if (lst[w2].y < lst[w2 - 1].y + page.stepY)
                        lst[w2].y = lst[w2 - 1].y + page.stepY
                // snap back onto the grid and off the top edge
                for (var g2 = 0; g2 < lst.length; g2++)
                    lst[g2].y = Math.max(page.grid, page.snap(lst[g2].y))
            }
        }
        page.graphChanged()
        canvas.requestPaint()
        gridCanvas.requestPaint()
        page.savePos()
    }

    function savePos() {
        if (editMode) { save(); return }
        backend.savePipelineLayout(pipeName, JSON.stringify(
            { nodes: graph.nodes }))
    }
    function nodeById(id) {
        for (const n of graph.nodes) if (n.id === id) return n
        return null
    }
    function canConnect(a, b) {
        const na = nodeById(a), nb = nodeById(b)
        if (!na || !nb || a === b) return false
        if (kindOrder[nb.kind] <= kindOrder[na.kind]) return false
        for (const e of graph.edges) if (e[0] === a && e[1] === b) return false
        return true
    }
    function addEdge(a, b) {
        if (!canConnect(a, b)) return
        graph.edges.push([a, b])
        graphChanged(); canvas.requestPaint(); save()
    }
    function removeEdge(a, b) {
        graph.edges = graph.edges.filter(e => !(e[0] === a && e[1] === b))
        graphChanged(); canvas.requestPaint(); save()
    }
    function removeNode(id) {
        graph.nodes = graph.nodes.filter(n => n.id !== id)
        graph.edges = graph.edges.filter(e => e[0] !== id && e[1] !== id)
        selected = ""
        graphChanged(); canvas.requestPaint(); save()
    }
    function setZoom(z, cx, cy) {
        const nz = Math.max(0.3, Math.min(2.5, z))
        // keep the point under the cursor in place
        const rx = (flick.contentX + cx) / zoom
        const ry = (flick.contentY + cy) / zoom
        zoom = nz
        flick.contentX = Math.max(0, rx * nz - cx)
        flick.contentY = Math.max(0, ry * nz - cy)
    }

    property var selNode: nodeById(selected)
    property var selCfg: {
        const n = nodeById(selected)
        return n && n.ref
               ? backend.expertiseParsed(n.ref + ".yaml") : null
    }
    property var selEdges: {
        const out = []
        for (const e of graph.edges)
            if (e[0] === selected || e[1] === selected) out.push(e)
        return out
    }

    Connections {
        target: backend
        function onPipelineReady() { if (!dragActive.running) page.reloadGraph() }
    }
    Timer { id: dragActive; interval: 600 }

    actions: [
        Kirigami.Action {
            icon.name: "go-previous"; text: "Back"
            onTriggered: root.pageStack.layers.pop()
        },
        Kirigami.Action {
            icon.name: "document-edit"; text: "Edit mode"
            visible: !page.editMode
            onTriggered: page.editMode = true
        },
        Kirigami.Action {
            icon.name: "distribute-horizontal-x"; text: "Arrange"
            // AUTO LAYOUT: a column per type (input -> normalization ->
            // enrichment -> filter -> output), rows inside a column with an
            // offset. The nodes always stand straight, the lines do not cross.
            onTriggered: page.tidyLayout()
        },
        Kirigami.Action {
            icon.name: "list-add"; text: "Element…"
            visible: page.editMode
            onTriggered: addDialog.openIt()
        },
        Kirigami.Action {
            icon.name: "media-playback-start"; text: "Run"
            onTriggered: backend.runPipeline(page.pipeName)
        },
        Kirigami.Action {
            icon.name: "dialog-ok-apply"; text: "Apply config"
            visible: page.editMode
            onTriggered: {
                backend.applyPipeline(page.pipeName)
                page.editMode = false
                page.reloadGraph()
            }
        },
        Kirigami.Action {
            icon.name: "edit-undo"; text: "Discard"
            visible: page.editMode
            onTriggered: {
                backend.discardPipelineDraft(page.pipeName)
                page.editMode = false
                page.reloadGraph()
            }
        },
        Kirigami.Action {
            icon.name: "zoom-original"; text: Math.round(page.zoom * 100) + "%"
            onTriggered: { page.zoom = 1; }
        },
        Kirigami.Action {
            icon.name: "dialog-cancel"; text: "Cancel connect"
            visible: page.connectFrom !== ""
            onTriggered: page.connectFrom = ""
        }
    ]

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // -------- the graph space --------
        Flickable {
            id: flick
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: page.worldW * page.zoom
            contentHeight: page.worldH * page.zoom
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            QQC2.ScrollBar.horizontal: QQC2.ScrollBar { policy: QQC2.ScrollBar.AlwaysOn }
            QQC2.ScrollBar.vertical: QQC2.ScrollBar { policy: QQC2.ScrollBar.AlwaysOn }

            // one wheel handler: Ctrl -> zoom to the cursor,
            // without Ctrl -> scrolling (vertical; +Shift -> horizontal)
            WheelHandler {
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: event => {
                    if (event.modifiers & Qt.ControlModifier) {
                        page.setZoom(page.zoom * (event.angleDelta.y > 0 ? 1.12 : 1/1.12),
                                     event.x, event.y)
                    } else if (event.modifiers & Qt.ShiftModifier) {
                        flick.contentX = Math.max(0, Math.min(
                            flick.contentWidth - flick.width,
                            flick.contentX - event.angleDelta.y))
                    } else {
                        flick.contentY = Math.max(0, Math.min(
                            flick.contentHeight - flick.height,
                            flick.contentY - event.angleDelta.y))
                        flick.contentX = Math.max(0, Math.min(
                            flick.contentWidth - flick.width,
                            flick.contentX - event.angleDelta.x))
                    }
                }
            }

            Item {
                id: world
                width: page.worldW
                height: page.worldH
                scale: page.zoom
                transformOrigin: Item.TopLeft

                // FAINT GRID. Drawn under everything at very low contrast: it
                // shows where cards snap without turning into a pattern you
                // have to look past. Visible only while editing, because that
                // is the only time it means anything.
                Canvas {
                    id: gridCanvas
                    anchors.fill: parent
                    z: -2
                    // Always visible, just very faint: it explains where
                    // cards snap. Slightly stronger while editing, when the
                    // snapping actually matters.
                    opacity: page.editMode ? 1 : 0.55
                    Behavior on opacity { NumberAnimation { duration: 150 } }
                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()
                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.reset()
                        var g = page.grid
                        ctx.lineWidth = 1
                        for (var x = g; x < width; x += g) {
                            // every fourth line slightly stronger, so the eye
                            // can count cells without measuring
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
                    Component.onCompleted: requestPaint()
                }

                MouseArea {   // a click on empty space clears the selection
                    anchors.fill: parent
                    z: -1
                    onClicked: { page.selected = ""; page.connectFrom = "" }
                }

                Canvas {
                    id: canvas
                    anchors.fill: parent
                    antialiasing: true
                    smooth: true
                    renderStrategy: Canvas.Cooperative
                    onPaint: {
                        const ctx = getContext("2d")
                        ctx.clearRect(0, 0, width, height)
                        ctx.lineWidth = 2.4
                        ctx.lineCap = "round"
                        for (const e of page.graph.edges) {
                            const a = page.nodeById(e[0]), b = page.nodeById(e[1])
                            if (!a || !b) continue
                            const sel = (e[0] === page.selected || e[1] === page.selected)
                            ctx.strokeStyle = sel ? Kirigami.Theme.highlightColor
                                                  : Qt.alpha(Kirigami.Theme.textColor, 0.4)
                            ctx.fillStyle = ctx.strokeStyle
                            ctx.lineWidth = sel ? 3.2 : 2.2
                            // anchor points follow the card size,
                            // so edges stay glued when it changes
                            const x1 = a.x + page.cardW, y1 = a.y + page.cardH / 2
                            const x2 = b.x, y2 = b.y + page.cardH / 2
                            // ROUTE AROUND CARDS. A straight run between two
                            // distant columns passed straight over the blocks
                            // in between. We look for cards the segment would
                            // cross and bend the curve into the free channel
                            // above or below them.
                            const detour = page.channelFor(a, b)
                            // a smooth S bend: the control points are halfway, the
                            // line enters and leaves horizontally - it looks good
                            // whatever the mutual position of the nodes
                            const dx = Math.max(60, Math.abs(x2 - x1) * 0.5)
                            ctx.beginPath()
                            ctx.moveTo(x1, y1)
                            ctx.bezierCurveTo(x1 + dx, y1 + detour,
                                              x2 - dx, y2 + detour, x2, y2)
                            ctx.stroke()
                            ctx.beginPath()
                            ctx.moveTo(x2, y2)
                            ctx.lineTo(x2 - 9, y2 - 5)
                            ctx.lineTo(x2 - 9, y2 + 5)
                            ctx.fill()
                        }
                    }
                }

                Repeater {
                    model: page.graph.nodes
                    delegate: Rectangle {
                        id: card
                        x: modelData.x
                        y: modelData.y
                        width: page.cardW
                        height: page.cardH
                        radius: 6
                        color: page.connectFrom !== "" && page.canConnect(page.connectFrom, modelData.id)
                               ? Qt.alpha(Kirigami.Theme.positiveTextColor, 0.15)
                               : Kirigami.Theme.backgroundColor
                        border.width: page.selected === modelData.id
                                      || page.connectFrom === modelData.id ? 2 : 1
                        border.color: page.connectFrom === modelData.id
                                      ? Kirigami.Theme.positiveTextColor
                                      : page.connectFrom !== "" && page.canConnect(page.connectFrom, modelData.id)
                                        ? Kirigami.Theme.positiveTextColor
                                        : page.selected === modelData.id
                                          ? Kirigami.Theme.highlightColor
                                          : modelData.error ? Kirigami.Theme.negativeTextColor
                                          : Kirigami.Theme.disabledTextColor

                        // the edges follow the card in real time
                        // the position is written into the MODEL, otherwise the
                        // edges are drawn at the old coordinates and do not follow
                        onXChanged: page.setNodePos(modelData.id, x, y)
                        onYChanged: page.setNodePos(modelData.id, x, y)

                        MouseArea {
                            anchors.fill: parent
                            // Nodes can be moved ALWAYS, not only in edit mode:
                            // the layout is presentation, not the logic of the
                            // pipeline. The edges are recomputed on every step
                            // (onXChanged/onYChanged above), so the lines follow
                            // the card instead of tearing away.
                            drag.target: card
                            drag.threshold: 4
                            onPressed: {
                                dragActive.restart()
                                if (page.connectFrom !== "") {
                                    if (page.canConnect(page.connectFrom, modelData.id))
                                        page.addEdge(page.connectFrom, modelData.id)
                                    page.connectFrom = ""
                                }
                                page.selected = modelData.id
                            }
                            onPositionChanged: if (drag.active) dragActive.restart()
                            onReleased: {
                                if (!drag.active) return
                                // Snap to the grid, then guarantee a two-cell
                                // gap: a card dropped on top of another is
                                // pushed to the nearest free slot instead of
                                // being left overlapping.
                                var pos = page.placeFree(modelData.id,
                                                         page.snap(card.x),
                                                         page.snap(card.y))
                                card.x = pos.x; card.y = pos.y
                                page.setNodePos(modelData.id, pos.x, pos.y)
                                page.savePos()
                            }
                        }

                        // The actions are RIGHT ON THE NODE (they appear on hover):
                        // "last run" and "YAML" used to live only in the side panel,
                        // and people did not find them.
                        Row {
                            z: 5
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: 2
                            spacing: 0
                            visible: cardHover.hovered || page.selected === modelData.id
                            QQC2.ToolButton {
                                width: Kirigami.Units.iconSizes.small + 6
                                height: width
                                icon.name: "view-visible"
                                icon.width: Kirigami.Units.iconSizes.small
                                icon.height: Kirigami.Units.iconSizes.small
                                QQC2.ToolTip.text: "Last run: input and output"
                                QQC2.ToolTip.visible: hovered
                                onClicked: {
                                    page.selected = modelData.id
                                    peekDialog.openFor(modelData.id, modelData.kind)
                                }
                            }
                            QQC2.ToolButton {
                                width: Kirigami.Units.iconSizes.small + 6
                                height: width
                                visible: modelData.ref !== ""
                                icon.name: "document-edit"
                                icon.width: Kirigami.Units.iconSizes.small
                                icon.height: Kirigami.Units.iconSizes.small
                                QQC2.ToolTip.text: "Open the rule YAML"
                                QQC2.ToolTip.visible: hovered
                                onClicked: {
                                    page.selected = modelData.id
                                    yamlDialog.openFor(modelData.ref + ".yaml")
                                }
                            }
                        }
                        HoverHandler { id: cardHover }

                        // STATUS ACCENT. An error used to add a third line of
                        // red text inside a fixed-height card, which is what
                        // made these cards look cramped and uneven. Now the
                        // state is a left accent bar plus one status icon, and
                        // the message lives in the tooltip — every card keeps
                        // exactly the same shape.
                        Rectangle {
                            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                            width: 4
                            radius: 2
                            visible: modelData.error !== ""
                            color: Kirigami.Theme.negativeTextColor
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: Kirigami.Units.smallSpacing
                            anchors.leftMargin: Kirigami.Units.smallSpacing + 4
                            anchors.rightMargin: Kirigami.Units.gridUnit * 2.8
                            spacing: Kirigami.Units.smallSpacing
                            Kirigami.Icon {
                                source: modelData.icon
                                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                                Layout.alignment: Qt.AlignVCenter
                            }
                            ColumnLayout {
                                spacing: 1
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignVCenter
                                QQC2.Label {
                                    text: modelData.title
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.smallSpacing
                                    Kirigami.Icon {
                                        source: "dialog-error"
                                        visible: modelData.error !== ""
                                        color: Kirigami.Theme.negativeTextColor
                                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                    }
                                    QQC2.Label {
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        opacity: modelData.error !== "" ? 0.9 : 0.6
                                        color: modelData.error !== ""
                                               ? Kirigami.Theme.negativeTextColor
                                               : Kirigami.Theme.textColor
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                        text: {
                                            if (modelData.error !== "") return "failed"
                                            let s = page.kindNames[modelData.kind]
                                            if (modelData.kind === "input" && modelData.ran_at)
                                                s += " · " + modelData.ran_at +
                                                     (modelData.rows >= 0 ? " · " + modelData.rows + " rows" : "")
                                            return s
                                        }
                                    }
                                }
                            }
                        }
                        QQC2.ToolTip.text: modelData.error !== "" ? modelData.error : modelData.title
                        QQC2.ToolTip.visible: cardHover.hovered && modelData.error !== ""
                        QQC2.ToolTip.delay: 300
                    }
                }
            }
        }

        // -------- the preview panel --------
        SidePanel {
            id: previewPanel
            title: page.selCfg ? (page.selCfg.title || page.selCfg.name || "") : "(unbound)"
            iconName: "documentinfo"
            panelWidth: Kirigami.Units.gridUnit * 19
            open: page.selected !== ""
            onCloseRequested: page.selected = ""

            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                ColumnLayout {
                width: previewPanel.panelWidth - Kirigami.Units.largeSpacing * 2
                spacing: Kirigami.Units.smallSpacing

                QQC2.Label {
                    Layout.leftMargin: Kirigami.Units.smallSpacing
                    opacity: 0.6
                    text: page.selNode
                          ? page.kindNames[page.selNode.kind] +
                            (page.selNode.ref ? " · " + page.selNode.ref : "")
                          : ""
                }

                // compact action icons (they fit into a narrow panel)
                RowLayout {
                    Layout.margins: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing
                    QQC2.ToolButton {
                        icon.name: "view-visible"
                        QQC2.ToolTip.text: "Last Run"
                        QQC2.ToolTip.visible: hovered
                        onClicked: peekDialog.openFor(page.selected, page.selNode.kind)
                    }
                    QQC2.ToolButton {
                        visible: page.selNode && page.selNode.ref !== ""
                        icon.name: "document-edit"
                        QQC2.ToolTip.text: "Edit YAML"
                        QQC2.ToolTip.visible: hovered
                        onClicked: yamlDialog.openFor(page.selNode.ref + ".yaml")
                    }
                    Kirigami.Separator { Layout.fillHeight: true; visible: page.editMode }
                    QQC2.ToolButton {
                        icon.name: "link"
                        visible: page.editMode
                        QQC2.ToolTip.text: "Bind to an expertise object"
                        QQC2.ToolTip.visible: hovered
                        onClicked: bindDialog.openFor(page.selNode.kind)
                    }
                    QQC2.ToolButton {
                        icon.name: "network-connect"
                        visible: page.editMode && page.selNode && page.selNode.kind !== "output"
                        QQC2.ToolTip.text: "Connect →"
                        QQC2.ToolTip.visible: hovered
                        onClicked: page.connectFrom = page.selected
                    }
                    QQC2.ToolButton {
                        icon.name: "edit-delete"
                        visible: page.editMode
                        QQC2.ToolTip.text: "Delete node"
                        QQC2.ToolTip.visible: hovered
                        onClicked: page.removeNode(page.selected)
                    }
                    Item { Layout.fillWidth: true }
                }

                QQC2.Label {
                    visible: page.connectFrom !== ""
                    Layout.margins: Kirigami.Units.smallSpacing
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    color: Kirigami.Theme.positiveTextColor
                    text: "Click a highlighted target node"
                }

                Kirigami.ListSectionHeader {
                    Layout.fillWidth: true
                    visible: page.selEdges.length > 0
                    label: "Edges"
                }
                Repeater {
                    model: page.selEdges
                    delegate: RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: Kirigami.Units.smallSpacing
                        QQC2.Label {
                            Layout.fillWidth: true
                            elide: Text.ElideMiddle
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            text: {
                                const a = page.nodeById(modelData[0])
                                const b = page.nodeById(modelData[1])
                                return (a ? a.title : modelData[0]) + " → " +
                                       (b ? b.title : modelData[1])
                            }
                        }
                        QQC2.ToolButton {
                            icon.name: "edit-delete"
                            visible: page.editMode
                            QQC2.ToolTip.text: "Remove edge"
                            QQC2.ToolTip.visible: hovered
                            onClicked: page.removeEdge(modelData[0], modelData[1])
                        }
                    }
                }

                Kirigami.ListSectionHeader {
                    Layout.fillWidth: true
                    visible: page.selCfg !== null
                    label: "Parameters"
                }
                Kirigami.FormLayout {
                    Layout.fillWidth: true
                    Repeater {
                        model: page.selCfg
                               ? Object.keys(page.selCfg).filter(k => k !== "code")
                               : []
                        delegate: QQC2.Label {
                            Kirigami.FormData.label: modelData
                            Layout.fillWidth: true
                            wrapMode: Text.WrapAnywhere
                            text: {
                                const v = page.selCfg[modelData]
                                return typeof v === "object" ? JSON.stringify(v) : String(v)
                            }
                        }
                    }
                }

                Kirigami.ListSectionHeader {
                    Layout.fillWidth: true
                    visible: page.selCfg && page.selCfg.code !== undefined
                    label: "Python plugin — normalize(text)"
                }
                QQC2.TextArea {
                    visible: page.selCfg && page.selCfg.code !== undefined
                    Layout.fillWidth: true
                    Layout.margins: Kirigami.Units.smallSpacing
                    readOnly: true
                    font.family: "monospace"
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    wrapMode: TextEdit.NoWrap
                    text: page.selCfg && page.selCfg.code ? page.selCfg.code : ""
                    background: Rectangle {
                        color: Kirigami.Theme.alternateBackgroundColor
                        radius: 4
                    }
                }
                }
            }
        }
    }

    QQC2.Label {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.margins: Kirigami.Units.smallSpacing
        opacity: 0.6
        font.pointSize: Kirigami.Theme.smallFont.pointSize
        text: page.connectFrom !== ""
              ? "Connect mode: click a green node (Esc to cancel)"
              : page.editMode
                ? "EDIT MODE: changes go to a draft — press “Apply config” to install"
                : "View mode · Ctrl+wheel to zoom · press “Edit mode” to modify"
    }

    Keys.onEscapePressed: page.connectFrom = ""

    // -------- add an object --------
    Kirigami.Dialog {
        id: addDialog
        title: "New pipeline element"
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        padding: Kirigami.Units.largeSpacing
        preferredWidth: Kirigami.Units.gridUnit * 20

        property var kinds: ["input", "normalize", "filter", "correlation", "output"]
        property var kindTitles: ["Input", "Normalization", "Filter", "Correlation", "Output"]

        function openIt() { kindBox.currentIndex = 0; open() }

        onAccepted: {
            const kind = kinds[kindBox.currentIndex]
            let base = kind, id = base, i = 2
            while (page.nodeById(id)) id = base + "_" + i++
            page.graph.nodes.push({
                id: id, kind: kind, ref: "",
                x: (flick.contentX + 60) / page.zoom,
                y: (flick.contentY + 60) / page.zoom,
                title: "(unbound)", icon: "emblem-warning",
                rows: -1, error: "", ran_at: ""
            })
            page.graphChanged()
            page.save()
            page.selected = id
            bindDialog.openFor(kind)
        }

        Kirigami.FormLayout {
            QQC2.ComboBox {
                id: kindBox
                Kirigami.FormData.label: "Element type"
                model: addDialog.kindTitles
            }
            QQC2.Label {
                opacity: 0.7
                text: "After creating, bind the element\nto an expertise object"
            }
        }
    }

    // -------- binding: the expertise window filtered by type --------
    Kirigami.Dialog {
        id: bindDialog
        title: "Expertise — " + (page.selNode ? page.kindNames[page.selNode.kind] : "")
        padding: 0
        preferredWidth: Kirigami.Units.gridUnit * 32
        preferredHeight: Kirigami.Units.gridUnit * 22
        standardButtons: Kirigami.Dialog.Cancel

        property var catalog: []

        function openFor(kind) {
            catalog = backend.expertiseCatalog(page.kindCats[kind])
            bindSearch.text = ""
            open()
        }

        property var shown: {
            const f = bindSearch.text.toLowerCase()
            if (!f) return catalog
            return catalog.filter(e =>
                (e.id + " " + e.name + " " + e.title + " " + e.ref)
                    .toLowerCase().includes(f))
        }

        ColumnLayout {
            spacing: 0

            Kirigami.SearchField {
                id: bindSearch
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                placeholderText: "Search by ID, name, title…"
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.largeSpacing
                QQC2.Label { text: "ID"; font.bold: true; Layout.preferredWidth: 80 }
                QQC2.Label { text: "Title"; font.bold: true; Layout.fillWidth: true }
                QQC2.Label { text: "Type"; font.bold: true; Layout.preferredWidth: 140; elide: Text.ElideRight }
                QQC2.Label { text: "Version"; font.bold: true; Layout.preferredWidth: 60 }
            }
            Kirigami.Separator { Layout.fillWidth: true }

            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: Kirigami.Units.gridUnit * 16
                ListView {
                    model: bindDialog.shown
                    clip: true
                    delegate: QQC2.ItemDelegate {
                        width: ListView.view.width
                        onClicked: {
                            const n = page.nodeById(page.selected)
                            if (n) { n.ref = modelData.ref; page.save(); page.reloadGraph() }
                            bindDialog.close()
                        }
                        contentItem: RowLayout {
                            spacing: Kirigami.Units.largeSpacing
                            QQC2.Label {
                                text: modelData.id || "—"
                                font.family: "monospace"
                                Layout.preferredWidth: 80
                            }
                            ColumnLayout {
                                spacing: 0
                                Layout.fillWidth: true
                                QQC2.Label {
                                    text: modelData.title || modelData.name
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                QQC2.Label {
                                    text: modelData.ref
                                    opacity: 0.6
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                            }
                            QQC2.Label {
                                text: modelData.type || "—"
                                opacity: 0.8
                                Layout.preferredWidth: 140
                                elide: Text.ElideRight
                            }
                            QQC2.Label {
                                text: modelData.version || "—"
                                Layout.preferredWidth: 60
                            }
                        }
                    }
                    Kirigami.PlaceholderMessage {
                        anchors.centerIn: parent
                        visible: parent.count === 0
                        text: "No objects of this type"
                        explanation: "Create them in the Expertise tab"
                    }
                }
            }
        }
    }

    // -------- edit expertise YAML in place --------
    Kirigami.Dialog {
        id: yamlDialog
        title: "Edit — " + rel
        padding: Kirigami.Units.smallSpacing
        preferredWidth: Kirigami.Units.gridUnit * 34
        preferredHeight: Kirigami.Units.gridUnit * 24
        standardButtons: Kirigami.Dialog.Save | Kirigami.Dialog.Cancel

        property string rel: ""
        property string err: ""

        function openFor(r) {
            rel = r
            err = ""
            yamlEditor.text = backend.readExpertise(r)
            open()
        }
        onAccepted: {
            err = backend.saveExpertise(rel, yamlEditor.text)
            if (err !== "") open()
            else page.reloadGraph()
        }

        ColumnLayout {
            spacing: Kirigami.Units.smallSpacing
            QQC2.Label {
                visible: yamlDialog.err !== ""
                color: Kirigami.Theme.negativeTextColor
                text: yamlDialog.err
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                QQC2.TextArea {
                    id: yamlEditor
                    font.family: "monospace"
                    wrapMode: TextEdit.NoWrap
                    tabStopDistance: 20
                }
            }
        }
    }

    // -------- the last run of a node (the eye) --------
    Kirigami.Dialog {
        id: peekDialog
        title: "Last run — " + kindLabel
        padding: 0
        preferredWidth: Kirigami.Units.gridUnit * 40
        preferredHeight: Kirigami.Units.gridUnit * 28
        standardButtons: Kirigami.Dialog.Close

        property var data: ({})
        property string kindLabel: ""

        function openFor(nodeId, kind) {
            data = backend.nodePeek(page.pipeName, nodeId)
            kindLabel = page.kindNames[kind] || kind
            open()
        }

        ColumnLayout {
            spacing: 0

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                visible: !peekDialog.data.has
                type: Kirigami.MessageType.Information
                text: "This node has not run yet. Press Run and open it again."
            }
            Kirigami.InlineMessage {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                visible: !!(peekDialog.data.error && peekDialog.data.error !== "")
                type: Kirigami.MessageType.Error
                text: peekDialog.data.error || ""
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                // what CAME IN to the node
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 2
                    visible: !!(peekDialog.data.in_text || peekDialog.data.in_rows)
                    QQC2.Label {
                        text: "Input"
                        font.bold: true
                        Layout.margins: Kirigami.Units.smallSpacing
                    }
                    QQC2.ScrollView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        QQC2.TextArea {
                            readOnly: true
                            font.family: "monospace"
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            wrapMode: TextEdit.NoWrap
                            text: peekDialog.data.in_text || peekDialog.data.in_rows || ""
                        }
                    }
                }

                Kirigami.Separator {
                    Layout.fillHeight: true
                    visible: !!(peekDialog.data.in_text || peekDialog.data.in_rows)
                }

                // what WENT OUT of the node
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 2
                    QQC2.Label {
                        text: peekDialog.data.out_text ? "Output (input stdout)"
                                                       : "Output (table rows)"
                        font.bold: true
                        Layout.margins: Kirigami.Units.smallSpacing
                    }
                    QQC2.ScrollView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        QQC2.TextArea {
                            readOnly: true
                            font.family: "monospace"
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            wrapMode: TextEdit.NoWrap
                            text: peekDialog.data.out_text || peekDialog.data.out_rows || "(empty)"
                        }
                    }
                }
            }
        }
    }
}

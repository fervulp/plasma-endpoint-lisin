import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "Fmt.js" as Fmt

// ПОЛОТНО ГРАФА — переиспользуемый компонент расследования.
//
// Собрано по разобранным практикам зрелых EDR (SentinelOne Storyline,
// Defender, Elastic, Cortex, Chronicle) + графовой визуализации
// (Cambridge Intelligence combos, DEPCOMM):
//   * КАТЕГОРИИ-КЛАСТЕРЫ: связанное сгруппировано; крупная группа свёрнута в
//     мета-узел со счётчиком, раскрывается на месте (клик) — «starburst» не
//     заваливает канву;
//   * цвет ПОЛОСЫ = категория, цвет+иконка+форма = тип сущности, красная
//     рамка = риск (тип и риск ортогональны, как в Defender);
//   * наведение подсвечивает соседей и гасит остальное (focus+context);
//   * КНОПКИ-ДЕЙСТВИЯ на узле: провалиться в State/События, сделать центром
//     (пивот), WHOIS — «drill deeper» одним жестом;
//   * панель масштаба + «вписать всё».
//
// Раскладка (x/y) и решение «свернуть/раскрыть» приходят ГОТОВЫМИ из Python;
// QML только рисует и шлёт сигналы. id узлов стабильны → анимация бесплатна.
Item {
    id: canvasRoot

    property var graph: ({ nodes: [], edges: [], categories: [] })
    property string selectedId: ""
    property string hoveredId: ""
    property real zoom: 1.0
    // масштаб меняется плавно: резкий скачок сбивает ориентацию
    Behavior on zoom { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    property int worldW: graph && graph.width ? graph.width : 1100
    property int worldH: graph && graph.height ? graph.height : 780

    signal nodeActivated(var node)          // клик по узлу → боковая панель
    signal toggleCategory(string category)  // клик по мета-узлу → раскрыть
    signal anchorRequested(var node)        // «сделать центром» (пивот)
    signal drillRequested(string action, var node)  // провалиться

    // ЗА КАЖДЫМ ТИПОМ ЗАКРЕПЛЁН СВОЙ ЦВЕТ — он не меняется между графами,
    // поэтому «оранжевое = удалённый адрес» запоминается и читается без
    // легенды. Процессы намеренно СЕРЫЕ: их на полотне больше всего, и
    // цветом должно выделяться то, что вокруг них, а не они сами.
    function colorFor(kind) {
        return kind === "process"   ? "#6e7276"   // серый — их больше всего
             : kind === "user"      ? "#2980b9"   // синий
             : kind === "package"   ? "#27ae60"   // зелёный
             : kind === "service"   ? "#2471a3"   // тёмно-синий
             : kind === "remote"    ? "#e67e22"   // оранжевый
             : kind === "listen"    ? "#c0392b"   // красный
             : kind === "socket"    ? "#8e44ad"   // фиолетовый
             : kind === "config"    ? "#16a085"   // бирюзовый
             : kind === "file"      ? "#5d6d7e"   // сланцевый
             : kind === "dir"       ? "#34495e"   // тёмно-сланцевый
             : kind === "action"    ? "#b7950b"   // оливковый
             : kind === "vuln"      ? "#922b21"   // тёмно-красный
             : kind === "persist"   ? "#6c3483"   // тёмно-фиолетовый
             : kind === "suid"      ? "#d35400"   // тыквенный
             : kind === "privesc"   ? "#a04000"   // коричнево-оранжевый
             : kind === "scheduled" ? "#148f77"   // тёмно-бирюзовый
             : kind === "kmod"      ? "#7d3c98"   // лиловый
             : kind === "group"     ? "#4a5158"   // нейтральный, блок-заголовок
             : kind === "warning"   ? "#cb4335"   // ярко-красный
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
    // цвет категории — из данных (Python шлёт color на узле); запасной по имени
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

    // рёбра рисуются на Canvas; во время анимации узлов их надо перерисовывать
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
                        // цвет ребра по смыслу связи
                        var col = conn ? Qt.rgba(0.90, 0.49, 0.13, lit ? 0.75 : 0.2)
                                       : Qt.alpha(Kirigami.Theme.textColor, lit ? 0.5 : 0.1)
                        ctx.strokeStyle = col
                        ctx.fillStyle = col
                        // ЛИНИИ СПЛОШНЫЕ И ПЛАВНЫЕ. Пунктир у мета-рёбер убран
                        // (рябил и читался как «связь ненастоящая»); толщина
                        // по-прежнему отличает пучок от одиночной связи.
                        ctx.lineWidth = member ? Math.min(5, 1.6 + (e.count || 1) / 5)
                                               : (lit && hov !== "" ? 2.2 : 1.5)
                        ctx.setLineDash([])
                        // Кубическая кривая с управляющими точками ВДОЛЬ
                        // основного направления: линия выходит и входит по
                        // касательной, поэтому изгиб мягкий при любом взаимном
                        // положении узлов (лесенка идёт вниз, дерево — вбок).
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
                        // стрелка по касательной в конце (от 2-й управляющей
                        // точки к узлу) — не для мета-рёбер, там пучок свёрнут
                        if (!member) {
                            var ang = Math.atan2(b.y - c2y, b.x - c2x)
                            var hx = b.x - Math.cos(ang) * 17, hy = b.y - Math.sin(ang) * 17
                            ctx.beginPath()
                            ctx.moveTo(hx, hy)
                            ctx.lineTo(hx - Math.cos(ang - 0.4) * 7, hy - Math.sin(ang - 0.4) * 7)
                            ctx.lineTo(hx - Math.cos(ang + 0.4) * 7, hy - Math.sin(ang + 0.4) * 7)
                            ctx.closePath(); ctx.fill()
                        }
                        // середина кривой (t=0.5) — туда ставим подпись
                        var lx = 0.125 * a.x + 0.375 * c1x + 0.375 * c2x + 0.125 * b.x
                        var ly = 0.125 * a.y + 0.375 * c1y + 0.375 * c2y + 0.125 * b.y
                        // подпись: ×N на мета-ребре всегда; отношение — при наведении
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
                    // ОДНА ФОРМА У ВСЕХ УЗЛОВ: прямоугольник с прямыми углами.
                    // Овалы вперемешку с блоками читались как «разные
                    // сущности», хотя тип показан иконкой и цветом.
                    radius: 0
                    opacity: dim ? 0.4 : 1.0
                    Behavior on opacity { NumberAnimation { duration: 140 } }
                    Behavior on x { NumberAnimation { duration: 190; easing.type: Easing.OutCubic } }
                    Behavior on y { NumberAnimation { duration: 190; easing.type: Easing.OutCubic } }
                    // ширина ограничена: длинная подпись раньше растягивала
                    // узел, он налезал на соседние и на рёбра
                    // ширина НЕ БОЛЬШЕ шага раскладки (200 px в Python),
                    // иначе соседние узлы налезают друг на друга
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
                            // у блока — иконка его содержимого (процессы,
                            // события, файлы), иначе безымянные блоки не
                            // отличить друг от друга
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
                                // ВРЕМЯ — в местной зоне: события хранятся в
                                // UTC, перевод делает граница UI (Fmt.js)
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
                        // счётчик у мета-узла категории
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

                    // бейдж риска/статуса в углу (OPEN, УДАЛЁН, +N…)
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
                    // двойной клик по сущности-якорю = пивот (сделать центром)
                    TapHandler {
                        acceptedButtons: Qt.LeftButton
                        onDoubleTapped: {
                            if (!chip.isGroup && modelData.drill === "reanchor")
                                canvasRoot.anchorRequested(modelData)
                        }
                    }

                    // ---- КНОПКИ-ДЕЙСТВИЯ (drill), появляются на выбранном/наведённом ----
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

        // ЩИПОК НА ТАЧПАДЕ: два пальца по диагонали — приближение к точке
        // между ними. Работает вместе с Ctrl+колесо (у мыши щипка нет).
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

    // ---- панель масштаба ----
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

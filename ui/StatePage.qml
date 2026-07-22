import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "Fmt.js" as Fmt

// System state: read-only tables view. Table/field/record management
// lives in the SQL tab. Right sidebars (details, columns) are full height.
Kirigami.Page {
    id: page
    title: "State"
    padding: 0

    property var s: root.sysState
    // Уязвимости живут в отдельной вкладке раздела «Дашборды»: это не
    // инвентарь системы, а список задач «что пропатчить».
    property var tabsModel: {
        var t = s ? s.tabs : []
        return t.filter(function (x) { return x.name !== "vulnerabilities" })
    }
    property int tabIndex: 0
    // отбор списка таблиц по названию
    property string tabFilter: ""
    readonly property var shownTabs: {
        if (tabFilter === "") return tabsModel
        var q = tabFilter.toLowerCase()
        return tabsModel.filter(t => String(t.name).toLowerCase().indexOf(q) >= 0
                                  || String(t.title).toLowerCase().indexOf(q) >= 0)
    }
    // выбрать таблицу по имени (список может быть отфильтрован — индексы врут)
    function openTable(name) {
        for (var i = 0; i < tabsModel.length; i++)
            if (tabsModel[i].name === name) { tabIndex = i; return }
    }

    property var cur: tabIndex >= 0 && tabIndex < tabsModel.length
                      ? tabsModel[tabIndex] : null

    property var listCols: cur ? cur.columns : []
    property var colOrder: {
        if (!cur) return listCols
        const cfg = cur.colcfg
        const base = cfg && cfg.order ? cfg.order.filter(c => listCols.includes(c)) : []
        for (const c of listCols) if (!base.includes(c)) base.push(c)
        return base
    }
    readonly property var longCols: ["content", "description", "code"]
    // "key" НЕ маскируем: приватный материал в БД не хранится (у приватных
    // ключей значение пустое), а публичные ключи по определению открыты —
    // показываем их контент прямо. Маскируем только настоящие секреты.
    readonly property var sensitiveCols: ["secret", "private", "token", "password"]
    property var hiddenCols: cur && cur.colcfg && cur.colcfg.hidden
                             ? cur.colcfg.hidden
                             : listCols.filter(c => longCols.includes(c)
                                                    || sensitiveCols.includes(c))
    property var visibleCols: colOrder.filter(c => !hiddenCols.includes(c))

    property var savedWidths: cur && cur.colcfg && cur.colcfg.widths
                              ? cur.colcfg.widths : ({})
    property var liveWidths: ({})
    // Сброс вида (выделение/сортировка/фильтры/страница) ТОЛЬКО при смене
    // вкладки (curName), не при каждом авто-обновлении данных — иначе
    // пользователь теряет выделенную строку и позицию при каждом тике.
    property string curName: cur ? cur.name : ""
    onCurNameChanged: {
        // У ДРУГОЙ ТАБЛИЦЫ ДРУГИЕ ПОЛЯ: и выборка, и условие от прежней
        // таблицы здесь бессмысленны — сбрасываем вместе с видом.
        page.queryText = ""; page.queryRows = []; page.queryError = ""
        if (typeof qbar !== "undefined") qbar.clearAll()
        liveWidths = ({}); selRows = []; selAnchor = -1; pageIndex = 0
        sortCol = ""; sortAsc = true; colFilters = ({}); lastSel = null; selName = ""
    }
    // Та же вкладка, свежие данные: переустанавливаем выделение и строку
    // деталей на НОВЫЕ объекты строк по _id (чтобы показывали актуальное).
    onCurChanged: {
        if (!cur || cur.name !== selName) return
        const byId = ({})
        for (const r of cur.rows) byId[r._id] = r
        selRows = selRows.map(r => byId[r._id]).filter(r => r !== undefined)
        lastSel = lastSel ? (byId[lastSel._id] || null) : null
        if (!lastSel && detailsPanel.open) detailsPanel.open = false
    }
    // «Исследовать» из события: открыть нужную вкладку и отфильтровать её.
    // Порядок важен: сперва вкладка (её смена сбрасывает colFilters), потом фильтр.
    function applyFocus() {
        var f = root ? root.stateFocus : null
        if (!f) return
        for (var i = 0; i < tabsModel.length; i++) {
            if (tabsModel[i].name === f.table) { tabIndex = i; break }
        }
        filtersOn = true
        setColFilter(f.col, f.val)
    }
    Component.onCompleted: applyFocus()
    Connections {
        target: root
        function onStateFocusChanged() { page.applyFocus() }
    }

    function colWidth(c) { return liveWidths[c] || savedWidths[c] || 160 }
    property int tableWidth: {
        let w = Math.round(Kirigami.Units.gridUnit * 2)   // колонка чекбоксов
        for (const c of visibleCols) w += colWidth(c)
        return w
    }
    function setColWidth(c, w) {
        const o = Object.assign({}, liveWidths)
        o[c] = Math.max(60, w)
        liveWidths = o
    }
    function persistWidths() {
        if (!cur) return
        saveColCfg(colOrder, hiddenCols, Object.assign({}, savedWidths, liveWidths))
    }
    function saveColCfg(order, hidden, widths) {
        if (!cur) return
        backend.setTabColumns(cur.name, JSON.stringify(
            { order: order, hidden: hidden,
              widths: widths || Object.assign({}, savedWidths, liveWidths) }))
    }
    function moveCol(name, dir) {
        const o = colOrder.slice()
        const i = o.indexOf(name), j = i + dir
        if (i < 0 || j < 0 || j >= o.length) return
        o[i] = o[j]; o[j] = name
        saveColCfg(o, hiddenCols)
    }
    function toggleCol(name) {
        let h = hiddenCols.slice()
        if (h.includes(name)) h = h.filter(x => x !== name)
        else h.push(name)
        saveColCfg(colOrder, h)
    }

    // идёт ли сбор по требованию
    property bool collecting: false
    Connections {
        target: backend
        function onCollectingChanged() { page.collecting = backend.isCollecting() }
    }

    // ---- поиск по всем таблицам состояния ----
    property bool searchAll: false
    property var globalHits: ({ tables: [], total: 0 })
    // для проверки рендером
    function setSearchText(t) { search.text = t }
    function setQuick(t) { qbar.quickText = t; qbar.apply() }
    // для проверки рендером
    function setGroupBy(fs) {
        qbar.addClause("group"); qbar.spec.groupBy = fs; qbar.touch(); qbar.apply()
    }
    function pickGroup(row) {
        page.groupPicked = true
        page.groupVal = String(row.value || "")
        page.groupParts = row.parts || []
        page.applyQuery(page.queryText)
    }

    function runGlobalSearch() {
        globalHits = backend.stateSearch(search.text)
    }
    // клик по найденной таблице: открыть её и оставить тот же текст фильтром
    function openHit(hit) {
        for (var i = 0; i < tabsModel.length; i++)
            if (tabsModel[i].name === hit.table) { tabIndex = i; break }
        page.searchAll = false
        page.pageIndex = 0
    }

    // sort + filters + pagination
    property string sortCol: ""
    property bool sortAsc: true
    property var colFilters: ({})
    property bool filtersOn: false
    // уникальные значения колонки; если их мало — фильтр показываем комбобоксом
    function uniqueVals(col) {
        if (!cur) return []
        const set = {}
        for (const r of cur.rows) {
            const v = String(r[col] ?? "")
            if (v !== "") set[v] = 1
        }
        const arr = Object.keys(set)
        return arr.length <= 15 ? arr.sort() : null   // null → обычное текст-поле
    }
    function setColFilter(c, v) {
        const o = Object.assign({}, colFilters)
        o[c] = v
        colFilters = o
        pageIndex = 0
    }
    function toggleSort(c) {
        if (sortCol === c) {
            if (sortAsc) sortAsc = false
            else { sortCol = ""; sortAsc = true }   // третий клик — сброс
        } else { sortCol = c; sortAsc = true }
    }
    // ---- ЕДИНЫЙ ПОИСК, КАК В СОБЫТИЯХ ----
    // Условие исполняет БАЗА (stateRows), а не разбор строки в интерфейсе:
    // так работают MATCH, OR и NOT, и механизм один на все разделы.
    property string queryText: ""
    property var queryRows: []
    property string queryError: ""
    // ВЫБОРКА ЗАДАЁТ КОЛОНКИ на текущий взгляд; постоянная настройка —
    // панель «Columns», она и сохраняет (иначе один запрос перекроил бы вид)
    function applySelectCols(sel) {
        if (!sel || !sel.length || !cur) return
        var all = cur.columns.filter(c => !c.startsWith("_"))
        var keep = sel.filter(c => all.indexOf(c) >= 0)
        if (!keep.length) return
        var rest = all.filter(c => keep.indexOf(c) < 0)
        colOrder = keep.concat(rest)
        hiddenCols = rest
    }

    // ЦВЕТ РИСКА В СТРОКЕ: критичность видна сразу, без чтения колонок.
    // Колонки риска у разных таблиц называются по-разному, поэтому смотрим
    // те, что есть: severity/cvss_rating (уязвимости), risk (privesc),
    // exposure (сокеты), status (kernel_params).
    function accentOf(r) { return String(page.rowAccent(r)) }
    function rowAccent(r) {
        if (!r) return ""
        var sev = String(r.severity || r.cvss_rating || "").toLowerCase()
        if (sev.indexOf("critical") >= 0) return Kirigami.Theme.negativeTextColor
        if (sev.indexOf("important") >= 0 || sev.indexOf("high") >= 0)
            return Kirigami.Theme.neutralTextColor
        var risk = String(r.risk || "").toLowerCase()
        if (risk === "high") return Kirigami.Theme.negativeTextColor
        if (risk === "medium") return Kirigami.Theme.neutralTextColor
        var exp = String(r.exposure || "")
        if (exp.indexOf("OPEN") >= 0) return Kirigami.Theme.negativeTextColor
        if (exp.indexOf("filtered") >= 0) return Kirigami.Theme.neutralTextColor
        var st = String(r.status || "").toLowerCase()
        if (st === "open" || st === "differs") return Kirigami.Theme.neutralTextColor
        if (String(r.deleted || "") === "yes") return Kirigami.Theme.negativeTextColor
        return ""
    }

    // ---- ГРУППИРОВКА (как в «Событиях») ----
    property var groupBy: []
    property var groupParts: []
    property string groupVal: ""
    property bool groupPicked: false
    property var groupRows: []
    function reloadGroups() {
        if (!cur || !groupBy.length) { groupRows = []; return }
        var r = backend.stateGroups(cur.name, groupBy.join(","), page.baseWhere())
        groupRows = r.rows || []
    }
    // условие без группы — по нему считаются сами группы
    function baseWhere() {
        if (queryText === "") return ""
        return hasOperator(queryText) ? queryText : freeText(queryText)
    }
    // условие выбранной группы: И по всем её полям
    function groupCond() {
        if (!groupBy.length || !groupPicked) return ""
        var parts = []
        for (var i = 0; i < groupBy.length; i++) {
            var f = groupBy[i]
            var v = i < groupParts.length ? String(groupParts[i]) : ""
            if (v === "")
                parts.push('("' + f + '" IS NULL OR "' + f + '" = \'\')')
            else
                parts.push('"' + f + '" = \'' + v.replace(/'/g, "''") + '\'')
        }
        return parts.length > 1 ? "(" + parts.join(" AND ") + ")" : parts[0]
    }

    // есть ли в строке оператор — тогда это условие, иначе свободный поиск
    function hasOperator(q) {
        return /(=|<>|<|>|LIKE|IS NULL|IS NOT NULL)/i.test(q)
    }
    // СВОБОДНЫЙ ТЕКСТ ИЩЕТСЯ ТОЛЬКО ПО КОЛОНКАМ ЭТОЙ ТАБЛИЦЫ: у каждой
    // таблицы состояния свой набор полей, общего списка не существует.
    function freeText(q) {
        if (!cur) return ""
        var cols = cur.columns.filter(c => !c.startsWith("_"))
        var e = String(q).replace(/'/g, "''")
        var parts = []
        for (var i = 0; i < cols.length; i++)
            parts.push('CAST("' + cols[i] + "\" AS TEXT) LIKE '%" + e + "%'")
        return parts.length ? "(" + parts.join(" OR ") + ")" : ""
    }
    function applyQuery(sql) {
        queryText = (sql || "").trim()
        pageIndex = 0
        reloadGroups()
        if (queryText === "" && !groupPicked) { queryRows = []; queryError = ""; return }
        if (!cur) { queryRows = []; queryError = ""; return }
        var where = hasOperator(queryText) ? queryText : freeText(queryText)
        var g = groupCond()
        if (g) where = where ? "(" + where + ") AND " + g : g
        var r = backend.stateRows(cur.name, where)
        queryRows = r.rows || []
        queryError = r.error || ""
    }
    property var filteredRows: {
        if (!cur) return []
        // если задано условие — работаем с тем, что вернула база
        // строки из базы — когда есть условие ИЛИ выбрана группа
        let rows = ((queryText !== "" || groupPicked) && queryError === "")
                   ? queryRows : cur.rows
        // текстовый отбор делает база (applyQuery), здесь остались только
        // пофакторные фильтры колонок и сортировка
        for (const c in colFilters) {
            const v = String(colFilters[c] || "")
            if (!v) continue
            const uniq = uniqueVals(c)
            if (uniq !== null && uniq.includes(v))     // combo → точное совпадение
                rows = rows.filter(r => String(r[c] ?? "") === v)
            else                                        // text → подстрока
                rows = rows.filter(r => String(r[c] ?? "").toLowerCase()
                                          .includes(v.toLowerCase()))
        }
        if (sortCol !== "") {
            const col = sortCol, asc = sortAsc ? 1 : -1
            rows = rows.slice().sort((a, b) => {
                const x = a[col] ?? "", y = b[col] ?? ""
                const nx = parseFloat(x), ny = parseFloat(y)
                if (isFinite(nx) && isFinite(ny) &&
                    String(nx).length >= String(x).trim().length - 2 &&
                    String(ny).length >= String(y).trim().length - 2)
                    return (nx - ny) * asc
                return String(x).localeCompare(String(y)) * asc
            })
        }
        return rows
    }
    property int pageLimit: 50
    property int pageIndex: 0
    property int pageCount: Math.max(1, Math.ceil(filteredRows.length / pageLimit))
    property var pagedRows: filteredRows.slice(pageIndex * pageLimit,
                                               (pageIndex + 1) * pageLimit)

    property var selRows: []           // выделенные строки (_id-объекты)
    property var lastSel: null         // последняя кликнутая — для сайдбара деталей
    property int selAnchor: -1         // индекс для shift-диапазона
    property string selName: ""        // вкладка, которой принадлежит выделение
    function isSel(r) {
        return r._id !== undefined && selRows.some(x => x._id === r._id)
    }
    function clickRow(r, index, mods) {
        selName = cur ? cur.name : ""    // выделение принадлежит этой вкладке
        if (mods & Qt.ShiftModifier && selAnchor >= 0) {
            const a = Math.min(selAnchor, index), b = Math.max(selAnchor, index)
            selRows = pagedRows.slice(a, b + 1)
        } else if (mods & Qt.ControlModifier) {
            selRows = isSel(r) ? selRows.filter(x => x._id !== r._id)
                               : selRows.concat([r])
            selAnchor = index
        } else {
            selRows = isSel(r) && selRows.length === 1 ? [] : [r]
            selAnchor = index
        }
        if (selRows.length === 1) {          // одна строка — показываем детали
            lastSel = selRows[0]
            detailsPanel.open = true
        } else {                              // ни одной или несколько — нет
            lastSel = null
            detailsPanel.open = false
        }
    }


    // -------- bottom toolbar --------
    footer: QQC2.ToolBar {
        RowLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing
            QQC2.ToolButton {
                icon.name: "view-refresh"
                text: "Refresh"
                display: QQC2.AbstractButton.IconOnly
                QQC2.ToolTip.text: "Re-read the collected data"
                QQC2.ToolTip.visible: hovered
                onClicked: backend.refresh()
            }
            // СОБРАТЬ СЕЙЧАС: у источников свои интервалы (у уязвимостей —
            // 6 часов), и после правки системы ждать расписание незачем.
            QQC2.ToolButton {
                icon.name: "download"
                text: page.collecting ? "Collecting…" : "Collect now"
                display: QQC2.AbstractButton.TextBesideIcon
                enabled: !page.collecting
                QQC2.ToolTip.text: "Run every state source right now"
                QQC2.ToolTip.visible: hovered
                onClicked: { page.collecting = true; backend.collectNow() }
            }
            QQC2.BusyIndicator {
                running: page.collecting
                visible: page.collecting
                Layout.preferredHeight: Kirigami.Units.gridUnit * 1.4
                Layout.preferredWidth: Kirigami.Units.gridUnit * 1.4
            }
            // когда эту таблицу наполняли в последний раз
            QQC2.Label {
                visible: page.cur && page.cur.collected_at
                text: "collected " + Fmt.local(page.cur ? page.cur.collected_at : "")
                opacity: 0.6
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
            QQC2.Label {
                Layout.leftMargin: Kirigami.Units.smallSpacing
                opacity: 0.6
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                text: page.s ? "Updated: " + page.s.collected_at : "Collecting…"
            }
            Item { Layout.fillWidth: true }
            QQC2.Label {
                opacity: 0.7
                text: page.filteredRows.length === 0 ? "0 rows"
                      : (page.pageIndex * page.pageLimit + 1) + "–" +
                        Math.min((page.pageIndex + 1) * page.pageLimit,
                                 page.filteredRows.length) +
                        " of " + page.filteredRows.length
            }
            QQC2.ToolButton {
                icon.name: "go-previous"
                enabled: page.pageIndex > 0
                onClicked: page.pageIndex--
            }
            QQC2.ToolButton {
                icon.name: "go-next"
                enabled: page.pageIndex < page.pageCount - 1
                onClicked: page.pageIndex++
            }
            QQC2.ComboBox {
                // сколько строк показывать; «all» = без ограничения
                model: [{ t: "50", v: 50 }, { t: "100", v: 100 }, { t: "200", v: 200 },
                        { t: "500", v: 500 }, { t: "1000", v: 1000 },
                        { t: "all", v: 0 }]
                textRole: "t"
                valueRole: "v"
                implicitWidth: Kirigami.Units.gridUnit * 6
                onActivated: { page.pageLimit = currentValue > 0 ? currentValue : 100000; page.pageIndex = 0 }
            }
            // ВЫБОР КОЛОНОК УБРАН: колонки задаёт SELECT в строке запроса
        }
    }

    // -------- page body: main column + full-height right sidebars --------
    RowLayout {
        anchors.fill: parent
        spacing: 0

        // -------- вертикальные вкладки состояния (ресайз за правый край) --------
        Item {
            id: tabsPanel
            property real panelW: Kirigami.Units.gridUnit * 12
            Layout.preferredWidth: panelW
            Layout.fillHeight: true

            ColumnLayout {
                anchors.fill: parent
                spacing: 0
                // ПОИСК ПО НАЗВАНИЯМ ТАБЛИЦ: набрал «release» — остались
                // только те, где это встречается. Таблиц почти полсотни.
                Kirigami.SearchField {
                    id: tabSearch
                    Layout.fillWidth: true
                    Layout.margins: Kirigami.Units.smallSpacing
                    placeholderText: "find a table…"
                    onTextChanged: page.tabFilter = text
                }
                QQC2.Label {
                    visible: page.tabFilter !== ""
                    Layout.leftMargin: Kirigami.Units.smallSpacing
                    text: page.shownTabs.length + " of " + page.tabsModel.length
                    opacity: 0.6
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                ListView {
                    model: page.shownTabs
                    clip: true
                    delegate: QQC2.ItemDelegate {
                        required property var modelData
                        width: ListView.view.width
                        highlighted: page.cur && page.cur.name === modelData.name
                        onClicked: page.openTable(modelData.name)
                        contentItem: RowLayout {
                            spacing: Kirigami.Units.smallSpacing
                            Kirigami.Icon {
                                source: modelData.icon
                                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                            }
                            QQC2.Label {
                                text: modelData.title
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                            QQC2.Label {   // счётчик всегда виден справа
                                text: modelData.rows.length
                                opacity: 0.55
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                        }
                    }
                }
            }
            }

            MouseArea {   // ручка ресайза панели вкладок
                width: 8
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                cursorShape: Qt.SplitHCursor
                preventStealing: true
                property real sx
                property real sw
                onPressed: m => { sx = m.x; sw = tabsPanel.panelW }
                onPositionChanged: m => {
                    if (pressed)
                        tabsPanel.panelW = Math.max(Kirigami.Units.gridUnit * 7,
                            Math.min(Kirigami.Units.gridUnit * 25, sw + (m.x - sx)))
                }
            }
        }

        Kirigami.Separator { Layout.fillHeight: true }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // ЕДИНАЯ СТРОКА ЗАПРОСА — тот же компонент, что в «Событиях»
            QueryBar {
                id: qbar
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                fields: page.cur
                    ? page.cur.columns.filter(c => !c.startsWith("_"))
                                      .map(function (c) { return { name: c } })
                    : []
                defaultSelect: page.visibleCols
                placeholder: "type SQL, or plain text to search this table"
                onApplied: function (spec, sql) {
                    page.applySelectCols(spec.select)
                    var g = spec.groupBy.slice()
                    if (g.join(",") !== page.groupBy.join(",")) {
                        page.groupBy = g
                        page.groupVal = ""; page.groupParts = []
                        page.groupPicked = false
                    }
                    page.applyQuery(sql)
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing
                // ПОЛЕ «filter this table» УБРАНО: по этой таблице ищет строка
                // запроса выше. Здесь осталось только то, чего она не умеет —
                // поиск СРАЗУ ПО ВСЕМ таблицам состояния.
                Kirigami.SearchField {
                    id: search
                    visible: page.searchAll
                    Layout.fillWidth: true
                    placeholderText: "search across all state tables…"
                    onTextChanged: {
                        page.pageIndex = 0
                        if (page.searchAll) page.runGlobalSearch()
                    }
                }
                Item { Layout.fillWidth: true; visible: !page.searchAll }
                // ПОИСК ПО ВСЕМУ СОСТОЯНИЮ: аналитик ищет адрес или имя, не
                // зная, в какой таблице оно лежит. Переключатель меняет
                // область поиска: эта таблица или все сразу.
                QQC2.ToolButton {
                    icon.name: "edit-find"
                    display: QQC2.AbstractButton.IconOnly
                    checkable: true
                    checked: page.searchAll
                    QQC2.ToolTip.text: "Search across every state table"
                    QQC2.ToolTip.visible: hovered
                    onClicked: {
                        page.searchAll = checked
                        if (checked) page.runGlobalSearch()
                    }
                }
            }

            // ---- результаты поиска по всем таблицам ----
            QQC2.ScrollView {
                visible: page.searchAll && search.text.length > 1
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(page.height * 0.5,
                                                 Kirigami.Units.gridUnit * 18)
                clip: true
                ListView {
                    model: page.globalHits.tables || []
                    reuseItems: true
                    delegate: QQC2.ItemDelegate {
                        required property var modelData
                        required property int index
                        width: ListView.view.width
                        height: Kirigami.Units.gridUnit * 3
                        onClicked: page.openHit(modelData)
                        background: Rectangle {
                            color: index % 2 ? Qt.alpha(Kirigami.Theme.textColor, 0.03)
                                             : "transparent"
                        }
                        contentItem: RowLayout {
                            spacing: Kirigami.Units.smallSpacing
                            Kirigami.Icon {
                                source: modelData.icon || "view-list-details"
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                QQC2.Label {
                                    text: modelData.title
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                QQC2.Label {
                                    text: (modelData.columns || []).join(", ")
                                    opacity: 0.6
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                    font.family: "monospace"
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                }
                            }
                            QQC2.Label {
                                text: modelData.n
                                opacity: 0.75
                                horizontalAlignment: Text.AlignRight
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 3
                            }
                        }
                    }
                }
            }

            // selection helpers
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing
                visible: page.filteredRows.length > 0
                QQC2.ToolButton {
                    text: "Select page"
                    icon.name: "edit-select-all"
                    onClicked: page.selRows = page.pagedRows.slice()
                }
                QQC2.ToolButton {
                    text: "Select all (" + page.filteredRows.length + ")"
                    icon.name: "edit-select-all-layers"
                    onClicked: page.selRows = page.filteredRows.slice()
                }
                QQC2.ToolButton {
                    text: "Clear"
                    icon.name: "edit-clear"
                    visible: page.selRows.length > 0
                    onClicked: page.selRows = []
                }
                Item { Layout.fillWidth: true }
            }

            // selected row actions
            RowLayout {
                visible: page.selRows.length > 0
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing
                QQC2.Label {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    opacity: 0.7
                    text: page.selRows.length === 1
                          ? "Selected: " + page.visibleCols.slice(0, 3)
                                .map(c => page.selRows[0][c]).filter(v => v).join(" · ")
                          : "Selected: " + page.selRows.length + " rows " +
                            "(Ctrl/Shift+click to extend)"
                }
                QQC2.Button {
                    text: "Explore"
                    icon.name: "view-list-tree"
                    visible: page.cur && page.cur.name === "processes" &&
                             page.selRows.length === 1
                    onClicked: root.pageStack.layers.push(
                        Qt.resolvedUrl("ProcessPage.qml"),
                        { pid: String(page.selRows[0].pid) })
                }
                QQC2.Button {
                    text: "Edit"
                    icon.name: "document-edit"
                    visible: page.selRows.length === 1
                    onClicked: editDialog.openFor(page.selRows[0])
                }
            }

            // ---- группы слева + таблица справа (как в «Событиях») ----
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

            // ---- ПАНЕЛЬ ГРУПП ----
            Item {
                visible: page.groupBy.length > 0
                Layout.preferredWidth: Math.min(page.width * 0.45,
                                                Kirigami.Units.gridUnit * (8 + 9 * page.groupBy.length))
                Layout.fillHeight: true
                ColumnLayout {
                    anchors.fill: parent
                    spacing: 0
                    // шапка — как у таблицы
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: gProbe.implicitHeight
                                                + Kirigami.Units.smallSpacing * 2
                        color: Kirigami.Theme.alternateBackgroundColor
                        QQC2.Label { id: gProbe; visible: false; text: "Ag"; font.bold: true }
                        Row {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            Item { width: Kirigami.Units.smallSpacing; height: 1 }
                            Repeater {
                                model: page.groupBy
                                delegate: QQC2.Label {
                                    required property var modelData
                                    width: Kirigami.Units.gridUnit * 8
                                    height: parent.height
                                    verticalAlignment: Text.AlignVCenter
                                    leftPadding: Kirigami.Units.smallSpacing
                                    text: modelData
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                            }
                        }
                        QQC2.Label {
                            anchors.right: parent.right
                            anchors.rightMargin: Kirigami.Units.largeSpacing
                            anchors.verticalCenter: parent.verticalCenter
                            text: "count"
                            font.bold: true
                        }
                        Kirigami.Separator {
                            anchors.bottom: parent.bottom
                            width: parent.width
                            opacity: 0.35
                        }
                    }
                    QQC2.ScrollView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        ListView {
                            model: page.groupRows
                            reuseItems: true
                            delegate: QQC2.ItemDelegate {
                                id: gRow
                                required property var modelData
                                required property int index
                                width: ListView.view.width
                                height: Kirigami.Units.gridUnit * 2.3
                                padding: 0
                                highlighted: page.groupPicked
                                             && page.groupVal === String(modelData.value || "")
                                onClicked: {
                                    var v = String(modelData.value || "")
                                    if (page.groupPicked && page.groupVal === v) {
                                        page.groupPicked = false
                                        page.groupVal = ""; page.groupParts = []
                                    } else {
                                        page.groupPicked = true
                                        page.groupVal = v
                                        page.groupParts = modelData.parts || [v]
                                    }
                                    page.applyQuery(page.queryText)
                                }
                                // ТЕ ЖЕ ЦВЕТА, ЧТО У ТАБЛИЦЫ: иначе две
                                // таблицы рядом выглядят из разных программ
                                background: Rectangle {
                                    color: gRow.highlighted
                                           ? Qt.alpha(Kirigami.Theme.highlightColor, 0.20)
                                           : (gRow.index % 2 === 0
                                              ? Kirigami.Theme.backgroundColor
                                              : Kirigami.Theme.alternateBackgroundColor)
                                    Kirigami.Separator {
                                        anchors.bottom: parent.bottom
                                        width: parent.width
                                        opacity: 0.35
                                    }
                                    Rectangle {
                                        anchors { left: parent.left; top: parent.top
                                                  bottom: parent.bottom }
                                        width: 3
                                        visible: gRow.highlighted
                                        color: Kirigami.Theme.highlightColor
                                    }
                                }
                                contentItem: RowLayout {
                                    spacing: 0
                                    Repeater {
                                        model: modelData.parts
                                               ? modelData.parts : [String(modelData.value)]
                                        delegate: QQC2.Label {
                                            required property var modelData
                                            Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                                            leftPadding: Kirigami.Units.smallSpacing
                                            rightPadding: Kirigami.Units.largeSpacing
                                            text: String(modelData) === "" ? "(empty)"
                                                                          : String(modelData)
                                            opacity: String(modelData) === "" ? 0.5 : 1
                                            elide: Text.ElideRight
                                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        }
                                    }
                                    Item { Layout.fillWidth: true }
                                    QQC2.Label {
                                        text: modelData.n
                                        opacity: 0.75
                                        horizontalAlignment: Text.AlignRight
                                        rightPadding: Kirigami.Units.largeSpacing
                                        Layout.preferredWidth: Kirigami.Units.gridUnit * 5
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Kirigami.Separator {
                visible: page.groupBy.length > 0
                Layout.fillHeight: true
            }

            // table
            Flickable {
                id: hflick
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: Math.max(width, page.tableWidth)
                flickableDirection: Flickable.HorizontalFlick
                clip: true
                QQC2.ScrollBar.horizontal: QQC2.ScrollBar {}

                ListView {
                    id: tableView
                    width: hflick.contentWidth
                    height: hflick.height
                    model: page.pagedRows
                    // delegate recycling: rows are rebuilt on every
                    // refresh, and without reuse the view stutters
                    reuseItems: true
                    clip: true
                    headerPositioning: ListView.OverlayHeader
                    QQC2.ScrollBar.vertical: QQC2.ScrollBar {}

                    header: Rectangle {
                        z: 3
                        width: tableView.width
                        height: hcolumn.implicitHeight + Kirigami.Units.smallSpacing * 2
                        color: Kirigami.Theme.alternateBackgroundColor
                        Column {
                        id: hcolumn
                        anchors.verticalCenter: parent.verticalCenter
                        Row {
                            id: headerRow
                            QQC2.CheckBox {   // выделить страницу целиком
                                width: Kirigami.Units.gridUnit * 2
                                tristate: true
                                checkState: page.selRows.length === 0 ? Qt.Unchecked
                                            : page.pagedRows.every(r => page.isSel(r))
                                              ? Qt.Checked : Qt.PartiallyChecked
                                onClicked: {
                                    if (page.pagedRows.every(r => page.isSel(r)))
                                        page.selRows = []
                                    else
                                        page.selRows = page.pagedRows.slice()
                                }
                            }
                            Repeater {
                                model: page.visibleCols
                                Item {
                                    width: page.colWidth(modelData)
                                    height: hlbl.implicitHeight
                                    property string col: modelData
                                    QQC2.Label {
                                        id: hlbl
                                        anchors.fill: parent
                                        anchors.rightMargin: 10
                                        leftPadding: Kirigami.Units.smallSpacing
                                        text: col + (page.sortCol === col
                                                     ? (page.sortAsc ? "  ↑" : "  ↓") : "")
                                        font.bold: true
                                        elide: Text.ElideRight
                                    }
                                    MouseArea {   // клик — сортировка
                                        anchors.fill: parent
                                        anchors.rightMargin: 14
                                        onClicked: page.toggleSort(col)
                                    }
                                    MouseArea {
                                        width: 12
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        anchors.bottom: parent.bottom
                                        cursorShape: Qt.SplitHCursor
                                        preventStealing: true
                                        property real sx
                                        property real sw
                                        onPressed: m => { sx = m.x; sw = page.colWidth(col) }
                                        onPositionChanged: m => {
                                            if (pressed) page.setColWidth(col, sw + (m.x - sx))
                                        }
                                        onReleased: page.persistWidths()
                                    }
                                    Kirigami.Separator {
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        anchors.bottom: parent.bottom
                                    }
                                }
                            }
                        }
                        // СТРОКА ФИЛЬТРОВ ПО КОЛОНКАМ УБРАНА: отбор задаёт
                        // строка запроса (положение 17: один механизм)

                        }
                        Kirigami.Separator {
                            anchors.bottom: parent.bottom
                            width: parent.width
                        }
                    }

                    delegate: QQC2.ItemDelegate {
                        id: rowDel
                        property var rowData: modelData
                        width: tableView.width
                        highlighted: page.isSel(rowData)
                        // зебра: белый/серый + нижняя граница строки
                        background: Rectangle {
                            color: rowDel.highlighted
                                   ? Qt.alpha(Kirigami.Theme.highlightColor, 0.20)
                                   : index % 2 === 0
                                     ? Kirigami.Theme.backgroundColor
                                     : Kirigami.Theme.alternateBackgroundColor
                            Kirigami.Separator {
                                anchors.bottom: parent.bottom
                                width: parent.width
                                opacity: 0.35
                            }
                            // ПОЛОСА КРИТИЧНОСТИ СЛЕВА, как в ленте событий:
                            // важное видно, не читая колонки
                            Rectangle {
                                anchors { left: parent.left; top: parent.top
                                          bottom: parent.bottom }
                                width: 4
                                visible: page.rowAccent(rowDel.rowData) !== ""
                                color: page.rowAccent(rowDel.rowData) || "transparent"
                                opacity: 0.9
                            }
                        }
                        property int rowIndex: index
                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton
                            onClicked: m => page.clickRow(rowDel.rowData,
                                                          rowDel.rowIndex,
                                                          m.modifiers)
                            onDoubleClicked: editDialog.openFor(rowDel.rowData)
                        }
                        contentItem: Row {
                            QQC2.CheckBox {
                                width: Kirigami.Units.gridUnit * 2
                                anchors.verticalCenter: parent.verticalCenter
                                checked: page.isSel(rowDel.rowData)
                                onClicked: page.clickRow(rowDel.rowData,
                                                         rowDel.rowIndex,
                                                         Qt.ControlModifier)
                            }
                            Repeater {
                                model: page.visibleCols
                                Item {
                                    width: page.colWidth(modelData)
                                    height: cellLbl.implicitHeight
                                    anchors.verticalCenter: parent.verticalCenter
                                    QQC2.Label {
                                        id: cellLbl
                                        anchors.fill: parent
                                        text: String(rowDel.rowData[modelData] ?? "")
                                        elide: Text.ElideRight
                                        leftPadding: Kirigami.Units.smallSpacing
                                    }
                                    Kirigami.Separator {
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        anchors.bottom: parent.bottom
                                        opacity: 0.25
                                    }
                                }
                            }
                        }
                    }

                    Kirigami.PlaceholderMessage {
                        anchors.centerIn: parent
                        visible: tableView.count === 0
                        text: "Empty"
                    }
                }
            }
            }
        }



        // -------- details sidebar (full height) --------
        SidePanel {
            id: detailsPanel
            title: "Details"
            iconName: "documentinfo"
            panelWidth: Kirigami.Units.gridUnit * 22
            onCloseRequested: open = false

            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                ColumnLayout {
                    width: detailsPanel.panelWidth - Kirigami.Units.largeSpacing * 2
                    spacing: Kirigami.Units.smallSpacing
                    Repeater {
                        model: page.lastSel && page.cur ? page.cur.columns : []
                        delegate: ColumnLayout {
                            spacing: 1
                            Layout.fillWidth: true
                            visible: String(page.lastSel[modelData] ?? "") !== ""
                            property bool sensitive: page.sensitiveCols.includes(modelData)
                            property bool revealed: false
                            RowLayout {
                                Layout.fillWidth: true
                                QQC2.Label {
                                    text: modelData
                                    opacity: 0.55
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    Layout.fillWidth: true
                                }
                                QQC2.ToolButton {   // глазик для секретных полей
                                    visible: parent.parent.sensitive
                                    icon.name: parent.parent.revealed ? "view-hidden" : "view-visible"
                                    implicitHeight: Kirigami.Units.gridUnit * 1.4
                                    implicitWidth: Kirigami.Units.gridUnit * 1.4
                                    onClicked: parent.parent.revealed = !parent.parent.revealed
                                }
                            }
                            QQC2.TextArea {
                                Layout.fillWidth: true
                                readOnly: true
                                wrapMode: TextEdit.Wrap
                                text: (parent.sensitive && !parent.revealed)
                                      ? "•••••••••  (click the eye to reveal)"
                                      : String(page.lastSel[modelData] ?? "")
                                font.family: (page.longCols.includes(modelData)
                                              || parent.sensitive)
                                             ? "monospace" : Kirigami.Theme.defaultFont.family
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                background: Rectangle {
                                    color: Kirigami.Theme.alternateBackgroundColor
                                    radius: 4
                                }
                            }
                        }
                    }
                }
            }
        }


        // -------- columns sidebar (full height) --------
        SidePanel {
            id: colPanel
            title: "Columns"
            iconName: "view-table-of-contents-ltr"
            panelWidth: Kirigami.Units.gridUnit * 14
            onCloseRequested: open = false

            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                ColumnLayout {
                    width: colPanel.panelWidth - Kirigami.Units.largeSpacing * 2
                    spacing: 0
                    Repeater {
                    model: page.colOrder
                    delegate: RowLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        QQC2.CheckBox {
                            checked: !page.hiddenCols.includes(modelData)
                            onToggled: page.toggleCol(modelData)
                        }
                        QQC2.Label {
                            text: modelData
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            opacity: page.hiddenCols.includes(modelData) ? 0.5 : 1
                        }
                        QQC2.ToolButton {
                            icon.name: "go-up"
                            enabled: index > 0
                            onClicked: page.moveCol(modelData, -1)
                        }
                        QQC2.ToolButton {
                            icon.name: "go-down"
                            enabled: index < page.colOrder.length - 1
                            onClicked: page.moveCol(modelData, 1)
                        }
                    }
                }
                }
            }
        }
    }

    Component {
        id: textFilter
        QQC2.TextField {
            property string col: parent.col
            placeholderText: "filter…"
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            text: page.colFilters[col] || ""
            onTextEdited: page.setColFilter(col, text)
        }
    }
    Component {
        id: comboFilter
        QQC2.ComboBox {
            property string col: parent.col
            property var uniq: parent.uniq
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            model: ["(all)"].concat(uniq)
            currentIndex: {
                const v = page.colFilters[col] || ""
                const i = uniq.indexOf(v)
                return i >= 0 ? i + 1 : 0
            }
            onActivated: page.setColFilter(col, currentIndex === 0 ? "" : currentText)
        }
    }

    // -------- row editor (double click / Edit) --------
    Kirigami.Dialog {
        id: editDialog
        title: "Record — " + (page.cur ? page.cur.title : "")
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        padding: Kirigami.Units.largeSpacing
        preferredWidth: Kirigami.Units.gridUnit * 24

        property var row: null
        function openFor(r) { row = r; open() }

        onAccepted: {
            const cols = page.cur.columns
            for (let i = 0; i < cols.length; i++) {
                const v = fieldsRep.itemAt(i).text
                if (v !== String(editDialog.row[cols[i]] ?? ""))
                    backend.setCell(page.cur.name, editDialog.row._id, cols[i], v)
            }
            backend.reload()
        }

        Kirigami.FormLayout {
            Repeater {
                id: fieldsRep
                model: editDialog.row && page.cur ? page.cur.columns : []
                QQC2.TextField {
                    Kirigami.FormData.label: modelData
                    text: editDialog.row ? String(editDialog.row[modelData] ?? "") : ""
                }
            }
        }
    }
}

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "Fmt.js" as Fmt

// События: ОДНО окно для ВСЕХ точек входа (нормализация приводит их к общей
// таксономии). Фильтрация «условно в SQL»: наведение на ячейку даёт + и −,
// они собирают WHERE, который виден и правится руками. Плюс группировка
// (слева значения группы, справа строки) и история SQL с поиском похожих.
Kirigami.Page {
    id: page
    title: "Events"
    padding: 0

    // Переключатель «Лента / Цепочки». Лента отвечает «что происходило»,
    // цепочки — «что за история за этим стоит»: связанная последовательность
    // от запуска процесса до соединения наружу.
    actions: [
        // ЦЕПОЧКИ ВРЕМЕННО СКРЫТЫ. Механизм работает (87 цепочек, покрытие
        // 100%), но пользоваться им рано: сперва доводим состояние и события.
        // Код, слоты и вкладка остаются — достаточно вернуть visible: true.
        Kirigami.Action {
            visible: false
            text: "Feed"
            icon.name: "view-list-details"
            checkable: true
            checked: page.mode === "feed"
            onTriggered: page.mode = "feed"
        },
        Kirigami.Action {
            visible: false
            text: "Chains"
            icon.name: "distribute-graph-directed"
            checkable: true
            checked: page.mode === "chains"
            onTriggered: {
                page.mode = "chains"
                if (!page.chains) page.chains = backend.eventChains()
            }
        },
        Kirigami.Action {
            text: "Refresh chains"
            icon.name: "view-refresh"
            visible: false
            onTriggered: {
                page.chains = backend.eventChains()
                if (page.chainId !== "")
                    page.chainSteps = backend.chainDetail(page.chainId)
            }
        }
    ]

    property var stats: ({ total: 0, by_category: [], by_module: [], by_outcome: [] })
    property var feed: ({ rows: [], total: 0, error: "" })
    property var fieldGroups: []
    property var sel: null
    property int pageIndex: 0
    property int pageLimit: 50

    // фильтры «условно в SQL»
    property var conds: []           // [{col, op, val}] — совместимость
    // ЕДИНЫЙ ЗАПРОС из общей строки (положение 15). Может быть условием SQL
    // или просто текстом — тогда ищем его по осмысленным полям сразу.
    property string queryText: ""
    // eventFields() отдаёт ГРУППЫ таксономии [{group, fields:[{name,…}]}],
    // а конструктору нужны плоские ИМЕНА — иначе в ComboBox попадают объекты
    // («Unable to assign QVariantMap to QString»).
    property var allFields: {
        var out = []
        var g = backend.eventFields() || []
        for (var i = 0; i < g.length; i++) {
            var ff = g[i].fields || []
            for (var j = 0; j < ff.length; j++)
                if (ff[j] && ff[j].name) out.push(ff[j].name)
        }
        return out.length ? out : ["ts", "event_action", "message"]
    }
    property string whereText: ""
    // режим раздела: лента отдельных событий или ЦЕПОЧКИ (связанные истории)
    property string mode: "feed"
    property var chains: null
    property string chainId: ""
    property var chainSteps: null
    // ГРУППИРОВКА ПО НЕСКОЛЬКИМ ПОЛЯМ: как `GROUP BY a, b` в SQL.
    // groupBy — список полей, groupParts — выбранные значения по каждому.
    property var groupBy: []
    property var groupParts: []
    property string groupVal: ""
    property bool groupPicked: false     // выбрана ли группа (пустое значение — тоже выбор)
    // Ограничение по времени БОЛЬШЕ НЕ ОТДЕЛЬНОЕ СОСТОЯНИЕ: промежуток
    // закрепляется обычным условием `ts >= …` в строке запроса (pinPeriod).
    // Скользящее окно давало разный набор при каждом обновлении.
    property var groupRows: []
    // все группы, как их вернула база: порог размера убран — прятать мелкие
    // группы значит прятать редкое, а редкое как раз и интересно
    readonly property var shownGroups: groupRows

    // ---- колонки ----
    property var allCols: []
    property var colOrder: []
    property var hiddenCols: []
    property var widths: ({})
    // РОВНО 8 колонок, которые отвечают на «что произошло»:
    // когда · кто · что сделал · над чем (тип+имя) · чем это кончилось ·
    // к какой области относится · подробности. Остальные 84 поля доступны
    // через «Columns» и в панели деталей — но не мешают чтению ленты.
    readonly property var defaultCols: ["ts", "subject_name", "event_action",
        "object_type", "object_name", "event_outcome", "event_category", "message"]
    readonly property int cfgVersion: 2      // смена набора по умолчанию
    // ЕСЛИ СГРУППИРОВАЛИ — эти поля из таблицы убираем: внутри группы они
    // одинаковы во всех строках и только занимают место (значение видно
    // слева, в самой группе).
    property var visibleCols: colOrder.filter(
        c => !hiddenCols.includes(c) && groupBy.indexOf(c) < 0)
    // поиск в панели выбора колонок
    property string colSearch: ""
    readonly property var shownColChoices: {
        if (colSearch === "") return colOrder
        var q = colSearch.toLowerCase()
        return colOrder.filter(c => c.toLowerCase().indexOf(q) >= 0)
    }
    // Снимок исходной выборки: к нему возвращает «Reset» в строке запроса.
    // Именно СНИМОК, а не visibleCols — иначе применение выборки меняло бы
    // и то, к чему сбрасывать.
    property var baseSelect: []

    // Поле события → куда «исследовать» в разделе «Состояние»
    readonly property var exploreMap: ({
        "process_pid":        { table: "processes",    col: "pid" },
        "parent_pid":         { table: "processes",    col: "pid" },
        "process_name":       { table: "processes",    col: "command" },
        "process_executable": { table: "processes",    col: "command" },
        "user_name":          { table: "users",        col: "name" },
        "user_id":            { table: "users",        col: "uid" },
        "destination_ip":     { table: "ports",        col: "remote" },
        "source_ip":          { table: "ports",        col: "remote" },
        "related_ip":         { table: "ports",        col: "remote" },
        "destination_port":   { table: "ports",        col: "port" },
        "service_name":       { table: "services",     col: "unit" },
        "package_name":       { table: "applications", col: "name" }
    })
    property var savedList: []
    function reloadSaved() { savedList = backend.savedQueries() }
    // каталоги сохранённых запросов (создаются пользователем)
    property var dirsList: ["general"]
    function reloadDirs() {
        var d = backend.queryDirs()
        dirsList = (d && d.length) ? d : ["general"]
    }

    function esc(v) { return String(v).replace(/'/g, "''") }
    function condSql(c) {
        // пустая ячейка бывает и NULL, и '' — учитываем оба варианта
        if (c.op === "IS NULL")
            return '("' + c.col + '" IS NULL OR "' + c.col + '" = \'\')'
        if (c.op === "IS NOT NULL")
            return '("' + c.col + '" IS NOT NULL AND "' + c.col + '" <> \'\')'
        if (c.op === "IN")
            return '"' + c.col + '" IN \'' + esc(c.val) + '\''
        if (c.op === "LIKE" || c.op === "NOT LIKE")
            return '"' + c.col + '" ' + c.op + " '%" + esc(c.val) + "%'"
        // для < > <= >= числовое значение отдаём БЕЗ кавычек, иначе SQLite
        // сравнивает как текст ('9' > '40') и порог работает неверно
        var num = (c.op === ">" || c.op === "<" || c.op === ">=" || c.op === "<=")
                  && c.val !== "" && !isNaN(Number(c.val))
        if (num) return '"' + c.col + '" ' + c.op + " " + c.val
        return '"' + c.col + '" ' + c.op + " '" + esc(c.val) + "'"
    }
    // общий сборщик условия
    function assemble(parts) { return parts.join(" AND ") }
    // Условие выбранной группы. Пустая ячейка в SQLite бывает и NULL, и '' —
    // GROUP BY даёт их РАЗНЫМИ группами, поэтому «= \'\'» ловил не те строки
    // (счётчик показывал 300, а таблица оставалась пустой).
    function groupCond() {
        if (!groupBy.length || !groupPicked) return ""
        var parts = []
        for (var i = 0; i < groupBy.length; i++) {
            var f = groupBy[i]
            var v = i < groupParts.length ? String(groupParts[i]) : ""
            // пустая ячейка в SQLite бывает и NULL, и '' — ловим обе
            if (v === "") parts.push('("' + f + '" IS NULL OR "' + f + '" = \'\')')
            else parts.push('"' + f + '" = \'' + esc(v) + '\'')
        }
        return parts.length > 1 ? "(" + parts.join(" AND ") + ")" : parts[0]
    }
    // WHERE без условия группы — по нему считаются счётчики групп,
    // чтобы они совпадали с тем, что реально покажет таблица.
    // Текст из общей строки: если это похоже на условие SQL — берём как есть,
    // иначе разворачиваем в поиск по осмысленным полям. Так одна строка
    // работает и для «набрать», и для «просто найти».
    function queryPart() {
        var q = String(page.queryText || "").trim()
        if (q === "") return ""
        if (/[<>=]|LIKE|IS NULL|IS NOT NULL/i.test(q)) return "(" + q + ")"
        var lk = "'%" + esc(q) + "%'"
        return "(message LIKE " + lk + " OR process_name LIKE " + lk +
               " OR process_executable LIKE " + lk +
               " OR destination_ip LIKE " + lk +
               " OR user_name LIKE " + lk +
               " OR event_action LIKE " + lk + ")"
    }
    function whereNoGroup() {
        var parts = []
        var qp = queryPart()
        if (qp !== "") parts.push(qp)
        return assemble(parts)
    }
    function buildWhere() {
        var parts = []
        var qp = queryPart()
        if (qp !== "") parts.push(qp)
        var gc = groupCond()
        if (gc !== "") parts.push(gc)
        return assemble(parts)
    }
    // Кнопки «+»/«−» на ячейке дописывают условие в ОБЩУЮ строку запроса,
    // а не в собственный список — источник запроса должен быть один.
    function addCond(col, op, val) { qbar.addCondition(col, op, String(val)) }
    function dropCond(i) {
        var c = conds.slice(); c.splice(i, 1); conds = c; syncWhere()
    }
    function syncWhere() { whereText = buildWhere(); pageIndex = 0; reload() }

    // КОПИРОВАНИЕ В БУФЕР. В QML нет прямого доступа к буферу обмена, поэтому
    // используем скрытый TextEdit: кладём текст, выделяем, copy().
    property string copied: ""
    function copyValue(v) {
        if (v === undefined || v === null || v === "") return
        clipHelper.text = String(v)
        clipHelper.selectAll()
        clipHelper.copy()
        page.copied = String(v)
        copiedTimer.restart()
    }
    TextEdit { id: clipHelper; visible: false }
    Timer { id: copiedTimer; interval: 1600; onTriggered: page.copied = "" }

    // ---- СТАТИСТИКА ПОЛЕЙ: что вообще заполнено и чем ----
    // ИМЯ ОТЛИЧАЕТСЯ от `stats`: то — фасеты ленты, это — разбор полей
    property var fieldStats: null
    property string statsFilter: ""
    // перечень значений одной строкой-столбиком; длинный раскрывается в панели
    // ШИРИНА КОЛОНКИ ПАНЕЛИ ГРУПП — ПО САМОМУ ДЛИННОМУ ЗНАЧЕНИЮ в ней
    // (и по имени поля в шапке), с потолком: что не влезло — многоточием.
    // Считается в одном месте, шапка и строки берут отсюда, иначе колонки
    // разъезжаются.
    readonly property int grpCountWidth: Kirigami.Units.gridUnit * 5
    readonly property int grpColMin: Kirigami.Units.gridUnit * 5
    readonly property int grpColMax: Kirigami.Units.gridUnit * 20
    FontMetrics { id: grpFm }
    readonly property var grpColWidths: {
        var out = []
        for (var i = 0; i < groupBy.length; i++) {
            var longest = String(groupBy[i])
            for (var j = 0; j < groupRows.length; j++) {
                var parts = groupRows[j].parts
                var v = parts && parts.length > i ? String(parts[i]) : ""
                if (v.length > longest.length) longest = v
            }
            var w = grpFm.advanceWidth(longest) + Kirigami.Units.gridUnit * 2.2
            out.push(Math.round(Math.max(grpColMin, Math.min(grpColMax, w))))
        }
        return out
    }
    // ручная ширина колонки перекрывает расчётную (ключ — имя поля, чтобы
    // не сбивалась при смене порядка группировки)
    property var grpColUser: ({})
    // желаемая ширина: ручная, иначе по содержимому
    function grpColWish(i) {
        var f = i < groupBy.length ? groupBy[i] : ""
        if (grpColUser[f] !== undefined) return grpColUser[f]
        return i < grpColWidths.length ? grpColWidths[i] : grpColMin
    }
    // ФАКТИЧЕСКАЯ ширина: если панель уже суммы желаемых, колонки ужимаются
    // ПРОПОРЦИОНАЛЬНО — счётчик не должен выпадать за край, что бы ни было
    // с шириной панели. Ниже минимума не жмём, дальше — многоточие.
    property int grpPanelWidth: 0
    readonly property var grpColFit: {
        var wish = [], sum = 0
        for (var i = 0; i < groupBy.length; i++) {
            var w = grpColWish(i); wish.push(w); sum += w
        }
        var free = grpPanelWidth - grpCountWidth - Kirigami.Units.smallSpacing * 3
        if (free <= 0 || sum <= free) return wish
        var k = free / sum
        var out = []
        for (var j = 0; j < wish.length; j++)
            out.push(Math.max(Kirigami.Units.gridUnit * 3, Math.floor(wish[j] * k)))
        return out
    }
    function grpColWidth(i) {
        if (i === undefined) i = 0
        return i < grpColFit.length ? grpColFit[i] : grpColMin
    }
    function setGrpColWidth(i, w) {
        var f = i < groupBy.length ? groupBy[i] : ""
        if (!f) return
        var o = Object.assign({}, grpColUser)
        o[f] = Math.max(grpColMin, Math.round(w))
        grpColUser = o
    }
    function resetGrpColWidth(i) {
        var f = i < groupBy.length ? groupBy[i] : ""
        var o = Object.assign({}, grpColUser)
        delete o[f]
        grpColUser = o
    }
    // сколько нужно панели целиком — и сколько задал пользователь перетаскиванием
    readonly property int grpNaturalWidth: {
        // учитываем и ручные ширины, иначе после растягивания колонки
        // счётчик уезжает за край панели
        var _ = grpColUser
        var w = grpCountWidth + Kirigami.Units.gridUnit * 2
        for (var i = 0; i < groupBy.length; i++) w += grpColWish(i)
        return w
    }
    property int grpUserWidth: 0

    readonly property int longValues: 1000
    function valuesText(f) {
        if (!f || !f.values) return ""
        var out = []
        for (var i = 0; i < f.values.length; i++)
            out.push(f.values[i].value + "  (" + f.values[i].n + ")")
        return out.join("\n")
    }

    // выбранное в таблице статистики поле и его значения
    property string statsField: ""
    readonly property var statsValues: {
        if (!fieldStats || !fieldStats.fields) return []
        for (var i = 0; i < fieldStats.fields.length; i++)
            if (fieldStats.fields[i].field === statsField)
                return fieldStats.fields[i].values
        return []
    }
    readonly property int statsMax: {
        var m = 1
        for (var i = 0; i < statsValues.length; i++)
            if (statsValues[i].n > m) m = statsValues[i].n
        return m
    }
    // для проверки рендером
    function openStats() { statsDlg.open() }

    function loadStats() {
        page.fieldStats = backend.eventFieldStats(page.whereText)
        // по умолчанию раскрыто первое поле — окно не выглядит пустым
        page.statsField = ""   // панель открывается по клику, а не сама
    }
    readonly property var statsRows: {
        var stats = page.fieldStats
        if (!stats || !stats.fields) return []
        var q = statsFilter.toLowerCase()
        if (!q) return stats.fields
        var out = []
        for (var i = 0; i < stats.fields.length; i++) {
            var f = stats.fields[i]
            if (f.field.toLowerCase().indexOf(q) >= 0) { out.push(f); continue }
            for (var j = 0; j < f.values.length; j++)
                if (String(f.values[j].value).toLowerCase().indexOf(q) >= 0) { out.push(f); break }
        }
        return out
    }

    // ЗАКРЕПИТЬ ПРОМЕЖУТОК: границу считаем СЕЙЧАС и записываем абсолютным
    // временем. «За последний час» остаётся тем самым часом, а не скользит
    // вслед за часами — иначе повторный просмотр показывал бы другой набор.
    // для проверки из харнесса: запустить текущий запрос, как кнопка Run
    function runQuery() { qbar.apply() }
    function setQuick(t) { qbar.quickText = t; qbar.apply() }
    // для проверки из харнесса
    function qbarChanged() { return qbar.changed }
    function editCond0() { qbar.editCondition(0) }
    // для проверки рендером
    function selectMany(fs) { qbar.spec.select = fs; qbar.touch(); qbar.apply() }
    function qbarHeight() { return qbar.height }
    function openMore(kind) { qbar.showMore(kind) }
    function moveSelectField(i, d) { qbar.moveSelect(i, d) }
    function specSelect() { return qbar.spec.select.join(",") }
    // для проверки: задать группировку и выбрать группу
    function setGroup(fs) {
        qbar.addClause("group")
        qbar.spec.groupBy = fs
        qbar.touch(); qbar.apply()
    }
    function pickGroup(row) {
        page.groupPicked = true
        page.groupVal = String(row.value || "")
        page.groupParts = row.parts || []
        page.syncWhere()
    }
    function openCal() { qbar.openCalendar("from") }
    function openSaved() { page.reloadSaved(); page.reloadDirs(); savedPanel.open = true }
    function openHistory() { histPopup.show("") }
    function setUpper(f, iso) { qbar.setUpperBound(f, iso) }
    function resetQuery() { qbar.clearAll() }
    function dropField(n) { qbar.toggleField(n) }
    function addCondition2(f, o, v) { qbar.addCondition(f, o, v) }

    // ---- СВЯЗЬ СОБЫТИЯ С ЖИВЫМ ПРОЦЕССОМ ----
    // Карта «pid -> команда» снимается ОДИН РАЗ НА СТРАНИЦУ (50 событий по
    // умолчанию). Считать её на каждое событие незачем, а на всю базу —
    // тем более: процесс из вчерашнего события давно мёртв.
    property var livePids: ({})
    function reloadLive() { livePids = backend.livePids() }
    function liveCommandOf(pid) { return page.liveCommand(pid) }
    function liveCommand(pid) {
        var p = String(pid || "")
        return p !== "" && livePids[p] !== undefined ? livePids[p] : ""
    }

    // ---- сортировка кликом по шапке ----
    // Порядок приходит ИЗ ЗАПРОСА (конструктор или набранный SQL) — одно
    // место истины, поэтому в шапке и в тексте запроса всегда одно и то же.
    property string orderText: ""
    property string sortCol: ""
    property bool sortDesc: false
    function sortBy(col) {
        if (sortCol === col) sortDesc = !sortDesc
        else { sortCol = col; sortDesc = false }
        qbar.addSort(col, sortDesc)     // попадёт и в SQL-текст, и в конструктор
        qbar.apply()
    }
    // и набрать запрос руками, как в режиме SQL
    function manualQuery(t) {
        qbar.builderMode = false
        qbar.manualText = t
        qbar.apply()
    }

    // окно времени по умолчанию: сутки, закреплённые абсолютной границей
    readonly property int defaultWindowMs: 86400000
    property bool timeSeeded: false
    function seedPeriod() {
        if (timeSeeded) return
        timeSeeded = true
        // ВЕРНУЛИСЬ В РАЗДЕЛ — ЗАПРОС НА МЕСТЕ. Страница пересоздаётся при
        // переходе по разделам, поэтому запрос хранится в настройках и
        // восстанавливается вместе с результатом.
        var st = backend.getSettings()
        if (st && st.events_query && qbar.importState(st.events_query)) return
        pinPeriod(defaultWindowMs)
        qbar.apply()
        // ЭТО И ЕСТЬ ИСХОДНЫЙ ЗАПРОС: 8 колонок ленты + сутки событий
        qbar.markBaseline()
    }
    function saveQueryState() {
        // сохраняем только осмысленное состояние: до инициализации колонок
        // apply() срабатывает вхолостую и записал бы пустой запрос
        if (!timeSeeded || !qbar.spec.select.length) return
        backend.setSetting("events_query", qbar.exportState())
    }

    function pinPeriod(ms) {
        var from = new Date(Date.now() - ms)
        // события хранятся в UTC — условие тоже в UTC. Смещение сохраняем:
        // при сбросе запроса граница пересчитается от текущего момента, а не
        // вернётся к дате, которая была при открытии раздела.
        qbar.addCondition("ts", ">=",
                          from.toISOString().replace(/\.\d+Z$/, "Z"), "AND", ms)
    }

    // Внешний переход (из сетевого дашборда: «События по адресу»). Условие
    // готовое, поэтому кладём его прямо в общую строку — там его видно и
    // можно поправить руками.
    function applyEventFocus() {
        if (!root.eventFocus) return
        qbar.builderMode = false
        qbar.manualText = root.eventFocus.where
        page.queryText = root.eventFocus.where
        page.pageIndex = 0
        page.syncWhere()
    }
    Connections {
        target: root
        function onEventFocusChanged() { page.applyEventFocus() }
        // приход из «Изменений»: сразу открыть нужную цепочку
        function onChainFocusChanged() { page.applyChainFocus() }
    }

    function applyChainFocus() {
        if (!root.chainFocus) return
        page.mode = "chains"
        if (!page.chains) page.chains = backend.eventChains()
        page.chainId = root.chainFocus.id
        var d = backend.chainDetail(page.chainId)
        page.feed = { rows: d.steps || [], total: d.count || 0, error: "" }
        page.sel = null
    }


    function colWidth(c) {
        if (widths[c]) return widths[c]
        if (c === "ts") return 150
        if (c === "message" || c === "process_command_line" || c === "raw") return 330
        if (c === "object_name") return 230
        if (c === "subject_name" || c === "event_action") return 150
        if (c === "object_type" || c === "event_outcome") return 90
        if (c === "event_severity" || c === "process_pid"
            || c === "destination_port" || c === "parent_pid") return 70
        return 130
    }
    property int tableWidth: {
        var w = 8
        for (var i = 0; i < visibleCols.length; i++) w += colWidth(visibleCols[i])
        return w
    }
    function setWidth(c, w) {
        var o = Object.assign({}, widths); o[c] = Math.max(50, w); widths = o
    }
    function toggleCol(c) {
        var h = hiddenCols.slice()
        if (h.includes(c)) h = h.filter(x => x !== c); else h.push(c)
        hiddenCols = h; saveCfg()
    }
    function moveCol(c, dir) {
        var o = colOrder.slice()
        var i = o.indexOf(c), j = i + dir
        if (i < 0 || j < 0 || j >= o.length) return
        o[i] = o[j]; o[j] = c; colOrder = o; saveCfg()
    }
    function saveCfg() {
        backend.setSetting("events_colcfg", JSON.stringify(
            { v: page.cfgVersion, order: colOrder,
              hidden: hiddenCols, widths: widths }))
    }
    function initCols() {
        var groups = backend.eventFields()
        page.fieldGroups = groups
        var all = []
        for (var g = 0; g < groups.length; g++)
            for (var i = 0; i < groups[g].fields.length; i++)
                all.push(groups[g].fields[i].name)
        page.allCols = all
        var cfg = null
        var s = backend.getSettings()
        if (s && s.events_colcfg) {
            try { cfg = JSON.parse(s.events_colcfg) } catch (e) { cfg = null }
            // старый сохранённый набор не должен перекрывать новый дефолт
            if (cfg && (cfg.v || 0) < page.cfgVersion) cfg = null
        }
        var order = []
        if (cfg && cfg.order) order = cfg.order.filter(c => all.includes(c))
        for (var k = 0; k < all.length; k++)
            if (!order.includes(all[k])) order.push(all[k])
        page.colOrder = order
        page.hiddenCols = (cfg && cfg.hidden)
            ? cfg.hidden.filter(c => all.includes(c))
            : all.filter(c => !page.defaultCols.includes(c))
        page.widths = (cfg && cfg.widths) ? cfg.widths : ({})
        page.baseSelect = order.filter(c => !page.hiddenCols.includes(c))
        page.seedPeriod()
    }

    // ВЫБОРКА ЗАДАЁТ КОЛОНКИ: что перечислено в SELECT, то лента и показывает,
    // в том же порядке. Пустая выборка колонки не трогает.
    function applySelect(sel) {
        if (!sel || !sel.length) return
        var keep = sel.filter(c => page.allCols.includes(c))
        if (!keep.length) return
        var rest = page.colOrder.filter(c => !keep.includes(c))
        page.colOrder = keep.concat(rest)
        page.hiddenCols = rest
        // НЕ СОХРАНЯЕМ: выборка в запросе — это разовый взгляд на данные, а
        // не настройка вида. Иначе один узкий запрос навсегда перекраивал бы
        // таблицу, и вернуть прежние колонки было бы нечем. Постоянная
        // настройка колонок делается панелью «Columns» — она и сохраняет.
    }

    function reload() {
        page.feed = backend.eventRows(whereText, pageLimit,
                                      pageIndex * pageLimit, page.orderText)
        // карта живых процессов — под ту же страницу
        page.reloadLive()
        page.stats = backend.eventStats()
        if (groupBy.length) {
            var g = backend.eventGroups(groupBy.join(","), whereNoGroup())
            page.groupRows = g.rows || []
        } else {
            page.groupRows = []
        }
    }
    Component.onCompleted: {
        initCols()
        // внешний переход (из сетевого дашборда) применяется ВМЕСТО
        // обычной загрузки: иначе условие затёрлось бы пустым фильтром
        if (root.eventFocus) applyEventFocus()
        else reload()
    }
    Connections {
        target: backend
        // Reload only on the first page and no more than once every few
        // seconds: the pipeline ticks every 2 s and a full reload on each tick
        // made scrolling stutter.
        property real lastReload: 0
        function onStateReady(s) {
            if (page.pageIndex !== 0) return
            var now = Date.now()
            if (now - lastReload < 5000) return
            lastReload = now
            page.reload()
        }
    }

    function sevColor(v) {
        var n = parseInt(v) || 0
        if (n >= 70) return "#e74c3c"
        if (n >= 45) return "#e67e22"
        if (n >= 25) return "#f1c40f"
        return Kirigami.Theme.disabledTextColor
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            // KDE HIG: one vertical rhythm for the whole column instead of
            // per-row margins — toolbars used to sit at different distances
            // from each other and from the page edge.
            spacing: Kirigami.Units.smallSpacing
            Layout.topMargin: Kirigami.Units.smallSpacing

            // ---- поиск + группировка ----
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.largeSpacing
                Layout.rightMargin: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.smallSpacing
                QueryBar {
                    id: qbar
                    Layout.fillWidth: true
                    // поля таксономии — из них строится конструктор
                    fields: {
                        var out = []
                        var f = page.allFields
                        for (var i = 0; i < f.length; i++) out.push({ name: f[i] })
                        return out
                    }
                    // выборка начинается с 8 колонок, которые лента показывает
                    defaultSelect: page.baseSelect
                    // ---- работа с запросами: слева от Run и Build ----
                    hostTools: [
                        QQC2.ToolButton {
                            icon.name: "document-save"
                            enabled: page.whereText.trim() !== ""
                            QQC2.ToolTip.text: "Save this query"
                            QQC2.ToolTip.visible: hovered
                            onClicked: { page.reloadDirs(); saveDialog.open() }
                        },
                        QQC2.ToolButton {
                            icon.name: "view-history"
                            QQC2.ToolTip.text: "Queries you ran before"
                            QQC2.ToolTip.visible: hovered
                            onClicked: histPopup.show("")
                        },
                        QQC2.ToolButton {
                            icon.name: "bookmarks"
                            QQC2.ToolTip.text: "Run a saved query"
                            QQC2.ToolTip.visible: hovered
                            onClicked: {
                                page.reloadSaved(); page.reloadDirs()
                                savedPanel.open = !savedPanel.open
                            }
                        }
                    ]
                    placeholder: "type SQL, or plain text to search everywhere"
                    onApplied: function (spec, sql) {
                        page.applySelect(spec.select)
                        // запомнить запрос в истории (пустые не храним)
                        if (sql && sql.trim() !== "") backend.eventSqlRemember(sql)
                        page.orderText = qbar.orderText()
                        // группировка задаётся в самом запросе (GROUP BY)
                        var g = spec.groupBy.slice()
                        if (g.join(",") !== page.groupBy.join(",")) {
                            page.groupBy = g
                            page.groupVal = ""; page.groupParts = []
                            page.groupPicked = false
                        }
                        page.queryText = sql
                        page.pageIndex = 0
                        page.syncWhere()
                        page.saveQueryState()
                    }
                }
            }

            // ---- WHERE «условно в SQL»: строится кнопками + / −, правится руками ----

            // ---- чипы активных условий ----

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.largeSpacing
                Layout.rightMargin: Kirigami.Units.largeSpacing
                visible: (page.feed.error || "") !== ""
                type: Kirigami.MessageType.Error
                text: page.feed.error || ""
            }

            // ---- группировка слева + таблица справа ----
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                Item {
                    visible: page.groupBy.length > 0
                    // КОЛОНОК СТОЛЬКО ЖЕ, СКОЛЬКО ПОЛЕЙ ГРУППИРОВКИ:
                    // ширина панели растёт вместе с ними
                    Layout.preferredWidth: page.grpUserWidth > 0
                        ? page.grpUserWidth
                        : Math.min(page.width * 0.6, page.grpNaturalWidth)
                    onWidthChanged: page.grpPanelWidth = width
                    Component.onCompleted: page.grpPanelWidth = width
                    Layout.fillHeight: true
                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 0
                        // ШАПКА — ТАКАЯ ЖЕ, КАК У ОСНОВНОЙ ТАБЛИЦЫ: тот же
                        // фон, та же высота, те же разделители колонок.
                        Rectangle {
                            id: grpHeadBar
                            Layout.fillWidth: true
                            Layout.preferredHeight: grpProbe.implicitHeight
                                                    + Kirigami.Units.smallSpacing * 2
                            color: Kirigami.Theme.alternateBackgroundColor
                            // мерка высоты: та же, что у шапки основной таблицы
                            QQC2.Label { id: grpProbe; visible: false; text: "Ag"; font.bold: true }
                            Row {
                                id: grpHead
                                anchors.left: parent.left
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                Item { width: Kirigami.Units.smallSpacing; height: 1 }
                                Repeater {
                                    model: page.groupBy
                                    delegate: Item {
                                        required property var modelData
                                        required property int index
                                        width: page.grpColWidth(index)
                                        // ЯЧЕЙКА ВО ВСЮ ВЫСОТУ ШАПКИ: рукоятка
                                        // изменения ширины была тонкой полоской
                                        // в 17 px и в неё было не попасть
                                        height: grpHeadBar.height
                                        QQC2.Label {
                                            id: grpHeadLbl
                                            anchors.fill: parent
                                            leftPadding: Kirigami.Units.smallSpacing
                                            rightPadding: Kirigami.Units.largeSpacing
                                            verticalAlignment: Text.AlignVCenter
                                            text: modelData
                                            font.bold: true
                                            elide: Text.ElideRight
                                        }
                                        Kirigami.Separator {
                                            anchors.right: parent.right
                                            anchors.top: parent.top
                                            anchors.bottom: parent.bottom
                                            opacity: 0.35
                                        }
                                    }
                                }
                            }
                            // ИЗМЕНЕНИЕ ШИРИНЫ КОЛОНОК — ОДНОЙ ПОЛОСОЙ ПОВЕРХ
                            // ШАПКИ. Отдельные рукоятки в ячейках событий не
                            // получали (их перекрывала раскладка), а здесь
                            // граница вычисляется по координате курсора.
                            MouseArea {
                                id: grpResize
                                anchors.fill: parent
                                z: 5
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton
                                property int edge: -1        // граница под курсором
                                property real sx: 0
                                property real sw: 0
                                function edgeAt(x) {
                                    var acc = Kirigami.Units.smallSpacing
                                    for (var i = 0; i < page.groupBy.length; i++) {
                                        acc += page.grpColWidth(i)
                                        if (Math.abs(x - acc) <= 6) return i
                                    }
                                    return -1
                                }
                                cursorShape: (edge >= 0 || pressed) ? Qt.SplitHCursor
                                                                    : Qt.ArrowCursor
                                onPositionChanged: m => {
                                    if (pressed && edge >= 0) {
                                        page.setGrpColWidth(edge, sw + (m.x - sx))
                                        return
                                    }
                                    edge = edgeAt(m.x)
                                }
                                onPressed: m => {
                                    edge = edgeAt(m.x)
                                    sx = m.x
                                    sw = edge >= 0 ? page.grpColWish(edge) : 0
                                }
                                onDoubleClicked: m => {
                                    var e = edgeAt(m.x)
                                    if (e >= 0) page.resetGrpColWidth(e)
                                }
                                onExited: edge = -1
                                // подсветка границы, за которую можно тянуть
                                Rectangle {
                                    visible: grpResize.edge >= 0
                                    width: 2
                                    height: parent.height
                                    color: Kirigami.Theme.highlightColor
                                    x: {
                                        var acc = Kirigami.Units.smallSpacing
                                        for (var i = 0; i <= grpResize.edge
                                             && i < page.groupBy.length; i++)
                                            acc += page.grpColWidth(i)
                                        return acc - 1
                                    }
                                }
                            }
                            QQC2.Label {
                                anchors.right: parent.right
                                z: 6
                                // ровно над числами: у списка есть полоса
                                // прокрутки, о ней шапка не знала — плюс
                                // отступ от края, иначе «n» липнет к границе
                                // ровно по правому краю списка: у шапки своя
                                // ширина, у списка — своя (полоса прокрутки)
                                anchors.rightMargin: Math.max(0, grpHeadBar.width
                                                               - grpList.width)
                                anchors.verticalCenter: parent.verticalCenter
                                rightPadding: Kirigami.Units.smallSpacing
                                width: page.grpCountWidth
                                text: "count"
                                QQC2.ToolTip.text: page.shownGroups.length + " groups"
                                QQC2.ToolTip.visible: hovered
                                font.bold: true
                                horizontalAlignment: Text.AlignHCenter
                            }
                            Kirigami.Separator {
                                anchors.bottom: parent.bottom
                                width: parent.width
                                opacity: 0.35
                            }
                        }
                        QQC2.ScrollView {
                            id: grpScroll
                            // ширина полосы прокрутки: под неё шапка оставляет
                            // ровно столько же, сколько занимает список
                            readonly property int barW: QQC2.ScrollBar.vertical
                                && QQC2.ScrollBar.vertical.visible
                                ? QQC2.ScrollBar.vertical.width : 0
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            ListView {
                                id: grpList
                                model: page.shownGroups
                                delegate: QQC2.ItemDelegate {
                                    id: grpRow
                                    required property var modelData
                                    required property int index
                                    width: ListView.view.width
                                    // ТА ЖЕ ФОРМА, ЧТО У ОСНОВНОЙ ТАБЛИЦЫ:
                                    // высота строки, зебра, разделитель, метка
                                    // выделения справа — иначе две таблицы
                                    // рядом читаются как разные приложения.
                                    height: Kirigami.Units.gridUnit * 2.3
                                    padding: 0
                                    highlighted: page.groupPicked
                                                 && page.groupVal === String(modelData.value || "")
                                    background: Rectangle {
                                        color: grpRow.highlighted
                                               ? Qt.alpha(Kirigami.Theme.highlightColor, 0.20)
                                               : (grpRow.hovered
                                                  ? Qt.alpha(Kirigami.Theme.textColor, 0.07)
                                                  : (grpRow.index % 2 === 0
                                                     ? Kirigami.Theme.backgroundColor
                                                     : Kirigami.Theme.alternateBackgroundColor))
                                        Kirigami.Separator {
                                            anchors.bottom: parent.bottom
                                            width: parent.width
                                            opacity: 0.35
                                        }
                                        // метка выбранной группы — СЛЕВА, как
                                        // полоса критичности в ленте: справа
                                        // она обрывалась на полосе прокрутки и
                                        // выделение выглядело кривым
                                        Rectangle {
                                            anchors { left: parent.left; top: parent.top
                                                      bottom: parent.bottom }
                                            width: 3
                                            visible: grpRow.highlighted
                                            color: Kirigami.Theme.highlightColor
                                        }
                                    }
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
                                        page.syncWhere()
                                    }
                                    contentItem: RowLayout {
                                        spacing: 0
                                        // по колонке на каждое поле группировки
                                        Repeater {
                                            model: modelData.parts
                                                   ? modelData.parts
                                                   : [String(modelData.value)]
                                            delegate: QQC2.Label {
                                                required property var modelData
                                                required property int index
                                                Layout.preferredWidth: page.grpColWidth(index)
                                                // воздух внутри ячейки, иначе
                                                // текст наезжает на границу
                                                leftPadding: Kirigami.Units.smallSpacing
                                                rightPadding: Kirigami.Units.largeSpacing
                                                horizontalAlignment: Text.AlignLeft
                                                // ТО ЖЕ ФОРМАТИРОВАНИЕ, ЧТО В ЛЕНТЕ:
                                                // время — в местной зоне, адреса и
                                                // время моноширинным шрифтом
                                                text: String(modelData) === ""
                                                    ? "(empty)"
                                                    : (page.groupBy[index] === "ts"
                                                       ? Fmt.local(String(modelData))
                                                       : String(modelData))
                                                opacity: String(modelData) === "" ? 0.5 : 1
                                                elide: Text.ElideRight
                                                font.family: (page.groupBy[index] === "ts"
                                                              || String(page.groupBy[index]).indexOf("_ip") >= 0)
                                                             ? "monospace"
                                                             : Kirigami.Theme.defaultFont.family
                                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                            }
                                        }
                                        Item { Layout.fillWidth: true }
                                        QQC2.Label {
                                            text: modelData.n
                                            opacity: 0.75
                                            horizontalAlignment: Text.AlignHCenter
                                            rightPadding: Kirigami.Units.smallSpacing
                                            Layout.preferredWidth: page.grpCountWidth
                                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                // ГРАНИЦА ПЕРЕТАСКИВАЕТСЯ: сколько места отдать группам, а
                // сколько ленте, решает пользователь. Двойной клик возвращает
                // ширину «по содержимому».
                Item {
                    visible: page.groupBy.length > 0
                    Layout.fillHeight: true
                    Layout.preferredWidth: Kirigami.Units.smallSpacing * 2
                    Kirigami.Separator {
                        anchors.horizontalCenter: parent.horizontalCenter
                        height: parent.height
                    }
                    MouseArea {
                        anchors.fill: parent
                        anchors.leftMargin: -3
                        anchors.rightMargin: -3
                        cursorShape: Qt.SplitHCursor
                        preventStealing: true
                        property real sx: 0
                        property int sw: 0
                        onPressed: m => {
                            sx = mapToItem(page, m.x, 0).x
                            sw = page.grpUserWidth > 0 ? page.grpUserWidth
                                 : Math.min(page.width * 0.6, page.grpNaturalWidth)
                        }
                        onPositionChanged: m => {
                            if (!pressed) return
                            var dx = mapToItem(page, m.x, 0).x - sx
                            page.grpUserWidth = Math.max(
                                Kirigami.Units.gridUnit * 8,
                                Math.min(page.width - Kirigami.Units.gridUnit * 12, sw + dx))
                        }
                        onDoubleClicked: page.grpUserWidth = 0
                    }
                }

                // ---- РЕЖИМ «СТАТИСТИКА»: та же область, что и лента ----
                ColumnLayout {
                    visible: page.mode === "stats"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                QQC2.TextField {
                    Layout.fillWidth: true
                    placeholderText: "search a field or a value…"
                    text: page.statsFilter
                    onTextChanged: page.statsFilter = text
                }
                QQC2.ToolButton {
                    icon.name: "view-refresh"
                    QQC2.ToolTip.text: "Recount for the current query"
                    QQC2.ToolTip.visible: hovered
                    onClicked: page.loadStats()
                }
            }
            QQC2.Label {
                Layout.fillWidth: true
                opacity: 0.7
                wrapMode: Text.Wrap
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                text: {
                    if (!page.fieldStats) return "…"
                    var t = page.statsRows.length + " fields filled in of "
                            + page.fieldStats.all_fields + "  ·  " + page.fieldStats.total + " events"
                    // МОЛЧАЛИВОГО СРЕЗА НЕ БЫВАЕТ: если упёрлись в порог, так и пишем
                    if (page.fieldStats.truncated) t += "  ·  counted over the latest " + page.fieldStats.total
                    if (page.whereText) t += "  ·  query applied"
                    return t
                }
            }
            // СТАТИСТИКА — ОДНА ТАБЛИЦА: строка = поле, во второй колонке
            // сами значения в столбик. Длинный перечень не раскрывается на
            // всю страницу: клик по строке открывает панель, где он целиком.
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: Kirigami.Units.gridUnit * 24
                spacing: 0

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 0
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.rightMargin: Kirigami.Units.largeSpacing
                        spacing: Kirigami.Units.smallSpacing
                        QQC2.Label {
                            text: "Field"; font.bold: true; opacity: 0.6
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 12
                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                        }
                        QQC2.Label {
                            text: "Values"; font.bold: true; opacity: 0.6
                            Layout.fillWidth: true
                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                        }
                        QQC2.Label {
                            text: "Filled"; font.bold: true; opacity: 0.6
                            horizontalAlignment: Text.AlignRight
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                        }
                        QQC2.Label {
                            text: "Unique"; font.bold: true; opacity: 0.6
                            horizontalAlignment: Text.AlignRight
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                            font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                        }
                    }
                    Kirigami.Separator { Layout.fillWidth: true }
                    QQC2.ScrollView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        ListView {
                            model: page.statsRows
                            reuseItems: true
                            delegate: QQC2.ItemDelegate {
                                required property var modelData
                                required property int index
                                width: ListView.view.width
                                height: Math.max(Kirigami.Units.gridUnit * 2,
                                                 Math.min(Kirigami.Units.gridUnit * 5,
                                                          valsLbl.contentHeight
                                                          + Kirigami.Units.smallSpacing * 2))
                                onClicked: page.statsField = modelData.field
                                QQC2.ToolTip.text: page.valuesText(modelData).length > page.longValues
                                    ? "Click to see all values" : ""
                                QQC2.ToolTip.visible: hovered && QQC2.ToolTip.text !== ""
                                background: Rectangle {
                                    color: page.statsField === modelData.field
                                        ? Qt.alpha(Kirigami.Theme.highlightColor, 0.25)
                                        : (index % 2 ? Kirigami.Theme.alternateBackgroundColor
                                                     : Kirigami.Theme.backgroundColor)
                                }
                                contentItem: RowLayout {
                                    spacing: Kirigami.Units.smallSpacing
                                    QQC2.Label {
                                        Layout.preferredWidth: Kirigami.Units.gridUnit * 12
                                        Layout.alignment: Qt.AlignTop
                                        text: modelData.field
                                        elide: Text.ElideRight
                                        font.family: "monospace"
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                    // ЗНАЧЕНИЯ В СТОЛБИК прямо в строке
                                    QQC2.Label {
                                        id: valsLbl
                                        Layout.fillWidth: true
                                        Layout.alignment: Qt.AlignTop
                                        text: page.valuesText(modelData)
                                        maximumLineCount: 4
                                        elide: Text.ElideRight
                                        wrapMode: Text.NoWrap
                                        opacity: 0.85
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                    QQC2.Label {
                                        Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                                        Layout.alignment: Qt.AlignTop
                                        horizontalAlignment: Text.AlignRight
                                        text: modelData.percent + "%"
                                        opacity: 0.8
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                    QQC2.Label {
                                        Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                                        Layout.rightMargin: Kirigami.Units.largeSpacing
                                        Layout.alignment: Qt.AlignTop
                                        horizontalAlignment: Text.AlignRight
                                        text: modelData.unique
                                        opacity: 0.8
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                }
                            }
                        }
                    }
                }

                // ---- панель поля: все значения целиком ----
                Kirigami.Separator {
                    Layout.fillHeight: true
                    visible: page.statsField !== ""
                }
                ColumnLayout {
                    visible: page.statsField !== ""
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 20
                    Layout.fillHeight: true
                    spacing: 0
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.margins: Kirigami.Units.smallSpacing
                        QQC2.Label {
                            Layout.fillWidth: true
                            text: page.statsField
                            font.bold: true
                            font.family: "monospace"
                            elide: Text.ElideRight
                        }
                        QQC2.ToolButton {
                            icon.name: "window-close"
                            onClicked: page.statsField = ""
                        }
                    }
                    Kirigami.Separator { Layout.fillWidth: true }
                    QQC2.ScrollView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        ListView {
                            model: page.statsValues
                            reuseItems: true
                            delegate: QQC2.ItemDelegate {
                                required property var modelData
                                required property int index
                                width: ListView.view.width
                                height: Kirigami.Units.gridUnit * 2
                                QQC2.ToolTip.text: "Add to the query"
                                QQC2.ToolTip.visible: hovered
                                onClicked: {
                                    qbar.addCondition(page.statsField, "=",
                                                      String(modelData.value))
                                }
                                background: Rectangle {
                                    color: index % 2 ? Kirigami.Theme.alternateBackgroundColor
                                                     : Kirigami.Theme.backgroundColor
                                }
                                contentItem: RowLayout {
                                    spacing: Kirigami.Units.smallSpacing
                                    QQC2.Label {
                                        Layout.fillWidth: true
                                        text: modelData.value
                                        elide: Text.ElideRight
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                    QQC2.Label {
                                        Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                                        Layout.rightMargin: Kirigami.Units.largeSpacing
                                        horizontalAlignment: Text.AlignRight
                                        text: modelData.n
                                        opacity: 0.8
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

                Flickable {
                    id: hflick
                    visible: page.mode !== "stats"
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
                        model: page.feed.rows
                        // delegate recycling: the feed is reloaded on every
                        // refresh, and without reuse scrolling stutters
                        reuseItems: true
                        cacheBuffer: Kirigami.Units.gridUnit * 40
                        clip: true
                        headerPositioning: ListView.OverlayHeader
                        QQC2.ScrollBar.vertical: QQC2.ScrollBar {}

                        Kirigami.PlaceholderMessage {
                            anchors.centerIn: parent
                            width: parent.width - Kirigami.Units.gridUnit * 4
                            visible: tableView.count === 0
                            icon.name: "view-calendar-list"
                            text: "No events match"
                            explanation: "Every input whose output is type:events lands here."
                        }

                        header: Rectangle {
                            z: 3
                            width: tableView.width
                            height: hrow.implicitHeight + Kirigami.Units.smallSpacing * 2
                            color: Kirigami.Theme.alternateBackgroundColor
                            Row {
                                id: hrow
                                anchors.verticalCenter: parent.verticalCenter
                                Item { width: 8; height: 1 }
                                Repeater {
                                    model: page.visibleCols
                                    Item {
                                        width: page.colWidth(modelData)
                                        height: hlbl.implicitHeight
                                        property string col: modelData
                                        QQC2.Label {
                                            id: hlbl
                                            anchors.fill: parent
                                            anchors.rightMargin: sortIcon.visible ? 26 : 10
                                            leftPadding: Kirigami.Units.largeSpacing
                                            text: col
                                            font.bold: true
                                            elide: Text.ElideRight
                                        }
                                        // НАПРАВЛЕНИЕ СОРТИРОВКИ — ИКОНКОЙ,
                                        // как принято в таблицах: стрелка
                                        // читается быстрее символа в тексте.
                                        Kirigami.Icon {
                                            id: sortIcon
                                            anchors.right: parent.right
                                            anchors.rightMargin: Kirigami.Units.smallSpacing + 4
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: Kirigami.Units.iconSizes.small
                                            height: Kirigami.Units.iconSizes.small
                                            visible: page.sortCol === parent.col
                                            source: page.sortDesc ? "view-sort-descending"
                                                                  : "view-sort-ascending"
                                        }
                                        // СОРТИРОВКА ИДЁТ В ЗАПРОС: клик по
                                        // шапке дописывает ORDER BY — и в
                                        // набранный SQL, и в конструктор.
                                        TapHandler {
                                            onTapped: page.sortBy(parent.col)
                                        }
                                        Kirigami.Separator {
                                            anchors.right: parent.right
                                            anchors.top: parent.top
                                            anchors.bottom: parent.bottom
                                            opacity: 0.35
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
                                            onPressed: m => { sx = m.x; sw = page.colWidth(parent.col) }
                                            onPositionChanged: m => {
                                                if (pressed) page.setWidth(parent.col, sw + (m.x - sx))
                                            }
                                            onReleased: page.saveCfg()
                                        }
                                    }
                                }
                            }
                            Kirigami.Separator {
                                anchors.bottom: parent.bottom
                                width: parent.width
                            }
                        }

                        delegate: QQC2.ItemDelegate {
                            id: rowDel
                            width: tableView.width
                            height: Kirigami.Units.gridUnit * 2.3
                            property var rowData: modelData
                            highlighted: page.sel && page.sel._id === modelData._id
                            onClicked: page.sel = modelData
                            background: Rectangle {
                                // ВЫДЕЛЕНИЕ ЦВЕТОМ ПОДСВЕТКИ, а не серым:
                                // серый поверх зебры почти не читался
                                color: rowDel.highlighted
                                       ? Qt.alpha(Kirigami.Theme.highlightColor, 0.20)
                                       : (rowDel.hovered
                                          ? Qt.alpha(Kirigami.Theme.textColor, 0.07)
                                          : (index % 2 === 0 ? Kirigami.Theme.backgroundColor
                                                             : Kirigami.Theme.alternateBackgroundColor))
                                Kirigami.Separator {
                                    anchors.bottom: parent.bottom
                                    width: parent.width
                                    opacity: 0.35
                                }
                                // ВЫБРАННАЯ СТРОКА помечается полосой цвета
                                // подсветки: заливка сама по себе спорит с
                                // зеброй и с полосой критичности слева.
                                Rectangle {
                                    anchors { right: parent.right; top: parent.top
                                              bottom: parent.bottom }
                                    width: 3
                                    visible: rowDel.highlighted
                                    color: Kirigami.Theme.highlightColor
                                }
                            }
                            contentItem: Row {
                                Rectangle {
                                    width: 8
                                    height: rowDel.height
                                    color: page.sevColor(rowDel.rowData.event_severity)
                                    opacity: 0.85
                                }
                                Repeater {
                                    model: page.visibleCols
                                    Item {
                                        id: cell
                                        width: page.colWidth(modelData)
                                        height: rowDel.height
                                        property string col: modelData
                                        property string val: String(rowDel.rowData[modelData] ?? "")
                                        // ПОКАЗЫВАЕМ местное время, а в val
                                        // остаётся UTC: из него строятся
                                        // условия WHERE, а в базе время UTC
                                        property string display: cell.col === "ts"
                                                                 ? Fmt.local(cell.val) : cell.val
                                        QQC2.Label {
                                            anchors.fill: parent
                                            // воздух внутри ячейки
                                            anchors.rightMargin: cellHover.hovered
                                                                 ? 40 : Kirigami.Units.largeSpacing
                                            verticalAlignment: Text.AlignVCenter
                                            leftPadding: Kirigami.Units.largeSpacing
                                            text: cell.display
                                            elide: Text.ElideRight
                                            font.family: (cell.col === "ts"
                                                          || cell.col.indexOf("_ip") >= 0)
                                                         ? "monospace"
                                                         : Kirigami.Theme.defaultFont.family
                                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                                            color: cell.col === "event_outcome" && cell.val === "failure"
                                                   ? Kirigami.Theme.negativeTextColor
                                                   : Kirigami.Theme.textColor
                                        }
                                        HoverHandler { id: cellHover }
                                        // Клик по ЯЧЕЙКЕ выделяет строку —
                                        // раньше выделение зависело от того,
                                        // попал ли клик мимо содержимого.
                                        // Двойной клик КОПИРУЕТ значение.
                                        TapHandler {
                                            acceptedButtons: Qt.LeftButton
                                            onSingleTapped: page.sel = rowDel.rowData
                                            onDoubleTapped: {
                                                page.sel = rowDel.rowData
                                                page.copyValue(cell.val)
                                            }
                                        }
                                        // + добавить значение в фильтр, − исключить
                                        // CELL ACTIONS ARE LAZY.
                                        // Each cell used to build three
                                        // buttons and a ten-item Menu up
                                        // front: 50 rows x 8 columns is
                                        // ~4000 objects, and that is what
                                        // made reload() take seconds.
                                        // Now nothing exists until hover.
                                        Loader {
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.rightMargin: 2
                                            active: cellHover.hovered && cell.val !== ""
                                            visible: active
                                            sourceComponent: Component {
                                            Row {
                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                anchors.rightMargin: 2
                                                spacing: 1
                                                QQC2.ToolButton {
                                                    implicitWidth: Kirigami.Units.gridUnit * 1.1
                                                    implicitHeight: Kirigami.Units.gridUnit * 1.1
                                                    text: "+"
                                                    QQC2.ToolTip.text: "Include " + cell.col + " = " + cell.val
                                                    QQC2.ToolTip.visible: hovered
                                                    onClicked: page.addCond(cell.col, "=", cell.val)
                                                }
                                                QQC2.ToolButton {
                                                    implicitWidth: Kirigami.Units.gridUnit * 1.1
                                                    implicitHeight: Kirigami.Units.gridUnit * 1.1
                                                    text: "−"
                                                    QQC2.ToolTip.text: "Exclude " + cell.col + " = " + cell.val
                                                    QQC2.ToolTip.visible: hovered
                                                    onClicked: page.addCond(cell.col, "<>", cell.val)
                                                }
                                                // остальные операторы сравнения (как в RQL)
                                                QQC2.ToolButton {
                                                    implicitWidth: Kirigami.Units.gridUnit * 1.1
                                                    implicitHeight: Kirigami.Units.gridUnit * 1.1
                                                    text: "⋯"
                                                    QQC2.ToolTip.text: "More operators"
                                                    QQC2.ToolTip.visible: hovered
                                                    onClicked: opMenu.popup()
                                                    QQC2.Menu {
                                                        id: opMenu
                                                        QQC2.MenuItem {
                                                            text: "contains  (LIKE)"
                                                            onTriggered: page.addCond(cell.col, "LIKE", cell.val)
                                                        }
                                                        QQC2.MenuItem {
                                                            text: "not contains  (NOT LIKE)"
                                                            onTriggered: page.addCond(cell.col, "NOT LIKE", cell.val)
                                                        }
                                                        QQC2.MenuSeparator {}
                                                        QQC2.MenuItem {
                                                            text: "greater  >"
                                                            onTriggered: page.addCond(cell.col, ">", cell.val)
                                                        }
                                                        QQC2.MenuItem {
                                                            text: "less  <"
                                                            onTriggered: page.addCond(cell.col, "<", cell.val)
                                                        }
                                                        QQC2.MenuItem {
                                                            text: "greater or equal  >="
                                                            onTriggered: page.addCond(cell.col, ">=", cell.val)
                                                        }
                                                        QQC2.MenuItem {
                                                            text: "less or equal  <="
                                                            onTriggered: page.addCond(cell.col, "<=", cell.val)
                                                        }
                                                        QQC2.MenuSeparator {}
                                                        QQC2.MenuItem {
                                                            text: "is empty  (IS NULL)"
                                                            onTriggered: page.addCond(cell.col, "IS NULL", "")
                                                        }
                                                        QQC2.MenuItem {
                                                            text: "is not empty  (IS NOT NULL)"
                                                            onTriggered: page.addCond(cell.col, "IS NOT NULL", "")
                                                        }
                                                        QQC2.MenuSeparator {}
                                                        QQC2.MenuItem {
                                                            // подсеть: RQL-приём `ip IN '10.0.0.0/8'`
                                                            text: "same /24 subnet"
                                                            enabled: cell.col.indexOf("_ip") >= 0
                                                            onTriggered: {
                                                                var o = cell.val.split(".")
                                                                if (o.length === 4)
                                                                    page.addCond(cell.col, "IN",
                                                                        o[0] + "." + o[1] + "." + o[2] + ".0/24")
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                            }
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
                    }
                }
            }

            // ---- футер ----
            QQC2.ToolBar {
                Layout.fillWidth: true
                RowLayout {
                    anchors.fill: parent
                    spacing: Kirigami.Units.smallSpacing
                    QQC2.Label {
                        opacity: 0.7
                        text: page.feed.total + " events" +
                              (page.stats.total ? "  of " + page.stats.total : "")
                    }
                    Item { Layout.fillWidth: true }
                    QQC2.ToolButton {
                        icon.name: "go-previous"; enabled: page.pageIndex > 0
                        onClicked: { page.pageIndex--; page.reload() }
                    }
                    QQC2.Label {
                        text: (page.pageIndex + 1) + " / " +
                              Math.max(1, Math.ceil(page.feed.total / page.pageLimit))
                    }
                    QQC2.ToolButton {
                        icon.name: "go-next"
                        enabled: (page.pageIndex + 1) * page.pageLimit < page.feed.total
                        onClicked: { page.pageIndex++; page.reload() }
                    }
                    QQC2.ComboBox {
                        // сколько строк показывать; «all» = без ограничения
                model: [{ t: "50", v: 50 }, { t: "100", v: 100 }, { t: "200", v: 200 },
                        { t: "500", v: 500 }, { t: "1000", v: 1000 },
                        { t: "all", v: 0 }]
                textRole: "t"
                valueRole: "v"
                        implicitWidth: Kirigami.Units.gridUnit * 6
                        QQC2.ToolTip.text: "Rows per page"
                        QQC2.ToolTip.visible: hovered
                        onActivated: {
                            page.pageLimit = currentValue > 0 ? currentValue : 100000
                            page.pageIndex = 0
                            page.reload()
                        }
                    }
                    QQC2.ToolButton {
                        icon.name: "view-refresh"; onClicked: page.reload()
                        QQC2.ToolTip.text: "Refresh"; QQC2.ToolTip.visible: hovered
                    }
                    QQC2.ToolButton {
                        icon.name: page.mode === "stats" ? "view-list-details"
                                                         : "office-chart-bar"
                        text: page.mode === "stats" ? "Events" : "Statistics"
                        display: QQC2.AbstractButton.TextBesideIcon
                        checkable: true
                        checked: page.mode === "stats"
                        QQC2.ToolTip.text: page.mode === "stats"
                            ? "Back to the event list"
                            : "Which fields are filled in, and with what — for this query"
                        QQC2.ToolTip.visible: hovered
                        onClicked: {
                            // СТАТИСТИКА — РЕЖИМ ТОЙ ЖЕ ТАБЛИЦЫ, а не окно
                            // поверх: запрос один, меняется только взгляд.
                            if (page.mode === "stats") { page.mode = "feed"; return }
                            page.mode = "stats"
                            page.loadStats()
                        }
                    }
            // ВЫБОР КОЛОНОК УБРАН: колонки задаёт SELECT в строке запроса
                }
            }
        }

        // ---- СОХРАНЁННЫЕ ЗАПРОСЫ ----
        SidePanel {
            id: savedPanel
            title: "Saved queries"
            iconName: "bookmarks"
            panelWidth: Kirigami.Units.gridUnit * 30
            open: false
            onCloseRequested: open = false

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                // дерево каталогов: «Все» + каталоги экспертизы
                ColumnLayout {
                    // ширина фиксирована, иначе колонка съедала всю панель и
                    // сами запросы оставались без места
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 11
                    Layout.maximumWidth: Kirigami.Units.gridUnit * 11
                    Layout.fillWidth: false
                    Layout.fillHeight: true
                    spacing: 0
                    QQC2.ItemDelegate {
                        Layout.fillWidth: true
                        height: Kirigami.Units.gridUnit * 2
                        highlighted: page.savedDir === ""
                        onClicked: page.savedDir = ""
                        contentItem: RowLayout {
                            Kirigami.Icon {
                                source: "folder-open"
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                            }
                            QQC2.Label {
                                Layout.fillWidth: true
                                text: "All queries"
                                elide: Text.ElideRight
                            }
                            QQC2.Label {
                                text: page.savedCount("")
                                opacity: 0.6
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                        }
                    }
                    QQC2.ScrollView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        ListView {
                            model: page.dirsList
                            reuseItems: true
                            delegate: QQC2.ItemDelegate {
                                required property var modelData
                                width: ListView.view.width
                                height: Kirigami.Units.gridUnit * 2
                                highlighted: page.savedDir === String(modelData)
                                onClicked: page.savedDir = String(modelData)
                                contentItem: RowLayout {
                                    Kirigami.Icon {
                                        source: "folder"
                                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                    }
                                    QQC2.Label {
                                        Layout.fillWidth: true
                                        text: modelData
                                        elide: Text.ElideRight
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                    QQC2.Label {
                                        text: page.savedCount(String(modelData))
                                        opacity: 0.6
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                }
                            }
                        }
                    }
                }
                Kirigami.Separator { Layout.fillHeight: true }

                // сами запросы выбранного каталога (или всех)
                QQC2.ScrollView {
                    Layout.fillWidth: true
                    Layout.minimumWidth: Kirigami.Units.gridUnit * 12
                    Layout.fillHeight: true
                    clip: true
                    ListView {
                        model: page.savedShown
                        reuseItems: true
                        section.property: page.savedDir === "" ? "dir" : ""
                        section.delegate: Kirigami.ListSectionHeader {
                            required property string section
                            width: ListView.view.width
                            label: section
                        }
                        delegate: QQC2.ItemDelegate {
                            required property var modelData
                            required property int index
                            width: ListView.view.width
                            height: Kirigami.Units.gridUnit * 3
                            onClicked: {
                                page.whereText = modelData.sql
                                qbar.builderMode = false
                                qbar.manualText = modelData.sql
                                page.queryText = modelData.sql
                                page.pageIndex = 0
                                page.reload()
                                savedPanel.open = false
                            }
                            background: Rectangle {
                                color: index % 2 ? Kirigami.Theme.alternateBackgroundColor
                                                 : Kirigami.Theme.backgroundColor
                            }
                            contentItem: RowLayout {
                                spacing: Kirigami.Units.smallSpacing
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0
                                    QQC2.Label {
                                        Layout.fillWidth: true
                                        text: modelData.title
                                        elide: Text.ElideRight
                                    }
                                    QQC2.Label {
                                        Layout.fillWidth: true
                                        text: modelData.sql
                                        elide: Text.ElideRight
                                        opacity: 0.6
                                        font.family: "monospace"
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                    }
                                }
                                QQC2.ToolButton {
                                    icon.name: "edit-delete"
                                    implicitWidth: Kirigami.Units.gridUnit * 1.8
                                    implicitHeight: Kirigami.Units.gridUnit * 1.8
                                    QQC2.ToolTip.text: "Delete"
                                    QQC2.ToolTip.visible: hovered
                                    onClicked: {
                                        backend.deleteQuery(modelData.ref)
                                        page.reloadSaved()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // ---- детали события ----
        SidePanel {
            id: details
            title: "Event"
            iconName: "view-calendar-list"
            panelWidth: Kirigami.Units.gridUnit * 24
            open: page.sel !== null && !colPanel.open
            onCloseRequested: page.sel = null

            // ПРОЦЕСС СОБЫТИЯ ЕЩЁ ЖИВ — можно посмотреть его в графе:
            // кто его запустил, что он открыл, куда ходит.
            QQC2.Button {
                Layout.fillWidth: true
                visible: page.sel && page.eventProcess(page.sel).alive
                icon.name: "distribute-graph-directed"
                text: "Open process graph"
                QQC2.ToolTip.text: page.sel
                    ? "PID " + page.sel.process_pid + " — "
                      + page.liveCommand(page.sel.process_pid)
                    : ""
                QQC2.ToolTip.visible: hovered
                onClicked: root.focusProcess(page.sel.process_pid)
            }
            QQC2.Label {
                Layout.fillWidth: true
                visible: page.sel && String(page.sel.process_pid || "") !== ""
                         && !page.eventProcess(page.sel).alive
                text: "Process " + (page.sel ? page.sel.process_pid : "")
                      + (page.sel && page.sel.process_name
                         ? " (" + page.sel.process_name + ")" : "") + " is gone"
                opacity: 0.6
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }

            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                ColumnLayout {
                    width: details.panelWidth - Kirigami.Units.largeSpacing * 2
                    spacing: Kirigami.Units.smallSpacing
                    Repeater {
                        model: page.fieldGroups
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            property var filled: {
                                var r = []
                                if (!page.sel) return r
                                for (var i = 0; i < modelData.fields.length; i++) {
                                    var f = modelData.fields[i]
                                    var v = page.sel[f.name]
                                    if (v !== undefined && v !== null && String(v) !== "") {
                                        // время показываем местное (в базе UTC)
                                        var sv = (f.name === "ts" || f.name === "ingested")
                                                 ? Fmt.local(v) : String(v)
                                        r.push({ n: f.name, v: sv, e: f.ecs })
                                    }
                                }
                                return r
                            }
                            visible: filled.length > 0
                            Kirigami.ListSectionHeader {
                                Layout.fillWidth: true
                                label: modelData.group
                            }
                            Repeater {
                                model: parent.filled
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.smallSpacing
                                    QQC2.Label {
                                        text: modelData.n
                                        opacity: 0.6
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                                        Layout.alignment: Qt.AlignTop
                                        elide: Text.ElideRight
                                        QQC2.ToolTip.text: modelData.e ? "ECS: " + modelData.e : modelData.n
                                        QQC2.ToolTip.visible: fieldHover.hovered
                                        HoverHandler { id: fieldHover }
                                    }
                                    QQC2.Label {
                                        Layout.fillWidth: true
                                        text: modelData.v
                                        wrapMode: Text.WrapAnywhere
                                        font.family: "monospace"
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                    // «Исследовать»: прыжок в State с фильтром
                                    QQC2.ToolButton {
                                        visible: page.exploreMap[modelData.n] !== undefined
                                        icon.name: "search"
                                        implicitWidth: Kirigami.Units.gridUnit * 1.4
                                        implicitHeight: Kirigami.Units.gridUnit * 1.4
                                        QQC2.ToolTip.visible: hovered
                                        QQC2.ToolTip.text: {
                                            var m = page.exploreMap[modelData.n]
                                            return m ? "Explore in State → " + m.table : ""
                                        }
                                        onClicked: {
                                            var m = page.exploreMap[modelData.n]
                                            if (m) root.focusState(m.table, m.col, modelData.v)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // ---- выбор колонок ----
        SidePanel {
            id: colPanel
            title: "Columns"
            iconName: "view-table-of-contents-ltr"
            panelWidth: Kirigami.Units.gridUnit * 16
            onCloseRequested: open = false

            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                ColumnLayout {
                    width: colPanel.panelWidth - Kirigami.Units.largeSpacing * 2
                    spacing: 0
                    Kirigami.SearchField {
                        Layout.fillWidth: true
                        placeholderText: "search a field…"
                        text: page.colSearch
                        onTextChanged: page.colSearch = text
                    }
                    QQC2.Label {
                        Layout.fillWidth: true
                        text: page.visibleCols.length + " of " + page.allCols.length + " shown"
                              + (page.colSearch !== ""
                                 ? "  ·  " + page.shownColChoices.length + " found" : "")
                        opacity: 0.6
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                    Repeater {
                        model: page.shownColChoices
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
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                opacity: page.hiddenCols.includes(modelData) ? 0.5 : 1
                            }
                            QQC2.ToolButton {
                                icon.name: "go-up"
                                // порядок считаем по ПОЛНОМУ списку: при поиске
                                // индекс в отфильтрованном ничего не значит
                                enabled: page.colOrder.indexOf(modelData) > 0
                                onClicked: page.moveCol(modelData, -1)
                            }
                            QQC2.ToolButton {
                                icon.name: "go-down"
                                enabled: page.colOrder.indexOf(modelData)
                                         < page.colOrder.length - 1
                                onClicked: page.moveCol(modelData, 1)
                            }
                        }
                    }
                }
            }
        }

        // ---- ЦЕПОЧКИ: слева список, справа СОБЫТИЯ ЦЕПОЧКИ ----
        // События показываются той же таблицей и той же боковой панелью, что
        // и обычная лента: цепочка — это не отдельный «дешёвый» список, а
        // тот же просмотр событий, только отфильтрованный по истории.
        ColumnLayout {
            visible: page.mode === "chains"
            Layout.preferredWidth: Kirigami.Units.gridUnit * 22
            Layout.fillHeight: true
            spacing: 0

            QQC2.Label {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                wrapMode: Text.WordWrap
                opacity: 0.75
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                text: page.chains
                      ? (page.chains.total + " chains · linked "
                         + page.chains.covered_pct + "% of events, strong links "
                         + page.chains.strong_pct + "%")
                      : ""
            }
            QQC2.ScrollView {
                id: chainScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                ListView {
                    model: page.chains ? (page.chains.chains || []) : []
                    spacing: 2
                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        width: chainScroll.availableWidth
                        height: chCol.implicitHeight + Kirigami.Units.smallSpacing
                        color: page.chainId === modelData.id
                               ? Qt.alpha(Kirigami.Theme.highlightColor, 0.3)
                               : (index % 2 ? Kirigami.Theme.alternateBackgroundColor
                                            : Kirigami.Theme.backgroundColor)
                        Rectangle {
                            width: 4; height: parent.height
                            color: page.sevColor(modelData.severity)
                        }
                        ColumnLayout {
                            id: chCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.leftMargin: Kirigami.Units.largeSpacing
                            anchors.margins: 3
                            spacing: 0
                            RowLayout {
                                Layout.fillWidth: true
                                QQC2.Label {
                                    Layout.fillWidth: true
                                    text: modelData.title
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                                QQC2.Label {
                                    text: modelData.count + " ev."
                                    opacity: 0.7
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                }
                            }
                            QQC2.Label {
                                Layout.fillWidth: true
                                opacity: 0.65
                                elide: Text.ElideRight
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                text: "from " + String(modelData.start).replace("T", " ").substring(0, 16)
                                      + " · " + (modelData.categories || []).join(", ")
                            }
                            QQC2.Label {
                                Layout.fillWidth: true
                                opacity: 0.5
                                elide: Text.ElideRight
                                font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                                // ЧЕМ связаны события: видно надёжность
                                text: {
                                    var l = modelData.links || {}, p = []
                                    for (var k in l) p.push(k + " " + l[k])
                                    return "link: " + p.join(", ")
                                }
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                page.chainId = modelData.id
                                var d = backend.chainDetail(modelData.id)
                                // подменяем ленту событиями цепочки: та же
                                // таблица, те же колонки, та же панель деталей
                                page.feed = { rows: d.steps || [],
                                              total: d.count || 0, error: "" }
                                page.sel = null
                            }
                        }
                    }
                }
            }
        }

        Kirigami.Separator {
            visible: page.mode === "chains"
            Layout.fillHeight: true
        }


    }

    // ---- история SQL: топ-10 последних, а при вводе — похожие из ВСЕЙ истории ----
    QQC2.Popup {
        id: histPopup
        // там же, где и сохранённые: левый угол под строкой запроса
        x: 0
        y: Kirigami.Units.gridUnit * 9
        width: Math.min(page.width * 0.6, Kirigami.Units.gridUnit * 40)
        padding: 2
        property var items: []
        property bool filtered: false      // список похожих, а не просто недавние
        function show(text) {
            var t = (text || "").trim()
            filtered = t !== ""
            items = t === "" ? backend.eventSqlHistory(10)
                             : backend.eventSqlSuggest(t, 8)
            if (items && items.length > 0) open(); else close()
        }
        contentItem: ColumnLayout {
            spacing: 0
            QQC2.Label {
                Layout.fillWidth: true
                Layout.margins: 4
                text: histPopup.filtered ? "Similar queries" : "Recent queries"
                opacity: 0.6
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
            Repeater {
                model: histPopup.items
                QQC2.ItemDelegate {
                    Layout.fillWidth: true
                    contentItem: QQC2.Label {
                        text: modelData
                        elide: Text.ElideRight
                        font.family: "monospace"
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                    onClicked: {
                        page.whereText = modelData
                        qbar.builderMode = false
                        qbar.manualText = modelData
                        page.queryText = modelData
                        histPopup.close()
                        page.pageIndex = 0
                        page.reload()
                    }
                }
            }
        }
    }

    // ---- сохранение запроса: имя + каталог (каталог можно создать тут же) ----
    Kirigami.Dialog {
        id: saveDialog
        title: "Save query"
        preferredWidth: Kirigami.Units.gridUnit * 26
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        onAccepted: {
            var d = (newDir.text.trim() !== "") ? newDir.text.trim()
                                                : String(dirBox.currentText || "general")
            var ref = backend.saveQuery(d, saveName.text, page.whereText, saveDesc.text)
            if (String(ref).indexOf("error:") !== 0) {
                page.reloadSaved()
                newDir.text = ""
            }
        }
        ColumnLayout {
            spacing: Kirigami.Units.smallSpacing
            QQC2.Label {
                Layout.fillWidth: true
                text: "Stored in expertise/queries/<folder>/ — outside fedora, yours to edit."
                opacity: 0.7
                wrapMode: Text.WordWrap
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
            QQC2.TextField {
                id: saveName
                Layout.fillWidth: true
                placeholderText: "Query name"
            }
            QQC2.TextField {
                id: saveDesc
                Layout.fillWidth: true
                placeholderText: "Description (optional)"
            }
            RowLayout {
                Layout.fillWidth: true
                QQC2.ComboBox {
                    id: dirBox
                    Layout.fillWidth: true
                    model: page.dirsList
                }
                QQC2.TextField {
                    id: newDir
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                    placeholderText: "or new folder"
                }
            }
            QQC2.Label {
                Layout.fillWidth: true
                text: page.whereText
                font.family: "monospace"
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                opacity: 0.75
                wrapMode: Text.WrapAnywhere
            }
        }
    }

    // ---- СОХРАНЁННЫЕ ЗАПРОСЫ — БОКОВАЯ ПАНЕЛЬ ----
    // Это объекты экспертизы (expertise/queries/<каталог>), поэтому и
    // показываем их как экспертизу: слева дерево каталогов, справа запросы.
    // Клик по КОРНЮ показывает запросы всех каталогов сразу.
    property string savedDir: ""          // "" = все каталоги
    readonly property var savedShown: {
        if (savedDir === "") return savedList
        var out = []
        for (var i = 0; i < savedList.length; i++)
            if (String(savedList[i].dir) === savedDir) out.push(savedList[i])
        return out
    }
    function savedCount(dir) {
        if (dir === "") return savedList.length
        var n = 0
        for (var i = 0; i < savedList.length; i++)
            if (String(savedList[i].dir) === dir) n++
        return n
    }


    // ---- выбор поля группировки с поиском (полей 87, списком неудобно) ----



    // Разбор начинают не с чтения ленты, а с вопроса «какие поля вообще
    // заполнены и какими значениями» — так делают в зрелых SIEM. Считается
    // ОТНОСИТЕЛЬНО ТЕКУЩЕГО ЗАПРОСА, поэтому сузил выборку — статистика
    // пересчиталась под неё. Клик по значению добавляет его в условие.



    // ПОДТВЕРЖДЕНИЕ КОПИРОВАНИЯ: без него двойной клик выглядит как «ничего
    // не произошло».
    Kirigami.InlineMessage {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Kirigami.Units.gridUnit * 3
        z: 100
        width: Math.min(parent.width * 0.6, Kirigami.Units.gridUnit * 30)
        visible: page.copied !== ""
        type: Kirigami.MessageType.Positive
        text: "Copied: " + page.copied
    }

}

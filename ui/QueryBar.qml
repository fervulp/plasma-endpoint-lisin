import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
// сетка месяца: в стиле org.kde.desktop её нет, берём из базового набора
import QtQuick.Controls.Basic as CB
import org.kde.kirigami as Kirigami

// ЕДИНАЯ СТРОКА ЗАПРОСА для всех таблиц приложения.
//
// Устройство простое: запрос ВСЕГДА начинается с ВЫБОРКИ (SELECT) — теми
// полями, которые таблица показывает прямо сейчас. Всё остальное —
// фильтр, сортировка, группировка, уникальные, вычисляемое поле —
// ДОБАВЛЯЕТСЯ по одному кнопкой «+» и строится ОТНОСИТЕЛЬНО выборки.
// Кнопка «Reset» возвращает выборку к исходной.
//
// Два способа задать одно и то же:
//   * НАКЛИКАТЬ — конструктор (по умолчанию);
//   * НАБРАТЬ — SQL руками.
// Переключение запрос не теряет.
//
// Компонент НИЧЕГО не исполняет: собирает спецификацию и отдаёт сигналом.
// Кто и как применит (SQL к базе или фильтрация в памяти) — дело хозяина
// таблицы. Поэтому одна строка работает и над state.db, и над списком,
// посчитанным в Python.
Item {
    id: bar
    implicitHeight: col.implicitHeight

    // поля таблицы: [{ name, title }] — что вообще можно выбрать
    property var fields: []
    // поля, которые таблица показывает СЕЙЧАС — с них начинается выборка
    property var defaultSelect: []
    // текущая спецификация запроса
    // where: [{field, op, value, join}] — join связывает с ПРЕДЫДУЩИМ условием
    // (AND по умолчанию; OR / AND NOT / OR NOT). orderBy: [{field, desc}] —
    // сортировок и группировок может быть несколько, как в SQL.
    property var spec: ({ where: [], select: [], groupBy: [],
                          orderBy: [], distinct: false, computed: [] })
    // какие части запроса добавлены кнопкой «+»
    property var clauses: []
    property bool builderMode: true      // накликать (по умолчанию) или набрать
    property string manualText: ""       // то, что набрали руками
    property string placeholder: "SELECT * WHERE field = 'value'"

    signal applied(var spec, string sql)

    // есть несохранённые правки — Run подсвечен
    property bool dirty: false
    // снимок исходного запроса: к нему возвращает сброс
    property var initialQuery: null
    function snapshot() {
        var w = []
        for (var i = 0; i < spec.where.length; i++) {
            var c = spec.where[i]
            // у относительной границы сравниваем смещение, а не саму дату
            w.push(c.ago ? { field: c.field, op: c.op, join: c.join, ago: c.ago }
                         : c)
        }
        return JSON.stringify({ w: w, s: spec.select, g: spec.groupBy,
                                o: spec.orderBy, d: spec.distinct,
                                c: spec.computed, cl: clauses, m: manualText,
                                q: quickText })
    }
    function markBaseline() { initialQuery = snapshot() }

    // состояние запроса целиком — для сохранения между переходами
    function exportState() {
        return JSON.stringify({ w: spec.where, s: spec.select, g: spec.groupBy,
                                o: spec.orderBy, d: spec.distinct,
                                c: spec.computed, cl: clauses,
                                m: manualText, b: builderMode, q: quickText,
                                init: initialQuery })
    }
    function importState(text) {
        if (!text) return false
        var st
        try { st = JSON.parse(text) } catch (e) { return false }
        if (!st || !st.s || !st.s.length) return false
        spec = { where: st.w || [], select: st.s || [], groupBy: st.g || [],
                 orderBy: st.o || [], distinct: !!st.d, computed: st.c || [] }
        clauses = st.cl || []
        manualText = st.m || ""
        quickText = st.q || ""
        builderMode = st.b !== false
        initialQuery = st.init || null
        dirty = false
        apply()                 // вернулись — запрос уже выполнен
        return true
    }

    // запрос отличается от исходного — тогда и только тогда есть что сбрасывать
    readonly property bool changed: {
        // перечисляем поля явно, чтобы привязка пересчитывалась при их правке
        var _ = [spec.where.length, spec.select.length, spec.groupBy.length,
                 spec.orderBy.length, spec.distinct, spec.computed.length,
                 clauses.length, manualText, quickText]
        if (initialQuery !== null) return snapshot() !== initialQuery
        if (spec.where.length || clauses.length || manualText !== "") return true
        if (spec.select.length !== defaultSelect.length) return true
        for (var i = 0; i < spec.select.length; i++)
            if (spec.select[i] !== defaultSelect[i]) return true
        return false
    }
    property bool editingCalc: false
    // для проверки рендером: сколько условий реально нарисовано
    readonly property int chipCount: repWhere.count

    // Поля, ОТНОСИТЕЛЬНО которых строятся фильтр, группировка и сортировка:
    // те, что в выборке; если выборка пуста — все.
    readonly property var activeFields: {
        if (spec.select.length) return spec.select
        return fields.map(function (f) { return f.name })
    }

    // ПСЕВДОПОЛЕ «all» — искать во всех полях сразу
    readonly property string anyField: "all fields"
    // имена всех полей — для выбора с поиском; «all» первым
    readonly property var allFieldNames: {
        var out = [anyField]
        var f = fields
        for (var i = 0; i < f.length; i++) out.push(f[i].name)
        return out
    }
    // СНАЧАЛА ПОЛЯ ВЫБОРКИ, ПОТОМ ОСТАЛЬНЫЕ. Группировать и сортировать можно
    // по любому полю, даже если его нет в SELECT (в SQL это законно), но
    // выбранные показываем первыми — по ним группируют чаще всего.
    readonly property var fieldsPreferSelected: {
        var out = spec.select.slice()
        var all = allFieldNames
        for (var i = 0; i < all.length; i++)
            if (out.indexOf(all[i]) < 0) out.push(all[i])
        return out
    }
    // поле, выбранное в строке фильтра
    property string filterField: ""
    // БЫСТРЫЙ ПОИСК ПО ВСЕМ ПОЛЯМ: главное действие строки. Это обычное
    // условие «all fields MATCH …», просто у него своё поле ввода — так
    // «найти что угодно» не требует ни конструктора, ни знания SQL.
    property string quickText: ""
    // ВЫСОТА ДВУХ СТРОК ЧИПОВ: длинный перечень не растягивает панель —
    // что не поместилось, открывается кнопкой «…» отдельным окном.
    readonly property int twoRows: Kirigami.Units.gridUnit * 4
                                   + Kirigami.Units.smallSpacing
    // какой перечень открыт в окне «показать всё»
    property string moreKind: ""
    // кнопки хозяина страницы (история, сохранить, сохранённые) — слева
    // в строке управления запросом
    property alias hostTools: hostToolsRow.data

    readonly property var operators: ["MATCH", "NOT MATCH", "=", "<>",
                                      "LIKE", "NOT LIKE",
                                      ">", "<", ">=", "<=",
                                      "IS NULL", "IS NOT NULL"]
    function noValue(op) { return op === "IS NULL" || op === "IS NOT NULL" }
    // кавычка в значении не должна разрывать запрос
    function quote(v) { return "'" + String(v).replace(/'/g, "''") + "'" }
    // одно условие -> кусок SQL
    function condSql(field, op, value) {
        // «all fields» разворачивается в OR по всем полям таблицы
        if (field === anyField) {
            var parts = []
            for (var i = 0; i < fields.length; i++)
                parts.push(condSql(fields[i].name, op, value))
            return parts.length ? "(" + parts.join(" OR ") + ")" : ""
        }
        if (noValue(op)) return '"' + field + '" ' + op
        if (op === "MATCH")
            return '"' + field + '" LIKE ' + quote("%" + value + "%")
        if (op === "NOT MATCH")
            return '"' + field + '" NOT LIKE ' + quote("%" + value + "%")
        return '"' + field + '" ' + op + " " + quote(value)
    }
    readonly property var joiners: ["AND", "OR", "AND NOT", "OR NOT"]

    // ПОЛЕ ВРЕМЕНИ распознаём по имени — признак структурный, не список
    // конкретных полей: подойдёт любой таблице, где время названо привычно.
    function isTimeField(n) {
        if (!n) return false
        n = String(n).toLowerCase()
        return n === "ts" || n === "time" || n === "date"
               || /(^|_)(ts|time|date|at|changed|issued|installed|seen|login)$/.test(n)
    }
    // Готовые промежутки для такого поля. Границу считаем СЕЙЧАС и записываем
    // абсолютным временем: «за последний час» остаётся тем самым часом и не
    // уползает при следующем открытии.
    readonly property var timePresets: [
        { t: "Last 5 minutes",  ms: 300000 },
        { t: "Last 15 minutes", ms: 900000 },
        { t: "Last hour",       ms: 3600000 },
        { t: "Last 24 hours",   ms: 86400000 },
        { t: "Last 7 days",     ms: 604800000 },
        { t: "Last 30 days",    ms: 2592000000 }
    ]
    function agoIso(ms) {
        return new Date(Date.now() - ms).toISOString().replace(/\.\d+Z$/, "Z")
    }
    // ПРОИЗВОЛЬНЫЙ ПРОМЕЖУТОК: «столько-то минут/часов/дней/месяцев/лет назад».
    // Месяцы и годы считаем календарно (в месяце не 30 суток), поэтому не
    // через миллисекунды, а сдвигом даты.
    readonly property var timeUnits: ["seconds", "minutes", "hours", "days",
                                      "weeks", "months", "years"]
    // смещение в миллисекундах — им помечается относительная граница, чтобы
    // сброс запроса пересчитывал её от «сейчас»
    function agoMs(n, unit) {
        n = Math.max(0, Number(n) || 0)
        var k = { seconds: 1000, minutes: 60000, hours: 3600000,
                  days: 86400000, weeks: 604800000,
                  months: 2592000000, years: 31536000000 }
        return n * (k[unit] || 0)
    }
    // ЧЕЛОВЕЧЕСКОЕ ВРЕМЯ для кнопок: «22 Jul 2026 17:59» в местной зоне
    // (в базе UTC — перевод делает граница интерфейса)
    readonly property var monthNames: ["Jan","Feb","Mar","Apr","May","Jun",
                                       "Jul","Aug","Sep","Oct","Nov","Dec"]
    function pad2(n) { return n < 10 ? "0" + n : String(n) }
    function humanTime(iso) {
        if (!iso) return "not set"
        var d = new Date(iso)
        if (isNaN(d.getTime())) return String(iso)
        return d.getDate() + " " + monthNames[d.getMonth()] + " " + d.getFullYear()
               + "  " + pad2(d.getHours()) + ":" + pad2(d.getMinutes())
    }
    // «за последние N единиц» — задаёт нижнюю границу и снимает верхнюю
    function applyLast(n, unit) {
        if (editIndex < 0) return
        setCond(editIndex, "op", ">=")
        setCond(editIndex, "value", agoUnits(n, unit))
        setCond(editIndex, "ago", agoMs(n, unit))
    }

    function agoUnits(n, unit) {
        var d = new Date()
        n = Math.max(0, Number(n) || 0)
        if (unit === "seconds") d.setSeconds(d.getSeconds() - n)
        else if (unit === "minutes") d.setMinutes(d.getMinutes() - n)
        else if (unit === "hours") d.setHours(d.getHours() - n)
        else if (unit === "days") d.setDate(d.getDate() - n)
        else if (unit === "weeks") d.setDate(d.getDate() - n * 7)
        else if (unit === "months") d.setMonth(d.getMonth() - n)
        else if (unit === "years") d.setFullYear(d.getFullYear() - n)
        return d.toISOString().replace(/\.\d+Z$/, "Z")
    }

    // Выборка стартует с того, что таблица показывает сейчас.
    onDefaultSelectChanged: if (!spec.select.length) resetSelect()
    Component.onCompleted: {
        if (!spec.select.length && defaultSelect.length) resetSelect()
        apply()          // отдать таблице выборку по умолчанию
    }

    // ---- сборка запроса ----

    // УСЛОВИЕ (WHERE) — это то, что уходит хозяину: он подставляет его
    // в свой запрос или фильтрует им список в памяти.
    function buildSql() {
        var out = ""
        // быстрый поиск идёт первым условием
        if (quickText.trim() !== "")
            out = condSql(anyField, "MATCH", quickText.trim())
        for (var i = 0; i < spec.where.length; i++) {
            var c = spec.where[i]
            if (!c.field) continue
            if (!noValue(c.op) && c.value === "") continue
            var frag = condSql(c.field, c.op, c.value)
            var j = c.join || "AND"
            var neg = j.indexOf("NOT") >= 0
            if (neg) frag = "NOT (" + frag + ")"
            if (out === "") out = frag
            else out += " " + (j.indexOf("OR") === 0 ? "OR" : "AND") + " " + frag
        }
        return out
    }
    // ПОЛНЫЙ запрос — то, что видно в строке: начинается с выборки.
    function fullSql() {
        var out = "SELECT "
        if (spec.distinct) out += "DISTINCT "
        var cols = spec.select.slice()
        for (var i = 0; i < spec.computed.length; i++)
            if (spec.computed[i].expr)
                cols.push(spec.computed[i].expr + " AS " + (spec.computed[i].alias || "calc"))
        out += cols.length ? cols.join(", ") : "*"
        var w = buildSql()
        if (w) out += " WHERE " + w
        if (spec.groupBy.length) out += " GROUP BY " + spec.groupBy.join(", ")
        if (spec.orderBy.length) {
            var o = []
            for (var k = 0; k < spec.orderBy.length; k++)
                o.push(spec.orderBy[k].field + (spec.orderBy[k].desc ? " DESC" : ""))
            out += " ORDER BY " + o.join(", ")
        }
        return out
    }
    // Из набранного руками берём условие: всё после WHERE, а если слова
    // WHERE нет — считаем условием весь текст (так привычнее в фильтрах).
    function manualWhere() {
        var t = manualText.trim()
        var m = t.match(/\bWHERE\b([\s\S]*)$/i)
        if (m) {
            var tail = m[1]
            var cut = tail.search(/\b(GROUP\s+BY|ORDER\s+BY|LIMIT)\b/i)
            return (cut >= 0 ? tail.slice(0, cut) : tail).trim()
        }
        return /^\s*SELECT\b/i.test(t) ? "" : t
    }
    // ПОРЯДОК СОРТИРОВКИ для хозяина таблицы: из конструктора или из
    // набранного текста — источник один, каким бы способом ни задавали.
    // краткая сводка условий — для подсказки на значке
    function conditionSummary() {
        var out = []
        for (var i = 0; i < spec.where.length && i < 4; i++) {
            var c = spec.where[i]
            out.push(c.field + " " + c.op + (c.value ? " " + c.value : ""))
        }
        if (spec.where.length > 4) out.push("…")
        return out.join(", ")
    }

    function orderText() {
        if (builderMode) {
            var o = []
            for (var i = 0; i < spec.orderBy.length; i++)
                o.push(spec.orderBy[i].field + (spec.orderBy[i].desc ? " DESC" : ""))
            return o.join(", ")
        }
        var m = String(manualText).match(/\bORDER\s+BY\b([\s\S]*?)(\bLIMIT\b|$)/i)
        return m ? m[1].trim() : ""
    }

    function apply() {
        dirty = false
        bar.applied(spec, builderMode ? buildSql() : manualWhere())
    }
    // ВАЖНО: присвоить `spec = spec` НЕЛЬЗЯ — QML пропускает присваивание
    // того же объекта, уведомления нет, и всё, что на spec завязано, не
    // обновляется. Поэтому кладём НОВЫЙ объект: это и есть сигнал «изменилось».
    // ЗАПРОС НЕ ИСПОЛНЯЕТСЯ САМ. Правки конструктора только обновляют
    // спецификацию (видно по чипам и по строке запроса); поиск запускает
    // кнопка Run. Иначе каждый клик бил по базе, и было непонятно, что
    // именно сейчас выполнено.
    function touch() {
        spec = { where: spec.where.slice(),
                 select: spec.select.slice(),
                 groupBy: spec.groupBy.slice(),
                 orderBy: spec.orderBy.slice(),
                 distinct: spec.distinct,
                 computed: spec.computed.slice() }
        dirty = true
    }

    // ---- выборка ----
    function resetSelect() {
        spec.select = defaultSelect.slice()
        touch()
    }
    // ПОЛЕ МЕНЯЕТСЯ НА МЕСТЕ: и в выборке, и в группировке, и в сортировке.
    function replaceSelect(i, name) {
        var sl = spec.select.slice()
        if (i < 0 || i >= sl.length || sl.indexOf(name) >= 0) return
        sl[i] = name; spec.select = sl; touch()
    }
    function replaceGroup(i, name) {
        var g = spec.groupBy.slice()
        if (i < 0 || i >= g.length || g.indexOf(name) >= 0) return
        g[i] = name; spec.groupBy = g; touch()
    }
    function replaceOrder(i, name) {
        var o = spec.orderBy.slice()
        if (i < 0 || i >= o.length) return
        o[i] = { field: name, desc: o[i].desc }; spec.orderBy = o; touch()
    }

    // ПОРЯДОК ПОЛЕЙ В ВЫБОРКЕ = порядок колонок в таблице, поэтому его
    // должно быть можно менять, а не только набирать заново.
    function moveSelectTo(from, to) {
        var sl = spec.select.slice()
        if (from === to || from < 0 || from >= sl.length) return
        to = Math.max(0, Math.min(sl.length - 1, to))
        var v = sl.splice(from, 1)[0]
        sl.splice(to, 0, v)
        spec.select = sl
        touch()
    }
    function moveSelect(i, delta) {
        var sl = spec.select.slice()
        var j = i + delta
        if (i < 0 || i >= sl.length || j < 0 || j >= sl.length) return
        var t = sl[i]; sl[i] = sl[j]; sl[j] = t
        spec.select = sl
        touch()
    }

    function toggleField(name) {
        var sl = spec.select.slice()
        var i = sl.indexOf(name)
        if (i >= 0) sl.splice(i, 1); else sl.push(name)
        spec.select = sl
        touch()
    }

    // ---- части запроса, добавляемые кнопкой «+» ----
    function addClause(kind) {
        if (clauses.indexOf(kind) >= 0) return
        var c = clauses.slice()
        c.push(kind)
        clauses = c
        if (kind === "distinct") { spec.distinct = true; touch() }
    }
    function dropClause(kind) {
        var c = clauses.slice()
        var i = c.indexOf(kind)
        if (i >= 0) c.splice(i, 1)
        clauses = c
        if (kind === "where") spec.where = []
        if (kind === "order") spec.orderBy = []
        if (kind === "group") spec.groupBy = []
        if (kind === "distinct") spec.distinct = false
        if (kind === "calc") spec.computed = []
        touch()
    }
    function hasClause(kind) { return clauses.indexOf(kind) >= 0 }

    // добавить условие извне (кнопка «+» на ячейке таблицы)
    // ---- дописывание в НАБРАННЫЙ ТЕКСТ (режим SQL) ----
    // «+» на ячейке и сортировка должны попадать туда же, куда смотрит
    // пользователь: если он набирает SQL руками — прямо в текст запроса.
    function sqlFragment(field, op, value) { return condSql(field, op, value) }
    function appendWhere(text, frag) {
        var t = String(text || "").trim()
        if (t === "") return "SELECT * WHERE " + frag
        var tail = t.match(/\b(GROUP\s+BY|ORDER\s+BY|LIMIT)\b[\s\S]*$/i)
        var head = tail ? t.slice(0, t.length - tail[0].length).trim() : t
        var rest = tail ? " " + tail[0] : ""
        if (/\bWHERE\b/i.test(head)) return head + " AND " + frag + rest
        return head + " WHERE " + frag + rest
    }
    function appendOrder(text, field, desc) {
        var t = String(text || "").trim()
        var piece = field + (desc ? " DESC" : "")
        if (t === "") return "SELECT * ORDER BY " + piece
        if (/\bORDER\s+BY\b/i.test(t))
            return t.replace(/(\bORDER\s+BY\b)([\s\S]*?)(\bLIMIT\b[\s\S]*)?$/i,
                             function (m, kw, cols, lim) {
                                 return kw + cols.replace(/\s+$/, "") + ", " + piece
                                        + (lim ? " " + lim : "")
                             })
        return t + " ORDER BY " + piece
    }

    // сортировка снаружи (клик по заголовку колонки)
    function addSort(field, desc) {
        if (!builderMode) {
            manualText = appendOrder(manualText, field, !!desc)
            dirty = true
            return
        }
        addClause("order")
        var o = spec.orderBy.slice()
        for (var i = 0; i < o.length; i++)
            if (o[i].field === field) { o[i] = { field: field, desc: !!desc }; spec.orderBy = o; touch(); return }
        o.push({ field: field, desc: !!desc })
        spec.orderBy = o
        touch()
    }

    // По умолчанию условия соединяются через И — так ждут от фильтра.
    function addCondition(field, op, value, join, agoMs) {
        // в режиме SQL условие дописывается прямо в набранный текст
        if (!builderMode) {
            manualText = appendWhere(manualText, sqlFragment(field, op, value))
            dirty = true
            return
        }
        var w = spec.where.slice()
        for (var i = 0; i < w.length; i++)
            if (w[i].field === field && w[i].op === op
                && String(w[i].value) === String(value)) {
                builderMode = true
                addClause("where")
                return                       // такое условие уже есть
            }
        w.push({ field: field, op: op, value: String(value),
                 join: join || "AND", ago: agoMs || 0 })
        spec.where = w
        builderMode = true
        addClause("where")
        touch()
    }
    // какое условие правим (-1 — не правим)
    property int editIndex: -1
    function editCondition(i) { editIndex = i; condPopup.open() }
    function closeCondEditor() { condPopup.close() }
    function showMore(kind) { moreKind = kind; morePopup.open() }
    // для проверки рендером
    function openCalendar(which) { calPopup.target = which; calPopup.open() }

    // правка одного условия: поле / оператор / значение
    function setCond(i, key, v) {
        var w = spec.where.slice()
        if (i < 0 || i >= w.length) return
        var c = { field: w[i].field, op: w[i].op, value: w[i].value,
                  join: w[i].join, ago: w[i].ago || 0 }
        if (key === "value" || key === "field") c.ago = 0   // задали руками
        c[key] = v
        w[i] = c
        spec.where = w
        touch()
    }
    // верхняя граница промежутка: одно условие `<=` на поле, не плодим дубли
    function setUpperBound(field, iso) {
        var w = spec.where.slice()
        for (var i = 0; i < w.length; i++)
            if (w[i].field === field && w[i].op === "<=") {
                w[i] = { field: field, op: "<=", value: iso, join: w[i].join }
                spec.where = w; touch(); return
            }
        w.push({ field: field, op: "<=", value: iso, join: "AND" })
        spec.where = w; touch()
    }

    function clearAll() {
        if (initialQuery !== null) {
            var b = JSON.parse(initialQuery)
            // относительные границы времени пересчитываем от СЕЙЧАС
            for (var i = 0; i < b.w.length; i++)
                if (b.w[i].ago)
                    b.w[i] = { field: b.w[i].field, op: b.w[i].op,
                               join: b.w[i].join, ago: b.w[i].ago,
                               value: agoIso(b.w[i].ago) }
            spec = { where: b.w, select: b.s, groupBy: b.g, orderBy: b.o,
                     distinct: b.d, computed: b.c }
            clauses = b.cl
            manualText = b.m
            builderMode = true
            apply()          // сброс применяется сразу: это возврат к началу
            return
        }
        spec = { where: [], select: defaultSelect.slice(), groupBy: [],
                 orderBy: [], distinct: false, computed: [] }
        clauses = []
        manualText = ""
        quickText = ""
        touch()
    }

    // ОКНО ПРАВКИ УСЛОВИЯ. Одно на все условия: клик по условию открывает
    // его здесь. Поле МОЖНО СМЕНИТЬ — с поиском по всем полям, оператор из
    // списка, значение вводится; у поля времени предлагаются промежутки.
    QQC2.Popup {
        id: condPopup
        parent: bar
        x: 0
        y: bar.height + Kirigami.Units.smallSpacing
        width: Math.min(bar.width, Kirigami.Units.gridUnit * 34)
        padding: Kirigami.Units.largeSpacing
        modal: false
        closePolicy: QQC2.Popup.CloseOnEscape | QQC2.Popup.CloseOnPressOutsideParent
        onClosed: bar.editIndex = -1
        // трогал ли пользователь поля произвольного промежутка
        property bool agoTouched: false
        property string until: ""          // верхняя граница; "" = now
        onOpened: { agoTouched = false; until = "" }
        readonly property var cond: (bar.editIndex >= 0
                                     && bar.editIndex < bar.spec.where.length)
                                    ? bar.spec.where[bar.editIndex] : null

        ColumnLayout {
            width: parent.width
            spacing: Kirigami.Units.smallSpacing

            QQC2.Label {
                text: "Condition"
                font.bold: true
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                QQC2.Label {
                    text: "Field"
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                    opacity: 0.7
                }
                // ПОЛЕ МЕНЯЕТСЯ В ЛЮБОЙ МОМЕНТ — со списком и поиском
                FieldPicker {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Kirigami.Units.gridUnit * 2
                    fields: bar.allFieldNames
                    current: condPopup.cond ? condPopup.cond.field : ""
                    label: "choose a field"
                    onPicked: function (n) { bar.setCond(bar.editIndex, "field", n) }
                }
            }
            // ---- ОБЫЧНОЕ УСЛОВИЕ ----
            RowLayout {
                Layout.fillWidth: true
                visible: !!(condPopup.cond && !bar.isTimeField(condPopup.cond.field))
                spacing: Kirigami.Units.smallSpacing
                QQC2.Label {
                    text: "Is"
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                    opacity: 0.7
                }
                QQC2.ComboBox {
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 9
                    // у поиска по всем полям осмысленны только текстовые
                    // операторы: сравнивать «всё» числом бессмысленно
                    model: (condPopup.cond && condPopup.cond.field === bar.anyField)
                           ? ["MATCH", "NOT MATCH", "=", "<>"] : bar.operators
                    currentIndex: condPopup.cond
                                  ? Math.max(0, model.indexOf(condPopup.cond.op)) : 0
                    onActivated: bar.setCond(bar.editIndex, "op", currentText)
                }
                QQC2.TextField {
                    Layout.fillWidth: true
                    text: condPopup.cond ? condPopup.cond.value : ""
                    placeholderText: condPopup.cond
                        && condPopup.cond.op.indexOf("MATCH") >= 0
                        ? "text to find anywhere in the field" : "value"
                    enabled: !condPopup.cond || !bar.noValue(condPopup.cond.op)
                    onEditingFinished: bar.setCond(bar.editIndex, "value", text)
                }
            }

            // ---- УСЛОВИЕ ПО ВРЕМЕНИ ----
            // Читается как фраза: «с ... по ...». Границу задают либо готовым
            // промежутком, либо числом единиц назад, либо календарём.
            ColumnLayout {
                Layout.fillWidth: true
                visible: !!(condPopup.cond && bar.isTimeField(condPopup.cond.field))
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    QQC2.Label {
                        text: "From"
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                        opacity: 0.7
                    }
                    QQC2.Button {
                        Layout.fillWidth: true
                        icon.name: "view-calendar-day"
                        text: condPopup.cond ? bar.humanTime(condPopup.cond.value)
                                             : ""
                        onClicked: { calPopup.target = "from"; calPopup.open() }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    QQC2.Label {
                        text: "Until"
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                        opacity: 0.7
                    }
                    QQC2.Button {
                        Layout.fillWidth: true
                        icon.name: "view-calendar-day"
                        text: condPopup.until === "" ? "now"
                                                     : bar.humanTime(condPopup.until)
                        onClicked: { calPopup.target = "until"; calPopup.open() }
                    }
                    QQC2.ToolButton {
                        visible: condPopup.until !== ""
                        icon.name: "edit-clear"
                        QQC2.ToolTip.text: "Back to now"
                        QQC2.ToolTip.visible: hovered
                        onClicked: condPopup.until = ""
                    }
                }

                // быстрый способ: «за последние N единиц»
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    QQC2.Label {
                        text: "Last"
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                        opacity: 0.7
                    }
                    QQC2.SpinBox {
                        id: agoN
                        from: 1
                        to: 9999
                        value: 30
                        editable: true
                        opacity: 0.75
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 4.5
                        onValueModified: bar.applyLast(agoN.value, agoUnit.currentText)
                    }
                    QQC2.ComboBox {
                        id: agoUnit
                        model: bar.timeUnits
                        currentIndex: 3
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                        onActivated: bar.applyLast(agoN.value, agoUnit.currentText)
                    }
                    Item { Layout.fillWidth: true }
                }
                Flow {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    Repeater {
                        model: bar.timePresets
                        delegate: QQC2.Button {
                            required property var modelData
                            text: modelData.t
                            flat: true
                            onClicked: {
                                bar.setCond(bar.editIndex, "op", ">=")
                                bar.setCond(bar.editIndex, "value", bar.agoIso(modelData.ms))
                                bar.setCond(bar.editIndex, "ago", modelData.ms)
                                condPopup.until = ""
                            }
                        }
                    }
                }
            }

            // ---- КАЛЕНДАРЬ ----
            // MonthGrid из QtQuick.Controls.Basic: настоящая сетка месяца,
            // без внешних зависимостей и без локализации KDE (она требует
            // i18n, которого в приложении нет).
            QQC2.Popup {
                id: calPopup
                modal: false
                padding: Kirigami.Units.smallSpacing
                x: 0
                y: Kirigami.Units.gridUnit * 2
                closePolicy: QQC2.Popup.CloseOnEscape | QQC2.Popup.CloseOnPressOutside
                property string target: "from"        // from | until
                property int yy: 2026
                property int mo: 6                    // 0-11
                property int dd: 1
                onOpened: {
                    var iso = target === "until"
                        ? condPopup.until
                        : (condPopup.cond ? condPopup.cond.value : "")
                    var dt = iso ? new Date(iso) : new Date()
                    if (isNaN(dt.getTime())) dt = new Date()
                    yy = dt.getFullYear(); mo = dt.getMonth(); dd = dt.getDate()
                    hh.value = dt.getHours(); mm.value = dt.getMinutes()
                }

                ColumnLayout {
                    spacing: Kirigami.Units.smallSpacing

                    RowLayout {
                        Layout.fillWidth: true
                        QQC2.ToolButton {
                            icon.name: "go-previous"
                            onClicked: {
                                if (calPopup.mo === 0) { calPopup.mo = 11; calPopup.yy-- }
                                else calPopup.mo--
                            }
                        }
                        QQC2.Label {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            font.bold: true
                            text: bar.monthNames[calPopup.mo] + " " + calPopup.yy
                        }
                        QQC2.ToolButton {
                            icon.name: "go-next"
                            onClicked: {
                                if (calPopup.mo === 11) { calPopup.mo = 0; calPopup.yy++ }
                                else calPopup.mo++
                            }
                        }
                    }

                    CB.DayOfWeekRow {
                        Layout.fillWidth: true
                        locale: Qt.locale("en_GB")     // неделя с понедельника
                    }
                    CB.MonthGrid {
                        id: grid
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 21
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 13
                        month: calPopup.mo
                        year: calPopup.yy
                        locale: Qt.locale("en_GB")
                        delegate: QQC2.ItemDelegate {
                            required property var model
                            width: grid.width / 7
                            height: Kirigami.Units.gridUnit * 2
                            enabled: model.month === calPopup.mo
                            onClicked: calPopup.dd = model.day
                            background: Rectangle {
                                radius: 3
                                color: (model.day === calPopup.dd
                                        && model.month === calPopup.mo)
                                    ? Qt.alpha(Kirigami.Theme.highlightColor, 0.45)
                                    : (model.today
                                       ? Qt.alpha(Kirigami.Theme.highlightColor, 0.15)
                                       : "transparent")
                            }
                            contentItem: QQC2.Label {
                                text: model.day
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                opacity: model.month === calPopup.mo ? 1 : 0.35
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        QQC2.Label { text: "Time"; opacity: 0.7 }
                        QQC2.SpinBox { id: hh; from: 0; to: 23; editable: true
                                       Layout.preferredWidth: Kirigami.Units.gridUnit * 5 }
                        QQC2.Label { text: ":" }
                        QQC2.SpinBox { id: mm; from: 0; to: 59; editable: true
                                       Layout.preferredWidth: Kirigami.Units.gridUnit * 5 }
                        QQC2.Button {
                            text: "Start of day"
                            flat: true
                            onClicked: { hh.value = 0; mm.value = 0 }
                        }
                        QQC2.Button {
                            text: "End of day"
                            flat: true
                            onClicked: { hh.value = 23; mm.value = 59 }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        QQC2.Label {
                            opacity: 0.7
                            text: calPopup.dd + " " + bar.monthNames[calPopup.mo] + " "
                                  + calPopup.yy + "  " + bar.pad2(hh.value) + ":"
                                  + bar.pad2(mm.value)
                        }
                        Item { Layout.fillWidth: true }
                        QQC2.Button { text: "Cancel"; onClicked: calPopup.close() }
                        QQC2.Button {
                            text: "Set"
                            highlighted: true
                            onClicked: {
                                // местное время -> UTC, как хранится в базе
                                var d = new Date(calPopup.yy, calPopup.mo, calPopup.dd,
                                                 hh.value, mm.value, 0)
                                var iso = d.toISOString().replace(/\.\d+Z$/, "Z")
                                if (calPopup.target === "until") condPopup.until = iso
                                else {
                                    bar.setCond(bar.editIndex, "op", ">=")
                                    bar.setCond(bar.editIndex, "value", iso)
                                    bar.setCond(bar.editIndex, "ago", 0)
                                }
                                calPopup.close()
                            }
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: bar.editIndex > 0
                spacing: Kirigami.Units.smallSpacing
                QQC2.Label {
                    text: "Join"
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                    opacity: 0.7
                }
                QQC2.ComboBox {
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 9
                    model: bar.joiners
                    currentIndex: condPopup.cond
                                  ? Math.max(0, bar.joiners.indexOf(condPopup.cond.join || "AND")) : 0
                    onActivated: bar.setCond(bar.editIndex, "join", currentText)
                }
                Item { Layout.fillWidth: true }
            }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                // Done И ЕСТЬ Apply: отдельная кнопка «применить» только
                // добавляла шаг. Условие удаляется крестиком на нём самом.
                QQC2.Button {
                    text: "Done"
                    highlighted: true
                    onClicked: {
                        if (condPopup.cond && bar.isTimeField(condPopup.cond.field)) {
                            if (condPopup.agoTouched) {
                                bar.setCond(bar.editIndex, "op", ">=")
                                bar.setCond(bar.editIndex, "value",
                                            bar.agoUnits(agoN.value, agoUnit.currentText))
                                bar.setCond(bar.editIndex, "ago",
                                            bar.agoMs(agoN.value, agoUnit.currentText))
                            }
                            if (condPopup.until !== "")
                                bar.setUpperBound(condPopup.cond.field, condPopup.until)
                        }
                        condPopup.close()
                    }
                }
            }
        }
    }

    // ---- ОКНО «ПОКАЗАТЬ ВСЁ» ----
    // Длинный перечень (полей выборки, условий, сортировок, группировок) не
    // должен растягивать панель запроса: в строке остаются две строки чипов,
    // а весь список — здесь, с теми же действиями.
    QQC2.Popup {
        id: morePopup
        modal: false
        parent: bar
        // прямо под строкой запроса: меню, а не окно поверх таблицы
        x: 0
        y: bar.height + Kirigami.Units.smallSpacing
        width: Math.min(bar.width, Kirigami.Units.gridUnit * 32)
        height: Kirigami.Units.gridUnit * 16
        padding: Kirigami.Units.smallSpacing
        closePolicy: QQC2.Popup.CloseOnEscape | QQC2.Popup.CloseOnPressOutsideParent

        readonly property var items: {
            if (bar.moreKind === "select") return bar.spec.select
            if (bar.moreKind === "where") return bar.spec.where
            if (bar.moreKind === "order") return bar.spec.orderBy
            if (bar.moreKind === "group") return bar.spec.groupBy
            return []
        }
        readonly property string caption: {
            if (bar.moreKind === "select") return "Fields in the query"
            if (bar.moreKind === "where") return "Conditions"
            if (bar.moreKind === "order") return "Sorting"
            if (bar.moreKind === "group") return "Grouping"
            return ""
        }
        function textOf(m) {
            if (bar.moreKind === "where")
                return (m.join && m.join !== "AND" ? m.join + "  " : "")
                       + m.field + " " + m.op + (m.value ? " " + m.value : "")
            if (bar.moreKind === "order")
                return m.field + (m.desc ? "  ↓" : "  ↑")
            return String(m)
        }
        function removeAt(i) {
            if (bar.moreKind === "select") {
                var sl = bar.spec.select.slice(); sl.splice(i, 1)
                bar.spec.select = sl
            } else if (bar.moreKind === "where") {
                var w = bar.spec.where.slice(); w.splice(i, 1)
                bar.spec.where = w
            } else if (bar.moreKind === "order") {
                var o = bar.spec.orderBy.slice(); o.splice(i, 1)
                bar.spec.orderBy = o
            } else if (bar.moreKind === "group") {
                var g = bar.spec.groupBy.slice(); g.splice(i, 1)
                bar.spec.groupBy = g
            }
            bar.touch()
        }
        function addField(n) {
            if (bar.moreKind === "select") bar.toggleField(n)
            else if (bar.moreKind === "where") {
                bar.addCondition(n, "=", "")
                bar.editCondition(bar.spec.where.length - 1)
                morePopup.close()
            } else if (bar.moreKind === "order") {
                var o = bar.spec.orderBy.slice()
                for (var i = 0; i < o.length; i++) if (o[i].field === n) return
                o.push({ field: n, desc: false }); bar.spec.orderBy = o; bar.touch()
            } else if (bar.moreKind === "group") {
                if (bar.spec.groupBy.indexOf(n) >= 0) return
                var g = bar.spec.groupBy.slice(); g.push(n)
                bar.spec.groupBy = g; bar.touch()
            }
        }

        ColumnLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                QQC2.Label {
                    text: morePopup.caption
                    font.bold: true
                }
                QQC2.Label {
                    text: morePopup.items.length + " total"
                    opacity: 0.6
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
                Item { Layout.fillWidth: true }
                FieldPicker {
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                    Layout.preferredHeight: Kirigami.Units.gridUnit * 2
                    fields: bar.moreKind === "select" ? bar.allFieldNames
                                                      : bar.fieldsPreferSelected
                    preferred: bar.spec.select
                    checkMode: bar.moreKind === "select"
                    checked: bar.spec.select
                    label: "add"
                    iconName: "list-add"
                    onPicked: function (n) { morePopup.addField(n) }
                }
                QQC2.ToolButton {
                    icon.name: "window-close"
                    onClicked: morePopup.close()
                }
            }
            Kirigami.Separator { Layout.fillWidth: true }

            QQC2.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: Kirigami.Units.gridUnit * 11
                clip: true
                ListView {
                    id: moreList
                    model: morePopup.items
                    // reuseItems выключен: при перетаскивании делегат должен
                    // жить, пока его тащат
                    delegate: QQC2.ItemDelegate {
                        id: moreRow
                        required property var modelData
                        required property int index
                        width: ListView.view.width
                        height: Kirigami.Units.gridUnit * 2.2
                        // ПЕРЕТАСКИВАНИЕ ПОЛЕЙ ВЫБОРКИ: порядок полей — это
                        // порядок колонок, и мышью его менять привычнее, чем
                        // стрелками. Стрелки остаются: клавиатурой и точнее.
                        z: dragArea.drag.active ? 2 : 1
                        Drag.active: dragArea.drag.active
                        onClicked: {
                            // условие правится в своём окне
                            if (bar.moreKind === "where") {
                                morePopup.close()
                                bar.editCondition(index)
                            }
                        }
                        background: Rectangle {
                            color: index % 2 ? Qt.alpha(Kirigami.Theme.textColor, 0.03)
                                             : "transparent"
                        }
                        MouseArea {
                            id: dragArea
                            objectName: "DRAG"
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            width: Kirigami.Units.gridUnit * 1.8
                            visible: bar.moreKind === "select"
                            cursorShape: Qt.SizeVerCursor
                            drag.target: visible ? moreRow : null
                            drag.axis: Drag.YAxis
                            property int startY: 0
                            onPressed: startY = moreRow.y
                            onReleased: {
                                // куда отпустили — на столько строк и сдвигаем
                                var step = moreRow.height
                                var delta = Math.round((moreRow.y - startY) / step)
                                moreRow.y = startY          // вернуть на место:
                                                            // порядок задаёт модель
                                if (delta !== 0)
                                    bar.moveSelectTo(index, index + delta)
                            }
                        }
                        contentItem: RowLayout {
                            spacing: Kirigami.Units.smallSpacing
                            Kirigami.Icon {
                                visible: bar.moreKind === "select"
                                source: "handle-sort"
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                opacity: 0.6
                            }
                            QQC2.Label {
                                Layout.fillWidth: true
                                text: morePopup.textOf(modelData)
                                elide: Text.ElideRight
                                font.family: "monospace"
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                            // ПОРЯДОК ПОЛЕЙ — ПЕРЕТАСКИВАНИЕМ за ручку
                            // слева; стрелки убраны как дубль.
                            QQC2.ToolButton {
                                visible: bar.moreKind === "order"
                                implicitWidth: Kirigami.Units.gridUnit * 1.6
                                implicitHeight: Kirigami.Units.gridUnit * 1.6
                                icon.name: modelData.desc ? "view-sort-descending"
                                                          : "view-sort-ascending"
                                onClicked: {
                                    var o = bar.spec.orderBy.slice()
                                    o[index] = { field: o[index].field, desc: !o[index].desc }
                                    bar.spec.orderBy = o; bar.touch()
                                }
                            }
                            QQC2.ToolButton {
                                implicitWidth: Kirigami.Units.gridUnit * 1.6
                                implicitHeight: Kirigami.Units.gridUnit * 1.6
                                icon.name: "window-close"
                                onClicked: morePopup.removeAt(index)
                            }
                        }
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                QQC2.Button {
                    text: "Done"
                    highlighted: true
                    onClicked: morePopup.close()
                }
            }
        }
    }

    ColumnLayout {
        id: col
        width: parent.width
        spacing: Kirigami.Units.smallSpacing

        // ---- строка запроса + переключатель способа ----
        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                source: "search"
                visible: !bar.builderMode
                opacity: 0.6
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
            }
            // МНОГОСТРОЧНОЕ поле: запрос бывает длиннее строки, и в одну
            // строку его было не разглядеть. Растёт по содержимому до 6 строк,
            // дальше прокручивается. Enter применяет, Shift+Enter — перенос.
            QQC2.ScrollView {
                // В режиме «накликать» поле скрыто: запрос читается по самому
                // конструктору, а дублирующая строка только занимает место.
                visible: !bar.builderMode
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(
                    Math.max(sqlField.implicitHeight, Kirigami.Units.gridUnit * 1.8),
                    Kirigami.Units.gridUnit * 9)
                Layout.preferredWidth: visible ? -1 : 0
                clip: true
                QQC2.TextArea {
                    id: sqlField
                    font.family: "monospace"
                    wrapMode: TextEdit.Wrap
                    placeholderText: bar.placeholder
                    readOnly: bar.builderMode
                    // в конструкторе поле показывает собранный запрос,
                    // в ручном — то, что набрали
                    text: bar.builderMode ? bar.fullSql() : bar.manualText
                    onTextChanged: if (!bar.builderMode) bar.manualText = text
                    opacity: bar.builderMode ? 0.75 : 1.0
                    Keys.onReturnPressed: function (ev) {
                        if (ev.modifiers & Qt.ShiftModifier) { ev.accepted = false; return }
                        bar.apply(); ev.accepted = true
                    }
                }
            }
            // ЯВНЫЙ ЗАПУСК: в многострочном поле Enter может быть переносом,
            // и «когда же он выполнится» переставало быть очевидным.
            // Управление (Run, режим, очистка) — ВНИЗУ СПРАВА
        }

        // ---- КОНСТРУКТОР ----
        Rectangle {
            Layout.fillWidth: true
            // Панель И ЕСТЬ режим «накликать»
            visible: bar.builderMode
            implicitHeight: bcol.implicitHeight + Kirigami.Units.largeSpacing
            radius: 4
            color: Kirigami.Theme.alternateBackgroundColor

            ColumnLayout {
                id: bcol
                // НЕ anchors.fill: высота панели считается из bcol, и
                // заполнение родителя замыкало бы вычисление само на себя
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                // ===== СТРОКА ПОИСКА =====
                // Слева — быстрый поиск по всем полям (главное действие),
                // справа — части запроса СЖАТЫМИ ЗНАЧКАМИ со счётчиком.
                // Подробности (какие поля, какие условия) живут в своих
                // окнах: 20 полей и 5 условий в строку не поместятся никогда,
                // а счётчик читается мгновенно.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Kirigami.SearchField {
                        id: quickField
                        // компактное поле: строка запроса не должна быть
                        // шириной во весь экран ради одного слова
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 18
                        Layout.maximumWidth: Kirigami.Units.gridUnit * 24
                        visible: bar.builderMode      // в режиме SQL не нужно
                        placeholderText: "search in all fields…"
                        text: bar.quickText
                        onTextEdited: {
                            bar.quickText = text
                            // очистили строку — сразу показываем всё
                            if (text === "") bar.apply()
                        }
                        onAccepted: bar.apply()
                    }

                    Item { Layout.fillWidth: true }
                    // ---- ВЫБОРКА ----
                    QQC2.ToolButton {
                        icon.name: "view-list-details"
                        text: bar.spec.select.length ? String(bar.spec.select.length) : ""
                        display: bar.spec.select.length ? QQC2.AbstractButton.TextBesideIcon
                                                        : QQC2.AbstractButton.IconOnly
                        QQC2.ToolTip.text: "Fields in the query: add, remove, reorder"
                        QQC2.ToolTip.visible: hovered
                        onClicked: { bar.moreKind = "select"; morePopup.open() }
                    }
                    // ---- УСЛОВИЯ ----
                    QQC2.ToolButton {
                        icon.name: "view-filter"
                        text: bar.spec.where.length ? String(bar.spec.where.length) : ""
                        display: bar.spec.where.length ? QQC2.AbstractButton.TextBesideIcon
                                                       : QQC2.AbstractButton.IconOnly
                        highlighted: bar.spec.where.length > 0
                        QQC2.ToolTip.text: bar.spec.where.length
                            ? "Conditions: " + bar.conditionSummary()
                            : "Add a condition"
                        QQC2.ToolTip.visible: hovered
                        onClicked: {
                            if (!bar.spec.where.length) {
                                bar.addClause("where")
                                bar.addCondition(bar.anyField, "MATCH", "")
                                bar.editCondition(bar.spec.where.length - 1)
                            } else {
                                bar.moreKind = "where"; morePopup.open()
                            }
                        }
                    }
                    // ---- ГРУППИРОВКА ----
                    QQC2.ToolButton {
                        icon.name: "view-group"
                        text: bar.spec.groupBy.length ? String(bar.spec.groupBy.length) : ""
                        display: bar.spec.groupBy.length ? QQC2.AbstractButton.TextBesideIcon
                                                         : QQC2.AbstractButton.IconOnly
                        highlighted: bar.spec.groupBy.length > 0
                        QQC2.ToolTip.text: bar.spec.groupBy.length
                            ? "Grouped by " + bar.spec.groupBy.join(", ")
                            : "Group by a field"
                        QQC2.ToolTip.visible: hovered
                        onClicked: {
                            bar.addClause("group")
                            bar.moreKind = "group"; morePopup.open()
                        }
                    }
                    // ---- СОРТИРОВКА ----
                    QQC2.ToolButton {
                        icon.name: "view-sort-ascending"
                        text: bar.spec.orderBy.length ? String(bar.spec.orderBy.length) : ""
                        display: bar.spec.orderBy.length ? QQC2.AbstractButton.TextBesideIcon
                                                         : QQC2.AbstractButton.IconOnly
                        highlighted: bar.spec.orderBy.length > 0
                        QQC2.ToolTip.text: bar.spec.orderBy.length
                            ? "Sorted by " + bar.orderText()
                            : "Sort by a field"
                        QQC2.ToolTip.visible: hovered
                        onClicked: {
                            bar.addClause("order")
                            bar.moreKind = "order"; morePopup.open()
                        }
                    }
                    // ---- ГРУППЫ КНОПОК РАЗДЕЛЕНЫ: слева части запроса,
                    // в середине работа с запросами (сохранить, история),
                    // справа запуск и режим ----
                    Kirigami.Separator {
                        visible: hostToolsRow.children.length > 0
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 1.4
                        Layout.preferredWidth: 1
                        Layout.leftMargin: Kirigami.Units.smallSpacing
                        Layout.rightMargin: Kirigami.Units.smallSpacing
                    }
                    Row {
                        id: hostToolsRow
                        spacing: Kirigami.Units.smallSpacing
                    }
                    Kirigami.Separator {
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 1.4
                        Layout.preferredWidth: 1
                        Layout.leftMargin: Kirigami.Units.smallSpacing
                        Layout.rightMargin: Kirigami.Units.smallSpacing
                    }
                    // ---- ЗАПУСК И РЕЖИМ ----
                    QQC2.ToolButton {
                        objectName: "resetBtn"
                        icon.name: "edit-clear-all"
                        visible: bar.changed
                        QQC2.ToolTip.text: "Reset the query to its initial state"
                        QQC2.ToolTip.visible: hovered
                        onClicked: bar.clearAll()
                    }
                    QQC2.Button {
                        text: "Run"
                        icon.name: "media-playback-start"
                        // пока запрос не менялся — запускать нечего
                        enabled: bar.dirty
                        highlighted: bar.dirty
                        QQC2.ToolTip.text: bar.dirty ? "Run the query"
                                                     : "Nothing changed since the last run"
                        QQC2.ToolTip.visible: hovered
                        onClicked: bar.apply()
                    }
                    QQC2.Button {
                        text: "SQL"
                        icon.name: "code-context"
                        QQC2.ToolTip.text: "Type the query by hand instead"
                        QQC2.ToolTip.visible: hovered
                        onClicked: {
                            bar.manualText = bar.fullSql()
                            bar.builderMode = false
                            bar.apply()
                        }
                    }

                    // ---- ПРОЧЕЕ: уникальные, вычисляемое поле ----
                    QQC2.ToolButton {
                        icon.name: "overflow-menu"
                        QQC2.ToolTip.text: "More parts of the query"
                        QQC2.ToolTip.visible: hovered
                        onClicked: partMenu.open()
                        QQC2.Menu {
                            id: partMenu
                            QQC2.MenuItem {
                                text: bar.spec.distinct ? "Unique rows — on" : "Unique rows"
                                icon.name: "edit-duplicate"
                                checkable: true
                                checked: bar.spec.distinct
                                onTriggered: {
                                    bar.spec.distinct = checked
                                    if (checked) bar.addClause("distinct")
                                    else bar.dropClause("distinct")
                                    bar.touch()
                                }
                            }
                            QQC2.MenuItem {
                                text: "Calculated field…"
                                icon.name: "accessories-calculator"
                                onTriggered: { bar.addClause("calc"); bar.editingCalc = true }
                            }
                            QQC2.MenuSeparator {}
                            QQC2.MenuItem {
                                text: "Show the query as SQL"
                                icon.name: "code-context"
                                onTriggered: {
                                    bar.manualText = bar.fullSql()
                                    bar.builderMode = false
                                    bar.apply()
                                }
                            }
                        }
                    }
                }

                // ввод вычисляемого поля — только когда его добавляют
                RowLayout {
                    Layout.fillWidth: true
                    visible: bar.editingCalc
                    spacing: Kirigami.Units.smallSpacing
                    QQC2.TextField {
                        id: cExpr
                        Layout.fillWidth: true
                        font.family: "monospace"
                        placeholderText: "expression, for example  rss_mb * 1024"
                    }
                    QQC2.TextField {
                        id: cAlias
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                        placeholderText: "name"
                    }
                    QQC2.Button {
                        text: "Add"
                        icon.name: "list-add"
                        enabled: cExpr.text.trim() !== ""
                        onClicked: {
                            var c = bar.spec.computed.slice()
                            c.push({ expr: cExpr.text.trim(),
                                     alias: cAlias.text.trim() || "calc" })
                            bar.spec.computed = c
                            cExpr.text = ""; cAlias.text = ""
                            bar.editingCalc = false
                            bar.touch()
                        }
                    }
                }
            }
        }

        // ручной режим: то же управление под строкой SQL
        RowLayout {
            Layout.fillWidth: true
            visible: !bar.builderMode
            spacing: Kirigami.Units.smallSpacing
            Item { Layout.fillWidth: true }
            QQC2.Button {
                text: "Run"
                icon.name: "media-playback-start"
                enabled: bar.dirty
                highlighted: bar.dirty
                onClicked: bar.apply()
            }
            QQC2.Button {
                text: "Build"
                icon.name: "draw-freehand"
                QQC2.ToolTip.text: "Build the query by clicking instead"
                QQC2.ToolTip.visible: hovered
                onClicked: { bar.builderMode = true; bar.apply() }
            }
            QQC2.ToolButton {
                icon.name: "edit-clear-all"
                QQC2.ToolTip.text: "Clear the query"
                QQC2.ToolTip.visible: hovered
                onClicked: bar.clearAll()
            }
        }
    }
}

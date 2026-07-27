import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
// the month grid: the org.kde.desktop style has none, we take it from the basic set
import QtQuick.Controls.Basic as CB
import org.kde.kirigami as Kirigami
import "."

// THE SINGLE QUERY BAR for every table of the application.
//
// The design is simple: a query ALWAYS starts with a SELECTION (SELECT) - of the
// fields the table shows right now. Everything else - a filter, a sort, a
// grouping, DISTINCT, a calculated field - is ADDED one at a time with the
// "+" button and is built RELATIVE to the selection.
// The "Reset" button returns the selection to the original one.
//
// Two ways to express the same thing:
//   * CLICK it together - the builder (the default);
//   * TYPE it - SQL by hand.
// Switching does not lose the query.
//
// The component executes NOTHING: it assembles a specification and emits it as a
// signal. Who applies it and how (SQL against a database or filtering in memory)
// is the business of the owner of the table. That is why one bar works both over
// state.db and over a list computed in Python.
Item {
    id: bar
    implicitHeight: col.implicitHeight

    // the fields of the table: [{ name, title }] - what can be selected at all
    property var fields: []
    // the fields the table shows NOW - the selection starts with them
    property var defaultSelect: []
    // NEVER undefined: the owner binds defaultSelect to a computed list
    // (visibleCols) that is transiently undefined during init, which would make
    // defaultSelect.slice()/.length throw at load. Use _defSel everywhere.
    readonly property var _defSel: defaultSelect || []
    // ...and read it through THIS, never directly. A readonly property with a
    // binding is `undefined` until that binding first runs, and
    // onDefaultSelectChanged can fire before it does — which threw
    // "Cannot call method 'slice' of undefined" during load and left the
    // selection uninitialised.
    function defSel() {
        var d = _defSel !== undefined ? _defSel : defaultSelect
        return (d && d.slice) ? d : []
    }
    // the current query specification
    // where: [{field, op, value, join}] - join binds it to the PREVIOUS condition
    // (AND by default; OR / AND NOT / OR NOT). orderBy: [{field, desc}] - there
    // may be several sorts and groupings, as in SQL.
    property var spec: ({ where: [], select: [], groupBy: [],
                          orderBy: [], distinct: false, computed: [] })
    // which parts of the query were added with the "+" button
    property var clauses: []
    property bool builderMode: true      // click it together (default) or type it
    property string manualText: ""       // what was typed by hand
    property string placeholder: "SELECT * WHERE field = 'value'"

    signal applied(var spec, string sql)
    // the "…" menu — the owner shows the popups / dialog / sidebar
    signal saveToExpertise(string sql)
    signal historyRequested()
    signal useExpertiseRequested()

    // set the query from outside (a picked history item or saved query)
    function setSql(sql) {
        manualText = String(sql || "")
        builderMode = false
        apply()
    }

    // there are unsaved edits - Run is highlighted
    property bool dirty: false
    // the query differs from its default - then and only then is there something
    // to reset. (Query state used to be snapshotted/exported to survive
    // navigation; pages now live in Main's pageCache, so that machinery is gone.)
    readonly property bool changed: {
        // the fields are listed explicitly so the binding recomputes when edited
        var _ = [spec.where.length, spec.select.length, spec.groupBy.length,
                 spec.orderBy.length, spec.distinct, spec.computed.length,
                 clauses.length, manualText, quickText]
        if (spec.where.length || clauses.length || manualText !== "") return true
        var ds = defSel()
        if (spec.select.length !== ds.length) return true
        for (var i = 0; i < spec.select.length; i++)
            if (spec.select[i] !== ds[i]) return true
        return false
    }
    property bool editingCalc: false

    // THE PSEUDO FIELD "all" - search in every field at once
    readonly property string anyField: "all fields"
    // the names of all fields - for the search picker; "all" first
    readonly property var allFieldNames: {
        var out = [anyField]
        var f = fields
        for (var i = 0; i < f.length; i++) out.push(f[i].name)
        return out
    }
    // THE SELECTION FIELDS FIRST, THEN THE REST. One may group and sort by any
    // field even if it is not in SELECT (that is legal in SQL), but the selected
    // ones are shown first - people group by them most often.
    readonly property var fieldsPreferSelected: {
        var out = spec.select.slice()
        var all = allFieldNames
        for (var i = 0; i < all.length; i++)
            if (out.indexOf(all[i]) < 0) out.push(all[i])
        return out
    }
    // QUICK SEARCH ACROSS ALL FIELDS: the main action of the bar. It is an
    // ordinary condition "all fields MATCH ...", it simply has its own input -
    // that way "find anything" requires neither the builder nor knowing SQL.
    property string quickText: ""
    // which list is open in the "show all" popup
    property string moreKind: ""
    // the buttons of the page owner (history, save, saved) - on the left of the
    // query control row
    property alias hostTools: hostToolsRow.data

    readonly property var operators: ["MATCH", "NOT MATCH", "=", "<>",
                                      "LIKE", "NOT LIKE",
                                      ">", "<", ">=", "<=",
                                      "IS NULL", "IS NOT NULL"]
    function noValue(op) { return op === "IS NULL" || op === "IS NOT NULL" }
    // a quote inside a value must not break the query
    function quote(v) { return "'" + String(v).replace(/'/g, "''") + "'" }
    // one condition -> a piece of SQL
    function condSql(field, op, value) {
        // "all fields" expands into an OR over every field of the table
        if (field === anyField) {
            var parts = []
            for (var i = 0; i < fields.length; i++)
                parts.push(condSql(fields[i].name, op, value))
            return parts.length ? "(" + parts.join(" OR ") + ")" : ""
        }
        var col = '"' + field + '"'
        if (noValue(op)) return col + ' ' + op
        // TEXT MATCHING WORKS ON ANY COLUMN, not just the text ones. Columns are
        // no longer all strings — a view computes round(...) as a DOUBLE, a count
        // as a BIGINT, an event timestamp is a TIMESTAMP — and LIKE against those
        // is a binder error ("No function matches ~~(DOUBLE, VARCHAR)"), which is
        // what made the free-text search fail on those tables. Casting to text
        // asks the question the user actually asked: does this VALUE contain that.
        var text = 'CAST(' + col + ' AS VARCHAR)'
        if (op === "MATCH")     return text + ' LIKE ' + quote("%" + value + "%")
        if (op === "NOT MATCH") return text + ' NOT LIKE ' + quote("%" + value + "%")
        if (op === "LIKE")      return text + ' LIKE ' + quote(value)
        if (op === "NOT LIKE")  return text + ' NOT LIKE ' + quote(value)
        return col + ' ' + op + " " + quote(value)
    }
    readonly property var joiners: ["AND", "OR", "AND NOT", "OR NOT"]

    // A TIME FIELD is recognised by its name - the property is structural, not a
    // list of specific fields: it fits any table where time is named as usual.
    function isTimeField(n) {
        if (!n) return false
        n = String(n).toLowerCase()
        return n === "ts" || n === "time" || n === "date"
               || /(^|_)(ts|time|date|at|changed|issued|installed|seen|login)$/.test(n)
    }
    // Ready ranges for such a field. The bound is computed NOW and written as an
    // absolute time: "the last hour" stays that very hour and does not creep away
    // the next time the popup is opened.
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
    // AN ARBITRARY RANGE: "so many minutes/hours/days/months/years ago".
    // Months and years are counted by the calendar (a month is not 30 days), so
    // not through milliseconds but by shifting the date.
    readonly property var timeUnits: ["seconds", "minutes", "hours", "days",
                                      "weeks", "months", "years"]
    // the offset in milliseconds - a relative bound is marked with it so that
    // resetting the query recomputes it from "now"
    function agoMs(n, unit) {
        n = Math.max(0, Number(n) || 0)
        var k = { seconds: 1000, minutes: 60000, hours: 3600000,
                  days: 86400000, weeks: 604800000,
                  months: 2592000000, years: 31536000000 }
        return n * (k[unit] || 0)
    }
    // HUMAN TIME for the buttons: "22 Jul 2026 17:59" in the local zone
    // (the database holds UTC - the interface boundary converts it)
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
    // "for the last N units" - sets the lower bound and removes the upper one
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

    // THE SELECTION IS THE TABLE'S SHOWN COLUMNS, ALWAYS — and it cannot outlive
    // the table it was made for. This used to reset only when the selection was
    // empty, which meant that on a tab switch the bar kept the PREVIOUS table's
    // columns: the page clears the bar before the new table's column list has
    // been recomputed, so the "default" read at that moment was still the old one.
    // Resetting whenever the shown columns change fixes both the switch and a
    // column toggled in the Columns panel.
    onDefaultSelectChanged: resetSelect()
    Component.onCompleted: {
        if (!spec.select.length && defSel().length) resetSelect()
        apply()          // hand the default selection to the table
    }

    // ---- assembling the query ----

    // THE CONDITION (WHERE) is what goes to the owner: they substitute it into
    // their query or filter an in-memory list with it.
    function buildSql() {
        var out = ""
        // the quick search comes as the first condition
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
    // THE FULL query - what is visible in the bar: it starts with the selection.
    function fullSql() {
        var out = "SELECT "
        if (spec.distinct) out += "DISTINCT "
        var cols
        if (spec.groupBy.length) {
            // grouped: the group fields + a row count
            cols = spec.groupBy.slice()
            cols.push("count(*) AS count")
        } else {
            cols = spec.select.slice()
            for (var i = 0; i < spec.computed.length; i++)
                if (spec.computed[i].expr)
                    cols.push(spec.computed[i].expr + " AS " + (spec.computed[i].alias || "calc"))
        }
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
    // From what was typed by hand we take the condition: everything after WHERE,
    // and if there is no WHERE word we treat the whole text as the condition (that
    // is how filters usually behave).
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
    // THE SORT ORDER for the owner of the table: from the builder or from the
    // typed text - one source, whichever way it was set.
    // a short summary of the conditions - for the tooltip on the icon
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
    // IMPORTANT: assigning `spec = spec` is IMPOSSIBLE - QML skips an assignment
    // of the same object, there is no notification, and everything bound to spec
    // is not updated. So we put a NEW object: that is the "it changed" signal.
    // THE QUERY DOES NOT RUN BY ITSELF. Builder edits only update the
    // specification (visible in the chips and in the query line); the search is
    // started by the Run button. Otherwise every click hit the database and it was
    // unclear what exactly is executed right now.
    function touch() {
        spec = { where: spec.where.slice(),
                 select: spec.select.slice(),
                 groupBy: spec.groupBy.slice(),
                 orderBy: spec.orderBy.slice(),
                 distinct: spec.distinct,
                 computed: spec.computed.slice() }
        dirty = true
    }

    // Set the selection explicitly, when the owner knows the table's columns are
    // settled. Relying on the defaultSelect binding alone made the order of two
    // recomputations decide what the SELECT held.
    function setSelection(list) {
        spec.select = (list && list.slice) ? list.slice() : []
        touch()
    }

    // ---- the selection ----
    function resetSelect() {
        spec.select = defSel().slice()
        touch()
    }
    // THE ORDER OF THE FIELDS IN THE SELECTION = the order of the columns in the
    // table, so it must be changeable rather than only re-typed.
    function moveSelectTo(from, to) {
        var sl = spec.select.slice()
        if (from === to || from < 0 || from >= sl.length) return
        to = Math.max(0, Math.min(sl.length - 1, to))
        var v = sl.splice(from, 1)[0]
        sl.splice(to, 0, v)
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

    // ---- the parts of the query added with the "+" button ----
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

    // add a condition from outside (the "+" button on a table cell)
    // ---- appending to the TYPED TEXT (SQL mode) ----
    // "+" on a cell and sorting must land where the user is looking: if they are
    // typing SQL by hand - straight into the query text.
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

    // By default conditions are joined with AND - that is what people expect.
    function addCondition(field, op, value, join, agoMs) {
        // in SQL mode the condition is appended straight into the typed text
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
                return                       // such a condition already exists
            }
        w.push({ field: field, op: op, value: String(value),
                 join: join || "AND", ago: agoMs || 0 })
        spec.where = w
        builderMode = true
        addClause("where")
        touch()
    }
    // which condition is being edited (-1 - none)
    property int editIndex: -1
    function editCondition(i) { editIndex = i; condPopup.open() }

    // editing one condition: field / operator / value
    function setCond(i, key, v) {
        var w = spec.where.slice()
        if (i < 0 || i >= w.length) return
        var c = { field: w[i].field, op: w[i].op, value: w[i].value,
                  join: w[i].join, ago: w[i].ago || 0 }
        if (key === "value" || key === "field") c.ago = 0   // set by hand
        c[key] = v
        w[i] = c
        spec.where = w
        touch()
    }
    // the upper bound of a range: one `<=` condition on the field, no duplicates
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
        spec = { where: [], select: defSel().slice(), groupBy: [],
                 orderBy: [], distinct: false, computed: [] }
        clauses = []
        manualText = ""
        quickText = ""
        touch()
    }

    // THE CONDITION EDITOR. One for all conditions: a click on a condition opens
    // it here. The field CAN BE CHANGED - with a search over all fields, the
    // operator from a list, the value typed; a time field offers ranges.
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
        // whether the user touched the fields of the arbitrary range
        property bool agoTouched: false
        property string until: ""          // the upper bound; "" = now
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
                // THE FIELD CAN BE CHANGED AT ANY TIME - with a list and a search
                FieldPicker {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Kirigami.Units.gridUnit * 2
                    fields: bar.allFieldNames
                    current: condPopup.cond ? condPopup.cond.field : ""
                    label: "choose a field"
                    onPicked: function (n) { bar.setCond(bar.editIndex, "field", n) }
                }
            }
            // ---- AN ORDINARY CONDITION ----
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
                    // for a search over all fields only the text operators make
                    // sense: comparing "everything" with a number is meaningless
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

            // ---- A TIME CONDITION ----
            // It reads as a phrase: "from ... to ...". The bound is set either by a
            // ready range, by a number of units back, or by the calendar.
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

                // the quick way: "for the last N units"
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

            // ---- THE CALENDAR ----
            // MonthGrid from QtQuick.Controls.Basic: a real month grid, without
            // external dependencies and without the KDE localisation (which needs
            // i18n, and the application has none).
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
                        locale: Qt.locale("en_GB")     // the week starts on Monday
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
                                // local time -> UTC, as it is stored in the database
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
                // Done IS Apply: a separate "apply" button only added a step.
                // A condition is deleted by the cross on itself.
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

    // ---- THE "SHOW ALL" POPUP ----
    // A long list (of selection fields, conditions, sorts, groupings) must not
    // stretch the query panel: two rows of chips stay in the bar and the whole
    // list lives here, with the same actions.
    QQC2.Popup {
        id: morePopup
        modal: false
        parent: bar
        // right under the query bar: a menu, not a window on top of the table
        x: 0
        y: bar.height + Kirigami.Units.smallSpacing
        width: Math.min(bar.width, Kirigami.Units.gridUnit * 22)
        height: Kirigami.Units.gridUnit * 12
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
                // A GROUPING IS NOT ALWAYS A BARE FIELD. "How many per hour",
                // "by the first path segment", "by major version" are all
                // expressions, so besides picking a field one can type one:
                // anything the database understands as a GROUP BY term.
                QQC2.TextField {
                    id: groupExpr
                    visible: bar.moreKind === "group" || bar.moreKind === "order"
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 14
                    placeholderText: "or type an expression: substr(path,1,12)"
                    onAccepted: {
                        var e = text.trim()
                        if (e === "") return
                        morePopup.addField(e)
                        text = ""
                    }
                    QQC2.ToolTip.text: "A function or any SQL expression, then Enter"
                    QQC2.ToolTip.visible: hovered
                }
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
                    // reuseItems is off: while dragging, a delegate must stay
                    // alive as long as it is being dragged
                    delegate: QQC2.ItemDelegate {
                        id: moreRow
                        required property var modelData
                        required property int index
                        width: ListView.view.width
                        height: Kirigami.Units.gridUnit * 2.2
                        // DRAGGING THE SELECTION FIELDS: the order of the fields is
                        // the order of the columns, and changing it with the mouse
                        // is more natural than with arrows. The arrows stay: the
                        // keyboard is more precise.
                        z: dragArea.drag.active ? 2 : 1
                        Drag.active: dragArea.drag.active
                        onClicked: {
                            // a condition is edited in its own popup
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
                                // we move it by as many rows as it was dropped over
                                var step = moreRow.height
                                var delta = Math.round((moreRow.y - startY) / step)
                                moreRow.y = startY          // put it back: the order
                                                            // is set by the model
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
                            }
                            // THE ORDER OF THE FIELDS is set BY DRAGGING the handle
                            // on the left; the arrows were removed as a duplicate.
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

        // ---- the query line + the mode switch ----
        RowLayout {
            Layout.fillWidth: true
            // only in SQL mode; hiding the row EXCLUDES it from the column layout
            // (otherwise its top margin pushes the builder search down)
            visible: !bar.builderMode
            // a top margin brings the SQL field down to the same level as the
            // tabs 'find a table' search
            Layout.topMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                source: "search"
                visible: !bar.builderMode
                opacity: 0.6
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
            }
            // A MULTILINE field: a query is often longer than one line, and in a
            // single line it could not be read. It grows with the content up to 6
            // lines and then scrolls. Enter applies, Shift+Enter is a line break.
            QQC2.ScrollView {
                // In "click it together" mode the field is hidden: the query is read
                // from the builder itself, and a duplicate line only takes space.
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
                    topPadding: Kirigami.Units.smallSpacing
                    bottomPadding: Kirigami.Units.smallSpacing
                    wrapMode: TextEdit.Wrap
                    placeholderText: bar.placeholder
                    readOnly: bar.builderMode
                    // in the builder the field shows the assembled query,
                    // in manual mode what was typed
                    text: bar.builderMode ? bar.fullSql() : bar.manualText
                    onTextChanged: if (!bar.builderMode) bar.manualText = text
                    opacity: bar.builderMode ? 0.75 : 1.0
                    Keys.onReturnPressed: function (ev) {
                        if (ev.modifiers & Qt.ShiftModifier) { ev.accepted = false; return }
                        bar.apply(); ev.accepted = true
                    }
                }
            }
            // AN EXPLICIT RUN: in a multiline field Enter may be a line break, and
            // "when is it going to execute" stopped being obvious.
            // The controls (Run, mode, clear) are AT THE BOTTOM RIGHT
        }

        // ---- THE BUILDER ----
        Rectangle {
            Layout.fillWidth: true
            // The panel IS the "click it together" mode
            visible: bar.builderMode
            implicitHeight: bcol.implicitHeight
            // transparent: the search / group / select controls sit on the white
            // card, so the field matches the left 'find a table' search
            color: "transparent"

            ColumnLayout {
                id: bcol
                // NOT anchors.fill: the height of the panel is computed from bcol,
                // and filling the parent would close that computation on itself
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                spacing: Kirigami.Units.smallSpacing

                // ===== THE SEARCH ROW =====
                // On the left the quick search over all fields (the main action),
                // on the right the parts of the query as COMPACT ICONS with a
                // counter. The details (which fields, which conditions) live in
                // their own popups: 20 fields and 5 conditions never fit into one
                // line, while a counter is read instantly.
                RowLayout {
                    Layout.fillWidth: true
                    // align the builder search with the left / SQL search bars
                    // (2px higher: the field is vertically centred in a row made
                    // taller by the buttons, so it sat a touch low)
                    Layout.topMargin: Kirigami.Units.smallSpacing - 2
                    spacing: Kirigami.Units.smallSpacing

                    Kirigami.SearchField {
                        id: quickField
                        // RESPONSIVE: the field shares the slack with the spacer, so
                        // it grows on a wide window (capped) and SHRINKS when the app
                        // gets narrow, down to a still-usable minimum - instead of
                        // pushing the toolbar buttons off the edge.
                        Layout.fillWidth: true
                        Layout.minimumWidth: Kirigami.Units.gridUnit * 3
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 18
                        Layout.maximumWidth: Kirigami.Units.gridUnit * 24
                        visible: bar.builderMode      // not needed in SQL mode
                        placeholderText: "search in all fields…"
                        text: bar.quickText
                        onTextEdited: {
                            bar.quickText = text
                            // the line was cleared - show everything at once
                            if (text === "") bar.apply()
                        }
                        onAccepted: bar.apply()
                    }

                    Item { Layout.fillWidth: true }
                    // ---- THE SELECTION ----
                    QQC2.ToolButton {
                        icon.name: "view-list-details"
                        text: bar.spec.select.length ? String(bar.spec.select.length) : ""
                        display: bar.spec.select.length ? QQC2.AbstractButton.TextBesideIcon
                                                        : QQC2.AbstractButton.IconOnly
                        QQC2.ToolTip.text: "Fields in the query: add, remove, reorder"
                        QQC2.ToolTip.visible: hovered
                        onClicked: { bar.moreKind = "select"; morePopup.open() }
                    }
                    // ---- THE CONDITIONS ----
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
                    // ---- THE GROUPING ----
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
                    // ---- THE SORTING ----
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
                    // (a table-JOIN builder was removed in the v1 cleanup: state
                    // tables are related through SQL / the graph, not a join UI)
                    // ---- UNIQUE (DISTINCT) + a calculated field, direct buttons
                    // on the LEFT with the other functions (no "…" menu) ----
                    QQC2.ToolButton {
                        icon.name: "edit-duplicate"
                        text: bar.spec.distinct ? "Unique" : ""
                        display: bar.spec.distinct ? QQC2.AbstractButton.TextBesideIcon
                                                   : QQC2.AbstractButton.IconOnly
                        checkable: true
                        checked: bar.spec.distinct
                        highlighted: bar.spec.distinct
                        QQC2.ToolTip.text: "Unique rows (DISTINCT)"
                        QQC2.ToolTip.visible: hovered
                        onClicked: {
                            bar.spec.distinct = checked
                            if (checked) bar.addClause("distinct")
                            else bar.dropClause("distinct")
                            bar.touch()
                        }
                    }
                    QQC2.ToolButton {
                        icon.name: "insert-math-expression"
                        QQC2.ToolTip.text: "Calculated field"
                        QQC2.ToolTip.visible: hovered
                        onClicked: { bar.addClause("calc"); bar.editingCalc = true }
                    }
                    // ---- THE BUTTON GROUPS ARE SEPARATED: the parts of the query
                    // on the left, working with queries (save, history) in the
                    // middle, running and the mode on the right ----
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
                    // ---- RUNNING AND THE MODE ----
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
                        // while the query has not changed there is nothing to run
                        enabled: bar.dirty
                        highlighted: bar.dirty
                        QQC2.ToolTip.text: bar.dirty ? "Run the query"
                                                     : "Nothing changed since the last run"
                        QQC2.ToolTip.visible: hovered
                        onClicked: bar.apply()
                    }
                    QQC2.ToolButton {
                        icon.name: "overflow-menu"
                        QQC2.ToolTip.text: "SQL: write by hand, history, save/use from expertise"
                        QQC2.ToolTip.visible: hovered
                        onClicked: sqlMenu.popup()
                        QQC2.Menu {
                            id: sqlMenu
                            QQC2.MenuItem {
                                text: "Write SQL"
                                icon.name: "code-context"
                                onTriggered: {
                                    bar.manualText = bar.fullSql()
                                    bar.builderMode = false
                                    bar.apply()
                                }
                            }
                            QQC2.MenuItem {
                                text: "SQL history…"
                                icon.name: "view-history"
                                onTriggered: bar.historyRequested()
                            }
                            QQC2.MenuSeparator {}
                            QQC2.MenuItem {
                                text: "Save to expertise…"
                                icon.name: "document-save"
                                onTriggered: bar.saveToExpertise(bar.fullSql())
                            }
                            QQC2.MenuItem {
                                text: "Use from expertise…"
                                icon.name: "document-open"
                                onTriggered: bar.useExpertiseRequested()
                            }
                        }
                    }

                }

                // the calculated field input - only while one is being added
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

                // manual mode: the same controls under the SQL line
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
            QQC2.ToolButton {
                icon.name: "overflow-menu"
                QQC2.ToolTip.text: "Build by clicking, history, save/use from expertise"
                QQC2.ToolTip.visible: hovered
                onClicked: sqlMenu2.popup()
                QQC2.Menu {
                    id: sqlMenu2
                    QQC2.MenuItem {
                        text: "Build the query by clicking"
                        icon.name: "draw-freehand"
                        onTriggered: { bar.builderMode = true; bar.apply() }
                    }
                    QQC2.MenuItem {
                        text: "SQL history…"
                        icon.name: "view-history"
                        onTriggered: bar.historyRequested()
                    }
                    QQC2.MenuSeparator {}
                    QQC2.MenuItem {
                        text: "Save to expertise…"
                        icon.name: "document-save"
                        onTriggered: bar.saveToExpertise(bar.fullSql())
                    }
                    QQC2.MenuItem {
                        text: "Use from expertise…"
                        icon.name: "document-open"
                        onTriggered: bar.useExpertiseRequested()
                    }
                }
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

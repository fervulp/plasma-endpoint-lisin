import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

// Уязвимости — не инвентарь «что есть», а список задач «что пропатчить».
// Поэтому в строке сразу: статус (открыта/закрыта), балл CVSS с вектором,
// критичность вендора, какие УСТАНОВЛЕННЫЕ пакеты затронуты, какая версия
// стоит и какая чинит, дата бюллетеня, источник данных и готовая команда.
//
// Закрытые показываются намеренно: обновив систему, пользователь должен
// увидеть ответ «патч установлен», а не пустой экран, по которому нельзя
// отличить успешное обновление от сломавшегося сбора данных.
Item {
    id: view
    property var d: ({ rows: [], total: 0, open: 0, closed: 0,
                       by_severity: ({}), by_cvss: ({}), scored: 0, source: "" })
    // Open by default: closed advisories are history, the actionable
    // list is what is still unpatched.
    property string statusFilter: "open"
    property string cvssFilter: ""
    property string search: ""
    // Запрос из общей строки: либо условия вида `поле оп 'значение'`,
    // либо просто текст — тогда ищем его по всем полям строки.
    property string query: ""
    property var hiddenCols: []
    // сортировка кликом по заголовку: направление показывается иконкой
    property string sortCol: ""
    property bool sortDesc: false
    function sortBy(k) {
        if (sortCol === k) sortDesc = !sortDesc
        else { sortCol = k; sortDesc = false }
    }
    // СТАРЫЙ РАЗБОР УСЛОВИЯ ОСТАВЛЕН НЕ БЫЛ: он делил строку по « AND » и
    // не понимал ни OR, ни NOT, ни MATCH. Теперь фильтрует база (vulnRows).
    function matchQueryUnused(x) {
        var q = String(view.query || "").trim()
        if (q === "") return true
        var parts = q.split(" AND ")
        var ok = true
        for (var i = 0; i < parts.length; i++) {
            var m = parts[i].match(/^"?([\w_]+)"?\s*(=|<>|LIKE|NOT LIKE|>|<|>=|<=)\s*'(.*)'$/)
            if (!m) {                       // не условие — свободный поиск
                var hay = ""
                for (var k in x) hay += " " + String(x[k])
                if (hay.toLowerCase().indexOf(parts[i].toLowerCase().trim()) < 0) ok = false
                continue
            }
            var v = String(x[m[1]] === undefined ? "" : x[m[1]])
            var t = m[3], op = m[2]
            if (op === "=") ok = ok && v === t
            else if (op === "<>") ok = ok && v !== t
            else if (op === "LIKE") ok = ok && v.toLowerCase().indexOf(t.toLowerCase()) >= 0
            else if (op === "NOT LIKE") ok = ok && v.toLowerCase().indexOf(t.toLowerCase()) < 0
            else {
                var a = parseFloat(v), b = parseFloat(t)
                if (isNaN(a) || isNaN(b)) ok = false
                else ok = ok && (op === ">" ? a > b : op === "<" ? a < b
                                : op === ">=" ? a >= b : a <= b)
            }
        }
        return ok
    }
    property string openKey: ""
    // The active filter shown as SQL, the way the Events page does it: the
    // condition is never hidden — you can read it and see what is selected.
    readonly property string whereText: {
        var c = []
        if (statusFilter !== "") c.push("status = '" + statusFilter + "'")
        if (cvssFilter !== "") c.push("cvss_rating = '" + cvssFilter + "'")
        if (query.trim() !== "") c.push(query.trim())
        return c.length ? c.join(" AND ") : "(no filter — all advisories)"
    }

    // сводка (счётчики по критичности) — из полного набора; сами строки —
    // по условию, собранному строкой запроса и чипами
    function refresh() {
        view.d = backend.vulnerabilities()
        view.reloadRows()
    }
    property var rowsFiltered: []
    function sqlWhere() {
        var c = []
        if (statusFilter !== "") c.push("status = '" + statusFilter + "'")
        if (cvssFilter !== "") c.push("cvss_rating = '" + cvssFilter + "'")
        var q = String(view.query || "").trim()
        if (q !== "") c.push(view.hasOperator(q) ? q : view.freeText(q))
        return c.join(" AND ")
    }
    // есть ли в строке оператор — тогда это условие, иначе свободный поиск
    function hasOperator(q) {
        return /(=|<>|<|>|LIKE|IS NULL|IS NOT NULL)/i.test(q)
    }
    // свободный текст ищем по осмысленным полям бюллетеня
    function freeText(q) {
        var f = ["title", "packages", "cve", "advisory", "severity",
                 "cvss_rating", "description", "installed_version", "fixed_version"]
        var e = q.replace(/'/g, "''")
        var parts = []
        for (var i = 0; i < f.length; i++)
            parts.push('"' + f[i] + "\" LIKE '%" + e + "%'")
        return "(" + parts.join(" OR ") + ")"
    }
    function reloadRows() {
        var r = backend.vulnRows(view.sqlWhere())
        view.rowsFiltered = r.rows || []
        view.rowsError = r.error || ""
    }
    property string rowsError: ""
    onQueryChanged: view.reloadRows()
    onStatusFilterChanged: view.reloadRows()
    onCvssFilterChanged: view.reloadRows()
    Component.onCompleted: refresh()
    Connections {
        target: backend
        function onStateReady(s) { view.refresh() }
    }

    // цвет по БАЛЛУ CVSS — он сравним между бюллетенями, в отличие от
    // словесной критичности, которую каждый вендор трактует по-своему
    function cvssColor(r) {
        return r === "Critical" ? "#c0392b" : r === "High" ? "#e74c3c"
             : r === "Medium" ? "#e67e22" : r === "Low" ? "#f1c40f"
             : Kirigami.Theme.disabledTextColor
    }

    // ---- TABLE COLUMNS ----
    // One definition read by both the header and every row.
    readonly property var cols: [
        { k: "cvss",      t: "CVSS",      w: 3.6, right: true, mono: true },
        { k: "status",    t: "Status",    w: 5.0 },
        { k: "severity",  t: "Severity",  w: 5.4 },
        { k: "packages",  t: "Packages",  fill: true },
        { k: "installed", t: "Installed", w: 8.0, mono: true },
        { k: "fixed",     t: "Fixed in",  w: 8.0, mono: true },
        { k: "cve",       t: "CVE",       w: 3.4, right: true },
        { k: "issued",    t: "Issued",    w: 6.0, mono: true }
    ]
    readonly property var shownCols: {
        var out = []
        for (var i = 0; i < cols.length; i++)
            if (hiddenCols.indexOf(cols[i].k) < 0) out.push(cols[i])
        return out
    }
    readonly property var sel: {
        var r = shown
        for (var i = 0; i < r.length; i++)
            if (r[i].advisory === openKey) return r[i]
        return null
    }
    function sevColor(r) {
        if (r.cvss_rating) return view.cvssColor(r.cvss_rating)
        return r.severity === "Critical" ? "#c0392b"
             : r.severity === "Important" ? "#e74c3c"
             : r.severity === "Moderate" ? "#e67e22" : "#f1c40f"
    }
    function cell(r, k) {
        if (k === "cvss") return r.cvss_score || ""
        if (k === "status") return r.status === "open" ? "open" : "patched"
        if (k === "severity") return r.severity || ""
        if (k === "packages") return r.packages || r.advisory || ""
        if (k === "installed") return r.installed_version || ""
        if (k === "fixed") return r.fixed_version || ""
        if (k === "cve") return r.cve_count && r.cve_count !== "0" ? r.cve_count : ""
        if (k === "issued") return String(r.issued || "").substring(0, 10)
        return ""
    }
    function detailRows(r) {
        return [
            { k: "Advisory",     v: r.advisory },
            { k: "What to do",   v: r.action },
            { k: "CVE",          v: r.cve },
            { k: "CVSS vector",  v: r.cvss_vector },
            { k: "Score source", v: r.cvss_source
                                    + (r.cvss_covered ? "   (CVEs scored: "
                                                        + r.cvss_covered + ")" : "") },
            { k: "Packages",     v: r.packages },
            { k: "Installed",    v: r.installed_version },
            { k: "Fixed in",     v: r.fixed_version },
            { k: "Issued",       v: r.issued },
            { k: "Data source",  v: r.source },
            { k: "References",   v: r.references },
            { k: "Description",  v: r.description }
        ]
    }

    // строки приходят уже отфильтрованными базой
    property var shown: view.rowsFiltered

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- шапка: ответ на вопрос «всё ли закрыто» одной строкой ----
        Kirigami.AbstractCard {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            contentItem: RowLayout {
                spacing: Kirigami.Units.largeSpacing
                Kirigami.Icon {
                    source: view.d.open > 0 ? "security-low" : "security-high"
                    implicitWidth: Kirigami.Units.iconSizes.large
                    implicitHeight: Kirigami.Units.iconSizes.large
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Kirigami.Heading {
                        level: 3
                        text: view.d.open > 0
                              ? "Open vulnerabilities: " + view.d.open
                              : "No open vulnerabilities"
                        color: view.d.open > 0 ? "#e74c3c"
                                               : Kirigami.Theme.positiveTextColor
                    }
                    QQC2.Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        opacity: 0.75
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        text: "Patched: " + view.d.closed
                              + "  ·  CVSS scored: " + view.d.scored
                              + " of " + view.d.total
                              + "  ·  source: " + (view.d.source || "—")
                              + "  ·  CVSS score: NVD / OSV.dev"
                    }
                }
                // AVAILABLE SECURITY UPDATES — one command that closes every
                // open advisory at once. Shown only when there is something to
                // install, so it never reads as a suggestion to run commands
                // for no reason.
                ColumnLayout {
                    visible: view.d.open > 0
                    spacing: 2
                    QQC2.Label {
                        text: "Security updates available"
                        font.bold: true
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                    RowLayout {
                        spacing: Kirigami.Units.smallSpacing
                        QQC2.Label {
                            id: upCmd
                            text: "sudo dnf upgrade --security"
                            font.family: "monospace"
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                        QQC2.ToolButton {
                            icon.name: "edit-copy"
                            QQC2.ToolTip.text: "Copy the command"
                            QQC2.ToolTip.visible: hovered
                            onClicked: {
                                clipHelper.text = upCmd.text
                                clipHelper.selectAll()
                                clipHelper.copy()
                            }
                        }
                    }
                }
            }
        }
        // off-screen helper: TextEdit is the supported way to reach the clipboard
        TextEdit { id: clipHelper; visible: false }

        // ---- фильтры: статус и уровень CVSS ----
        Flow {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            QQC2.Button {
                text: "All (" + view.d.total + ")"
                checkable: true
                checked: view.statusFilter === "" && view.cvssFilter === ""
                onClicked: { view.statusFilter = ""; view.cvssFilter = "" }
            }
            QQC2.Button {
                text: "Open (" + view.d.open + ")"
                checkable: true
                checked: view.statusFilter === "open"
                enabled: view.d.open > 0
                onClicked: { view.statusFilter = checked ? "open" : ""
                             view.cvssFilter = "" }
            }
            QQC2.Button {
                text: "Closed (" + view.d.closed + ")"
                checkable: true
                checked: view.statusFilter === "closed"
                onClicked: { view.statusFilter = checked ? "closed" : ""
                             view.cvssFilter = "" }
            }
            Repeater {
                model: ["Critical", "High", "Medium", "Low"]
                QQC2.Button {
                    visible: (view.d.by_cvss[modelData] || 0) > 0
                    text: "CVSS " + modelData + " (" + (view.d.by_cvss[modelData] || 0) + ")"
                    checkable: true
                    checked: view.cvssFilter === modelData
                    onClicked: view.cvssFilter = checked ? modelData : ""
                }
            }
        }

        // ЕДИНАЯ СТРОКА ЗАПРОСА — та же, что во всех остальных таблицах.
        // Можно набрать условие руками или накликать конструктором.
        QueryBar {
            id: qbar
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.largeSpacing
            Layout.rightMargin: Kirigami.Units.largeSpacing
            Layout.topMargin: Kirigami.Units.smallSpacing
            fields: view.cols.map(function (c) { return { name: c.k } })
            // от ОПИСАНИЯ колонок, а не от текущих видимых: shownCols сам
            // зависит от результата запроса — вышла бы петля привязки
            defaultSelect: view.cols.map(function (c) { return c.k })
            placeholder: "severity = 'Important'   ·   or just type text to search"
            onApplied: function (spec, sql) {
                // SELECT задаёт видимые колонки таблицы
                var hide = []
                if (spec.select.length)
                    for (var i = 0; i < view.cols.length; i++)
                        if (spec.select.indexOf(view.cols[i].k) < 0)
                            hide.push(view.cols[i].k)
                view.hiddenCols = hide
                view.query = sql
            }
        }

        // ---- the active filter, written out as SQL ----
        // The same idea as on the Events page: the condition is never hidden,
        // so it is obvious that "open only" is preselected rather than the
        // list being mysteriously short.
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            Layout.topMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing
            Kirigami.Icon {
                source: "view-filter"
                opacity: 0.6
                implicitWidth: Kirigami.Units.iconSizes.small
                implicitHeight: Kirigami.Units.iconSizes.small
            }
            QQC2.Label {
                Layout.fillWidth: true
                text: view.whereText
                elide: Text.ElideRight
                opacity: 0.7
                font.family: "monospace"
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
            QQC2.Label {
                text: view.shown.length + " of " + view.d.total
                opacity: 0.6
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
        }

        // ---- ADVISORY TABLE ----
        // Many rows of the same shape are a table, like State and Events.
        // Header and rows read one column list, so widths cannot drift apart.
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.largeSpacing
            Layout.rightMargin: Kirigami.Units.largeSpacing
            Layout.topMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing
            Repeater {
                model: view.shownCols
                delegate: QQC2.Label {
                    required property var modelData
                    Layout.preferredWidth: modelData.fill === true
                        ? -1 : Kirigami.Units.gridUnit * modelData.w
                    Layout.fillWidth: modelData.fill === true
                    text: modelData.t
                    opacity: 0.6
                    font.bold: true
                    elide: Text.ElideRight
                    horizontalAlignment: modelData.right === true
                        ? Text.AlignRight : Text.AlignLeft
                    font.pointSize: Kirigami.Theme.smallFont.pointSize - 1
                }
            }
        }
        Kirigami.Separator { Layout.fillWidth: true }

        QQC2.ScrollView {
            id: scroller
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.leftMargin: Kirigami.Units.largeSpacing
            Layout.rightMargin: Kirigami.Units.largeSpacing
            clip: true

            ListView {
                id: vulnList
                model: view.shown
                reuseItems: true
                cacheBuffer: Kirigami.Units.gridUnit * 40

                delegate: QQC2.ItemDelegate {
                    id: row
                    required property var modelData
                    required property int index
                    width: ListView.view.width
                    height: Kirigami.Units.gridUnit * 2
                    onClicked: view.openKey =
                        (view.openKey === modelData.advisory) ? "" : modelData.advisory
                    background: Rectangle {
                        color: row.hovered
                               ? Qt.alpha(Kirigami.Theme.textColor, 0.06)
                               : (row.index % 2 ? Qt.alpha(Kirigami.Theme.textColor, 0.03)
                                                : "transparent")
                        // severity reads as a left accent, so type and
                        // urgency stay visually separate
                        Rectangle {
                            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                            width: 3
                            color: view.sevColor(row.modelData)
                            visible: row.modelData.status === "open"
                        }
                    }
                    contentItem: RowLayout {
                        spacing: Kirigami.Units.smallSpacing
                        Repeater {
                            model: view.shownCols
                            delegate: QQC2.Label {
                                required property var modelData
                                Layout.preferredWidth: modelData.fill === true
                                    ? -1 : Kirigami.Units.gridUnit * modelData.w
                                Layout.fillWidth: modelData.fill === true
                                text: view.cell(row.modelData, modelData.k)
                                elide: Text.ElideRight
                                opacity: text === "" ? 0 : 0.9
                                horizontalAlignment: modelData.right === true
                                    ? Text.AlignRight : Text.AlignLeft
                                font.family: modelData.mono === true
                                    ? "monospace" : Kirigami.Theme.defaultFont.family
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                color: modelData.k === "status" && row.modelData.status === "open"
                                       ? view.sevColor(row.modelData)
                                       : Kirigami.Theme.textColor
                            }
                        }
                    }
                }
            }
        }

        // ---- details of the selected advisory ----
        // A table row cannot hold a description and a list of CVEs, so the
        // full record opens below it instead of stretching the row.
        QQC2.ScrollView {
            id: detailScroll
            Layout.fillWidth: true
            Layout.preferredHeight: Kirigami.Units.gridUnit * 12
            Layout.leftMargin: Kirigami.Units.largeSpacing
            Layout.rightMargin: Kirigami.Units.largeSpacing
            Layout.bottomMargin: Kirigami.Units.smallSpacing
            visible: view.sel !== null
            clip: true
            contentWidth: availableWidth
            ColumnLayout {
                width: detailScroll.availableWidth
                spacing: 2
                RowLayout {
                    Layout.fillWidth: true
                    Kirigami.Heading {
                        level: 4
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        text: view.sel ? (view.sel.title || view.sel.advisory) : ""
                    }
                    QQC2.ToolButton {
                        icon.name: "window-close"
                        onClicked: view.openKey = ""
                    }
                }
                Repeater {
                    model: view.sel ? view.detailRows(view.sel) : []
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        visible: String(modelData.v).trim() !== ""
                        QQC2.Label {
                            text: modelData.k
                            opacity: 0.6
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 10
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                        QQC2.Label {
                            Layout.fillWidth: true
                            text: String(modelData.v)
                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                    }
                }
            }
        }
    }
}

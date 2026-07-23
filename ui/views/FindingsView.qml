import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components"

// WHAT IS WRONG AND WHAT TO DO ABOUT IT - not "how many of each".
//
// Built on the shared templates (principle 15/17): one QueryBar, one DataTable,
// one SidePanel. It used to be a hand-written list of cards: each card had its
// own height, the severity was a coloured bar inside the card, and the evidence
// unfolded in place and pushed everything below it. A finding is a row like any
// other - the long text (why / what to do / the evidence) belongs in the side
// panel, not in the row.
Item {
    id: view
    property var d: ({ findings: [], total: 0, high: 0, medium: 0, low: 0 })
    property var sel: null
    property string query: ""

    // one description of the columns, read by the header and by the rows
    readonly property var cols: [
        { k: "severity", t: "Severity", w: 6 },
        { k: "title", t: "Finding", w: 24, fill: true },
        { k: "objects", t: "Objects", w: 5, right: true, mono: true },
        { k: "when", t: "Last seen", w: 10, mono: true },
        { k: "rule", t: "Rule", w: 12, mono: true },
        { k: "source", t: "Source", w: 6 }
    ]
    property var hiddenCols: []

    function refresh() { view.d = backend.systemFindings() }
    Component.onCompleted: refresh()
    Connections {
        target: backend
        function onStateReady(s) { view.refresh() }
    }

    function sevColor(s) {
        return s === "high" ? "#e74c3c" : s === "medium" ? "#e67e22" : "#f1c40f"
    }
    // the severity is an accent on the row, not an extra line of text: that is
    // what keeps every row the same height
    function rowAccent(r) { return r ? sevColor(r.severity) : "" }

    // A finding carries a list of evidence; the table shows how many there are,
    // the panel shows them in full.
    readonly property var rows: {
        var out = []
        var f = view.d.findings || []
        for (var i = 0; i < f.length; i++) {
            var r = f[i]
            out.push({ severity: r.severity || "", title: r.title || "",
                       objects: (r.evidence || []).length,
                       when: r.when || "", rule: r.rule || "",
                       source: r.source || "", _f: r })
        }
        return out
    }

    // The condition is evaluated here because the findings are computed in
    // Python and never touch a database - there is nothing to hand an SQL
    // string to. The syntax is the same one the query bar produces.
    readonly property var shown: {
        var q = (view.query || "").trim()
        if (q === "") return view.rows
        var m = q.match(/^\s*(\w+)\s*(=|<>|!=|LIKE|NOT LIKE)\s*'?([^']*)'?\s*$/i)
        var out = []
        for (var i = 0; i < view.rows.length; i++) {
            var r = view.rows[i]
            if (m) {
                var v = String(r[m[1]] === undefined ? "" : r[m[1]]).toLowerCase()
                var want = m[3].toLowerCase()
                var op = m[2].toUpperCase()
                var hit = op === "=" ? v === want
                        : (op === "<>" || op === "!=") ? v !== want
                        : op === "LIKE" ? v.indexOf(want.replace(/%/g, "")) >= 0
                        : v.indexOf(want.replace(/%/g, "")) < 0
                if (hit) out.push(r)
            } else {
                var hay = (r.title + " " + r.severity + " " + r.rule + " " +
                           (r._f.why || "") + " " + (r._f.action || "")).toLowerCase()
                if (hay.indexOf(q.toLowerCase()) >= 0) out.push(r)
            }
        }
        return out
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.largeSpacing
                Kirigami.Heading { level: 3; text: "Needs Attention" }
                Repeater {
                    model: [{ k: "high", t: "critical" }, { k: "medium", t: "important" },
                            { k: "low", t: "worth a look" }]
                    QQC2.ToolButton {
                        required property var modelData
                        // a severity chip is a shortcut for a condition, and it
                        // writes into the SAME query bar - one source of truth
                        onClicked: qbar.addCondition("severity", "=", modelData.k)
                        contentItem: RowLayout {
                            spacing: Kirigami.Units.smallSpacing
                            Rectangle {
                                width: Kirigami.Units.gridUnit * 0.7; height: width
                                radius: 3; color: view.sevColor(modelData.k)
                            }
                            QQC2.Label {
                                text: modelData.t + "  " +
                                      (modelData.k === "high" ? view.d.high
                                       : modelData.k === "medium" ? view.d.medium : view.d.low)
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                        }
                    }
                }
                Item { Layout.fillWidth: true }
                QQC2.Label {
                    text: view.shown.length + " of " + view.rows.length
                    opacity: 0.6
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
                QQC2.ToolButton { icon.name: "view-refresh"; onClicked: view.refresh() }
            }

            QueryBar {
                id: qbar
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                fields: view.cols.map(function (c) { return { name: c.k } })
                defaultSelect: view.cols.map(function (c) { return c.k })
                placeholder: "severity = 'high'   ·   or just type text to search"
                onApplied: function (spec, sql) {
                    var hide = []
                    if (spec.select.length)
                        for (var i = 0; i < view.cols.length; i++)
                            if (spec.select.indexOf(view.cols[i].k) < 0)
                                hide.push(view.cols[i].k)
                    view.hiddenCols = hide
                    view.query = qbar.builderMode ? qbar.buildSql() : qbar.manualWhere()
                }
            }
            Kirigami.Separator { Layout.fillWidth: true }

            DataTable {
                id: table
                Layout.fillWidth: true
                Layout.fillHeight: true
                columns: view.cols
                rows: view.shown
                hidden: view.hiddenCols
                accent: view.rowAccent
                onRowActivated: function (row) { view.sel = row }
                onConditionRequested: function (field, op, value) {
                    qbar.addCondition(field, op, value)
                }
            }

            Kirigami.PlaceholderMessage {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.largeSpacing
                visible: view.shown.length === 0
                icon.name: "checkmark"
                text: "Nothing suspicious found"
                explanation: "Checks exposed ports, privilege escalation, persistence, " +
                             "unpackaged processes, file integrity and kernel parameters."
            }
        }

        SidePanel {
            id: side
            Layout.fillHeight: true
            open: view.sel !== null
            title: view.sel ? view.sel.title : ""
            iconName: "dialog-warning"
            onCloseRequested: view.sel = null

            QQC2.ScrollView {
                id: scroller
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                ColumnLayout {
                    // the width comes from the id of the ScrollView itself:
                    // parent.parent inside a ScrollView gives the wrong width
                    width: scroller.availableWidth
                    spacing: Kirigami.Units.smallSpacing

                    // WHY / WHAT TO DO / WHERE WE KNOW IT FROM - principle 6.
                    Repeater {
                        model: view.sel ? [
                            { i: "help-about", t: "Why it matters", v: view.sel._f.why || "" },
                            { i: "dialog-ok-apply", t: "What to do", v: view.sel._f.action || "" },
                            { i: "documentinfo", t: "On what basis", v: view.sel._f.reference || "" }
                        ] : []
                        delegate: ColumnLayout {
                            required property var modelData
                            visible: modelData.v !== ""
                            Layout.fillWidth: true
                            spacing: 2
                            RowLayout {
                                spacing: Kirigami.Units.smallSpacing
                                Kirigami.Icon {
                                    source: modelData.i
                                    implicitWidth: Kirigami.Units.iconSizes.small
                                    implicitHeight: Kirigami.Units.iconSizes.small
                                }
                                QQC2.Label {
                                    text: modelData.t; font.bold: true
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                }
                            }
                            QQC2.Label {
                                Layout.fillWidth: true
                                text: modelData.v
                                wrapMode: Text.WordWrap
                                opacity: 0.85
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                        }
                    }

                    QQC2.Button {
                        Layout.fillWidth: true
                        visible: view.sel && view.sel._f.table !== ""
                        text: "Show in State"
                        icon.name: "search"
                        onClicked: root.focusState(view.sel._f.table, view.sel._f.col,
                                                   view.sel._f.val)
                    }

                    Kirigami.Separator { Layout.fillWidth: true }
                    QQC2.Label {
                        text: "Evidence (" + (view.sel ? (view.sel._f.evidence || []).length : 0) + ")"
                        font.bold: true
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                    Repeater {
                        model: view.sel ? (view.sel._f.evidence || []) : []
                        delegate: QQC2.Label {
                            required property var modelData
                            Layout.fillWidth: true
                            text: modelData
                            wrapMode: Text.WrapAnywhere
                            font.family: "monospace"
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            opacity: 0.85
                        }
                    }
                }
            }
        }
    }
}

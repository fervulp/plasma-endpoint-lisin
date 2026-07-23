import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components"
import "../components/QueryMatch.js" as QM
import "../components/Fmt.js" as Fmt

// PRIVILEGE ESCALATION: both the EVENTS (who did what through sudo, failed
// logins) and the STANDING VECTORS (capabilities, NOPASSWD, SUID, polkit).
// One is useless without the other: events say "what happened", vectors say
// "what else could be used".
//
// Built on the shared templates (principle 17): one query bar, one table, one
// side panel. Two datasets of a different shape cannot share one table, so the
// switch at the top says which one is on screen - and both are tables.
Item {
    id: view
    property var d: ({ events: [], vectors: [], suid: [], admins: [], polkit: [], total: 0 })
    property var sel: null
    property string query: ""
    property var qconds: []
    property string qquick: ""
    property string mode: "vectors"      // vectors | events | admins

    readonly property var colsVectors: [
        { k: "changed", t: "Changed", w: 10, mono: true },
        { k: "age_days", t: "Age, days", w: 6, right: true, mono: true },
        { k: "kind", t: "Kind", w: 8 },
        { k: "name", t: "Object", w: 22, fill: true, mono: true },
        { k: "detail", t: "Detail", w: 18 },
        { k: "risk", t: "Risk", w: 5 },
        { k: "package", t: "Package", w: 10 }
    ]
    readonly property var colsEvents: [
        { k: "ts", t: "Time", w: 11, mono: true },
        { k: "subject_name", t: "Who", w: 10 },
        { k: "event_action", t: "Action", w: 12 },
        { k: "event_outcome", t: "Outcome", w: 7 },
        { k: "process_name", t: "Process", w: 10, mono: true },
        { k: "message", t: "Message", w: 30, fill: true }
    ]
    readonly property var colsAdmins: [
        { k: "name", t: "User", w: 10 },
        { k: "privilege", t: "Privilege", w: 10 },
        { k: "admin_groups", t: "Through", w: 20, fill: true },
        { k: "shell", t: "Shell", w: 14, mono: true }
    ]
    readonly property var cols: mode === "events" ? colsEvents
                              : mode === "admins" ? colsAdmins : colsVectors
    property var hiddenCols: []

    property bool _stale: false
    onVisibleChanged: if (view.visible && view._stale) { view._stale = false; view.refresh() }
    function refresh() { view.d = backend.privescActivity() }
    Component.onCompleted: refresh()
    Connections {
        target: backend
        // REFRESH ONLY WHEN SHOWN. The page is kept alive; a hidden one
        // still receives every tick, and recomputing a dashboard the user is not
        // looking at burns CPU and stalls the animation of the page they ARE
        // opening. We mark it stale and catch up when it becomes visible.
        function onStateReady(s) { if (view.visible) view.refresh(); else view._stale = true }
    }

    // THE TIME IS MANDATORY (principle 6): a vector without a date cannot be
    // tied to an incident. For a vector that is the mtime of its carrier, for
    // an event its own time; both are shown in the local zone.
    function fmt(row, key) {
        if (key === "ts") return Fmt.local(row.ts)
        if (key === "changed") return Fmt.localShort(row.changed)
        return undefined
    }
    function rowAccent(r) {
        if (!r) return ""
        if (r.risk === "high" || r.event_outcome === "failure") return "#e74c3c"
        if (r.nopasswd === "yes" || r.privilege === "admin") return "#e67e22"
        return ""
    }

    readonly property var rows: mode === "events" ? (d.events || [])
                              : mode === "admins" ? (d.admins || []) : (d.vectors || [])
    readonly property var shown: {
        var _ = [view.qconds, view.qquick, view.rows]
        if (!view.qquick && (!view.qconds || !view.qconds.length)) return view.rows
        var out = []
        for (var i = 0; i < view.rows.length; i++)
            if (QM.rowMatches(view.rows[i], view.qconds, view.qquick, view.cols))
                out.push(view.rows[i])
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
                spacing: Kirigami.Units.smallSpacing
                Kirigami.Heading { level: 3; text: "Privilege use" }
                Item { width: Kirigami.Units.largeSpacing }
                QQC2.ButtonGroup { id: modeGroup }
                Repeater {
                    model: [{ k: "vectors", t: "Standing vectors" },
                            { k: "events", t: "Events" },
                            { k: "admins", t: "Who is admin" }]
                    QQC2.ToolButton {
                        required property var modelData
                        checkable: true
                        QQC2.ButtonGroup.group: modeGroup
                        checked: view.mode === modelData.k
                        text: modelData.t + " (" +
                              (modelData.k === "vectors" ? (view.d.vectors || []).length
                               : modelData.k === "events" ? (view.d.events || []).length
                               : (view.d.admins || []).length) + ")"
                        onClicked: { view.mode = modelData.k; view.sel = null }
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
                placeholder: "risk = 'high'   ·   or just type text to search"
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

            DataTable {
                Layout.fillWidth: true
                Layout.fillHeight: true
                columns: view.cols
                rows: view.shown
                hidden: view.hiddenCols
                accent: view.rowAccent
                formatter: view.fmt
                onRowActivated: function (row) { view.sel = row }
                onConditionRequested: function (field, op, value) {
                    qbar.addCondition(field, op, value)
                }
            }
        }

        SidePanel {
            id: side
            Layout.fillHeight: true
            open: view.sel !== null
            title: view.sel ? (view.sel.name || view.sel.event_action || "") : ""
            iconName: "security-medium"
            onCloseRequested: view.sel = null

            QQC2.ScrollView {
                id: scroller
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                ColumnLayout {
                    width: scroller.availableWidth
                    spacing: 2
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
                                text: String(view.sel[modelData])
                                wrapMode: Text.WrapAnywhere
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                        }
                    }
                    QQC2.Button {
                        Layout.fillWidth: true
                        visible: view.mode === "vectors" && view.sel && view.sel.name
                        text: "Show in State"
                        icon.name: "search"
                        onClicked: root.focusState("privesc", "name", view.sel.name)
                    }
                }
            }
        }
    }
}

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "Fmt.js" as Fmt

// THE ENGINE, SAID OUT LOUD.
//
// Everything on this card was previously invisible from outside the source: which
// process owns the databases, how far behind the normalization is, how much of a
// database file is empty space and when it was last rewritten, how long a
// collection cycle takes, and that a process exit is written onto its start
// rather than kept as its own row. Each of those has surprised me at least once
// while building this — and the only way to find out was to read the code.
//
// Every figure is a measurement, not a setting: what IS, with the limit it is
// measured against next to it. A number with no limit tells you nothing, and a
// limit with no number is a promise.
Item {
    id: card
    property var state: ({})
    property bool expanded: false
    implicitHeight: col.implicitHeight + Kirigami.Units.largeSpacing

    readonly property var dbs: (state && state.databases) ? state.databases : []
    readonly property var stream: (state && state.stream) ? state.stream : ({})
    readonly property var coll: (state && state.collection) ? state.collection : ({})

    function mb(v) { return (v === undefined ? "?" : Number(v).toFixed(0)) + " MB" }

    function db(name) {
        for (var i = 0; i < dbs.length; i++)
            if (String(dbs[i].name) === name) return dbs[i]
        return null
    }
    function dbLine(name) {
        var d = db(name)
        if (!d) return "—"
        return mb(d.file_mb) + " on disk, " + mb(d.used_mb) + " of it data"
               + (d.free_share !== undefined
                  ? " (" + Math.round(d.free_share * 100) + "% free space)" : "")
    }
    function dbDetail(name) {
        var d = db(name)
        if (!d) return ""
        return "DuckDB never returns freed blocks to the system: retention deletes "
             + "rows, tables are replaced whole every cycle, and the file only "
             + "grows. It is rewritten when a third of it is empty — atomically, so "
             + "an interruption leaves the original file. "
             + (d.compacted_at
                ? "Last rewrite " + Fmt.maybeLocal(d.compacted_at) + " reclaimed "
                  + d.reclaimed_mb + " MB in " + d.compact_seconds + " s."
                : "Not rewritten yet in this run.")
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing
        radius: Kirigami.Units.smallSpacing
        color: Kirigami.Theme.alternateBackgroundColor

        ColumnLayout {
            id: col
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.smallSpacing

            // ---- one line that answers "is it running, and is it keeping up"
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.largeSpacing

                Kirigami.Icon {
                    source: "server-database"
                    implicitWidth: Kirigami.Units.iconSizes.small
                    implicitHeight: Kirigami.Units.iconSizes.small
                }
                QQC2.Label {
                    text: card.state && card.state.owner
                          ? "This window owns the databases and serves them"
                          : "Following the agent" + (card.state && card.state.owner_pid
                                                     ? " (pid " + card.state.owner_pid + ")" : "")
                    font.bold: true
                }
                Chip {
                    label: (card.coll.sources || 0) + " sources"
                    tip: "Every entry point in the expertise directory. "
                         + (card.coll.workers || 0) + " are queried at once — they are "
                         + "external processes, so a cycle is the longest wait, not the sum."
                }
                Chip {
                    label: card.coll.last && card.coll.last.seconds !== undefined
                           ? "cycle " + card.coll.last.seconds + " s" : "cycle —"
                    tip: card.coll.last && card.coll.last.at
                         ? "The last collection took " + card.coll.last.seconds
                           + " s over " + card.coll.last.sources + " due sources, at "
                           + Fmt.maybeLocal(card.coll.last.at)
                         : "No collection has finished in this window yet."
                }
                Chip {
                    label: (card.coll.failing || 0) + " failing"
                    warn: (card.coll.failing || 0) > 0
                    tip: "Sources whose last run returned an error. They are marked "
                         + "on their own card below."
                }
                Chip {
                    label: (card.stream.per_minute || 0) + " events/min"
                    warn: (card.stream.per_minute || 0) === 0
                    tip: "Measured over the last five minutes. Zero means the "
                         + "stream has stopped — which looks exactly like a quiet "
                         + "machine unless it is stated."
                }
                Chip {
                    label: "backlog " + (card.stream.backlog !== undefined
                                         ? card.stream.backlog : "?")
                    warn: (card.stream.backlog || 0) > 20000
                    tip: "Raw lines that have arrived but are not normalized yet. "
                         + "A number that keeps growing is the difference between "
                         + "'quiet' and 'stuck'."
                }
                Item { Layout.fillWidth: true }
                QQC2.ToolButton {
                    icon.name: card.expanded ? "go-up" : "go-down"
                    text: card.expanded ? "Less" : "How it works"
                    display: QQC2.AbstractButton.TextBesideIcon
                    onClicked: card.expanded = !card.expanded
                }
            }

            // ---- the mechanisms, each with the number it is measured by
            ColumnLayout {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
                visible: card.expanded
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Separator { Layout.fillWidth: true }

                Fact {
                    title: "Who may read"
                    value: card.state && card.state.serving
                           ? "serving on " + card.state.socket : "not serving"
                    detail: "DuckDB locks a database file exclusively — while a "
                            + "writer holds it no other process can open it, not even "
                            + "read-only. So one process owns both databases and "
                            + "answers for them on a Unix socket (0600, reads only). "
                            + "A second window, a script or the test suite reads "
                            + "through it while collection carries on."
                }
                // TWO DATABASES BY DESIGN, so they are written out rather than
                // repeated: state is a snapshot rewritten every cycle, events are
                // a stream with retention, and the two behave differently enough
                // that the same words would not fit both anyway.
                // (A Repeater over an inline component produced no rows at all
                // here, silently — caught by reading the render back, not by a
                // warning.)
                Fact {
                    title: "State database"
                    value: card.dbLine("state")
                    detail: card.dbDetail("state")
                }
                Fact {
                    title: "Event database"
                    value: card.dbLine("events")
                    detail: card.dbDetail("events")
                }
                Fact {
                    title: "How far the history goes"
                    value: (card.stream.materialized || 0) + " events of at most "
                           + (card.stream.retention_rows || 0)
                           + ", raw staging " + (card.stream.staged_raw || 0)
                           + " of " + (card.stream.raw_window || 0)
                    detail: "The events table is the history the interface reads. The "
                            + "raw staging table is not history — a line lives there "
                            + "until it has been normalized, plus a window kept so that "
                            + "editing the rule can re-read recent lines. Keeping every "
                            + "raw line for the whole retention window stored each event "
                            + "twice."
                }
                Fact {
                    visible: card.stream.fold !== undefined
                    title: "Process ends"
                    value: card.stream.fold
                           ? (card.stream.fold.rows || 0) + " starts carry the end of their process"
                           : ""
                    detail: card.stream.fold
                            ? "Tetragon reports a start and an end as two events, and "
                              + "the ends were half of everything stored. They are not "
                              + "dropped — a process that lived 20 ms is exactly what "
                              + "you look for — the end is written ONTO the start: "
                              + card.stream.fold.when + " → " + card.stream.fold.onto
                              + ", matched by " + card.stream.fold.key + ". An end whose "
                              + "start is not in the table is kept as its own row."
                            : ""
                }
                Fact {
                    title: "The stream itself"
                    value: (card.state && card.state.tetragon
                            ? (card.state.tetragon.readable ? "reading " : "cannot read ")
                              + card.state.tetragon.log : "")
                           + (card.stream.last_event
                              ? ", last event " + Fmt.maybeLocal(card.stream.last_event) : "")
                    warn: !!(card.state && card.state.tetragon
                             && (!card.state.tetragon.readable
                                 || card.state.tetragon.cursor_error))
                    detail: "Tetragon runs as root and exports JSON; this is the only "
                            + "thing crossing that boundary, and it is read with a "
                            + "cursor so a restart neither repeats nor skips. "
                            + (card.state && card.state.tetragon && card.state.tetragon.cursor_error
                               ? card.state.tetragon.cursor_error : "")
                }
                Fact {
                    title: "How often a source runs"
                    value: (card.coll.cadences || []).join(" s · ") + " s"
                    detail: "Each rule declares its own interval: the process list does "
                            + "not need re-reading as rarely as the package inventory, "
                            + "and running everything on the shortest interval would keep "
                            + "the machine busy for nothing."
                }
            }
        }
    }

    // a small labelled value with the explanation one hover away
    component Chip: Rectangle {
        id: chip
        property string label: ""
        property string tip: ""
        property bool warn: false
        implicitWidth: chipText.implicitWidth + Kirigami.Units.largeSpacing
        implicitHeight: chipText.implicitHeight + Kirigami.Units.smallSpacing
        radius: height / 2
        color: warn ? Qt.rgba(Kirigami.Theme.negativeTextColor.r,
                              Kirigami.Theme.negativeTextColor.g,
                              Kirigami.Theme.negativeTextColor.b, 0.18)
                    : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                              Kirigami.Theme.textColor.b, 0.08)
        QQC2.Label {
            id: chipText
            anchors.centerIn: parent
            text: chip.label
            font.pointSize: Kirigami.Theme.smallFont.pointSize
        }
        HoverHandler { id: hh }
        QQC2.ToolTip.visible: hh.hovered && chip.tip !== ""
        QQC2.ToolTip.text: chip.tip
        QQC2.ToolTip.delay: 300
    }

    // `parent.parent` inside an inline component resolves to the layout, not to
    // the component — which reads as "undefined" being assigned to a string. The
    // component refers to ITSELF by id instead.
    component Fact: ColumnLayout {
        id: fact
        property string title: ""
        property string value: ""
        property string detail: ""
        property bool warn: false
        Layout.fillWidth: true
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            QQC2.Label {
                text: fact.title
                font.bold: true
                color: fact.warn ? Kirigami.Theme.negativeTextColor
                                 : Kirigami.Theme.textColor
                Layout.preferredWidth: Kirigami.Units.gridUnit * 11
            }
            QQC2.Label {
                text: fact.value
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
            }
        }
        QQC2.Label {
            text: fact.detail
            visible: text !== ""
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.gridUnit * 11
            wrapMode: Text.WordWrap
            opacity: 0.7
            font.pointSize: Kirigami.Theme.smallFont.pointSize
        }
    }
}

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import "../components"
import "../components/Fmt.js" as Fmt
import "../pages"
import "."

// Settings in the modern KDE FormCard style (Kirigami Addons).
FormCard.FormCardPage {
    id: page
    title: "Settings"

    property var settings: backend.getSettings()


    FormCard.FormHeader {
        title: "Resources"
    }
    FormCard.FormCard {
        id: resCard
        property var u: backend.resourceUsage()
        property var m: backend.systemMetrics()

        FormCard.FormTextDelegate {
            text: "System load average"
            description: resCard.m.load.length
                         ? "1 min: " + resCard.m.load[0] +
                           " · 5 min: " + resCard.m.load[1] +
                           " · 15 min: " + resCard.m.load[2]
                         : "—"
        }
        FormCard.FormDelegateSeparator {}

        // a CPU/RAM chart for the last 30 minutes (sampled every 10 seconds)
        FormCard.AbstractFormDelegate {
            background: null
            contentItem: ColumnLayout {
                spacing: Kirigami.Units.smallSpacing
                RowLayout {
                    QQC2.Label { text: "CPU"; color: "#2980b9"; font.bold: true }
                    QQC2.Label {
                        text: resCard.m.series.length
                              ? resCard.m.series[resCard.m.series.length-1].cpu + " %" : "—"
                        color: "#2980b9"
                    }
                    Item { width: Kirigami.Units.largeSpacing }
                    QQC2.Label { text: "Memory"; color: "#e67e22"; font.bold: true }
                    QQC2.Label {
                        text: resCard.m.series.length
                              ? resCard.m.series[resCard.m.series.length-1].mem + " %" : "—"
                        color: "#e67e22"
                    }
                    Item { Layout.fillWidth: true }
                    QQC2.Label { text: "last 30 min"; opacity: 0.5 }
                }
                Canvas {
                    id: chart
                    Layout.fillWidth: true
                    Layout.preferredHeight: Kirigami.Units.gridUnit * 6
                    property var series: resCard.m.series
                    onSeriesChanged: requestPaint()
                    onPaint: {
                        const ctx = getContext("2d")
                        ctx.clearRect(0, 0, width, height)
                        // the 0/50/100 % grid
                        ctx.strokeStyle = Qt.alpha(Kirigami.Theme.textColor, 0.15)
                        ctx.lineWidth = 1
                        for (const p of [0, 0.5, 1]) {
                            ctx.beginPath()
                            ctx.moveTo(0, height * p)
                            ctx.lineTo(width, height * p)
                            ctx.stroke()
                        }
                        const s = series
                        if (!s || s.length < 2) return
                        const n = 181   // a fixed 30 minute window
                        function drawLine(key, color) {
                            ctx.strokeStyle = color
                            ctx.lineWidth = 2
                            ctx.beginPath()
                            for (let i = 0; i < s.length; i++) {
                                const x = width * (n - s.length + i) / (n - 1)
                                const y = height * (1 - s[i][key] / 100)
                                i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y)
                            }
                            ctx.stroke()
                        }
                        drawLine("cpu", "#2980b9")
                        drawLine("mem", "#e67e22")
                    }
                }
            }
        }
        FormCard.FormDelegateSeparator {}

        FormCard.FormTextDelegate {
            text: "Memory usage"
            description: "LiSin: " + resCard.u.app_mb + " MB"
        }
        FormCard.FormDelegateSeparator {}
        FormCard.FormTextDelegate {
            text: "Disk usage"
            description: "App: " + resCard.m.disk.app_mb + " MB · State DB: " +
                         resCard.m.disk.db_mb + " MB"
        }
        FormCard.FormDelegateSeparator {}
        FormCard.FormButtonDelegate {
            text: "Refresh"
            icon.name: "view-refresh"
            onClicked: {
                resCard.u = backend.resourceUsage()
                resCard.m = backend.systemMetrics()
            }
        }
    }

    FormCard.FormHeader {
        title: "Storage"
    }
    FormCard.FormCard {
        id: storeCard
        property var db: backend.dbSizes()

        // RETENTION: two limits, whichever bites first (row ceiling AND size cap)
        FormCard.AbstractFormDelegate {
            background: null
            contentItem: RowLayout {
                spacing: Kirigami.Units.smallSpacing
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    QQC2.Label { text: "Events kept (row ceiling)" }
                    QQC2.Label {
                        text: "The newest N events are kept; older ones are pruned. " +
                              "At about 1.2 KB per event, 1 GB holds roughly 1 million."
                        opacity: 0.6
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                    }
                }
                QQC2.SpinBox {
                    from: 1000
                    to: 20000000
                    stepSize: 100000
                    editable: true
                    value: storeCard.db.retention || 2000000
                    onValueModified: backend.setSetting("events_retention", String(value))
                }
            }
        }
        FormCard.FormDelegateSeparator {}
        FormCard.AbstractFormDelegate {
            background: null
            contentItem: RowLayout {
                spacing: Kirigami.Units.smallSpacing
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    QQC2.Label { text: "Size cap (MB)" }
                    QQC2.Label {
                        text: "The events data never grows past this. Whichever limit " +
                              "is reached first — rows or size — trims the oldest events."
                        opacity: 0.6
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                    }
                }
                QQC2.SpinBox {
                    from: 16
                    to: 20480
                    stepSize: 256
                    editable: true
                    value: storeCard.db.max_mb || 1024
                    onValueModified: backend.setSetting("events_max_mb", String(value))
                }
            }
        }
        FormCard.FormDelegateSeparator {}

        // normalization coverage + arrival rate
        FormCard.FormTextDelegate {
            text: "Events feed"
            description: (storeCard.db.events || 0) + " stored · "
                         + (storeCard.db.normalized_pct || 0) + "% fully normalized · "
                         + (storeCard.db.unmapped || 0) + " with unmapped fields · ~"
                         + (storeCard.db.per_hour || 0) + " events per hour"
        }
        FormCard.FormDelegateSeparator {}

        // the database files
        Repeater {
            model: storeCard.db.databases || []
            FormCard.FormTextDelegate {
                text: modelData.name + " database"
                description: Fmt.bytes(modelData.bytes)
            }
        }
        FormCard.FormDelegateSeparator {}

        // what our tables weigh (largest first)
        Repeater {
            model: storeCard.db.tables || []
            FormCard.FormTextDelegate {
                text: modelData.name
                description: Fmt.bytes(modelData.bytes)
                             + " · " + modelData.rows + " rows · " + modelData.db
            }
        }
        FormCard.FormButtonDelegate {
            text: "Refresh"
            icon.name: "view-refresh"
            onClicked: storeCard.db = backend.dbSizes()
        }
    }

    FormCard.FormHeader {
        title: "About"
    }
    FormCard.FormCard {
        FormCard.FormTextDelegate {
            text: "LiSin"
            description: "Lightweight local EDR for Fedora — state tables, YAML+Python expertise, data-flow pipelines, local AI."
        }
    }
}

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard

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

        // график CPU/RAM за последние 30 минут (сэмпл каждые 10 с)
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
                        // сетка 0/50/100 %
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
                        const n = 181   // фикс. окно 30 мин
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
        title: "About"
    }
    FormCard.FormCard {
        FormCard.FormTextDelegate {
            text: "LiSin"
            description: "Lightweight local EDR for Fedora — state tables, YAML+Python expertise, data-flow pipelines, local AI."
        }
    }
}

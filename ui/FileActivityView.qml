import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "Fmt.js" as Fmt

// Файловая активность: что создавали, меняли, удаляли. Слева — срезы
// (действие, каталог, пакет), справа — сами события. Клик по срезу
// фильтрует список: это и есть интерактивность, ради которой панель нужна.
Item {
    id: view
    property var d: ({ events: [], by_action: [], by_dir: [], by_package: [], total: 0 })
    property string fAction: ""
    property string fDir: ""
    function refresh() { view.d = backend.fileActivity() }
    Component.onCompleted: refresh()
    Connections { target: backend; function onStateReady(s) { view.refresh() } }

    function sevColor(v) {
        var n = parseInt(v) || 0
        return n >= 70 ? "#e74c3c" : n >= 45 ? "#e67e22" : n >= 25 ? "#f1c40f"
                                                                   : Kirigami.Theme.disabledTextColor
    }
    property var shown: {
        var r = d.events || [], o = []
        for (var i = 0; i < r.length; i++) {
            if (fAction !== "" && r[i].event_action !== fAction) continue
            if (fDir !== "" && r[i].file_directory !== fDir) continue
            o.push(r[i])
        }
        return o
    }
    component Facet: ColumnLayout {
        property string heading
        property var items: []
        property string current: ""
        signal picked(string v)
        Layout.fillWidth: true
        spacing: 1
        QQC2.Label { text: heading; font.bold: true
                     font.pointSize: Kirigami.Theme.smallFont.pointSize; opacity: 0.8 }
        Repeater {
            model: items
            QQC2.ItemDelegate {
                Layout.fillWidth: true
                highlighted: current === String(modelData.value)
                onClicked: picked(String(modelData.value))
                contentItem: RowLayout {
                    QQC2.Label {
                        Layout.fillWidth: true
                        text: String(modelData.value) || "(empty)"
                        elide: Text.ElideMiddle
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                    QQC2.Label { text: modelData.n; opacity: 0.6
                                 font.pointSize: Kirigami.Theme.smallFont.pointSize }
                }
            }
        }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0
        // ---- срезы ----
        QQC2.ScrollView {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 18
            Layout.fillHeight: true
            clip: true
            ColumnLayout {
                width: Kirigami.Units.gridUnit * 17
                spacing: Kirigami.Units.smallSpacing
                RowLayout {
                    Layout.fillWidth: true
                    Kirigami.Heading { level: 4; text: "Files: " + view.d.total }
                    Item { Layout.fillWidth: true }
                    QQC2.ToolButton {
                        icon.name: "edit-clear"
                        visible: view.fAction !== "" || view.fDir !== ""
                        onClicked: { view.fAction = ""; view.fDir = "" }
                    }
                }
                Facet { heading: "Action"; items: view.d.by_action; current: view.fAction
                        onPicked: v => view.fAction = (view.fAction === v ? "" : v) }
                Facet { heading: "Folder"; items: view.d.by_dir; current: view.fDir
                        onPicked: v => view.fDir = (view.fDir === v ? "" : v) }
                Facet { heading: "Package"; items: view.d.by_package }
            }
        }
        Kirigami.Separator { Layout.fillHeight: true }
        // ---- события ----
        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: view.shown
            QQC2.ScrollBar.vertical: QQC2.ScrollBar {}
            Kirigami.PlaceholderMessage {
                anchors.centerIn: parent
                visible: parent.count === 0
                text: "No file events"
                explanation: "Integrity is checked with rpm -Va against packaged configs every 15 minutes."
            }
            delegate: QQC2.ItemDelegate {
                width: ListView.view.width
                height: Kirigami.Units.gridUnit * 2.6
                contentItem: RowLayout {
                    spacing: Kirigami.Units.smallSpacing
                    Rectangle {
                        Layout.preferredWidth: 4; Layout.fillHeight: true
                        color: view.sevColor(modelData.event_severity)
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        QQC2.Label {
                            Layout.fillWidth: true
                            text: modelData.file_path
                            elide: Text.ElideMiddle
                            font.family: "monospace"
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                        QQC2.Label {
                            Layout.fillWidth: true
                            opacity: 0.65
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            text: modelData.event_action +
                                  (modelData.package_name ? "  ·  package " + modelData.package_name
                                                          : "  ·  unpackaged") +
                                  (modelData.file_mode ? "  ·  mode " + modelData.file_mode : "") +
                                  (modelData.file_owner ? "  ·  " + modelData.file_owner : "")
                        }
                    }
                    QQC2.Label {
                        // КТО и ОТКУДА ЭТО ИЗВЕСТНО. rpm -Va фиксирует расхождение,
                        // но не автора правки — тогда так и пишем, а не гадаем.
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        opacity: 0.6
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        text: modelData.changed_by
                              ? ("changed by: " + modelData.changed_by
                                 + (modelData.changed_by_user ? " (" + modelData.changed_by_user + ")" : "")
                                 + "  · " + (modelData.changed_at || "").replace("T", " ").substring(0, 16))
                              : (modelData.who_source || "")
                    }

                    QQC2.Label {
                        text: Fmt.local(modelData.ts)
                        opacity: 0.5
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                }
            }
        }
    }
}

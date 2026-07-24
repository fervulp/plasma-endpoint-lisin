import QtQuick
import org.kde.kirigami as Kirigami

// A FLOATING PANEL: a rounded card in the View colour with a soft drop shadow,
// so it reads as floating above the greyer page canvas. Theme-aware (light and
// dark, through the colour roles). Default children are placed inside — give
// them anchors or a Layout.
Kirigami.ShadowedRectangle {
    Kirigami.Theme.colorSet: Kirigami.Theme.View
    Kirigami.Theme.inherit: false
    color: Kirigami.Theme.backgroundColor
    radius: Kirigami.Units.smallSpacing * 1.5
    border.width: 1
    border.color: Qt.alpha(Kirigami.Theme.textColor, 0.08)
    shadow.size: Kirigami.Units.gridUnit
    shadow.xOffset: 0
    shadow.yOffset: 2
    shadow.color: Qt.rgba(0, 0, 0, 0.18)
}

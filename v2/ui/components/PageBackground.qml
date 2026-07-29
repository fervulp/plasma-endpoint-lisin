import QtQuick
import org.kde.kirigami as Kirigami

// The grey "canvas" behind the floating cards — identical on every top-level
// page (Data, Dashboards, Expertise). Was copied inline into each; one component
// now, used as `background: PageBackground {}`.
Rectangle {
    Kirigami.Theme.colorSet: Kirigami.Theme.Window
    Kirigami.Theme.inherit: false
    color: Kirigami.Theme.backgroundColor
}

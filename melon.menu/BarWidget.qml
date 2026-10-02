import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "melon.menu"

  // Draw the "M in a rounded square" with native QML shapes, matching the
  // melon.eye medallion footprint (Style.bar.iconCanvas slot) so the box is
  // exactly the same size as the eye icon and the other icon widgets.
  readonly property int slotSize: (Style.bar.iconCanvas > 0 ? Style.bar.iconCanvas : 16) + Style.space(1)
  readonly property color fg: root.bar ? root.bar.barForeground : Color.foreground
  readonly property color contrast: root.bar ? root.bar.background : Color.background
  readonly property bool vertical: root.bar ? root.bar.vertical : false

  implicitWidth: vertical ? root.bar.barSize : slotSize + Style.space(5)
  implicitHeight: vertical ? slotSize + Style.space(5) : root.bar.barSize

  function triggerPress(button) {
    if (!root.bar) return
    if (button === Qt.RightButton) root.bar.run("xdg-terminal-exec")
    else root.bar.run("omarchy-shell shell toggle melon.menu '{\"menu\":\"root\"}'")
  }

  // ---- "M" box ----
  Rectangle {
    id: box
    anchors.centerIn: parent
    width: root.slotSize
    height: root.slotSize
    radius: Math.max(3, root.slotSize * 0.24)
    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.92)
    border.width: 0
  }

  Text {
    id: letter
    anchors.centerIn: box
    text: "M"
    color: root.contrast
    font.family: root.bar ? root.bar.fontFamily : "monospace"
    font.pixelSize: Math.round(root.slotSize * 0.62)
    font.bold: true
    renderType: Text.NativeRendering
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: function(mouse) { root.triggerPress(mouse.button) }
  }
}

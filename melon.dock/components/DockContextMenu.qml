import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Right-click menu for a dock tile. Rendered in a full-screen transparent
// window with the menu card anchored above the dock (robust, OSD-style).
// Clicking outside dismisses.
Item {
  id: root

  required property Item anchorItem
  required property string position
  required property bool canClose
  required property bool autoHide

  property bool opened: false

  signal openNewWindow()
  signal closeWindow()
  signal addApplication()
  signal removeFromDock()
  signal toggleAutoHide()

  function open() {
    menuWindow.visible = true
    root.opened = true
  }

  function close() {
    menuWindow.visible = false
    root.opened = false
  }

  PanelWindow {
    id: menuWindow

    visible: false
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "melon-dock-menu"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Transparent dismiss layer: any click outside the card closes the menu.
    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card

      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(72)
      implicitWidth: menuColumn.implicitWidth + Style.spacing.sm * 2
        + Border.left(borderSpec) + Border.right(borderSpec)
      implicitHeight: menuColumn.implicitHeight + Style.spacing.sm * 2
        + Border.top(borderSpec) + Border.bottom(borderSpec)
      radius: Style.cornerRadius
      color: Color.popups.background
      borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Math.max(1, Style.spaceReal(2)))
      padding: Style.spacing.sm

      ColumnLayout {
        id: menuColumn

        anchors.fill: parent
        spacing: Style.spacing.xs

        Button {
          text: "Add Application"
          leftAlign: true
          Layout.fillWidth: true
          onClicked: { root.close(); root.addApplication() }
        }

        Button {
          text: "Remove from Dock"
          leftAlign: true
          Layout.fillWidth: true
          onClicked: { root.close(); root.removeFromDock() }
        }

        Button {
          text: root.autoHide ? "Disable Auto-Hide" : "Enable Auto-Hide"
          leftAlign: true
          Layout.fillWidth: true
          onClicked: { root.close(); root.toggleAutoHide() }
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.topMargin: Style.spacing.xs
          Layout.bottomMargin: Style.spacing.xs
          height: 1
          color: Util.alpha(Color.muted, 0.35)
        }

        Button {
          text: "Open New Window"
          leftAlign: true
          Layout.fillWidth: true
          onClicked: { root.close(); root.openNewWindow() }
        }

        Button {
          text: "Close"
          leftAlign: true
          Layout.fillWidth: true
          enabled: root.canClose
          onClicked: { root.close(); root.closeWindow() }
        }
      }
    }
  }
}

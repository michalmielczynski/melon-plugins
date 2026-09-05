pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// A single application slot in the dock, styled like the Omarchy system-monitor
// panels: a bordered micro-container with the full monospace application name
// and a thin jade underline when the app is running. Text-only, no icons, no
// tooltip (the name is always visible).
BorderSurface {
  id: root

  required property string desktopId
  required property int itemIndex
  required property var shell
  required property bool autoHide
  required property string position
  required property bool vertical
  required property string clickAction
  required property var labelMap
  required property int slotMinWidth
  required property int slotHeight
  property real reorderOffset: 0

  signal dragStarted(int itemIndex)
  signal dragMoved(real mainPosition)
  signal dragFinished()
  signal addApplicationRequested()
  signal removeRequested(string desktopId)
  signal autoHideToggled(bool enabled)
  signal contextMenuVisibilityChanged(bool visible)

  readonly property var applications: DesktopEntries.applications.values || []
  readonly property var entry: { var rev = applications.length; return DesktopEntries.byId(desktopId) }
  readonly property var toplevels: ToplevelManager.toplevels.values || []
  readonly property var runningToplevel: { var rev = toplevels.length; return findRunningToplevel() }
  readonly property bool isFocused: runningToplevel !== null && ToplevelManager.activeToplevel === runningToplevel
  readonly property string displayName: entry ? (entry.name || desktopId) : desktopId
  readonly property string label: {
    var map = labelMap || {}
    var v = map[desktopId]
    if (v) return String(v)
    return entry ? (entry.name || desktopId) : desktopId
  }

  // ---- app matching / launch (adapted for Omarchy) ----
  function normalizedId(value) {
    return String(value || "").toLowerCase().replace(/\.desktop$/, "")
  }

  function webAppId() {
    if (!entry || !entry.command) return ""
    for (var i = 0; i < entry.command.length; ++i) {
      var match = String(entry.command[i]).match(/https?:\/\/[^?#\s]+/i)
      if (!match) continue
      var url = match[0].replace(/^https?:\/\//i, "").replace(/\/$/, "")
      try { url = decodeURIComponent(url) } catch (error) {}
      return url.toLowerCase().replace(/[^a-z0-9]/g, "")
    }
    return ""
  }

  function matchesEntry(toplevel) {
    if (!toplevel) return false
    var appId = normalizedId(toplevel.appId)
    if (!appId) return false
    var ids = [desktopId]
    if (entry) ids.push(entry.id, entry.startupClass)
    for (var i = 0; i < ids.length; ++i) {
      var id = normalizedId(ids[i])
      if (id && appId === id) return true
    }
    var generatedWebAppId = webAppId()
    return generatedWebAppId.length >= 6
      && appId.replace(/[^a-z0-9]/g, "").indexOf(generatedWebAppId) >= 0
  }

  function findRunningToplevel() {
    for (var i = 0; i < toplevels.length; ++i)
      if (matchesEntry(toplevels[i])) return toplevels[i]
    return null
  }

  function launch() {
    if (shell && shell.appLibrary && typeof shell.appLibrary.launch === "function")
      shell.appLibrary.launch(desktopId, displayName)
    else
      Quickshell.execDetached(["gtk-launch", desktopId + ".desktop"])
  }

  function activateOrLaunch() {
    if (clickAction === "focus-or-launch" && runningToplevel) {
      runningToplevel.activate()
      return
    }
    launch()
  }

  function closeRunning() {
    if (runningToplevel) runningToplevel.close()
  }

  // ---- state-driven visual ----
  width: Math.max(slotMinWidth, labelText.implicitWidth + 24)
  height: slotHeight
  radius: Style.cornerRadius
  color: mouse.pressed
    ? Style.pressedFillFor(Color.foreground, Color.accent)
    : (mouse.hovered || isFocused)
      ? (isFocused ? Style.selectedFillFor(Color.foreground, Color.accent)
                   : Style.hoverFillFor(Color.foreground, Color.accent))
      : (runningToplevel ? Style.selectedFillFor(Color.foreground, Color.accent) : "transparent")
  borderSpec: (mouse.hovered || isFocused)
    ? Border.controlSpec("hover-cursor", Color.foreground, Color.accent)
    : Border.none()

  Behavior on color { ColorAnimation { duration: 100 } }

  Text {
    id: labelText

    textFormat: Text.PlainText
    anchors.centerIn: parent
    text: root.label
    color: root.runningToplevel ? Color.foreground : Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    font.bold: root.isFocused
    font.letterSpacing: 0.6

    Behavior on color { ColorAnimation { duration: 100 } }
  }

  // Running indicator: thin jade underline (system-monitor style).
  Rectangle {
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: 4
    width: root.isFocused ? 22 : (root.runningToplevel ? 14 : 0)
    height: 3
    radius: 1.5
    color: Color.accent
    opacity: root.runningToplevel ? 1.0 : 0

    Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    Behavior on opacity { NumberAnimation { duration: 120 } }
  }

  // ---- interactions ----
  HoverHandler { id: mouse; cursorShape: Qt.PointingHandCursor }

  TapHandler {
    acceptedButtons: Qt.LeftButton
    onTapped: root.activateOrLaunch()
  }

  TapHandler {
    acceptedButtons: Qt.RightButton
    onTapped: contextMenu.open()
  }

  DragHandler {
    id: dragHandler

    target: null
    acceptedButtons: Qt.LeftButton
    xAxis.enabled: !root.vertical
    yAxis.enabled: root.vertical
    onActiveChanged: {
      if (active) root.dragStarted(root.itemIndex)
      else root.dragFinished()
    }
    onActiveTranslationChanged: {
      if (active)
        root.dragMoved((root.vertical ? root.y + root.height / 2 : root.x + root.width / 2)
          + (root.vertical ? activeTranslation.y : activeTranslation.x))
    }
  }

  DockContextMenu {
    id: contextMenu

    anchorItem: root
    position: root.position
    canClose: root.runningToplevel !== null
    autoHide: root.autoHide
    onOpenedChanged: root.contextMenuVisibilityChanged(opened)
    onOpenNewWindow: root.launch()
    onCloseWindow: root.closeRunning()
    onAddApplication: root.addApplicationRequested()
    onRemoveFromDock: root.removeRequested(root.desktopId)
    onToggleAutoHide: root.autoHideToggled(!root.autoHide)
  }
}

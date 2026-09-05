pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The dock window: a themed rounded card of application tiles at the chosen
// screen edge, with an auto-hide screen-edge reveal. One instance per screen.
PanelWindow {
  id: root

  required property var settings
  required property var shell

  signal reorderRequested(int from, int to)
  signal pinRequested(string desktopId)
  signal unpinRequested(string desktopId)
  signal autoHideRequested(bool enabled)

  // ---- config-derived ----
  readonly property int iconSize: settings.iconSize || 40
  // Optional override for the dock surface alpha. When unset (NaN) the dock
  // uses the theme's own popups.background color/alpha, so it follows the theme.
  readonly property real backgroundOpacity: {
    var v = Number(settings.backgroundOpacity)
    return settings.backgroundOpacity === undefined || isNaN(v) ? NaN : Math.max(0, Math.min(1, v))
  }
  readonly property bool reserveSpace: settings.reserveSpace === undefined ? false : settings.reserveSpace
  readonly property bool autoHide: settings.autoHide === undefined ? false : settings.autoHide
  readonly property string clickAction: settings.clickAction || "focus-or-launch"
  readonly property string requestedPosition: settings.position || "bottom"
  readonly property string position: ["top", "bottom", "left", "right"].indexOf(requestedPosition) >= 0
    ? requestedPosition
    : "bottom"
  readonly property bool vertical: position === "left" || position === "right"
  readonly property bool fullLength: settings.fullLength === undefined ? false : settings.fullLength
  readonly property bool showLauncher: settings.showLauncher === undefined ? true : settings.showLauncher
  readonly property var pinned: settings.pinned || []
  readonly property int edgeMargin: settings.margin === undefined ? 8 : settings.margin
  readonly property int revealThickness: {
    var v = Number(settings.revealThickness)
    return settings.revealThickness === undefined || isNaN(v) ? 12 : Math.max(1, Math.min(80, Math.round(v)))
  }
  readonly property int slotHeight: Math.max(36, Math.min(52, iconSize))
  readonly property int slotMinWidth: slotHeight
  readonly property int launcherWidth: Math.max(44, slotHeight)
  readonly property int gap: Style.spacing.sm
  readonly property int cardPad: 8
  readonly property int cardHeight: slotHeight + cardPad * 2

  // ---- auto-hide state ----
  property bool autoHideRevealed: false
  readonly property bool keepAutoHideOpen: windowPointer.hovered
    || appPicker.opened || openMenuCount > 0 || dragSource >= 0
  readonly property bool dockShown: !autoHide || autoHideRevealed

  property int dragSource: -1
  property int dragTarget: -1
  property int openMenuCount: 0

  function itemWidth(index) {
    var it = pinnedRepeater.itemAt(index)
    return it ? it.width : root.slotMinWidth
  }

  function reorderOffset(index) {
    if (dragSource < 0 || dragTarget < 0) return 0
    var w = itemWidth(dragSource)
    if (dragSource < dragTarget && index > dragSource && index <= dragTarget) return -w
    if (dragSource > dragTarget && index >= dragTarget && index < dragSource) return w
    return 0
  }

  function updateDragTarget(position) {
    if (pinnedRepeater.count === 0) { dragTarget = 0; return }
    var best = 0
    var bestDist = Infinity
    for (var i = 0; i < pinnedRepeater.count; ++i) {
      var it = pinnedRepeater.itemAt(i)
      if (!it) continue
      var center = it.x + it.width / 2
      var d = Math.abs(position - center)
      if (d < bestDist) { bestDist = d; best = i }
    }
    dragTarget = best
  }

  function finishDrag() {
    var from = dragSource
    var to = dragTarget
    dragSource = -1
    dragTarget = -1
    if (from >= 0 && to >= 0 && from !== to) reorderRequested(from, to)
  }

  // --- Screen-edge frame geometry (mirrors the omarchy top bar) -----------
  // SVG path for the card outline: fills to the screen edge and rounds only the
  // interior-facing corners (top for a bottom dock, bottom for a top dock, right
  // for a left dock, left for a right dock). This makes the dock read as part of
  // the screen edge rather than a floating pill.
  function framePath(w, h) {
    if (w <= 0 || h <= 0) return ""
    var r = Math.max(0, Math.min(Style.cornerRadius, Math.min(w, h) / 2))
    if (r <= 0) return "M 0 0 H " + w + " V " + h + " H 0 Z"
    if (root.position === "bottom") {
      return "M 0 " + h + " H " + w + " V " + r
        + " Q " + w + " 0 " + (w - r) + " 0 H " + r + " Q 0 0 0 " + r + " Z"
    } else if (root.position === "left") {
      return "M 0 0 H " + (w - r) + " Q " + w + " 0 " + w + " " + r
        + " V " + (h - r) + " Q " + w + " " + h + " " + (w - r) + " " + h + " H 0 Z"
    } else if (root.position === "right") {
      return "M " + w + " 0 V " + h + " H " + r
        + " Q 0 " + h + " 0 " + (h - r) + " V " + r + " Q 0 0 " + r + " 0 H " + w + " Z"
    }
    // top: round only the bottom corners
    return "M 0 0 H " + w + " V " + (h - r)
      + " Q " + w + " " + h + " " + (w - r) + " " + h + " H " + r + " Q 0 " + h + " 0 " + (h - r) + " Z"
  }

  // OPEN SVG path for the card border, omitting the screen-edge segment (top
  // for a top dock, bottom for a bottom dock, etc.) so the dock merges into the
  // screen edge instead of showing a border line on it.
  function frameBorderPath(w, h) {
    if (w <= 0 || h <= 0) return ""
    var r = Math.max(0, Math.min(Style.cornerRadius, Math.min(w, h) / 2))
    if (r <= 0) {
      if (root.position === "bottom") return "M 0 " + h + " V 0 H " + w + " V " + h
      if (root.position === "left") return "M 0 0 H " + w + " V " + h + " H 0"
      if (root.position === "right") return "M " + w + " 0 H 0 V " + h + " H " + w
      return "M 0 0 V " + h + " H " + w + " V 0"
    }
    if (root.position === "bottom") {
      return "M 0 " + h + " V " + r + " Q 0 0 " + r + " 0 H " + (w - r)
        + " Q " + w + " 0 " + w + " " + r + " V " + h
    } else if (root.position === "left") {
      return "M 0 0 H " + (w - r) + " Q " + w + " 0 " + w + " " + r
        + " V " + (h - r) + " Q " + w + " " + h + " " + (w - r) + " " + h + " H 0"
    } else if (root.position === "right") {
      return "M " + w + " 0 H " + r + " Q 0 0 0 " + r
        + " V " + (h - r) + " Q 0 " + h + " " + r + " " + h + " H " + w
    }
    // top: omit the top border, trace left, bottom, right
    return "M 0 0 V " + (h - r) + " Q 0 " + h + " " + r + " " + h
      + " H " + (w - r) + " Q " + w + " " + h + " " + w + " " + (h - r) + " V 0"
  }

  function updateAutoHideState() {
    if (!autoHide) {
      hideTimer.stop()
      autoHideRevealed = false
    } else if (keepAutoHideOpen) {
      hideTimer.stop()
      autoHideRevealed = true
    } else if (autoHideRevealed) {
      hideTimer.restart()
    }
  }

  onAutoHideChanged: updateAutoHideState()
  onKeepAutoHideOpenChanged: updateAutoHideState()

  anchors {
    top: position === "top" || (vertical && fullLength)
    bottom: position === "bottom" || (vertical && fullLength)
    left: position === "left" || (!vertical && fullLength)
    right: position === "right" || (!vertical && fullLength)
  }
  implicitWidth: vertical ? cardHeight : (fullLength ? 0 : cardRow.implicitWidth + cardPad * 2)
  implicitHeight: vertical ? (fullLength ? 0 : cardRow.implicitHeight + cardPad * 2) : cardHeight
  color: "transparent"
  exclusionMode: reserveSpace && !autoHide ? ExclusionMode.Normal : ExclusionMode.Ignore
  WlrLayershell.exclusiveZone: reserveSpace && !autoHide ? cardHeight + edgeMargin : 0
  WlrLayershell.namespace: "melon-dock"
  WlrLayershell.layer: WlrLayer.Top
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  mask: Region {
    item: root.dockShown ? interactionArea : revealStrip
  }

  Timer {
    id: hideTimer
    interval: 800
    onTriggered: if (root.autoHide && !root.keepAutoHideOpen) root.autoHideRevealed = false
  }

  Item {
    id: interactionArea
    anchors.fill: parent
  }

  Item {
    id: revealStrip

    x: root.position === "right" ? parent.width - width : 0
    y: root.position === "bottom" ? parent.height - height : 0
    width: root.vertical ? root.revealThickness : parent.width
    height: root.vertical ? parent.height : root.revealThickness
  }

  Item {
    id: card

    anchors.fill: parent
    transform: Translate {
      x: !root.dockShown && root.vertical
        ? (root.position === "left" ? -(root.cardHeight + root.edgeMargin) : root.cardHeight + root.edgeMargin)
        : 0
      y: !root.dockShown && !root.vertical
        ? (root.position === "top" ? -(root.cardHeight + root.edgeMargin) : root.cardHeight + root.edgeMargin)
        : 0
      Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
      Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    }

    // Screen-edge frame: the fill reaches the screen edge and the border is
    // omitted on that edge, so the dock merges into the screen edge (like the
    // top bar, but inverted). For a bottom dock the bottom border is dropped
    // and only the TOP corners are rounded.
    Shape {
      id: dockFrame

      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer
      z: 0

      ShapePath {
        fillColor: isNaN(root.backgroundOpacity)
          ? Color.popups.background
          : Util.alpha(Color.popups.background, root.backgroundOpacity)
        strokeColor: "transparent"
        strokeWidth: 0
        fillRule: ShapePath.WindingFill

        PathSvg { path: root.framePath(dockFrame.width, dockFrame.height) }
      }

      // Border as an OPEN path that drops the screen-edge segment. Thickness and
      // alpha are matched to the omarchy top bar frame (2px, subtle) so the dock
      // reads as the same surface family instead of a bold outline.
      ShapePath {
        fillColor: "transparent"
        strokeColor: Util.alpha(Color.popups.border, 0.28)
        strokeWidth: 2
        fillRule: ShapePath.WindingFill

        PathSvg { path: root.frameBorderPath(dockFrame.width, dockFrame.height) }
      }
    }

    Row {
      id: cardRow

      anchors.centerIn: parent
      z: 1
      spacing: root.gap

      Repeater {
        id: pinnedRepeater
        model: root.pinned

        delegate: DockItem {
          required property string modelData
          required property int index

          desktopId: modelData
          itemIndex: index
          shell: root.shell
          autoHide: root.autoHide
          position: root.position
          vertical: root.vertical
          clickAction: root.clickAction
          slotMinWidth: root.slotMinWidth
          slotHeight: root.slotHeight
          labelMap: root.settings && root.settings.labels ? root.settings.labels : ({})
          reorderOffset: root.reorderOffset(index)

          onDragStarted: itemIndex => { root.dragSource = itemIndex; root.dragTarget = itemIndex }
          onDragMoved: mainPosition => root.updateDragTarget(mainPosition)
          onDragFinished: root.finishDrag()
          onAddApplicationRequested: appPicker.open()
          onRemoveRequested: desktopId => root.unpinRequested(desktopId)
          onAutoHideToggled: enabled => root.autoHideRequested(enabled)
          onContextMenuVisibilityChanged: visible => {
            root.openMenuCount = Math.max(0, root.openMenuCount + (visible ? 1 : -1))
          }
        }
      }

      // Launcher tile: opens the "add application" picker.
      BorderSurface {
        id: launcherTile

        visible: root.showLauncher
        width: root.launcherWidth
        height: root.slotHeight
        radius: Style.cornerRadius
        color: launcherMouse.pressed
          ? Style.pressedFillFor(Color.foreground, Color.accent)
          : launcherMouse.hovered
            ? Style.hoverFillFor(Color.foreground, Color.accent)
            : "transparent"
        borderSpec: launcherMouse.hovered
          ? Border.controlSpec("hover-cursor", Color.foreground, Color.accent)
          : Border.none()

        Behavior on color { ColorAnimation { duration: 100 } }

        Text {
          anchors.centerIn: parent
          text: "+"
          color: launcherMouse.hovered ? Color.foreground : Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.heading
          font.bold: true
        }

        HoverHandler {
          id: launcherMouse
          cursorShape: Qt.PointingHandCursor
        }

        TapHandler {
          acceptedButtons: Qt.LeftButton
          onTapped: appPicker.open()
        }
      }
    }
  }

  DockAppPicker {
    id: appPicker

    anchorItem: launcherTile
    position: root.position
    pinned: root.pinned
    onApplicationSelected: desktopId => root.pinRequested(desktopId)
  }

  HoverHandler {
    id: windowPointer
  }
}

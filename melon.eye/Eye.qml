pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Minimalist eye for the bar, in the Omarchy theme style:
// - the pupil follows the mouse cursor (eye-helper.py polls Hyprland IPC),
// - a ring blooms in a theme colour on mouse clicks (left/right/middle),
// - clicking the eye toggles tracking on/off.

Item {
  id: root

  property var bar: null
  property var shell: null

  property bool tracking: false

  property real pupilX: 0
  property real pupilY: 0
  property color flashColor: Color.accent

  readonly property color fg: root.bar ? root.bar.barForeground : Color.foreground
  readonly property int slotSize: (Style.bar.iconSlot > 0) ? Style.bar.iconSlot : 26
  readonly property real pupilTravel: slotSize * 0.20
  readonly property string helperPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/melon.eye/eye-helper.py"

  implicitWidth: slotSize
  implicitHeight: slotSize

  // ---- helper: cursor position + mouse clicks via stdout lines ----
  Process {
    id: helper
    command: ["python3", root.helperPath]
    running: root.tracking
    stdout: SplitParser { splitMarker: "\n" }
  }
  Connections {
    target: helper.stdout
    function onRead(line) { root.onHelperLine(String(line).trim()) }
  }

  function onHelperLine(line) {
    if (line.charAt(0) === "P") {
      var parts = line.split(" ")
      if (parts.length === 3) {
        var px = Number(parts[1])
        var py = Number(parts[2])
        if (isFinite(px) && isFinite(py)) {
          var gp = mapToGlobal(slotSize / 2, slotSize / 2)
          var dx = px - gp.x
          var dy = py - gp.y
          var a = Math.atan2(dy, dx)
          pupilX = Math.cos(a) * pupilTravel
          pupilY = Math.sin(a) * pupilTravel
        }
      }
    } else if (line === "L") {
      flash(Color.accent)
    } else if (line === "R") {
      flash(Color.urgent)
    } else if (line === "M") {
      flash(root.fg)
    }
  }

  function flash(color) {
    flashColor = color
    flashAnim.restart()
  }

  // ---- visuals ----
  Rectangle {
    id: sclera
    anchors.centerIn: parent
    width: root.slotSize - Style.space(2)
    height: root.slotSize - Style.space(2)
    radius: width / 2
    color: "transparent"
    border.width: Math.max(1, Style.spaceReal(1))
    border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, root.tracking ? 0.55 : 0.25)
  }

  Rectangle {
    id: pupil
    width: root.slotSize * 0.30
    height: root.slotSize * 0.30
    radius: width / 2
    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, root.tracking ? 0.95 : 0.35)
    x: root.slotSize / 2 - width / 2 + root.pupilX
    y: root.slotSize / 2 - height / 2 + root.pupilY

    Behavior on x { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
    Behavior on y { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
  }

  Rectangle {
    id: flashRing
    anchors.centerIn: parent
    width: root.slotSize
    height: root.slotSize
    radius: width / 2
    color: "transparent"
    border.width: Math.max(1.5, Style.spaceReal(1))
    border.color: root.flashColor
    opacity: 0
    scale: 0.55
    transformOrigin: Item.Center
  }

  SequentialAnimation {
    id: flashAnim
    PropertyAction { target: flashRing; property: "scale"; value: 0.55 }
    PropertyAction { target: flashRing; property: "opacity"; value: 0.9 }
    ParallelAnimation {
      NumberAnimation { target: flashRing; property: "scale"; to: 1.7; duration: 520; easing.type: Easing.OutCubic }
      NumberAnimation { target: flashRing; property: "opacity"; to: 0; duration: 520; easing.type: Easing.OutCubic }
    }
  }

  // ---- toggle ----
  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: {
      root.tracking = !root.tracking
      if (!root.tracking) {
        root.pupilX = 0
        root.pupilY = 0
      }
    }
  }
}

pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "components"
import "EyeState.js" as EyeState

// Minimalist eye bar widget, in the Omarchy theme style:
// - the pupil follows the mouse cursor (position from EyeState, fed by the
//   overlay helper eye-helper.py),
// - blinks randomly (not too often),
// - clicking the eye toggles tracking on/off; when on, the overlay draws the
//   click rings at the cursor (see Overlay.qml / RingLayer.qml).

Item {
  id: root

  property var bar: null
  property var shell: null

  property bool tracking: false   // QML-side copy of EyeState.tracking
  property real pupilX: 0
  property real pupilY: 0

  readonly property color fg: root.bar ? root.bar.barForeground : Color.foreground
  // Match the bar's icon canvas size (16) so the eye doesn't tower over the
  // other widgets, plus a hair for the ring to breathe.
  readonly property int slotSize: (Style.bar.iconCanvas > 0 ? Style.bar.iconCanvas : 16) + Style.space(1)
  readonly property real pupilTravel: slotSize * 0.20
  readonly property bool vertical: bar ? bar.vertical : false
  // Pupil dilates as the cursor approaches the eye: pupilZoom goes 1.0 (cursor
  // far away) up to maxPupilZoom (cursor at/near the eye), interpolated by how
  // close the cursor is within pupilDilationRange (logical px).
  property real pupilZoom: 1.0
  readonly property real pupilBaseSize: (slotSize - Style.space(6)) * 0.32
  readonly property real pupilSize: pupilBaseSize * pupilZoom
  readonly property real maxPupilZoom: 1.8
  readonly property real pupilDilationRange: 250
  readonly property int barBase: bar ? bar.barSize : slotSize

  // The widget spans the full bar height (like every other widget) and the
  // eye visual is centred inside it — otherwise the island Row top-aligns the
  // small eye and it rides above the rest of the bar. Width grows to fit key
  // pops to the right of the eye when keys are pressed, but is capped so it
  // never runs over the centre island.
  readonly property int maxPills: (Style.bar.iconSlot > 0 ? Style.bar.iconSlot : 26) * 10
  implicitWidth: vertical ? barBase : (barBase + Math.min(keys.implicitWidth, root.maxPills))
  implicitHeight: vertical ? slotSize : barBase

  Component.onDestruction: EyeState.tracking = false

  // ---- sync shared state + pupil direction ----
  Timer {
    id: sync
    interval: 33
    repeat: true
    running: true
    onTriggered: {
      if (root.tracking !== EyeState.tracking) root.tracking = EyeState.tracking
      var gp = eyeVisual.mapToGlobal(eyeVisual.width / 2, eyeVisual.height / 2)
      var dx = EyeState.cursorX - gp.x
      var dy = EyeState.cursorY - gp.y
      var a = Math.atan2(dy, dx)
      pupilX = Math.cos(a) * pupilTravel
      pupilY = Math.sin(a) * pupilTravel
      // Dilate as the cursor closes in: smaller distance -> bigger pupil.
      var dist = Math.hypot(dx, dy)
      var t = Math.max(0, 1 - dist / root.pupilDilationRange)
      root.pupilZoom = 1 + t * (root.maxPupilZoom - 1)
    }
  }

  // ---- random blink, not too often ----
  Timer {
    id: blinkTimer
    interval: 2500
    repeat: false
    running: true
    onTriggered: {
      // Occasionally do a quick double blink (blink-blink); otherwise a single.
      if (Math.random() < 0.25) doubleBlink.start()
      else blink.start()
      interval = 3000 + Math.random() * 6000
      restart()
    }
  }
  SequentialAnimation {
    id: blink
    NumberAnimation { target: blinkScale; property: "yScale"; to: 0.12; duration: 70; easing.type: Easing.InOutQuad }
    NumberAnimation { target: blinkScale; property: "yScale"; to: 1; duration: 90; easing.type: Easing.InOutQuad }
  }
  // A double blink: two quick close-open cycles with a tiny pause in between.
  SequentialAnimation {
    id: doubleBlink
    NumberAnimation { target: blinkScale; property: "yScale"; to: 0.12; duration: 70; easing.type: Easing.InOutQuad }
    NumberAnimation { target: blinkScale; property: "yScale"; to: 1; duration: 90; easing.type: Easing.InOutQuad }
    PauseAnimation { duration: 90 }
    NumberAnimation { target: blinkScale; property: "yScale"; to: 0.12; duration: 70; easing.type: Easing.InOutQuad }
    NumberAnimation { target: blinkScale; property: "yScale"; to: 1; duration: 90; easing.type: Easing.InOutQuad }
  }

  // ---- visuals: eye (centred in the icon slot) + live key pills to its right ----
  Item {
    id: layout
    // Left-anchored (not centred): the eye stays put and key pills grow right.
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: root.barBase + Math.min(keys.implicitWidth, root.maxPills)
    height: root.barBase
    Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

    // Framing ring: a sibling of the eye (outside the blink transform) so it
    // stays a full circle while the eye blinks ("open" during a blink) and stays
    // concentric with the eye — no squish/tilt from the blink. Same colour as
    // the eye (barForeground) so it reads as one medallion.
    Rectangle {
      id: eyeRing
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: root.slotSize
      height: root.slotSize
      radius: width / 2
      color: "transparent"
      border.width: Math.max(1, Style.spaceReal(1.5))
      border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.85)
    }

    Item {
      id: eyeVisual
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: root.slotSize
      height: root.slotSize
      transform: Scale {
        id: blinkScale
        origin.x: root.slotSize / 2
        origin.y: root.slotSize / 2
        yScale: 1
      }

      // ON = negative (theme-aware): sclera filled with the theme foreground,
      // pupil with the theme background — so on a dark theme the eye becomes a
      // light disc, on a light theme a dark disc. OFF = the normal outline eye.
      // The disc is held back from the ring so there's a clear gap between the
      // frame and the eye.
      Rectangle {
        id: sclera
        anchors.centerIn: parent
        width: root.slotSize - Style.space(6)
        height: root.slotSize - Style.space(6)
        radius: width / 2
        color: root.tracking ? root.fg : "transparent"
        border.width: root.tracking ? 0 : Math.max(1, Style.spaceReal(1))
        border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, root.tracking ? 0 : 0.55)
      }

      Rectangle {
        id: pupil
        width: root.pupilSize
        height: root.pupilSize
        radius: width / 2
        color: root.tracking ? Color.background : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.95)
        x: root.slotSize / 2 - width / 2 + root.pupilX
        y: root.slotSize / 2 - height / 2 + root.pupilY

        Behavior on x { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
        Behavior on y { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
        Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
        Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      }
    }

    KeyDisplay {
      id: keys
      anchors.left: eyeVisual.right
      anchors.leftMargin: Style.spaceReal(3)
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // ---- toggle ----
  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: {
      // Off only dims the eye and stops the click rings; the pupil keeps
      // following the cursor.
      EyeState.tracking = !EyeState.tracking
    }
  }
}

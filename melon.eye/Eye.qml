pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "components"
import "EyeState.js" as EyeState

// Minimalist eye bar widget, in the Omarchy theme style:
// - one filled sclera disc with a big dark pupil and a small specular glint
//   (a cartoon eye: no extra framing ring, the disc edge is the outline),
// - the pupil follows the mouse cursor (position from EyeState, fed by the
//   overlay helper eye-helper.py) and dilates as the cursor closes in,
// - blinks randomly (not too often),
// - clicking the eye toggles tracking on/off (off = the same eye, dimmed);
//   tracking on rings the eye in the theme accent as an "armed" cue, and the
//   overlay draws the click rings at the cursor
//   (see Overlay.qml / RingLayer.qml).

Item {
  id: root

  property var bar: null
  property var shell: null

  property bool tracking: false   // QML-side copy of EyeState.tracking
  property real pupilX: 0
  property real pupilY: 0

  // Match the bar's icon canvas size (16) so the eye doesn't tower over the
  // other widgets, plus a hair so the disc edge stays crisp against the bar.
  readonly property int slotSize: (Style.bar.iconCanvas > 0 ? Style.bar.iconCanvas : 16) + Style.space(1)
  // The eye is one disc that fills the slot; proportions follow a classic
  // cartoon eye: pupil ≈ 46% of the eye, glint ≈ 23% of the pupil, and the
  // pupil can travel 18% of the eye off-centre without leaving the sclera.
  readonly property real eyeSize: slotSize
  readonly property real pupilTravel: eyeSize * 0.18
  readonly property bool vertical: bar ? bar.vertical : false
  // Pupil reacts to how far the cursor is, in two segments — one range can't do
  // both jobs. A short one next to the eye (the old 250 px response, which is
  // what reads as "it noticed me") and a long tail out to the far corner of the
  // eye's screen, so moving away keeps constricting instead of freezing at the
  // value reached a few hundred pixels out.
  property real pupilZoom: 1.0
  readonly property real pupilBaseSize: eyeSize * 0.46
  readonly property real pupilSize: pupilBaseSize * pupilZoom
  readonly property real maxPupilZoom: 1.3   // cursor on the eye
  readonly property real midPupilZoom: 1.05  // at pupilNearRange
  readonly property real minPupilZoom: 0.7   // cursor at the far corner of the screen
  readonly property real pupilNearRange: 250

  // Distance that maps to full constriction: from the eye to the far corner of
  // its own screen, so it holds for any resolution or multi-monitor layout.
  function gazeReach(gp) {
    // `typeof` guard: the widget runs inside Quickshell, but the offscreen
    // render harness loads it without that module.
    var screens = (typeof Quickshell !== "undefined" && Quickshell.screens) ? Quickshell.screens : []
    var s = null
    for (var i = 0; i < screens.length; i++) {
      var c = screens[i]
      if (c && c.width > 0 && c.height > 0
          && gp.x >= c.x && gp.x < c.x + c.width
          && gp.y >= c.y && gp.y < c.y + c.height) {
        s = c
        break
      }
    }
    if (!s && root.bar && root.bar.window) s = root.bar.window.screen
    if (!s || !(s.width > 0)) return 900
    var ex = Math.max(gp.x - s.x, s.x + s.width - gp.x)
    var ey = Math.max(gp.y - s.y, s.y + s.height - gp.y)
    return Math.max(240, Math.hypot(ex, ey))
  }

  // The eye must always read as an eye — a light sclera with dark ink — in
  // both dark and light themes. On a dark theme that is foreground/background
  // as they come; on a light theme the roles swap, or the eye renders as a
  // negative (dark disc, light pupil) and stops looking like an eye. On a
  // light theme the sclera takes the bar's own paper colour, so the disc also
  // needs the ink rim to keep its edge.
  readonly property bool lightTheme: Color.background.hslLightness > Color.foreground.hslLightness
  readonly property color scleraColor: root.lightTheme ? Color.background : Color.foreground
  readonly property color inkColor: root.lightTheme ? Color.foreground : Color.background
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
      // Dilation -> constriction with distance: wide open on the eye, narrower
      // than the base drawing by the time the cursor reaches the far corner.
      var dist = Math.hypot(dx, dy)
      var reach = Math.max(root.pupilNearRange + 1, root.gazeReach(gp))
      var near = Math.min(dist, root.pupilNearRange) / root.pupilNearRange
      var far = Math.min(1, Math.max(0, (dist - root.pupilNearRange)
                                        / (reach - root.pupilNearRange)))
      root.pupilZoom = root.maxPupilZoom
                       - near * (root.maxPupilZoom - root.midPupilZoom)
                       - far * (root.midPupilZoom - root.minPupilZoom)
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

    // Tracker halo: the "armed" cue. Only present while tracking is on and in
    // the theme accent colour. It is a sibling of the eye (outside the blink
    // transform) so it stays a crisp circle while the eye squints, and it is a
    // touch larger than the sclera so it reads as a ring around the eye rather
    // than another edge on it.
    Rectangle {
      id: trackerRing
      anchors.horizontalCenter: eyeVisual.horizontalCenter
      anchors.verticalCenter: eyeVisual.verticalCenter
      width: root.eyeSize + Style.space(2)
      height: width
      radius: width / 2
      color: "transparent"
      border.width: Math.max(1, Style.spaceReal(1))
      border.color: Color.accent
      opacity: root.tracking ? 0.9 : 0

      Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
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

      // The eye: one filled disc, its own edge acting as the outline (the
      // bar behind it is the dark "ink"). Tracking off only dims the whole
      // eye — the drawing itself stays a complete, open eyeball.
      Rectangle {
        id: sclera
        anchors.centerIn: parent
        width: root.eyeSize
        height: root.eyeSize
        radius: width / 2
        color: root.scleraColor
        // On a light theme the sclera is the same paper as the bar, so the
        // ink rim is what draws the eye. On a dark theme the disc already
        // stands out and a rim would only eat into it.
        border.width: root.lightTheme ? Math.max(1, Style.spaceReal(1)) : 0
        border.color: root.inkColor
        opacity: root.tracking ? 1 : 0.8

        Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

        Rectangle {
          id: pupil
          width: root.pupilSize
          height: root.pupilSize
          radius: width / 2
          color: root.inkColor
          x: sclera.width / 2 - width / 2 + root.pupilX
          y: sclera.height / 2 - height / 2 + root.pupilY

          Behavior on x { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
          Behavior on y { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
          Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
          Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

          // Specular glint, pinned to the pupil's upper-right so it travels
          // with the gaze and still reads as a reflection of the window.
          Rectangle {
            width: parent.width * 0.23
            height: width
            radius: width / 2
            color: root.scleraColor
            x: parent.width * 0.57 - width / 2
            y: parent.height * 0.20 - height / 2
          }
        }
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

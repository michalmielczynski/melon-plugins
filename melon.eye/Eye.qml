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
    }
  }

  // ---- random blink, not too often ----
  Timer {
    id: blinkTimer
    interval: 2500
    repeat: false
    running: true
    onTriggered: {
      blink.start()
      interval = 3000 + Math.random() * 6000
      restart()
    }
  }
  SequentialAnimation {
    id: blink
    NumberAnimation { target: blinkScale; property: "yScale"; to: 0.12; duration: 70; easing.type: Easing.InOutQuad }
    NumberAnimation { target: blinkScale; property: "yScale"; to: 1; duration: 90; easing.type: Easing.InOutQuad }
  }

  // ---- visuals: eye (centred in the icon slot) + live key pills to its right ----
  Item {
    id: layout
    anchors.centerIn: parent
    width: root.barBase + Math.min(keys.implicitWidth, root.maxPills)
    height: root.barBase

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

      // ON = negative: solid black sclera + white pupil. OFF = the normal
      // eye: a fg outline + a dark pupil following the cursor.
      Rectangle {
        id: sclera
        anchors.centerIn: parent
        width: root.slotSize - Style.space(2)
        height: root.slotSize - Style.space(2)
        radius: width / 2
        color: root.tracking ? Qt.rgba(0, 0, 0, 1) : "transparent"
        border.width: root.tracking ? 0 : Math.max(1, Style.spaceReal(1))
        border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, root.tracking ? 0 : 0.55)
      }

      Rectangle {
        id: pupil
        width: root.slotSize * 0.30
        height: root.slotSize * 0.30
        radius: width / 2
        color: root.tracking ? Qt.rgba(1, 1, 1, 1) : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.95)
        x: root.slotSize / 2 - width / 2 + root.pupilX
        y: root.slotSize / 2 - height / 2 + root.pupilY

        Behavior on x { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
        Behavior on y { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
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

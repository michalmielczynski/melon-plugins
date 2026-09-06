pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "../EyeState.js" as EyeState

// Transparent, click-through overlay that draws the click rings at the mouse
// cursor. One instance per screen; a ring is only visible on the screen that
// actually contains the cursor, because the others get out-of-bounds coords.

PanelWindow {
  id: root

  required property var screen

  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "melon-eye-rings"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  // Click-through: a single pixel of input region in the corner; everything
  // else falls through to the windows below.
  mask: Region { width: 1; height: 1 }

  property int lastSeq: EyeState.ringSeq

  // TEMP TEST removed

  // Poll the shared mailbox and spawn a ring when a click happened.
  Timer {
    id: seqWatcher
    interval: 33
    repeat: true
    running: true
    onTriggered: root.pollRings()
  }

  function pollRings() {
    // Persistent cursor marker: follow the shared cursor position (fed by the
    // helper at ~20 Hz). Only the screen that actually contains the cursor
    // shows it; the others get out-of-bounds coords and hide it. Shown only
    // while tracking is on — a small ring around the mouse so screencast
    // viewers can see where the cursor is.
    var gp = content.mapFromGlobal(EyeState.cursorX, EyeState.cursorY)
    cursorMarker.targetX = gp.x
    cursorMarker.targetY = gp.y
    cursorMarker.onScreen = (gp.x >= 0 && gp.y >= 0 && gp.x <= content.width && gp.y <= content.height)
    cursorMarker.trackingNow = EyeState.tracking

    if (lastSeq === EyeState.ringSeq) return
    lastSeq = EyeState.ringSeq
    ringModel.append({
      cx: gp.x,
      cy: gp.y,
      rc: String(EyeState.ringColor),
      expire: Date.now() + 750
    })
    sweeper.restart()
  }

  Timer {
    id: sweeper
    interval: 100
    repeat: true
    running: false
    onTriggered: {
      while (ringModel.count > 0 && ringModel.get(0).expire <= Date.now()) ringModel.remove(0)
      if (ringModel.count === 0) stop()
    }
  }

  ListModel { id: ringModel }

  Item {
    id: content
    anchors.fill: parent

    Repeater {
      model: ringModel

      delegate: Item {
        required property real cx
        required property real cy
        required property color rc

        x: cx - 24
        y: cy - 24
        width: 48
        height: 48

        Rectangle {
          id: ring
          anchors.fill: parent
          radius: width / 2
          color: "transparent"
          border.width: 3
          border.color: rc
          opacity: 0
          scale: 0.5
          transformOrigin: Item.Center

          ParallelAnimation {
            id: bloom
            NumberAnimation { target: ring; property: "scale"; from: 0.5; to: 2.2; duration: 550; easing.type: Easing.OutCubic }
            NumberAnimation { target: ring; property: "opacity"; from: 0.95; to: 0; duration: 550; easing.type: Easing.OutCubic }
          }

          Component.onCompleted: bloom.start()
        }
      }
    }

    // Persistent, calm halo around the cursor. Follows the cursor in real time
    // (repositioned by pollRings above) and only appears when tracking is on.
    Item {
      id: cursorMarker
      property real targetX: 0
      property real targetY: 0
      property bool onScreen: false
      property bool trackingNow: false

      x: targetX - width / 2
      y: targetY - height / 2
      width: 30
      height: 30
      opacity: (trackingNow && onScreen) ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: "transparent"
        border.width: 2
        border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.9)
      }
    }
  }
}

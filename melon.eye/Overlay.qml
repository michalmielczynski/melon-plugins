pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "components"
import "EyeState.js" as EyeState

// melon.eye overlay host:
// - runs the cursor/click helper (eye-helper.py) when tracking is on,
// - updates the shared cursor position,
// - bumps the shared ring mailbox on left/right/middle clicks,
// - hosts one transparent RingLayer per screen that draws the rings.
// The bar eye widget (Eye.qml) reads the same EyeState for its pupil.

Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string helperPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/melon.eye/eye-helper.py"

  // ---- helper: cursor position + mouse clicks via stdout lines ----
  Process {
    id: helper
    command: ["python3", root.helperPath]
    stdout: SplitParser { splitMarker: "\n" }
  }
  // EyeState.tracking is a plain JS var (not bindable), so sync via a timer.
  Timer {
    id: trackingSync
    interval: 250
    repeat: true
    running: true
    onTriggered: {
      var want = EyeState.tracking ? true : false
      if (helper.running !== want) helper.running = want
    }
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
          EyeState.cursorX = px
          EyeState.cursorY = py
        }
      }
    } else if (line === "L") {
      EyeState.notifyClick(String(Color.accent))
    } else if (line === "R") {
      EyeState.notifyClick(String(Color.urgent))
    } else if (line === "M") {
      EyeState.notifyClick(String(Color.foreground))
    }
  }

  Component.onDestruction: helper.running = false

  // ---- one ring layer per screen ----
  Variants {
    model: Quickshell.screens

    delegate: Component {
      RingLayer {
        required property var modelData
        screen: modelData
      }
    }
  }
}

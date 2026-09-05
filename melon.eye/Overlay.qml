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
  // Runs always: the eye's pupil follows the cursor even when tracking is
  // off (off only dims the eye and disables the click rings).
  Process {
    id: helper
    command: ["/usr/bin/python3", root.helperPath]
    running: true
    stdout: SplitParser { splitMarker: "\n" }
    stderr: SplitParser { splitMarker: "\n" }
  }
  Connections {
    target: helper.stderr
    function onRead(line) { console.log("helper stderr: " + String(line)) }
  }
  Connections {
    target: helper.stdout
    function onRead(line) { root.onHelperLine(String(line).trim()) }
  }

  function onHelperLine(line) {
    var parts = line.split(" ")
    if (parts[0] === "P" && parts.length === 3) {
      var px = Number(parts[1])
      var py = Number(parts[2])
      if (isFinite(px) && isFinite(py)) {
        EyeState.cursorX = px
        EyeState.cursorY = py
      }
    } else if (parts[0] === "C" && parts.length === 4) {
      // Click with the cursor position captured at the click moment: update
      // the position first so the ring spawns exactly under the cursor.
      var cx = Number(parts[1])
      var cy = Number(parts[2])
      if (isFinite(cx) && isFinite(cy)) {
        EyeState.cursorX = cx
        EyeState.cursorY = cy
        if (EyeState.tracking) {
          var code = parts[3]
          if (code === "L") {
            EyeState.notifyClick(String(Color.accent))
          } else if (code === "R") {
            EyeState.notifyClick(String(Color.urgent))
          } else if (code === "M") {
            EyeState.notifyClick(String(Color.foreground))
          }
        }
      }
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

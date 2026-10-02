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
  // Green ring shown when a mouse/touchpad button is RELEASED.
  readonly property color releaseGreen: "#3fae5f"

  // ---- helper: cursor position + mouse clicks via stdout lines ----
  // Runs always: the eye's pupil follows the cursor even when tracking is
  // off (off only dims the eye and disables the click rings).
  Process {
    id: helper
    command: ["/usr/bin/python3", "-B", root.helperPath]
    running: true
    stdout: SplitParser { splitMarker: "\n" }
    stderr: SplitParser { splitMarker: "\n" }
    // The helper is the ONLY source of cursor position, clicks and keys: when it
    // exits (crash, a device that went away, the shell dropping its stdout) the
    // rings and key pills go dead while the eye still sits in the bar. Bring it
    // back instead of leaving the widget half-working until a manual reload.
    onExited: function(exitCode, exitStatus) {
      console.warn("melon.eye: helper exited (code " + exitCode + "), restarting")
      helperRestart.restart()
    }
  }
  Timer {
    id: helperRestart
    interval: 1000
    onTriggered: helper.running = true
  }
  // Watchdog: the helper prints a cursor line at ~60 Hz. Once it has spoken,
  // 8 s of silence means it is wedged (not merely waiting for Hyprland's IPC
  // socket at boot) — restart it.
  property bool helperSpoke: false
  Timer {
    id: helperWatchdog
    interval: 1000
    repeat: true
    running: true
    property double lastLine: 0
    onTriggered: {
      if (!root.helperSpoke || !helper.running) return
      if (Date.now() - lastLine > 8000) {
        console.warn("melon.eye: helper silent for 8 s, restarting")
        lastLine = Date.now()
        helper.running = false
        helperRestart.restart()
      }
    }
  }
  Connections {
    target: helper.stdout
    function onRead(line) { root.onHelperLine(String(line).trim()) }
  }
  Connections {
    target: helper.stderr
    // Helper tracebacks used to disappear into a SplitParser with no handler,
    // which is why the death of the helper was invisible.
    function onRead(line) {
      var text = String(line).trim()
      if (text) console.warn("melon.eye helper: " + text)
    }
  }

  function onHelperLine(line) {
    helperWatchdog.lastLine = Date.now()
    root.helperSpoke = true
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
          var color = code === "G" ? String(root.releaseGreen)
                    : code === "R" ? String(Color.urgent)
                    : code === "M" ? String(Color.foreground)
                    : String(Color.accent)   // L, D, T all use the accent
          EyeState.notifyClick(color, code)
        }
      }
    } else if (parts[0] === "K" && parts.length >= 2 && EyeState.tracking) {
      var mods = parts.length >= 3 ? parts[2] : ""
      EyeState.notifyKey(parts[1], mods)
    } else if (parts[0] === "M" && parts.length === 3 && EyeState.tracking) {
      EyeState.notifyMod(parts[1], parts[2] === "1")
    } else if (parts[0] === "H" && parts.length === 3) {
      EyeState.notifyButton(parts[1], parts[2] === "1")
    }
  }

  Component.onDestruction: helper.running = false

  // ---- one ring layer + key panel per screen ----
  Variants {
    model: Quickshell.screens

    delegate: Component {
      Item {
        id: screenRoot
        required property var modelData
        readonly property var screen: modelData
        RingLayer { screen: screenRoot.screen }
      }
    }
  }
}

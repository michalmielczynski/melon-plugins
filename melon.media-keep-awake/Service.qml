import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris

// Keeps the Omarchy idle service (screensaver + lock) suspended while any
// MPRIS media player is playing. Browsers do not hold Wayland idle
// inhibitors for video playback, so the built-in IdleMonitor alone would
// blank the screen mid-YouTube.
//
// We reuse the same stay-awake state file the 󰅶 bar indicator uses
// (~/.local/state/omarchy/indicators/stay-awake); the idle service watches
// that directory and reacts immediately.
//
// Ownership rules (never clobber a manual toggle): a marker file next to the
// state file records that WE created it (and survives shell restarts).
//   - on playback start:
//       marker present          -> ours from before a restart, keep owning
//       state file only         -> manual toggle, leave everything alone
//       neither                 -> create state file + marker (we own it)
//   - on playback stop: if we own it, remove marker and state file
Item {
  id: root

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/indicators"
  readonly property string statePath: stateDir + "/stay-awake"
  readonly property string markerPath: stateDir + "/stay-awake-media-keep"

  property bool weOwn: false
  property bool playingNow: false

  readonly property var players: Mpris.players ? Mpris.players.values : []

  function log(msg) { console.log("omarchy media-keep-awake " + msg) }

  function writeState(enabled) {
    if (stateWriter.running) return
    var command = enabled
      ? "mkdir -p \"" + root.stateDir + "\" && touch \"" + root.statePath + "\""
      : "rm -f \"" + root.statePath + "\" && rm -f \"" + root.markerPath + "\""
    stateWriter.command = ["bash", "-c", command]
    stateWriter.running = true
  }

  function updatePlaying() {
    var list = root.players
    var found = false
    for (var i = 0; i < list.length; i++) {
      if (list[i] && list[i].isPlaying) { found = true; break }
    }
    if (found !== root.playingNow) root.playingNow = found
  }

  function onPlayingChanged() {
    if (root.playingNow) {
      if (probe.running) return
      probe.command = ["bash", "-c",
        "if [[ -f \"" + root.markerPath + "\" ]]; then echo ours; " +
        "elif [[ -f \"" + root.statePath + "\" ]]; then echo manual; " +
        "else mkdir -p \"" + root.stateDir + "\" && touch \"" + root.statePath + "\" \"" + root.markerPath + "\" && echo created; fi"]
      probe.running = true
    } else if (root.weOwn) {
      root.weOwn = false
      root.log("media stopped -> re-enabling idle")
      root.writeState(false)
    }
  }

  Component.onCompleted: root.log("service-ready")

  Process {
    id: stateWriter
  }

  Process {
    id: probe
    stdout: SplitParser {
      onRead: function(line) {
        var result = String(line).trim()
        if (result === "manual") {
          root.weOwn = false
          root.log("media playing, stay-awake already on (manual) -> leaving it alone")
        } else {
          root.weOwn = true
          root.log("media playing -> staying awake (" + result + ")")
          // The idle service probes the state dir on startup and watches it
          // afterwards. If we race its startup (file appears before the
          // watcher attaches), touch again after a moment so the fileChanged
          // signal is guaranteed to fire.
          confirmTouchTimer.restart()
        }
      }
    }
  }

  Timer {
    id: confirmTouchTimer
    interval: 2000
    repeat: false
    onTriggered: if (root.weOwn) root.writeState(true)
  }

  // Small delay so the Mpris service has populated players before we act on
  // a player that may already be playing at shell (re)start.
  Timer {
    interval: 1000
    repeat: false
    running: true
    onTriggered: {
      root.updatePlaying()
      root.log("initial-scan players=" + root.players.length + " playing=" + root.playingNow)
      root.onPlayingChanged()
    }
  }

  onPlayersChanged: root.updatePlaying()
  onPlayingNowChanged: root.onPlayingChanged()

  Instantiator {
    model: root.players
    delegate: Connections {
      required property var modelData
      target: modelData
      function onIsPlayingChanged() { root.updatePlaying() }
    }
  }
}

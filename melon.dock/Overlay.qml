pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "components"

// Melon Dock — an Omarchy-native application dock. Runs inside the long-lived
// omarchy-shell process as a keep-loaded overlay plugin. Reads its settings
// from ~/.config/omarchy/dock.json and renders one Dock per screen.
Item {
  id: root

  // Properties injected by the Omarchy shell plugin host.
  property var shell: null
  property var manifest: null

  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/dock.json"

  property var settings: ({
    iconSize: 40,
    margin: 8,
    backgroundOpacity: 0.72,
    position: "bottom",
    fullLength: false,
    reserveSpace: false,
    autoHide: true,
    revealThickness: 12,
    clickAction: "focus-or-launch",
    showLauncher: true,
    pinned: [
      "org.gnome.Nautilus",
      "com.google.Chrome",
      "com.mitchellh.ghostty",
      "code",
      "obsidian",
      "chatgpt"
    ]
  })

  function loadSettings(raw) {
    try {
      var parsed = JSON.parse(raw)
      if (!parsed.pinned || !Array.isArray(parsed.pinned))
        throw new Error("'pinned' must be an array")
      settings = parsed
    } catch (error) {
      console.warn("Dock: could not load " + configPath + ":", error)
    }
  }

  function reorderPinned(from, to) {
    if (from === to || from < 0 || to < 0
        || from >= settings.pinned.length || to >= settings.pinned.length)
      return
    var pinned = settings.pinned.slice()
    var moved = pinned.splice(from, 1)[0]
    pinned.splice(to, 0, moved)
    savePinned(pinned)
  }

  function pinApplication(desktopId) {
    if (!desktopId || settings.pinned.indexOf(desktopId) >= 0) return
    var pinned = settings.pinned.slice()
    pinned.push(desktopId)
    savePinned(pinned)
  }

  function unpinApplication(desktopId) {
    var index = settings.pinned.indexOf(desktopId)
    if (index < 0) return
    var pinned = settings.pinned.slice()
    pinned.splice(index, 1)
    savePinned(pinned)
  }

  function savePinned(pinned) {
    saveSetting("pinned", pinned)
  }

  function saveSetting(key, value) {
    var updated = {}
    for (var setting in settings)
      updated[setting] = settings[setting]
    updated[key] = value
    settings = updated
    configFile.setText(JSON.stringify(updated, null, 2) + "\n")
  }

  FileView {
    id: configFile

    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadSettings(text())
    onFileChanged: reload()
    onSaveFailed: error => console.warn("Dock: could not save " + root.configPath + ":", error)
  }

  Variants {
    model: Quickshell.screens

    delegate: Component {
      Dock {
        required property var modelData

        screen: modelData
        shell: root.shell
        settings: root.settings
        onReorderRequested: (from, to) => root.reorderPinned(from, to)
        onPinRequested: desktopId => root.pinApplication(desktopId)
        onUnpinRequested: desktopId => root.unpinApplication(desktopId)
        onAutoHideRequested: enabled => root.saveSetting("autoHide", enabled)
      }
    }
  }
}

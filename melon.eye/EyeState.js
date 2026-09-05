// Shared state between the bar eye widget and the click-ring overlay.
// .pragma library: the state is shared across all imports in the shell process.
.pragma library

// Whether tracking (and the click rings) are on. Toggled by the eye widget.
var tracking = false

// Last known cursor position in global layout coordinates (from Hyprland IPC).
var cursorX = 0
var cursorY = 0

// Click-ring mailbox: the overlay controller bumps ringSeq on every click and
// stores the ring colour; each ring layer polls and spawns on change.
var ringSeq = 0
var ringColor = "#00000000"

function notifyClick(color) {
  ringColor = color
  ringSeq += 1
}

// --- key display state -------------------------------------------------------
// The helper emits "K <name> <mods>" and "M <mod> <0|1>"; the overlay pushes
// each key into a QUEUE so no key is lost even when several arrive between the
// panel's polls (fast typing). keySeq = number of keys received; the panel
// drains keyQueue[lastSeen..keySeq-1].
var keyQueue = []
var keySeq = 0
var heldMods = ""

function notifyKey(name, mods) {
  keyQueue.push({ name: name, mods: mods })
  keySeq += 1
  heldMods = mods
}

function notifyMod(mod, down) {
  var set = heldMods ? heldMods.split(",") : []
  var has = set.indexOf(mod) !== -1
  if (down && !has) set.push(mod)
  if (!down && has) set.splice(set.indexOf(mod), 1)
  heldMods = set.join(",")
}

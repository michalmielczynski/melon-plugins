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

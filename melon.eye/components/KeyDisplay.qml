pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui
import "../EyeState.js" as EyeState

// Inline keypress pills for the top bar (compact, fits the bar height).
// Reads EyeState (fed by eye-helper.py + the overlay): holds the most recent
// keystroke groups; each fades out independently (hold then fade) so the bar
// grows while keys are pressed and returns to its normal size afterwards.

Item {
  id: root

  property int holdMs: 1400
  property int fadeMs: 2400
  property real gap: Style.spaceReal(2)

  property int clock: 0
  property int lastSeq: EyeState.keySeq
  property string heldMods: ""

  ListModel { id: hist }

  implicitWidth: row.implicitWidth
  implicitHeight: row.implicitHeight

  Timer { id: poll; interval: 33; repeat: true; running: true; onTriggered: root.poll() }
  Timer { id: clk; interval: 50; repeat: true; running: true; onTriggered: root.clock++ }

  function poll() {
    if (root.heldMods !== EyeState.heldMods) root.heldMods = EyeState.heldMods
    // Drain every new key (in order, none lost even on fast typing).
    while (lastSeq < EyeState.keySeq) {
      var ev = EyeState.keyQueue[lastSeq]
      if (ev) hist.append({ kseq: lastSeq, name: ev.name, mods: ev.mods, born: root.clock })
      lastSeq++
    }
    while (hist.count > 7) hist.remove(0)
    // Sweep faded items on every poll so the bar collapses back after typing.
    var i = 0
    while (i < hist.count) {
      var ag = root.clock - hist.get(i).born
      var th = (root.holdMs + root.fadeMs) / 50
      if (ag > th) hist.remove(i)
      else i++
    }
  }

  Row {
    id: row
    spacing: root.gap

    // currently-held modifiers (lit)
    Repeater {
      model: root.heldMods ? root.heldMods.split(",") : []
      delegate: Pill {
        required property string modelData
        mod: modelData
        held: true
        compact: true
      }
    }

    // past keystroke groups, each fading independently
    Repeater {
      id: histRep
      model: hist

      delegate: Item {
        required property string name
        required property string mods
        required property int born

        readonly property int age: root.clock - born
        opacity: {
          if (age * 50 <= root.holdMs) return 1
          return Math.max(0, 1 - (age * 50 - root.holdMs) / root.fadeMs)
        }

        // Combined label, e.g. "⌃+⇧+S" (or just "S" with no modifiers).
        readonly property string comboLabel: {
          var arr = mods ? mods.split(",") : []
          var s = ""
          for (var i = 0; i < arr.length; i++) {
            var m = arr[i]
            s += (m === "ctrl" ? "⌃" : m === "shift" ? "⇧" : m === "alt" ? "⌥" : m === "super" ? "⌘" : m) + "+"
          }
          return s + name
        }

        Pill {
          label: comboLabel
          combo: mods !== ""
          isKey: mods === ""
          compact: true
        }
      }
    }
  }
}

pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "../EyeState.js" as EyeState

// Discreet floating keypress panel, Omarchy-themed. A fullscreen transparent
// click-through window whose content is a horizontal row of "keystroke groups"
// anchored to the bottom-centre. Each group fades out INDEPENDENTLY (per key):
// it stays fully visible for HOLD_MS then fades over FADE_MS. Newest groups sit
// at the right; a leading indicator shows the modifiers held right now.

PanelWindow {
  id: root

  required property var screen

  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "melon-eye-keys"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  mask: Region { width: 1; height: 1 }

  readonly property int holdMs: 1200
  readonly property int fadeMs: 2400
  property int clock: 0

  ListModel { id: hist }
  property int lastSeq: EyeState.keySeq
  property string heldMods: ""

  Timer { id: poll; interval: 33; repeat: true; running: true; onTriggered: root.poll() }
  Timer { id: clk; interval: 50; repeat: true; running: true; onTriggered: root.clock++ }

  function poll() {
    if (root.heldMods !== EyeState.heldMods) root.heldMods = EyeState.heldMods
    if (lastSeq === EyeState.keySeq) return
    lastSeq = EyeState.keySeq
    hist.append({ kseq: EyeState.keySeq, name: EyeState.keyName, mods: EyeState.keyMods, born: root.clock })
    while (hist.count > 8) hist.remove(0)
    // remove fully-faded items (their age exceeds HOLD+FADE)
    var i = 0
    while (i < hist.count) {
      if (root.clock - hist.get(i).born > (root.holdMs + root.fadeMs) / 50) hist.remove(i)
      else i++
    }
  }

  Item {
    anchors.fill: parent

    Row {
      id: rowLayout
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(10)
      spacing: Style.space(4)

      // current held modifiers (lit)
      Repeater {
        model: root.heldMods ? root.heldMods.split(",") : []
        delegate: Pill {
          required property string modelData
          mod: modelData
          held: true
        }
      }

      // past keystroke groups, newest at the end, each fading independently
      Repeater {
        id: histRep
        model: hist

        delegate: Item {
          required property string name
          required property string mods
          required property int born

          readonly property int age: root.clock - born
          opacity: {
            // fully visible for holdMs, then fade to 0 over fadeMs
            if (age * 50 <= root.holdMs) return 1
            return Math.max(0, 1 - (age * 50 - root.holdMs) / root.fadeMs)
          }
          implicitWidth: grpRow.implicitWidth
          implicitHeight: grpRow.implicitHeight

          Row {
            id: grpRow
            spacing: Style.space(4)

            Repeater {
              model: mods ? mods.split(",") : []
              delegate: Pill {
                required property string modelData
                mod: modelData
                held: false
              }
            }
            Pill { mod: name; isKey: true }
          }
        }
      }
    }
  }
}

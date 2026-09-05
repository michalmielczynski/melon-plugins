pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "../EyeState.js" as EyeState

// Discreet floating keypress panel, Omarchy-themed. A fullscreen transparent
// click-through window whose content is a horizontal row of "keystroke groups"
// anchored to the bottom-centre. Newest group is full opacity; older groups
// fade out slowly (not abruptly), like screenkey / showmethekey. A leading
// indicator shows the modifiers held right now.

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

  readonly property color accent: Color.accent

  ListModel { id: hist }

  property int lastSeq: EyeState.keySeq
  property string heldMods: ""

  Timer {
    id: poll
    interval: 33
    repeat: true
    running: true
    onTriggered: root.poll()
  }
  function poll() {
    if (root.heldMods !== EyeState.heldMods) root.heldMods = EyeState.heldMods
    if (lastSeq === EyeState.keySeq) return
    lastSeq = EyeState.keySeq
    hist.append({ name: EyeState.keyName, mods: EyeState.keyMods, born: Date.now() })
    while (hist.count > 6) hist.remove(0)
  }

  Item {
    anchors.fill: parent

    Row {
      id: rowLayout
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(8)
      spacing: Style.space(3)

      // current held modifiers (lit)
      Repeater {
        model: root.heldMods ? root.heldMods.split(",") : []
        delegate: Pill {
          required property string modelData
          mod: modelData
          held: true
        }
      }

      // past keystroke groups, newest at the end (rightmost), fading out
      Repeater {
        id: histRep
        model: hist

        delegate: Item {
          required property string name
          required property string mods
          required property int born

          implicitWidth: grpRow.implicitWidth
          implicitHeight: grpRow.implicitHeight
          opacity: 1

          Row {
            id: grpRow
            spacing: Style.space(3)

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

          SequentialAnimation {
            running: true
            PauseAnimation { duration: 900 }
            NumberAnimation { target: parent; property: "opacity"; to: 0; duration: 2200; easing.type: Easing.OutCubic }
            onStopped: {
              var i
              for (i = 0; i < histRep.model.count; i++) {
                if (histRep.model.get(i).born === born) { histRep.model.remove(i); break }
              }
            }
          }
        }
      }
    }
  }
}

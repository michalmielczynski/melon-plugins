pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// A single keycap "pill": rounded, Omarchy-coloured. Modifiers are shown with
// an accent accent underline; the main (pressed) key is solid foreground.

Rectangle {
  id: root

  property string mod: ""
  property bool held: false
  property bool isKey: false

  readonly property bool isMod: mod === "ctrl" || mod === "shift" || mod === "alt" || mod === "super"

  implicitWidth: label.implicitWidth + Style.space(6)
  implicitHeight: label.implicitHeight + Style.space(4)
  radius: Style.cornerRadius
  color: root.isKey
    ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)
    : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.05)
  border.width: 1
  border.color: root.isMod
    ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b,
              root.held ? 0.8 : 0.35)
    : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.18)

  readonly property color accent: Color.accent

  Text {
    id: label
    anchors.centerIn: parent
    text: root.isMod ? qsTr(root.mod.charAt(0).toUpperCase() + root.mod.slice(1))
                     : root.mod
    color: root.isMod
      ? (root.held ? root.accent : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.7))
      : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.95)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    font.bold: root.isKey
  }
}

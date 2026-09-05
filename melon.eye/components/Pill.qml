pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

// A single keycap "pill": rounded, Omarchy-coloured. Modifiers are shown with
// an accent underline/border; the main (pressed) key is a solid keycap.

Rectangle {
  id: root

  property string mod: ""
  property bool held: false
  property bool isKey: false

  readonly property bool isMod: mod === "ctrl" || mod === "shift" || mod === "alt" || mod === "super"

  implicitWidth: label.implicitWidth + Style.space(9)
  implicitHeight: label.implicitHeight + Style.space(6)
  radius: Style.cornerRadius

  // Opaque, theme-aware background so pills are fully readable on any theme.
  color: Color.popups.background
  border.width: 1.5
  border.color: root.isMod
    ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, root.held ? 1.0 : 0.6)
    : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.45)

  Text {
    id: label
    anchors.centerIn: parent
    text: root.isMod ? qsTr(root.mod.charAt(0).toUpperCase() + root.mod.slice(1))
                     : root.mod
    color: root.isMod
      ? (root.held ? Color.accent : Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.85))
      : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 1.0)
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    font.bold: root.isKey || root.isMod
  }
}

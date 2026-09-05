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
  // When set, overrides the label text (used for combined pills like "⌃S").
  property string label: ""
  // A combined modifier+key pill: uses the accent border like a modifier.
  property bool combo: false
  // Compact mode sizes the pill to fit inside the bar (barSize height) when
  // the pills are rendered inline in the top bar rather than in a floating
  // panel.
  property bool compact: false

  readonly property bool isMod: mod === "ctrl" || mod === "shift" || mod === "alt" || mod === "super"
  readonly property string modIcon: mod === "ctrl" ? "⌃"
    : mod === "shift" ? "⇧"
    : mod === "alt" ? "⌥"
    : mod === "super" ? "⌘" : mod

  implicitWidth: textLabel.implicitWidth + (root.compact ? Style.space(5) : Style.space(9))
  implicitHeight: textLabel.implicitHeight + (root.compact ? Style.space(3) : Style.space(6))
  radius: Style.cornerRadius

  readonly property bool topAccent: root.isMod || root.combo

  // Opaque, theme-aware background so pills are fully readable on any theme.
  color: Color.popups.background
  border.width: 1.5
  border.color: root.topAccent
    ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, root.held ? 1.0 : 0.6)
    : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.45)

  Text {
    id: textLabel
    anchors.centerIn: parent
    text: root.label !== "" ? root.label : (root.isMod ? root.modIcon : root.mod)
    color: root.topAccent
      ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, root.held ? 1.0 : 0.9)
      : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 1.0)
    font.family: Style.font.family
    font.pixelSize: root.compact ? Style.font.bodySmall : Style.font.body
    font.bold: root.isKey || root.isMod || root.combo
  }
}

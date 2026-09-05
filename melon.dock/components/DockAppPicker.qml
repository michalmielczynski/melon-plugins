pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Commons
import qs.Ui

// Full-screen modal used to add a pinned application to the dock. Renders a
// dim scrim behind a centered search card (OSD-style, robust positioning).
Item {
  id: root

  required property Item anchorItem
  required property string position
  required property var pinned

  signal applicationSelected(string desktopId)

  // True while the picker window is actually shown (used by the dock's
  // auto-hide keep-open logic).
  readonly property bool opened: pickerWindow.visible

  readonly property var applications: DesktopEntries.applications.values || []
  readonly property var filteredApplications: filterApplications(searchInput.text)

  function open() {
    searchInput.text = ""
    pickerWindow.visible = true
    Qt.callLater(() => searchInput.forceActiveFocus())
  }

  function close() {
    pickerWindow.visible = false
  }

  function matchScore(value, query) {
    var text = String(value || "").toLowerCase()
    var exactIndex = text.indexOf(query)
    if (exactIndex >= 0) return 1000 - exactIndex * 4 - text.length
    var queryIndex = 0
    var previousIndex = -2
    var score = 0
    for (var i = 0; i < text.length && queryIndex < query.length; ++i) {
      if (text[i] !== query[queryIndex]) continue
      score += i === previousIndex + 1 ? 8 : 2
      previousIndex = i
      ++queryIndex
    }
    return queryIndex === query.length ? score - text.length : -1
  }

  function filterApplications(rawQuery) {
    var query = String(rawQuery || "").trim().toLowerCase()
    var matches = []
    var modelRevision = applications.length
    for (var i = 0; i < applications.length; ++i) {
      var application = applications[i]
      if (!application || !application.id || application.noDisplay
          || pinned.indexOf(application.id) >= 0) continue
      var score = query
        ? Math.max(matchScore(application.name, query), matchScore(application.id, query))
        : 0
      if (score >= 0) matches.push({ application: application, score: score })
    }
    matches.sort((left, right) => right.score - left.score
      || String(left.application.name).localeCompare(String(right.application.name)))
    return matches.slice(0, 100).map(match => match.application)
  }

  function selectCurrent() {
    if (applicationList.currentIndex < 0 || applicationList.currentIndex >= filteredApplications.length) return
    var application = filteredApplications[applicationList.currentIndex]
    close()
    applicationSelected(application.id)
  }

  onFilteredApplicationsChanged: applicationList.currentIndex = filteredApplications.length ? 0 : -1

  PanelWindow {
    id: pickerWindow

    visible: false
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "melon-dock-picker"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    exclusionMode: ExclusionMode.Ignore

    // Scrim: dim the desktop; clicking outside dismisses.
    Rectangle {
      anchors.fill: parent
      color: Util.alpha(Color.background, 0.5)

      MouseArea {
        anchors.fill: parent
        onClicked: root.close()
      }
    }

    // Centered search card.
    BorderSurface {
      id: card

      anchors.centerIn: parent
      width: Style.space(480)
      height: Style.space(520)
      radius: Style.cornerRadius
      color: Color.popups.background
      borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Math.max(1, Style.spaceReal(2)))
      padding: Style.spacing.md

      ColumnLayout {
        anchors.fill: parent
        spacing: Style.spacing.md

        Rectangle {
          id: searchField

          Layout.fillWidth: true
          height: Style.space(40)
          radius: Style.cornerRadius
          color: searchInput.activeFocus
            ? Style.selectedFillFor(Color.foreground, Color.accent)
            : Style.hoverFillFor(Color.foreground, Color.accent)
          border.width: 1
          border.color: searchInput.activeFocus ? Color.accent : Util.alpha(Color.muted, 0.4)

          Behavior on border.color { ColorAnimation { duration: 120 } }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.lg
            visible: !searchInput.text
            text: "Search applications…"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          TextInput {
            id: searchInput

            anchors.fill: parent
            anchors.leftMargin: Style.spacing.lg
            anchors.rightMargin: Style.spacing.lg
            verticalAlignment: TextInput.AlignVCenter
            color: Color.foreground
            selectionColor: Util.alpha(Color.accent, 0.35)
            selectedTextColor: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            clip: true

            Keys.onPressed: event => {
              if (event.key === Qt.Key_Down) {
                applicationList.currentIndex = Math.min(applicationList.count - 1, applicationList.currentIndex + 1)
                applicationList.positionViewAtIndex(applicationList.currentIndex, ListView.Contain)
                event.accepted = true
              } else if (event.key === Qt.Key_Up) {
                applicationList.currentIndex = Math.max(0, applicationList.currentIndex - 1)
                applicationList.positionViewAtIndex(applicationList.currentIndex, ListView.Contain)
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.selectCurrent()
                event.accepted = true
              } else if (event.key === Qt.Key_Escape) {
                root.close()
                event.accepted = true
              }
            }
          }
        }

        ListView {
          id: applicationList

          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          spacing: Style.spacing.xs
          model: root.filteredApplications

          delegate: Rectangle {
            id: applicationRow

            required property var modelData
            required property int index

            width: applicationList.width
            height: Style.space(48)
            radius: Style.cornerRadius
            color: applicationList.currentIndex === index
              ? Style.hoverFillFor(Color.foreground, Color.accent)
              : "transparent"

            Behavior on color { ColorAnimation { duration: 100 } }

            IconImage {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.lg
              width: Style.space(28)
              height: Style.space(28)
              source: applicationRow.modelData.icon
                ? Quickshell.iconPath(applicationRow.modelData.icon, true)
                : Quickshell.iconPath("application-x-executable", true)
              asynchronous: true
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.spacing.lg + Style.space(34)
              anchors.rightMargin: Style.spacing.lg
              spacing: 1

              Text {
                width: parent.width
                text: applicationRow.modelData.name || applicationRow.modelData.id
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: applicationRow.modelData.id
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            HoverHandler {
              cursorShape: Qt.PointingHandCursor
              onHoveredChanged: if (hovered) applicationList.currentIndex = applicationRow.index
            }

            TapHandler {
              onTapped: {
                applicationList.currentIndex = applicationRow.index
                root.selectCurrent()
              }
            }
          }

          Text {
            anchors.centerIn: parent
            visible: applicationList.count === 0
            text: "No matching applications"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }
      }
    }
  }
}

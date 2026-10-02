pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "melon.lights"

  // ---- backend ----
  readonly property string helperPath:
    (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/" + moduleName + "/dirigera.py"

  // ---- state ----
  property var lights: []
  property string selectedRoom: ""
  property bool popupOpen: false
  property bool loading: false
  property string lastError: ""
  property bool _dragging: false

  // Mirrors popupOpen so the bar can route summon/hide (findPanelWidget needs a
  // defined `opened` in addition to open()/close()).
  readonly property bool opened: popupOpen

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color barFg: bar ? bar.barForeground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int onCount: {
    var n = 0
    for (var i = 0; i < lights.length; i++)
      if (lights[i].isOn) n++
    return n
  }

  readonly property var rooms: {
    var seen = {}
    var list = []
    for (var i = 0; i < lights.length; i++) {
      var r = lights[i].room || "Inne"
      if (!seen[r]) { seen[r] = true; list.push(r) }
    }
    return list
  }

  readonly property var filteredLights: {
    var list = []
    for (var i = 0; i < lights.length; i++) {
      var r = lights[i].room || "Inne"
      if (r === selectedRoom) list.push(lights[i])
    }
    return list
  }

  onRoomsChanged: {
    if (selectedRoom === "" || rooms.indexOf(selectedRoom) < 0)
      selectedRoom = rooms.length > 0 ? rooms[0] : ""
  }

  readonly property bool roomAnyOn: {
    var list = filteredLights
    for (var i = 0; i < list.length; i++)
      if (list[i].isOn) return true
    return false
  }

  readonly property bool roomCanLevel: {
    var list = filteredLights
    for (var i = 0; i < list.length; i++)
      if (list[i].canLevel) return true
    return false
  }

  readonly property bool roomCanTemp: {
    var list = filteredLights
    for (var i = 0; i < list.length; i++)
      if (list[i].canTemp) return true
    return false
  }

  readonly property bool roomCanColor: {
    var list = filteredLights
    for (var i = 0; i < list.length; i++)
      if (list[i].canColor) return true
    return false
  }

  readonly property int roomLevel: {
    var list = filteredLights
    var sum = 0, n = 0
    for (var i = 0; i < list.length; i++)
      if (list[i].level != null) { sum += list[i].level; n++ }
    return n > 0 ? Math.round(sum / n) : 50
  }

  readonly property int roomTemp: {
    var list = filteredLights
    var sum = 0, n = 0
    for (var i = 0; i < list.length; i++)
      if (list[i].ct != null) { sum += list[i].ct; n++ }
    return n > 0 ? Math.round(sum / n) : 2700
  }

  readonly property int roomTempMin: {
    var list = filteredLights
    var lo = 2200
    for (var i = 0; i < list.length; i++)
      if (list[i].ctMin != null && list[i].ctMin < lo) lo = list[i].ctMin
    return lo
  }

  readonly property int roomTempMax: {
    var list = filteredLights
    var hi = 4000
    for (var i = 0; i < list.length; i++)
      if (list[i].ctMax != null && list[i].ctMax > hi) hi = list[i].ctMax
    return hi
  }

  readonly property int roomHue: {
    var list = filteredLights
    var sum = 0, n = 0
    for (var i = 0; i < list.length; i++)
      if (list[i].hue != null) { sum += list[i].hue; n++ }
    return n > 0 ? Math.round(sum / n) : 0
  }

  // ---- header / card aggregates ----
  readonly property int activeRooms: {
    var n = 0
    for (var i = 0; i < rooms.length; i++)
      if (roomOnCount(rooms[i]) > 0) n++
    return n
  }

  readonly property int avgOnLevel: {
    var sum = 0, n = 0
    for (var i = 0; i < lights.length; i++)
      if (lights[i].isOn && lights[i].level != null) { sum += lights[i].level; n++ }
    return n > 0 ? Math.round(sum / n) : 0
  }

  function roomOnCount(room) {
    var n = 0
    for (var i = 0; i < lights.length; i++)
      if ((lights[i].room || "Inne") === room && lights[i].isOn) n++
    return n
  }

  function roomCount(room) {
    var n = 0
    for (var i = 0; i < lights.length; i++)
      if ((lights[i].room || "Inne") === room) n++
    return n
  }

  function roomAvgLevel(room) {
    var sum = 0, n = 0
    for (var i = 0; i < lights.length; i++)
      if ((lights[i].room || "Inne") === room && lights[i].level != null) { sum += lights[i].level; n++ }
    return n > 0 ? Math.round(sum / n) : 0
  }

  // ---- helpers ----
  function optimistic(id, patch) {
    var next = []
    for (var i = 0; i < lights.length; i++) {
      var l = lights[i]
      if (l.id !== id) { next.push(l); continue }
      var copy = {}
      for (var k in l) copy[k] = l[k]
      for (var k2 in patch) copy[k2] = patch[k2]
      next.push(copy)
    }
    lights = next
  }

  function fireSet(id, attrs) {
    Quickshell.execDetached(["python3", "-B", helperPath, "set", id, JSON.stringify(attrs)])
  }

  function allOff() {
    for (var i = 0; i < lights.length; i++)
      if (lights[i].isOn) fireSet(lights[i].id, { "isOn": false })
    var next = []
    for (var j = 0; j < lights.length; j++) {
      var l = lights[j]
      var copy = {}
      for (var k in l) copy[k] = l[k]
      copy.isOn = false
      next.push(copy)
    }
    lights = next
  }

  function setRoomOn(on) {
    var list = filteredLights
    for (var i = 0; i < list.length; i++) {
      fireSet(list[i].id, { "isOn": on })
      optimistic(list[i].id, { "isOn": on })
    }
  }

  function setRoomLevel(v) {
    var lvl = Math.round(v)
    var list = filteredLights
    for (var i = 0; i < list.length; i++) {
      if (!list[i].canLevel) continue
      var attrs = { "lightLevel": lvl }
      if (!list[i].isOn) attrs.isOn = true
      fireSet(list[i].id, attrs)
      optimistic(list[i].id, { "level": lvl, "isOn": true })
    }
  }

  function setRoomTemp(v) {
    var t = Math.round(v)
    var list = filteredLights
    for (var i = 0; i < list.length; i++) {
      if (!list[i].canTemp) continue
      var attrs = { "colorTemperature": t }
      if (!list[i].isOn) attrs.isOn = true
      fireSet(list[i].id, attrs)
      optimistic(list[i].id, { "ct": t, "isOn": true })
    }
  }

  function setRoomHue(v) {
    var h = Math.round(v)
    var list = filteredLights
    for (var i = 0; i < list.length; i++) {
      if (!list[i].canColor) continue
      var attrs = { "colorHue": h, "colorSaturation": 0.85 }
      if (!list[i].isOn) attrs.isOn = true
      fireSet(list[i].id, attrs)
      optimistic(list[i].id, { "hue": h, "sat": 0.85, "isOn": true })
    }
  }

  function roomLights(room) {
    var list = []
    for (var i = 0; i < lights.length; i++)
      if ((lights[i].room || "Inne") === room) list.push(lights[i])
    return list
  }

  function setRoomOnFor(room, on) {
    var list = roomLights(room)
    for (var i = 0; i < list.length; i++) {
      fireSet(list[i].id, { "isOn": on })
      optimistic(list[i].id, { "isOn": on })
    }
  }

  function setAll(on) {
    for (var i = 0; i < lights.length; i++) {
      fireSet(lights[i].id, { "isOn": on })
      optimistic(lights[i].id, { "isOn": on })
    }
  }

  function refresh() {
    if (fetchProc.running) return
    loading = true
    fetchProc.command = ["python3", "-B", helperPath, "devices"]
    fetchProc.running = true
  }

  function applyDevices(raw) {
    loading = false
    if (root._dragging) return
    var parsed
    try { parsed = JSON.parse(raw) }
    catch (e) { lastError = "Error parsing hub response"; return }
    if (!Array.isArray(parsed)) {
      lastError = (parsed && parsed.error) ? parsed.error : "Invalid hub response"
      return
    }
    lastError = ""
    lights = parsed
  }

  // PopupCard.close() (outside-click / focus-grab dismiss) calls `owner.close()`.
  // Setting our own `popupOpen` (not the PopupCard's `open`) keeps the
  // `open: root.popupOpen` binding intact so the popup can reopen.
  function open() { popupOpen = true }
  function close() { popupOpen = false }
  function toggle() { popupOpen = !popupOpen }

  onPopupOpenChanged: if (popupOpen) refresh()

  Component.onCompleted: refresh()

  // ---- processes ----
  Process {
    id: fetchProc
    running: false
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyDevices(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text).trim()
        if (t) root.lastError = t
      }
    }
    onExited: function(code) {
      root.loading = false
      if (code !== 0 && root.lastError === "")
        root.lastError = "Could not read lights"
    }
  }

  // Fast refresh while the popup is open, slow otherwise (keeps the count fresh).
  Timer {
    id: refreshTimer
    interval: root.popupOpen ? 5000 : 60000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  // ---- bar presentation ----
  // Vertical bar (bar.vertical, e.g. Omacale's left bar): icon only, the count
  // is hidden -- an icon+count row is wider than the pill and pushed the icons
  // off the bar's axis. Horizontal bars (melon.bar) keep the count.
  readonly property bool barVertical: root.vertical
  implicitWidth: barVertical ? barSize : row.implicitWidth + Style.space(14)
  implicitHeight: barSize

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      textFormat: Text.PlainText
      text: root.onCount > 0 ? "󰛩" : "󰛨"
      color: root.onCount > 0 ? root.barFg : Qt.darker(root.barFg, 1.7)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      anchors.verticalCenter: parent.verticalCenter
      Behavior on color { ColorAnimation { duration: 160 } }
    }

    Text {
      textFormat: Text.PlainText
      text: String(root.onCount)
      visible: root.onCount > 0 && !root.barVertical
      color: Qt.darker(root.barFg, 1.2)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    onClicked: function(mouse) {
      if (mouse.button === Qt.LeftButton) root.popupOpen = !root.popupOpen
      else if (mouse.button === Qt.RightButton) root.allOff()
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, "IKEA lights (Dirigera)")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  // ---- popup ----
  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(360))
    contentHeight: popup.fittedContentHeight(contentColumn.implicitHeight, Style.space(600))

    ScrollView {
      id: scrollArea
      anchors.fill: parent
      clip: true
      ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
      ScrollBar.vertical.policy: contentColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

      Column {
        id: contentColumn
        width: scrollArea.availableWidth
        spacing: Style.space(10)

        // ---- hero header ----
        PanelHero {
          width: parent.width
          foreground: root.fg
          fontFamily: root.fontFamily
          title: "Lights"
          meta: root.loading ? "Refreshing"
              : root.lastError ? "Read error"
              : (root.lights.length + " lights · " + root.onCount + " on")
          iconComponent: LightIcon
          trailingControl: RefreshButton
        }

        // ---- stat cards ----
        Row {
          width: parent.width
          spacing: Style.space(8)

          StatCard {
            width: (parent.width - Style.space(8) * 2) / 3
            label: "ON"
            value: String(root.onCount)
            caption: "of " + root.lights.length
            fraction: root.lights.length > 0 ? root.onCount / root.lights.length : 0
            toggleVisible: true
            toggleOn: root.onCount > 0
            onToggleClicked: root.setAll(root.onCount === 0)
          }

          StatCard {
            width: (parent.width - Style.space(8) * 2) / 3
            label: "ROOMS"
            value: String(root.activeRooms)
            caption: "of " + root.rooms.length
            fraction: root.rooms.length > 0 ? root.activeRooms / root.rooms.length : 0
          }

          StatCard {
            width: (parent.width - Style.space(8) * 2) / 3
            label: "BRIGHTNESS"
            value: root.avgOnLevel + "%"
            caption: "average"
            fraction: root.avgOnLevel / 100
          }
        }

        PanelSeparator { foreground: root.fg }

        // ---- rooms: picker pills + selected-room controls ----
        Item {
          width: parent.width
          height: Math.max(roomsHeader.implicitHeight, roomsCount.implicitHeight)

          PanelSectionHeader {
            id: roomsHeader
            text: "ROOMS"
            foreground: root.fg
            fontFamily: root.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: roomsCount
            textFormat: Text.PlainText
            text: root.activeRooms + " on"
            color: Qt.darker(root.fg, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // room picker pills (selected = highlighted, on-rooms show a dot)
        Flow {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.rooms

            Button {
              required property var modelData
              text: modelData + (root.roomOnCount(modelData) > 0 ? " 󰛩" : "")
              selected: root.selectedRoom === modelData
              foreground: root.fg
              onClicked: root.selectedRoom = modelData
            }
          }
        }

        // selected-room control card
        BorderSurface {
          id: roomDetail
          width: parent.width
          visible: root.filteredLights.length > 0
          color: Util.alpha(root.fg, 0.04)
          borderSpec: Border.controlSpec("normal", root.fg, Color.accent)
          radius: Style.cornerRadius
          padding: Style.space(6)
          implicitHeight: roomDetailCol.implicitHeight + roomDetail.contentTopInset + roomDetail.contentBottomInset

          Column {
            id: roomDetailCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: roomDetail.contentLeftInset
            anchors.rightMargin: roomDetail.contentRightInset
            anchors.topMargin: roomDetail.contentTopInset
            spacing: Style.space(6)

            // header: room name + on/off toggle
            Item {
              width: parent.width
              height: Math.max(dName.implicitHeight, dToggle.implicitHeight)

              Column {
                id: dNameCol
                anchors.left: parent.left
                anchors.right: dToggle.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(1)

                Text {
                  id: dName
                  textFormat: Text.PlainText
                  text: (root.selectedRoom || "Room").toUpperCase()
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.filteredLights.length + " lights · " + root.roomOnCount(root.selectedRoom) + " on"
                  color: Qt.darker(root.fg, 1.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  elide: Text.ElideRight
                }
              }

              ToggleSwitch {
                id: dToggle
                checked: root.roomAnyOn
                foreground: root.fg
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                onToggled: root.setRoomOn(!root.roomAnyOn)
              }
            }

            // BRIGHTNESS
            Item {
              width: parent.width
              height: Math.max(dLevelHdr.implicitHeight, dLevelVal.implicitHeight)

              PanelSectionHeader {
                id: dLevelHdr
                text: "BRIGHTNESS"
                foreground: root.fg
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: dLevelVal
                textFormat: Text.PlainText
                text: (dLevel.dragging ? Math.round(dLevel.liveValue) : root.roomLevel) + "%"
                color: Qt.darker(root.fg, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Item {
              width: parent.width
              height: dLevel.implicitHeight

              Text {
                id: dimSun
                textFormat: Text.PlainText
                text: "☼"
                color: Qt.darker(root.fg, 1.7)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                visible: root.roomCanLevel
              }

              PanelSlider {
                id: dLevel
                bar: root.bar
                minimum: 1
                maximum: 100
                integer: true
                step: 1
                value: root.roomLevel
                visible: root.roomCanLevel
                opacity: root.roomAnyOn ? 1.0 : 0.55
                anchors.left: dimSun.right
                anchors.leftMargin: Style.space(6)
                anchors.right: brightSun.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                onMoved: root._dragging = true
                onReleased: function(v) { root._dragging = false; root.setRoomLevel(v) }
              }

              Text {
                id: brightSun
                textFormat: Text.PlainText
                text: "☀"
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.roomCanLevel
              }
            }

            // COLOR TEMPERATURE
            Item {
              width: parent.width
              visible: root.roomCanTemp
              height: Math.max(dTempHdr.implicitHeight, dTempVal.implicitHeight)

              PanelSectionHeader {
                id: dTempHdr
                text: "COLOR TEMPERATURE"
                foreground: root.fg
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: dTempVal
                textFormat: Text.PlainText
                text: Math.round(dTemp.dragging ? dTemp.liveValue : dTemp.value) + " K"
                color: Qt.darker(root.fg, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            PanelSlider {
              id: dTemp
              bar: root.bar
              width: parent.width
              minimum: root.roomTempMin
              maximum: root.roomTempMax
              integer: true
              step: 50
              value: root.roomTemp
              visible: root.roomCanTemp
              opacity: root.roomAnyOn ? 1.0 : 0.55
              onMoved: root._dragging = true
              onReleased: function(v) { root._dragging = false; root.setRoomTemp(v) }
            }

            // COLOR
            Item {
              width: parent.width
              visible: root.roomCanColor
              height: Math.max(dHueHdr.implicitHeight, dHueVal.implicitHeight)

              PanelSectionHeader {
                id: dHueHdr
                text: "COLOR"
                foreground: root.fg
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: dHueVal
                textFormat: Text.PlainText
                text: Math.round(dHue.dragging ? dHue.liveValue : dHue.value) + "°"
                color: Qt.darker(root.fg, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            PanelSlider {
              id: dHue
              bar: root.bar
              width: parent.width
              minimum: 0
              maximum: 360
              integer: true
              step: 1
              value: root.roomHue
              visible: root.roomCanColor
              opacity: root.roomAnyOn ? 1.0 : 0.55
              onMoved: root._dragging = true
              onReleased: function(v) { root._dragging = false; root.setRoomHue(v) }
            }
          }
        }

      }
    }
  }

  // ---- reusable inline components ----

  component LightIcon: Text {
    textFormat: Text.PlainText
    text: root.onCount > 0 ? "󰛩" : "󰛨"
    color: root.onCount > 0 ? root.fg : Qt.darker(root.fg, 1.4)
    font.family: root.fontFamily
    font.pixelSize: Style.font.display
    anchors.verticalCenter: parent.verticalCenter
  }

  component RefreshButton: Button {
    iconText: "󰑖"
    foreground: root.fg
    onClicked: root.refresh()
  }

  component MiniBar: Item {
    id: mbar
    property real fraction: 0
    implicitHeight: Style.space(4)
    height: Style.space(4)

    Rectangle {
      anchors.fill: parent
      radius: height / 2
      color: Util.alpha(root.fg, 0.18)
    }

    Rectangle {
      height: parent.height
      width: parent.width * Math.max(0, Math.min(1, mbar.fraction))
      radius: height / 2
      color: Color.accent
      Behavior on width { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    }
  }

  component StatCard: BorderSurface {
    id: card
    property string label: ""
    property string value: ""
    property string caption: ""
    property real fraction: 0
    property bool toggleVisible: false
    property bool toggleOn: false
    signal toggleClicked()

    color: Util.alpha(root.fg, 0.04)
    borderSpec: Border.controlSpec("normal", root.fg, Color.accent)
    radius: Style.cornerRadius
    padding: Style.space(6)

    implicitHeight: statCol.implicitHeight + card.contentTopInset + card.contentBottomInset

    Column {
      id: statCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: card.contentLeftInset
      anchors.rightMargin: card.contentRightInset
      anchors.topMargin: card.contentTopInset
      spacing: Style.space(3)

      Text {
        textFormat: Text.PlainText
        text: card.label
        color: Qt.darker(root.fg, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.2
        width: parent.width
      }

      // value + optional master toggle in the empty space to its right
      Item {
        width: parent.width
        height: valueText.implicitHeight

        Text {
          id: valueText
          textFormat: Text.PlainText
          text: card.value
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.display
          font.bold: true
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
        }

        Button {
          id: toggleBtn
          visible: card.toggleVisible
          iconText: card.toggleOn ? "󰛩" : "󰛨"
          iconSize: Style.font.bodySmall
          foreground: card.toggleOn ? Color.accent : Qt.darker(root.fg, 1.7)
          horizontalPadding: Style.space(2)
          verticalPadding: Style.space(2)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          onClicked: card.toggleClicked()
        }
      }

      Text {
        textFormat: Text.PlainText
        text: card.caption
        color: Qt.darker(root.fg, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        width: parent.width
        elide: Text.ElideRight
      }

      MiniBar {
        width: parent.width
        fraction: card.fraction
      }
    }
  }


}

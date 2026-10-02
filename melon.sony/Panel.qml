pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Sony WF-1000XM5 (i inne sluchawki Sony mowiace MDR v2) w pasku Omarchy.
//
// Panel nie rozmawia po Bluetooth sam - sesje kontrolna trzyma sony-helper.py,
// bo sluchawki daja tylko jedna i kosztuje ona kilka sekund handshake'u.
// Helper pisze stan jako linie JSON na stdout, a komendy czyta ze stdin.
BarWidget {
  id: root
  moduleName: "melon.sony"

  // ---- backend ----
  readonly property string helperPath:
    (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/" + moduleName + "/sony-helper.py"
  // Adres opcjonalny: bez niego helper sam znajduje sluchawki po usludze MDR.
  property string mac: ""

  // ---- stan z helpera ----
  property var st: null
  property string lastError: ""
  property bool popupOpen: false
  property bool eqOpen: false
  property real lastUpdate: 0

  readonly property var empty: ({})
  readonly property var s: st === null ? empty : st
  readonly property var buds: s.buds !== undefined ? s.buds : empty
  readonly property var anc: s.anc !== undefined ? s.anc : empty
  readonly property var eq: s.eq !== undefined ? s.eq : empty
  readonly property var audio: s.audio !== undefined ? s.audio : empty
  readonly property var features: s.features !== undefined ? s.features : empty

  readonly property string link: s.link !== undefined ? s.link : "idle"
  readonly property bool released: s.released === true
  readonly property bool online: link === "ready"
  readonly property bool connected: s.connected === true
  readonly property string deviceName: s.name !== undefined ? s.name : "Sony"
  readonly property string reason: s.reason !== undefined ? s.reason : ""

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color barFg: bar ? bar.barForeground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- bateria ----
  readonly property bool hasBuds: buds.left !== null && buds.left !== undefined
  readonly property int levelLeft: (buds.left === null || buds.left === undefined) ? -1 : buds.left
  readonly property int levelRight: (buds.right === null || buds.right === undefined) ? -1 : buds.right
  readonly property int levelCase: (buds.case === null || buds.case === undefined) ? -1 : buds.case
  readonly property int bluezLevel: (s.bluez_battery === null || s.bluez_battery === undefined) ? -1 : s.bluez_battery
  // w pasku pokazujemy slabsza ze sluchawek - to ona skonczy sluchanie
  readonly property int barLevel: {
    if (levelLeft >= 0 && levelRight >= 0) return Math.min(levelLeft, levelRight)
    if (levelLeft >= 0) return levelLeft
    if (levelRight >= 0) return levelRight
    return bluezLevel
  }
  readonly property string barLevelText: barLevel < 0 ? "—" : barLevel + "%"
  readonly property bool charging: buds.left_charging === true || buds.right_charging === true

  // ---- ANC ----
  readonly property string ancMode: anc.mode !== undefined ? anc.mode : "unknown"
  readonly property int ancLevel: anc.level !== undefined ? anc.level : 10
  readonly property bool ancFocus: anc.focus === true
  readonly property string ancLabel: ancMode === "anc" ? "ANC"
    : ancMode === "ambient" ? "Ambient" : ancMode === "wind" ? "Wiatr"
    : ancMode === "off" ? "Wyłączona" : "—"
  readonly property string ancIcon: ancMode === "anc" ? "󰝟"
    : ancMode === "ambient" ? "󰕾" : ancMode === "off" ? "󰋋" : "󰋋"

  // ---- dzwiek ----
  readonly property bool dseeOn: s.dsee === true
  readonly property bool stcOn: s.stc === true
  readonly property bool autoPauseOn: s.auto_pause === true
  readonly property string autoOff: s.auto_off !== undefined && s.auto_off !== null ? s.auto_off : ""
  readonly property string eqPreset: eq.preset !== undefined ? eq.preset : "off"
  readonly property var eqBands: eq.bands !== undefined && eq.bands !== null ? eq.bands : [0, 0, 0, 0, 0, 0]
  readonly property var eqLabels: ["CLEAR BASS", "400 Hz", "1 kHz", "2,5 kHz", "6,3 kHz", "16 kHz"]

  // ---- jakosc lacza ----
  readonly property string codec: audio.codec !== undefined ? String(audio.codec) : ""
  readonly property string profile: audio.profile !== undefined ? String(audio.profile) : ""
  readonly property string ldacQuality: audio.ldac !== undefined ? String(audio.ldac) : ""
  readonly property string codecLabel: {
    var c = codec.toUpperCase()
    if (c === "LDAC") {
      var q = ldacQuality === "hq" ? "990 kbps" : ldacQuality === "sq" ? "660 kbps"
            : ldacQuality === "mq" ? "330 kbps" : ldacQuality === "auto" ? "auto" : ""
      return q === "" ? "LDAC" : "LDAC · " + q
    }
    if (c === "AAC") return "AAC"
    if (c === "SBC_XQ") return "SBC-XQ"
    if (c === "SBC") return "SBC"
    return c === "" ? "—" : c
  }
  readonly property bool micProfile: profile.indexOf("headset") === 0
  readonly property string profileLabel: micProfile ? "Mikrofon (HFP)" : "Jakość (A2DP)"
  readonly property string qualityHint: micProfile
    ? "Profil mikrofonowy obniża jakość do rozmowy."
    : (codec.toUpperCase() === "LDAC" ? "Maksymalna jakość: LDAC."
       : "LDAC wejdzie, gdy słuchawki są w trybie priorytetu jakości.")

  readonly property string ageText: lastUpdate === 0 ? ""
    : Math.max(1, Math.round((Date.now() - lastUpdate) / 1000)) + " s temu"

  // ---- mostek do helpera ----
  Process {
    id: helper
    command: root.mac !== ""
      ? ["/usr/bin/python3", "-B", root.helperPath, "serve", "--mac", root.mac]
      : ["/usr/bin/python3", "-B", root.helperPath, "serve"]
    running: true
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.onHelperLine(line) }
    }
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        var t = String(line).trim()
        if (t) console.warn("melon.sony: " + t)
      }
    }
    // Helper trzyma jedyna sesje kontrolna - gdy padnie, sam sie nie wskrzesi.
    onExited: function(exitCode, exitStatus) {
      console.warn("melon.sony: helper exited (" + exitCode + "), restart")
      helperRestart.restart()
    }
  }

  Timer {
    id: helperRestart
    interval: 1500
    onTriggered: helper.running = true
  }

  /** Linia JSON z helpera: stan, zmiana lacza albo blad. */
  function onHelperLine(line) {
    var text = String(line).trim()
    if (text === "") return
    var msg
    try {
      msg = JSON.parse(text)
    } catch (e) {
      console.warn("melon.sony: nie JSON: " + text)
      return
    }
    if (msg.type === "state") {
      root.st = msg
      root.lastUpdate = Date.now()
      root.lastError = ""
    } else if (msg.type === "error") {
      root.lastError = (msg.where ? msg.where + ": " : "") + (msg.message || "błąd")
    }
  }

  function send(obj) {
    if (!helper.running) return
    helper.write(JSON.stringify(obj) + "\n")
  }

  function setAnc(mode) { send({ "cmd": "anc", "value": mode }) }
  function setAncLevel(level) { send({ "cmd": "anc-level", "value": Math.round(level) }) }
  function setAncFocus(on) { send({ "cmd": "anc-focus", "value": on }) }
  function setDsee(on) { send({ "cmd": "dsee", "value": on }) }
  function setStc(on) { send({ "cmd": "stc", "value": on }) }
  function setAutoPause(on) { send({ "cmd": "auto-pause", "value": on }) }
  function setAutoOff(value) { send({ "cmd": "auto-off", "value": value }) }
  function setEqPreset(preset) { send({ "cmd": "eq", "preset": preset }) }
  function setEqBand(index, value) {
    var bands = []
    for (var i = 0; i < 6; i++) bands.push(i === index ? Math.round(value) : Number(root.eqBands[i] || 0))
    send({ "cmd": "eq", "preset": "manual", "bands": bands })
  }
  function setEqFlat() { send({ "cmd": "eq", "preset": "off", "bands": [0, 0, 0, 0, 0, 0] }) }
  function setProfile(kind) { send({ "cmd": "audio-profile", "value": kind }) }
  function powerOff() { send({ "cmd": "power-off" }) }
  function releaseSession() { send({ "cmd": "release" }) }
  function claimSession() { send({ "cmd": "claim" }) }
  function refresh() { send({ "cmd": "refresh" }) }

  readonly property string cycleOrder: "anc,ambient,off"
  function cycleAnc() {
    var order = ["anc", "ambient", "off"]
    var next = order[(order.indexOf(root.ancMode) + 1) % order.length]
    setAnc(next)
  }

  // ---- chip w pasku ----
  // Pionowy pasek (bar.vertical, np. Omacale po lewej): zostaje sam poziom
  // baterii, bez ikony słuchawek — ikona + poziom + bolt błyskawicy to rząd
  // szerszy niż pigułka i chip wychodził z osi. W poziomym pasku bez zmian.
  readonly property bool barVertical: root.vertical
  implicitWidth: barVertical ? barSize : barRow.implicitWidth + Style.space(14)
  implicitHeight: barSize

  Row {
    id: barRow
    anchors.centerIn: parent
    spacing: Style.space(4)

    Text {
      textFormat: Text.PlainText
      text: "󰋋"
      visible: !root.barVertical
      color: root.online ? Color.accent : Qt.darker(root.barFg, 1.7)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      textFormat: Text.PlainText
      text: root.barLevelText
      color: root.connected ? Qt.darker(root.barFg, 1.15) : Qt.darker(root.barFg, 1.8)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      visible: root.charging && !root.barVertical
      textFormat: Text.PlainText
      text: "󰂚"
      color: Color.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: function(mouse) {
      if (mouse.button === Qt.LeftButton) root.popupOpen = !root.popupOpen
      else root.cycleAnc()
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.tooltipText())
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  function tooltipText() {
    var parts = [root.deviceName]
    if (root.online) {
      parts.push(root.ancLabel)
      if (root.ancMode === "ambient") parts.push("poziom " + root.ancLevel)
    } else if (root.connected) {
      parts.push(root.link === "error" ? "brak sesji kontrolnej" : "łączę…")
    } else {
      parts.push("rozłączone")
    }
    if (root.codecLabel !== "—") parts.push(root.codecLabel)
    parts.push("PPM: cykl ANC")
    return parts.filter(function(p) { return p !== "" }).join(" · ")
  }

  // ---- panel ----
  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(390))
    contentHeight: popup.fittedContentHeight(contentColumn.implicitHeight, Style.space(660))

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

        PanelHero {
          width: parent.width
          foreground: root.fg
          fontFamily: root.fontFamily
          title: root.deviceName
          meta: {
            if (!root.connected) return "Rozłączone"
            if (root.released) return "Sesja u telefonu"
            if (root.link === "ready") return root.ancLabel + (root.ancMode === "ambient" ? " · poziom " + root.ancLevel : "")
            if (root.link === "error") return "Brak sesji kontrolnej"
            return "Łączę z słuchawkami…"
          }
          detail: root.lastError !== "" ? root.lastError
            : (root.link === "error" && root.reason !== "" ? root.reason : root.ageText)
          iconComponent: HeadphonesIcon
          trailingControl: RefreshButton
        }

        // ---- bateria ----
        Row {
          width: parent.width
          spacing: Style.space(8)

          StatCard {
            width: root.levelCase >= 0 ? (parent.width - Style.space(16)) / 3 : (parent.width - Style.space(8)) / 2
            label: "LEWY"
            value: root.levelLeft < 0 ? "—" : root.levelLeft + "%"
            caption: root.buds.left_charging === true ? "ładuje się" : "słuchawka"
            fraction: root.levelLeft < 0 ? 0 : root.levelLeft / 100
          }

          StatCard {
            width: root.levelCase >= 0 ? (parent.width - Style.space(16)) / 3 : (parent.width - Style.space(8)) / 2
            label: "PRAWY"
            value: root.levelRight < 0 ? "—" : root.levelRight + "%"
            caption: root.buds.right_charging === true ? "ładuje się" : "słuchawka"
            fraction: root.levelRight < 0 ? 0 : root.levelRight / 100
          }

          StatCard {
            visible: root.levelCase >= 0
            width: (parent.width - Style.space(16)) / 3
            label: "ETUI"
            value: root.levelCase < 0 ? "—" : root.levelCase + "%"
            caption: root.buds.case_charging === true ? "ładuje się" : "etui"
            fraction: root.levelCase < 0 ? 0 : root.levelCase / 100
          }
        }

        PanelSeparator { foreground: root.fg }

        // ---- halas ----
        Item {
          width: parent.width
          height: Math.max(noiseHeader.implicitHeight, noiseState.implicitHeight)

          PanelSectionHeader {
            id: noiseHeader
            text: "HAŁAS"
            foreground: root.fg
            fontFamily: root.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: noiseState
            textFormat: Text.PlainText
            text: root.online ? root.ancLabel : "wymaga sesji"
            color: root.online ? Qt.darker(root.fg, 1.4) : Qt.darker(root.fg, 1.8)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: root.online
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        ButtonGroup {
          width: parent.width
          foreground: root.fg
          value: root.ancMode === "wind" ? "ambient" : root.ancMode
          options: [
            { "value": "anc", "label": "ANC" },
            { "value": "ambient", "label": "Ambient" },
            { "value": "off", "label": "Wyłącz" }
          ]
          onChanged: function(v) { root.setAnc(v) }
        }

        Item {
          width: parent.width
          implicitHeight: ambientCol.implicitHeight
          visible: root.ancMode === "ambient" || root.ancMode === "wind"

          Column {
            id: ambientCol
            width: parent.width
            spacing: Style.space(4)

            Item {
              width: parent.width
              height: Math.max(ambientLabel.implicitHeight, ambientValue.implicitHeight)

              Text {
                id: ambientLabel
                textFormat: Text.PlainText
                text: "Poziom dźwięku z otoczenia"
                color: Qt.darker(root.fg, 1.35)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: ambientValue
                textFormat: Text.PlainText
                text: String(root.ancLevel) + " / 20"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            PanelSlider {
              bar: root.bar
              width: parent.width
              minimum: 1
              maximum: 20
              integer: true
              step: 1
              value: root.ancLevel
              onReleased: function(v) { root.setAncLevel(v) }
            }
          }
        }

        Toggle {
          width: parent.width
          foreground: root.fg
          fontFamily: root.fontFamily
          label: "Skoncentruj na głosie"
          description: "W trybie Ambient wycisza rozmówcę na wprost"
          checked: root.ancFocus
          onClicked: root.setAncFocus(!root.ancFocus)
        }

        PanelSeparator { foreground: root.fg }

        // ---- dzwiek ----
        SectionLabel { text: "DŹWIĘK" }

        Toggle {
          width: parent.width
          foreground: root.fg
          fontFamily: root.fontFamily
          label: "DSEE Extreme"
          description: "Odtwarzanie stratnych plików w wyższej jakości"
          checked: root.dseeOn
          onClicked: root.setDsee(!root.dseeOn)
        }

        Toggle {
          width: parent.width
          foreground: root.fg
          fontFamily: root.fontFamily
          label: "Rozmowa bez zdejmowania (Speak-to-Chat)"
          description: "Gdy mówisz, słuchawki wstrzymują muzykę i wpuszczają otoczenie"
          checked: root.stcOn
          onClicked: root.setStc(!root.stcOn)
        }

        Item {
          width: parent.width
          height: Math.max(eqHeader.implicitHeight, eqToggle.implicitHeight)

          PanelSectionHeader {
            id: eqHeader
            text: "KOREKTOR"
            foreground: root.fg
            fontFamily: root.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              text: root.eqPreset === "manual" ? "własny" : root.eqPreset
              color: Qt.darker(root.fg, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }

            Button {
              id: eqToggle
              iconText: root.eqOpen ? "󰅀" : "󰅂"
              tooltipText: root.eqOpen ? "Zwiń korektor" : "Rozwiń korektor"
              foreground: root.fg
              onClicked: root.eqOpen = !root.eqOpen
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: root.eqOpen

          Repeater {
            model: 6

            delegate: Item {
              id: bandRow
              required property int index
              width: contentColumn.width
              height: bandColumn.implicitHeight

              Column {
                id: bandColumn
                width: parent.width
                spacing: Style.space(2)

                Item {
                  width: parent.width
                  height: Math.max(bandName.implicitHeight, bandValue.implicitHeight)

                  Text {
                    id: bandName
                    textFormat: Text.PlainText
                    text: root.eqLabels[bandRow.index]
                    color: Qt.darker(root.fg, 1.35)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    id: bandValue
                    textFormat: Text.PlainText
                    text: {
                      var v = Number(root.eqBands[bandRow.index] || 0)
                      return (v > 0 ? "+" : "") + String(v)
                    }
                    color: Number(root.eqBands[bandRow.index] || 0) === 0 ? Qt.darker(root.fg, 1.6) : root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: Number(root.eqBands[bandRow.index] || 0) !== 0
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                PanelSlider {
                  bar: root.bar
                  width: parent.width
                  minimum: -10
                  maximum: 10
                  integer: true
                  step: 1
                  value: Number(root.eqBands[bandRow.index] || 0)
                  onReleased: function(v) { root.setEqBand(bandRow.index, v) }
                }
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            Button {
              text: "Płasko"
              foreground: root.fg
              onClicked: root.setEqFlat()
            }

            Button {
              text: "Bass"
              foreground: root.fg
              selected: root.eqPreset === "bass"
              onClicked: root.setEqPreset("bass")
            }

            Button {
              text: "Speech"
              foreground: root.fg
              selected: root.eqPreset === "speech"
              onClicked: root.setEqPreset("speech")
            }

            Button {
              text: "Treble"
              foreground: root.fg
              selected: root.eqPreset === "treble"
              onClicked: root.setEqPreset("treble")
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "Presety XM5 przyjmuje, ale zwykle ich nie zapisuje — pewne są suwaki (zapisują się jako własny)."
            color: Qt.darker(root.fg, 1.7)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        PanelSeparator { foreground: root.fg }

        // ---- zasilanie ----
        SectionLabel { text: "ZASILANIE" }

        Toggle {
          width: parent.width
          foreground: root.fg
          fontFamily: root.fontFamily
          label: "Pauza po zdjęciu"
          description: "Muzyka wstrzymuje się, gdy wyjmiesz słuchawki z uszu"
          checked: root.autoPauseOn
          onClicked: root.setAutoPause(!root.autoPauseOn)
        }

        Item {
          width: parent.width
          height: Math.max(autoOffHeader.implicitHeight, autoOffValue.implicitHeight)

          PanelSectionHeader {
            id: autoOffHeader
            text: "WYŁĄCZANIE"
            foreground: root.fg
            fontFamily: root.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: autoOffValue
            textFormat: Text.PlainText
            text: {
              var v = root.autoOff
              if (v === "removed") return "po zdjęciu"
              if (v === "off") return "nigdy"
              if (v === "") return "—"
              return v + " min"
            }
            color: Qt.darker(root.fg, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Flow {
          width: parent.width
          spacing: Style.space(5)

          Repeater {
            model: [
              { "value": "removed", "label": "po zdjęciu" },
              { "value": "5", "label": "5 min" },
              { "value": "15", "label": "15 min" },
              { "value": "30", "label": "30 min" },
              { "value": "60", "label": "60 min" },
              { "value": "180", "label": "3 h" },
              { "value": "off", "label": "nigdy" }
            ]

            delegate: Button {
              required property var modelData
              text: modelData.label
              foreground: root.fg
              selected: root.autoOff === modelData.value
              onClicked: root.setAutoOff(modelData.value)
            }
          }
        }

        PanelSeparator { foreground: root.fg }

        // ---- sesja kontrolna ----
        // Sluchawki daja jedna sesje MDR: albo my, albo aplikacja Sony w telefonie.
        Toggle {
          width: parent.width
          foreground: root.fg
          fontFamily: root.fontFamily
          label: "Trzymaj sesję kontrolną"
          description: released
            ? "Sesję ma telefon — włącz, żeby znów sterować z paska"
            : "Wyłącz, żeby oddać sterowanie aplikacji Sony w telefonie"
          checked: !released
          onClicked: released ? root.claimSession() : root.releaseSession()
        }

        PanelSeparator { foreground: root.fg }

        // ---- jakosc lacza ----
        Item {
          width: parent.width
          height: Math.max(qualityHeader.implicitHeight, qualityValue.implicitHeight)

          PanelSectionHeader {
            id: qualityHeader
            text: "JAKOŚĆ DŹWIĘKU"
            foreground: root.fg
            fontFamily: root.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: qualityValue
            textFormat: Text.PlainText
            text: root.codecLabel
            color: root.codec.toUpperCase() === "LDAC" ? Color.accent : Qt.darker(root.fg, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        ButtonGroup {
          width: parent.width
          foreground: root.fg
          value: root.micProfile ? "headset" : "a2dp"
          options: [
            { "value": "a2dp", "label": "Jakość (A2DP)" },
            { "value": "headset", "label": "Mikrofon (HFP)" }
          ]
          onChanged: function(v) { root.setProfile(v) }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.qualityHint
          color: Qt.darker(root.fg, 1.6)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Row {
          width: parent.width
          spacing: Style.space(6)

          Button {
            text: "Wyłącz słuchawki"
            iconText: "󰐲"
            foreground: root.fg
            onClicked: root.powerOff()
          }

          Button {
            text: "Odśwież"
            iconText: "󰑐"
            foreground: root.fg
            onClicked: root.refresh()
          }
        }
      }
    }
  }

  // ---- IPC: omarchy-shell melon.sony <metoda> ----
  IpcHandler {
    target: "melon.sony"

    function open(): void { root.popupOpen = true }
    function close(): void { root.popupOpen = false }
    function toggle(): void { root.popupOpen = !root.popupOpen }
    function cycle(): void { root.cycleAnc() }
    function equalizer(): void { root.eqOpen = !root.eqOpen }
    function release(): void { root.releaseSession() }
    function claim(): void { root.claimSession() }
    function refresh(): void { root.refresh() }
    function state(): string { return JSON.stringify(root.st === null ? {} : root.st) }
  }

  // ---- czesci wspolne ----
  component SectionLabel: Text {
    width: parent ? parent.width : implicitWidth
    textFormat: Text.PlainText
    color: Qt.darker(root.fg, 1.4)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1.2
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

    color: Util.alpha(root.fg, 0.04)
    borderSpec: Border.controlSpec("normal", root.fg, Color.accent)
    radius: Style.cornerRadius
    padding: Style.space(6)
    implicitHeight: statCol.implicitHeight + contentTopInset + contentBottomInset

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

      Text {
        textFormat: Text.PlainText
        text: card.value
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.display
        font.bold: true
        width: parent.width
        elide: Text.ElideRight
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

  component HeadphonesIcon: Text {
    textFormat: Text.PlainText
    text: "󰋋"
    color: root.online ? Color.accent : root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.display
  }

  component RefreshButton: Button {
    iconText: "󰑐"
    tooltipText: "Odśwież stan"
    foreground: root.fg
    onClicked: root.refresh()
  }
}

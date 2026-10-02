pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Sterowanie rekuperacją (Thessla Green AirPack Home 500h) z paska Omarchy.
// Rozmawia z mostkiem HTTP na Raspberry Pi (Modbus RTU po /dev/ttyAMA0).
// Mostek jest hybrydowy: przejmuje port RS485 na czas odczytu/zapisu i oddaje
// go ZenSystemConnect (aplikacja AirMobile) po okresie bezczynności — dlatego
// pasek odpytuje centralę tylko przy otwartym panelu.
BarWidget {
  id: root
  moduleName: "melon.rekuperacja"

  // ---- backend ----
  readonly property string helperPath:
    (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/" + moduleName + "/rekuperacja.py"

  // ---- stan ----
  property var st: null
  // Zamiast nadpisywać wartości od razu (co potrafiło "wrócić"), trzymamy tylko
  // informację, KTÓRY element czeka na potwierdzenie - on się wtedy animuje.
  property string pendingKey: ""
  property int scrambleTick: 0
  readonly property string scrambleGlyphs: "ABCDEFGHJKLMNPQRSTUVWXYZ0123456789#%*@"
  property bool popupOpen: false
  property bool loading: false
  property bool busy: false
  property bool writing: false
  property string lastError: ""
  property real lastUpdate: 0

  readonly property bool opened: popupOpen

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color barFg: bar ? bar.barForeground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var empty: ({})
  readonly property var s: st === null ? empty : st
  readonly property var temps: s.temperatures !== undefined ? s.temperatures : empty
  readonly property var fans: s.fans !== undefined ? s.fans : empty
  readonly property var bypass: s.bypass !== undefined ? s.bypass : empty
  readonly property var alarms: s.alarms !== undefined ? s.alarms : empty
  readonly property var port: s.owner !== undefined ? s.owner : empty

  readonly property bool online: s.online === true
  readonly property bool powerOn: online && s.on === true
  readonly property bool alarmActive: online
    && (alarms.alarm === true || alarms.error === true || (alarms.stop_code || 0) !== 0)

  // ---- wartości z uwzględnieniem optymistycznych nadpisań ----
  function val(key, fallback) {
    var v = s[key]
    return v === undefined || v === null ? fallback : v
  }

  /** Tekst "przestawiający się" w trakcie oczekiwania na centralę. */
  function scramble(text, active) {
    if (!active) return text
    var t = root.scrambleTick
    var out = ""
    for (var i = 0; i < text.length; i++) {
      var ch = text.charAt(i)
      out += (ch === " " || t > i + 2)
        ? ch
        : root.scrambleGlyphs.charAt((i * 7 + t * 3) % root.scrambleGlyphs.length)
    }
    return out
  }

  /** Pulsowanie elementu (ikony, przełączniki) w trakcie oczekiwania. */
  function pulse(active) {
    if (!active) return 1.0
    return 0.35 + 0.65 * Math.abs(Math.sin(root.scrambleTick / 5.0))
  }

  function isPending(key) {
    return root.pendingKey === key
  }

  /** Naprzemienne ikony pogody - "przestawianie" dla przyciskow bez podpisu. */
  readonly property string flickerIcon: {
    var icons = [String.fromCodePoint(0xF0599), String.fromCodePoint(0xF0717), String.fromCodePoint(0xF0C2), String.fromCodePoint(0xF059D)]
    return icons[root.scrambleTick % icons.length]
  }

  readonly property string modeName: val("mode", "?")
  readonly property string seasonName: val("season", "?")
  readonly property string specialName: val("special", "none")
  readonly property int airflowManual: val("airflow_manual", 30)

  // Efektywna intensywność wentylacji (rejestr 0x0110). W trybie AUTO wyznacza ją
  // harmonogram, więc nastawa ręczna (0x1072) bywa inna - suwak i procent muszą
  // pokazywać to, co centrala faktycznie robi.
  readonly property int effectivePercent: {
    var v = root.fans.supply_percent
    return (v === undefined || v === null) ? root.airflowManual : v
  }
  readonly property real tempManual: val("temp_manual", 20)
  readonly property string comfortName: val("comfort", "eco")
  readonly property bool onState: val("on", false) === true
  readonly property bool bypassEnabled: bypass.enabled === true
  readonly property int bypassUserMode: bypass.user_mode !== undefined ? bypass.user_mode : 1

  function bypassVal(key, fallback) {
    var v = bypass[key]
    return v === undefined || v === null ? fallback : v
  }

  readonly property real minTemp: bypassVal("min_temp", NaN)
  readonly property real freecoolingTemp: bypassVal("freecooling_temp", NaN)
  readonly property real freeheatingTemp: bypassVal("freeheating_temp", NaN)

  readonly property int supplyFlow: fans.supply_flow !== undefined ? fans.supply_flow : 0
  readonly property int exhaustFlow: fans.exhaust_flow !== undefined ? fans.exhaust_flow : 0
  readonly property real supplyTemp: temps.supply !== undefined && temps.supply !== null ? temps.supply : NaN
  readonly property real outsideTemp: temps.outside !== undefined && temps.outside !== null ? temps.outside : NaN
  readonly property real exhaustTemp: temps.exhaust !== undefined && temps.exhaust !== null ? temps.exhaust : NaN

  readonly property string modeLabel: {
    if (modeName === "auto") return "automatyczny"
    if (modeName === "manual") return "manualny"
    if (modeName === "temporary") return "chwilowy"
    return "?"
  }

  readonly property string specialLabel: {
    if (specialName === "none") return "brak"
    if (specialName === "hood") return "okap"
    if (specialName === "fireplace") return "kominek"
    if (specialName.indexOf("airing") === 0) return "wietrzenie"
    if (specialName === "open_windows") return "otwarte okna"
    if (specialName === "empty_house") return "pusty dom"
    return specialName
  }

  readonly property string bypassLabel: {
    if (bypass.mode === "freecooling") return "freecooling"
    if (bypass.mode === "freeheating") return "freeheating"
    if (bypass.enabled) return "gotowy"
    return "wyłączony"
  }

  function half(value) {
    return Number(value).toFixed(1).replace(".", ",") + "\u00B0C"
  }

  // Jedno zdanie: co bypass teraz robi albo czego mu brakuje (jak w apce Android).
  readonly property string bypassHint: {
    if (!online) return ""
    if (bypass.mode === "freecooling") return "freecooling — wpuszcza chłodniejsze powietrze z zewnątrz"
    if (bypass.mode === "freeheating") return "freeheating — wpuszcza cieplejsze powietrze z zewnątrz"
    if (!bypassEnabled) return "zablokowany — przepustnica zostaje zamknięta"
    if (!isNaN(outsideTemp) && !isNaN(minTemp) && minTemp > 0 && outsideTemp < minTemp)
      return "nie otwiera: zewnętrzna " + half(outsideTemp) + " poniżej progu " + half(minTemp)
    if (!isNaN(exhaustTemp) && !isNaN(freecoolingTemp) && freecoolingTemp > 0)
      return "nie otwiera: w domu " + half(exhaustTemp) + ", próg freecoolingu " + half(freecoolingTemp)
    return "gotowy — czeka na warunki"
  }

  readonly property string ageText: {
    if (lastUpdate <= 0) return "brak danych"
    var d = Math.round((Date.now() - lastUpdate) / 1000)
    if (d < 5) return "teraz"
    if (d < 60) return d + " s temu"
    return Math.round(d / 60) + " min temu"
  }

  readonly property string portText: {
    if (port.port === "bridge") {
      var left = port.release_in
      return left === undefined || left === null
        ? "port RS485: mostek"
        : "port RS485: mostek (oddanie za " + Math.round(left) + " s)"
    }
    return "port RS485: ZenSystemConnect"
  }

  // lista temperatur do panelu (pomija czujniki bez odczytu)
  readonly property var tempRows: {
    var rows = []
    var t = root.temps
    function add(label, key) {
      var v = t[key]
      if (v === undefined || v === null) return
      rows.push({ "label": label, "value": Number(v).toFixed(1) + "°C" })
    }
    add("Zewnętrzna", "outside")
    add("Nawiew", "supply")
    add("Wywiew z domu", "exhaust")
    add("Za FPX", "fpx")
    add("Kanał (nagrzewnica)", "duct")
    add("GWC", "gwc")
    add("Otoczenie", "ambient")
    return rows
  }

  // ---- komunikacja z mostkiem ----
  function send(args, key) {
    if (proc.running) return
    pendingKey = key === undefined ? "" : key
    busy = true
    var verb = args.length > 0 ? String(args[0]) : ""
    writing = verb !== "status" && verb !== "s" && verb !== "health" && verb !== "h"
    lastError = ""
    proc.command = ["python3", "-B", helperPath].concat(args)
    proc.running = true
  }

  function refresh(fresh) {
    send(fresh ? ["status", "--fresh"] : ["status"])
  }

  function apply(raw) {
    var parsed
    try { parsed = JSON.parse(String(raw).trim()) }
    catch (e) { lastError = "Nie mogę odczytać odpowiedzi mostka"; return }
    if (parsed && parsed.error !== undefined && parsed.online !== true) {
      lastError = String(parsed.error)
      return
    }
    if (parsed && parsed.ok === false) {
      lastError = String(parsed.error !== undefined ? parsed.error : "operacja nieudana")
      return
    }
    if (parsed && parsed.written === true) {
      // mostek potwierdzil zapis bez odczytu - swiezy stan dociagamy za chwile,
      // a do tego czasu klikniety element dalej sie animuje (pendingKey)
      confirmTimer.restart()
      return
    }
    pendingKey = ""
    st = parsed
    lastUpdate = Date.now()
    lastError = ""
  }

  function setOn(on) { send([on ? "on" : "off"], on ? "on" : "off") }
  function setMode(mode) { send(["mode", mode], "mode:" + mode) }
  function setSeason(season) { send(["season", season], "season:" + season) }
  function setAirflow(percent) { send(["airflow", String(percent), "--manual"], "airflow:" + percent) }
  function setTemp(value) { send(["temp", String(value)], "temp:" + value) }
  function setSpecial(name) { send(["special", name], "special:" + name) }
  function setBypass(on) { send(["bypass", on ? "on" : "off"], "bypass") }
  function setBypassUser(mode) { send(["bypass-user", String(mode)], "bypass-user:" + mode) }
  function releasePort() { send(["release"], "") }

  function setBypassThreshold(kind, value) {
    var key = kind === "min" ? "min-temp" : kind
    if (kind === "min") send(["bypass-min-temp", String(value)], key)
    else if (kind === "freecooling") send(["bypass-freecooling", String(value)], key)
    else send(["bypass-freeheating", String(value)], key)
  }

  function open() { popupOpen = true }
  function close() { popupOpen = false }

  // Panel otwarty = szybkie odświeżanie; zamknięcie panelu oddaje port Zenowi.
  onPopupOpenChanged: {
    if (popupOpen) refresh(true)
    else releasePort()
  }

  Component.onCompleted: refresh(true)

  Process {
    id: proc
    running: false
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.apply(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text).trim()
        if (t) root.lastError = t
      }
    }
    onExited: function(code) {
      root.busy = false
      root.writing = false
      root.loading = false
      if (code !== 0 && root.lastError === "")
        root.lastError = "Mostek rekuperacji nie odpowiedział"
    }
  }

  // Animacja "przestawiania" - chodzi tylko, gdy coś czeka na potwierdzenie.
  Timer {
    interval: 60
    repeat: true
    running: root.pendingKey !== ""
    onTriggered: root.scrambleTick = root.scrambleTick + 1
  }

  Timer {
    id: confirmTimer
    interval: 600
    repeat: false
    onTriggered: root.refresh(true)
  }

  // `status` bez parametrow = odpowiedz z cache mostka (CACHE_TTL). Z `--fast`
  // kazde odpytywanie wymuszalo pelny odczyt centrali (~6,4 s) i blokowalo port
  // RS485 innym klientom (apka na telefonie) -- przy dwoch klientach kolejka
  // przekraczala ich timeouty.
  Timer {
    interval: 5000
    repeat: true
    running: root.popupOpen
    onTriggered: send(["status"])
  }

  // Powolny retry w tle (2026-10-02). Jedyne odczyty to start (Component.onCompleted)
  // i panel, więc nieudany odczyt startowy (mostek/Pi jeszcze nie wstał, port zajął
  // Zen, timeout 25 s) zostawiał w pasku "—" na zawsze -- do pierwszego otwarcia
  // panelu. Ten timer odzywa się rzadko (5 min) i tylko wtedy, gdy danych nie ma
  // albo są stare, więc nie zabiera portu Zenowi, gdy wszystko działa.
  Timer {
    interval: 300000
    repeat: true
    readonly property bool wantsRefresh: !root.online || root.lastUpdate <= 0
      || (Date.now() - root.lastUpdate) > 900000
    running: wantsRefresh && !root.popupOpen && !root.busy && !root.writing
    onTriggered: root.refresh(false)
  }

  // ---- prezentacja w pasku ----
  // Pionowy pasek (bar.vertical, np. Omacale po lewej): sama ikona w slocie,
  // wartość chowana — rząd ikona+wartość nie mieścił się w szerokości pigułki
  // i ikony wychodziły z osi. W poziomym pasku (melon.bar) bez zmian.
  readonly property bool barVertical: root.vertical
  implicitWidth: barVertical ? barSize : barRow.implicitWidth + Style.space(14)
  implicitHeight: barSize

  Row {
    id: barRow
    anchors.centerIn: parent
    spacing: Style.space(5)

    Text {
      textFormat: Text.PlainText
      text: String.fromCodePoint(0xF0210)
      color: root.alarmActive ? Color.urgent
           : root.powerOn ? Color.accent
           : Qt.darker(root.barFg, 1.8)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      anchors.verticalCenter: parent.verticalCenter
      RotationAnimation on rotation {
        running: root.powerOn
        loops: Animation.Infinite
        from: 0
        to: 360
        duration: Math.max(1200, 9000 - root.supplyFlow * 20)
      }
    }

    Text {
      textFormat: Text.PlainText
      text: root.online ? (root.powerOn ? String(root.supplyFlow) : "OFF") : "—"
      visible: !root.barVertical
      color: root.online ? Qt.darker(root.barFg, 1.2) : Qt.darker(root.barFg, 1.9)
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
      else if (mouse.button === Qt.RightButton) root.setOn(!root.onState)
      else root.refresh(true)
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, "Rekuperacja — przepływ " + root.supplyFlow + " m³/h")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  // ---- panel ----
  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(380))
    contentHeight: popup.fittedContentHeight(contentColumn.implicitHeight, Style.space(620))

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

        // ---- nagłówek ----
        PanelHero {
          width: parent.width
          foreground: root.fg
          fontFamily: root.fontFamily
          title: "Rekuperacja"
          meta: !root.online ? (root.busy ? "Łączę z centralą…" : "Brak danych")
              : root.writing ? "Zapisuję…"
              : (root.powerOn ? "Wł." : "Wył.") + " · " + root.modeLabel + " · " + root.supplyFlow + " m³/h"
          detail: root.lastError !== "" ? root.lastError : root.ageText
          iconComponent: FanIcon
          trailingControl: RefreshButton
        }

        // ---- kafelki ----
        Row {
          width: parent.width
          spacing: Style.space(8)

          StatCard {
            width: (parent.width - Style.space(8) * 2) / 3
            label: "NAWIEW"
            value: root.online ? String(root.supplyFlow) : "—"
            // pasek = nastawa wentylacji (jak pierścień w apce), liczba = realny przepływ;
            // nominalne 400 m³/h z mostka nie odpowiada temu, co ta centrala osiąga
            caption: "m³/h · " + root.effectivePercent + "%"
            fraction: root.online ? Math.max(0, Math.min(1, root.effectivePercent / 100)) : 0
          }

          StatCard {
            width: (parent.width - Style.space(8) * 2) / 3
            label: "WYWIEW"
            value: root.online ? String(root.exhaustFlow) : "—"
            caption: "m³/h · " + root.effectivePercent + "%"
            fraction: root.online ? Math.max(0, Math.min(1, root.effectivePercent / 100)) : 0
          }

          StatCard {
            width: (parent.width - Style.space(8) * 2) / 3
            label: "NAWIEW"
            value: isNaN(root.supplyTemp) ? "—" : root.supplyTemp.toFixed(1) + "°"
            caption: isNaN(root.outsideTemp) ? "zewn. —" : "zewn. " + root.outsideTemp.toFixed(1) + "°"
            fraction: isNaN(root.supplyTemp) ? 0 : Math.min(1, Math.max(0, (root.supplyTemp - 10) / 25))
          }
        }

        // ---- alarmy ----
        BorderSurface {
          width: parent.width
          visible: root.alarmActive
          color: Util.alpha(Color.urgent, 0.12)
          borderSpec: Border.controlSpec("normal", Color.urgent, Color.urgent)
          radius: Style.cornerRadius
          padding: Style.space(6)
          implicitHeight: alarmRow.implicitHeight + contentTopInset + contentBottomInset

          Row {
            id: alarmRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: parent.contentLeftInset
            anchors.rightMargin: parent.contentRightInset
            anchors.topMargin: parent.contentTopInset
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              text: "\uF0026"
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              width: parent.width - Style.space(20)
              textFormat: Text.PlainText
              text: {
                var parts = []
                if (root.alarms.alarm === true) parts.push("alarm centrali")
                if (root.alarms.error === true) parts.push("błąd")
                if ((root.alarms.stop_code || 0) !== 0) parts.push("kod zatrzymania " + root.alarms.stop_code)
                return "Uwaga: " + parts.join(", ")
              }
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }

        PanelSeparator { foreground: root.fg }

        // ---- praca ----
        SectionLabel { text: "PRACA" }

        Item {
          width: parent.width
          height: Math.max(powerLabel.implicitHeight, powerToggle.implicitHeight)

          Column {
            anchors.left: parent.left
            anchors.right: powerToggle.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Text {
              id: powerLabel
              textFormat: Text.PlainText
              text: root.onState ? "Centrala włączona" : "Centrala wyłączona"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              text: root.online ? ("tryb " + root.modeLabel + " · sezon " + (root.seasonName === "winter" ? "zima" : "lato")) : "brak danych z centrali"
              color: Qt.darker(root.fg, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          ToggleSwitch {
            id: powerToggle
            checked: root.onState
            foreground: root.fg
            busy: root.busy
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onToggled: root.setOn(!root.onState)
          }
        }

        ButtonGroup {
          width: parent.width
          foreground: root.fg
          visible: root.online
          value: root.modeName === "temporary" ? "manual" : root.modeName
          options: [
            { "value": "auto", "label": root.scramble("automatyczny", root.isPending("mode:auto")) },
            { "value": "manual", "label": root.scramble("manualny", root.isPending("mode:manual")) }
          ]
          onChanged: function(v) { root.setMode(v) }
        }

        ButtonGroup {
          width: parent.width
          foreground: root.fg
          visible: root.online
          value: root.seasonName
          options: [
            { "value": "summer", "label": "", "tooltip": "lato",
              "icon": root.isPending("season:summer") ? root.flickerIcon : String.fromCodePoint(0xF0599) },
            { "value": "winter", "label": "", "tooltip": "zima",
              "icon": root.isPending("season:winter") ? root.flickerIcon : String.fromCodePoint(0xF0717) }
          ]
          onChanged: function(v) { root.setSeason(v) }
        }

        PanelSeparator { foreground: root.fg }

        // ---- wentylacja ----
        Item {
          width: parent.width
          height: Math.max(airflowHeader.implicitHeight, airflowValue.implicitHeight)

          PanelSectionHeader {
            id: airflowHeader
            text: "WENTYLACJA"
            foreground: root.fg
            fontFamily: root.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: airflowValue
            textFormat: Text.PlainText
            text: root.scramble(root.effectivePercent + "%", root.pendingKey.indexOf("airflow:") === 0)
            color: Qt.darker(root.fg, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        PanelSlider {
          id: airflowSlider
          bar: root.bar
          width: parent.width
          minimum: 10
          maximum: 100
          integer: true
          step: 1
          value: root.effectivePercent
          enabled: root.online
          opacity: root.powerOn ? 1.0 : 0.55
          onReleased: function(v) { root.setAirflow(Math.round(v)) }
        }

        ButtonGroup {
          width: parent.width
          foreground: root.fg
          visible: root.online
          value: String(root.effectivePercent)
          options: [
            { "value": "30", "label": "1 bieg · 30%" },
            { "value": "60", "label": "2 bieg · 60%" },
            { "value": "100", "label": "3 bieg · 100%" }
          ]
          onChanged: function(v) { root.setAirflow(parseInt(v)) }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          visible: root.modeName !== "manual"
          text: "Zmiana biegu przełącza centralę w tryb manualny."
          color: Qt.darker(root.fg, 1.6)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // Blok "TEMPERATURA NAWIEWU" usunięty (2026-09-17): nastawa 0x1074 działa tylko
        // w trybie KOMFORT, którego ta centrala nie ma (brak wymienników kanałowych),
        // a faktyczne temperatury są w bloku TEMPERATURY. Patrz wiki rekuperacja-modbus.

        PanelSeparator { foreground: root.fg }

        // ---- funkcje specjalne ----
        Item {
          width: parent.width
          height: Math.max(specialHeader.implicitHeight, specialValue.implicitHeight)

          PanelSectionHeader {
            id: specialHeader
            text: "FUNKCJE SPECJALNE"
            foreground: root.fg
            fontFamily: root.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: specialValue
            textFormat: Text.PlainText
            text: root.specialLabel
            color: root.specialName === "none" ? Qt.darker(root.fg, 1.5) : Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: root.specialName !== "none"
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Flow {
          width: parent.width
          spacing: Style.space(6)

          // same ikony (MDI z Nerd Font); podpis w tooltipie i w metce nagłówka
          Button {
            iconText: String.fromCodePoint(0xF073A)
            opacity: root.pulse(root.isPending("special:none"))
            tooltipText: "brak funkcji specjalnej"
            selected: root.specialName === "none"
            foreground: root.fg
            horizontalPadding: Style.space(7)
            onClicked: root.setSpecial("none")
          }

          Button {
            iconText: String.fromCodePoint(0xF059D)
            opacity: root.pulse(root.isPending("special:airing_manual"))
            tooltipText: "wietrzenie"
            selected: root.specialName.indexOf("airing") === 0
            foreground: root.fg
            horizontalPadding: Style.space(7)
            onClicked: root.setSpecial("airing_manual")
          }

          Button {
            iconText: String.fromCodePoint(0xF0238)
            opacity: root.pulse(root.isPending("special:fireplace"))
            tooltipText: "kominek"
            selected: root.specialName === "fireplace"
            foreground: root.fg
            horizontalPadding: Style.space(7)
            onClicked: root.setSpecial("fireplace")
          }

          Button {
            iconText: String.fromCodePoint(0xF02DC)
            opacity: root.pulse(root.isPending("special:empty_house"))
            tooltipText: "pusty dom"
            selected: root.specialName === "empty_house"
            foreground: root.fg
            horizontalPadding: Style.space(7)
            onClicked: root.setSpecial("empty_house")
          }

          Button {
            iconText: String.fromCodePoint(0xF05AE)
            opacity: root.pulse(root.isPending("special:open_windows"))
            tooltipText: "otwarte okna"
            selected: root.specialName === "open_windows"
            foreground: root.fg
            horizontalPadding: Style.space(7)
            onClicked: root.setSpecial("open_windows")
          }
        }

        PanelSeparator { foreground: root.fg }

        // ---- bypass ----
        Item {
          width: parent.width
          height: Math.max(bypassLabelItem.implicitHeight, bypassToggle.implicitHeight)

          Column {
            anchors.left: parent.left
            anchors.right: bypassToggle.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Text {
              id: bypassLabelItem
              textFormat: Text.PlainText
              text: "Bypass (chłodzenie latem)"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              // Jedno zdanie: co bypass robi albo czego mu brakuje (jak w apce Android).
              text: root.bypassHint !== "" ? root.bypassHint
                : (root.bypassEnabled ? "aktywny · " + root.bypassLabel : "zablokowany")
              color: (root.bypass.mode === "freecooling" || root.bypass.mode === "freeheating")
                ? Color.accent : Qt.darker(root.fg, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              width: parent.width
              wrapMode: Text.WordWrap
            }
          }

          ToggleSwitch {
            id: bypassToggle
            checked: root.bypassEnabled
            foreground: root.fg
            busy: root.busy
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onToggled: root.setBypass(!root.bypassEnabled)
          }
        }

        ButtonGroup {
          width: parent.width
          foreground: root.fg
          visible: root.online
          value: String(root.bypassUserMode)
          options: [
            { "value": "1", "label": "tryb 1", "tooltip": "tylko zmiana położenia przepustnicy" },
            { "value": "2", "label": "tryb 2", "tooltip": "zróżnicowanie strumieni (mniejszy wywiew)" },
            { "value": "3", "label": "tryb 3", "tooltip": "wyłączenie wentylatora wywiewnego" }
          ]
          onChanged: function(v) { root.setBypassUser(parseInt(v)) }
        }

        SectionLabel {
          text: "PROGI BYPASSU"
          visible: root.online
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.online

          ThresholdRow {
            width: parent.width
            label: "zewnętrzna powyżej"
            pendingKey: "min-temp"
            value: root.minTemp
            from: 5
            to: 20
            onUpdated: function(v) { root.setBypassThreshold("min", v) }
          }

          ThresholdRow {
            width: parent.width
            label: "freecooling — pokój powyżej"
            pendingKey: "freecooling"
            value: root.freecoolingTemp
            from: 15
            to: 30
            onUpdated: function(v) { root.setBypassThreshold("freecooling", v) }
          }

          ThresholdRow {
            width: parent.width
            label: "freeheating — pokój poniżej"
            pendingKey: "freeheating"
            value: root.freeheatingTemp
            from: 15
            to: 30
            onUpdated: function(v) { root.setBypassThreshold("freeheating", v) }
          }
        }

        PanelSeparator { foreground: root.fg }

        // ---- odzysk ciepła ----
        // ---- temperatury ----
        PanelSeparator { foreground: root.fg }

        SectionLabel { text: "TEMPERATURY" }

        Flow {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.tempRows

            delegate: BorderSurface {
              id: tempCard
              required property var modelData
              width: (parent.width - Style.space(6)) / 2
              color: Util.alpha(root.fg, 0.04)
              borderSpec: Border.controlSpec("normal", root.fg, Color.accent)
              radius: Style.cornerRadius
              padding: Style.space(5)
              implicitHeight: tempCol.implicitHeight + contentTopInset + contentBottomInset

              Column {
                id: tempCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: parent.contentLeftInset
                anchors.rightMargin: parent.contentRightInset
                anchors.topMargin: parent.contentTopInset
                spacing: Style.space(1)

                Text {
                  textFormat: Text.PlainText
                  text: tempCard.modelData.label
                  color: Qt.darker(root.fg, 1.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  text: tempCard.modelData.value
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }
              }
            }
          }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.portText
          color: Qt.darker(root.fg, 1.6)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // ---- komponenty lokalne ----

  component FanIcon: Text {
    textFormat: Text.PlainText
    text: String.fromCodePoint(0xF0210)
    color: root.powerOn ? root.fg : Qt.darker(root.fg, 1.4)
    font.family: root.fontFamily
    font.pixelSize: Style.font.display
    anchors.verticalCenter: parent.verticalCenter
  }

  component RefreshButton: Button {
    iconText: String.fromCodePoint(0xF0456)
    foreground: root.fg
    onClicked: root.refresh(true)
  }

  component SectionLabel: Text {
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1.2
    color: Qt.darker(root.fg, 1.4)
  }

  component ThresholdRow: Item {
    id: row
    property string label: ""
    property string pendingKey: ""
    property real value: NaN
    property real from: 5
    property real to: 20
    signal updated(real value)

    implicitHeight: Math.max(rowLabel.implicitHeight, rowButtons.implicitHeight)

    Text {
      id: rowLabel
      textFormat: Text.PlainText
      text: row.label
      color: Qt.darker(root.fg, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.left: parent.left
      anchors.right: rowButtons.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideRight
    }

    Row {
      id: rowButtons
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      Button {
        text: "−"
        foreground: root.fg
        enabled: !isNaN(row.value) && row.value > row.from
        onClicked: row.updated(Math.max(row.from, row.value - 0.5))
      }

      Text {
        textFormat: Text.PlainText
        text: root.scramble(isNaN(row.value) ? "—" : Number(row.value).toFixed(1).replace(".", ",") + "°C",
                            root.isPending(row.pendingKey))
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        width: Style.space(46)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Button {
        text: "+"
        foreground: root.fg
        enabled: !isNaN(row.value) && row.value < row.to
        onClicked: row.updated(Math.min(row.to, row.value + 0.5))
      }
    }
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
}

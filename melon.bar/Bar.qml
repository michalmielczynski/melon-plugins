import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import qs.Commons
import qs.Ui
import "BarModel.js" as BarModel

Item {
  id: root

  // The omarchy-shell host injects omarchyPath from OMARCHY_PATH.
  // NOTE: declared as a plain (non-required) property so a cloned bar can
  // load through Loader.source (async) + configureBar(), which assigns these
  // AFTER QML instantiation. `required` rejects post-construction assignment.
  property string omarchyPath: ""
  // Injected by the host shell so bar slots can resolve enabled widgets.
  property var barWidgetRegistry: null
  // Injected by the host shell every time shell.json is reloaded. Holds the
  // `bar:` subtree: position, centerAnchor, layout. The host owns file IO;
  // the bar just renders whatever it's handed. The bar font follows the
  // OS-level fontconfig monospace binding — it is not stored in shell.json.
  property var barConfig: ({})
  // Injected by the host shell. Used for shell-wide actions such as opening
  // settings and persisting inline widget state.
  property var shell: null
  // Manifest for the active bar option. Present for custom bars and useful for
  // diagnostics; the built-in bar does not otherwise need it.
  property var manifest: null
  // Mirrors the on-disk `bar-off` flag so the user can hide the bar without
  // killing the entire shell. Hidden panels stay mapped but park off-screen
  // without an exclusion zone; updated by the FileView watcher further down.
  property bool barHidden: false
  property string home: Quickshell.env("HOME")
  property string stateHome: home + "/.local/state"
  property string omarchyConfigDir: home + "/.config/omarchy"
  property var fallbackBarConfig: ({
    position: "top",
    transparent: false,
    centerAnchor: "omarchy.clock",
    layout: { left: [], center: [], right: [] }
  })
  property var layoutConfig: fallbackBarConfig.layout
  property string centerAnchor: ""
  property bool requestedTransparent: false
  property bool useTransparentForeground: false
  property bool transparent: false
  property bool centerSectionHovered: false
  // One bar surface exists per monitor and each reports into this count, so a
  // pointer crossing from one monitor's bar to another's stays counted however
  // the enter and leave interleave. A single shared bool would be left false by
  // whichever event landed last.
  property int barHoverCount: 0
  // True while the pointer is over any bar, widgets included.
  readonly property bool barHovered: barHoverCount > 0
  property bool centerSectionRevealHeld: false
  property bool centerHoverRevealSuppressed: false
  property int barConfigSerial: 0
  property string position: "top"
  // Resolves through fontconfig at paint time (Style.font.family defaults
  // to "monospace"), so changing the system font (via `omarchy-font-set`)
  // updates the bar without a reload.
  property string fontFamily: Style.font.family
  // Bound to the central Color singleton so the bar tracks shell.toml's
  // [bar] section. Property names kept for the rest of this file's bindings.
  property color themeForeground: Color.bar.text
  property color themeContrastForeground: Color.background
  property color transparentForeground: Color.bar.text
  property color foreground: themeForeground
  property color barForeground: useTransparentForeground ? transparentForeground : themeForeground
  property bool foregroundAnimationEnabled: true
  property color background: Color.bar.background
  property color urgent: Color.bar.active

  // --- Frame ("pill") styling for the bar surface -------------------------
  // omarchy ships the bar as an invisible opacity strip; this clone draws it
  // as a rounded, bordered card so the bar reads as a real frame. All of these
  // are overridable from shell.json's bar config via `bar.frame.*` if a theme
  // or user wants to tune them. `frameEnabled=false` restores the stock look.
  property bool frameEnabled: true
  // Gap between the frame and the screen edge. 0 = hug the edge (the caelestia
  // "frame around the screen" look): the bar is flush to the edge and rounds
  // only its interior-facing corners. > 0 = a floating pill (all corners round).
  property real frameMargin: 0
  // Internal breathing room between the frame border and the widgets. Kept
  // proportionate to Omarchy's popup padding (Style.spacing.popupPadding).
  property real framePadding: Style.space(6)
  property real frameRadius: Math.min(Style.cornerRadius, root.barSize / 2)
  property bool frameFill: true
  // A QColor (not a string) so alpha composition below works. Uses the live
  // bar background token so the frame tracks themes; alpha tints it for the
  // transparent-bar case so it never reads as a solid slab.
  property color frameBackground: root.background
  // Single source of truth for the translucency shared by the transparent bar
  // frame and Hyprland's inactive windows: ~/.config/hypr/looknfeel.lua
  // (decoration.inactive_opacity). It is parsed from the FILE (see
  // refreshInactiveAlpha), NOT read back from hyprctl — syncInactiveOpacity()
  // overwrites decoration:inactive_opacity on every toggle, so reading the live
  // value would feed the sync's own output into the "transparent" target and
  // collapse it to 1.0 (no visible change).
  property real inactiveAlpha: 0.82
  property real frameBackgroundAlpha: root.transparent ? root.inactiveAlpha : 1.0
  // Border width in px, matching Hyprland's window border (general:border_size).
  property real frameBorderWidth: 2
  property real frameBorderAlpha: root.transparent ? 0.28 : 0.9
  // Inactive window border color, read live from Hyprland's
  // `general:col.inactive_border` so the island frame matches unfocused
  // windows (the color changes per theme). Falls back to the Omarchy default
  // gray until the first hyprctl read lands.
  property color windowBorderColor: "#aa595959"
  // Split the bar into separate content-fitted "islands" (left / centre /
  // right), each with its own frame hugging the screen edge, with the gaps
  // between them showing the wallpaper. Off = one full-width frame.
  property bool islands: false
  // Two islands that would touch instead merge into ONE card: the right group
  // keeps its frame pinned to the screen edge and stretches it over the centre
  // group, which slides left into the free space on its way. Off = every
  // island keeps its own frame (they overlap once they no longer fit).
  property bool islandsJoin: true

  // SVG path for a rounded frame that ONLY rounds the interior-facing corners
  // (bottom for a top bar, top for a bottom bar, right for a left bar, left for
  // a right bar). This makes the bar read as the edge of a screen frame rather
  // than a floating pill.
  function framePath(w, h) {
    if (w <= 0 || h <= 0) return ""
    var r = Math.max(0, Math.min(root.frameRadius, Math.min(w, h) / 2))
    if (r <= 0) return "M 0 0 H " + w + " V " + h + " H 0 Z"
    if (root.position === "bottom") {
      return "M 0 " + h + " H " + w + " V " + r
        + " Q " + w + " 0 " + (w - r) + " 0 H " + r + " Q 0 0 0 " + r + " Z"
    } else if (root.position === "left") {
      return "M 0 0 H " + (w - r) + " Q " + w + " 0 " + w + " " + r
        + " V " + (h - r) + " Q " + w + " " + h + " " + (w - r) + " " + h + " H 0 Z"
    } else if (root.position === "right") {
      return "M " + w + " 0 V " + h + " H " + r
        + " Q 0 " + h + " 0 " + (h - r) + " V " + r + " Q 0 0 " + r + " 0 H " + w + " Z"
    }
    // top (default): round only the bottom corners
    return "M 0 0 H " + w + " V " + (h - r)
      + " Q " + w + " " + h + " " + (w - r) + " " + h + " H " + r + " Q 0 " + h + " 0 " + (h - r) + " Z"
  }

  // OPEN SVG path for the frame border. It is the same outline as framePath but
  // the screen-edge segment is omitted (top for a top bar, bottom for a bottom
  // bar, left for a left bar, right for a right bar), so the fill bleeds into
  // the screen edge while the border renders only on the interior-facing sides
  // (caelestia "frame around the screen" look). Not closed = no edge segment.
  function frameBorderPath(w, h) {
    if (w <= 0 || h <= 0) return ""
    var r = Math.max(0, Math.min(root.frameRadius, Math.min(w, h) / 2))
    if (r <= 0) {
      if (root.position === "bottom") return "M 0 " + h + " V 0 H " + w + " V " + h
      if (root.position === "left") return "M 0 0 H " + w + " V " + h + " H 0"
      if (root.position === "right") return "M " + w + " 0 H 0 V " + h + " H " + w
      // top: left, bottom, right (no top)
      return "M 0 0 V " + h + " H " + w + " V 0"
    }
    if (root.position === "bottom") {
      return "M 0 " + h + " V " + r + " Q 0 0 " + r + " 0 H " + (w - r)
        + " Q " + w + " 0 " + w + " " + r + " V " + h
    } else if (root.position === "left") {
      return "M 0 0 H " + (w - r) + " Q " + w + " 0 " + w + " " + r
        + " V " + (h - r) + " Q " + w + " " + h + " " + (w - r) + " " + h + " H 0"
    } else if (root.position === "right") {
      return "M " + w + " 0 H " + r + " Q 0 0 0 " + r
        + " V " + (h - r) + " Q 0 " + h + " " + r + " " + h + " H " + w
    }
    // top: omit the top border, trace left, bottom, right
    return "M 0 0 V " + (h - r) + " Q 0 " + h + " " + r + " " + h
      + " H " + (w - r) + " Q " + w + " " + h + " " + w + " " + (h - r) + " V 0"
  }

  Behavior on barForeground { enabled: root.foregroundAnimationEnabled; ColorAnimation { duration: 420; easing.type: Easing.InOutCubic } }
  Behavior on background { ColorAnimation { duration: 420; easing.type: Easing.InOutCubic } }
  Behavior on urgent { ColorAnimation { duration: 420; easing.type: Easing.InOutCubic } }
  property var tooltipTarget: null
  property var pendingTooltipTarget: null
  property string tooltipText: ""
  property string pendingTooltipText: ""
  property bool tooltipShown: false
  property int tooltipRequest: 0
  property var activePopout: null
  property var barDragSource: null
  property var barDragTarget: null
  property var barDragTargetGeometry: null
  property bool barDragAfter: false
  property var barDragWindow: null
  property var barDragScreen: null
  property url barDragImageUrl: ""
  property real barDragSceneX: 0
  property real barDragSceneY: 0
  property real barDragScreenX: 0
  property real barDragScreenY: 0
  property real barDragOffsetX: 0
  property real barDragOffsetY: 0
  property bool barMoveActive: false
  property string barMoveCandidate: ""
  property var barMoveWindow: null
  property var barMoveScreen: null
  property var clickTargets: []
  property var moduleSlots: []

  function registerClickTarget(target) {
    if (!target || clickTargets.indexOf(target) !== -1) return
    var next = clickTargets.slice()
    next.push(target)
    clickTargets = next
  }

  function unregisterClickTarget(target) {
    var next = clickTargets.filter(function(item) { return item !== target })
    clickTargets = next
  }

  function registerModuleSlot(slot) {
    if (!slot || moduleSlots.indexOf(slot) !== -1) return
    var next = moduleSlots.slice()
    next.push(slot)
    moduleSlots = next
  }

  function unregisterModuleSlot(slot) {
    var next = moduleSlots.filter(function(item) { return item !== slot })
    moduleSlots = next
  }

  function debugBarGeometry() {
    var out = []
    for (var i = 0; i < moduleSlots.length; i++) {
      var slot = moduleSlots[i]
      if (!slot || !slot.activeItem) continue
      var point = { x: slot.x, y: slot.y }
      try {
        point = slot.mapToItem(null, 0, 0)
      } catch (e) {
      }
      out.push({
        id: slot.moduleName,
        section: slot.region,
        x: Math.round(point.x),
        y: Math.round(point.y),
        width: Math.round(slot.width),
        height: Math.round(slot.height),
        visible: slot.visible === true && slot.width > 0 && slot.height > 0,
        itemVisible: slot.activeItem.visible === true,
        itemWidth: Math.round(slot.activeItem.implicitWidth || 0),
        itemHeight: Math.round(slot.activeItem.implicitHeight || 0)
      })
    }
    return out
  }

  function targetWindow(target) {
    return target && target.QsWindow ? target.QsWindow.window : null
  }

  function targetBelongsToWindow(target, window) {
    return !!target && !!window && targetWindow(target) === window
  }

  function slotWindow(slot) {
    if (!slot) return null
    return targetWindow(slot.activeItem) || targetWindow(slot)
  }

  function sameWindow(left, right) {
    if (!left || !right) return false
    if (left === right) return true
    return !!left.screen && !!right.screen && !!left.screen.name && !!right.screen.name && left.screen.name === right.screen.name
  }

  function targetTooltipHovered(target) {
    return !!target && target.visible !== false && target.opacity !== 0 && target.tooltipHovered === true
  }

  function clearTooltip() {
    tooltipTimer.stop()
    pendingTooltipTarget = null
    pendingTooltipText = ""
    tooltipTarget = null
    tooltipText = ""
    tooltipShown = false
  }

  function clearBarDrag() {
    barDragSource = null
    barDragWindow = null
    barDragScreen = null
    barDragImageUrl = ""
    barDragTarget = null
    barDragTargetGeometry = null
    barDragAfter = false
    barDragSceneX = 0
    barDragSceneY = 0
    barDragScreenX = 0
    barDragScreenY = 0
    barDragOffsetX = 0
    barDragOffsetY = 0
  }

  function windowScreenPoint(scenePoint, window) {
    var x = scenePoint ? scenePoint.x : 0
    var y = scenePoint ? scenePoint.y : 0
    if (!window || !window.screen) return { x: x, y: y }

    if (root.position === "bottom")
      y += Math.max(0, window.screen.height - window.height)
    else if (root.position === "right")
      x += Math.max(0, window.screen.width - window.width)

    return { x: x, y: y }
  }

  function barDragScreenPoint(scenePoint) {
    return windowScreenPoint(scenePoint, barDragWindow)
  }

  function dropMarkerRect(slot, after) {
    if (!slot) return null

    try {
      var slotPoint = slot.mapToItem(null, 0, 0)
      var screenPoint = barDragScreenPoint(slotPoint)
      var thickness = Style.spacing.xs
      if (vertical) {
        return {
          x: screenPoint.x,
          y: screenPoint.y + (after ? slot.height : 0) - thickness / 2,
          width: slot.width,
          height: thickness
        }
      }

      return {
        x: screenPoint.x + (after ? slot.width : 0) - thickness / 2,
        y: screenPoint.y,
        width: thickness,
        height: slot.height
      }
    } catch (e) {
      return null
    }
  }

  // Split the screen along its diagonals (in normalized space, so widescreens
  // don't bias toward left/right): whichever triangle holds the cursor names
  // the candidate edge.
  function nearestScreenEdge(point, screen) {
    var nx = screen.width > 0 ? Util.clamp(point.x / screen.width, 0, 1) : 0.5
    var ny = screen.height > 0 ? Util.clamp(point.y / screen.height, 0, 1) : 0.5

    var edge = "top"
    var best = ny
    if (1 - ny < best) { edge = "bottom"; best = 1 - ny }
    if (nx < best) { edge = "left"; best = nx }
    if (1 - nx < best) { edge = "right"; best = 1 - nx }
    return edge
  }

  function beginBarMove(window) {
    barMoveWindow = window
    barMoveScreen = window ? window.screen : null
    barMoveCandidate = position
    barMoveActive = true
  }

  function updateBarMove(screenPoint) {
    if (!barMoveActive || !barMoveScreen) return
    barMoveCandidate = nearestScreenEdge(screenPoint, barMoveScreen)
  }

  function clearBarMove() {
    barMoveActive = false
    barMoveCandidate = ""
    barMoveWindow = null
    barMoveScreen = null
  }

  function finishBarMove() {
    var edge = barMoveCandidate
    if (!barMoveActive || !edge || edge === position) {
      clearBarMove()
      return
    }

    clearBarMove()
    setBarPosition(edge)
  }

  function setBarPosition(value) {
    var next = normalizePosition(value)
    if (root.shell && typeof root.shell.mutateShellConfig === "function") {
      root.shell.mutateShellConfig(function(config) {
        if (!Util.isPlainObject(config.bar)) config.bar = {}
        config.bar.position = next
      })
    } else {
      root.position = next
    }
  }

  function captureBarDragGhost(slot) {
    var item = slot && slot.activeItem ? slot.activeItem : null
    barDragImageUrl = ""
    if (!item || typeof item.grabToImage !== "function") return

    var grabWidth = Math.max(1, Math.ceil(item.width || item.implicitWidth || slot.width || 1))
    var grabHeight = Math.max(1, Math.ceil(item.height || item.implicitHeight || slot.height || 1))
    item.grabToImage(function(result) {
      if (root.barDragSource !== slot || !result || !result.url) return
      root.barDragImageUrl = result.url
    }, Qt.size(grabWidth, grabHeight))
  }

  function requestPopout(owner) {
    if (activePopout === owner) return
    if (activePopout) {
      if ("closeForPopoutSwitch" in activePopout) activePopout.closeForPopoutSwitch()
      else if ("close" in activePopout) activePopout.close()
    }
    activePopout = owner
  }

  function releasePopout(owner) {
    if (activePopout === owner) activePopout = null
  }

  readonly property bool vertical: position === "left" || position === "right"
  readonly property int barSize: vertical ? Style.bar.sizeVertical : Style.bar.sizeHorizontal

  function normalizePosition(value) {
    return BarModel.normalizePosition(value)
  }

  // Apply tray-pinning on top of the shared layout normalization so the
  // bar host and scriptable config helpers can't drift on entry shape.
  function normalizeLayout(layout) {
    var normalized = Util.normalizeLayout(Util.isPlainObject(layout) ? layout : fallbackBarConfig.layout)
    return {
      left:   pinTrayToInner(normalized.left,   "left"),
      center: pinTrayToInner(normalized.center, "center"),
      right:  pinTrayToInner(normalized.right,  "right")
    }
  }

  // The tray drawer reveals inward (away from the bar edge). Place it at the
  // section's inner edge: start of the right section, end of the left/center
  // sections. The drawer's reserved space then sits next to the bar center,
  // not stranded mid-section.
  function pinTrayToInner(entries, section) {
    return BarModel.pinTrayToInner(entries, section)
  }

  function applyBarConfig() {
    var config = Util.isPlainObject(barConfig) ? barConfig : fallbackBarConfig

    position = normalizePosition(config.position)
    setRequestedTransparency(config.transparent === true)
    centerAnchor = Util.canonicalWidgetId(config.centerAnchor || "")
    islands = config.islands === true

    // Frame ("pill") overrides, all optional, read from shell.json bar.frame.*.
    // Any field left out keeps the current value, so a theme can set just one.
    if (Util.isPlainObject(config.frame)) {
      var fr = config.frame
      if (fr.enabled !== undefined) frameEnabled = fr.enabled === true
      if (fr.margin !== undefined) { var m = Number(fr.margin); if (isFinite(m) && m >= 0) frameMargin = m }
      if (fr.padding !== undefined) { var p = Number(fr.padding); if (isFinite(p) && p >= 0) framePadding = p }
      if (fr.radius !== undefined) { var r = Number(fr.radius); if (isFinite(r) && r >= 0) frameRadius = r }
      if (fr.fill !== undefined) frameFill = fr.fill === true
      if (fr.backgroundAlpha !== undefined) { var ba = Number(fr.backgroundAlpha); if (isFinite(ba) && ba >= 0 && ba <= 1) frameBackgroundAlpha = ba }
      if (fr.borderAlpha !== undefined) { var bd = Number(fr.borderAlpha); if (isFinite(bd) && bd >= 0 && bd <= 1) frameBorderAlpha = bd }
      if (fr.borderWidth !== undefined) { var bw = Number(fr.borderWidth); if (isFinite(bw) && bw >= 0) frameBorderWidth = bw }
    }

    // layoutEntries feeds plain JS arrays to the module Repeaters, and QML
    // cannot diff those: reassigning layoutConfig rebuilds every widget on
    // every monitor. When a shell.json write only changed inline widget
    // settings, patch the live layout and running widgets in place instead.
    var next = normalizeLayout(config.layout)
    var delta = BarModel.inlineSettingsDelta(layoutConfig, next)
    if (delta) {
      applySettingsDelta(delta)
      return
    }
    layoutConfig = next
    barConfigSerial++
  }

  function applySettingsDelta(delta) {
    for (var i = 0; i < delta.length; i++) {
      var change = delta[i]
      layoutConfig[change.region][change.index] = change.entry
      var settings = entrySettings(change.entry)
      for (var s = 0; s < moduleSlots.length; s++) {
        var slot = moduleSlots[s]
        if (!slot || slot.region !== change.region || slot.moduleName !== entryId(change.entry)) continue
        var item = slot.activeItem
        if (item && "settings" in item) item.settings = settings
      }
    }
  }

  onBarConfigChanged: applyBarConfig()

  function layoutEntries(region) {
    var serial = barConfigSerial
    var entries = layoutConfig ? layoutConfig[region] : null
    return Array.isArray(entries) ? entries : []
  }

  // Tab order for the panels in one bar region. Scoped to a single bar surface
  // so tabbing walks the bar the open panel belongs to instead of hopping the
  // panel to another monitor's copy of the same widget.
  function panelNavigationSlots(region, window) {
    var entries = layoutEntries(region)
    var slots = []
    for (var i = 0; i < entries.length; i++) {
      var id = entryId(entries[i])
      for (var j = 0; j < moduleSlots.length; j++) {
        var slot = moduleSlots[j]
        if (!slot || slot.region !== region || slot.moduleName !== id) continue
        if (window && !sameWindow(slotWindow(slot), window)) continue
        var item = slot.activeItem
        if (!item || item.visible !== true || slot.visible !== true || slot.width <= 0 || slot.height <= 0) continue
        if (typeof item.open !== "function" || typeof item.close !== "function" || item.opened === undefined) continue
        slots.push(slot)
        break
      }
    }
    return slots
  }

  // The Nth panel in a bar region, counted the way the bar reads: layout order,
  // and only the panels actually on screen. A widget with no panel (the tray)
  // and one that is hiding itself are passed over, so the number lands on the
  // Nth panel icon the user can see rather than the Nth layout entry.
  // One-based, because it exists for hotkeys; anything else lands on no slot.
  //
  // Counting any bar surface is enough: every monitor lays its bar out from the
  // one layout, and summoning the id routes through pickPanelSlot, which opens
  // the focused monitor's copy whichever surface was counted.
  function panelWidgetIdAt(region, index) {
    var slots = panelNavigationSlots(String(region || ""), null)
    var slot = slots[Math.round(Number(index)) - 1]
    return slot ? String(slot.moduleName || "") : ""
  }

  function switchPanelFrom(owner, direction) {
    if (!owner) return false

    var currentSlot = null
    for (var i = 0; i < moduleSlots.length; i++) {
      var slot = moduleSlots[i]
      if (slot && slot.activeItem === owner) {
        currentSlot = slot
        break
      }
    }
    if (!currentSlot) return false

    var slots = panelNavigationSlots(currentSlot.region, slotWindow(currentSlot))
    if (slots.length < 2) return false

    var currentIndex = -1
    for (var j = 0; j < slots.length; j++) {
      if (slots[j] === currentSlot) {
        currentIndex = j
        break
      }
    }
    if (currentIndex < 0) return false

    var step = direction < 0 ? -1 : 1
    var nextSlot = slots[(currentIndex + step + slots.length) % slots.length]
    if (!nextSlot || !nextSlot.activeItem || nextSlot.activeItem === owner) return false

    nextSlot.activeItem.open()
    return true
  }

  // Every live instance of a widget id. A bar surface is built per monitor, so
  // a widget that appears once in the layout is still live once per screen.
  function moduleWidgets(pluginId) {
    var id = String(pluginId || "")
    var items = []
    if (!id) return items
    for (var i = 0; i < moduleSlots.length; i++) {
      var slot = moduleSlots[i]
      if (!slot || !slot.activeItem || slot.moduleName !== id) continue
      items.push(slot.activeItem)
    }
    return items
  }

  function slotScreenName(slot) {
    var window = slotWindow(slot)
    return window && window.screen ? String(window.screen.name || "") : ""
  }

  // The output Hyprland has focused, which is where a keyboard-summoned panel
  // belongs. Empty until Hyprland reports one, which leaves panel routing on
  // its per-monitor fallback rather than guessing at an output.
  function focusedScreenName() {
    var monitor = Hyprland.focusedMonitor
    return monitor ? String(monitor.name || "") : ""
  }

  // Resolve the live bar-widget instance for a plugin id (e.g. "omarchy.bluetooth").
  // Only widgets that expose popup open/close methods count; plain indicators
  // (clock, workspaces, tray) return null. Used by shell.summon/toggle so
  // panel hotkeys route through the bar instead of a per-target IPC handler
  // that only reaches whichever per-monitor instance claimed the target.
  function findPanelWidget(pluginId) {
    var id = String(pluginId || "")
    if (!id) return null
    var candidates = []
    for (var i = 0; i < moduleSlots.length; i++) {
      var slot = moduleSlots[i]
      if (!slot || !slot.activeItem) continue
      if (slot.moduleName !== id) continue
      var item = slot.activeItem
      if (typeof item.open !== "function" || typeof item.close !== "function" || item.opened === undefined) continue
      candidates.push({ slot: slot, screenName: slotScreenName(slot), opened: item.opened === true })
    }
    // One copy per monitor, plus a zero-size placeholder for anchored center
    // modules. See BarModel.pickPanelSlot for which one a hotkey acts on.
    var chosen = BarModel.pickPanelSlot(candidates, focusedScreenName())
    return chosen ? chosen.activeItem : null
  }

  function summonBarWidget(pluginId) {
    var item = findPanelWidget(pluginId)
    if (!item || typeof item.open !== "function") return false
    item.open()
    return true
  }

  function hideBarWidget(pluginId) {
    var item = findPanelWidget(pluginId)
    if (!item || typeof item.close !== "function") return false
    item.close()
    return true
  }

  function isBarWidgetOpen(pluginId) {
    var item = findPanelWidget(pluginId)
    return !!item && item.opened === true
  }

  function entrySettings(entry) {
    return BarModel.entrySettings(entry)
  }

  function entryId(entry) {
    return BarModel.entryId(entry)
  }

  function moduleString(entry, key, fallback) {
    return BarModel.moduleString(entry, key, fallback)
  }

  function entryIndex(entries, name) {
    return BarModel.entryIndex(entries, name)
  }

  function entriesBefore(entries, name) {
    return BarModel.entriesBefore(entries, name)
  }

  function entriesAfter(entries, name) {
    return BarModel.entriesAfter(entries, name)
  }

  function canonicalWidgetId(name) {
    return Util.canonicalWidgetId(name)
  }

  function expandPath(path) {
    return BarModel.expandPath(path, home)
  }

  function customModuleSafeName(name) {
    return BarModel.customModuleSafeName(name)
  }

  function customModuleType(entry) {
    return BarModel.customModuleType(entry)
  }

  function customModuleSource(entry) {
    var source = BarModel.customModulePath(entry, home, omarchyConfigDir)
    return source ? Util.fileUrl(source) : ""
  }

  Component.onCompleted: {
    applyBarConfig()
    refreshWindowBorderColor()
    refreshInactiveAlpha()
    syncInactiveOpacity()
  }

  // Revealing the indicators widens their section, which can slide a neighbour
  // under a stationary pointer. Collapsing on that un-hover would move it back
  // out and re-open the peek, so hold until the pointer leaves the bar.
  function setCenterSectionHovered(hovered) {
    centerSectionHovered = hovered
    if (hovered) {
      centerSectionRevealTimer.stop()
      centerSectionRevealHeld = true
    } else {
      centerSectionRevealTimer.restart()
    }
  }

  function setBarHovered(hovered) {
    barHoverCount = Math.max(0, barHoverCount + (hovered ? 1 : -1))
    if (barHoverCount === 0) centerSectionRevealTimer.restart()
  }

  Timer {
    id: centerSectionRevealTimer
    interval: 120
    // Collapse only. Opening the peek is the center section's own gesture, done
    // in setCenterSectionHovered, so a timer left pending by a pointer that dipped
    // off the bar and came back cannot reveal indicators it never pointed at.
    onTriggered: if (!root.centerSectionHovered && !root.barHovered) root.centerSectionRevealHeld = false
  }

  function run(command) {
    if (!command) return

    Util.execDetached(command)
  }

  function toggleTransparency() {
    var nextTransparent = !(root.requestedTransparent === true)
    if (root.shell && typeof root.shell.mutateShellConfig === "function") {
      root.shell.mutateShellConfig(function(config) {
        if (!Util.isPlainObject(config.bar)) config.bar = {}
        config.bar.transparent = nextTransparent
      })
    } else {
      root.setRequestedTransparency(nextTransparent)
    }
  }

  function rawLayoutSection(config, region) {
    if (!Util.isPlainObject(config.bar)) config.bar = {}
    if (!Util.isPlainObject(config.bar.layout)) config.bar.layout = {}
    if (!Array.isArray(config.bar.layout[region])) config.bar.layout[region] = []

    return config.bar.layout[region]
  }

  function rawEntryIndex(entries, name) {
    for (var i = 0; i < entries.length; i++) {
      if (root.entryId(entries[i]) === name) return i
    }

    return -1
  }

  function moveModuleInConfig(config, fromRegion, fromName, toRegion, beforeName) {
    var fromEntries = rawLayoutSection(config, fromRegion)
    var toEntries = rawLayoutSection(config, toRegion)
    var fromIndex = rawEntryIndex(fromEntries, fromName)
    if (fromIndex < 0) return false

    var toIndex = beforeName ? rawEntryIndex(toEntries, beforeName) : toEntries.length
    if (toIndex < 0) toIndex = toEntries.length

    if (fromRegion === toRegion && fromIndex === toIndex) return false

    var movedEntry = fromEntries[fromIndex]
    fromEntries.splice(fromIndex, 1)

    if (fromRegion === toRegion && fromIndex < toIndex) toIndex -= 1
    if (toIndex < 0) toIndex = 0
    if (toIndex > toEntries.length) toIndex = toEntries.length
    if (fromRegion === toRegion && fromIndex === toIndex) {
      fromEntries.splice(fromIndex, 0, movedEntry)
      return false
    }

    toEntries.splice(toIndex, 0, movedEntry)
    return true
  }

  function dropBarModule(source, toRegion, beforeName) {
    if (!source || !source.region || !source.moduleName || !toRegion) return false
    if (source.region === toRegion && source.moduleName === beforeName) return false
    if (!root.shell || typeof root.shell.mutateShellConfig !== "function") return false

    var changed = false
    root.shell.mutateShellConfig(function(config) {
      changed = moveModuleInConfig(config, source.region, source.moduleName, toRegion, beforeName)
    })
    return changed
  }

  function moduleDropAtScene(scenePoint, sourceSlot) {
    var sourceWindow = root.slotWindow(sourceSlot) || root.barDragWindow
    if (sourceWindow && sourceWindow.contentItem) {
      var barPoint = sourceWindow.contentItem.mapFromItem(null, scenePoint.x, scenePoint.y)
      if (barPoint.x < 0 || barPoint.x > sourceWindow.contentItem.width ||
          barPoint.y < 0 || barPoint.y > sourceWindow.contentItem.height)
        return null
    }

    var candidates = []
    for (var i = 0; i < moduleSlots.length; i++) {
      var slot = moduleSlots[i]
      if (!slot || slot === sourceSlot || !slot.visible || slot.width <= 0 || slot.height <= 0) continue
      if (sourceWindow && !root.sameWindow(root.slotWindow(slot), sourceWindow)) continue

      var slotPoint = { x: slot.x, y: slot.y }
      try {
        slotPoint = slot.mapToItem(null, 0, 0)
      } catch (e) {
      }

      candidates.push({
        slot: slot,
        x: slotPoint.x,
        y: slotPoint.y,
        width: slot.width,
        height: slot.height
      })
    }

    return BarModel.nearestDropTarget(candidates, scenePoint, root.vertical)
  }

  function visibleModuleSlot(region, name, sourceSlot) {
    var sourceWindow = root.slotWindow(sourceSlot) || root.barDragWindow
    for (var i = 0; i < moduleSlots.length; i++) {
      var slot = moduleSlots[i]
      if (!slot || slot === sourceSlot || slot.region !== region || slot.moduleName !== name ||
          !slot.visible || slot.width <= 0 || slot.height <= 0) continue
      if (sourceWindow && !root.sameWindow(root.slotWindow(slot), sourceWindow)) continue
      return slot
    }

    return null
  }

  function nextVisibleModuleName(region, afterName, sourceSlot) {
    var entries = layoutEntries(region)
    var found = false
    for (var i = 0; i < entries.length; i++) {
      var name = entryId(entries[i])
      if (!found) {
        found = name === afterName
        continue
      }

      if (visibleModuleSlot(region, name, sourceSlot)) return name
    }

    return ""
  }

  function dropBarModuleAtTarget(sourceSlot, targetSlot, afterTarget) {
    if (!sourceSlot || !targetSlot) return false

    var beforeName = afterTarget ? nextVisibleModuleName(targetSlot.region, targetSlot.moduleName, sourceSlot) : targetSlot.moduleName
    return dropBarModule(sourceSlot, targetSlot.region, beforeName)
  }

  function moduleTargetClickable(target) {
    return target
      && target.visible !== false
      && target.opacity !== 0
      && target.interactive !== false
      && target.pressable !== false
      && target.concealed !== true
      && typeof target.triggerPress === "function"
  }

  function moduleClickTargetAt(slot, localX, localY) {
    for (var i = clickTargets.length - 1; i >= 0; i--) {
      var target = clickTargets[i]
      if (!moduleTargetClickable(target)) continue

      var targetPoint = { x: localX, y: localY }
      try {
        targetPoint = slot.mapToItem(target, localX, localY)
      } catch (e) {
        continue
      }

      if (targetPoint.x >= 0 && targetPoint.x <= target.width &&
          targetPoint.y >= 0 && targetPoint.y <= target.height) {
        return target
      }
    }

    if (moduleTargetClickable(slot.activeItem)) return slot.activeItem
    return null
  }

  function pressModuleClickTarget(slot, button, localX, localY) {
    var target = moduleClickTargetAt(slot, localX, localY)
    if (!target) return false

    target.triggerPress(button)
    return true
  }

  function colorHex(colorValue) {
    var c = colorValue
    if (typeof c === "string") c = Qt.color(c)
    function hexChannel(value) {
      var s = Math.round(Util.clamp(value, 0, 1) * 255).toString(16)
      return s.length < 2 ? "0" + s : s
    }
    return "#" + hexChannel(c.r) + hexChannel(c.g) + hexChannel(c.b)
  }

  function setRequestedTransparency(value) {
    var nextTransparent = value === true
    requestedTransparent = nextTransparent
    if (!nextTransparent) {
      foregroundAnimationEnabled = false
      useTransparentForeground = false
      transparent = false
      transparentForeground = themeForeground
      restoreForegroundAnimation()
      return
    }
    scheduleTransparentForegroundRefresh()
  }

  function restoreForegroundAnimation() {
    Qt.callLater(function() {
      Qt.callLater(function() { root.foregroundAnimationEnabled = true })
    })
  }

  function scheduleTransparentForegroundRefresh() {
    if (!requestedTransparent) {
      transparentForeground = themeForeground
      return
    }
    transparentForegroundTimer.restart()
  }

  function refreshTransparentForeground() {
    if (!requestedTransparent || transparentForegroundProc.running) return

    transparentForegroundProc.command = [
      "omarchy-bar-text-color",
      root.position,
      String(root.barSize),
      colorHex(root.themeForeground),
      colorHex(root.themeContrastForeground)
    ]
    transparentForegroundProc.running = true
  }

  onRequestedTransparentChanged: scheduleTransparentForegroundRefresh()
  onPositionChanged: scheduleTransparentForegroundRefresh()
  onThemeForegroundChanged: scheduleTransparentForegroundRefresh()
  onThemeContrastForegroundChanged: scheduleTransparentForegroundRefresh()

  Timer {
    id: transparentForegroundTimer
    interval: 120
    repeat: false
    onTriggered: root.refreshTransparentForeground()
  }

  Process {
    id: transparentForegroundProc
    stdout: SplitParser {
      onRead: function(line) {
        var value = String(line || "").trim()
        if (!/^#[0-9A-Fa-f]{6}$/.test(value)) return

        root.foregroundAnimationEnabled = false
        root.transparentForeground = value
        if (root.requestedTransparent) {
          root.useTransparentForeground = true
          root.transparent = true
        }
        root.restoreForegroundAnimation()
      }
    }
  }

  FileView {
    path: root.stateHome + "/omarchy/current"
    watchChanges: true
    printErrors: false
    onFileChanged: {
      root.scheduleTransparentForegroundRefresh()
      root.refreshWindowBorderColor()
    }
  }

  // Read Hyprland's inactive window border color so islands match unfocused
  // windows (color changes per theme; re-read when the current theme changes).
  Process {
    id: windowBorderColorProc
    stdout: SplitParser {
      onRead: function(line) {
        var value = String(line || "").trim()
        if (!value) return
        // hyprctl returns {"gradient":"AARRGGBB 0deg",...} — take the ARGB.
        var m = value.match(/"gradient"\s*:\s*"([0-9A-Fa-f]{8})/)
        if (!m) return
        var hex = m[1]
        var a = parseInt(hex.substring(0, 2), 16) / 255.0
        var r = parseInt(hex.substring(2, 4), 16) / 255.0
        var g = parseInt(hex.substring(4, 6), 16) / 255.0
        var b = parseInt(hex.substring(6, 8), 16) / 255.0
        root.windowBorderColor = Qt.rgba(r, g, b, a)
      }
    }
  }

  function refreshWindowBorderColor() {
    if (windowBorderColorProc.running) return
    windowBorderColorProc.command = ["hyprctl", "-j", "getoption", "general:col.inactive_border"]
    windowBorderColorProc.running = true
  }

  // Keep Hyprland's inactive-window opacity in lockstep with the bar's own
  // transparency: double-clicking the bar toggles `transparent`, which flips
  // decoration:inactive_opacity between the bar's translucent alpha (0.72) and
  // fully opaque (1.0) — "exactly like the bar". Uses hyprctl eval (Hyprland's
  // Lua config manager, so `keyword` is unavailable). We sync on the actual
  // `transparent` state (what the bar renders), not `requestedTransparent`,
  // which is only set early and settles later.
  // Hyprland does not animate decoration:inactive_opacity itself, so to make
  // the opaque<->translucent flip read as a smooth fade (matching the bar's
  // own ColorAnimation) we interpolate the value in small steps via repeated
  // hyprctl eval calls, eased in/out at both ends. The first sync after boot
  // just snaps the value (no visible fade at startup); later toggles animate.
  property real lastInactiveOpacity: 1.0
  property bool opacitySnapped: false
  property real pendingInactiveOpacity: -1

  function applyInactiveOpacity(alpha) {
    opacityProc.command = ["hyprctl", "eval", 'hl.config({decoration = {inactive_opacity = ' + String(alpha) + '}})']
    opacityProc.running = true
  }

  function animateInactiveOpacity(from, to) {
    var steps = 10
    var alphas = []
    for (var i = 0; i <= steps; i++) {
      var t = i / steps
      // easeInOutQuad: slow start + slow end, smooth mid fade
      var e = t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2
      var a = from + (to - from) * e
      alphas.push(a.toFixed(3))
    }
    var script = "for a in " + alphas.join(" ") + "; do hyprctl eval \"hl.config({decoration = {inactive_opacity = $a}})\" >/dev/null 2>&1; sleep 0.018; done"
    opacityProc.command = ["bash", "-c", script]
    opacityProc.running = true
  }

  function syncInactiveOpacity() {
    var alpha = root.transparent ? root.inactiveAlpha : 1.0
    if (!root.opacitySnapped) {
      root.lastInactiveOpacity = alpha
      root.opacitySnapped = true
      applyInactiveOpacity(alpha)
      return
    }
    if (Math.abs(alpha - root.lastInactiveOpacity) < 0.001) return
    // Remember the latest target; if an animation is still in flight we can't
    // start another, but onExited picks the pending target up when it finishes.
    root.pendingInactiveOpacity = alpha
    if (opacityProc.running) return
    root.animateInactiveOpacity(root.lastInactiveOpacity, alpha)
    root.lastInactiveOpacity = alpha
    root.pendingInactiveOpacity = -1
  }

  Process {
    id: opacityProc
    // fire-and-forget; the command is set in syncInactiveOpacity()
    onExited: function(exitCode) {
      if (root.pendingInactiveOpacity >= 0) {
        var target = root.pendingInactiveOpacity
        root.pendingInactiveOpacity = -1
        root.animateInactiveOpacity(root.lastInactiveOpacity, target)
        root.lastInactiveOpacity = target
      }
    }
  }

  // Parse the translucent alpha from ~/.config/hypr/looknfeel.lua so the bar
  // frame and the value pushed on toggle share ONE config value. Never read it
  // back from Hyprland (see the property comment above).
  FileView {
    id: inactiveOpacityFile
    path: root.home + "/.config/hypr/looknfeel.lua"
    watchChanges: true
    printErrors: false
    onLoaded: root.refreshInactiveAlpha()
    onFileChanged: root.refreshInactiveAlpha()
  }

  function refreshInactiveAlpha() {
    var text = String(inactiveOpacityFile.text() || "")
    var m = text.match(/inactive_opacity\s*=\s*([0-9.]+)/)
    if (!m) return
    var v = Number(m[1])
    if (!isFinite(v) || v <= 0 || v > 1) return
    root.inactiveAlpha = v
    // The source value changed — re-sync Hyprland to the current transparent state.
    syncInactiveOpacity()
  }

  onTransparentChanged: syncInactiveOpacity()

  function runProcess(process) {
    if (!process.running)
      process.running = true
  }

  function showTooltip(target, text) {
    clearTooltip()

    if (!targetTooltipHovered(target) || !text) {
      tooltipRequest += 1
      return
    }

    var request = tooltipRequest + 1
    tooltipRequest = request
    pendingTooltipTarget = target
    pendingTooltipText = text

    Qt.callLater(function() {
      if (request !== tooltipRequest) return
      if (!targetTooltipHovered(pendingTooltipTarget)) {
        clearTooltip()
        return
      }
      tooltipTarget = pendingTooltipTarget
      tooltipText = pendingTooltipText
      pendingTooltipTarget = null
      pendingTooltipText = ""
      tooltipTimer.restart()
    })
  }

  function hideTooltip(target) {
    if (tooltipTarget !== target && pendingTooltipTarget !== target) return

    tooltipRequest += 1
    clearTooltip()
  }

  Timer {
    id: tooltipTimer
    interval: 400
    onTriggered: {
      if (root.targetTooltipHovered(root.tooltipTarget)) root.tooltipShown = true
      else root.clearTooltip()
    }
  }

  Timer {
    interval: 100
    running: root.tooltipShown
    repeat: true
    onTriggered: if (!root.targetTooltipHovered(root.tooltipTarget)) root.hideTooltip(root.tooltipTarget)
  }

  // Presence of the `bar-off` flag = bar hidden. Watching the parent toggles
  // directory because FileView can't observe a file that doesn't exist yet,
  // and the flag is created/removed by `omarchy-toggle-bar`.
  Process {
    id: barHiddenProbe
    running: true
    command: ["bash", "-c", "[[ -f $HOME/.local/state/omarchy/toggles/bar-off ]] && echo yes || echo no"]
    stdout: SplitParser { onRead: function(line) { root.barHidden = String(line).trim() === "yes" } }
  }
  FileView {
    path: root.home + "/.local/state/omarchy/toggles"
    watchChanges: true
    printErrors: false
    onFileChanged: barHiddenProbe.running = true
  }

  // The directory watch can permanently stop delivering events after flag
  // changes land in quick succession, stranding the bar off screen until the
  // shell restarts. `omarchy-toggle-bar` nudges this after flipping the flag
  // so the probe re-reads it even when the watch has gone quiet.
  IpcHandler {
    target: "omarchy.bar"

    // Start rather than restart: a probe already in flight was launched by the
    // directory watch after the flag flipped, so its answer is current, and
    // killing it here can swallow the result entirely.
    function syncHidden(): void {
      barHiddenProbe.running = true
    }
  }

  Variants {
    model: Quickshell.screens

    delegate: Component {
      BarPanel {
        required property var modelData

        screen: modelData
      }
    }
  }

  Variants {
    model: Quickshell.screens

    delegate: Component {
      DragGhostPanel {
        required property var modelData

        screen: modelData
        ghostScreen: modelData
      }
    }
  }

  Variants {
    model: Quickshell.screens

    delegate: Component {
      BarMoveGhostPanel {
        required property var modelData

        screen: modelData
        ghostScreen: modelData
      }
    }
  }

  component BarPanel: PanelWindow {
    id: barWindow

    // Hiding parks the bar just past its screen edge instead of unmapping it.
    // Unmapping frees the layer surface and the whole scene graph, so every
    // reveal has to rebuild them — new surface, re-shaped glyphs, re-uploaded
    // textures — which measures ~150ms against ~20ms to tear down. Parking
    // keeps the surface alive, so showing is only a margin change.
    visible: !remapGuard.remapping
    exclusionMode: root.barHidden ? ExclusionMode.Ignore : ExclusionMode.Auto

    ScreenMoveRemap {
      id: remapGuard
      window: barWindow
    }

    margins {
      top: root.barHidden && root.position === "top" ? -root.barSize : 0
      bottom: root.barHidden && root.position === "bottom" ? -root.barSize : 0
      left: root.barHidden && root.position === "left" ? -root.barSize : 0
      right: root.barHidden && root.position === "right" ? -root.barSize : 0
    }

    anchors {
      top: root.position === "top" || root.vertical
      bottom: root.position === "bottom" || root.vertical
      left: root.position === "left" || !root.vertical
      right: root.position === "right" || !root.vertical
    }

    implicitWidth: root.vertical ? root.barSize : 0
    implicitHeight: root.vertical ? 0 : root.barSize
    // Transparent window; the visible surface is the framed BorderSurface child
    // (below). This keeps the drag ghost / move ghost and layer hit-testing
    // working, and lets frame.enabled=false restore the stock full-width fill.
    color: "transparent"
    surfaceFormat.opaque: false
    WlrLayershell.namespace: "omarchy-bar"
    WlrLayershell.layer: WlrLayer.Top

    Loader {
      anchors.fill: parent
      sourceComponent: root.islands && !root.vertical ? horizontalBarIslands : (root.vertical ? verticalBar : horizontalBar)

      // A child of the loader, not a sibling of the sections: an ancestor stays
      // hovered while the pointer is over a widget, where a sibling would lose
      // hover to the section the pointer entered.
      HoverHandler {
        onHoveredChanged: root.setBarHovered(hovered)
        // Unplugging a monitor destroys its bar without a leave event, which
        // would strand this surface's tally and hold the peek open for good.
        Component.onDestruction: if (hovered) root.setBarHovered(false)
      }
    }

    PopupWindow {
      id: tooltipWindow

      visible: root.tooltipShown && root.tooltipTarget !== null && root.tooltipText !== "" && root.targetBelongsToWindow(root.tooltipTarget, barWindow)
      color: "transparent"
      implicitWidth: Math.ceil(tooltipBubble.implicitWidth)
      implicitHeight: Math.ceil(tooltipBubble.implicitHeight)

      anchor {
        id: tooltipAnchor
        window: barWindow
        adjustment: PopupAdjustment.Slide
        edges: Edges.Top | Edges.Left
        gravity: Edges.Bottom | Edges.Right
        rect.width: 1
        rect.height: 1

        onAnchoring: {
          var target = root.tooltipTarget
          if (!root.targetBelongsToWindow(target, barWindow)) return

          var popupWidth = tooltipWindow.implicitWidth
          var popupHeight = tooltipWindow.implicitHeight
          var localX = target.width / 2 - popupWidth / 2
          var localY = target.height + 6

          if (root.position === "bottom") {
            localY = -popupHeight - 6
          } else if (root.position === "left") {
            localX = target.width + 6
            localY = target.height / 2 - popupHeight / 2
          } else if (root.position === "right") {
            localX = -popupWidth - 6
            localY = target.height / 2 - popupHeight / 2
          }

          var point = barWindow.contentItem.mapFromItem(target, localX, localY)
          tooltipAnchor.rect.x = Math.round(point.x)
          tooltipAnchor.rect.y = Math.round(point.y)
        }
      }

      BorderSurface {
        id: tooltipBubble
        implicitWidth: tooltipLabel.implicitWidth + 20
        implicitHeight: tooltipLabel.implicitHeight + 14
        color: Color.tooltip.background
        borderSpec: Border.surfaceSpec("tooltip", "border", Color.tooltip.border, 1)
        radius: Style.cornerRadius

        Text {
          id: tooltipLabel
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: root.tooltipText
          color: Color.tooltip.text
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
        }
      }
    }

    Component {
      id: horizontalBarIslands

      Item {
        id: islandsRoot

        anchors.fill: parent

        // Outer inset that lands an island's frame on the window edge below:
        // gapsOut*2 (Style halves Hyprland's gaps_out) + frameBorderWidth. With
        // gaps_in=0 a full-width window sits at gap = gapsOut + border on both
        // sides, so this inset puts the frame edge on the window's own edge.
        readonly property real edgeInset: Style.gapsOut * 2 + root.frameBorderWidth
        // Room the merged card keeps for the left island before it starts
        // overlapping it; elastic widgets are given up before that happens.
        readonly property real leftIslandGap: Style.space(8)

        // The centre island sits on the screen centre while there is room. Once
        // the right island reaches it, the centre island slides left instead of
        // letting the two overlap: it stays glued to the right island's edge,
        // so the merged card also gets to use the free space left of centre.
        readonly property real naturalCenterX: (width - centerIsland.width) / 2
        readonly property real gluedCenterX: rightIsland.x - centerIsland.width
        readonly property bool centerJoined: root.islandsJoin && rightIsland.width > 0
          && gluedCenterX <= naturalCenterX
        readonly property real centerX: centerJoined ? gluedCenterX : naturalCenterX

        // Elastic widgets (omarchy.spacer) only exist to hold groups apart, so
        // the merged card is the first thing to give them up when it would
        // otherwise run into the left island. The measurement uses the slots'
        // natural widths, not the collapsed ones, so collapsing cannot feed
        // back into the decision that triggered it.
        readonly property real joinedNaturalWidth: centerIsland.naturalWidth + rightIsland.naturalWidth
        readonly property bool elasticCollapsed: centerJoined
          && width - edgeInset - joinedNaturalWidth < leftIsland.x + leftIsland.width + leftIslandGap

        // Full-window gesture layer behind the islands: double-clicking empty
        // bar space toggles transparency, press-and-hold drags the bar. The
        // islands render above it and handle their own widget clicks.
        CenterGestureArea { anchors.fill: parent; z: 0 }

        // Declared first: when the pair merges this island owns the shared
        // frame, so it paints under the centre island's widgets and under the
        // left island (which the card may reach once space really runs out).
        BarIsland {
          id: rightIsland

          anchors.right: parent.right
          // Mirror the left island: a full-width window's right edge sits at
          // gap = gapsOut(10) + border(2) = 12; gapsOut*2 + frameBorderWidth
          // lands the island frame exactly on the window's right edge.
          anchors.rightMargin: islandsRoot.edgeInset
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          entries: root.layoutEntries("right")
          region: "right"
          // One frame for the merged card: stretch it over the centre island so
          // the pair reads as a single surface (no seam, no doubled border).
          frameExtendLeft: islandsRoot.centerJoined ? centerIsland.width : 0
          joinedLeft: islandsRoot.centerJoined
          collapseElastic: islandsRoot.elasticCollapsed
        }

        BarIsland {
          id: centerIsland

          x: islandsRoot.centerX
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          entries: root.layoutEntries("center")
          region: "center"
          // The merged neighbour paints the shared frame.
          frameOwner: !islandsRoot.centerJoined
          joinedRight: islandsRoot.centerJoined
          collapseElastic: islandsRoot.elasticCollapsed
        }

        BarIsland {
          id: leftIsland

          anchors.left: parent.left
          anchors.leftMargin: islandsRoot.edgeInset
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          entries: root.layoutEntries("left")
          region: "left"
        }
      }
    }

    Component {
      id: horizontalBar

      Item {
        anchors.fill: parent

        // Screen-edge frame drawn behind the widgets. For a top bar it is flush
        // to the top edge and rounds only the interior (bottom) corners, so it
        // reads as the border of the screen rather than a floating pill.
        Shape {
          id: barFrame

          visible: root.frameEnabled
          anchors.fill: parent
          anchors.margins: root.frameMargin
          preferredRendererType: Shape.CurveRenderer
          z: 0

          ShapePath {
            fillColor: root.frameFill ? Qt.rgba(
              root.frameBackground.r, root.frameBackground.g, root.frameBackground.b,
              root.frameBackgroundAlpha) : "transparent"
            strokeColor: "transparent"
            strokeWidth: 0
            fillRule: ShapePath.WindingFill

            PathSvg {
              path: root.framePath(root.frameEnabled ? barFrame.width : 0, barFrame.height)
            }
          }

          // Border stroke as an OPEN path that drops the screen-edge segment, so
          // the bar merges into the screen edge instead of showing a line there.
          // Border stroke: only drawn in the translucent (transparent) bar; in
          // solid mode the outline is dropped and only the filled shape remains.
          ShapePath {
            fillColor: "transparent"
            strokeColor: Qt.rgba(
              root.barForeground.r, root.barForeground.g, root.barForeground.b,
              root.frameBorderAlpha)
            strokeWidth: root.transparent ? root.frameBorderWidth : 0
            fillRule: ShapePath.WindingFill

            PathSvg {
              path: root.frameBorderPath(root.frameEnabled ? barFrame.width : 0, barFrame.height)
            }
          }
        }

        CenterModules {
          anchors.fill: parent
          anchors.margins: root.frameEnabled ? root.framePadding : 0
          z: 1
        }

        LeftModules {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8) + (root.frameEnabled ? root.framePadding : 0)
          anchors.verticalCenter: parent.verticalCenter
          z: 1
        }

        RightModules {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8) + (root.frameEnabled ? root.framePadding : 0)
          anchors.verticalCenter: parent.verticalCenter
          z: 1
        }
      }
    }

    Component {
      id: verticalBar

      Item {
        anchors.fill: parent

        Shape {
          id: barFrame

          visible: root.frameEnabled
          anchors.fill: parent
          anchors.margins: root.frameMargin
          preferredRendererType: Shape.CurveRenderer
          z: 0

          ShapePath {
            fillColor: root.frameFill ? Qt.rgba(
              root.frameBackground.r, root.frameBackground.g, root.frameBackground.b,
              root.frameBackgroundAlpha) : "transparent"
            strokeColor: "transparent"
            strokeWidth: 0
            fillRule: ShapePath.WindingFill

            PathSvg {
              path: root.framePath(root.frameEnabled ? barFrame.width : 0, barFrame.height)
            }
          }

          // Border stroke as an OPEN path that drops the screen-edge segment, so
          // the bar merges into the screen edge instead of showing a line there.
          // Border stroke: only drawn in the translucent (transparent) bar; in
          // solid mode the outline is dropped and only the filled shape remains.
          ShapePath {
            fillColor: "transparent"
            strokeColor: Qt.rgba(
              root.barForeground.r, root.barForeground.g, root.barForeground.b,
              root.frameBorderAlpha)
            strokeWidth: root.transparent ? root.frameBorderWidth : 0
            fillRule: ShapePath.WindingFill

            PathSvg {
              path: root.frameBorderPath(root.frameEnabled ? barFrame.width : 0, barFrame.height)
            }
          }
        }

        CenterModules {
          anchors.fill: parent
          anchors.margins: root.frameEnabled ? root.framePadding : 0
          z: 1
        }

        LeftModules {
          anchors.top: parent.top
          anchors.topMargin: Style.space(8) + (root.frameEnabled ? root.framePadding : 0)
          anchors.horizontalCenter: parent.horizontalCenter
          z: 1
        }

        RightModules {
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(8) + (root.frameEnabled ? root.framePadding : 0)
          anchors.horizontalCenter: parent.horizontalCenter
          z: 1
        }
      }
    }
  }

  Component { id: emptyModuleComponent; Item { implicitWidth: 0; implicitHeight: 0; visible: false } }

  component DragGhostPanel: PanelWindow {
    id: ghostWindow

    required property var ghostScreen
    readonly property bool screenMatches: root.barDragScreen === ghostScreen ||
      (root.barDragScreen && ghostScreen && root.barDragScreen.name && ghostScreen.name && root.barDragScreen.name === ghostScreen.name)
    readonly property bool active: root.barDragSource && root.barDragScreen && screenMatches
    readonly property var sourceItem: root.barDragSource ? root.barDragSource.activeItem : null
    readonly property int ghostPadding: Style.space(1)
    readonly property int ghostWidth: sourceItem ? Math.max(1, Math.ceil(sourceItem.width)) : 1
    readonly property int ghostHeight: sourceItem ? Math.max(1, Math.ceil(sourceItem.height)) : 1

    visible: active && sourceItem !== null
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-bar-drag-ghost"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors {
      top: true
      bottom: true
      left: true
      right: true
    }

    // Visual-only drag feedback. Keep the input region empty so the ghost can
    // sit under the cursor without stealing the MouseArea's active pointer grab.
    mask: Region {}

    Item {
      visible: ghostWindow.visible
      x: Math.round(root.barDragScreenX - root.barDragOffsetX - ghostWindow.ghostPadding)
      y: Math.round(root.barDragScreenY - root.barDragOffsetY - ghostWindow.ghostPadding)
      width: ghostWindow.ghostWidth + ghostWindow.ghostPadding * 2
      height: ghostWindow.ghostHeight + ghostWindow.ghostPadding * 2

      BorderSurface {
        anchors.fill: parent
        color: root.transparent ? "transparent" : root.background
        borderSpec: Border.flat(root.barForeground, 1)
        radius: Math.min(Style.cornerRadius, height / 2)
        opacity: root.transparent ? 0.45 : 0.94
      }

      Image {
        anchors.fill: parent
        anchors.margins: ghostWindow.ghostPadding
        source: root.barDragImageUrl
        fillMode: Image.Stretch
        smooth: true
        opacity: 0.84
      }
    }

    Rectangle {
      readonly property var targetRect: root.barDragTargetGeometry

      visible: ghostWindow.active && targetRect !== null
      x: targetRect ? Math.round(targetRect.x) : 0
      y: targetRect ? Math.round(targetRect.y) : 0
      width: targetRect ? targetRect.width : 0
      height: targetRect ? targetRect.height : 0
      color: Color.accent
      radius: Math.min(width, height) / 2
    }
  }

  component BarMoveGhostPanel: PanelWindow {
    id: moveGhostWindow

    required property var ghostScreen
    readonly property bool screenMatches: root.barMoveScreen === ghostScreen ||
      (root.barMoveScreen && ghostScreen && root.barMoveScreen.name && ghostScreen.name && root.barMoveScreen.name === ghostScreen.name)
    visible: root.barMoveActive && screenMatches
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-bar-move-ghost"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors {
      top: true
      bottom: true
      left: true
      right: true
    }

    // Visual-only preview of the candidate edge. Keep the input region empty
    // so the overlay never steals the gesture area's active pointer grab.
    mask: Region {}

    // One fixed-geometry slab per edge, crossfaded on candidate changes.
    // Resizing a single slab between edges repaints mid-transition and
    // flickers; fading between static ones does not.
    Repeater {
      model: ["top", "bottom", "left", "right"]

      BorderSurface {
        id: edgeSlab

        required property string modelData
        readonly property bool edgeVertical: modelData === "left" || modelData === "right"
        readonly property int edgeSize: edgeVertical ? Style.bar.sizeVertical : Style.bar.sizeHorizontal

        x: modelData === "right" ? parent.width - edgeSize : 0
        y: modelData === "bottom" ? parent.height - edgeSize : 0
        width: edgeVertical ? edgeSize : parent.width
        height: edgeVertical ? parent.height : edgeSize
        color: root.transparent ? "transparent" : root.background
        borderSpec: Border.flat(root.barForeground, 1)
        visible: opacity > 0
        opacity: root.barMoveCandidate === modelData ? (root.transparent ? 0.45 : 0.7) : 0

        Behavior on opacity {
          NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
        }
      }
    }
  }

  function findCenterAnchorEntry() {
    var entries = root.layoutEntries("center")
    var idx = root.entryIndex(entries, root.centerAnchor)
    return idx === -1 ? null : entries[idx]
  }

  // A self-contained "island": a content-fitted frame that hugs the screen
  // edge (no border on the edge side), sized to its widgets. `entries` are the
  // bar widgets for this cluster; gaps between islands show the wallpaper.
  // Two islands that merge (see horizontalBarIslands) share ONE frame: the
  // outer island owns it and stretches it over its neighbour.
  component BarIsland: Item {
    id: island
    property var entries: []
    property string region: ""
    // Generous internal horizontal padding so the island frame breathes around
    // the widgets (and gives room for the double-click/toggle gesture).
    property real padX: Style.space(12)
    // Pixels this island's frame is painted past its own left edge, over the
    // neighbour it merged with.
    property real frameExtendLeft: 0
    // A merged neighbour paints the shared frame; this island then only paints
    // its widgets on top of it.
    property bool frameOwner: true
    // Pull the widgets toward a merged neighbour: the two islands' inner
    // paddings would otherwise add up to a gap twice the size of the ordinary
    // spacing between widgets.
    property bool joinedLeft: false
    property bool joinedRight: false
    // Elastic widgets give up their space when the merged card runs out of it.
    property bool collapseElastic: false

    readonly property real contentWidth: contentRow.implicitWidth
    readonly property real seamPull: Style.space(6)
    // Width this island wants with every elastic widget visible. Measured from
    // the slots' own natural widths rather than from the collapsed width, so
    // the merged card can price the room it needs without shrinking itself
    // into a different answer.
    readonly property real naturalWidth: visible ? slotSum("naturalWidth") + padX * 2 : 0
    width: visible ? contentWidth + padX * 2 : 0
    implicitWidth: width
    visible: island.entries.length > 0

    function slotSum(name) {
      var total = 0
      var slots = contentRow.children
      for (var i = 0; i < slots.length; i++) {
        if (slots[i] && slots[i][name] !== undefined) total += slots[i][name]
      }
      return total
    }

    Shape {
      id: islandFrame
      // Explicit geometry rather than anchors.fill: a merged card stretches its
      // frame past its own left edge, over the island it swallowed.
      visible: island.frameOwner
      x: root.frameMargin - island.frameExtendLeft
      y: root.frameMargin
      width: Math.max(0, island.width + island.frameExtendLeft - root.frameMargin * 2)
      height: Math.max(0, island.height - root.frameMargin * 2)
      preferredRendererType: Shape.CurveRenderer
      z: 0

      ShapePath {
        fillColor: root.frameFill ? Qt.rgba(
          root.frameBackground.r, root.frameBackground.g, root.frameBackground.b,
          root.frameBackgroundAlpha) : "transparent"
        strokeColor: "transparent"
        strokeWidth: 0
        fillRule: ShapePath.WindingFill
        PathSvg { path: root.framePath(islandFrame.width, islandFrame.height) }
      }

      // Border stroke: match the inactive window (general:col.inactive_border
      // color, general:border_size width) so islands read as window frames. It
      // is drawn in both transparent and solid mode, just like a window's own
      // border, not just in the translucent bar.
      ShapePath {
        fillColor: "transparent"
        strokeColor: root.windowBorderColor
        strokeWidth: root.frameBorderWidth
        fillRule: ShapePath.WindingFill
        PathSvg { path: root.frameBorderPath(islandFrame.width, islandFrame.height) }
      }
    }

    // The widgets live in a Row (matching the stock ModuleList pattern). The
    // Repeater is a direct child of the Row, so the island hugs the widgets.
    Row {
      id: contentRow
      // x instead of horizontalCenter: the merged side pulls the widgets toward
      // the seam by a few pixels, which centring would divide away again.
      x: island.padX + (island.joinedRight ? island.seamPull : 0)
        - (island.joinedLeft ? island.seamPull : 0)
      anchors.verticalCenter: parent.verticalCenter
      // Small optical correction: the shared WidgetButton centers the text's
      // line box geometrically, which can read slightly low. Nudging up a hair
      // aligns the visual centre with the card (best-practice text centring).
      anchors.verticalCenterOffset: -Math.round(Style.space(1))
      spacing: 0
      z: 1

      Repeater {
        model: island.entries
        ModuleSlot {
          required property var modelData
          entry: modelData
          region: island.region
          collapseElastic: island.collapseElastic
        }
      }
    }
  }

  component LeftModules: ModuleList {
    entries: root.layoutEntries("left")
    region: "left"
  }

  component RightModules: ModuleList {
    entries: root.layoutEntries("right")
    region: "right"
  }

  component CenterModules: Item {
    id: centerRoot

    property var entries: root.layoutEntries("center")
    readonly property bool hasAnchor: root.entryIndex(entries, root.centerAnchor) !== -1
    readonly property var anchorEntry: root.findCenterAnchorEntry()

    Loader {
      anchors.fill: parent
      sourceComponent: root.vertical ? verticalCenterModules : horizontalCenterModules
    }

    Component {
      id: horizontalCenterModules

      Item {
        anchors.fill: parent

        CenterGestureArea { anchors.fill: parent }

        HoverHandler {
          onHoveredChanged: root.setCenterSectionHovered(hovered)
        }

        ModuleList {
          visible: !centerRoot.hasAnchor
          entries: centerRoot.entries
          region: "center"
          anchors.centerIn: parent
        }

        ModuleList {
          visible: centerRoot.hasAnchor
          entries: root.entriesBefore(centerRoot.entries, root.centerAnchor)
          region: "center"
          anchors.right: centerAnchorModule.left
          anchors.verticalCenter: centerAnchorModule.verticalCenter
        }

        ModuleSlot {
          id: centerAnchorModule
          visible: centerRoot.hasAnchor
          entry: centerRoot.anchorEntry
          region: "center"
          anchors.centerIn: parent
        }

        ModuleList {
          visible: centerRoot.hasAnchor
          entries: root.entriesAfter(centerRoot.entries, root.centerAnchor)
          region: "center"
          anchors.left: centerAnchorModule.right
          anchors.verticalCenter: centerAnchorModule.verticalCenter
        }
      }
    }

    Component {
      id: verticalCenterModules

      Item {
        anchors.fill: parent

        CenterGestureArea { anchors.fill: parent }

        HoverHandler {
          onHoveredChanged: root.setCenterSectionHovered(hovered)
        }

        ModuleList {
          visible: !centerRoot.hasAnchor
          entries: centerRoot.entries
          region: "center"
          anchors.centerIn: parent
        }

        ModuleList {
          visible: centerRoot.hasAnchor
          entries: root.entriesBefore(centerRoot.entries, root.centerAnchor)
          region: "center"
          anchors.bottom: centerAnchorModule.top
          anchors.horizontalCenter: centerAnchorModule.horizontalCenter
        }

        ModuleSlot {
          id: centerAnchorModule
          visible: centerRoot.hasAnchor
          entry: centerRoot.anchorEntry
          region: "center"
          anchors.centerIn: parent
        }

        ModuleList {
          visible: centerRoot.hasAnchor
          entries: root.entriesAfter(centerRoot.entries, root.centerAnchor)
          region: "center"
          anchors.top: centerAnchorModule.bottom
          anchors.horizontalCenter: centerAnchorModule.horizontalCenter
        }
      }
    }
  }

  component CenterGestureArea: MouseArea {
    id: gestureArea

    property bool dragging: false
    property bool suppressClick: false
    property real pressedX: 0
    property real pressedY: 0
    readonly property real dragThreshold: Style.space(4)

    acceptedButtons: Qt.LeftButton
    cursorShape: dragging ? Qt.ClosedHandCursor : Qt.ArrowCursor
    pressAndHoldInterval: 200

    function startDrag(x, y) {
      if (dragging) return
      dragging = true
      root.beginBarMove(root.targetWindow(gestureArea))
      var scenePoint = gestureArea.mapToItem(null, x, y)
      root.updateBarMove(root.windowScreenPoint(scenePoint, root.barMoveWindow))
    }

    onPressed: function(mouse) {
      dragging = false
      suppressClick = false
      pressedX = mouse.x
      pressedY = mouse.y
    }

    onPressAndHold: function(mouse) {
      // A widget above us propagates its composed press-and-hold down here without
      // ever handing over the grab, so we'd get no release or cancel to end the move.
      if (!gestureArea.pressed) return
      startDrag(mouse.x, mouse.y)
    }

    onPositionChanged: function(mouse) {
      if (!(mouse.buttons & Qt.LeftButton)) return

      if (!dragging) {
        var distance = Math.abs(mouse.x - pressedX) + Math.abs(mouse.y - pressedY)
        if (distance < dragThreshold) return
        startDrag(mouse.x, mouse.y)
        return
      }

      var scenePoint = gestureArea.mapToItem(null, mouse.x, mouse.y)
      root.updateBarMove(root.windowScreenPoint(scenePoint, root.barMoveWindow))
    }

    onReleased: function(mouse) {
      if (!dragging) return
      dragging = false
      suppressClick = true
      root.finishBarMove()
      mouse.accepted = true
    }

    onCanceled: {
      dragging = false
      suppressClick = false
      root.clearBarMove()
    }

    onClicked: function(mouse) {
      if (suppressClick) {
        suppressClick = false
        mouse.accepted = true
      }
    }

    onDoubleClicked: function(mouse) {
      if (suppressClick) {
        suppressClick = false
        return
      }
      if (mouse.button === Qt.LeftButton) {
        root.toggleTransparency()
        mouse.accepted = true
      }
    }
  }

  component ModuleList: Loader {
    id: moduleListRoot

    property var entries: []
    property string region: ""

    visible: entries.length > 0
    // A hidden list must not build its modules. The center section declares
    // both an anchored and an unanchored arrangement and shows whichever
    // fits, so leaving the other one loaded mounts every center module
    // twice — two IPC handlers registered for the same target, two clocks
    // ticking, two of every timer and fetch behind them.
    active: visible && entries.length > 0
    sourceComponent: root.vertical ? verticalModuleList : horizontalModuleList
    width: item ? item.implicitWidth : 0
    height: item ? item.implicitHeight : 0

    Component {
      id: horizontalModuleList

      Row {
        spacing: 0

        Repeater {
          model: moduleListRoot.entries

          ModuleSlot {
            required property var modelData
            entry: modelData
            region: moduleListRoot.region
          }
        }
      }
    }

    Component {
      id: verticalModuleList

      Column {
        spacing: 0

        Repeater {
          model: moduleListRoot.entries

          ModuleSlot {
            required property var modelData
            entry: modelData
            region: moduleListRoot.region
          }
        }
      }
    }
  }

  component ModuleSlot: Item {
    id: slot

    required property var entry
    property string region: ""
    // Set by the island when a merged card is out of room: elastic widgets
    // (spacers) collapse instead of pushing the card over the left island.
    property bool collapseElastic: false
    readonly property string moduleName: root.entryId(entry)
    readonly property var moduleSettings: root.entrySettings(entry)
    readonly property string customType: root.customModuleType(entry)
    // Re-evaluate when the registry mutates (Component reference changes,
    // plugin enabled/disabled, etc.). Reading the `widgets` property creates
    // the binding dependency — the wrapped function call alone wouldn't.
    readonly property var registryComponent: {
      var w = root.barWidgetRegistry.widgets
      if (customType) return null
      var registryName = root.canonicalWidgetId(moduleName)
      return w[registryName] ? w[registryName].component : null
    }
    readonly property bool qmlCustom: customType === "qml"
    readonly property bool commandCustom: customType === "command"
    readonly property bool registered: registryComponent !== null
    readonly property var activeItem: {
      if (registered) return registryLoader.item
      if (qmlCustom) return qmlLoader.item
      return componentLoader.item
    }
    // Elastic widgets only exist to hold groups apart, so they are the first
    // thing a crowded merged card gives up.
    readonly property bool elasticSlot: moduleName === "omarchy.spacer"
    readonly property bool elasticHidden: collapseElastic && elasticSlot
    // Width the widget wants on its own, ignoring the elastic collapse: the
    // island prices the fully expanded card with it.
    readonly property real naturalWidth: activeItem && activeItem.visible ? (root.vertical ? root.barSize : activeItem.implicitWidth) : 0
    readonly property bool hovered: moduleHover.hovered
    readonly property bool dragSource: root.barDragSource === slot
    readonly property bool panelOpen: root.activePopout === slot.activeItem
    // Modules bigger than the mark they want (a text label in a padded slot,
    // a multi-line stack on a vertical bar) can say how long the open-panel
    // dot should be along the bar, so it tracks what the module paints
    // instead of a fraction of whatever slot it happens to fill.
    readonly property real panelIndicatorExtent: {
      var key = root.vertical ? "openPanelIndicatorHeight" : "openPanelIndicatorWidth"
      var hint = activeItem && key in activeItem ? activeItem[key] : undefined
      if (hint !== undefined && hint !== null && hint > 0) return Math.round(hint)
      return Math.max(Style.space(10), Math.round((root.vertical ? slot.height : slot.width) * 0.55))
    }
    implicitWidth: elasticHidden ? 0 : naturalWidth
    implicitHeight: elasticHidden ? 0 : (activeItem && activeItem.visible ? activeItem.implicitHeight : 0)
    width: implicitWidth
    height: implicitHeight
    z: modulePointer.dragging ? 100 : 0

    Component.onCompleted: root.registerModuleSlot(slot)
    Component.onDestruction: {
      if (root.barDragSource === slot) root.clearBarDrag()
      root.unregisterModuleSlot(slot)
    }

    HoverHandler { id: moduleHover }

    BorderSurface {
      visible: slot.dragSource
      anchors.fill: parent
      anchors.margins: Style.space(1)
      color: root.transparent ? "transparent" : root.background
      borderSpec: Border.flat(root.barForeground, 1)
      radius: Math.min(Style.cornerRadius, height / 2)
      opacity: root.transparent ? 0.22 : 0.32
    }

    Loader {
      id: componentLoader
      active: !slot.qmlCustom && !slot.registered
      sourceComponent: slot.commandCustom ? customCommandModuleComponent : emptyModuleComponent
      anchors.fill: parent
      opacity: slot.dragSource ? 0.22 : 1.0
      onLoaded: {
        slot.injectProps()
        Qt.callLater(slot.injectProps)
      }
    }

    Loader {
      id: registryLoader
      active: slot.registered
      sourceComponent: slot.registered ? slot.registryComponent : null
      anchors.fill: parent
      opacity: slot.dragSource ? 0.22 : 1.0
      onLoaded: {
        slot.injectProps()
        Qt.callLater(slot.injectProps)
      }
    }

    Loader {
      id: qmlLoader
      active: slot.qmlCustom
      source: slot.qmlCustom ? root.customModuleSource(slot.entry) : ""
      anchors.fill: parent
      opacity: slot.dragSource ? 0.22 : 1.0
      onLoaded: {
        slot.injectProps()
        Qt.callLater(slot.injectProps)
      }
    }

    Rectangle {
      id: openPanelIndicator

      readonly property int inset: Style.space(2)

      visible: opacity > 0
      opacity: slot.panelOpen && !slot.dragSource ? 0.9 : 0
      color: Color.accent
      radius: Math.min(width, height) / 2
      width: root.vertical ? Style.space(2) : slot.panelIndicatorExtent
      height: root.vertical ? slot.panelIndicatorExtent : Style.space(2)
      // The mark sits on the module's inner edge — the one facing the
      // desktop — so it underlines a top bar, overlines a bottom one, and
      // points inward from a left or right one. It reads as pointing at the
      // panel that opens on that side.
      x: root.vertical
        ? (root.position === "left" ? parent.width - width - inset : inset)
        : Math.round((parent.width - width) / 2)
      y: root.vertical
        ? Math.round((parent.height - height) / 2)
        : (root.position === "top" ? parent.height - height - inset : inset)
      z: 50

      Behavior on opacity {
        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
      }
    }

    MouseArea {
      id: modulePointer

      property bool dragging: false
      property bool suppressClick: false
      property real pressedX: 0
      property real pressedY: 0
      readonly property bool canReorder: root.shell && typeof root.shell.mutateShellConfig === "function"
      readonly property real dragThreshold: Style.space(4)

      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      enabled: slot.visible && slot.width > 0 && slot.height > 0
      propagateComposedEvents: true
      cursorShape: root.moduleClickTargetAt(slot, mouseX, mouseY) ? Qt.PointingHandCursor : Qt.ArrowCursor
      // Do not assign drag.target here: ModuleSlot is owned by Row/Column
      // positioners, and mutating slot.x/slot.y can leave stale offsets that
      // make neighboring modules overlap after a small aborted drag.

      onPressed: function(mouse) {
        dragging = false
        suppressClick = false
        pressedX = mouse.x
        pressedY = mouse.y
        root.clearBarDrag()
      }

      onPositionChanged: function(mouse) {
        if (!canReorder || !(mouse.buttons & Qt.LeftButton)) return

        var distance = Math.abs(mouse.x - pressedX) + Math.abs(mouse.y - pressedY)
        if (distance >= dragThreshold) {
          if (!dragging) {
            root.barDragWindow = root.targetWindow(slot.activeItem) || root.targetWindow(slot)
            root.barDragScreen = root.barDragWindow ? root.barDragWindow.screen : null
            root.barDragOffsetX = pressedX
            root.barDragOffsetY = pressedY
            root.captureBarDragGhost(slot)
            root.barDragSource = slot
          }
          dragging = true
          root.hideTooltip(slot.activeItem)
        }

        if (dragging) {
          var scenePoint = slot.mapToItem(null, mouse.x, mouse.y)
          var screenPoint = root.barDragScreenPoint(scenePoint)
          root.barDragSceneX = scenePoint.x
          root.barDragSceneY = scenePoint.y
          root.barDragScreenX = screenPoint.x
          root.barDragScreenY = screenPoint.y

          var drop = root.moduleDropAtScene(scenePoint, slot)
          root.barDragTarget = drop ? drop.slot : null
          root.barDragAfter = drop ? drop.after : false
          root.barDragTargetGeometry = drop ? root.dropMarkerRect(drop.slot, drop.after) : null
        }
      }

      onReleased: function(mouse) {
        var wasDragging = dragging
        var targetSlot = root.barDragTarget
        var afterTarget = root.barDragAfter

        if (wasDragging) suppressClick = true

        dragging = false
        root.clearBarDrag()

        if (wasDragging && targetSlot) {
          root.dropBarModuleAtTarget(slot, targetSlot, afterTarget)
          mouse.accepted = true
        } else if (!wasDragging) {
          mouse.accepted = false
        }
      }

      onCanceled: {
        dragging = false
        suppressClick = false
        root.clearBarDrag()
      }

      onClicked: function(mouse) {
        if (suppressClick) {
          suppressClick = false
          mouse.accepted = true
          return
        }

        if (!root.pressModuleClickTarget(slot, mouse.button, mouse.x, mouse.y)) mouse.accepted = false
      }
    }

    onActiveItemChanged: Qt.callLater(injectProps)
    onModuleSettingsChanged: injectProps()

    function injectProps() {
      var target = activeItem
      if (!target) return
      if ("bar" in target) target.bar = root
      if ("moduleName" in target) target.moduleName = moduleName
      if ("settings" in target) target.settings = moduleSettings
    }

    Component {
      id: customCommandModuleComponent
      CustomCommandModule { entry: slot.entry }
    }
  }

  component CustomCommandModule: WidgetButton {
    id: customRoot

    required property var entry
    readonly property string moduleName: root.entryId(entry)
    readonly property var settings: root.entrySettings(entry)
    property string outputText: ""
    property string outputTooltip: ""
    property bool outputActive: false

    function setting(name, fallback) {
      var value = settings ? settings[name] : undefined
      return value === undefined || value === null ? fallback : value
    }

    function update(raw) {
      var data = Util.parseModuleJson(raw)
      var klass = data.class || data.alt || ""

      outputText = data.text || String(raw || "").trim()
      outputTooltip = data.tooltip || String(setting("tooltip", ""))
      outputActive = klass === "active" || (Array.isArray(klass) && klass.indexOf("active") !== -1)
    }

    bar: root
    text: outputText || String(setting("text", ""))
    tooltipText: outputTooltip || String(setting("tooltip", ""))
    active: outputActive
    keepSpace: setting("keepSpace", false) === true
    horizontalMargin: Number(setting("horizontalMargin", 7.5))
    verticalPadding: Number(setting("verticalPadding", 6))
    fontSize: Number(setting("fontSize", 12))

    onPressed: function(button) {
      var command = ""
      if (button === Qt.RightButton)
        command = String(setting("onRightClick", ""))
      else if (button === Qt.MiddleButton)
        command = String(setting("onMiddleClick", ""))
      else
        command = String(setting("onClick", ""))

      if (command) root.run(command)
    }

    Process {
      id: customProc
      command: ["bash", "-lc", String(customRoot.setting("exec", ""))]
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: customRoot.update(text)
      }
    }

    Timer {
      interval: Math.max(1, Number(customRoot.setting("interval", 5))) * 1000
      running: String(customRoot.setting("exec", "")) !== ""
      repeat: true
      triggeredOnStart: true
      onTriggered: root.runProcess(customProc)
    }
  }
}

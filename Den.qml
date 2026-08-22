import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell.Services.SystemTray
import qs.Commons
import qs.Ui
import "DenModel.js" as DenModel

// Den — a Windows-style overflow flyout for the Omarchy bar.
//
// Clicking the chevron drops down a compact grid of icon tiles: every tray
// app that is not pinned on the stock tray, plus any bar plugins hidden here.
// It is purely a declutter tool — nothing in this widget enables, disables,
// or removes anything.
//
// Gestures:
//   - Press-and-hold a bar widget anywhere on the bar and drop it on the
//     chevron (or the open card) to tuck it away.
//   - Inside the grid, press-and-hold a tile and release it on the eject
//     strip at the top of the card ("Release to show") to send it back:
//     plugins return to the bar layout, tray apps get pinned on the bar.
//   - Left-click a tile to activate the app / toggle the plugin's panel;
//     right-click opens the app's real menu (submenus included) or sends a
//     plugin tile straight back to the bar.
BarWidget {
  id: root
  moduleName: "so.den"

  // --- shared lookups --------------------------------------------------------

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Per-widget inline settings from this layout entry in shell.json.
  //   icons: { "<plugin-id>": "<glyph or image path>" } — manual overrides.
  //   captureOverflow: write unpinned-but-not-hidden tray ids into the stock
  //     tray's hidden list so its own expander stays empty (default true).
  readonly property var iconOverrides: {
    var m = root.setting("icons", {})
    return m && typeof m === "object" ? m : {}
  }
  readonly property bool captureOverflow: root.setting("captureOverflow", true) !== false

  // --- plugin registry -------------------------------------------------------

  readonly property var registryWidgets: root.bar && root.bar.barWidgetRegistry
    ? root.bar.barWidgetRegistry.widgets : ({})

  // Raw configured list, read from the live in-memory config so rapid
  // successive changes never read a stale settings snapshot.
  readonly property var configuredIds: {
    var rev = root.manageRevision
    void rev
    var list = null
    var shell = root.bar && root.bar.shell
    var config = shell ? shell.shellConfig : null
    if (config && config.bar && config.bar.layout) {
      var sections = DenModel.sections()
      for (var s = 0; s < sections.length; s++) {
        var arr = DenModel.sectionEntries(config, sections[s])
        for (var i = 0; i < arr.length; i++) {
          if (arr[i] && DenModel.entryId(arr[i]) === root.moduleName) {
            if (Array.isArray(arr[i].widgets)) list = arr[i].widgets
            break
          }
        }
        if (list) break
      }
    }
    if (!Array.isArray(list)) {
      var defaults = root.defaultsFor(root.moduleName)
      list = defaults && Array.isArray(defaults.widgets) ? defaults.widgets : []
    }
    return DenModel.stringList(list)
  }

  readonly property var hiddenIds: {
    var out = []
    var configured = root.configuredIds
    for (var i = 0; i < configured.length; i++) {
      var id = String(configured[i] || "")
      if (id && root.registryWidgets[id]) out.push(id)
    }
    return out
  }

  function defaultsFor(id) {
    var entry = root.registryWidgets[id]
    if (entry && entry.metadata && entry.metadata.defaults) return entry.metadata.defaults
    var manifest = root.pluginManifest(id)
    return manifest && manifest.barWidget && manifest.barWidget.defaults
      ? manifest.barWidget.defaults : ({})
  }

  function displayName(id) {
    var entry = root.registryWidgets[id]
    if (entry && entry.metadata && entry.metadata.displayName) return String(entry.metadata.displayName)
    var manifest = root.pluginManifest(id)
    if (manifest && manifest.name) return String(manifest.name)
    return id
  }

  function pluginManifest(id) {
    var reg = root.bar && root.bar.shell && root.bar.shell.pluginRegistry
    return reg && reg.installedPlugins ? (reg.installedPlugins[String(id || "")] || null) : null
  }

  // --- tray state ------------------------------------------------------------

  readonly property var trayState: {
    var rev = root.manageRevision
    void rev
    var shell = root.bar && root.bar.shell
    var config = shell ? shell.shellConfig : null
    return DenModel.trayEntrySettings(config)
  }

  readonly property var trayPinnedIds: DenModel.stringList(trayState.pinned)
  readonly property var trayHiddenIds: DenModel.stringList(trayState.hidden)

  function trayItemName(item) {
    var t = String(item.title || "").trim()
    if (t) return t
    var tt = String(item.tooltipTitle || "").trim()
    if (tt) return tt
    var id = String(item.id || "")
    var slash = id.lastIndexOf("/")
    return slash !== -1 ? id.substring(slash + 1) : (id || "Unknown")
  }

  // Tray apps are untrusted local inputs (StatusNotifierItem D-Bus). Reject any
  // network-scheme string (http/https/ftp/…) so a malicious notifier can't make
  // the shared shell fetch or load an arbitrary remote/SSRF resource. Any other
  // value (QIcon, theme name, local path, empty) is passed through unchanged.
  function safeIconSource(v) {
    if (typeof v !== "string") return v
    var s = v || ""
    if (!s) return ""
    if (/^(https?|ftps?):/i.test(s)) return ""
    return s
  }

  // Live tray items, excluding passives and omarchy-owned pseudo-items.
  readonly property var liveTrayItems: {
    var values = SystemTray.items.values
    var out = []
    for (var i = 0; i < values.length; i++) {
      var item = values[i]
      if (item.status === Status.Passive) continue
      if (DenModel.ownedByOmarchy(item, root.bar && root.bar.layoutConfig)) continue
      out.push(item)
    }
    return out
  }

  // Windows-style overflow membership: everything NOT pinned lives here.
  // Persisted hidden ids come first (stable order), unclassified follow.
  readonly property var trayOverflowItems: {
    var byId = {}
    for (var i = 0; i < root.liveTrayItems.length; i++)
      byId[String(root.liveTrayItems[i].id || "")] = root.liveTrayItems[i]
    var out = []
    var ids = root.trayHiddenIds
    for (var j = 0; j < ids.length; j++) {
      if (byId[ids[j]]) { out.push(byId[ids[j]]); delete byId[ids[j]] }
    }
    for (var key in byId) {
      if (root.trayPinnedIds.indexOf(key) === -1) out.push(byId[key])
    }
    return out
  }

  function trayItemById(id) {
    var items = root.liveTrayItems
    for (var i = 0; i < items.length; i++) {
      if (String(items[i].id || "") === id) return items[i]
    }
    return null
  }

  function persistTrayState(pinned, hidden) {
    var shell = root.bar && root.bar.shell
    if (!shell || typeof shell.updateEntryInline !== "function") return
    shell.updateEntryInline("omarchy.tray", { id: "omarchy.tray", pinned: pinned, hidden: hidden })
  }

  // Auto-capture: unpinned ids that are not yet in the hidden list are added
  // there once, so the stock tray's expander stays empty and the overflow
  // lives solely in this drawer. Only ever appends; ejecting pins instead.
  readonly property string overflowSignature: {
    var ids = []
    for (var i = 0; i < root.trayOverflowItems.length; i++) ids.push(String(root.trayOverflowItems[i].id || ""))
    return ids.join("|")
  }

  onOverflowSignatureChanged: reconcileTrayTimer.restart()

  Timer {
    id: reconcileTrayTimer
    interval: 400
    onTriggered: root.captureOverflowIfNeeded()
  }

  function captureOverflowIfNeeded() {
    if (!root.captureOverflow) return
    var missing = []
    for (var i = 0; i < root.trayOverflowItems.length; i++) {
      var iid = String(root.trayOverflowItems[i].id || "")
      if (iid && root.trayHiddenIds.indexOf(iid) === -1) missing.push(iid)
    }
    if (missing.length === 0) return
    root.persistTrayState(root.trayPinnedIds, root.trayHiddenIds.concat(missing))
  }

  // --- eject / drag-out gestures -----------------------------------------------
  //
  // Pressing a tile arms nothing; a drag only starts once movement passes the
  // threshold, so plain clicks can never flash drag visuals or get swallowed.
  //
  // While a PLUGIN tile is dragged, a lightweight hyprctl cursorpos poller
  // tracks the global cursor and compares it against every visible bar slot's
  // screen rectangle (via the bar's own windowScreenPoint mapping). The
  // nearest slot becomes the live drop target, previewed in the footer;
  // releasing over the bar inserts the plugin exactly there. Releasing on the
  // top strip keeps the plain end-of-right eject. Tray tiles never target the
  // bar — their strip release pins them back on the stock tray.

  property string dragKind: ""
  property string dragId: ""
  property bool dragActive: false
  property bool ejectArmed: false
  property real dragGhostX: 0
  property real dragGhostY: 0
  readonly property real dragThreshold: Style.space(6)
  readonly property real tileSize: Style.space(32)
  readonly property real gridSpacing: Style.space(6)
  readonly property real ejectStripHeight: Style.space(34)

  function tileDragStart(kind, id, handle, mx, my) {
    root.dragKind = kind
    root.dragId = id
    root.dragActive = true
    root.ejectArmed = false
    root.trackDrag(handle, mx, my)
    if (kind === "plugin" && !monitorsProcess.running) monitorsProcess.running = true
  }

  function trackDrag(handle, mx, my) {
    var popPoint
    try {
      popPoint = bodyFlick.mapFromItem(handle, mx, my)
    } catch (e) {
      return
    }
    root.dragGhostX = popPoint.x - root.tileSize / 2
    root.dragGhostY = popPoint.y - root.tileSize / 2
  }

  function tileDragMove(handle, mx, my) {
    if (!root.dragActive) return
    root.trackDrag(handle, mx, my)
    var popPoint
    try {
      popPoint = menuPopup.mapFromItem(handle, mx, my)
    } catch (e) {
      return
    }
    root.ejectArmed = popPoint.y <= root.ejectStripHeight || popPoint.y < 0
    if (root.ejectArmed) {
      root.reorderTargetKey = ""
      root.reorderAfter = false
      return
    }
    root.computeReorderTarget(handle, mx, my)
  }

  // Live bar drop target while dragging a plugin tile: { region, anchorName,
  // after } or null.
  property var barDropTarget: null

  // Reorder preview while hovering the grid: the same-kind tile whose slot
  // the dragged tile would take.
  property string reorderTargetKey: ""
  property bool reorderAfter: false

  function computeReorderTarget(handle, mx, my) {
    var p
    try {
      p = bodyContent.mapFromItem(handle, mx, my)
    } catch (e) {
      return
    }
    var marginX = Style.space(10)
    var marginY = Style.space(10)
    if (p.x < -marginX || p.x > bodyContent.width + marginX
        || p.y < -marginY || p.y > bodyContent.height + marginY) {
      root.reorderTargetKey = ""
      return
    }

    var kindIsTray = root.dragKind === "tray"
    var kids = bodyContent.children
    var best = null
    var bestDist = Infinity
    for (var i = 0; i < kids.length; i++) {
      var t = kids[i]
      // Only DrawerTile delegates carry this marker.
      if (t.tileIsTray === undefined || !t.visible) continue
      if (t.tileIsTray !== kindIsTray) continue
      if (String(t.key) === String(root.dragId)) continue
      var cx = t.x + t.width / 2
      var cy = t.y + t.height / 2
      var dx = p.x - cx
      var dy = p.y - cy
      var d = dx * dx + dy * dy
      if (d < bestDist) {
        bestDist = d
        best = { key: String(t.key), after: dx > 0 }
      }
    }
    if (!best) {
      root.reorderTargetKey = ""
      return
    }
    root.reorderTargetKey = best.key
    root.reorderAfter = best.after
  }

  function commitReorder(id, anchorKey, after) {
    if (!id || !anchorKey) return
    if (root.dragKind === "plugin") reorderPluginInList(id, anchorKey, after)
    else reorderTrayAppInList(id, anchorKey, after)
  }

  function reorderPluginInList(id, anchorId, after) {
    var list = root.configuredIds.slice()
    var fi = list.indexOf(String(id))
    var ti = list.indexOf(String(anchorId))
    if (fi === -1 || ti === -1) return
    list.splice(fi, 1)
    var idx = list.indexOf(String(anchorId))
    if (idx === -1) return
    var insertAt = Math.max(0, Math.min(after ? idx + 1 : idx, list.length))
    if (insertAt === fi) return
    list.splice(insertAt, 0, String(id))
    root.persistWidgets(list)
  }

  function reorderTrayAppInList(id, anchorId, after) {
    // Overflow order is the persisted hidden order (captureOverflow keeps all
    // members there). A brand-new app may not be persisted yet, so pull any
    // missing overflow members in first; pinned ids stay excluded.
    var list = root.trayHiddenIds.slice()
    var members = root.trayOverflowItems
    for (var m = 0; m < members.length; m++) {
      var mid = String(members[m].id || "")
      if (!mid) continue
      if (root.trayPinnedIds.indexOf(mid) !== -1) continue
      if (list.indexOf(mid) === -1) list.push(mid)
    }
    var fi = list.indexOf(String(id))
    var ti = list.indexOf(String(anchorId))
    if (fi === -1 || ti === -1) return
    list.splice(fi, 1)
    var idx = list.indexOf(String(anchorId))
    if (idx === -1) return
    var insertAt = Math.max(0, Math.min(after ? idx + 1 : idx, list.length))
    if (insertAt === fi) return
    list.splice(insertAt, 0, String(id))
    root.persistTrayState(root.trayPinnedIds, list)
  }

  function tileDragEnd() {
    // Capture every piece of drag state first — tileDragCancel() wipes it all.
    var kind = root.dragKind
    var id = root.dragId
    var target = root.barDropTarget
    var eject = root.ejectArmed
    var rAnchor = root.reorderTargetKey
    var rAfter = root.reorderAfter
    root.tileDragCancel()
    if (!id) return
    if (kind === "plugin") {
      if (target) {
        root.ejectPlugin(id, String(target.region), String(target.anchorName), target.after === true)
        return
      }
      if (eject) {
        root.ejectPlugin(id, "", "", false)
        return
      }
    } else {
      if (eject) {
        root.ejectTrayIcon(id)
        return
      }
    }
    if (rAnchor) {
      if (kind === "plugin") root.reorderPluginInList(id, rAnchor, rAfter)
      else root.reorderTrayAppInList(id, rAnchor, rAfter)
    }
  }

  function tileDragCancel() {
    root.dragKind = ""
    root.dragId = ""
    root.dragActive = false
    root.ejectArmed = false
    root.barDropTarget = null
    root.reorderTargetKey = ""
    root.reorderAfter = false
  }

  function ejectPlugin(id, region, anchorName, after) {
    var key = String(id || "")
    if (!key || key === root.moduleName) return
    root.removeFromPluginsAndAddToLayout(key, region, anchorName, after)
    var list = root.configuredIds.slice()
    var idx = list.indexOf(key)
    if (idx !== -1) {
      list.splice(idx, 1)
      root.persistWidgets(list)
    }
  }

  function ejectTrayIcon(id) {
    var key = String(id || "")
    if (!key) return
    var p = root.trayPinnedIds.slice()
    if (p.indexOf(key) === -1) p.push(key)
    var h = root.trayHiddenIds.slice()
    var idx = h.indexOf(key)
    if (idx !== -1) h.splice(idx, 1)
    root.persistTrayState(p, h)
  }

  // --- drag-out engine (plugins only) ------------------------------------------
  //
  // hyprctl gives the cursor in global layout coordinates; windowScreenPoint
  // produces screen-local ones. A one-shot monitors fetch maps our screen's
  // global origin so both spaces line up. Single-monitor setups simply get a
  // zero offset.

  property var monitorCache: []

  Process {
    id: monitorsProcess
    command: ["hyprctl", "-j", "monitors"]
    stdout: StdioCollector { id: monitorsStdout; waitForEnd: true }
    stderr: StdioCollector {}
    onExited: {
      try {
        var parsed = JSON.parse(String(monitorsStdout.text || "[]"))
        root.monitorCache = Array.isArray(parsed) ? parsed : []
      } catch (e) {
        root.monitorCache = []
      }
    }
  }

  function monitorOffsetFor(screen) {
    var name = screen && String(screen.name || "") ? String(screen.name) : ""
    for (var i = 0; i < root.monitorCache.length; i++) {
      if (String(root.monitorCache[i].name || "") === name)
        return { x: Number(root.monitorCache[i].x) || 0, y: Number(root.monitorCache[i].y) || 0 }
    }
    return { x: 0, y: 0 }
  }

  Timer {
    id: cursorPollTimer
    interval: 40
    repeat: true
    running: root.dragActive && root.dragKind === "plugin"
    onTriggered: {
      if (cursorPosProcess.running) return
      cursorPosProcess.running = true
    }
  }

  Process {
    id: cursorPosProcess
    command: ["hyprctl", "cursorpos"]
    stdout: StdioCollector { id: cursorStdout; waitForEnd: true }
    stderr: StdioCollector {}
    onExited: {
      if (!root.dragActive || root.dragKind !== "plugin") return
      // Output format: "<x>, <y>"
      var match = /(-?\d+)\D+(-?\d+)/.exec(String(cursorStdout.text || ""))
      if (!match) return
      root.updateBarDropTarget(Number(match[1]), Number(match[2]))
    }
  }

  function updateBarDropTarget(globalX, globalY) {
    var win = button.QsWindow ? button.QsWindow.window : null
    if (!root.bar || !win) return
    var off = root.monitorOffsetFor(win.screen)
    var lx = globalX - off.x
    var ly = globalY - off.y

    var origin
    try {
      origin = root.bar.windowScreenPoint({ x: 0, y: 0 }, win)
    } catch (e) {
      return
    }

    var slots = root.bar.moduleSlots || []
    var best = null
    var bestDist = Infinity
    for (var i = 0; i < slots.length; i++) {
      var slot = slots[i]
      if (!slot || !slot.visible || slot.width <= 0 || slot.height <= 0) continue
      var name = String(slot.moduleName || "")
      if (!name || name === root.moduleName || name === root.dragId) continue

      var scene
      try {
        scene = slot.mapToItem(null, 0, 0)
      } catch (e2) {
        continue
      }
      var rx = origin.x + scene.x
      var ry = origin.y + scene.y

      var dx = Math.max(rx - lx, 0, lx - (rx + slot.width))
      var dy = Math.max(ry - ly, 0, ly - (ry + slot.height))
      var dist = dx * dx + dy * dy
      if (dist < bestDist) {
        bestDist = dist
        best = {
          region: String(slot.region || ""),
          anchorName: name,
          after: root.vertical ? ly > ry + slot.height / 2 : lx > rx + slot.width / 2,
          dist: dist
        }
      }
    }

    root.barDropTarget = best && bestDist <= Style.space(28) * Style.space(28) ? best : null
  }

  // --- external drop zone ------------------------------------------------------
  //
  // The bar natively press-drags any module (barDragSource + scene coords in
  // bar-window space). While such a drag is live we treat two regions as the
  // drawer's drop zone: the chevron itself, and — while the card is open —
  // the strip of screen just below the bar where the card sits. When the drag
  // ends over either, the source module is tucked into the drawer. A drop
  // exactly on our slot makes the bar try to reorder next to us first, which
  // is a safe no-op once the module left the layout.

  readonly property bool extDragActive: root.bar ? root.bar.barDragSource !== null : false
  property string extDragId: ""
  property bool extOverZone: false

  onExtDragActiveChanged: {
    if (root.extDragActive) {
      var slot = root.bar ? root.bar.barDragSource : null
      root.extDragId = slot && slot.moduleName ? String(slot.moduleName) : ""
      root.extOverZone = false
      return
    }
    var id = root.extDragId
    var over = root.extOverZone
    root.extDragId = ""
    root.extOverZone = false
    if (over && id && id !== root.moduleName && root.registryWidgets[id] && root.layoutHasId(id))
      root.setDrawer(id, true)
  }

  function updateExtZone() {
    if (!root.extDragActive || !root.bar) return
    var x = root.bar.barDragSceneX
    var y = root.bar.barDragSceneY

    // Chevron hit area, padded a little for forgiving drops.
    var pad = Style.space(3)
    var local
    try {
      local = button.mapFromItem(null, x, y)
    } catch (e) {
      return
    }
    if (local.x >= -pad && local.x <= button.width + pad
        && local.y >= -pad && local.y <= button.height + pad) {
      root.extOverZone = true
      return
    }

    // The open card itself. Bar drags hold the pointer grab, so hover handlers
    // on the popup never fire — compare scene coordinates against the card's
    // real anchored rectangle instead (anchor.rect lives in the same bar-window
    // space as barDragSceneX/Y).
    if (!root.menuOpen) {
      root.extOverZone = false
      return
    }
    var cw = menuPopup.contentWidth
    var ch = menuPopup.height
    var cardX = null
    var cardY = null
    try {
      cardX = Number(menuPopup.anchor.rect.x)
      cardY = Number(menuPopup.anchor.rect.y)
    } catch (e2) {
      cardX = null
    }
    if (isNaN(cardX) || isNaN(cardY)) {
      root.extOverZone = false
      return
    }
    root.extOverZone = x >= cardX && x <= cardX + cw && y >= cardY - Style.space(4)
      && y <= cardY + ch
  }

  Connections {
    target: root.bar
    function onBarDragSceneXChanged() { root.updateExtZone() }
    function onBarDragSceneYChanged() { root.updateExtZone() }
  }

  // --- icons -------------------------------------------------------------------
  //
  // There is no icon field in Omarchy's plugin system, so plugin faces come
  // from a fallback chain:
  //   1. "icons" overrides map on our layout entry,
  //   2. optional manifest icon (glyph string or image path),
  //   3. the widget's real bar glyph, extracted from the mounted instance,
  //   4. a letter avatar.
  // Tray tiles always use the item's real icon.

  function isGlyphString(s) {
    if (!s || s.length === 0 || s.length > 4) return false
    for (var i = 0; i < s.length; i++) {
      var cp = s.codePointAt(i)
      if (cp > 0xFFFF) i++
      var privateUse = (cp >= 0xE000 && cp <= 0xF8FF)
        || (cp >= 0xF0000 && cp <= 0xFFFFD)
        || (cp >= 0x100000 && cp <= 0x10FFFD)
      if (!privateUse) return false
    }
    return true
  }

  // Breadth-first so the widget's main button glyph wins over nested ones.
  function findGlyphBFS(inst) {
    if (!inst) return ""
    var queue = [inst]
    while (queue.length > 0) {
      var item = queue.shift()
      if (!item || typeof item !== "object") continue
      var t = item["text"]
      if (typeof t === "string" && root.isGlyphString(t)) return t
      var g = item["iconText"]
      if (typeof g === "string" && root.isGlyphString(g)) return g
      var kids = item.children
      if (kids) for (var i = 0; i < kids.length; i++) queue.push(kids[i])
    }
    return ""
  }

  function absoluteIconPath(id, value) {
    var v = String(value || "")
    if (v.indexOf("/") === 0 || v.indexOf("file:") === 0) return v
    var manifest = root.pluginManifest(id)
    var dir = manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : ""
    return dir ? dir + "/" + v : v
  }

  function avatarLetter(name) {
    var n = String(name || "")
    for (var i = 0; i < n.length; i++) {
      var c = n.charAt(i)
      if (/[A-Za-z0-9]/.test(c)) return c.toUpperCase()
    }
    return "?"
  }

  function resolvePluginIcon(id) {
    void root.iconRevision
    var overrideValue = root.iconOverrides[String(id || "")]
    var declared = String(overrideValue || "")
    if (!declared) {
      var manifest = root.pluginManifest(id)
      declared = String((manifest && manifest.icon) || (manifest && manifest.barWidget && manifest.barWidget.icon) || "")
    }
    if (declared) {
      if (root.isGlyphString(declared)) return { kind: "glyph", value: declared }
      return { kind: "image", value: root.absoluteIconPath(id, declared) }
    }
    var extracted = root.findGlyphBFS(root.mountedItem(id))
    if (extracted) return { kind: "glyph", value: extracted }
    return { kind: "letter", value: root.avatarLetter(root.displayName(id)) }
  }

  // Bumped whenever the card opens so dynamic glyphs (mute states, VPN icons)
  // are re-extracted fresh instead of frozen at mount time.
  property int iconRevision: 0

  // --- menu state --------------------------------------------------------------

  property bool menuOpen: false
  readonly property bool opened: menuOpen

  function open() {
    root.tileDragCancel()
    root.hoveredTileLabel = ""
    if (root.trayMenuMode) root.closeTrayMenu()
    root.iconRevision++
    root.menuOpen = true
  }

  function close() {
    root.tileDragCancel()
    root.hoveredTileLabel = ""
    if (root.trayMenuMode) root.closeTrayMenu()
    root.menuOpen = false
    root.manageRevision++
  }

  // Kept as the cheap "config changed" tick used by the live-config readers.
  property int manageRevision: 0

  // --- layout ------------------------------------------------------------------

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // The chevron points toward wherever the overflow appears, based purely on
  // where the bar sits: top bar -> down, bottom -> up, left -> right,
  // right -> left.
  readonly property string chevronGlyph: root.vertical
    ? (bar && bar.position === "left" ? "\uf054" : "\uf053")
    : (bar && bar.position === "bottom" ? "\uf077" : "\uf078")

  // Invisible host at the button's spot: tucked-away plugins stay mounted here
  // so their services keep running and their panels can be toggled anchored
  // under the drawer.
  Item {
    id: hiddenHost
    anchors.fill: button
    visible: false

    Repeater {
      model: root.hiddenIds
      DrawerWidget {}
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    scale: root.extOverZone ? 1.18 : 1.0
    Behavior on scale {
      NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
    }
    text: root.chevronGlyph
    tooltipText: "Den"
    onPressed: function(b) {
      if (b !== Qt.LeftButton) return
      if (root.menuOpen) root.close()
      else root.open()
    }
  }

  Rectangle {
    anchors.fill: button
    anchors.margins: -Style.space(2)
    radius: Math.max(4, Style.cornerRadius)
    color: Util.alpha(Color.accent, root.extOverZone ? 0.45 : 0.22)
    border.width: root.extOverZone ? 1.5 : 1
    border.color: Color.accent
    visible: root.extOverZone || root.extDragActive
  }

  property var mountedMap: ({})

  function registerMounted(id, item) {
    var m = root.mountedMap
    m[id] = item
    root.mountedMap = m
  }

  function unregisterMounted(id) {
    var m = root.mountedMap
    delete m[id]
    root.mountedMap = m
  }

  function mountedItem(id) {
    return root.mountedMap[id]
  }

  // Closing the card first and opening the widget panel on the next tick keeps
  // the two popups' HyprlandFocusGrabs from overlapping — otherwise a panel
  // can open and instantly lose its grab.
  property string pendingPanelId: ""

  Timer {
    id: panelOpenTimer
    interval: 160
    onTriggered: root.openWidgetNow(root.pendingPanelId)
  }

  function openWidget(id) {
    root.pendingPanelId = String(id || "")
    root.menuOpen = false
    panelOpenTimer.restart()
  }

  function openWidgetNow(id) {
    var w = root.mountedItem(id)
    if (w) {
      var toggled = false
      if (typeof w.toggle === "function") {
        w.toggle()
        toggled = true
      } else if ("popupOpen" in w) {
        w.popupOpen = !w.popupOpen
        toggled = true
      } else if ("opened" in w && typeof w.open === "function" && typeof w.close === "function") {
        if (w.opened) w.close()
        else w.open()
        toggled = true
      } else if ("menuOpen" in w && typeof w.open === "function" && typeof w.close === "function") {
        if (w.menuOpen) w.close()
        else w.open()
        toggled = true
      } else if (typeof w.open === "function" && typeof w.close === "function") {
        w.open()
        toggled = true
      }
      if (!toggled && root.bar && typeof root.bar.shell.toggle === "function") {
        root.bar.shell.toggle(id, "{}")
      }
    }
  }

  component DrawerWidget: Item {
    id: slot
    required property int index
    required property var modelData
    readonly property string widgetId: String(modelData || "")
    readonly property var component: root.registryWidgets[widgetId] ? root.registryWidgets[widgetId].component : null

    implicitWidth: loader.item ? loader.item.implicitWidth : root.button.implicitWidth
    implicitHeight: loader.item ? loader.item.implicitHeight : root.button.implicitHeight

    Loader {
      id: loader
      anchors.fill: parent
      sourceComponent: slot.component
      onLoaded: {
        var w = loader.item
        if (!w) return
        if ("bar" in w) w.bar = root.bar
        if ("moduleName" in w) w.moduleName = slot.widgetId
        if ("settings" in w) w.settings = root.defaultsFor(slot.widgetId)
        if ("anchorItem" in w) w.anchorItem = root.button
        root.registerMounted(slot.widgetId, w)
      }
    }

    Component.onDestruction: {
      if (root) root.unregisterMounted(slot.widgetId)
    }
  }

  // --- dropdown card -----------------------------------------------------------

  PopupCard {
    id: menuPopup
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.menuOpen
    // Click-away dismissal routes through owner.close(), but a lost release
    // (e.g. the shell restarting mid-gesture) could otherwise leave the eject
    // strip stuck on screen.
    onVisibleChanged: if (!visible) root.tileDragCancel()
    contentWidth: menuPopup.fittedContentWidth(Style.space(184))
    contentHeight: menuPopup.fittedContentHeight(
      headerRow.implicitHeight + Style.space(6)
      + bodyFlick.height
      + footerRow.height + Style.space(8),
      Style.space(340))

    Rectangle {
      id: ejectStrip
      z: 30
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      height: root.ejectStripHeight
      radius: Math.max(2, Style.cornerRadius)
      color: Util.alpha(Color.accent, root.ejectArmed ? 0.40 : 0.14)
      border.width: root.ejectArmed ? 1.5 : 1
      border.color: Color.accent
      visible: root.dragActive

      Text {
        anchors.centerIn: parent
        text: root.ejectArmed ? "Release to show" : "Drop here to show on bar"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: root.ejectArmed
      }
    }

    Column {
      id: menuColumn
      anchors.fill: parent
      spacing: Style.space(4)

      Item {
        id: headerRow
        width: menuColumn.width
        implicitHeight: 20

        Button {
          id: backBtn
          visible: root.trayMenuMode
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: parent.left
          text: "\u2039 Back"
          foreground: root.foreground
          horizontalPadding: 8
          verticalPadding: 2
          fontSize: Style.font.bodySmall
          onClicked: {
            if (root.menuLevelSettling) return
            if (root.submenuDepth > 0) {
              bodyFlick.contentY = 0
              root.leaveSubmenu()
            } else {
              root.closeTrayMenu()
            }
          }
        }

        Text {
          id: titleText
          // Idle grid shows no title — the tile count lives bottom-right. The
          // name here is only the menu view's wayfinding (which app you're in).
          visible: root.trayMenuMode
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: backBtn.visible ? backBtn.right : parent.left
          anchors.leftMargin: backBtn.visible ? Style.space(8) : 0
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8)
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: root.submenuDepth > 0 ? root.currentTitle : root.activeTrayName
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
      }

      Flickable {
        id: bodyFlick
        width: menuColumn.width
        height: {
          if (root.trayMenuMode)
            return Math.min(menuCol.implicitHeight, Style.space(300))
          return root.trayOverflowItems.length + root.hiddenIds.length > 0
            ? Math.min(gridCol.implicitHeight, Style.space(264))
            : Style.space(72)
        }
        contentWidth: width
        contentHeight: Math.max(root.trayMenuMode ? menuCol.implicitHeight : gridCol.implicitHeight, height)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height && !root.dragActive

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        // Icon-grid view.
        Column {
          id: gridCol
          visible: !root.trayMenuMode
          width: bodyFlick.width
          spacing: 0

          Flow {
            id: bodyContent
            width: gridCol.width
            spacing: root.gridSpacing

            Repeater {
              model: root.trayOverflowItems
              DrawerTile { tileIsTray: true }
            }

            Repeater {
              model: root.hiddenIds
              DrawerTile { tileIsTray: false }
            }
          }

          Text {
            visible: root.trayOverflowItems.length === 0 && root.hiddenIds.length === 0
            width: gridCol.width
            text: "Nothing tucked away.\nHold a bar widget and drop it\non the chevron to hide it."
            horizontalAlignment: Text.AlignHCenter
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
            wrapMode: Text.WordWrap
          }
        }

        // Inline app-menu view: swaps in for the grid when a tray tile's
        // menu is opened, submenus drill down in place.
        Column {
          id: menuCol
          visible: root.trayMenuMode
          width: bodyFlick.width
          spacing: 0

          Repeater {
            model: root.currentChildren
            TrayMenuRow {}
          }
        }

        // Free-floating ghost: follows the cursor loosely while dragging.
        Rectangle {
          id: dragGhost
          visible: root.dragActive
          z: 25
          x: root.dragGhostX
          y: root.dragGhostY
          width: root.tileSize
          height: root.tileSize
          radius: Math.max(4, Style.cornerRadius)
          color: Util.alpha(Color.accent, 0.30)
          border.width: 1.5
          border.color: Color.accent
          opacity: root.ejectArmed ? 0.75 : 0.95

          TileFace {
            id: ghostFace
            anchors.fill: parent
            faceKind: root.dragKind
            faceItem: root.dragKind === "tray" ? root.trayItemById(root.dragId) : null
            faceInfo: root.dragKind === "plugin" ? root.resolvePluginIcon(root.dragId) : null
          }
        }
      }

      Item {
        id: footerRow
        width: menuColumn.width
        height: Style.space(16)

        Text {
          id: footerLabel
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: parent.left
          anchors.right: countLabel.visible ? countLabel.left : parent.right
          anchors.rightMargin: Style.space(8)
          height: parent.height
          verticalAlignment: Text.AlignVCenter
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: {
            if (root.dragActive && root.dragKind === "plugin") {
              var t = root.barDropTarget
              if (t) return (t.after ? "after " : "before ") + root.displayName(String(t.anchorName))
              if (root.ejectArmed) return "Release for end of bar"
            }
            if (root.dragActive && root.dragKind === "tray" && root.ejectArmed)
              return "Release to pin on bar"
            if (root.dragActive && root.reorderTargetKey) return "Move here"
            return root.hoveredTileLabel
          }
          color: Qt.darker(root.foreground, 1.35)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          id: countLabel
          visible: !root.trayMenuMode
          anchors.verticalCenter: parent.verticalCenter
          anchors.right: parent.right
          text: {
            var total = root.trayOverflowItems.length + root.hiddenIds.length
            return total > 0 ? String(total) : ""
          }
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  property string hoveredTileLabel: ""

  // --- tile components ---------------------------------------------------------

  component TileFace: Item {
    id: face
    property string faceKind: ""
    property var faceItem: null
    property var faceInfo: null

    TrayIcon {
      anchors.centerIn: parent
      width: Style.space(19)
      height: Style.space(19)
      icon: face.faceItem ? face.faceItem.icon : ""
      visible: face.faceKind === "tray"
    }

    Image {
      visible: face.faceKind === "plugin" && face.faceInfo && face.faceInfo.kind === "image"
      anchors.centerIn: parent
      width: Style.space(20)
      height: Style.space(20)
      fillMode: Image.PreserveAspectFit
      sourceSize.width: Math.round(width * Screen.devicePixelRatio)
      sourceSize.height: Math.round(height * Screen.devicePixelRatio)
      source: face.faceInfo && face.faceInfo.kind === "image" ? String(face.faceInfo.value || "") : ""
    }

    Text {
      visible: face.faceKind === "plugin" && face.faceInfo && face.faceInfo.kind === "glyph"
      anchors.centerIn: parent
      text: face.faceInfo && face.faceInfo.kind === "glyph" ? String(face.faceInfo.value || "") : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Math.round(root.tileSize * 0.56)
    }

    Rectangle {
      visible: face.faceKind === "plugin" && face.faceInfo && face.faceInfo.kind === "letter"
      anchors.centerIn: parent
      width: Style.space(24)
      height: Style.space(24)
      radius: width / 2
      color: Util.alpha(Color.accent, 0.32)

      Text {
        anchors.centerIn: parent
        text: face.faceInfo && face.faceInfo.kind === "letter" ? String(face.faceInfo.value || "?") : "?"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Math.round(root.tileSize * 0.38)
        font.bold: true
      }
    }
  }

  component DrawerTile: Rectangle {
    id: tile
    required property int index
    required property var modelData
    property bool tileIsTray: false

    // Which Repeater this delegate came from; tray items are objects with an
    // .id, plugin entries are plain id strings.
    readonly property string trayId: tileIsTray ? String(modelData.id || "") : ""
    readonly property string pluginId: !tileIsTray ? String(modelData || "") : ""
    readonly property string key: tileIsTray ? trayId : pluginId
    readonly property string tileLabel: tileIsTray
      ? root.trayItemName(modelData)
      : root.displayName(pluginId)

    width: root.tileSize
    height: root.tileSize
    radius: Math.max(4, Style.cornerRadius)
    color: root.dragActive
      ? (root.dragId === key ? Util.alpha(Color.accent, 0.30) : "transparent")
      : (tileMouse.containsMouse
          ? Style.hoverFillFor(root.foreground, root.foreground)
          : "transparent")
    // The dragged tile gets a soft border; the slot it would land in gets a
    // bright accent ring.
    border.width: root.dragActive && (root.dragId === key || root.reorderTargetKey === key) ? 1.5 : 0
    border.color: Color.accent

    opacity: root.dragActive && root.dragId === key ? 0.45 : 1.0

    TileFace {
      anchors.fill: parent
      faceKind: tile.tileIsTray ? "tray" : "plugin"
      faceItem: tile.tileIsTray ? tile.modelData : null
      faceInfo: tile.tileIsTray ? null : root.resolvePluginIcon(tile.pluginId)
    }

    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      preventStealing: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      cursorShape: root.dragActive ? Qt.ClosedHandCursor : Qt.PointingHandCursor

      property real pressX: 0
      property real pressY: 0
      property bool moved: false

      onEntered: root.hoveredTileLabel = tile.tileLabel
      onExited: if (root.hoveredTileLabel === tile.tileLabel) root.hoveredTileLabel = ""

      onPressed: function(mouse) {
        if (mouse.button !== Qt.LeftButton) return
        tileMouse.moved = false
        tileMouse.pressX = mouse.x
        tileMouse.pressY = mouse.y
      }

      onPositionChanged: function(mouse) {
        if (!(mouse.buttons & Qt.LeftButton)) return
        if (!tileMouse.moved) {
          var dist = Math.abs(mouse.x - tileMouse.pressX) + Math.abs(mouse.y - tileMouse.pressY)
          if (dist < root.dragThreshold) return
          tileMouse.moved = true
          // Arming happens lazily: a plain click never touches drag state.
          root.tileDragStart(tile.tileIsTray ? "tray" : "plugin", tile.key, tileMouse, mouse.x, mouse.y)
        }
        root.tileDragMove(tileMouse, mouse.x, mouse.y)
      }

      onReleased: {
        if (root.dragActive) root.tileDragEnd()
      }

      onCanceled: root.tileDragCancel()

      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) {
          mouse.accepted = true
          if (tileMouse.moved) return
          if (tile.tileIsTray) root.openTrayMenu(tile.modelData, tile, mouse)
          else root.ejectPlugin(tile.pluginId)
        } else if (mouse.button === Qt.MiddleButton) {
          if (tile.tileIsTray) tile.modelData.secondaryActivate()
        } else if (!tileMouse.moved) {
          if (tile.tileIsTray) {
            if (tile.modelData.onlyMenu) root.openTrayMenu(tile.modelData, tile, mouse)
            else tile.modelData.activate()
          } else {
            root.openWidget(tile.pluginId)
          }
        }
      }

      onWheel: function(wheel) {
        if (tile.tileIsTray) tile.modelData.scroll(wheel.angleDelta.y, false)
      }
    }
  }

  // Renders a tray icon, recoloring symbolic icons to the foreground.
  component TrayIcon: Item {
    id: trayIconRoot
    required property var icon
    readonly property bool symbolic: root.iconIsSymbolic(icon)

    Image {
      id: trayIconImage
      anchors.fill: parent
      fillMode: Image.PreserveAspectFit
      sourceSize.width: Math.round(Math.min(width, height) * Screen.devicePixelRatio)
      sourceSize.height: Math.round(Math.min(width, height) * Screen.devicePixelRatio)
      source: root.safeIconSource(trayIconRoot.icon)
      visible: !trayIconRoot.symbolic
      layer.enabled: trayIconRoot.symbolic
    }

    MultiEffect {
      anchors.fill: trayIconImage
      source: trayIconImage
      visible: trayIconRoot.symbolic
      colorization: 1.0
      colorizationColor: root.foreground
    }
  }

  // --- tray menus (inline) ------------------------------------------------------
  //
  // QsMenuEntry.display() renders a platform menu, which Quickshell refuses
  // without QApplication mode, so app menus render INSIDE this card: picking
  // one swaps the tile grid for menu rows, submenus drill down in place, and
  // Back returns to the grid. One window, one focus grab — right-click can
  // never race a second popup again.

  property var activeTrayItem: null
  property bool trayMenuMode: false
  property var submenuStack: []
  readonly property int submenuDepth: submenuStack.length
  readonly property string currentTitle: submenuDepth > 0 ? submenuStack[submenuDepth - 1].title : ""
  readonly property var currentChildren: submenuDepth > 0
    ? submenuStack[submenuDepth - 1].opener.children
    : trayMenuOpener.children

  readonly property string activeTrayName: activeTrayItem ? root.trayItemName(activeTrayItem) : ""

  property bool menuLevelSettling: false

  Component {
    id: submenuOpenerComponent
    QsMenuOpener {}
  }

  Timer {
    id: menuLevelSettleTimer
    interval: 250
    onTriggered: root.menuLevelSettling = false
  }

  function settleMenuLevel() {
    menuLevelSettling = true
    menuLevelSettleTimer.restart()
  }

  function resetTrayMenu() {
    menuLevelSettling = false
    menuLevelSettleTimer.stop()
    bodyFlick.contentY = 0
    var openers = submenuStack
    submenuStack = []
    for (var i = openers.length - 1; i >= 0; i--) openers[i].opener.destroy()
  }

  function enterSubmenu(entry, title) {
    var opener = submenuOpenerComponent.createObject(root, { menu: entry })
    if (!opener) return
    var stack = root.submenuStack.slice()
    stack.push({ opener: opener, title: title })
    root.submenuStack = stack
    root.settleMenuLevel()
  }

  function leaveSubmenu() {
    if (root.submenuStack.length === 0) return
    var stack = root.submenuStack.slice()
    var top = stack.pop()
    root.submenuStack = stack
    top.opener.destroy()
    root.settleMenuLevel()
  }

  // Leave the menu view and show the icon grid again.
  function closeTrayMenu() {
    root.resetTrayMenu()
    root.trayMenuMode = false
  }

  function iconIsSymbolic(icon) {
    var name = String(icon || "").split("?")[0]
    return name.slice(-9) === "-symbolic"
  }

  function openTrayMenu(item, anchorItem, mouse) {
    if (!item) return
    if (!item.menu) {
      // Rare apps expose no D-Bus menu object: fall through to the platform
      // popup, which needs the click coordinates from the tile.
      if (anchorItem && mouse) {
        try {
          var point = anchorItem.QsWindow.contentItem.mapFromItem(anchorItem, mouse.x, mouse.y)
          item.display(anchorItem.QsWindow.window, point.x, point.y)
        } catch (e) {
        }
      }
      return
    }
    root.resetTrayMenu()
    root.activeTrayItem = item
    root.trayMenuMode = true
  }

  QsMenuOpener {
    id: trayMenuOpener
    menu: root.activeTrayItem ? root.activeTrayItem.menu : null
  }

  // A single menu entry row: separators, checkmarks, icons, labels, and
  // submenu glyphs all render here instead of in a platform popup.
  component TrayMenuRow: Item {
    id: menuRow
    required property var modelData
    required property int index
    width: menuCol.width
    implicitHeight: modelData.isSeparator ? Style.space(11) : Style.space(30)
    opacity: modelData.enabled ? 1.0 : 0.45

    readonly property string rowText: String(modelData.text || "")
    readonly property bool atRoot: root.submenuDepth === 0
    readonly property string rootAppTitle: root.activeTrayItem ? String(root.activeTrayItem.title || root.activeTrayItem.id || "") : ""
    readonly property bool rootTitleEntry: atRoot && index === 0 && modelData.hasChildren && rowText.toLowerCase() === rootAppTitle.toLowerCase()
    readonly property bool leadingSeparator: atRoot && modelData.isSeparator && index <= 1
    readonly property bool hiddenRow: rootTitleEntry || leadingSeparator

    visible: !hiddenRow
    height: hiddenRow ? 0 : implicitHeight

    Rectangle {
      visible: menuRow.modelData.isSeparator
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: 1
      color: Color.popups.border
      opacity: 0.45
    }

    Rectangle {
      visible: !menuRow.modelData.isSeparator
      anchors.fill: parent
      radius: Math.max(2, Style.cornerRadius)
      color: menuRowMouse.containsMouse && menuRow.modelData.enabled ? Style.hoverFillFor(root.foreground, root.foreground) : "transparent"
    }

    Text {
      visible: !menuRow.modelData.isSeparator && menuRow.modelData.buttonType !== QsMenuButtonType.None
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      width: Style.space(22)
      horizontalAlignment: Text.AlignHCenter
      text: menuRow.modelData.checkState === Qt.Checked ? "\uf00c" : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Image {
      id: menuEntryIcon
      visible: !menuRow.modelData.isSeparator && String(menuRow.modelData.icon || "") !== ""
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: Style.space(24)
      width: Style.space(16)
      height: Style.space(16)
      fillMode: Image.PreserveAspectFit
      sourceSize.width: width * Screen.devicePixelRatio
      sourceSize.height: height * Screen.devicePixelRatio
      source: root.safeIconSource(menuRow.modelData.icon)
    }

    Text {
      visible: !menuRow.modelData.isSeparator
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: menuEntryIcon.visible ? Style.space(46) : Style.space(28)
      anchors.right: submenuGlyph.left
      anchors.rightMargin: Style.space(8)
      textFormat: Text.PlainText
      text: menuRow.rowText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Text {
      id: submenuGlyph
      visible: !menuRow.modelData.isSeparator && menuRow.modelData.hasChildren
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      text: "\u203a"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      id: menuRowMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: !menuRow.modelData.isSeparator && menuRow.modelData.enabled
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: {
        if (root.menuLevelSettling) return
        if (menuRow.modelData.hasChildren) {
          bodyFlick.contentY = 0
          root.enterSubmenu(menuRow.modelData, menuRow.rowText)
        } else {
          menuRow.modelData.triggered()
          root.close()
        }
      }
    }
  }

  // --- config sync -------------------------------------------------------------
  //
  // A plugin listed in the drawer must not render on the bar, but stays
  // enabled (moved into plugins[]) so its service keeps running and the
  // drawer can mount it. Showing it does the reverse.

  function layoutHasId(id) {
    var shell = root.bar && root.bar.shell
    var config = shell ? shell.shellConfig : null
    return DenModel.layoutHas(config, id)
  }

  function pluginsHasId(id) {
    var shell = root.bar && root.bar.shell
    var config = shell ? shell.shellConfig : null
    return DenModel.pluginsHas(config, id)
  }

  function persistWidgets(list) {
    var id = root.moduleName
    root.mutateConfig(function(c) {
      if (!c || !c.bar || !c.bar.layout) return
      var sections = DenModel.sections()
      for (var s = 0; s < sections.length; s++) {
        var arr = DenModel.sectionEntries(c, sections[s])
        for (var k = 0; k < arr.length; k++) {
          if (arr[k] && DenModel.entryId(arr[k]) === id) {
            arr[k].widgets = list.slice()
            return
          }
        }
      }
    })
  }

  function mutateConfig(mutator) {
    var shell = root.bar && root.bar.shell
    if (!shell || typeof shell.mutateShellConfig !== "function") return
    shell.mutateShellConfig(mutator)
  }

  function removeFromLayoutAndKeepEnabled(key) {
    var shell = root.bar && root.bar.shell
    if (!shell || !shell.shellConfig) return
    var inLayout = root.layoutHasId(key)
    var inPlugins = root.pluginsHasId(key)
    if (!inLayout && inPlugins) return
    var sections = DenModel.sections()
    root.mutateConfig(function(c) {
      if (!c) return
      if (c.bar && c.bar.layout) {
        for (var s = 0; s < sections.length; s++) {
          var a = c.bar.layout[sections[s]]
          if (!Array.isArray(a)) continue
          var kept = []
          for (var j = 0; j < a.length; j++) {
            if (!(a[j] && DenModel.entryId(a[j]) === key)) kept.push(a[j])
          }
          c.bar.layout[sections[s]] = kept
        }
      }
      if (!Array.isArray(c.plugins)) c.plugins = []
      var exists = false
      for (var k = 0; k < c.plugins.length; k++) {
        if (c.plugins[k] && DenModel.entryId(c.plugins[k]) === key) { exists = true; break }
      }
      if (!exists) c.plugins.push({ id: key })
    })
  }

  // Return a plugin to the layout. With an anchor slot (from a drag-out
  // release over the bar) it inserts exactly before/after it; without one it
  // lands at the right-section end, just before omarchy.power.
  function removeFromPluginsAndAddToLayout(key, region, anchorName, after) {
    var shell = root.bar && root.bar.shell
    if (!shell || !shell.shellConfig) return
    var inLayout = root.layoutHasId(key)
    var inPlugins = root.pluginsHasId(key)
    if (inLayout && !inPlugins) return
    var targetRegion = String(region || "")
    if (targetRegion !== "left" && targetRegion !== "center" && targetRegion !== "right")
      targetRegion = "right"
    var anchor = String(anchorName || "")
    root.mutateConfig(function(c) {
      if (!c) return
      if (Array.isArray(c.plugins)) {
        var kept = []
        for (var j = 0; j < c.plugins.length; j++) {
          if (!(c.plugins[j] && DenModel.entryId(c.plugins[j]) === key)) kept.push(c.plugins[j])
        }
        c.plugins = kept
      }
      if (!inLayout && c.bar && c.bar.layout) {
        var arr = c.bar.layout[targetRegion]
        if (!Array.isArray(arr)) { arr = []; c.bar.layout[targetRegion] = arr }
        var insertAt = -1
        if (anchor) {
          for (var k = 0; k < arr.length; k++) {
            if (DenModel.entryId(arr[k]) === anchor) {
              insertAt = after === true ? k + 1 : k
              break
            }
          }
        }
        if (insertAt === -1) {
          insertAt = arr.length
          for (var m = 0; m < arr.length; m++) {
            if (arr[m] && DenModel.entryId(arr[m]) === "omarchy.power") { insertAt = m; break }
          }
        }
        insertAt = Math.max(0, Math.min(insertAt, arr.length))
        arr.splice(insertAt, 0, { id: key })
      }
    })
  }

  function setDrawer(id, hide) {
    var key = String(id || "")
    if (!key || key === root.moduleName) return
    var list = root.configuredIds.slice()
    var idx = list.indexOf(key)
    if (hide && idx === -1) list.push(key)
    else if (!hide && idx !== -1) list.splice(idx, 1)
    if (hide) root.removeFromLayoutAndKeepEnabled(key)
    else root.removeFromPluginsAndAddToLayout(key)
    root.persistWidgets(list)
  }

  // Reconcile on load: every configured id stays enabled via plugins[] so the
  // drawer can mount it. Never moves a widget off the bar by itself.
  function syncHiddenFromLayout() {
    var configured = root.configuredIds
    for (var i = 0; i < configured.length; i++) {
      root.ensureConfiguredEnabled(configured[i])
    }
  }

  function ensureConfiguredEnabled(key) {
    var shell = root.bar && root.bar.shell
    if (!shell || !shell.shellConfig) return
    if (root.layoutHasId(key)) return
    if (root.pluginsHasId(key)) return
    root.mutateConfig(function(c) {
      if (!c) return
      if (!Array.isArray(c.plugins)) c.plugins = []
      var exists = false
      for (var k = 0; k < c.plugins.length; k++) {
        if (c.plugins[k] && DenModel.entryId(c.plugins[k]) === key) { exists = true; break }
      }
      if (!exists) c.plugins.push({ id: key })
    })
  }

  property var reconcileRegistry: root.bar ? root.bar.shell.pluginRegistry : null

  onBarChanged: root.reconcileRegistry = root.bar ? root.bar.shell.pluginRegistry : null

  Connections {
    target: root.reconcileRegistry
    function onPluginsChanged() { reconcileTimer.restart() }
  }

  Timer {
    id: reconcileTimer
    interval: 150
    onTriggered: root.syncHiddenFromLayout()
  }

  Component.onCompleted: {
    root.syncHiddenFromLayout()
    reconcileTrayTimer.restart()
  }
}

// Pure helpers for so.drawer. Everything here works on plain config objects
// (the in-memory shellConfig) so it stays testable and free of QML imports.

function text(value) {
  return String(value || "").toLowerCase()
}

function entryId(entry) {
  if (typeof entry === "string") return entry
  if (entry && typeof entry === "object") {
    var id = entry.id
    if (id !== undefined && id !== null && String(id) !== "") return String(id)
  }
  return ""
}

function sections() {
  return ["left", "center", "right"]
}

function sectionEntries(config, region) {
  if (!config || !config.bar || !config.bar.layout) return []
  var arr = config.bar.layout[region]
  return Array.isArray(arr) ? arr : []
}

function findLayoutEntry(config, id) {
  var key = String(id || "")
  var regions = sections()
  for (var s = 0; s < regions.length; s++) {
    var entries = sectionEntries(config, regions[s])
    for (var i = 0; i < entries.length; i++) {
      if (entryId(entries[i]) === key) return entries[i]
    }
  }
  return null
}

// Write a single key into a widget's layout entry. The bar host reads
// settings flat (all entry keys except id), so values must live at the
// top level — not inside a nested settings sub-object.
function setEntrySetting(config, id, name, value) {
  var entry = findLayoutEntry(config, id)
  if (!entry) return
  entry[name] = value
}

function layoutHas(config, id) {
  return findLayoutEntry(config, id) !== null
}

function pluginsHas(config, id) {
  var key = String(id || "")
  if (!config || !Array.isArray(config.plugins)) return false
  for (var i = 0; i < config.plugins.length; i++) {
    if (config.plugins[i] && entryId(config.plugins[i]) === key) return true
  }
  return false
}

// The stock tray keeps its pin/hide state inline on its own layout entry.
function trayEntrySettings(config) {
  var entry = findLayoutEntry(config, "omarchy.tray")
  var pinned = entry && entry.pinned instanceof Array ? entry.pinned : []
  var hidden = entry && entry.hidden instanceof Array ? entry.hidden : []
  return { pinned: pinned, hidden: hidden }
}

// Inline settings for a widget id: its bar-layout entry if present, else its
// top-level plugins[] entry. Returns a shallow copy of every key except id,
// mirroring BarModel.entrySettings; null when neither entry exists.
function entrySettings(config, id) {
  var key = String(id || "")
  var entry = findLayoutEntry(config, key)
  if (!entry && config && Array.isArray(config.plugins)) {
    for (var i = 0; i < config.plugins.length; i++) {
      var p = config.plugins[i]
      if (p && entryId(p) === key) { entry = p; break }
    }
  }
  if (!entry || typeof entry !== "object") return null
  var copy = {}
  for (var k in entry) if (k !== "id") copy[k] = entry[k]
  return copy
}

function stringList(value) {
  var out = []
  if (!(value instanceof Array)) return out
  for (var i = 0; i < value.length; i++) {
    var v = String(value[i] || "")
    if (v) out.push(v)
  }
  return out
}

function rectContains(x, y, w, h, px, py) {
  return px >= x && px <= x + w && py >= y && py <= y + h
}

// Tray item name matching, mirroring the stock tray's TrayModel.
function itemNamed(item, name) {
  if (!item) return false
  var needle = text(name)
  return text(item.id).indexOf(needle) !== -1
    || text(item.title).indexOf(needle) !== -1
    || text(item.tooltipTitle).indexOf(needle) !== -1
}

function layoutHasWidget(layout, id) {
  if (!layout) return false
  var regions = sections()
  for (var s = 0; s < regions.length; s++) {
    var entries = layout[regions[s]]
    if (!Array.isArray(entries)) continue
    for (var i = 0; i < entries.length; i++) {
      if (entryId(entries[i]) === id) return true
    }
  }
  return false
}

function ownedByOmarchy(item, layout) {
  return itemNamed(item, "localsend")
    || (layoutHasWidget(layout, "omarchy.dropbox") && itemNamed(item, "dropbox"))
}

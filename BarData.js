// Pure helpers for Home Assistant data instances in the Omarchy bar.
//
// A child needs a distinct layout id. Omarchy's drag code resolves a source by
// id, so repeated `hass` ids make it move the main panel instead of the child.
// Child entries point back to DataBarWidget.qml as custom QML modules. They
// still use the shared hass service, but can be moved independently.

var DATA_SOURCE = "$HOME/.config/omarchy/plugins/hass/DataBarWidget.qml"
var LAYOUT_TOOL = "$HOME/.config/omarchy/plugins/hass/bin/hass-bar-layout"

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function widgetId(kind, identity) {
  return "hass.data." + String(kind || "") + "." + String(identity || "")
}

// Every reading gets its own id so the shell can drag it on its own. Omarchy
// 4.0.4 mounts such a module without plugin services; DataBarWidget gets the
// service from Bridge.js instead. Entries that still use the plugin's own id
// (written by an earlier build) are recognised, and migrate() rewrites them.
function entityEntry(entityId) {
  var identity = String(entityId || "")
  return { id: widgetId("entity", identity), source: DATA_SOURCE,
           dataKind: "entity", entityId: identity }
}

function roomEntry(deviceId) {
  var identity = String(deviceId || "")
  return { id: widgetId("room", identity), source: DATA_SOURCE,
           dataKind: "room", deviceId: identity }
}

// The bar layout as the plugin may read it: Omarchy 4.0.4 exposes the public
// bar config (`shell.barConfig`) instead of the whole shell config.
function readableConfig(shellApi) {
  if (!shellApi) return null
  if (shellApi.shellConfig) return shellApi.shellConfig
  return shellApi.barConfig ? { bar: shellApi.barConfig } : null
}

function valid(entry) {
  if (!isPlainObject(entry)) return false
  if (entry.dataKind === "entity") {
    var entityId = String(entry.entityId || "")
    return entityId !== "" && (entry.id === "hass"
      || entry.id === widgetId("entity", entityId))
  }
  if (entry.dataKind === "room") {
    var deviceId = String(entry.deviceId || "")
    return deviceId !== "" && (entry.id === "hass"
      || entry.id === widgetId("room", deviceId))
  }
  return false
}

function sameInstance(left, right) {
  if (!valid(left) || !valid(right) || left.dataKind !== right.dataKind) return false
  return left.dataKind === "entity"
    ? String(left.entityId) === String(right.entityId)
    : String(left.deviceId) === String(right.deviceId)
}

function entryId(entry) {
  if (typeof entry === "string") return entry
  return isPlainObject(entry) ? String(entry.id || "") : ""
}

function ensureLayout(config) {
  if (!isPlainObject(config.bar)) config.bar = {}
  if (!isPlainObject(config.bar.layout)) config.bar.layout = {}
  var sections = ["left", "center", "right"]
  for (var i = 0; i < sections.length; i++) {
    if (!Array.isArray(config.bar.layout[sections[i]]))
      config.bar.layout[sections[i]] = []
  }
  return config.bar.layout
}

function location(config, target) {
  if (!isPlainObject(config) || !valid(target)) return null
  var layout = config.bar && config.bar.layout
  if (!isPlainObject(layout)) return null
  var sections = ["left", "center", "right"]
  for (var s = 0; s < sections.length; s++) {
    var entries = layout[sections[s]]
    if (!Array.isArray(entries)) continue
    for (var i = 0; i < entries.length; i++) {
      if (sameInstance(entries[i], target))
        return { section: sections[s], index: i }
    }
  }
  return null
}

function contains(config, target) {
  return location(config, target) !== null
}

function canonicalEntry(target) {
  if (!valid(target)) return null
  return target.dataKind === "entity"
    ? entityEntry(target.entityId) : roomEntry(target.deviceId)
}

function migrate(config, target) {
  var found = location(config, target)
  var canonical = canonicalEntry(target)
  if (!found || !canonical) return false
  var current = config.bar.layout[found.section][found.index]
  if (JSON.stringify(current) === JSON.stringify(canonical)) return false
  config.bar.layout[found.section][found.index] = canonical
  return true
}

function add(config, target) {
  if (!isPlainObject(config) || !valid(target) || contains(config, target)) return false
  var layout = ensureLayout(config)
  var sections = ["left", "center", "right"]
  var section = "right"
  var insertAt = layout.right.length

  // Keep data instances beside the main panel entry. Put a later reading
  // after existing Home Assistant data instances so repeated additions keep
  // the order in which the user picked them.
  for (var s = 0; s < sections.length; s++) {
    var entries = layout[sections[s]]
    var mainIndex = -1
    for (var i = 0; i < entries.length; i++) {
      if (entryId(entries[i]) === "hass"
          && (!isPlainObject(entries[i]) || !entries[i].dataKind)) mainIndex = i
    }
    if (mainIndex === -1) continue
    section = sections[s]
    insertAt = mainIndex + 1
    while (insertAt < entries.length && valid(entries[insertAt])) insertAt++
    break
  }

  var copy = {}
  for (var key in target) copy[key] = target[key]
  layout[section].splice(insertAt, 0, copy)
  return true
}

function remove(config, target) {
  var found = location(config, target)
  if (!found) return false
  config.bar.layout[found.section].splice(found.index, 1)
  return true
}

// Omarchy 4.0.4 only lets a replacement bar edit the layout from QML, so a bar
// widget's mutateShellConfig returns false. The panels then run this helper,
// which applies add/remove to shell.json with the same rules and reloads the shell.
function layoutCommand(action, base64Entry) {
  var verb = action === "remove" ? "remove" : "add"
  return "python3 \"" + LAYOUT_TOOL + "\" " + verb + " " + String(base64Entry || "").replace(/[^A-Za-z0-9+/=]/g, "")
}

if (typeof module !== "undefined") module.exports = {
  readableConfig: readableConfig,
  layoutCommand: layoutCommand,
  entityEntry: entityEntry,
  roomEntry: roomEntry,
  valid: valid,
  sameInstance: sameInstance,
  contains: contains,
  migrate: migrate,
  add: add,
  remove: remove,
  widgetId: widgetId
}

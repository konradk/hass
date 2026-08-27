// Pure helpers for Home Assistant data instances in the Omarchy bar.
//
// Omarchy represents repeated widgets as independent layout entries with the
// same plugin id and different inline settings. Match the inline identity as
// well as the id so adding or removing a reading can never touch the main
// Home Assistant panel entry.

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function entityEntry(entityId) {
  return { id: "hass", dataKind: "entity", entityId: String(entityId || "") }
}

function roomEntry(deviceId) {
  return { id: "hass", dataKind: "room", deviceId: String(deviceId || "") }
}

function valid(entry) {
  if (!isPlainObject(entry) || entry.id !== "hass") return false
  if (entry.dataKind === "entity") return String(entry.entityId || "") !== ""
  if (entry.dataKind === "room") return String(entry.deviceId || "") !== ""
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

if (typeof module !== "undefined") module.exports = {
  entityEntry: entityEntry,
  roomEntry: roomEntry,
  valid: valid,
  sameInstance: sameInstance,
  contains: contains,
  add: add,
  remove: remove
}

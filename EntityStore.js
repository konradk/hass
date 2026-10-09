.pragma library

// Stateless projection of Home Assistant payloads into the indexes consumed
// by Service.qml. Transport lifecycle and QML model mutation stay in the
// service; data normalization is kept here and covered without Quickshell.

function validEntityId(value) {
  return typeof value === "string" && /^[a-z0-9_]+\.[a-z0-9_]+$/.test(value)
}

function safeKey(value) {
  return typeof value === "string" && value
    && value !== "__proto__" && value !== "constructor" && value !== "prototype"
}

function cleaned(value) {
  return typeof value === "string" ? value.trim() : ""
}

function deviceName(device) {
  if (!device || typeof device !== "object") return ""
  return cleaned(device.name_by_user) || cleaned(device.name)
    || cleaned(device.model)
}

function deviceInfo(device) {
  if (!device || typeof device !== "object") return ({})
  return {
    manufacturer: cleaned(device.manufacturer),
    model: cleaned(device.model)
  }
}

function dictionary() {
  return Object.create(null)
}

function indexStates(entities) {
  var next = {}
  if (!Array.isArray(entities)) return next
  for (var i = 0; i < entities.length; i++) {
    var entity = entities[i]
    if (entity && validEntityId(entity.entity_id)) {
      next[entity.entity_id] = entity
    }
  }
  return next
}

// Replacing an entity that is already indexed mutates the map in place and
// returns it unchanged. A real instance is mostly sensors reporting
// constantly, and copying every entity per state_changed is O(entities) of
// pure garbage on the hottest path there is; callers bump stateRevision, which
// is what actually invalidates the bindings.
//
// A genuinely new entity still gets a fresh map. That is rare, and it is the
// only case where the *set* of entities changed — which is what the bindings
// watching `states` identity (the settings device count) are asking about.
function upsertState(states, entity) {
  if (!entity || !validEntityId(entity.entity_id)) {
    return states || {}
  }
  var current = states || {}
  if (current[entity.entity_id] !== undefined) {
    current[entity.entity_id] = entity
    return current
  }
  var next = {}
  for (var key in current) next[key] = current[key]
  next[entity.entity_id] = entity
  return next
}

function removeState(states, entityId) {
  var next = {}
  var current = states || {}
  for (var key in current) {
    if (key !== entityId) next[key] = current[key]
  }
  return next
}

function projectRegistries(areas, entities, devices) {
  // Registry IDs are server-controlled. Prototype-free maps allow valid IDs
  // such as `toString` without inheriting a non-array value at that key.
  var names = dictionary()
  var areaList = Array.isArray(areas) ? areas : []
  for (var i = 0; i < areaList.length; i++) {
    var area = areaList[i]
    if (area && safeKey(area.area_id)) {
      names[area.area_id] = String(area.name || area.area_id)
    }
  }

  var deviceArea = dictionary()
  var deviceNames = dictionary()
  var deviceInfoById = dictionary()
  var deviceList = Array.isArray(devices) ? devices : []
  for (var d = 0; d < deviceList.length; d++) {
    var device = deviceList[d]
    if (device && safeKey(device.id)) {
      deviceArea[device.id] = safeKey(device.area_id) ? device.area_id : ""
      deviceNames[device.id] = deviceName(device)
      deviceInfoById[device.id] = deviceInfo(device)
    }
  }

  var mapping = dictionary()
  var entityDevice = dictionary()
  var deviceEntities = dictionary()
  var entityRegistry = dictionary()
  // Home Assistant keeps per-light favourite colours in the registry entry's
  // options, not on the entity state, so they are picked up here rather than
  // from the state snapshot. Kept raw: Model validates each entry against the
  // light's own capabilities before anything is drawn or sent.
  var favorites = dictionary()
  var entityList = Array.isArray(entities) ? entities : []
  for (var e = 0; e < entityList.length; e++) {
    var entry = entityList[e]
    if (!entry || !validEntityId(entry.entity_id)) continue
    entityRegistry[entry.entity_id] = {
      entityCategory: cleaned(entry.entity_category),
      name: cleaned(entry.name),
      originalName: cleaned(entry.original_name)
    }
    var ownArea = safeKey(entry.area_id) ? entry.area_id : ""
    var inheritedArea = safeKey(entry.device_id) ? deviceArea[entry.device_id] : ""
    var areaId = ownArea || inheritedArea || ""
    if (areaId) mapping[entry.entity_id] = areaId

    var deviceId = safeKey(entry.device_id) ? entry.device_id : ""
    if (deviceId) {
      entityDevice[entry.entity_id] = deviceId
      if (!deviceEntities[deviceId]) deviceEntities[deviceId] = []
      deviceEntities[deviceId].push(entry.entity_id)
    }

    var options = entry.options
    var lightOptions = options && typeof options === "object"
      ? options.light : null
    var saved = lightOptions && typeof lightOptions === "object"
      ? lightOptions.favorite_colors : null
    if (Array.isArray(saved)) {
      favorites[entry.entity_id] = saved
    }
  }
  return {
    areaNames: names,
    entityArea: mapping,
    favoriteColors: favorites,
    deviceNames: deviceNames,
    deviceInfo: deviceInfoById,
    deviceArea: deviceArea,
    entityDevice: entityDevice,
    deviceEntities: deviceEntities,
    entityRegistry: entityRegistry
  }
}

function sortedIds(states, displayName) {
  var ids = Object.keys(states || {})
  ids.sort(function(a, b) {
    return String(displayName(a) || a).toLowerCase()
      .localeCompare(String(displayName(b) || b).toLowerCase())
  })
  return ids
}

function computeTabs(favorites, groupByArea, areaNames, entityArea) {
  var picked = Array.isArray(favorites) ? favorites : []
  var favoriteIds = picked.map(function(id) { return String(id) })
  var favoritesTab = {
    id: "favorites",
    title: "Favorites",
    entityIds: favoriteIds
  }
  if (!groupByArea || favoriteIds.length === 0) return [favoritesTab]

  var buckets = {}
  var names = {}
  var other = []
  for (var i = 0; i < favoriteIds.length; i++) {
    var entityId = favoriteIds[i]
    var areaId = (entityArea || {})[entityId]
    var areaName = areaId ? (areaNames || {})[areaId] : ""
    if (areaId && areaName) {
      if (!buckets[areaId]) buckets[areaId] = []
      buckets[areaId].push(entityId)
      names[areaId] = areaName
    } else {
      other.push(entityId)
    }
  }

  var areaIds = Object.keys(names).sort(function(a, b) {
    return String(names[a]).toLowerCase()
      .localeCompare(String(names[b]).toLowerCase())
  })
  var grouped = []
  for (var n = 0; n < areaIds.length; n++) {
    var id = areaIds[n]
    grouped.push({ id: "area:" + id, title: names[id], entityIds: buckets[id] })
  }
  if (other.length > 0) {
    grouped.push({ id: "other", title: "Other", entityIds: other })
  }
  return grouped.length ? [favoritesTab].concat(grouped) : [favoritesTab]
}

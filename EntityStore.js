.pragma library

// Stateless projection of Loxone bridge payloads into the indexes consumed by
// Service.qml. Transport lifecycle and QML model mutation stay in the
// service; data normalization is kept here and covered without Quickshell.

// entity_id is "<domain>.<uuid>" — a Loxone control UUID keeps its hyphens, so
// this is looser than a Home Assistant slug but still anchored: a lowercase
// domain word, a dot, then only the hex/hyphen characters a Miniserver UUID is
// made of.
function validEntityId(value) {
  return typeof value === "string" && /^[a-z_]+\.[0-9a-f-]{8,}$/.test(value)
}

function safeKey(value) {
  return typeof value === "string" && value
    && value !== "__proto__" && value !== "constructor" && value !== "prototype"
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
// returns it unchanged. A Miniserver polling several dozen controls is mostly
// sensors reporting the same value, and copying every entity per poll tick is
// O(entities) of pure garbage on the hottest path there is; callers bump
// stateRevision, which is what actually invalidates the bindings.
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

// Small copy-on-write maps keyed by entity id, kept separate from `states`
// because they are local UI state the bridge never echoes back as part of an
// entity.
function withEntry(map, key, value) {
  if (!safeKey(key)) return map || {}
  var next = {}
  var current = map || {}
  for (var k in current) next[k] = current[k]
  next[key] = value
  return next
}

function withoutEntry(map, key) {
  var current = map || {}
  if (current[key] === undefined) return current
  var next = {}
  for (var k in current) {
    if (k !== key) next[k] = current[k]
  }
  return next
}

// Loxone controls carry their own room UUID directly — there is no separate
// device registry standing between an entity and its area the way Home
// Assistant has one, so this is a straight projection of the bridge's rooms
// list plus each entity's own `area_id` attribute.
function projectRegistries(rooms, entities) {
  var names = {}
  var roomList = Array.isArray(rooms) ? rooms : []
  for (var i = 0; i < roomList.length; i++) {
    var room = roomList[i]
    if (room && safeKey(room.area_id)) {
      names[room.area_id] = String(room.name || room.area_id)
    }
  }

  var mapping = {}
  var entityList = Array.isArray(entities) ? entities : []
  for (var e = 0; e < entityList.length; e++) {
    var entry = entityList[e]
    if (!entry || !validEntityId(entry.entity_id)) continue
    if (safeKey(entry.area_id)) mapping[entry.entity_id] = entry.area_id
  }
  return { areaNames: names, entityArea: mapping }
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

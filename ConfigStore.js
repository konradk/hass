.pragma library

var KEYS = [
  "baseUrl", "localUrl", "trustedNetwork", "demoMode", "favorites",
  "demoFavorites", "roomReadings", "demoRoomReadings",
  "pinnedRoomReadings", "demoPinnedRoomReadings",
  "pinnedEntities", "demoPinnedEntities",
  "panelOrder", "demoPanelOrder",
  "groupByArea", "showEntityIcons", "showPanelPinOnHover", "selectedTab",
  "displayNameOverrides", "iconOverrides"
]

function stringList(value, fallback) {
  if (!Array.isArray(value)) return fallback.slice()
  var out = []
  var seen = {}
  for (var i = 0; i < value.length; i++) {
    if (typeof value[i] === "string"
        && /^[a-z0-9_]+\.[a-z0-9_]+$/.test(value[i])
        && !seen[value[i]]) {
      seen[value[i]] = true
      out.push(value[i])
    }
  }
  return out
}

function deviceList(value) {
  if (!Array.isArray(value)) return []
  var out = []
  var seen = {}
  for (var i = 0; i < value.length; i++) {
    var id = value[i]
    if (typeof id !== "string" || !id
        || id === "__proto__" || id === "constructor" || id === "prototype"
        || !/^[A-Za-z0-9_.:-]+$/.test(id) || seen[id]) continue
    seen[id] = true
    out.push(id)
  }
  return out
}

function panelItemList(value) {
  if (!Array.isArray(value)) return []
  var out = []
  var seen = {}
  for (var i = 0; i < value.length; i++) {
    var id = value[i]
    var valid = typeof id === "string"
      && (/^[a-z0-9_]+\.[a-z0-9_]+$/.test(id)
          || /^room_reading:[A-Za-z0-9_.:-]+$/.test(id))
    if (!valid || seen[id]) continue
    seen[id] = true
    out.push(id)
  }
  return out
}

function normalizedPanelOrder(value, favorites, roomReadings) {
  var selected = {}
  for (var f = 0; f < favorites.length; f++) selected[favorites[f]] = true
  for (var r = 0; r < roomReadings.length; r++) {
    selected["room_reading:" + roomReadings[r]] = true
  }

  var requested = panelItemList(value)
  var out = []
  var included = {}
  for (var i = 0; i < requested.length; i++) {
    if (selected[requested[i]]) {
      out.push(requested[i])
      included[requested[i]] = true
    }
  }
  // Old configurations had no combined order. Preserve the existing entity
  // order and append newly selected room cards, which is where a newly starred
  // item belongs.
  for (var e = 0; e < favorites.length; e++) {
    if (!included[favorites[e]]) out.push(favorites[e])
  }
  for (var d = 0; d < roomReadings.length; d++) {
    var key = "room_reading:" + roomReadings[d]
    if (!included[key]) out.push(key)
  }
  return out
}

function selectedDevices(value, roomReadings) {
  var requested = deviceList(value)
  var selected = {}
  for (var i = 0; i < roomReadings.length; i++) selected[roomReadings[i]] = true
  return requested.filter(function(id) { return selected[id] === true })
}

function selectedEntities(value, favorites) {
  var requested = stringList(value, [])
  var selected = {}
  for (var i = 0; i < favorites.length; i++) selected[favorites[i]] = true
  return requested.filter(function(id) { return selected[id] === true })
}

function plainMap(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {}
  var out = {}
  for (var key in value) {
    if (key === "__proto__" || key === "constructor" || key === "prototype") continue
    if (typeof value[key] === "string") out[key] = value[key]
  }
  return out
}

function parse(text, demoDefaults) {
  var raw = {}
  var error = ""
  try {
    raw = text ? JSON.parse(text) : {}
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      raw = {}
      error = "config.json must contain a JSON object"
    }
  } catch (exception) {
    raw = {}
    error = "config.json is not valid JSON"
  }

  var favorites = stringList(raw.favorites, [])
  var demoFavorites = stringList(raw.demoFavorites,
                                 Array.isArray(demoDefaults) ? demoDefaults : [])
  var roomReadings = deviceList(raw.roomReadings)
  var demoRoomReadings = deviceList(raw.demoRoomReadings)

  return {
    error: error,
    config: {
      baseUrl: typeof raw.baseUrl === "string" ? raw.baseUrl : "",
      // Optional. An alternate address for the same Home Assistant instance
      // — a LAN address, say — tried first, but only on trustedNetwork. It
      // shares baseUrl's credential; it is never a separate keyring origin.
      localUrl: typeof raw.localUrl === "string" ? raw.localUrl : "",
      // The Wi-Fi network name localUrl requires a match against before it is
      // ever tried. See bin/hass-bridge's current_wifi_ssid.
      trustedNetwork: typeof raw.trustedNetwork === "string" ? raw.trustedNetwork : "",
      demoMode: raw.demoMode === true,
      favorites: favorites,
      demoFavorites: demoFavorites,
      roomReadings: roomReadings,
      demoRoomReadings: demoRoomReadings,
      pinnedRoomReadings: selectedDevices(raw.pinnedRoomReadings, roomReadings),
      demoPinnedRoomReadings: selectedDevices(
        raw.demoPinnedRoomReadings, demoRoomReadings),
      pinnedEntities: selectedEntities(raw.pinnedEntities, favorites),
      demoPinnedEntities: selectedEntities(raw.demoPinnedEntities, demoFavorites),
      panelOrder: normalizedPanelOrder(raw.panelOrder, favorites, roomReadings),
      demoPanelOrder: normalizedPanelOrder(
        raw.demoPanelOrder, demoFavorites, demoRoomReadings),
      groupByArea: raw.groupByArea === true,
      showEntityIcons: raw.showEntityIcons !== false,
      showPanelPinOnHover: raw.showPanelPinOnHover === true,
      selectedTab: typeof raw.selectedTab === "string" && raw.selectedTab
        ? raw.selectedTab : "favorites",
      displayNameOverrides: plainMap(raw.displayNameOverrides),
      iconOverrides: plainMap(raw.iconOverrides)
    }
  }
}

function merge(current, patch) {
  var result = {}
  for (var i = 0; i < KEYS.length; i++) {
    var key = KEYS[i]
    result[key] = current[key]
  }
  for (var p = 0; p < KEYS.length; p++) {
    var patchKey = KEYS[p]
    if (Object.prototype.hasOwnProperty.call(patch || {}, patchKey)) {
      result[patchKey] = patch[patchKey]
    }
  }
  return result
}

function serialize(config) {
  return JSON.stringify(config, null, 2) + "\n"
}

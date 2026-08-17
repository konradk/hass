.pragma library

var KEYS = [
  "baseUrl", "username", "verifyTls", "demoMode", "favorites", "demoFavorites",
  "groupByArea", "showEntityIcons", "selectedTab", "displayNameOverrides",
  "iconOverrides", "cameraUrl", "cameraUsername", "cameraVerifyTls"
]

function stringList(value, fallback) {
  if (!Array.isArray(value)) return fallback.slice()
  var out = []
  var seen = {}
  for (var i = 0; i < value.length; i++) {
    if (typeof value[i] === "string"
        && /^[a-z_]+\.[0-9a-f-]{8,}$/.test(value[i])
        && !seen[value[i]]) {
      seen[value[i]] = true
      out.push(value[i])
    }
  }
  return out
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

  return {
    error: error,
    config: {
      baseUrl: typeof raw.baseUrl === "string" ? raw.baseUrl : "",
      username: typeof raw.username === "string" ? raw.username : "",
      // Loxone Miniservers overwhelmingly run on a self-signed local
      // certificate; defaulting verification off matches what actually
      // works out of the box; a user with a real certificate can turn it on.
      verifyTls: raw.verifyTls === true,
      demoMode: raw.demoMode === true,
      favorites: stringList(raw.favorites, []),
      demoFavorites: stringList(raw.demoFavorites,
                                Array.isArray(demoDefaults) ? demoDefaults : []),
      groupByArea: raw.groupByArea === true,
      showEntityIcons: raw.showEntityIcons !== false,
      selectedTab: typeof raw.selectedTab === "string" && raw.selectedTab
        ? raw.selectedTab : "favorites",
      displayNameOverrides: plainMap(raw.displayNameOverrides),
      iconOverrides: plainMap(raw.iconOverrides),
      // An arbitrary HTTP(S) camera, independent of the Miniserver — see
      // Service.qml's camera functions. Only the URL and username are
      // config.json material; the password goes through the same keyring
      // path as the Miniserver's.
      cameraUrl: typeof raw.cameraUrl === "string" ? raw.cameraUrl : "",
      cameraUsername: typeof raw.cameraUsername === "string" ? raw.cameraUsername : "",
      cameraVerifyTls: raw.cameraVerifyTls === true
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

.pragma library

// Stateless view logic: raw Loxone control entities in, drawable values out.
// No QML types and no side effects, so it is testable outside the shell.
//
// Loxone has no service-bus/feature-bitmask negotiation the way Home Assistant
// does: what a control can do follows directly from its Loxone control type
// (Switch, Dimmer, Jalousie, IRoomControllerV2, ...), which the bridge already
// resolved into one of the domains below. So capability derivation here is
// domain-driven rather than bit-tested.

var TOGGLEABLE_DOMAINS = ["light", "switch"]

function attrs(entity) {
  return (entity && entity.attributes) ? entity.attributes : {}
}

function domainOf(entityId) {
  var id = String(entityId || "")
  var dot = id.indexOf(".")
  return dot === -1 ? "" : id.slice(0, dot)
}

function domain(entity) {
  return domainOf(entity ? entity.entity_id : "")
}

function name(entity) {
  var friendly = attrs(entity).friendly_name
  return cleaned(friendly) || (entity ? entity.entity_id : "")
}

function cleaned(value) {
  if (typeof value !== "string") return ""
  var trimmed = value.trim()
  return trimmed.length ? trimmed : ""
}

function stateOf(entity) {
  return entity && typeof entity.state === "string" ? entity.state : ""
}

// The bridge reports this when a poll fails or a control's Miniserver value
// cannot be parsed, mirroring the vocabulary Home Assistant users already know.
function isUnavailable(entity) {
  var state = stateOf(entity)
  return state === "unavailable" || state === "unknown"
}

// A pushbutton's state is when it was last pressed, or "unknown" — not a
// reason to grey it out.
function isAvailable(entity) {
  if (!entity) return false
  if (controlKind(entity) === "activate") return true
  return !isUnavailable(entity)
}

function isToggleable(entity) {
  return TOGGLEABLE_DOMAINS.indexOf(domain(entity)) !== -1
}

function isExpandable(entity) {
  return capabilitiesFor(entity).expandable
}

function isOn(entity) {
  var state = stateOf(entity)
  var dom = domain(entity)
  if (dom === "cover") return state === "open"
  if (dom === "climate") {
    return state !== "" && state !== "off"
      && state !== "unavailable" && state !== "unknown"
  }
  return state === "on" || state === "locked"
}

function capitalize(value) {
  var text = String(value || "")
  return text.length ? text.charAt(0).toUpperCase() + text.slice(1) : ""
}

function displayState(entity) {
  var state = stateOf(entity)
  if (isUnavailable(entity)) return capitalize(state)

  var unit = cleaned(attrs(entity).unit_of_measurement)
  if (unit) return state + " " + unit

  if (state === "on") return "On"
  if (state === "off") return "Off"
  return capitalize(state)
}

function subtitle(entity, unitFallback) {
  var dom = domain(entity)
  if (dom === "climate") return climateSubtitle(entity, unitFallback)
  if (dom === "cover") return coverSubtitle(entity)
  if (isToggleable(entity)) return displayState(entity)
  return ""
}

function coverSubtitle(entity) {
  var position = attrs(entity).position
  if (typeof position === "number") {
    return Math.round(position) + "% open"
  }
  var state = stateOf(entity)
  return state ? capitalize(state) : ""
}

function badgeText(entity) {
  var dom = domain(entity)
  if (dom === "scene") return "Trigger"
  if (dom === "cover") return coverSubtitle(entity) || capitalize(stateOf(entity))
  if (dom === "climate") {
    var current = attrs(entity).current_temperature
    if (typeof current === "number") {
      return formatTemp(current, temperatureUnit(entity)) + " now"
    }
  }
  if (isUnavailable(entity)) return capitalize(stateOf(entity))
  return displayState(entity)
}

// ---------------------------------------------------------------- light

// A Loxone Dimmer (or a LightControllerV2 sub-output) reports its position as
// a live 0-100 percent value; the bridge writes it straight into `brightness`,
// so unlike Home Assistant there is no 0-255 scale and no separate
// "supports dimming" flag to test — a reported number is the signal.
function supportsBrightness(entity) {
  return domain(entity) === "light" && typeof attrs(entity).brightness === "number"
}

function brightnessPercent(entity) {
  var value = attrs(entity).brightness
  if (typeof value !== "number") return -1
  return Math.min(Math.max(value, 0), 100)
}

// ---------------------------------------------------------------- media
//
// No Loxone control in this plugin's mapping produces domain `media_player`
// yet (the Music Server's zone API is a separate integration — see README).
// These stay defined, and unreachable, so MediaControls.qml and a future
// zone bridge have something to project onto without every caller needing to
// special-case "not supported yet".

function isPlaying(entity) {
  return playbackState(entity) === "playing"
}

function playbackState(entity) {
  var explicit = cleaned(attrs(entity).media_playback_state)
  return (explicit || stateOf(entity)).toLowerCase()
}

function volumeLevel(entity) {
  var value = attrs(entity).volume_level
  return typeof value === "number" ? value : -1
}

function capabilitiesFor(entity) {
  var dom = domain(entity)
  var a = attrs(entity)
  var activate = dom === "scene"
  var available = !!entity && (activate || !isUnavailable(entity))
  var result = {
    available: available,
    toggle: available && isToggleable(entity),
    lock: available && dom === "lock",
    activate: available && activate,
    brightness: available && supportsBrightness(entity),
    mediaPrevious: false,
    mediaPlayPause: false,
    mediaNext: false,
    mediaVolume: false,
    coverOpen: false,
    coverStop: false,
    coverClose: false,
    climateTarget: false,
    climateRange: false,
    stream: false,
    expandable: false,
    reserveExpandSlot: false
  }

  if (available && dom === "cover") {
    // Jalousie and Gate controls always answer up/stop/down — Loxone does not
    // negotiate a subset the way Home Assistant's cover feature bitmask does.
    result.coverOpen = true
    result.coverStop = true
    result.coverClose = true
  } else if (available && dom === "climate") {
    result.climateTarget = typeof a.temperature === "number"
  }

  // Cover deliberately does not contribute to expandable: its up/stop/down
  // buttons sit inline on the row itself (EntityRow), not behind a chevron —
  // a Jalousie is not a control anyone wants to tap twice to move.
  result.expandable = result.brightness || result.climateTarget
  // A room controller commonly has no live target yet right after connecting.
  // Keep the row geometry stable without pretending there is a value to edit.
  result.reserveExpandSlot = result.expandable || (!!entity && dom === "climate")
  return result
}

// ---------------------------------------------------------------- climate

// IRoomControllerV2 always works in Celsius; there is no instance-wide unit
// setting to fetch the way Home Assistant's get_config carries one. The
// `fallback` parameter still exists so callers (and their tests) can pass one,
// but Model itself has nothing to negotiate.
function temperatureUnit(entity, fallback) {
  var a = attrs(entity)
  return cleaned(a.temperature_unit) || cleaned(a.unit_of_measurement)
    || cleaned(fallback) || "°C"
}

function formatTemp(value, unit) {
  if (typeof value !== "number") return ""
  var rounded = Math.round(value)
  var text = Math.abs(rounded - value) < 0.01
    ? String(rounded)
    : value.toFixed(1)
  return unit ? text + unit : text
}

function climateSubtitle(entity, unitFallback) {
  var a = attrs(entity)
  var unit = temperatureUnit(entity, unitFallback)
  var parts = []

  if (typeof a.temperature === "number") {
    parts.push("Target " + formatTemp(a.temperature, unit))
  }
  if (typeof a.current_temperature === "number") {
    parts.push("Now " + formatTemp(a.current_temperature, unit))
  }
  return parts.join(" · ")
}

// The comfort-temperature step Loxone's own app uses.
function temperatureStep(entity, unitFallback) {
  var declared = attrs(entity).target_temp_step
  if (typeof declared === "number" && declared > 0) return declared
  return 0.5
}

function temperatureRange(entity, unitFallback) {
  var a = attrs(entity)
  if (typeof a.min_temp === "number" && typeof a.max_temp === "number"
      && a.min_temp < a.max_temp) {
    return { min: a.min_temp, max: a.max_temp }
  }
  return { min: 5, max: 35 }
}

function climateTemperatureData(entity, target, unitFallback) {
  var caps = capabilitiesFor(entity)
  var range = temperatureRange(entity, unitFallback)
  var data = {}
  if (typeof target === "number" && isFinite(target) && caps.climateTarget) {
    data.temperature = Math.max(range.min, Math.min(range.max, target))
  }
  return data
}

// ---------------------------------------------------------------- icons

// Material Design Icons, as codepoints from the Nerd Font by glyph name; a
// wrong one renders as a box. Every glyph here is reused from a spot in this
// file already known to render, rather than a freshly guessed codepoint.
var DEVICE_CLASS_ICONS = {
  "garage": "󰛙",               // md-garage
  "door": "󰠚",                 // md-door
  "window": "󰖮",               // md-window_closed
  "shutter": "󱄜",              // md-window_shutter
  "blind": "󱄜",                // md-window_shutter
  "motion": "󰶑",               // md-motion_sensor
  "temperature": "󰔏",          // md-thermometer
  "humidity": "󰖎",             // md-water_percent
  "battery": "󰁹",              // md-battery
  "power": "󰉁",                // md-flash
  "outlet": "󰚥"                // md-power_plug
}

var DOMAIN_ICONS = {
  "light": "󰌵",                // md-lightbulb
  "switch": "󰔡",               // md-toggle_switch
  "climate": "󰎓",              // md-thermostat
  "cover": "󱄜",                // md-window_shutter
  "lock": "󰌾",                 // md-lock
  "scene": "󰏘",                // md-palette
  "sensor": "󰊚",               // md-gauge
  "binary_sensor": "󰶑"         // md-motion_sensor
}

var FALLBACK_ICON = "󰾰"          // md-devices

var BRAND_ICON = "󰋜"             // md-home

function iconFor(entity) {
  var dom = domain(entity)

  if (dom === "lock") {
    return stateOf(entity) === "locked" ? "󰌾" : "󰌿"
  }

  var deviceClass = cleaned(attrs(entity).device_class).toLowerCase()
  if (deviceClass && DEVICE_CLASS_ICONS[deviceClass]) {
    return DEVICE_CLASS_ICONS[deviceClass]
  }

  return DOMAIN_ICONS[dom] || FALLBACK_ICON
}

// ---------------------------------------------------------------- commands

// A toggle sends the Loxone `on`/`off` command directly; there is no
// domain/service pair to look up the way Home Assistant has one.
function toggleCall(entity, currentlyOn) {
  return { command: currentlyOn ? "off" : "on" }
}

// "toggle" | "lock" (switch calling lock/unlock) | "activate" (one-shot) | "none".
function controlKind(entity) {
  var dom = domain(entity)
  if (isToggleable(entity)) return "toggle"
  if (dom === "lock") return "lock"
  if (dom === "scene") return "activate"
  return "none"
}

// Seed picks for demo mode. Ids also live in bin/loxone-bridge; test_model.js
// checks these stay a subset.
var DEMO_DEFAULT_FAVORITES = [
  "light.5b93f8a1-0001-0001-0000000000001",
  "switch.5b93f8a1-0002-0001-0000000000002",
  "climate.5b93f8a1-0003-0001-0000000000003",
  "scene.5b93f8a1-0004-0001-0000000000004",
  "light.5b93f8a1-0005-0001-0000000000005",
  "sensor.5b93f8a1-0006-0001-0000000000006",
  "cover.5b93f8a1-0007-0001-0000000000007",
  "lock.5b93f8a1-0008-0001-0000000000008"
]

// Scoped to picked devices, so the count stays verifiable. Locks excluded:
// nobody reading "3 on" means a door.
function activitySummary(entities) {
  if (!entities || entities.length === 0) return "No devices picked"

  var on = 0
  for (var i = 0; i < entities.length; i++) {
    var entity = entities[i]
    if (!entity) continue
    if (isToggleable(entity) && isOn(entity)) on++
  }

  return on > 0 ? on + " on" : "All off"
}

// Settings browser buckets.
var DOMAIN_FILTERS = [
  { id: "all", title: "All", domains: [] },
  { id: "lights", title: "Lights", domains: ["light"] },
  { id: "controls", title: "Controls", domains: ["switch", "lock", "scene"] },
  { id: "climate", title: "Climate", domains: ["climate"] },
  { id: "covers", title: "Covers", domains: ["cover"] },
  { id: "sensors", title: "Sensors", domains: ["sensor", "binary_sensor"] }
]

function filterMatches(filterId, entity) {
  for (var i = 0; i < DOMAIN_FILTERS.length; i++) {
    var filter = DOMAIN_FILTERS[i]
    if (filter.id !== filterId) continue
    if (filter.domains.length === 0) return true
    return filter.domains.indexOf(domain(entity)) !== -1
  }
  return true
}

// Attribute names whose value would be a credential or a precise location
// rather than a state worth reading, kept for defense in depth: the IPC
// inspector and any future debug dump go through here before printing
// anything. Loxone's own structure data does not currently carry either kind
// of attribute, so the list is empty rather than guessed at.
var REDACTED_ATTRIBUTES = []

function redactAttributes(entity) {
  var source = attrs(entity)
  var out = {}
  for (var key in source) {
    out[key] = REDACTED_ATTRIBUTES.indexOf(key) === -1
      ? source[key] : "[redacted]"
  }
  return out
}

// Matches the friendly name, the entity id, and — since Loxone repeats
// control names across rooms constantly ("Jalousie" in every room with a
// blind) — the room name, when the caller has one to offer.
function searchMatches(query, entity, roomName) {
  var needle = String(query || "").trim().toLowerCase()
  if (!needle) return true
  return name(entity).toLowerCase().indexOf(needle) !== -1
    || String(entity.entity_id).toLowerCase().indexOf(needle) !== -1
    || (!!roomName && String(roomName).toLowerCase().indexOf(needle) !== -1)
}

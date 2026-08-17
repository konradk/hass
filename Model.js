.pragma library

// Stateless view logic: raw Home Assistant entities in, drawable values out.
// No QML types and no side effects, so it is testable outside the shell.

var TOGGLEABLE_DOMAINS = ["light", "switch", "fan", "input_boolean", "humidifier"]

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

function isUnavailable(entity) {
  var state = stateOf(entity)
  return state === "unavailable" || state === "unknown"
}

// A scene's state is when it last ran, or "unknown" — not a reason to grey it out.
function isAvailable(entity) {
  if (!entity) return false
  if (controlKind(entity) === "activate") return true
  return !isUnavailable(entity)
}

function isToggleable(entity) {
  return TOGGLEABLE_DOMAINS.indexOf(domain(entity)) !== -1
    || climateCanToggle(entity)
}

function isExpandable(entity) {
  return capabilitiesFor(entity).expandable
}

function isOn(entity) {
  var state = stateOf(entity)
  // A climate entity's state is its HVAC mode, so every real mode except
  // `off` means the device is on. It never reports the literal state `on`.
  if (domain(entity) === "climate") {
    return state !== "" && state !== "off"
      && state !== "unavailable" && state !== "unknown"
  }
  return state === "on" || state === "locked" || state === "open"
}

function isPlaying(entity) {
  return playbackState(entity) === "playing"
}

function playbackState(entity) {
  var explicit = cleaned(attrs(entity).media_playback_state)
  return (explicit || stateOf(entity)).toLowerCase()
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
  if (dom === "media_player") {
    var media = mediaSubtitle(entity)
    if (media) return media
    var state = stateOf(entity)
    if (state === "playing" || state === "paused") return capitalize(state)
    return ""
  }
  if (isToggleable(entity)) return displayState(entity)
  return ""
}

function badgeText(entity) {
  var dom = domain(entity)
  if (dom === "scene") return "Scene"
  if (dom === "camera") return "Camera"
  if (dom === "climate") {
    // The HVAC mode is the entity's state, not an attribute; `hvac_action` is
    // the separate, more useful "what is it doing right now" — heating vs idle
    // while both sit in mode "heat". Falls through to the state without one.
    var action = cleaned(attrs(entity).hvac_action)
    if (action) return capitalize(action)
  }
  if (isUnavailable(entity)) return capitalize(stateOf(entity))
  return displayState(entity)
}

function mediaSubtitle(entity) {
  var a = attrs(entity)
  var title = cleaned(a.media_title)
  var artist = cleaned(a.media_artist)
  var album = cleaned(a.media_album_name)
  var channel = cleaned(a.media_channel)

  if (title) {
    if (artist) return artist + " — " + title
    if (album) return title + " — " + album
    return title
  }
  return channel || ""
}

// ---------------------------------------------------------------- light

// Home Assistant removed SUPPORT_BRIGHTNESS (bit 0) in 2022; a modern light
// advertises dimming through supported_color_modes. The brightness attribute
// is not a substitute, because a light that is off reports it as null — which
// is exactly the moment someone wants the slider.
var UNDIMMABLE_COLOR_MODES = ["onoff", "unknown"]

function supportsBrightness(entity) {
  if (domain(entity) !== "light") return false
  var modes = attrs(entity).supported_color_modes
  if (Array.isArray(modes)) {
    for (var i = 0; i < modes.length; i++) {
      if (UNDIMMABLE_COLOR_MODES.indexOf(String(modes[i])) === -1) return true
    }
    return false
  }
  // Pre-2022 instances, and anything that reports a live brightness.
  var features = attrs(entity).supported_features
  if (typeof features === "number" && (features & 1) === 1) return true
  return typeof attrs(entity).brightness === "number"
}

function brightnessPercent(entity) {
  var value = attrs(entity).brightness
  if (typeof value !== "number") return -1
  return Math.min(Math.max(value / 255.0 * 100.0, 0), 100)
}

// ---------------------------------------------------------------- media

function volumeLevel(entity) {
  var value = attrs(entity).volume_level
  return typeof value === "number" ? value : -1
}

// Home Assistant EntityFeature values. Keep the constants next to the only
// projection that interprets them, rather than scattering bit tests across
// QML controls.
var MEDIA_PAUSE = 1
var MEDIA_VOLUME_SET = 4
var MEDIA_PREVIOUS_TRACK = 16
var MEDIA_NEXT_TRACK = 32
var MEDIA_PLAY = 16384

var COVER_OPEN = 1
var COVER_CLOSE = 2
var COVER_STOP = 8

var CLIMATE_TARGET_TEMPERATURE = 1
var CLIMATE_TARGET_TEMPERATURE_RANGE = 2
var CLIMATE_FAN_MODE = 8
var CLIMATE_PRESET_MODE = 16
var CLIMATE_SWING_MODE = 32
var CLIMATE_TURN_OFF = 128
var CLIMATE_TURN_ON = 256

function featureBits(entity) {
  var value = attrs(entity).supported_features
  return typeof value === "number" && isFinite(value) ? Math.floor(value) : 0
}

function hasFeature(bits, flag) {
  return (bits & flag) === flag
}

function climateCanToggle(entity) {
  if (domain(entity) !== "climate") return false
  var required = stateOf(entity) === "off" ? CLIMATE_TURN_ON : CLIMATE_TURN_OFF
  return hasFeature(featureBits(entity), required)
}

function capabilitiesFor(entity) {
  var dom = domain(entity)
  var a = attrs(entity)
  var bits = featureBits(entity)
  var activate = dom === "scene" || dom === "script"
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
    climateHvacMode: false,
    climateFanMode: false,
    climatePresetMode: false,
    climateSwingMode: false,
    expandable: false,
    reserveExpandSlot: false
  }

  if (available && dom === "media_player") {
    result.mediaPrevious = hasFeature(bits, MEDIA_PREVIOUS_TRACK)
    result.mediaPlayPause = hasFeature(bits, MEDIA_PAUSE)
      || hasFeature(bits, MEDIA_PLAY)
    result.mediaNext = hasFeature(bits, MEDIA_NEXT_TRACK)
    result.mediaVolume = hasFeature(bits, MEDIA_VOLUME_SET)
      && typeof a.volume_level === "number"
  } else if (available && dom === "cover") {
    result.coverOpen = hasFeature(bits, COVER_OPEN)
    result.coverStop = hasFeature(bits, COVER_STOP)
    result.coverClose = hasFeature(bits, COVER_CLOSE)
  } else if (available && dom === "climate") {
    result.climateRange = hasFeature(bits, CLIMATE_TARGET_TEMPERATURE_RANGE)
      && typeof a.target_temp_low === "number"
      && typeof a.target_temp_high === "number"
    result.climateTarget = hasFeature(bits, CLIMATE_TARGET_TEMPERATURE)
      && typeof a.temperature === "number"
    result.climateHvacMode = hasClimateModeOption(entity, "hvac_modes")
    result.climateFanMode = hasFeature(bits, CLIMATE_FAN_MODE)
      && hasClimateModeOption(entity, "fan_modes")
    result.climatePresetMode = hasFeature(bits, CLIMATE_PRESET_MODE)
      && hasClimateModeOption(entity, "preset_modes")
    result.climateSwingMode = hasFeature(bits, CLIMATE_SWING_MODE)
      && hasClimateModeOption(entity, "swing_modes")

  }
  result.expandable = result.brightness
    || result.mediaPrevious || result.mediaPlayPause || result.mediaNext
    || result.mediaVolume || result.coverOpen || result.coverStop
    || result.coverClose || result.climateTarget || result.climateRange
    || result.climateHvacMode || result.climateFanMode
    || result.climatePresetMode || result.climateSwingMode
  // Climate integrations commonly clear the live target while the device is
  // off. Keep the row geometry stable without pretending there is a target
  // value to edit: the chevron remains hidden/disabled until controls are
  // usable, but its slot is already reserved.
  result.reserveExpandSlot = result.expandable
    || (!!entity && dom === "climate"
      && (hasFeature(bits, CLIMATE_TARGET_TEMPERATURE)
        || hasFeature(bits, CLIMATE_TARGET_TEMPERATURE_RANGE)))
  return result
}

// ---------------------------------------------------------------- climate

// `climate` entities carry no unit of their own — the instance decides, and
// the bridge reports it from get_config. `fallback` is that value; the entity
// attributes are still checked first, for the domains that do declare one.
function temperatureUnit(entity, fallback) {
  var a = attrs(entity)
  return cleaned(a.temperature_unit) || cleaned(a.unit_of_measurement)
    || cleaned(fallback) || ""
}

function formatTemp(value, unit) {
  if (typeof value !== "number") return ""
  var rounded = Math.round(value)
  var text = Math.abs(rounded - value) < 0.01
    ? String(rounded)
    : value.toFixed(1)
  return unit ? text + unit : text
}

function hasTargetRange(entity) {
  var a = attrs(entity)
  return typeof a.target_temp_low === "number" && typeof a.target_temp_high === "number"
}

function climateSubtitle(entity, unitFallback) {
  var a = attrs(entity)
  var unit = temperatureUnit(entity, unitFallback)
  var parts = []

  if (hasTargetRange(entity)) {
    parts.push("Target " + formatTemp(a.target_temp_low, unit)
      + "–" + formatTemp(a.target_temp_high, unit))
  } else if (typeof a.temperature === "number") {
    parts.push("Target " + formatTemp(a.temperature, unit))
  }
  if (typeof a.current_temperature === "number") {
    parts.push("Now " + formatTemp(a.current_temperature, unit))
  }
  return parts.join(" · ")
}

// Home Assistant publishes the increment the thermostat actually accepts;
// deriving one from the unit is a guess, and only right by coincidence.
function temperatureStep(entity, unitFallback) {
  var declared = attrs(entity).target_temp_step
  if (typeof declared === "number" && declared > 0) return declared
  return temperatureUnit(entity, unitFallback).indexOf("F") !== -1 ? 1.0 : 0.5
}

function temperatureRange(entity, unitFallback) {
  var a = attrs(entity)
  if (typeof a.min_temp === "number" && typeof a.max_temp === "number"
      && a.min_temp < a.max_temp) {
    return { min: a.min_temp, max: a.max_temp }
  }
  return temperatureUnit(entity, unitFallback).indexOf("F") !== -1
    ? { min: 50, max: 90 }
    : { min: 5, max: 35 }
}

function climateTemperatureData(entity, target, low, high, unitFallback) {
  var caps = capabilitiesFor(entity)
  var range = temperatureRange(entity, unitFallback)
  var data = {}
  if (typeof target === "number" && isFinite(target) && caps.climateTarget) {
    data.temperature = Math.max(range.min, Math.min(range.max, target))
  }
  if (typeof low === "number" && isFinite(low)
      && typeof high === "number" && isFinite(high)
      && caps.climateRange) {
    var clampedLow = Math.max(range.min, Math.min(range.max, low))
    var clampedHigh = Math.max(range.min, Math.min(range.max, high))
    data.target_temp_low = Math.min(clampedLow, clampedHigh)
    data.target_temp_high = Math.max(clampedLow, clampedHigh)
  }
  return data
}

// HVAC mode is the climate entity state. Unlike optional climate controls,
// Home Assistant does not assign it a supported-feature bit; the advertised
// `hvac_modes` list is the capability contract for climate.set_hvac_mode.
function climateModeOptions(entity, optionsAttribute) {
  var declared = attrs(entity)[optionsAttribute]
  if (!Array.isArray(declared)) return []
  var modes = []
  for (var i = 0; i < declared.length; i++) {
    if (typeof declared[i] !== "string" || !declared[i].trim()) continue
    if (modes.indexOf(declared[i]) === -1) modes.push(declared[i])
  }
  return modes
}

// Projection only needs the capability bit, not a new option list on every
// state update. Scan the advertised values directly.
function hasClimateModeOption(entity, optionsAttribute) {
  var declared = attrs(entity)[optionsAttribute]
  if (!Array.isArray(declared)) return false
  for (var i = 0; i < declared.length; i++) {
    if (typeof declared[i] === "string" && declared[i].trim()) return true
  }
  return false
}

function climateModeDeclared(entity, optionsAttribute, mode) {
  var declared = attrs(entity)[optionsAttribute]
  if (!Array.isArray(declared) || typeof mode !== "string") return false
  for (var i = 0; i < declared.length; i++) {
    if (declared[i] === mode && mode.trim()) return true
  }
  return false
}

function climateAttributeMode(entity, attributeName) {
  var mode = attrs(entity)[attributeName]
  return typeof mode === "string" ? mode : ""
}

function climateModeData(entity, mode, featureFlag, optionsAttribute, payloadKey) {
  if (domain(entity) !== "climate" || isUnavailable(entity)
      || (featureFlag && !hasFeature(featureBits(entity), featureFlag))
      || !climateModeDeclared(entity, optionsAttribute, mode)) {
    return {}
  }
  var data = {}
  data[payloadKey] = mode
  return data
}

function climateHvacModes(entity) {
  return climateModeOptions(entity, "hvac_modes")
}

function climateHvacMode(entity) {
  return stateOf(entity)
}

// Home Assistant mode tokens are protocol values, not ready-made UI copy.
// Preserve the token for service calls, but never render separators verbatim.
function humanizeMode(mode) {
  var text = cleaned(mode).replace(/[_-]+/g, " ")
  return capitalize(text)
}

function climateHvacModeLabel(mode) {
  return mode === "heat_cool" ? "Heat/Cool" : humanizeMode(mode)
}

function climateFanModeLabel(mode) {
  return humanizeMode(mode)
}

function climateHvacModeData(entity, mode) {
  return climateModeData(entity, mode, 0, "hvac_modes", "hvac_mode")
}

// Climate integrations declare every permitted fan-mode token. Preserve tokens
// exactly because Home Assistant expects the selected value verbatim.
function climateFanModes(entity) {
  return climateModeOptions(entity, "fan_modes")
}

function climateFanMode(entity) {
  return climateAttributeMode(entity, "fan_mode")
}

function climateFanModeData(entity, mode) {
  return climateModeData(entity, mode, CLIMATE_FAN_MODE, "fan_modes", "fan_mode")
}

function climatePresetModeLabel(mode) {
  return humanizeMode(mode)
}

function climatePresetModes(entity) {
  return climateModeOptions(entity, "preset_modes")
}

function climatePresetMode(entity) {
  return climateAttributeMode(entity, "preset_mode")
}

function climatePresetModeData(entity, mode) {
  return climateModeData(entity, mode, CLIMATE_PRESET_MODE,
                         "preset_modes", "preset_mode")
}

function climateSwingModeLabel(mode) {
  return humanizeMode(mode)
}

function climateSwingModes(entity) {
  return climateModeOptions(entity, "swing_modes")
}

function climateSwingMode(entity) {
  return climateAttributeMode(entity, "swing_mode")
}

function climateSwingModeData(entity, mode) {
  return climateModeData(entity, mode, CLIMATE_SWING_MODE,
                         "swing_modes", "swing_mode")
}


// ---------------------------------------------------------------- icons

// Material Design Icons, as in Home Assistant's own `mdi:` hints. Codepoints
// were read from the Nerd Font by glyph name; a wrong one renders as a box.
var DEVICE_CLASS_ICONS = {
  "garage": "󰛙",               // md-garage
  "door": "󰠚",                 // md-door
  "window": "󰖮",               // md-window_closed
  "shutter": "󱄜",              // md-window_shutter
  "blind": "󰂬",                // md-blinds
  "curtain": "󱡆",              // md-curtains
  "motion": "󰶑",               // md-motion_sensor
  "temperature": "󰔏",          // md-thermometer
  "humidity": "󰖎",             // md-water_percent
  "tv": "󰔂",                   // md-television
  "speaker": "󰓃",              // md-speaker
  "battery": "󰁹",              // md-battery
  "power": "󰉁",                // md-flash
  "outlet": "󰚥"                // md-power_plug
}

var DOMAIN_ICONS = {
  "light": "󰌵",                // md-lightbulb
  "switch": "󰔡",               // md-toggle_switch
  "fan": "󰈐",                  // md-fan
  "input_boolean": "󰨚",        // md-toggle_switch_outline
  "humidifier": "󱂙",           // md-air_humidifier
  "climate": "󰎓",              // md-thermostat
  "media_player": "󰝚",         // md-music
  "cover": "󱄜",                // md-window_shutter
  "lock": "󰌾",                 // md-lock
  "scene": "󰏘",                // md-palette
  "camera": "󰞮",               // md-cctv
  "sensor": "󰊚",               // md-gauge
  "binary_sensor": "󰶑",        // md-motion_sensor
  "automation": "󰚩",           // md-robot
  "script": "󰯂",               // md-script_text
  "vacuum": "󰜍",               // md-robot_vacuum
  "person": "󰀄",               // md-account
  "weather": "󰖕"               // md-weather_partly_cloudy
}

var FALLBACK_ICON = "󰾰"          // md-devices

var BRAND_ICON = "󰟐"             // md-home_assistant

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

// ---------------------------------------------------------------- service calls

// Own turn_on/turn_off where the domain has them, so Home Assistant applies
// its semantics; otherwise homeassistant.toggle.
function toggleCall(entity, currentlyOn) {
  var dom = domain(entity)
  if (isToggleable(entity)) {
    return { domain: dom, service: currentlyOn ? "turn_off" : "turn_on" }
  }
  return { domain: "homeassistant", service: "toggle" }
}

// "toggle" | "lock" (switch calling lock/unlock) | "activate" (one-shot) | "none".
function controlKind(entity) {
  var dom = domain(entity)
  if (isToggleable(entity)) return "toggle"
  if (dom === "lock") return "lock"
  if (dom === "scene" || dom === "script") return "activate"
  return "none"
}

// Seed picks for demo mode. Ids also live in bin/hass-bridge; test_model.js
// checks these stay a subset.
var DEMO_DEFAULT_FAVORITES = [
  "light.living_room_lamp",
  "fan.living_room_ceiling_fan",
  "climate.living_room_thermostat",
  "media_player.living_room_tv",
  "scene.living_room_movie_night",
  "light.kitchen_pendant",
  "switch.kitchen_coffee_maker",
  "sensor.kitchen_temperature",
  "cover.garage_door",
  "lock.garage_side_door"
]

// Scoped to picked devices, so the count stays verifiable. Locks excluded:
// nobody reading "3 on" means a door.
function activitySummary(entities) {
  if (!entities || entities.length === 0) return "No devices picked"

  var on = 0
  var playing = ""
  var playingCount = 0

  for (var i = 0; i < entities.length; i++) {
    var entity = entities[i]
    if (!entity) continue
    if (isToggleable(entity) && isOn(entity)) on++
    if (domain(entity) === "media_player" && isPlaying(entity)) {
      playingCount++
      if (!playing) playing = name(entity)
    }
  }

  var parts = []
  if (on > 0) parts.push(on + " on")
  if (playingCount === 1) parts.push(playing + " playing")
  else if (playingCount > 1) parts.push(playingCount + " playing")

  return parts.length ? parts.join(" · ") : "All off"
}

// Settings browser buckets. No "Cameras" until cameras ship.
var DOMAIN_FILTERS = [
  { id: "all", title: "All", domains: [] },
  { id: "lights", title: "Lights", domains: ["light"] },
  { id: "controls", title: "Controls",
    domains: ["switch", "fan", "input_boolean", "humidifier", "lock", "scene", "script"] },
  { id: "climate", title: "Climate", domains: ["climate"] },
  { id: "media", title: "Media", domains: ["media_player"] },
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

// Attribute names whose value is a credential or a location rather than a
// state worth reading. Home Assistant puts a live camera `access_token` and a
// signed `entity_picture` straight into the attribute map, so anything that
// prints attributes for a human — the IPC inspector, any future debug dump —
// has to go through here first.
var REDACTED_ATTRIBUTES = [
  "access_token", "entity_picture", "entity_picture_local", "token",
  "latitude", "longitude", "gps_accuracy"
]

function redactAttributes(entity) {
  var source = attrs(entity)
  var out = {}
  for (var key in source) {
    out[key] = REDACTED_ATTRIBUTES.indexOf(key) === -1
      ? source[key] : "[redacted]"
  }
  return out
}

// Matches the friendly name and the entity id.
function searchMatches(query, entity) {
  var needle = String(query || "").trim().toLowerCase()
  if (!needle) return true
  return name(entity).toLowerCase().indexOf(needle) !== -1
    || String(entity.entity_id).toLowerCase().indexOf(needle) !== -1
}

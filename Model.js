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

function parseNumericState(value) {
  if (typeof value === "number") return isFinite(value) ? value : null
  if (typeof value !== "string") return null
  var trimmed = value.trim()
  if (!trimmed) return null
  var parsed = Number(trimmed)
  return isFinite(parsed) ? parsed : null
}

function hasHistoryGraph(entity) {
  return domain(entity) === "sensor" && parseNumericState(stateOf(entity)) !== null
}

var HISTORY_HOURS = [1, 3, 6, 12, 24]
var HISTORY_MAX_POINTS = 240

function normalizeHistoryHours(hours) {
  if (typeof hours === "string" && hours.trim() !== "") hours = Number(hours)
  if (typeof hours !== "number" || !isFinite(hours)) return 0
  for (var i = 0; i < HISTORY_HOURS.length; i++) {
    if (hours === HISTORY_HOURS[i]) return hours
  }
  return 0
}

function historyWindowLabel(hours) {
  var windowHours = normalizeHistoryHours(hours)
  if (windowHours === 24) return "1d"
  return windowHours ? String(windowHours) + "h" : ""
}

function historyAxisEnd(points, hours, localNow) {
  var windowHours = normalizeHistoryHours(hours)
  if (!windowHours || typeof localNow !== "number" || !isFinite(localNow))
    return 0
  if (!points || !points.length) return localNow
  var newest = Number(points[points.length - 1].t)
  if (!isFinite(newest)) return localNow
  if (newest > localNow || localNow - newest > windowHours * 3600)
    return newest
  return localNow
}

function downsampleHistoryPoints(points, limit) {
  if (!points || !points.length) return []
  var cap = typeof limit === "number" && isFinite(limit) && limit > 0
    ? Math.floor(limit) : HISTORY_MAX_POINTS
  if (points.length <= cap) return points.slice()
  if (cap === 1) return [points[points.length - 1]]
  var selected = { 0: true }
  selected[points.length - 1] = true
  var selectedCount = points.length > 1 ? 2 : 1
  for (var transition = 1; transition < points.length; transition++) {
    if ((points[transition - 1].v === null) !== (points[transition].v === null)) {
      if (!selected[transition - 1]) { selected[transition - 1] = true; selectedCount++ }
      if (!selected[transition]) { selected[transition] = true; selectedCount++ }
    }
  }
  if (selectedCount >= cap) {
    var required = []
    for (var requiredIndex = 0; requiredIndex < points.length; requiredIndex++) {
      if (selected[requiredIndex]) required.push(points[requiredIndex])
    }
    var trimmed = []
    var requiredStep = (required.length - 1) / Math.max(1, cap - 1)
    for (var requiredSlot = 0; requiredSlot < cap; requiredSlot++)
      trimmed.push(required[Math.round(requiredSlot * requiredStep)])
    return trimmed
  }
  var capacity = Math.max(0, cap - selectedCount)
  var buckets = Math.max(1, Math.floor(capacity / 2))
  var start = Number(points[0].t)
  var span = Math.max(1, Number(points[points.length - 1].t) - start)
  for (var bucket = 0; bucket < buckets && selectedCount < cap; bucket++) {
    var lowT = start + span * bucket / buckets
    var highT = start + span * (bucket + 1) / buckets
    var minIndex = -1
    var maxIndex = -1
    for (var index = 0; index < points.length; index++) {
      var point = points[index]
      if (selected[index] || point.v === null || Number(point.t) < lowT
          || (Number(point.t) >= highT && bucket !== buckets - 1)) continue
      if (minIndex < 0 || point.v < points[minIndex].v) minIndex = index
      if (maxIndex < 0 || point.v > points[maxIndex].v) maxIndex = index
    }
    if (minIndex >= 0 && !selected[minIndex]) {
      selected[minIndex] = true
      selectedCount++
    }
    if (maxIndex >= 0 && selectedCount < cap && !selected[maxIndex]) {
      selected[maxIndex] = true
      selectedCount++
    }
  }
  var out = []
  for (var outputIndex = 0; outputIndex < points.length; outputIndex++) {
    if (selected[outputIndex]) out.push(points[outputIndex])
  }
  return out
}

function clampHistoryPoints(points, hours, now, maxPoints) {
  var windowHours = normalizeHistoryHours(hours)
  if (!points || !points.length || !windowHours) return []
  if (typeof now !== "number" || !isFinite(now)) return []

  function keepFrom(end) {
    var start = end - windowHours * 3600
    var kept = []
    for (var i = 0; i < points.length; i++) {
      var point = points[i]
      if (!point) continue
      if (typeof point.t !== "number" || !isFinite(point.t)) continue
      if (point.v !== null
          && (typeof point.v !== "number" || !isFinite(point.v))) continue
      if (point.t < start) continue
      kept.push({ t: point.t, v: point.v })
    }
    return kept
  }

  var kept = keepFrom(now)
  // Recorder timestamps follow Home Assistant's clock. If this desktop is ahead
  // of the server, anchoring to Date.now() can drop every sample — fall back
  // to the newest sample so a successful fetch still has something to draw.
  if (!kept.length) {
    var latest = null
    for (var i = 0; i < points.length; i++) {
      var point = points[i]
      if (!point) continue
      if (typeof point.t !== "number" || !isFinite(point.t)) continue
      if (latest === null || point.t > latest) latest = point.t
    }
    if (latest !== null && latest < now) kept = keepFrom(latest)
  }
  return downsampleHistoryPoints(kept, maxPoints)
}

// Last known sample at or before the cursor time (step-chart semantics).
function nearestHistoryIndex(points, x, left, spanX, minT, maxT) {
  if (!points || !points.length || !(spanX > 0)) return -1
  if (!(maxT > minT)) return points.length - 1
  var t = minT + ((x - left) / spanX) * (maxT - minT)
  if (t < points[0].t) return 0
  var best = 0
  for (var i = 0; i < points.length; i++) {
    if (points[i].t <= t) best = i
    else break
  }
  return best
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

// ---------------------------------------------------------------- room readings

function environmentalKind(entity) {
  if (domain(entity) !== "sensor") return ""
  var a = attrs(entity)
  var deviceClass = cleaned(a.device_class).toLowerCase()
  // Home Assistant's SensorDeviceClass values are the canonical metadata.
  // A declared but unrelated class must never be reinterpreted from its name
  // or unit (battery percentage is the common failure mode).
  var byClass = {
    temperature: "temperature", humidity: "humidity", pm1: "pm1",
    pm25: "pm25", pm10: "pm10",
    volatile_organic_compounds: "voc",
    volatile_organic_compounds_parts: "voc",
    carbon_dioxide: "co2", carbon_monoxide: "co",
    aqi: "aqi", atmospheric_pressure: "pressure",
    illuminance: "illuminance"
  }
  if (byClass[deviceClass]) return byClass[deviceClass]
  if (deviceClass) return ""

  // A unit alone is not identity. Classless CPU, memory, storage and battery
  // sensors all legitimately use %, so every fallback also requires a clear,
  // entity-specific name. Only the entity state name and entity_id are used;
  // the shared device name is deliberately excluded.
  var unit = environmentalUnit(entity)
  var haystack = environmentalName(entity)
  var temperatureUnit = /^(°c|°f|k)$/i.test(unit)
  var massUnit = /^(ug\/m3|mg\/m3)$/.test(unit)
  var gasUnit = /^(ppm|ppb|ug\/m3|mg\/m3)$/.test(unit)
  if (temperatureUnit
      && /\b(temperature|temp|dew point|heat index|feels like)\b/.test(haystack))
    return "temperature"
  if (unit === "%" && /\b(humidity|relative humidity|rh)\b/.test(haystack))
    return "humidity"
  if (/^(lx|lux)$/.test(unit)
      && /\b(illuminance|lux|light level)\b/.test(haystack))
    return "illuminance"
  if (/^(pa|hpa|kpa|mbar|bar|inhg|mmhg)$/.test(unit)
      && /\b(pressure|barometer|barometric)\b/.test(haystack))
    return "pressure"
  if (massUnit && /\b(pm2[ .]?5|pm25)\b/.test(haystack)) return "pm25"
  if (massUnit && /\bpm10\b/.test(haystack)) return "pm10"
  if (massUnit && /\bpm1\b/.test(haystack)) return "pm1"
  if (/\b(voc|tvoc|volatile organic compounds?)\b/.test(haystack)
      && /\bindex\b/.test(haystack) && (!unit || unit === "index"))
    return "voc_index"
  if (/\b(voc|tvoc|volatile organic compounds?)\b/.test(haystack)
      && massUnit) return "voc"
  if (/\b(co2|carbon dioxide)\b/.test(haystack) && gasUnit) return "co2"
  if (/\b(carbon monoxide|co)\b/.test(haystack) && gasUnit) return "co"
  if (/\b(aqi|air quality index)\b/.test(haystack) && (!unit || unit === "index"))
    return "aqi"
  return ""
}

function environmentalName(entity) {
  var a = attrs(entity)
  var entityId = String(entity && entity.entity_id || "")
  var objectId = entityId.split(".").slice(1).join(" ")
  return (cleaned(a.friendly_name) + " " + objectId).toLowerCase()
    .replace(/[_-]+/g, " ")
}

function environmentalUnit(entity) {
  return cleaned(attrs(entity).unit_of_measurement).toLowerCase()
    .replace(/\s+/g, "").replace(/[µμ]/g, "u")
    .replace(/³/g, "3").replace(/²/g, "2")
}

var ENVIRONMENTAL_LABELS = {
  temperature: "Temperature", humidity: "Humidity", pm1: "PM1",
  pm25: "PM2.5", pm10: "PM10", voc: "VOC", voc_index: "VOC index",
  co2: "CO₂", co: "CO", aqi: "Air quality", pressure: "Pressure",
  illuminance: "Light"
}

var ENVIRONMENTAL_ORDER = {
  temperature: 10, humidity: 20, co2: 30, voc: 40, voc_index: 40,
  pm1: 50, pm25: 60, pm10: 70, aqi: 80, pressure: 90, illuminance: 100
}

function isIkeaVindstyrka(device) {
  var manufacturer = cleaned(device && device.manufacturer).toLowerCase()
  var model = cleaned(device && device.model).toLowerCase()
  return manufacturer.indexOf("ikea") !== -1
    && (model.indexOf("vindstyrka") !== -1
      || /(?:^|[^a-z0-9])e2112(?:$|[^a-z0-9])/.test(model))
}

function environmentalQuality(kind, state, unit, device) {
  var value = Number(state)
  if (!isFinite(value)) return "unknown"
  var bands = null
  var normalizedUnit = String(unit || "").toLowerCase().replace(/\s+/g, "")
    .replace(/[µμ]/g, "u").replace(/³/g, "3")
  if (kind === "pm25" || kind === "pm10" || kind === "voc") {
    if (normalizedUnit === "mg/m3") value *= 1000
    else if (normalizedUnit !== "ug/m3") return "neutral"
  } else if (kind === "co2" || kind === "co") {
    if (normalizedUnit === "ppb") value /= 1000
    else if (normalizedUnit !== "ppm") return "neutral"
  } else if (kind === "aqi" || kind === "voc_index") {
    if (normalizedUnit && normalizedUnit !== "index") return "neutral"
  }
  if (kind === "pm25") bands = [5, 15, 35]
  else if (kind === "pm10") bands = [15, 45, 75]
  // VINDSTYRKA contains a Sensirion SEN54. Its unitless VOC Index uses the
  // manufacturer's purifier mapping: 1–150, 150–250, 250–400, 400–500.
  // Keep this device-specific: another integration's index may mean something
  // different even when Home Assistant gives it a similar display name.
  else if (kind === "voc_index" && isIkeaVindstyrka(device))
    bands = [150, 250, 400]
  else if (kind === "voc") bands = [220, 660, 2200]
  else if (kind === "co2") bands = [800, 1200, 2000]
  else if (kind === "co") bands = [4, 9, 35]
  else if (kind === "aqi") bands = [50, 100, 150]
  if (!bands) return "neutral"
  if (value <= bands[0]) return "good"
  if (value <= bands[1]) return "moderate"
  if (value <= bands[2]) return "poor"
  return "critical"
}

function environmentalReading(entity, device) {
  var kind = environmentalKind(entity)
  if (!kind) return null
  var sourceLabel = name(entity)
  var unit = environmentalUnit(entity)
  return {
    entityId: String(entity.entity_id || ""),
    kind: kind,
    label: ENVIRONMENTAL_LABELS[kind] || name(entity),
    sourceLabel: sourceLabel,
    value: displayState(entity),
    quality: isUnavailable(entity) ? "unknown"
      : environmentalQuality(kind, stateOf(entity), unit, device),
    order: ENVIRONMENTAL_ORDER[kind] || 999
  }
}

function distinguishEnvironmentalReadings(readings) {
  var list = Array.isArray(readings) ? readings : []
  var counts = Object.create(null)
  var sourceCounts = Object.create(null)
  for (var i = 0; i < list.length; i++) {
    var kind = String(list[i] && list[i].kind || "")
    counts[kind] = (counts[kind] || 0) + 1
    var sourceKey = kind + "\u0000" + String(list[i] && list[i].sourceLabel || "")
    sourceCounts[sourceKey] = (sourceCounts[sourceKey] || 0) + 1
  }
  var out = []
  for (var n = 0; n < list.length; n++) {
    var reading = list[n]
    if (!reading) continue
    var sourceLabel = reading.sourceLabel || reading.entityId
    var duplicateSource = sourceCounts[String(reading.kind) + "\u0000"
      + String(reading.sourceLabel || "")] > 1
    var objectId = String(reading.entityId || "").split(".").slice(1).join(".")
    out.push({
      entityId: reading.entityId,
      kind: reading.kind,
      label: counts[reading.kind] > 1
        ? sourceLabel + (duplicateSource && objectId ? " (" + objectId + ")" : "")
        : reading.label,
      sourceLabel: reading.sourceLabel,
      value: reading.value,
      quality: reading.quality,
      order: reading.order
    })
  }
  return out
}

function normalizedControlName(value) {
  return cleaned(value).toLowerCase().replace(/[^a-z0-9]+/g, "")
}

function isSafePrimaryControl(entity, deviceName, registryEntry) {
  if (!entity || !capabilitiesFor(entity).toggle) return false
  var entry = registryEntry && typeof registryEntry === "object"
    ? registryEntry : {}
  if (cleaned(entry.entityCategory)) return false
  var controlName = (name(entity) + " " + String(entity.entity_id || "") + " "
    + cleaned(entry.name) + " " + cleaned(entry.originalName)).toLowerCase()
  if (/(child.?lock|identify|indicator|led|display|reset|calibrat|mute|alarm)/
      .test(controlName)) return false
  var dom = domain(entity)
  if (dom === "light" || dom === "fan" || dom === "climate"
      || dom === "humidifier") return true
  if (dom !== "switch" && dom !== "input_boolean") return false
  var deviceKey = normalizedControlName(deviceName)
  if (!deviceKey) return false
  var objectId = String(entity.entity_id || "").split(".").slice(1).join(".")
  return normalizedControlName(name(entity)) === deviceKey
    || normalizedControlName(objectId) === deviceKey
    || normalizedControlName(entry.name) === deviceKey
    || normalizedControlName(entry.originalName) === deviceKey
}

function roomReadingSummary(readings, limit) {
  var values = Array.isArray(readings) ? readings : []
  var cap = typeof limit === "number" && limit > 0 ? Math.floor(limit) : 3
  var parts = []
  for (var i = 0; i < values.length && parts.length < cap; i++) {
    var reading = values[i] || {}
    var value = cleaned(reading.value)
    if (!value) continue
    parts.push(reading.kind === "temperature" || reading.kind === "humidity"
      ? value : cleaned(reading.label) + " " + value)
  }
  if (values.length > parts.length) parts.push("+" + (values.length - parts.length))
  return parts.join(" · ")
}

function barDataEligible(entity) {
  var dom = domain(entity)
  return dom === "sensor" || dom === "binary_sensor" || dom === "climate"
}

function barDataReadings(entity, unitFallback, device) {
  if (!entity) return []
  var environmental = environmentalReading(entity, device)
  if (environmental) return [environmental]

  if (domain(entity) !== "climate") {
    return [{
      entityId: String(entity.entity_id || ""),
      kind: "state",
      label: name(entity),
      value: displayState(entity),
      quality: isUnavailable(entity) ? "unknown" : "neutral",
      order: 10
    }]
  }

  if (isUnavailable(entity)) {
    return [{
      entityId: String(entity.entity_id || ""),
      kind: "climate_state",
      label: "AC",
      value: displayState(entity),
      quality: "unknown",
      order: 10
    }]
  }

  var a = attrs(entity)
  var unit = temperatureUnit(entity, unitFallback)
  var readings = []
  if (typeof a.current_temperature === "number" && isFinite(a.current_temperature)) {
    readings.push({
      entityId: String(entity.entity_id || ""),
      kind: "climate_current",
      label: "Current",
      value: formatTemp(a.current_temperature, unit),
      quality: "neutral",
      order: 10
    })
  }

  var target = ""
  if (typeof a.target_temp_low === "number" && isFinite(a.target_temp_low)
      && typeof a.target_temp_high === "number" && isFinite(a.target_temp_high)) {
    target = formatTemp(a.target_temp_low, "") + "–"
      + formatTemp(a.target_temp_high, unit)
  } else if (typeof a.temperature === "number" && isFinite(a.temperature)) {
    target = formatTemp(a.temperature, unit)
  }
  if (target) {
    readings.push({
      entityId: String(entity.entity_id || ""),
      kind: "climate_target",
      label: "Target",
      value: "→ " + target,
      quality: "neutral",
      order: 20
    })
  }

  if (!readings.length) {
    readings.push({
      entityId: String(entity.entity_id || ""),
      kind: "climate_state",
      label: "Mode",
      value: displayState(entity),
      quality: "neutral",
      order: 10
    })
  }
  return readings
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

// ---------------------------------------------------------------- cover

// Home Assistant already reports current_position as a 0-100 percentage
// (100 = fully open), so this only validates and clamps rather than converts.
function coverPositionPercent(entity) {
  var value = attrs(entity).current_position
  if (typeof value !== "number" || !isFinite(value)) return -1
  return clampNumber(value, 0, 100)
}

// ---------------------------------------------------------- light colour

// Every mode here accepts hs_color on the way in — Home Assistant converts to
// the one the light actually speaks — so one wheel drives all of them.
// `color_temp` and `white` produce white light only, and are separate.
var COLOR_MODES = ["hs", "xy", "rgb", "rgbw", "rgbww"]

// Home Assistant's own fallbacks, for a light that publishes no limits.
var DEFAULT_MIN_KELVIN = 2000
var DEFAULT_MAX_KELVIN = 6535

function clampNumber(value, low, high) {
  return Math.min(Math.max(value, low), high)
}

function colorModes(entity) {
  var modes = attrs(entity).supported_color_modes
  if (!Array.isArray(modes)) return []
  var out = []
  for (var i = 0; i < modes.length; i++) {
    if (typeof modes[i] === "string") out.push(modes[i])
  }
  return out
}

// Capability comes from supported_color_modes, never from a currently non-null
// hs_color: a colour light that is off reports no colour at all, which is
// exactly when someone wants the picker.
function supportsColor(entity) {
  if (domain(entity) !== "light") return false
  var modes = colorModes(entity)
  for (var i = 0; i < modes.length; i++) {
    if (COLOR_MODES.indexOf(modes[i]) !== -1) return true
  }
  return false
}

function supportsColorTemp(entity) {
  if (domain(entity) !== "light") return false
  return colorModes(entity).indexOf("color_temp") !== -1
}

// { hue: 0-360, saturation: 0-100 }, or null when the light reports no colour.
// Home Assistant publishes hs_color for every colour light whatever its native
// mode — including one in colour-temperature mode, where it derives a hue from
// the temperature — so this one attribute covers xy and rgb lights too.
function hsColor(entity) {
  var value = attrs(entity).hs_color
  if (!Array.isArray(value) || value.length < 2) return null
  var hue = Number(value[0])
  var saturation = Number(value[1])
  if (!isFinite(hue) || !isFinite(saturation)) return null
  return {
    hue: clampNumber(hue, 0, 360),
    saturation: clampNumber(saturation, 0, 100)
  }
}

// Instances before 2022.11 publish mireds instead of kelvin. The ends swap in
// the conversion: the largest mired is the warmest light, so it becomes the
// *minimum* kelvin.
function kelvinRange(entity) {
  var a = attrs(entity)
  var min = typeof a.min_color_temp_kelvin === "number"
    ? a.min_color_temp_kelvin
    : (typeof a.max_mireds === "number" && a.max_mireds > 0
      ? Math.round(1000000 / a.max_mireds) : DEFAULT_MIN_KELVIN)
  var max = typeof a.max_color_temp_kelvin === "number"
    ? a.max_color_temp_kelvin
    : (typeof a.min_mireds === "number" && a.min_mireds > 0
      ? Math.round(1000000 / a.min_mireds) : DEFAULT_MAX_KELVIN)
  if (!isFinite(min) || !isFinite(max) || min >= max) {
    return { min: DEFAULT_MIN_KELVIN, max: DEFAULT_MAX_KELVIN }
  }
  return { min: min, max: max }
}

function colorTempKelvin(entity) {
  var a = attrs(entity)
  if (typeof a.color_temp_kelvin === "number" && isFinite(a.color_temp_kelvin)) {
    return a.color_temp_kelvin
  }
  if (typeof a.color_temp === "number" && a.color_temp > 0) {
    return Math.round(1000000 / a.color_temp)
  }
  return -1
}

// True while the light renders white from its colour-temperature channel
// rather than a hue. Only decides which control reads as the live one; both
// stay usable.
function isColorTempActive(entity) {
  return cleaned(attrs(entity).color_mode) === "color_temp"
}

// Home Assistant treats hue as a half-open range: 360 is rejected, and it is
// the same colour as 0 anyway. Round before wrapping, or 359.999 rounds up
// into the value the wrap exists to avoid.
function lightColorData(hue, saturation) {
  if (typeof hue !== "number" || !isFinite(hue)) return null
  if (typeof saturation !== "number" || !isFinite(saturation)) return null
  var rounded = Math.round(hue * 100) / 100
  return {
    hs_color: [
      ((rounded % 360) + 360) % 360,
      Math.round(clampNumber(saturation, 0, 100) * 100) / 100
    ]
  }
}

function lightColorTempData(entity, kelvin) {
  if (typeof kelvin !== "number" || !isFinite(kelvin)) return null
  var range = kelvinRange(entity)
  return { color_temp_kelvin: Math.round(clampNumber(kelvin, range.min, range.max)) }
}

// ------------------------------------------------ optimistic reconciliation

// A control shows the value someone picked until the entity reports it back.
// The tolerances are the cost of the round trip: brightness travels as a
// 0-255 byte, colour temperature as an integer mired, and a light answers in
// whatever colour space it speaks.

function settledWithin(live, wanted, slack) {
  if (typeof live !== "number" || !isFinite(live)) return false
  if (typeof wanted !== "number" || !isFinite(wanted)) return false
  return Math.abs(live - wanted) <= slack
}

// Hue is circular: 358 and 2 are four degrees apart, not 356.
function hueGap(one, other) {
  var gap = Math.abs(one - other) % 360
  return Math.min(gap, 360 - gap)
}

function brightnessSettled(entity, percent) {
  if (typeof percent !== "number" || !isFinite(percent)) return false
  // Zero is a turn_off, and a light that is off publishes no brightness.
  if (percent <= 0) return !isOn(entity)
  return settledWithin(brightnessPercent(entity), percent, 0.5)
}

function colorSettled(entity, hue, saturation) {
  if (isColorTempActive(entity)) return false
  var live = hsColor(entity)
  if (!live) return false
  if (!settledWithin(live.saturation, saturation, 2)) return false
  // Hue survives the light's colour space in proportion to saturation, and at
  // the centre of the wheel every angle is the same white.
  return hueGap(live.hue, hue) <= Math.min(180, 500 / saturation)
}

// Compared in mireds, which is what Home Assistant stores: the same kelvin
// tolerance would be four kelvin at the warm end and forty at the cold one.
function colorTempSettled(entity, kelvin) {
  if (typeof kelvin !== "number" || !isFinite(kelvin) || kelvin <= 0) return false
  if (!isColorTempActive(entity)) return false
  var live = colorTempKelvin(entity)
  if (live <= 0) return false
  return settledWithin(1000000 / live, 1000000 / kelvin, 1)
}

function volumeSettled(entity, level) {
  return settledWithin(volumeLevel(entity), level, 0.01)
}

// Whole percent, like the brightness slider: Home Assistant echoes back the
// same integer sent, so no device-side rounding slack is needed.
function coverPositionSettled(entity, percent) {
  if (typeof percent !== "number" || !isFinite(percent)) return false
  return settledWithin(coverPositionPercent(entity), percent, 0.5)
}

// Rounded either side of `round`: float noise must not cost a whole step, nor
// reach the value that gets sent.
function gridPoint(base, step, value, round) {
  var steps = Math.round((value - base) / step * 1e6) / 1e6
  return Math.round((base + round(steps) * step) * 1e6) / 1e6
}

// A bound comes from the device and need not sit on the grid, so a snapped
// value can land past it.
function snapToStep(value, base, step, min, max, round) {
  if (typeof value !== "number" || !isFinite(value)) return value
  var clamped = clampNumber(value, min, max)
  if (typeof step !== "number" || !isFinite(step) || step <= 0
      || typeof base !== "number" || !isFinite(base)) {
    return clamped
  }
  var snapped = gridPoint(base, step, clamped, round || Math.round)
  if (snapped > max) snapped = gridPoint(base, step, max, Math.floor)
  if (snapped < min) snapped = gridPoint(base, step, min, Math.ceil)
  // Bounds narrower than a step hold no grid point; off the grid beats past a
  // limit the device just reported.
  if (snapped > max || snapped < min) return clamped
  return snapped
}

function temperatureSettled(entity, attribute, value, step) {
  var slack = typeof step === "number" && isFinite(step) && step > 0
    ? step / 2 : 0.25
  return settledWithin(attrs(entity)[attribute], value, slack)
}

// ------------------------------------------------------------ command tags

// Identifies the call, not the entity. Reaches IPC and the bridge's logs, so
// it carries nothing but an entity id and a counter.
var CALL_TAG_PREFIX = "call:"

function callTag(entityId, sequence) {
  return CALL_TAG_PREFIX + String(entityId) + ":" + String(sequence)
}

function isCallTag(tag) {
  return String(tag || "").indexOf(CALL_TAG_PREFIX) === 0
}

function callTagMatches(pendingTag, failedTag) {
  if (!pendingTag || !failedTag) return false
  return String(pendingTag) === String(failedTag)
}

// ------------------------------------------------------- colour conversion

// Ported from the frontend's temperature2rgb: a temperature swatch has to be
// the colour the app draws, and a second approximation of the curve would not
// be. rgbToHs/hsToRgb/matchMaxScale/rgbw*ToRgb below come from the same place.
function temperatureToRgb(kelvin) {
  var t = clampNumber(kelvin, 1000, 40000) / 100
  var red = t <= 66
    ? 255
    : clampNumber(329.698727446 * Math.pow(t - 60, -0.1332047592), 0, 255)
  var green = t <= 66
    ? clampNumber(99.4708025861 * Math.log(t) - 161.1195681661, 0, 255)
    : clampNumber(288.1221695283 * Math.pow(t - 60, -0.0755148492), 0, 255)
  var blue = t >= 66
    ? 255
    : (t <= 19
      ? 0
      : clampNumber(138.5177312231 * Math.log(t - 10) - 305.0447927307, 0, 255))
  return [Math.round(red), Math.round(green), Math.round(blue)]
}

function rgbToHs(rgb) {
  var red = clampNumber(rgb[0], 0, 255) / 255
  var green = clampNumber(rgb[1], 0, 255) / 255
  var blue = clampNumber(rgb[2], 0, 255) / 255
  var high = Math.max(red, green, blue)
  var low = Math.min(red, green, blue)
  var delta = high - low

  var hue = 0
  if (delta > 0) {
    if (high === red) hue = 60 * (((green - blue) / delta) % 6)
    else if (high === green) hue = 60 * ((blue - red) / delta + 2)
    else hue = 60 * ((red - green) / delta + 4)
  }
  if (hue < 0) hue += 360

  return {
    hue: Math.round(hue * 100) / 100,
    saturation: Math.round((high === 0 ? 0 : delta / high) * 10000) / 100
  }
}

function hsToRgb(hue, saturation) {
  var h = (((hue % 360) + 360) % 360) / 60
  var s = clampNumber(saturation, 0, 100) / 100
  var chroma = s
  var second = chroma * (1 - Math.abs((h % 2) - 1))
  var rgb = [0, 0, 0]
  if (h < 1) rgb = [chroma, second, 0]
  else if (h < 2) rgb = [second, chroma, 0]
  else if (h < 3) rgb = [0, chroma, second]
  else if (h < 4) rgb = [0, second, chroma]
  else if (h < 5) rgb = [second, 0, chroma]
  else rgb = [chroma, 0, second]
  var offset = 1 - chroma
  return [
    Math.round((rgb[0] + offset) * 255),
    Math.round((rgb[1] + offset) * 255),
    Math.round((rgb[2] + offset) * 255)
  ]
}

// Scales a converted colour so its brightest channel matches the input's,
// which is what keeps the two below from overflowing.
function matchMaxScale(inputs, outputs) {
  var maxIn = Math.max.apply(null, inputs)
  var maxOut = Math.max.apply(null, outputs)
  var factor = maxOut === 0 ? 0 : maxIn / maxOut
  var scaled = []
  for (var i = 0; i < outputs.length; i++) {
    scaled.push(Math.round(outputs[i] * factor))
  }
  return scaled
}

function rgbwToRgb(rgbw) {
  var white = rgbw[3]
  return matchMaxScale(rgbw,
    [rgbw[0] + white, rgbw[1] + white, rgbw[2] + white])
}

function rgbwwToRgb(rgbww, minKelvin, maxKelvin) {
  var cold = rgbww[3]
  var warm = rgbww[4]
  var maxMireds = 1000000 / minKelvin
  var minMireds = 1000000 / maxKelvin
  var ratio = (cold + warm) === 0 ? 0.5 : warm / (cold + warm)
  var mireds = minMireds + ratio * (maxMireds - minMireds)
  var white = temperatureToRgb(1000000 / mireds)
  var level = Math.max(cold, warm) / 255
  return matchMaxScale(rgbww, [
    rgbww[0] + white[0] * level,
    rgbww[1] + white[1] * level,
    rgbww[2] + white[2] * level
  ])
}

function xyToRgb(xy) {
  var x = xy[0]
  var y = xy[1]
  if (!(y > 0)) return [0, 0, 0]
  var bigX = x / y
  var bigZ = (1 - x - y) / y
  var linear = [
    bigX * 3.2406 - 1.5372 - bigZ * 0.4986,
    -bigX * 0.9689 + 1.8758 + bigZ * 0.0415,
    bigX * 0.0557 - 0.2040 + bigZ * 1.0570
  ]
  var peak = Math.max(linear[0], linear[1], linear[2])
  var out = []
  for (var i = 0; i < 3; i++) {
    var c = clampNumber(peak > 1 ? linear[i] / peak : linear[i], 0, 1)
    out.push(255 * (c <= 0.0031308
      ? 12.92 * c
      : 1.055 * Math.pow(c, 1 / 2.4) - 0.055))
  }
  return out
}

// ------------------------------------------------------- favourite colours

// Home Assistant keeps per-light favourites in the entity registry under
// options.light.favorite_colors, and computes a set for the many lights with
// none saved. Both are mirrored, so the panel offers the app's swatches
// rather than a private palette sitting next to one.
var COLOR_TEMP_COUNT = 4
var DEFAULT_COLORED_COLORS = [
  [127, 172, 255],
  [215, 150, 255],
  [255, 158, 243],
  [255, 110, 84]
]

// The registry is server-controlled and unbounded; the app's own editor stops
// well short of this.
var MAX_FAVORITE_COLORS = 24

function numberArray(value, length) {
  if (!Array.isArray(value) || value.length < length) return null
  var out = []
  for (var i = 0; i < length; i++) {
    var number = Number(value[i])
    if (!isFinite(number)) return null
    out.push(number)
  }
  return out
}

// A favourite is normalized into the same hue/saturation or kelvin the wheel
// and the warmth slider produce, never carried around as a raw registry
// object, so a saved favourite cannot become an arbitrary service call.
function hsFavorite(hue, saturation) {
  return {
    kind: "color", hue: hue, saturation: saturation, kelvin: -1,
    rgb: hsToRgb(hue, saturation)
  }
}

function colorFavorite(rgb) {
  var hs = rgbToHs(rgb)
  return {
    kind: "color", hue: hs.hue, saturation: hs.saturation, kelvin: -1,
    rgb: [Math.round(clampNumber(rgb[0], 0, 255)),
          Math.round(clampNumber(rgb[1], 0, 255)),
          Math.round(clampNumber(rgb[2], 0, 255))]
  }
}

function colorTempFavorite(kelvin) {
  return {
    kind: "colorTemp", hue: -1, saturation: -1, kelvin: Math.round(kelvin),
    rgb: temperatureToRgb(kelvin)
  }
}

function parseFavoriteColor(entity, raw) {
  if (!raw || typeof raw !== "object") return null
  var range = kelvinRange(entity)

  if (typeof raw.color_temp_kelvin === "number"
      && isFinite(raw.color_temp_kelvin)) {
    if (!supportsColorTemp(entity)) return null
    return colorTempFavorite(
      clampNumber(raw.color_temp_kelvin, range.min, range.max))
  }
  if (!supportsColor(entity)) return null

  // Saved hue and saturation are authoritative; converting them to rgb and
  // back would round a low-saturation favourite into a visibly different hue.
  var hs = numberArray(raw.hs_color, 2)
  if (hs) {
    return hsFavorite(clampNumber(hs[0], 0, 360), clampNumber(hs[1], 0, 100))
  }
  var rgb = numberArray(raw.rgb_color, 3)
  if (rgb) return colorFavorite(rgb)

  var xy = numberArray(raw.xy_color, 2)
  if (xy) return colorFavorite(xyToRgb(xy))

  var rgbw = numberArray(raw.rgbw_color, 4)
  if (rgbw) return colorFavorite(rgbwToRgb(rgbw))

  var rgbww = numberArray(raw.rgbww_color, 5)
  if (rgbww) return colorFavorite(rgbwwToRgb(rgbww, range.min, range.max))

  return null
}

// The frontend's computeDefaultFavoriteColors: colour temperatures stepped
// across the light's own range when it has one, otherwise the same steps
// rendered as colours, then four fixed picks. The 2000/6500 bounds of the
// colour-only branch are upstream's literals, not the defaults above.
function defaultFavoriteColors(entity) {
  var out = []
  var hasTemp = supportsColorTemp(entity)
  var hasColor = supportsColor(entity)

  if (hasTemp) {
    var range = kelvinRange(entity)
    var step = (range.max - range.min) / (COLOR_TEMP_COUNT - 1)
    for (var i = 0; i < COLOR_TEMP_COUNT; i++) {
      out.push(colorTempFavorite(Math.round(range.min + step * i)))
    }
  } else if (hasColor) {
    var whiteStep = (6500 - 2000) / (COLOR_TEMP_COUNT - 1)
    for (var w = 0; w < COLOR_TEMP_COUNT; w++) {
      out.push(colorFavorite(
        temperatureToRgb(Math.round(2000 + whiteStep * w))))
    }
  }

  if (hasColor) {
    for (var c = 0; c < DEFAULT_COLORED_COLORS.length; c++) {
      out.push(colorFavorite(DEFAULT_COLORED_COLORS[c]))
    }
  }
  return out
}

// A list in the registry is a choice, whatever it holds: emptied, or filled
// with entries this light cannot render — temperatures kept from before it
// stopped advertising color_temp — it still means "not the defaults". Only an
// absent list is an unanswered question. Every entry is still validated, so a
// saved favourite can never become an arbitrary service call.
function favoriteColors(entity, saved) {
  if (!entity || domain(entity) !== "light") return []
  if (!Array.isArray(saved)) return defaultFavoriteColors(entity)
  var out = []
  var list = saved.slice(0, MAX_FAVORITE_COLORS)
  for (var i = 0; i < list.length; i++) {
    var parsed = parseFavoriteColor(entity, list[i])
    if (parsed) out.push(parsed)
  }
  return out
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
var COVER_SET_POSITION = 4
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
    color: available && supportsColor(entity),
    colorTemp: available && supportsColorTemp(entity),
    mediaPrevious: false,
    mediaPlayPause: false,
    mediaNext: false,
    mediaVolume: false,
    coverOpen: false,
    coverStop: false,
    coverClose: false,
    coverPosition: false,
    climateTarget: false,
    climateRange: false,
    climateHvacMode: false,
    climateFanMode: false,
    climatePresetMode: false,
    climateSwingMode: false,
    historyGraph: false,
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
    // Unlike brightness, current_position is not required: it is a state
    // attribute, not part of the capability contract, so a cover that
    // advertises the feature but has not reported a position yet (or reports
    // one only while moving) must still get the control. coverPositionPercent
    // already falls back to 0 for the slider when no position is known.
    result.coverPosition = hasFeature(bits, COVER_SET_POSITION)
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
  result.historyGraph = available && hasHistoryGraph(entity)
  result.expandable = result.brightness || result.color || result.colorTemp
    || result.mediaPrevious || result.mediaPlayPause || result.mediaNext
    || result.mediaVolume || result.coverOpen || result.coverStop
    || result.coverClose || result.coverPosition
    || result.climateTarget || result.climateRange
    || result.climateHvacMode || result.climateFanMode
    || result.climatePresetMode || result.climateSwingMode
    || result.historyGraph
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
  "cover.living_room_blinds",
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

function panelActivityEntities(favoriteIds, roomCards, states) {
  var entities = states && typeof states === "object" ? states : {}
  var favorites = Array.isArray(favoriteIds) ? favoriteIds : []
  var cards = Array.isArray(roomCards) ? roomCards : []
  var seen = Object.create(null)
  var picked = []

  function add(entityId) {
    var id = String(entityId || "")
    if (!id || seen[id] || !entities[id]) return
    seen[id] = true
    picked.push(entities[id])
  }

  for (var i = 0; i < favorites.length; i++) add(favorites[i])
  for (var n = 0; n < cards.length; n++) {
    var card = cards[n] || {}
    if (card.controlEntityId) add(card.controlEntityId)
    else if (card.readings && card.readings.length) add(card.readings[0].entityId)
  }
  return picked
}

// Settings browser buckets. No "Cameras" until cameras ship.
var DOMAIN_FILTERS = [
  { id: "all", title: "All", domains: [] },
  { id: "room_readings", title: "Room readings", domains: [] },
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

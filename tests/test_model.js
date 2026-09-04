#!/usr/bin/env node
// Unit tests for Model.js. Run: node tests/test_model.js
//
// Model.js holds every formatting and classification rule the panel draws
// from. It is a QML JS library, not a CommonJS module, so it is loaded by
// stripping the `.pragma` line and evaluating it.

const fs = require("fs");
const path = require("path");

const source = fs
  .readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "");

const names = [...source.matchAll(/^function\s+([A-Za-z0-9_]+)/gm)].map((m) => m[1]);
const consts = [...source.matchAll(/^var\s+([A-Z][A-Z0-9_]*)/gm)].map((m) => m[1]);
const Model = new Function(`${source}\nreturn {${[...names, ...consts].join(",")}};`)();

let failures = 0;
let checks = 0;

function eq(label, actual, expected) {
  checks++;
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (!ok) {
    failures++;
    console.log(`  FAIL ${label}\n       got      ${JSON.stringify(actual)}` +
                `\n       expected ${JSON.stringify(expected)}`);
  }
}

function entity(entity_id, state, attributes) {
  return { entity_id, state, attributes: attributes || {} };
}

function section(title, body) {
  console.log(title);
  const before = failures;
  body();
  console.log(before === failures ? "  ok" : "  ^^ failures above");
}

section("identity and naming", () => {
  eq("domain from id", Model.domainOf("light.kitchen"), "light");
  eq("no dot means no domain", Model.domainOf("bogus"), "");
  eq("friendly_name wins",
     Model.name(entity("light.a", "on", { friendly_name: "Desk" })), "Desk");
  eq("falls back to entity_id", Model.name(entity("light.a", "on")), "light.a");
  eq("blank friendly_name is ignored",
     Model.name(entity("light.a", "on", { friendly_name: "   " })), "light.a");
});

section("on/off semantics", () => {
  // Locked and open count as "on", so a lock and a cover read like a light.
  eq("on", Model.isOn(entity("light.a", "on")), true);
  eq("locked is on", Model.isOn(entity("lock.a", "locked")), true);
  eq("open is on", Model.isOn(entity("cover.a", "open")), true);
  eq("off", Model.isOn(entity("light.a", "off")), false);
  eq("closed is off", Model.isOn(entity("cover.a", "closed")), false);
  eq("unlocked is off", Model.isOn(entity("lock.a", "unlocked")), false);
  eq("a climate HVAC mode is on", Model.isOn(entity("climate.a", "heat")), true);
  eq("climate off is off", Model.isOn(entity("climate.a", "off")), false);
  eq("unavailable climate is not on",
     Model.isOn(entity("climate.a", "unavailable")), false);
});

section("state text", () => {
  eq("unit is appended",
     Model.displayState(entity("sensor.a", "22.3", { unit_of_measurement: "°C" })),
     "22.3 °C");
  eq("on is capitalised", Model.displayState(entity("light.a", "on")), "On");
  eq("off is capitalised", Model.displayState(entity("light.a", "off")), "Off");
  eq("unavailable passes through",
     Model.displayState(entity("light.a", "unavailable")), "Unavailable");
  eq("unknown counts as unavailable",
     Model.isUnavailable(entity("scene.a", "unknown")), true);
  eq("a unit does not leak into an unavailable state",
     Model.displayState(entity("sensor.a", "unavailable", { unit_of_measurement: "°C" })),
     "Unavailable");
});

section("subtitles", () => {
  eq("climate shows target and current",
     Model.subtitle(entity("climate.a", "heat", {
       temperature: 22.0, current_temperature: 21.4, temperature_unit: "°C" })),
     "Target 22°C · Now 21.4°C");
  eq("climate range replaces the single target",
     Model.subtitle(entity("climate.a", "heat", {
       target_temp_low: 18, target_temp_high: 24, temperature_unit: "°C" })),
     "Target 18°C–24°C");
  eq("media shows artist and title",
     Model.subtitle(entity("media_player.a", "playing", {
       media_title: "Open Floor", media_artist: "Daylight FM" })),
     "Daylight FM — Open Floor");
  eq("media falls back to the channel",
     Model.subtitle(entity("media_player.a", "playing", { media_channel: "BBC 6" })),
     "BBC 6");
  eq("media with nothing playing shows the state",
     Model.subtitle(entity("media_player.a", "paused")), "Paused");
  eq("a toggle shows its state",
     Model.subtitle(entity("switch.a", "off")), "Off");
  eq("a scene stays available despite an unknown state",
     Model.isAvailable(entity("scene.a", "unknown")), true);
  eq("a script stays available too",
     Model.isAvailable(entity("script.a", "unknown")), true);
  eq("an unavailable light is not available",
     Model.isAvailable(entity("light.a", "unavailable")), false);
  eq("a missing entity is not available", Model.isAvailable(null), false);
  eq("a normal light is available", Model.isAvailable(entity("light.a", "off")), true);

  eq("a sensor has no subtitle",
     Model.subtitle(entity("sensor.a", "5", { unit_of_measurement: "lx" })), "");
});

section("badges", () => {
  eq("scene", Model.badgeText(entity("scene.a", "unknown")), "Scene");
  eq("camera", Model.badgeText(entity("camera.a", "streaming")), "Camera");
  // hvac_action is what a real climate entity exposes; the mode is the state.
  eq("climate prefers hvac_action",
     Model.badgeText(entity("climate.a", "heat", { hvac_action: "idle" })), "Idle");
  eq("climate falls back to the state, which is the mode",
     Model.badgeText(entity("climate.a", "heat")), "Heat");
});

section("room-reading classification", () => {
  const temperature = entity("sensor.air_temperature", "26", {
    device_class: "temperature", unit_of_measurement: "°C"
  });
  eq("temperature becomes a compact room reading", Model.environmentalReading(temperature), {
    entityId: "sensor.air_temperature", kind: "temperature", label: "Temperature",
    sourceLabel: "sensor.air_temperature", value: "26 °C",
    quality: "neutral", order: 10
  });
  eq("PM2.5 gets a quality band",
     Model.environmentalReading(entity("sensor.air_pm2_5", "5", {
       device_class: "pm25", unit_of_measurement: "µg/m³"
     })).quality, "good");
  eq("VOC index fallback recognizes an unambiguous unitless name",
     Model.environmentalReading(entity("sensor.air_voc_index", "250")).kind,
     "voc_index");
  const voc = (value) => entity("sensor.air_voc_index", String(value));
  const vindstyrka = {
    manufacturer: "IKEA of Sweden",
    model: "VINDSTYRKA air quality and humidity sensor"
  };
  [[150, "good"], [151, "moderate"], [250, "moderate"],
   [251, "poor"], [400, "poor"], [401, "critical"]].forEach(([value, quality]) => {
    eq(`IKEA VOC index ${value} is ${quality}`,
       Model.environmentalReading(voc(value), vindstyrka).quality, quality);
  });
  eq("IKEA's E2112 model number is recognized",
     Model.environmentalReading(voc(251), {
       manufacturer: "IKEA", model: "E2112"
     }).quality, "poor");
  eq("a generic VOC index does not inherit IKEA bands",
     Model.environmentalReading(voc(401), {
       manufacturer: "Other", model: "VINDSTYRKA"
     }).quality, "neutral");
  eq("another IKEA device does not inherit VINDSTYRKA bands",
     Model.environmentalReading(voc(401), {
       manufacturer: "IKEA", model: "STARKVIND"
     }).quality, "neutral");
  eq("battery is not treated as a room reading",
     Model.environmentalReading(entity("sensor.air_battery", "100", {
       device_class: "battery"
     })), null);
  eq("a shared device name cannot turn a battery into temperature",
     Model.environmentalReading(entity("sensor.temperature_kids_battery", "96", {
       friendly_name: "Temperature Kids Battery", device_class: "battery",
       unit_of_measurement: "%"
     })), null);
  eq("device class wins over a misleading shared name",
     Model.environmentalReading(entity("sensor.temperature_kids_humidity", "50", {
       friendly_name: "Temperature Kids Humidity", device_class: "humidity",
       unit_of_measurement: "%"
     })).kind, "humidity");
  eq("a classless temperature needs an unambiguous name and unit",
     Model.environmentalReading(entity("sensor.room_probe", "22", {
       friendly_name: "Room probe", unit_of_measurement: "°C"
     })), null);
  eq("a named classless temperature can fall back safely",
     Model.environmentalReading(entity("sensor.room_temperature", "22", {
       friendly_name: "Room temperature", unit_of_measurement: "°C"
     })).kind, "temperature");
  eq("Home Assistant's canonical AQI device class is accepted",
     Model.environmentalReading(entity("sensor.outdoor_aqi", "42", {
       device_class: "aqi"
     })).kind, "aqi");
  eq("the non-existent air_quality_index class is not accepted",
     Model.environmentalReading(entity("sensor.outdoor_aqi", "42", {
       device_class: "air_quality_index"
     })), null);

  for (const metric of ["cpu", "memory", "storage", "load"]) {
    eq(`classless ${metric} percentage is not humidity`,
       Model.environmentalReading(entity(`sensor.dream_machine_${metric}`, "54", {
         friendly_name: `Dream Machine ${metric}`, unit_of_measurement: "%"
       })), null);
  }
  eq("classless humidity needs both its name and compatible unit",
     Model.environmentalReading(entity("sensor.room_humidity", "54", {
       friendly_name: "Room humidity", unit_of_measurement: "%"
     })).kind, "humidity");

  eq("CO ppb is converted before applying ppm bands",
     Model.environmentalQuality("co", "4000", "ppb", null), "good");
  eq("CO ppm is not confused with ppb",
     Model.environmentalQuality("co", "4000", "ppm", null), "critical");
  eq("mass concentration CO stays neutral without a physical conversion",
     Model.environmentalQuality("co", "4000", "µg/m³", null), "neutral");
  eq("PM mass concentration accepts equivalent mg units",
     Model.environmentalQuality("pm25", "0.035", "mg/m³", null), "poor");

  const duplicateHumidity = Model.distinguishEnvironmentalReadings([
    Model.environmentalReading(entity("sensor.north_humidity", "50", {
      friendly_name: "North humidity", device_class: "humidity",
      unit_of_measurement: "%"
    })),
    Model.environmentalReading(entity("sensor.south_humidity", "45", {
      friendly_name: "South humidity", device_class: "humidity",
      unit_of_measurement: "%"
    }))
  ]);
  eq("duplicate kinds retain distinguishing entity names",
     duplicateHumidity.map((reading) => reading.label),
     ["North humidity", "South humidity"]);
  const sameNamedHumidity = Model.distinguishEnvironmentalReadings([
    Model.environmentalReading(entity("sensor.north_humidity", "50", {
      friendly_name: "Humidity", device_class: "humidity",
      unit_of_measurement: "%"
    })),
    Model.environmentalReading(entity("sensor.south_humidity", "45", {
      friendly_name: "Humidity", device_class: "humidity",
      unit_of_measurement: "%"
    }))
  ]);
  eq("same-named duplicate kinds fall back to distinct entity object IDs",
     sameNamedHumidity.map((reading) => reading.label),
     ["Humidity (north_humidity)", "Humidity (south_humidity)"]);

  const primary = entity("switch.ikea_air_monitor", "on", {
    friendly_name: "Ikea Air Monitor"
  });
  eq("a switch named for its device is a safe primary control",
     Model.isSafePrimaryControl(primary, "Ikea Air Monitor", {}), true);
  eq("a configuration entity cannot become the primary control",
     Model.isSafePrimaryControl(primary, "Ikea Air Monitor",
       { entityCategory: "config" }), false);
  eq("identify is never selected as a primary control",
     Model.isSafePrimaryControl(entity("switch.ikea_air_monitor_identify", "off", {
       friendly_name: "Ikea Air Monitor Identify"
     }), "Ikea Air Monitor", {}), false);
  eq("an unrelated auxiliary switch is not selected",
     Model.isSafePrimaryControl(entity("switch.child_lock", "off", {
       friendly_name: "Child lock"
     }), "Air purifier", {}), false);
  eq("a unique fan is eligible as an explicit device control",
     Model.isSafePrimaryControl(entity("fan.purifier", "on", {
       friendly_name: "Purifier fan"
     }), "Air purifier", {}), true);

  eq("room summary keeps the first readings compact",
     Model.roomReadingSummary([
       { kind: "temperature", label: "Temperature", value: "24.7 °C" },
       { kind: "humidity", label: "Humidity", value: "46.9 %" },
       { kind: "co2", label: "CO₂", value: "407 ppm" },
       { kind: "voc", label: "VOC", value: "12 ppb" },
       { kind: "pm25", label: "PM2.5", value: "4 µg/m³" }
     ], 3), "24.7 °C · 46.9 % · CO₂ 407 ppm · +2");
});

section("bar data readings", () => {
  const climate = entity("climate.office", "cool", {
    current_temperature: 25, temperature: 25.5
  });
  eq("climate is eligible for a bar reading",
     Model.barDataEligible(climate), true);
  eq("lights are not data widgets",
     Model.barDataEligible(entity("light.office", "on")), false);
  eq("AC shows current and target temperatures",
     Model.barDataReadings(climate, "°C"), [
       { entityId: "climate.office", kind: "climate_current", label: "Current",
         value: "25°C", quality: "neutral", order: 10 },
       { entityId: "climate.office", kind: "climate_target", label: "Target",
         value: "→ 25.5°C", quality: "neutral", order: 20 }
     ]);
  eq("an unavailable AC remains removable and identifiable",
     Model.barDataReadings(entity("climate.office", "unavailable"), "°C"), [
       { entityId: "climate.office", kind: "climate_state", label: "AC",
         value: "Unavailable", quality: "unknown", order: 10 }
     ]);
  eq("an individual VINDSTYRKA VOC widget uses the device bands",
     Model.barDataReadings(entity("sensor.air_voc_index", "151"), "", {
       manufacturer: "IKEA of Sweden", model: "VINDSTYRKA"
     })[0].quality, "moderate");
});

section("brightness", () => {
  // Modern Home Assistant advertises dimming through supported_color_modes.
  eq("a dimmable colour mode counts",
     Model.supportsBrightness(entity("light.a", "on",
       { supported_color_modes: ["brightness"] })), true);
  eq("a colour light is dimmable too",
     Model.supportsBrightness(entity("light.a", "on",
       { supported_color_modes: ["color_temp", "hs"] })), true);
  eq("an on/off-only light is not",
     Model.supportsBrightness(entity("light.a", "on",
       { supported_color_modes: ["onoff"] })), false);
  // The regression this rule exists for: Home Assistant nulls brightness when
  // the light is off, which must not read as "not dimmable".
  eq("a dimmable light that is off still offers the slider",
     Model.supportsBrightness(entity("light.a", "off",
       { supported_color_modes: ["brightness"], brightness: null })), true);
  eq("legacy supported_features bit 0 still counts",
     Model.supportsBrightness(entity("light.a", "on", { supported_features: 1 })), true);
  eq("a live brightness attribute alone is enough",
     Model.supportsBrightness(entity("light.a", "on", { brightness: 10 })), true);
  eq("a plain light is not dimmable",
     Model.supportsBrightness(entity("light.a", "on", { supported_features: 0 })), false);
  eq("only lights are dimmable",
     Model.supportsBrightness(entity("switch.a", "on", { brightness: 200 })), false);
  eq("255 is full", Model.brightnessPercent(entity("light.a", "on", { brightness: 255 })), 100);
  eq("0 is off", Model.brightnessPercent(entity("light.a", "on", { brightness: 0 })), 0);
  eq("missing brightness is signalled with -1",
     Model.brightnessPercent(entity("light.a", "on")), -1);
});

section("cover position", () => {
  eq("current_position passes through",
     Model.coverPositionPercent(entity("cover.a", "open", { current_position: 70 })), 70);
  eq("out-of-range position is clamped",
     Model.coverPositionPercent(entity("cover.a", "open", { current_position: 140 })), 100);
  eq("missing current_position is signalled with -1",
     Model.coverPositionPercent(entity("cover.a", "open")), -1);
});

section("temperature", () => {
  eq("a whole number drops its decimal", Model.formatTemp(22.0, "°C"), "22°C");
  eq("a fraction keeps one place", Model.formatTemp(21.44, "°C"), "21.4°C");
  eq("no unit, no suffix", Model.formatTemp(21.5, ""), "21.5");
  eq("celsius steps by a half",
     Model.temperatureStep(entity("climate.a", "heat", { temperature_unit: "°C" })), 0.5);
  eq("fahrenheit steps by one",
     Model.temperatureStep(entity("climate.a", "heat", { temperature_unit: "°F" })), 1.0);
  eq("a declared step wins over the guess",
     Model.temperatureStep(entity("climate.a", "heat", { target_temp_step: 0.1 })), 0.1);

  // A real climate entity has no unit attribute at all — the instance-wide one
  // arrives from the bridge and is passed in.
  eq("the instance unit is used when the entity has none",
     Model.subtitle(entity("climate.a", "heat", { temperature: 22.0 }), "°F"),
     "Target 22°F");
  eq("without any unit the number stands alone",
     Model.subtitle(entity("climate.a", "heat", { temperature: 22.0 })), "Target 22");
  eq("the instance unit drives the step too",
     Model.temperatureStep(entity("climate.a", "heat"), "°F"), 1.0);
  eq("and the fallback range",
     Model.temperatureRange(entity("climate.a", "heat"), "°F"), { min: 50, max: 90 });
  eq("declared limits win",
     Model.temperatureRange(entity("climate.a", "heat", { min_temp: 16, max_temp: 30 })),
     { min: 16, max: 30 });
  eq("nonsense limits fall back",
     Model.temperatureRange(entity("climate.a", "heat", { min_temp: 30, max_temp: 16 })),
     { min: 5, max: 35 });
  eq("fahrenheit has its own fallback",
     Model.temperatureRange(entity("climate.a", "heat", { temperature_unit: "°F" })),
     { min: 50, max: 90 });

  const rangeEntity = entity("climate.a", "heat", {
    supported_features: 2, target_temp_low: 18, target_temp_high: 24,
    min_temp: 10, max_temp: 30
  });

  const hvacEntity = entity("climate.a", "cool", {
    hvac_modes: ["off", "heat", "cool", "dry", "fan_only", "cool", "", 1]
  });
  eq("advertised climate HVAC modes are preserved and cleaned",
     Model.climateHvacModes(hvacEntity),
     ["off", "heat", "cool", "dry", "fan_only"]);
  eq("the HVAC mode is the climate state", Model.climateHvacMode(hvacEntity), "cool");
  eq("a climate HVAC mode needs advertised options, not a feature bit",
     Model.capabilitiesFor(hvacEntity).climateHvacMode, true);
  eq("the selected advertised HVAC mode maps to the typed service payload",
     Model.climateHvacModeData(hvacEntity, "dry"), { hvac_mode: "dry" });
  eq("an undeclared HVAC mode is rejected",
     Model.climateHvacModeData(hvacEntity, "turbo"), {});
  eq("HVAC mode without advertised options is rejected",
     Model.climateHvacModeData(entity("climate.a", "cool"), "heat"), {});
  eq("heat_cool has its conventional label",
     Model.climateHvacModeLabel("heat_cool"), "Heat/Cool");
  eq("custom mode separators are humanized",
     Model.climateFanModeLabel("eco_quiet-mode"), "Eco quiet mode");

  const optionalModeCases = [
    {
      name: "fan", capability: "climateFanMode", feature: 8,
      optionsAttribute: "fan_modes", currentAttribute: "fan_mode",
      selected: "high", options: ["auto", "high"],
      modes: Model.climateFanModes, data: Model.climateFanModeData,
      payload: { fan_mode: "high" }
    },
    {
      name: "preset", capability: "climatePresetMode", feature: 16,
      optionsAttribute: "preset_modes", currentAttribute: "preset_mode",
      selected: "away", options: ["none", "away"],
      modes: Model.climatePresetModes, data: Model.climatePresetModeData,
      payload: { preset_mode: "away" }
    },
    {
      name: "swing", capability: "climateSwingMode", feature: 32,
      optionsAttribute: "swing_modes", currentAttribute: "swing_mode",
      selected: "vertical", options: ["off", "vertical"],
      modes: Model.climateSwingModes, data: Model.climateSwingModeData,
      payload: { swing_mode: "vertical" }
    }
  ];

  optionalModeCases.forEach((modeCase) => {
    const attributes = { supported_features: modeCase.feature };
    attributes[modeCase.optionsAttribute] = modeCase.options;
    attributes[modeCase.currentAttribute] = modeCase.options[0];
    const modeEntity = entity("climate.a", "cool", attributes);

    eq(`${modeCase.name} modes are preserved`,
       modeCase.modes(modeEntity), modeCase.options);
    eq(`${modeCase.name} mode needs its feature and options`,
       Model.capabilitiesFor(modeEntity)[modeCase.capability], true);
    eq(`${modeCase.name} mode is absent without its feature`,
       Model.capabilitiesFor(entity("climate.a", "cool", {
         [modeCase.optionsAttribute]: modeCase.options
       }))[modeCase.capability], false);
    eq(`${modeCase.name} mode is absent without advertised options`,
       Model.capabilitiesFor(entity("climate.a", "cool", {
         supported_features: modeCase.feature
       }))[modeCase.capability], false);
    eq(`${modeCase.name} payload has only its typed key`,
       modeCase.data(modeEntity, modeCase.selected), modeCase.payload);
    eq(`${modeCase.name} rejects an undeclared value`,
       modeCase.data(modeEntity, "turbo"), {});
  });


  eq("crossed target bounds are normalized",
     Model.climateTemperatureData(rangeEntity, undefined, 27, 16, "°C"),
     { target_temp_low: 16, target_temp_high: 27 });
  eq("target bounds are clamped to the entity range",
     Model.climateTemperatureData(rangeEntity, undefined, -10, 50, "°C"),
     { target_temp_low: 10, target_temp_high: 30 });
  eq("an unsupported synthetic target is rejected",
     Model.climateTemperatureData(entity("climate.a", "heat"), 22, undefined,
                                  undefined, "°C"), {});
});

section("activity summary", () => {
  const light = (state) => entity("light.a", state, { friendly_name: "Lamp" });
  const sw = (state) => entity("switch.b", state, { friendly_name: "Plug" });
  const player = (state, n) => entity("media_player." + (n || "x"), state,
    { friendly_name: n || "Sonos" });

  eq("nothing picked", Model.activitySummary([]), "No devices picked");
  eq("everything off", Model.activitySummary([light("off"), sw("off")]), "All off");
  eq("one on", Model.activitySummary([light("on"), sw("off")]), "1 on");
  eq("several on", Model.activitySummary([light("on"), sw("on")]), "2 on");
  eq("a player names itself",
     Model.activitySummary([player("playing", "Sonos")]), "Sonos playing");
  eq("several players are counted, not listed",
     Model.activitySummary([player("playing", "a"), player("playing", "b")]),
     "2 playing");
  eq("a paused player is not playing",
     Model.activitySummary([player("paused", "Sonos")]), "All off");
  eq("both halves join",
     Model.activitySummary([light("on"), player("playing", "Sonos")]),
     "1 on · Sonos playing");
  // A locked door reads as `isOn`, but "3 on" must not be counting deadbolts.
  eq("locks are left out",
     Model.activitySummary([entity("lock.a", "locked"), light("off")]), "All off");
  eq("sensors are left out",
     Model.activitySummary([entity("sensor.a", "22.5"), light("off")]), "All off");
  eq("a missing entity is skipped", Model.activitySummary([null, light("on")]), "1 on");

  const activityStates = {
    "sensor.room_temperature": entity("sensor.room_temperature", "22.5"),
    "switch.air_monitor": entity("switch.air_monitor", "on")
  };
  const sensorOnly = Model.panelActivityEntities([], [{
    controlEntityId: "",
    readings: [{ entityId: "sensor.room_temperature" }]
  }], activityStates);
  eq("a sensor-only room still counts as a selected panel item",
     Model.activitySummary(sensorOnly), "All off");
  const controlledRoom = Model.panelActivityEntities([], [{
    controlEntityId: "switch.air_monitor", readings: []
  }], activityStates);
  eq("a room primary control participates in activity",
     Model.activitySummary(controlledRoom), "1 on");
});

section("demo starter picks match the demo house", () => {
  // The ids live in two files — this list and the bridge's fake house. A stale
  // one here would show up as an unavailable ghost row the moment someone
  // turns demo mode on, so read the bridge and compare.
  const bridge = fs.readFileSync(path.join(__dirname, "..", "bin", "hass-bridge"), "utf8");
  const block = bridge.slice(bridge.indexOf("DEMO_DEVICES = {"),
                             bridge.indexOf("DEMO_PLAYLIST"));
  const known = new Set([...block.matchAll(/"([a-z_]+\.[a-z0-9_]+)":/g)].map((m) => m[1]));

  eq("the bridge's demo house was found", known.size > 0, true);
  const missing = Model.DEMO_DEFAULT_FAVORITES.filter((id) => !known.has(id));
  eq("every starter pick exists in the demo house", missing, []);
  eq("there are some starter picks", Model.DEMO_DEFAULT_FAVORITES.length > 0, true);
});

section("control classification", () => {
  eq("light is a toggle", Model.controlKind(entity("light.a", "on")), "toggle");
  eq("humidifier is a toggle", Model.controlKind(entity("humidifier.a", "on")), "toggle");
  eq("climate with turn-off support is a toggle",
     Model.controlKind(entity("climate.a", "heat", { supported_features: 128 })),
     "toggle");
  eq("climate without the required turn-off support is not a toggle",
     Model.controlKind(entity("climate.a", "heat", { supported_features: 256 })),
     "none");
  eq("lock is its own kind", Model.controlKind(entity("lock.a", "locked")), "lock");
  eq("scene is one-shot", Model.controlKind(entity("scene.a", "unknown")), "activate");
  eq("script is one-shot", Model.controlKind(entity("script.a", "off")), "activate");
  eq("sensor has no control", Model.controlKind(entity("sensor.a", "5")), "none");
  eq("a numeric sensor is graphable",
     Model.hasHistoryGraph(entity("sensor.a", "22.3")), true);
  eq("a blank numeric parse is rejected",
     Model.parseNumericState("  "), null);
  eq("text sensors are not graphable",
     Model.hasHistoryGraph(entity("sensor.weather", "sunny")), false);
  eq("binary sensors are not graphable",
     Model.hasHistoryGraph(entity("binary_sensor.a", "on")), false);
  eq("history windows are 1, 3, 6, 12 or 24 hours",
     [Model.normalizeHistoryHours(1), Model.normalizeHistoryHours(3),
      Model.normalizeHistoryHours(6), Model.normalizeHistoryHours(12),
      Model.normalizeHistoryHours(24), Model.normalizeHistoryHours(2),
      Model.normalizeHistoryHours("3"), Model.normalizeHistoryHours(null)],
     [1, 3, 6, 12, 24, 0, 3, 0]);
  eq("a day window is labelled 1d", Model.historyWindowLabel(24), "1d");
  eq("an hour window keeps an h suffix", Model.historyWindowLabel(12), "12h");
  eq("history axis follows a server clock ahead of the desktop",
     Model.historyAxisEnd([{t: 110, v: 2}], 1, 100), 110);
  eq("history axis follows a server clock beyond the local window",
     Model.historyAxisEnd([{t: 100, v: 2}], 1, 4000), 100);
  eq("history axis otherwise advances to local now",
     Model.historyAxisEnd([{t: 90, v: 2}], 1, 100), 100);
  eq("hover uses the last known sample at the cursor time",
     Model.nearestHistoryIndex(
       [{ t: 10, v: 1 }, { t: 20, v: 2 }, { t: 30, v: 3 }],
       75, 0, 100, 10, 30),
     1);
  eq("hover after the last sample keeps the last value",
     Model.nearestHistoryIndex(
       [{ t: 10, v: 1 }, { t: 20, v: 2 }],
       100, 0, 100, 10, 40),
     1);
  eq("an empty series has no hover sample",
     Model.nearestHistoryIndex([], 10, 0, 100, 0, 1), -1);
  eq("history points outside the window are dropped",
     Model.clampHistoryPoints(
       [{ t: -100, v: 1 }, { t: 3500, v: 2 }, { t: 3700, v: 3 }],
       1, 3600, 240),
     [{ t: 3500, v: 2 }, { t: 3700, v: 3 }]);
  eq("a client clock ahead of Home Assistant still keeps samples",
     Model.clampHistoryPoints(
       [{ t: 1000, v: 1 }, { t: 2000, v: 2 }, { t: 3000, v: 3 }],
       1, 10000, 240),
     [{ t: 1000, v: 1 }, { t: 2000, v: 2 }, { t: 3000, v: 3 }]);
  eq("unavailable history remains a gap",
     Model.clampHistoryPoints(
       [{ t: 1000, v: 1 }, { t: 1500, v: null }, { t: 2000, v: 2 }],
       1, 2000, 240),
     [{ t: 1000, v: 1 }, { t: 1500, v: null }, { t: 2000, v: 2 }]);
  const dense = [];
  for (let i = 0; i < 500; i++) dense.push({ t: 1000 + i, v: i });
  eq("history points are capped",
     Model.clampHistoryPoints(dense, 1, 2000, 240).length <= 240, true);
  const peaked = [];
  for (let i = 0; i < 500; i++) peaked.push({ t: 1000 + i, v: i === 250 ? 999 : 10 });
  eq("min max sampling retains a brief peak",
     Math.max(...Model.downsampleHistoryPoints(peaked, 40).map((point) => point.v)),
     999);
  eq("history max points matches the bridge ceiling",
     Model.HISTORY_MAX_POINTS, 240);

  eq("a dimmable light expands",
     Model.isExpandable(entity("light.a", "on",
       { supported_color_modes: ["brightness"] })), true);
  eq("a plain light does not",
     Model.isExpandable(entity("light.a", "on", { supported_color_modes: ["onoff"] })),
     false);
  eq("climate with a reported target expands",
     Model.isExpandable(entity("climate.a", "heat",
       { supported_features: 1, temperature: 22 })), true);
  eq("climate without a target control does not expand",
     Model.isExpandable(entity("climate.a", "heat")), false);
  eq("climate with advertised HVAC modes expands",
     Model.isExpandable(entity("climate.a", "heat",
       { hvac_modes: ["off", "heat", "cool"] })), true);
  eq("cover with open support expands",
     Model.isExpandable(entity("cover.a", "open", { supported_features: 1 })), true);
  eq("cover without advertised actions does not expand",
     Model.isExpandable(entity("cover.a", "open", { supported_features: 0 })), false);
  eq("cover with only position support still expands",
     Model.isExpandable(entity("cover.a", "open",
       { supported_features: 4, current_position: 50 })), true);
  eq("a numeric sensor expands onto a graph",
     Model.isExpandable(entity("sensor.a", "5")), true);
  eq("an unavailable numeric sensor does not expand",
     Model.isExpandable(entity("sensor.a", "unavailable")), false);
  eq("a text sensor does not expand",
     Model.isExpandable(entity("sensor.weather", "sunny")), false);
  // Every expandable domain must have a control to expand into; EntityRow maps
  // them by hand, and a camera has none.
  eq("camera does not expand onto an empty panel",
     Model.isExpandable(entity("camera.a", "streaming")), false);
});

section("entity capabilities", () => {
  const media = Model.capabilitiesFor(entity("media_player.a", "playing", {
    supported_features: 1 | 4 | 32,
    volume_level: 0.4
  }));
  eq("media exposes only advertised previous", media.mediaPrevious, false);
  eq("media exposes advertised play/pause", media.mediaPlayPause, true);
  eq("media exposes advertised next", media.mediaNext, true);
  eq("media exposes volume only with feature and value", media.mediaVolume, true);

  const noLevel = Model.capabilitiesFor(entity("media_player.a", "idle", {
    supported_features: 4
  }));
  eq("volume isn't synthesized without a reported level", noLevel.mediaVolume, false);

  const cover = Model.capabilitiesFor(entity("cover.a", "closed", {
    supported_features: 1 | 2
  }));
  eq("cover advertises open", cover.coverOpen, true);
  eq("cover advertises close", cover.coverClose, true);
  eq("cover hides stop when unsupported", cover.coverStop, false);
  eq("cover without the position feature has no position control",
     cover.coverPosition, false);

  const positionable = Model.capabilitiesFor(entity("cover.a", "open", {
    supported_features: 1 | 2 | 4 | 8, current_position: 70
  }));
  eq("cover with the feature and a reported position exposes position control",
     positionable.coverPosition, true);

  // current_position is state, not capability: a cover that advertises the
  // feature but has not reported a position yet (or only reports one while
  // moving) must still get the control, same as coverOpen/coverClose don't
  // require the cover to currently be open or closed.
  const positionBitNoValue = Model.capabilitiesFor(entity("cover.a", "open", {
    supported_features: 4
  }));
  eq("the position feature alone is enough without a reported value",
     positionBitNoValue.coverPosition, true);

  const range = Model.capabilitiesFor(entity("climate.a", "heat", {
    supported_features: 2, target_temp_low: 18, target_temp_high: 24
  }));
  eq("climate range is supported", range.climateRange, true);
  eq("range doesn't imply a single target", range.climateTarget, false);

  const missingRange = Model.capabilitiesFor(entity("climate.a", "heat", {
    supported_features: 2
  }));
  eq("a missing target range isn't invented", missingRange.climateRange, false);
  eq("a missing live climate target still reserves stable row geometry",
     missingRange.reserveExpandSlot, true);
  eq("a missing live climate target does not enable empty controls",
     missingRange.expandable, false);

  const climateOn = Model.capabilitiesFor(entity("climate.a", "heat", {
    supported_features: 1 | 128 | 256, temperature: 22
  }));
  eq("an active climate entity exposes turn off", climateOn.toggle, true);

  const climateOff = Model.capabilitiesFor(entity("climate.a", "off", {
    supported_features: 1 | 128 | 256, temperature: 22
  }));
  eq("an off climate entity exposes turn on", climateOff.toggle, true);

  const oneWayClimate = Model.capabilitiesFor(entity("climate.a", "off", {
    supported_features: 128
  }));
  eq("climate does not invent an unsupported turn-on action",
     oneWayClimate.toggle, false);

  const unavailable = Model.capabilitiesFor(entity("cover.a", "unavailable", {
    supported_features: 1 | 2 | 8
  }));
  eq("unavailable controls are disabled", unavailable.expandable, false);
  eq("scenes remain activatable despite unknown state",
     Model.capabilitiesFor(entity("scene.a", "unknown")).activate, true);

  const numericSensor = Model.capabilitiesFor(entity("sensor.a", "22.3", {
    unit_of_measurement: "°C"
  }));
  eq("a numeric sensor advertises a history graph",
     numericSensor.historyGraph, true);
  eq("a numeric sensor reserves the expand slot",
     numericSensor.reserveExpandSlot, true);
});

section("service calls", () => {
  eq("a light on turns off",
     Model.toggleCall(entity("light.a", "on"), true), { domain: "light", service: "turn_off" });
  eq("a light off turns on",
     Model.toggleCall(entity("light.a", "off"), false), { domain: "light", service: "turn_on" });
  eq("an active climate entity turns off through its own domain",
     Model.toggleCall(entity("climate.a", "heat", { supported_features: 128 }), true),
     { domain: "climate", service: "turn_off" });
  eq("an off climate entity turns on through its own domain",
     Model.toggleCall(entity("climate.a", "off", { supported_features: 256 }), false),
     { domain: "climate", service: "turn_on" });
  // Anything outside the known list still gets a sensible attempt.
  eq("an unknown domain falls back",
     Model.toggleCall(entity("water_heater.a", "on"), true),
     { domain: "homeassistant", service: "toggle" });
});

section("icons", () => {
  eq("device_class beats domain",
     Model.iconFor(entity("cover.a", "closed", { device_class: "garage" })),
     Model.DEVICE_CLASS_ICONS["garage"]);
  eq("domain is used when there is no device_class",
     Model.iconFor(entity("light.a", "on")), Model.DOMAIN_ICONS["light"]);
  eq("an unknown domain gets the fallback",
     Model.iconFor(entity("wombat.a", "on")), Model.FALLBACK_ICON);

  const locked = Model.iconFor(entity("lock.a", "locked"));
  const unlocked = Model.iconFor(entity("lock.a", "unlocked"));
  eq("a lock changes glyph with its state", locked !== unlocked, true);

  // A wrong codepoint renders as an empty box, not as a visible error, so
  // assert every glyph is a single character in the Nerd Font private range
  // rather than an accidental empty string or ASCII leftover.
  const glyphs = [...Object.values(Model.DOMAIN_ICONS),
                  ...Object.values(Model.DEVICE_CLASS_ICONS),
                  Model.FALLBACK_ICON, Model.BRAND_ICON];
  const bad = glyphs.filter((g) => [...g].length !== 1 || g.codePointAt(0) < 0xE000);
  eq("every icon is one private-use glyph", bad, []);
});

section("attribute redaction", () => {
  // `omarchy-shell hass entityState ...` output is what people paste into bug
  // reports. Home Assistant puts a live camera access token and a signed
  // picture URL directly into the attribute map.
  const camera = Model.redactAttributes(entity("camera.drive", "streaming", {
    friendly_name: "Driveway",
    access_token: "1f3c9d0e5b",
    entity_picture: "/api/camera_proxy/camera.drive?token=1f3c9d0e5b"
  }));
  eq("camera access token is redacted", camera.access_token, "[redacted]");
  eq("signed picture URL is redacted", camera.entity_picture, "[redacted]");
  eq("ordinary attributes survive", camera.friendly_name, "Driveway");

  const tracker = Model.redactAttributes(entity("device_tracker.phone", "home", {
    latitude: 52.2297, longitude: 21.0122, gps_accuracy: 12, battery_level: 80
  }));
  eq("coordinates are redacted",
     [tracker.latitude, tracker.longitude, tracker.gps_accuracy],
     ["[redacted]", "[redacted]", "[redacted]"]);
  eq("unrelated telemetry survives", tracker.battery_level, 80);

  eq("an entity with no attributes redacts to an empty object",
     Model.redactAttributes(null), {});
});

section("light colour capability", () => {
  // A Philips Hue colour strip reports exactly this pair.
  const strip = entity("light.strip", "on",
    { supported_color_modes: ["color_temp", "xy"] });
  eq("an xy light supports colour", Model.supportsColor(strip), true);
  eq("the same light supports colour temperature",
     Model.supportsColorTemp(strip), true);

  eq("hs is a colour mode", Model.supportsColor(entity("light.a", "on",
     { supported_color_modes: ["hs"] })), true);
  eq("rgbww is a colour mode", Model.supportsColor(entity("light.a", "on",
     { supported_color_modes: ["rgbww"] })), true);

  // color_temp and white produce white light only. Treating either as colour
  // would put a hue slider on a tunable-white bulb that cannot act on it.
  eq("colour temperature alone is not colour",
     Model.supportsColor(entity("light.a", "on",
       { supported_color_modes: ["color_temp"] })), false);
  eq("white alone is not colour", Model.supportsColor(entity("light.a", "on",
     { supported_color_modes: ["white"] })), false);
  eq("a dimmable-only light has no colour",
     Model.supportsColor(entity("light.a", "on",
       { supported_color_modes: ["brightness"] })), false);
  eq("colour is a light-only capability",
     Model.supportsColor(entity("switch.a", "on",
       { supported_color_modes: ["hs"] })), false);

  // The capability has to come from supported_color_modes, because a colour
  // light that is off reports no hs_color at all — which is the moment the
  // picker is wanted.
  const off = entity("light.strip", "off",
    { supported_color_modes: ["color_temp", "xy"], hs_color: null });
  eq("a light that is off still advertises colour",
     Model.supportsColor(off), true);
  eq("a light that is off reports no live colour", Model.hsColor(off), null);
});

section("light colour values", () => {
  eq("hs_color is read as hue and saturation",
     Model.hsColor(entity("light.a", "on", { hs_color: [28.5, 100] })),
     { hue: 28.5, saturation: 100 });
  eq("out-of-range values are clamped rather than trusted",
     Model.hsColor(entity("light.a", "on", { hs_color: [400, 140] })),
     { hue: 360, saturation: 100 });
  eq("a malformed hs_color is no colour",
     Model.hsColor(entity("light.a", "on", { hs_color: ["red"] })), null);
  eq("a missing hs_color is no colour",
     Model.hsColor(entity("light.a", "on")), null);

  eq("colour temperature mode is detected",
     Model.isColorTempActive(entity("light.a", "on",
       { color_mode: "color_temp" })), true);
  eq("hue mode is not colour temperature mode",
     Model.isColorTempActive(entity("light.a", "on", { color_mode: "hs" })),
     false);
});

section("colour temperature range", () => {
  eq("declared kelvin limits are used as-is",
     Model.kelvinRange(entity("light.a", "on",
       { min_color_temp_kelvin: 2202, max_color_temp_kelvin: 4000 })),
     { min: 2202, max: 4000 });

  // Pre-2022.11 instances publish mireds only, and the ends swap: the largest
  // mired value is the warmest light and therefore the lowest kelvin.
  eq("mireds are converted and the ends swapped",
     Model.kelvinRange(entity("light.a", "on",
       { min_mireds: 153, max_mireds: 500 })),
     { min: 2000, max: 6536 });

  eq("a light with no limits falls back to the Home Assistant defaults",
     Model.kelvinRange(entity("light.a", "on")), { min: 2000, max: 6535 });
  eq("a nonsense range falls back rather than inverting the slider",
     Model.kelvinRange(entity("light.a", "on",
       { min_color_temp_kelvin: 5000, max_color_temp_kelvin: 2000 })),
     { min: 2000, max: 6535 });

  eq("kelvin is read directly when published",
     Model.colorTempKelvin(entity("light.a", "on",
       { color_temp_kelvin: 2700 })), 2700);
  eq("mireds are converted to kelvin",
     Model.colorTempKelvin(entity("light.a", "on", { color_temp: 370 })), 2703);
  eq("no colour temperature is signalled with -1",
     Model.colorTempKelvin(entity("light.a", "on")), -1);
});

section("colour service payloads", () => {
  eq("a hue and saturation become hs_color",
     Model.lightColorData(28, 100), { hs_color: [28, 100] });

  // Home Assistant rejects a hue of exactly 360, which is the same colour as 0.
  eq("360 degrees wraps to 0", Model.lightColorData(360, 80),
     { hs_color: [0, 80] });
  // Rounding runs before the wrap, or a hue a hair under 360 rounds up into
  // the value the wrap exists to avoid. The wheel emits continuous angles.
  eq("a hue that rounds up to 360 still wraps",
     Model.lightColorData(359.999, 80), { hs_color: [0, 80] });
  eq("a negative hue wraps forward", Model.lightColorData(-10, 80),
     { hs_color: [350, 80] });
  eq("saturation is clamped", Model.lightColorData(10, 140),
     { hs_color: [10, 100] });
  eq("a non-numeric hue produces no call", Model.lightColorData("red", 50),
     null);
  eq("a non-finite hue produces no call", Model.lightColorData(Infinity, 50),
     null);

  const strip = entity("light.strip", "on",
    { min_color_temp_kelvin: 2202, max_color_temp_kelvin: 4000 });
  eq("kelvin is clamped into the light's own range",
     Model.lightColorTempData(strip, 6500), { color_temp_kelvin: 4000 });
  eq("kelvin below the range is clamped up",
     Model.lightColorTempData(strip, 1000), { color_temp_kelvin: 2202 });
  eq("a non-numeric kelvin produces no call",
     Model.lightColorTempData(strip, "warm"), null);
});

section("colour conversion", () => {
  // Anchors from the frontend's own temperature2rgb curve.
  eq("a warm temperature is orange", Model.temperatureToRgb(2000),
     [255, 137, 14]);
  eq("6500K is near white", Model.temperatureToRgb(6500), [255, 254, 250]);
  eq("above 6600K the blue channel saturates",
     Model.temperatureToRgb(10000)[2], 255);

  eq("pure red converts to hue 0", Model.rgbToHs([255, 0, 0]),
     { hue: 0, saturation: 100 });
  eq("pure green converts to hue 120", Model.rgbToHs([0, 255, 0]),
     { hue: 120, saturation: 100 });
  eq("white has no saturation", Model.rgbToHs([255, 255, 255]),
     { hue: 0, saturation: 0 });
  eq("black has no saturation", Model.rgbToHs([0, 0, 0]),
     { hue: 0, saturation: 0 });

  eq("hue 0 renders red", Model.hsToRgb(0, 100), [255, 0, 0]);
  eq("hue 240 renders blue", Model.hsToRgb(240, 100), [0, 0, 255]);
  eq("no saturation renders white", Model.hsToRgb(200, 0), [255, 255, 255]);

  // The favourites round-trip through both directions, so they have to agree.
  const roundTrip = Model.rgbToHs(Model.hsToRgb(210, 60));
  eq("hue survives a round trip", Math.round(roundTrip.hue), 210);
  eq("saturation survives a round trip", Math.round(roundTrip.saturation), 60);

  // A white channel lifts the colour without letting it overflow past 255.
  eq("rgbw folds the white channel in", Model.rgbwToRgb([255, 0, 0, 255]),
     [255, 128, 128]);

  // rgbww carries a cold and a warm white; their ratio picks a temperature
  // between the light's limits, which is then folded in like the rgbw white.
  eq("an all-cold rgbww renders the top of the range",
     Model.rgbwwToRgb([0, 0, 0, 255, 0], 2000, 6535),
     Model.temperatureToRgb(6535));
  eq("an all-warm rgbww renders the bottom of it",
     Model.rgbwwToRgb([0, 0, 0, 0, 255], 2000, 6535),
     Model.temperatureToRgb(2000));
  // Even channels interpolate in mireds, not kelvin, so the midpoint is
  // 3063K rather than 4267K.
  eq("a balanced rgbww sits between the two",
     Model.rgbwwToRgb([0, 0, 0, 255, 255], 2000, 6535),
     [255, 179, 114]);
  eq("rgbww with no white channels keeps the colour",
     Model.rgbwwToRgb([255, 0, 0, 0, 0], 2000, 6535), [255, 0, 0]);
});

section("favourite colours", () => {
  // A Philips Hue colour strip: colour and colour temperature.
  const strip = entity("light.strip", "on", {
    supported_color_modes: ["color_temp", "xy"],
    min_color_temp_kelvin: 2000, max_color_temp_kelvin: 6535
  });

  // With nothing saved, Home Assistant computes four colour temperatures
  // stepped across the light's own range, then four fixed colours. The panel
  // has to show the same eight, in the same order, as the app.
  const defaults = Model.favoriteColors(strip, null);
  eq("a light with no saved favourites gets eight", defaults.length, 8);
  eq("the first four are colour temperatures",
     defaults.slice(0, 4).map((f) => f.kind),
     ["colorTemp", "colorTemp", "colorTemp", "colorTemp"]);
  eq("they step across the light's own range",
     defaults.slice(0, 4).map((f) => f.kelvin), [2000, 3512, 5023, 6535]);
  eq("the last four are colours",
     defaults.slice(4).map((f) => f.kind),
     ["color", "color", "color", "color"]);
  eq("and are the frontend's fixed picks",
     defaults.slice(4).map((f) => f.rgb),
     [[127, 172, 255], [215, 150, 255], [255, 158, 243], [255, 110, 84]]);

  // Without colour temperature the same four whites are sent as colours,
  // because that is the only channel the light has to render them on.
  const colorOnly = entity("light.c", "on", { supported_color_modes: ["hs"] });
  const colorDefaults = Model.favoriteColors(colorOnly, null);
  eq("a colour-only light still gets eight", colorDefaults.length, 8);
  eq("none of them are colour temperatures",
     colorDefaults.every((f) => f.kind === "color"), true);

  // A tunable white gets the temperatures and nothing else — offering a
  // colour it cannot render would send a call it has to reject.
  const whiteOnly = entity("light.w", "on",
    { supported_color_modes: ["color_temp"],
      min_color_temp_kelvin: 2200, max_color_temp_kelvin: 4000 });
  const whiteDefaults = Model.favoriteColors(whiteOnly, null);
  eq("a tunable white gets only temperatures", whiteDefaults.length, 4);
  eq("bounded by its own range",
     [whiteDefaults[0].kelvin, whiteDefaults[3].kelvin], [2200, 4000]);

  eq("a non-light has no favourites",
     Model.favoriteColors(entity("switch.a", "on"), null), []);
});

section("saved favourite colours", () => {
  const strip = entity("light.strip", "on", {
    supported_color_modes: ["color_temp", "xy"],
    min_color_temp_kelvin: 2000, max_color_temp_kelvin: 6535
  });

  const saved = Model.favoriteColors(strip, [
    { color_temp_kelvin: 2700 },
    { rgb_color: [255, 110, 84] },
    { hs_color: [120, 100] }
  ]);
  eq("saved favourites replace the defaults", saved.length, 3);
  eq("a saved temperature keeps its kelvin", saved[0].kelvin, 2700);
  eq("a saved temperature carries a drawable swatch", saved[0].rgb,
     Model.temperatureToRgb(2700));
  eq("a saved rgb becomes hue and saturation",
     [Math.round(saved[1].hue), Math.round(saved[1].saturation)], [9, 67]);
  const xy = Model.favoriteColors(strip, [{ xy_color: [0.7, 0.3] }]);
  eq("a saved xy_color produces a swatch", xy.length, 1);
  eq("a saved xy_color becomes hue and saturation",
     [Math.round(xy[0].hue), Math.round(xy[0].saturation)], [0, 100]);

  eq("a saved hs_color survives as itself",
     [Math.round(saved[2].hue), Math.round(saved[2].saturation)], [120, 100]);

  // Exactly, not approximately: converting to rgb and back would round a
  // pale favourite through three bytes and shift its hue several degrees.
  const pale = Model.favoriteColors(strip, [{ hs_color: [30, 2] }]);
  eq("a pale saved hs_color keeps its exact hue",
     [pale[0].hue, pale[0].saturation], [30, 2]);
  eq("and still draws a swatch", pale[0].rgb, Model.hsToRgb(30, 2));

  // The registry is server-controlled and unbounded, but the Repeater that
  // draws these is not.
  const many = [];
  for (let i = 0; i < 200; i++) many.push({ rgb_color: [0, 0, 255] });
  eq("an absurd saved list is capped",
     Model.favoriteColors(strip, many).length, 24);

  // Registry contents are server-controlled, so a malformed entry must be
  // dropped rather than drawn or sent.
  const messy = Model.favoriteColors(strip, [
    { rgb_color: ["red", 0, 0] }, { nonsense: true }, null, "blue",
    { rgb_color: [0, 0, 255] }
  ]);
  eq("malformed favourites are dropped", messy.length, 1);
  eq("the survivor is the valid one", messy[0].rgb, [0, 0, 255]);

  eq("an emptied saved list draws no swatches",
     Model.favoriteColors(strip, []).length, 0);
  eq("an unset saved list falls back to the defaults",
     Model.favoriteColors(strip, null).length, 8);

  // A temperature favourite copied onto a light with no white channel would
  // produce a call the light must reject.
  const colorOnly = entity("light.c", "on", { supported_color_modes: ["hs"] });
  eq("a temperature favourite is dropped on a colour-only light",
     Model.favoriteColors(colorOnly, [{ color_temp_kelvin: 2700 }]).length, 0);

  const whiteOnly = entity("light.w", "on",
    { supported_color_modes: ["color_temp"] });
  eq("a colour favourite is dropped on a tunable white",
     Model.favoriteColors(whiteOnly, [{ rgb_color: [255, 0, 0] }]).length, 0);
  eq("an xy favourite is dropped on a tunable white",
     Model.favoriteColors(whiteOnly, [{ xy_color: [0.7, 0.3] }]).length, 0);

  // The list is the answer even when none of it survives validation: a light
  // that stopped advertising color_temp keeps whatever the user chose, minus
  // the entries it can no longer render. Reinstating eight defaults would
  // hand back picks that were replaced.
  eq("a saved list nothing survives still means no defaults",
     Model.favoriteColors(whiteOnly, [
       { rgb_color: [255, 0, 0] }, { hs_color: [120, 100] }, { nonsense: true }
     ]).length, 0);

  // Clamping is the model's job, not the light's.
  const clamped = Model.favoriteColors(strip, [{ color_temp_kelvin: 99000 }]);
  eq("a saved temperature is clamped into range", clamped[0].kelvin, 6535);
});

section("colour capabilities and expansion", () => {
  const strip = Model.capabilitiesFor(entity("light.strip", "on",
    { supported_color_modes: ["color_temp", "xy"] }));
  eq("a colour strip reports colour", strip.color, true);
  eq("a colour strip reports colour temperature", strip.colorTemp, true);
  eq("a colour strip is expandable", strip.expandable, true);

  const plain = Model.capabilitiesFor(entity("light.a", "on",
    { supported_color_modes: ["onoff"] }));
  eq("an on/off light has no colour", plain.color, false);
  eq("an on/off light has no colour temperature", plain.colorTemp, false);
  eq("an on/off light is not expandable", plain.expandable, false);

  // Unavailable entities must not offer controls that would send a command.
  const gone = Model.capabilitiesFor(entity("light.strip", "unavailable",
    { supported_color_modes: ["hs"] }));
  eq("an unavailable light offers no colour control", gone.color, false);
});

section("optimistic reconciliation", () => {
  const lit = (attributes) => entity("light.a", "on", attributes);

  eq("brightness settles on the byte it rounded to",
     Model.brightnessSettled(lit({ brightness: 128 }), 50), true);
  eq("a different brightness does not settle it",
     Model.brightnessSettled(lit({ brightness: 128 }), 70), false);
  eq("zero settles once the light is off",
     Model.brightnessSettled(entity("light.a", "off"), 0), true);
  eq("zero does not settle while the light is on",
     Model.brightnessSettled(lit({ brightness: 128 }), 0), false);
  // One slider step must not settle against the value the light still holds,
  // or the knob snaps back to it.
  eq("a brightness one step away does not settle it",
     Model.brightnessSettled(lit({ brightness: 128 }), 51), false);
  eq("a positive brightness never settles against an off light",
     Model.brightnessSettled(entity("light.a", "off"), 50), false);

  const shade = (attributes) => entity("cover.a", "open", attributes);
  eq("cover position settles on the percent it was sent",
     Model.coverPositionSettled(shade({ current_position: 60 }), 60), true);
  eq("a different position does not settle it",
     Model.coverPositionSettled(shade({ current_position: 60 }), 40), false);
  eq("no reported position never settles",
     Model.coverPositionSettled(entity("cover.a", "open"), 60), false);

  eq("hue is measured the short way round the wheel",
     Model.hueGap(350, 10), 20);
  eq("hue gap is symmetric", Model.hueGap(10, 350), 20);
  eq("opposite hues are half a circle apart", Model.hueGap(0, 180), 180);
  eq("the same hue has no gap", Model.hueGap(210, 210), 0);

  eq("a colour settles on a near-enough hue",
     Model.colorSettled(lit({ hs_color: [211, 60] }), 210, 60), true);
  eq("hue wraps rather than reading as a full circle apart",
     Model.colorSettled(lit({ hs_color: [359, 80] }), 0.5, 80), true);
  eq("a different hue does not settle it",
     Model.colorSettled(lit({ hs_color: [211, 60] }), 120, 60), false);
  // White has no hue of its own, so any angle confirms it.
  eq("an unsaturated pick ignores hue",
     Model.colorSettled(lit({ hs_color: [30, 0] }), 210, 0), true);
  eq("a light on its temperature channel is not showing a colour",
     Model.colorSettled(lit({ hs_color: [211, 60], color_mode: "color_temp" }),
                        210, 60), false);
  // Near the centre of the wheel an xy round trip barely preserves hue, so the
  // tolerance has to widen or the knob freezes until the pending expires.
  eq("a barely saturated pick settles on any hue",
     Model.colorSettled(lit({ hs_color: [45, 3] }), 200, 3), true);
  eq("a saturated pick still needs the hue it asked for",
     Model.colorSettled(lit({ hs_color: [216, 100] }), 210, 100), false);
  eq("a colour never settles against a light with no colour",
     Model.colorSettled(entity("light.a", "off"), 210, 60), false);
  eq("a colour never settles against an unavailable light",
     Model.colorSettled(entity("light.a", "unavailable"), 210, 60), false);
  eq("a colour never settles against a missing entity",
     Model.colorSettled(null, 210, 60), false);

  const white = (kelvin) =>
    lit({ color_mode: "color_temp", color_temp_kelvin: kelvin });
  eq("warmth settles through the mired rounding",
     Model.colorTempSettled(white(4000), 4008), true);
  eq("a warmth a slider step away does not settle it",
     Model.colorTempSettled(white(4000), 4100), false);
  // A slider step is only 1.17 mireds at 6500K, so the slack has to stay under
  // it even though a step is 100 kelvin wide down at 4000K.
  eq("the mired rounding is still absorbed at the cold end",
     Model.colorTempSettled(white(6494), 6500), true);
  eq("a warmth one step away at the cold end does not settle it",
     Model.colorTempSettled(white(6500), 6550), false);
  eq("a light showing a hue has no warmth to settle",
     Model.colorTempSettled(lit({ hs_color: [211, 60] }), 4000), false);
  eq("a nonsensical kelvin never settles",
     Model.colorTempSettled(white(4000), 0), false);
  eq("a negative kelvin never settles",
     Model.colorTempSettled(white(4000), -4000), false);
  eq("warmth never settles against an off light",
     Model.colorTempSettled(entity("light.a", "off"), 4000), false);
  eq("warmth never settles against an unavailable light",
     Model.colorTempSettled(entity("light.a", "unavailable"), 4000), false);
  eq("warmth never settles against a missing entity",
     Model.colorTempSettled(null, 4000), false);

  eq("volume settles on the level it reports",
     Model.volumeSettled(entity("media_player.a", "playing",
                                { volume_level: 0.35 }), 0.35), true);
  eq("a different volume does not settle it",
     Model.volumeSettled(entity("media_player.a", "playing",
                                { volume_level: 0.35 }), 0.5), false);
  eq("volume never settles against an unavailable player",
     Model.volumeSettled(entity("media_player.a", "unavailable"), 0.35), false);
  eq("volume never settles against an off player",
     Model.volumeSettled(entity("media_player.a", "off"), 0.35), false);
  eq("volume never settles against a missing entity",
     Model.volumeSettled(null, 0.35), false);

  const stat = entity("climate.a", "heat", { temperature: 21 });
  eq("a setpoint settles within half a step",
     Model.temperatureSettled(stat, "temperature", 21.2, 0.5), true);
  eq("a setpoint a step away does not settle",
     Model.temperatureSettled(stat, "temperature", 21.5, 0.5), false);
  eq("a missing attribute never settles",
     Model.temperatureSettled(stat, "target_temp_low", 21, 0.5), false);
  // A thermostat that reports no step falls back to a quarter degree.
  eq("an absent step settles within a quarter degree",
     Model.temperatureSettled(stat, "temperature", 21.2), true);
  eq("an absent step rejects more than a quarter degree",
     Model.temperatureSettled(stat, "temperature", 21.3), false);
  eq("a zero step falls back to the same quarter degree",
     Model.temperatureSettled(stat, "temperature", 21.2, 0), true);
});

section("command tags", () => {
  eq("two calls to the same entity get different tags",
     Model.callTag("light.a", 1) === Model.callTag("light.a", 2), false);
  eq("the same call reads back as the same tag",
     Model.callTag("light.a", 7), Model.callTag("light.a", 7));
  eq("a tag keeps the prefix the bridge needs to report a failure",
     Model.callTag("light.a", 3).indexOf("call:"), 0);
  eq("a tag carries nothing but an entity id and a counter",
     /^call:[A-Za-z0-9_.]+:\d+$/.test(Model.callTag("light.a", 12)), true);

  eq("a call tag is recognised", Model.isCallTag(Model.callTag("light.a", 1)),
     true);
  eq("a toggle tag is not a call tag", Model.isCallTag("toggle:light.a"), false);
  eq("an empty tag is not a call tag", Model.isCallTag(""), false);
  eq("a missing tag is not a call tag", Model.isCallTag(null), false);

  const first = Model.callTag("light.a", 1);
  const second = Model.callTag("light.a", 2);
  eq("a failure matches the value its own call put on screen",
     Model.callTagMatches(first, first), true);
  eq("a failure of an older call does not match a newer value",
     Model.callTagMatches(second, first), false);
  eq("nor does a newer failure match an older value",
     Model.callTagMatches(first, second), false);
  eq("an unsent value matches nothing", Model.callTagMatches("", first), false);
  eq("an untagged failure matches nothing",
     Model.callTagMatches(first, ""), false);
  eq("two untagged sides still do not match",
     Model.callTagMatches("", ""), false);
});

section("step snapping", () => {
  eq("a drag lands on the nearest step",
     Model.snapToStep(21.2, 5, 0.5, 5, 35), 21);
  eq("it rounds up past the halfway point",
     Model.snapToStep(21.3, 5, 0.5, 5, 35), 21.5);
  eq("an offset base moves the whole grid",
     Model.snapToStep(21.2, 5.25, 0.5, 5, 35), 21.25);
  eq("a value already on the grid is left alone",
     Model.snapToStep(21.5, 5, 0.5, 5, 35), 21.5);
  eq("the result stays inside the range",
     Model.snapToStep(40, 5, 0.5, 5, 35), 35);
  eq("and inside it at the bottom",
     Model.snapToStep(-3, 5, 0.5, 5, 35), 5);
  eq("a percentage snaps to whole numbers",
     Model.snapToStep(63.7, 0, 1, 0, 100), 64);
  eq("a coarse step still lands on the grid",
     Model.snapToStep(4123, 2000, 50, 2000, 6500), 4100);

  // Band sliders bound themselves by the thermostat's own low and high.
  eq("an upper bound off the grid snaps down into the range",
     Model.snapToStep(40, 5, 0.5, 5, 21.3), 21);
  eq("a lower bound off the grid snaps up into the range",
     Model.snapToStep(3, 5, 0.5, 5.2, 30), 5.5);
  eq("a value already inside and on the grid is untouched",
     Model.snapToStep(21, 5, 0.5, 5.2, 21.3), 21);

  eq("a value just inside an off-grid maximum stays inside",
     Model.snapToStep(20.28, 5, 0.5, 5, 20.3), 20);
  eq("a value just inside an off-grid minimum stays inside",
     Model.snapToStep(20.22, 5, 0.5, 20.2, 35), 20.5);

  // Off the grid beats past a limit the thermostat just reported.
  eq("a range with no grid point in it keeps the clamped value",
     Model.snapToStep(20.3, 5, 0.5, 20.2, 20.4), 20.3);
  eq("and still clamps into that range",
     Model.snapToStep(30, 5, 0.5, 20.2, 20.4), 20.4);
  eq("the arithmetic does not leak float noise",
     String(Model.snapToStep(21.4, 5, 0.5, 5, 35)), "21.5");
  eq("a missing step leaves the value alone",
     Model.snapToStep(21.2, 5, 0, 5, 35), 21.2);
  eq("a negative step leaves the value alone",
     Model.snapToStep(21.2, 5, -0.5, 5, 35), 21.2);
  eq("a non-finite base leaves the value alone",
     Model.snapToStep(21.2, NaN, 0.5, 5, 35), 21.2);
  eq("a non-numeric value passes straight through",
     Model.snapToStep(undefined, 5, 0.5, 5, 35), undefined);

  eq("a downward nudge lands on the step below",
     Model.snapToStep(20.5, 5, 0.5, 5, 35, Math.ceil), 20.5);
  eq("an upward nudge lands on the step above",
     Model.snapToStep(21.5, 5, 0.5, 5, 35, Math.floor), 21.5);
  eq("a downward nudge from an off-grid target still moves one step",
     Model.snapToStep(20, 4.5, 1, 4.5, 35, Math.ceil), 20.5);
  eq("an upward nudge from an off-grid target still moves one step",
     Model.snapToStep(22, 4.5, 1, 4.5, 35, Math.floor), 21.5);
  eq("a directional mode still respects an off-grid maximum",
     Model.snapToStep(40, 5, 0.5, 5, 21.3, Math.floor), 21);
  eq("a directional mode still respects an off-grid minimum",
     Model.snapToStep(3, 5, 0.5, 5.2, 30, Math.ceil), 5.5);
});

console.log();
if (failures) {
  console.log(`FAILED: ${failures} of ${checks} checks`);
  process.exit(1);
}
console.log(`all ${checks} checks passed`);

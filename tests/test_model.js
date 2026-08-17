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
  eq("sensor does not", Model.isExpandable(entity("sensor.a", "5")), false);
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

console.log();
if (failures) {
  console.log(`FAILED: ${failures} of ${checks} checks`);
  process.exit(1);
}
console.log(`all ${checks} checks passed`);

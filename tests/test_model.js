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
  eq("on", Model.isOn(entity("light.a", "on")), true);
  eq("locked is on", Model.isOn(entity("lock.a", "locked")), true);
  eq("open is on", Model.isOn(entity("cover.a", "open")), true);
  eq("off", Model.isOn(entity("light.a", "off")), false);
  eq("closed is off", Model.isOn(entity("cover.a", "closed")), false);
  eq("unlocked is off", Model.isOn(entity("lock.a", "unlocked")), false);
  // A Loxone room controller has no "off" state; anything reported counts.
  eq("a climate entity with a state is on", Model.isOn(entity("climate.a", "auto")), true);
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
     Model.subtitle(entity("climate.a", "auto", {
       temperature: 22.0, current_temperature: 21.4 })),
     "Target 22°C · Now 21.4°C");
  eq("climate with only a current reading still shows it",
     Model.subtitle(entity("climate.a", "auto", { current_temperature: 21.4 })),
     "Now 21.4°C");
  eq("cover shows its live position",
     Model.subtitle(entity("cover.a", "open", { position: 45 })), "45% open");
  eq("cover without a reported position falls back to its state",
     Model.subtitle(entity("cover.a", "open")), "Open");
  eq("a toggle shows its state",
     Model.subtitle(entity("switch.a", "off")), "Off");
  eq("a pushbutton stays available despite an unknown state",
     Model.isAvailable(entity("scene.a", "unknown")), true);
  eq("an unavailable light is not available",
     Model.isAvailable(entity("light.a", "unavailable")), false);
  eq("a missing entity is not available", Model.isAvailable(null), false);
  eq("a normal light is available", Model.isAvailable(entity("light.a", "off")), true);

  eq("a sensor has no subtitle",
     Model.subtitle(entity("sensor.a", "5", { unit_of_measurement: "lx" })), "");
});

section("badges", () => {
  eq("pushbutton", Model.badgeText(entity("scene.a", "unknown")), "Trigger");
  eq("cover shows its position",
     Model.badgeText(entity("cover.a", "open", { position: 20 })), "20% open");
  eq("climate shows the current reading",
     Model.badgeText(entity("climate.a", "auto", { current_temperature: 21.4 })),
     "21.4°C now");
  eq("climate without a current reading falls back to displayState",
     Model.badgeText(entity("climate.a", "auto")), "Auto");
});

section("brightness", () => {
  // A Loxone Dimmer reports its live position as a 0-100 percent, and the
  // bridge writes it straight into `brightness` — there is no 0-255 scale
  // and no separate "supports dimming" flag to negotiate.
  eq("a reported brightness is enough",
     Model.supportsBrightness(entity("light.a", "on", { brightness: 40 })), true);
  eq("no reported brightness means no slider",
     Model.supportsBrightness(entity("light.a", "on")), false);
  eq("a dimmable light that is off still offers the slider",
     Model.supportsBrightness(entity("light.a", "off", { brightness: 0 })), true);
  eq("only lights are dimmable",
     Model.supportsBrightness(entity("switch.a", "on", { brightness: 40 })), false);
  eq("100 is full",
     Model.brightnessPercent(entity("light.a", "on", { brightness: 100 })), 100);
  eq("0 is off", Model.brightnessPercent(entity("light.a", "on", { brightness: 0 })), 0);
  eq("out-of-range values are clamped",
     Model.brightnessPercent(entity("light.a", "on", { brightness: 140 })), 100);
  eq("missing brightness is signalled with -1",
     Model.brightnessPercent(entity("light.a", "on")), -1);
});

section("temperature", () => {
  eq("a whole number drops its decimal", Model.formatTemp(22.0, "°C"), "22°C");
  eq("a fraction keeps one place", Model.formatTemp(21.44, "°C"), "21.4°C");
  eq("no unit, no suffix", Model.formatTemp(21.5, ""), "21.5");
  eq("the comfort-temperature step is a half degree by default",
     Model.temperatureStep(entity("climate.a", "auto")), 0.5);
  eq("a declared step wins over the default",
     Model.temperatureStep(entity("climate.a", "auto", { target_temp_step: 0.1 })), 0.1);
  eq("declared limits win",
     Model.temperatureRange(entity("climate.a", "auto", { min_temp: 16, max_temp: 30 })),
     { min: 16, max: 30 });
  eq("nonsense limits fall back",
     Model.temperatureRange(entity("climate.a", "auto", { min_temp: 30, max_temp: 16 })),
     { min: 5, max: 35 });
  eq("no declared limits falls back to a wide comfort range",
     Model.temperatureRange(entity("climate.a", "auto")), { min: 5, max: 35 });

  const target = entity("climate.a", "auto", { temperature: 22 });
  eq("a target within range is accepted",
     Model.climateTemperatureData(target, 23, "°C"), { temperature: 23 });
  eq("a target is clamped to the entity range",
     Model.climateTemperatureData(
       entity("climate.a", "auto", { temperature: 22, min_temp: 10, max_temp: 30 }),
       50, "°C"),
     { temperature: 30 });
  eq("without a reported target the control is not writable",
     Model.climateTemperatureData(entity("climate.a", "auto"), 22, "°C"), {});
});

section("activity summary", () => {
  const light = (state) => entity("light.a", state, { friendly_name: "Lamp" });
  const sw = (state) => entity("switch.b", state, { friendly_name: "Plug" });

  eq("nothing picked", Model.activitySummary([]), "No devices picked");
  eq("everything off", Model.activitySummary([light("off"), sw("off")]), "All off");
  eq("one on", Model.activitySummary([light("on"), sw("off")]), "1 on");
  eq("several on", Model.activitySummary([light("on"), sw("on")]), "2 on");
  // A locked door and an open cover both read as `isOn`, but "on" is a
  // light/switch count, not a tally of every device that happens to answer
  // isOn.
  eq("locks are left out",
     Model.activitySummary([entity("lock.a", "locked"), light("off")]), "All off");
  eq("covers are left out",
     Model.activitySummary([entity("cover.a", "open"), light("off")]), "All off");
  eq("sensors are left out",
     Model.activitySummary([entity("sensor.a", "22.5"), light("off")]), "All off");
  eq("a missing entity is skipped", Model.activitySummary([null, light("on")]), "1 on");
});

section("demo starter picks match the demo house", () => {
  // The ids live in two files — this list and the bridge's fake house. A
  // stale one here would show up as an unavailable ghost row the moment
  // someone turns demo mode on, so read the bridge and compare.
  const bridge = fs.readFileSync(
    path.join(__dirname, "..", "bin", "loxone-bridge"), "utf8");
  const block = bridge.slice(bridge.indexOf("DEMO_FIXTURE = ["),
                             bridge.indexOf("class DemoHouse"));
  const known = new Set(
    [...block.matchAll(/\("([a-z_]+\.[0-9a-f-]+)"/g)].map((m) => m[1]));

  eq("the bridge's demo house was found", known.size > 0, true);
  const missing = Model.DEMO_DEFAULT_FAVORITES.filter((id) => !known.has(id));
  eq("every starter pick exists in the demo house", missing, []);
  eq("there are some starter picks", Model.DEMO_DEFAULT_FAVORITES.length > 0, true);
});

section("control classification", () => {
  eq("light is a toggle", Model.controlKind(entity("light.a", "on")), "toggle");
  eq("switch is a toggle", Model.controlKind(entity("switch.a", "on")), "toggle");
  eq("lock is its own kind", Model.controlKind(entity("lock.a", "locked")), "lock");
  eq("a pushbutton is one-shot", Model.controlKind(entity("scene.a", "unknown")), "activate");
  eq("a Loxone room controller has no primary toggle",
     Model.controlKind(entity("climate.a", "auto")), "none");
  eq("a cover has no primary toggle either — it always expands instead",
     Model.controlKind(entity("cover.a", "closed")), "none");
  eq("sensor has no control", Model.controlKind(entity("sensor.a", "5")), "none");

  eq("a dimmable light expands",
     Model.isExpandable(entity("light.a", "on", { brightness: 40 })), true);
  eq("a plain light does not",
     Model.isExpandable(entity("light.a", "on")), false);
  eq("climate with a reported target expands",
     Model.isExpandable(entity("climate.a", "auto", { temperature: 22 })), true);
  eq("climate without a target does not expand",
     Model.isExpandable(entity("climate.a", "auto")), false);
  eq("a cover never expands — its up/stop/down buttons sit inline on the row",
     Model.isExpandable(entity("cover.a", "open")), false);
  eq("sensor does not", Model.isExpandable(entity("sensor.a", "5")), false);
});

section("entity capabilities", () => {
  const cover = Model.capabilitiesFor(entity("cover.a", "closed"));
  eq("cover always offers open", cover.coverOpen, true);
  eq("cover always offers stop", cover.coverStop, true);
  eq("cover always offers close", cover.coverClose, true);

  const unavailableCover = Model.capabilitiesFor(entity("cover.a", "unavailable"));
  eq("an unavailable cover disables its controls", unavailableCover.expandable, false);
  eq("an unavailable cover has no actions either",
     [unavailableCover.coverOpen, unavailableCover.coverStop, unavailableCover.coverClose],
     [false, false, false]);

  const climate = Model.capabilitiesFor(entity("climate.a", "auto", { temperature: 22 }));
  eq("a reported comfort target is writable", climate.climateTarget, true);
  eq("climate never claims a low/high band Loxone does not have",
     climate.climateRange, false);

  const missingTarget = Model.capabilitiesFor(entity("climate.a", "auto"));
  eq("a missing live target isn't invented", missingTarget.climateTarget, false);
  eq("but the row still reserves its expansion slot",
     missingTarget.reserveExpandSlot, true);
  eq("and does not show an empty expander",
     missingTarget.expandable, false);

  eq("pushbuttons remain activatable despite an unknown state",
     Model.capabilitiesFor(entity("scene.a", "unknown")).activate, true);

  const lock = Model.capabilitiesFor(entity("lock.a", "locked"));
  eq("lock exposes its own capability, not a toggle", [lock.lock, lock.toggle],
     [true, false]);
});

section("commands", () => {
  eq("on turns off", Model.toggleCall(entity("light.a", "on"), true),
     { command: "off" });
  eq("off turns on", Model.toggleCall(entity("light.a", "off"), false),
     { command: "on" });
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
  eq("an entity with no attributes redacts to an empty object",
     Model.redactAttributes(null), {});
  eq("ordinary attributes survive untouched",
     Model.redactAttributes(entity("sensor.a", "5", { unit_of_measurement: "lx" })),
     { unit_of_measurement: "lx" });
});

section("search", () => {
  eq("matches the friendly name",
     Model.searchMatches("desk", entity("light.a", "on", { friendly_name: "Desk Lamp" })),
     true);
  eq("matches the entity id",
     Model.searchMatches("1234", entity("light.abcd1234-0000-0000-0000000000000001", "on")),
     true);
  eq("an empty query matches everything",
     Model.searchMatches("", entity("light.a", "on")), true);
  eq("no match is no match",
     Model.searchMatches("nope", entity("light.a", "on", { friendly_name: "Desk" })),
     false);
  // Loxone repeats control names across rooms constantly ("Jalousie" in
  // every room with a blind), so the room name is searchable too.
  eq("matches the room name when the caller has one",
     Model.searchMatches("empore", entity("light.a", "on", { friendly_name: "Jalousie" }),
       "Empore"),
     true);
  eq("a room match doesn't override a real mismatch on name/id",
     Model.searchMatches("kitchen",
       entity("light.a", "on", { friendly_name: "Jalousie" }), "Empore"),
     false);
});

console.log();
if (failures) {
  console.log(`FAILED: ${failures} of ${checks} checks`);
  process.exit(1);
}
console.log(`all ${checks} checks passed`);

#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

function load(name) {
  const source = fs.readFileSync(path.join(__dirname, "..", name), "utf8")
    .replace(/^\.pragma library\s*$/m, "");
  const names = [...source.matchAll(/^function\s+([A-Za-z0-9_]+)/gm)].map((m) => m[1]);
  const constants = [...source.matchAll(/^var\s+([A-Z][A-Z0-9_]*)/gm)].map((m) => m[1]);
  return new Function(`${source}\nreturn {${[...names, ...constants].join(",")}};`)();
}

const Model = load("Model.js");
const Rows = load("RowModel.js");
let failures = 0;
let checks = 0;
function eq(label, actual, expected) {
  checks++;
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    failures++;
    console.log(`  FAIL ${label}\n       got      ${JSON.stringify(actual)}` +
                `\n       expected ${JSON.stringify(expected)}`);
  }
}

console.log("row model projection");
const entity = {
  entity_id: "cover.garage",
  state: "closed",
  attributes: { friendly_name: "Garage", supported_features: 1 | 2 }
};
const row = Rows.project(entity.entity_id, entity, {
  name: "Main garage",
  icon: "X",
  isOn: false,
  pending: true,
  temperatureUnit: "°C",
  entityArea: { "cover.garage": "outside" },
  areaNames: { outside: "Outside" }
}, Model);
eq("display context is projected", [row.name, row.icon, row.areaName],
   ["Main garage", "X", "Outside"]);
eq("capabilities control expansion", row.expandable, true);
eq("a cover has no primary toggle", row.control, "none");
eq("optimistic state reaches the row", [row.isOn, row.pending], [false, true]);

const climate = {
  entity_id: "climate.hallway",
  state: "heat",
  attributes: { supported_features: 1 | 128 | 256, temperature: 22 }
};
const climateRow = Rows.project(climate.entity_id, climate, {
  name: "Hallway", icon: "T", isOn: true, pending: false,
  temperatureUnit: "°C", entityArea: {}, areaNames: {}
}, Model);
eq("climate turn-on/off support projects a primary toggle",
   climateRow.control, "toggle");
eq("climate keeps its temperature expansion", climateRow.expandable, true);

const climateWithoutTarget = {
  entity_id: "climate.hallway",
  state: "off",
  attributes: { supported_features: 1 | 128 | 256, current_temperature: 21 }
};
const offClimateRow = Rows.project(climateWithoutTarget.entity_id,
  climateWithoutTarget, {
    name: "Hallway", icon: "T", isOn: false, pending: false,
    temperatureUnit: "°C", entityArea: {}, areaNames: {}
  }, Model);
eq("off climate without a target keeps an expansion slot",
   offClimateRow.reserveExpandSlot, true);
eq("off climate without a target does not expose an empty expander",
   offClimateRow.expandable, false);

// A button reports its last press as its state; the row still has to offer the
// one-shot action rather than printing the timestamp as a badge.
const button = {
  entity_id: "button.front_door",
  state: "2026-08-27T08:25:57.454573+00:00",
  attributes: { friendly_name: "Front Door" }
};
const buttonRow = Rows.project(button.entity_id, button, {
  name: "Front Door", icon: "B", isOn: false, pending: false,
  temperatureUnit: "", entityArea: {}, areaNames: {}
}, Model);
eq("a button projects the one-shot control", buttonRow.control, "activate");
eq("a button is available despite its timestamp state",
   buttonRow.available, true);
eq("a button badges its kind, not its press time", buttonRow.badge, "Button");

const missing = Rows.project("light.missing", null, {
  name: "light.missing", icon: "?", isOn: false, pending: false,
  temperatureUnit: "", entityArea: {}, areaNames: {}
}, Model);
eq("missing favorites remain identifiable", missing.name, "light.missing");
eq("missing favorites are unavailable", missing.available, false);

console.log();
if (failures) {
  console.log(`FAILED: ${failures} of ${checks} checks`);
  process.exit(1);
}
console.log(`all ${checks} checks passed`);

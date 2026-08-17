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
const cover = {
  entity_id: "cover.a1b2c3d4-0000-0000-0000000000000001",
  state: "closed",
  attributes: { friendly_name: "Garage", position: 0 }
};
const row = Rows.project(cover.entity_id, cover, {
  name: "Main garage",
  icon: "X",
  isOn: false,
  pending: true,
  temperatureUnit: "°C",
  entityArea: { [cover.entity_id]: "outside" },
  areaNames: { outside: "Outside" }
}, Model);
eq("display context is projected", [row.name, row.icon, row.areaName],
   ["Main garage", "X", "Outside"]);
eq("a cover never expands — up/stop/down sit inline on the row instead",
   row.expandable, false);
eq("a cover has no primary toggle", row.control, "none");
eq("optimistic state reaches the row", [row.isOn, row.pending], [false, true]);

const climate = {
  entity_id: "climate.a1b2c3d4-0000-0000-0000000000000002",
  state: "auto",
  attributes: { temperature: 22 }
};
const climateRow = Rows.project(climate.entity_id, climate, {
  name: "Hallway", icon: "T", isOn: true, pending: false,
  temperatureUnit: "°C", entityArea: {}, areaNames: {}
}, Model);
eq("a Loxone room controller has no primary toggle — no `off` to send",
   climateRow.control, "none");
eq("a reported comfort target keeps the temperature expansion",
   climateRow.expandable, true);

const climateWithoutTarget = {
  entity_id: "climate.a1b2c3d4-0000-0000-0000000000000002",
  state: "auto",
  attributes: {}
};
const offClimateRow = Rows.project(climateWithoutTarget.entity_id,
  climateWithoutTarget, {
    name: "Hallway", icon: "T", isOn: false, pending: false,
    temperatureUnit: "°C", entityArea: {}, areaNames: {}
  }, Model);
eq("a room controller with no live target yet keeps an expansion slot",
   offClimateRow.reserveExpandSlot, true);
eq("it does not expose an empty expander before the target arrives",
   offClimateRow.expandable, false);

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

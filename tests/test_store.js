#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const source = fs
  .readFileSync(path.join(__dirname, "..", "EntityStore.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "");
const names = [...source.matchAll(/^function\s+([A-Za-z0-9_]+)/gm)].map((m) => m[1]);
const Store = new Function(`${source}\nreturn {${names.join(",")}};`)();

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

const LIGHT_A = "light.11111111-0000-0000-0000000000000001";
const SENSOR_B = "sensor.22222222-0000-0000-0000000000000002";
const LIGHT_NEW = "light.33333333-0000-0000-0000000000000003";

console.log("entity store projections");
const indexed = Store.indexStates([
  { entity_id: LIGHT_A, state: "on" },
  null,
  { entity_id: "", state: "off" },
  { entity_id: "__proto__", state: "hostile" },
  { entity_id: "sensor.tooshort", state: "hostile" },
  { entity_id: SENSOR_B, state: "4" }
]);
eq("valid states are indexed", Object.keys(indexed), [LIGHT_A, SENSOR_B]);

// Replacing a known entity is the hot path — every poll tick touches most
// controls — so it updates in place rather than rebuilding the map. Identity
// only changes when the set of entities does.
const updated = Store.upsertState(indexed, { entity_id: LIGHT_A, state: "off" });
eq("replacing a known entity keeps the same map", updated === indexed, true);
eq("upsert replaces one entity", updated[LIGHT_A].state, "off");
eq("a new entity gets a fresh map, so `states` identity tracks the entity set",
   Store.upsertState(updated, { entity_id: LIGHT_NEW, state: "on" }) === updated,
   false);
eq("the new entity is present",
   Object.keys(Store.upsertState(updated, { entity_id: LIGHT_NEW, state: "on" })),
   [LIGHT_A, SENSOR_B, LIGHT_NEW]);
eq("a rejected entity id leaves the map alone",
   Store.upsertState(updated, { entity_id: "__proto__", state: "hostile" }) === updated,
   true);
const removed = Store.removeState(updated, SENSOR_B);
eq("remove returns a new map without the entity", Object.keys(removed), [LIGHT_A]);
eq("remove leaves the input map intact", Object.keys(updated), [LIGHT_A, SENSOR_B]);

// Loxone controls carry their own room UUID directly (`area_id`), so
// projectRegistries only needs the rooms list plus the entities themselves —
// there is no separate device layer to join through the way Home Assistant
// has one.
const registries = Store.projectRegistries(
  [{ area_id: "k", name: "Kitchen" }, { area_id: "h", name: "Hall" }],
  [{ entity_id: LIGHT_A, area_id: "k" },
   { entity_id: SENSOR_B, area_id: "h" }]
);
eq("area names are projected", registries.areaNames, { k: "Kitchen", h: "Hall" });
eq("entity area comes straight from the entity",
   registries.entityArea, { [LIGHT_A]: "k", [SENSOR_B]: "h" });
eq("an entity with no room is left out of the mapping",
   Store.projectRegistries([], [{ entity_id: LIGHT_A, area_id: "" }]).entityArea,
   {});

eq("display names drive the stable index",
   Store.sortedIds(indexed, (id) => id === SENSOR_B ? "Alpha" : "Zulu"),
   [SENSOR_B, LIGHT_A]);

const SWITCH_MISSING = "switch.44444444-0000-0000-0000000000000004";
const tabs = Store.computeTabs(
  [LIGHT_A, SENSOR_B, SWITCH_MISSING], true,
  registries.areaNames, registries.entityArea
);
eq("favorites remain the first complete tab", tabs[0].entityIds,
   [LIGHT_A, SENSOR_B, SWITCH_MISSING]);
eq("areas are alphabetical", tabs.slice(1, 3).map((tab) => tab.title),
   ["Hall", "Kitchen"]);
eq("unassigned favorites remain visible",
   tabs[tabs.length - 1],
   { id: "other", title: "Other", entityIds: [SWITCH_MISSING] });

eq("flat mode doesn't depend on room data being ready",
   Store.computeTabs([LIGHT_A], false, {}, {}),
   [{ id: "favorites", title: "Favorites", entityIds: [LIGHT_A] }]);

console.log();
if (failures) {
  console.log(`FAILED: ${failures} of ${checks} checks`);
  process.exit(1);
}
console.log(`all ${checks} checks passed`);

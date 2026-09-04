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

console.log("entity store projections");
const indexed = Store.indexStates([
  { entity_id: "light.a", state: "on" },
  null,
  { entity_id: "", state: "off" },
  { entity_id: "__proto__", state: "hostile" },
  { entity_id: "sensor.b", state: "4" }
]);
eq("valid states are indexed", Object.keys(indexed), ["light.a", "sensor.b"]);

// Replacing a known entity is the hot path — hundreds of sensor updates a
// second on a real instance — so it updates in place rather than rebuilding
// the map. Identity only changes when the set of entities does.
const updated = Store.upsertState(indexed, { entity_id: "light.a", state: "off" });
eq("replacing a known entity keeps the same map", updated === indexed, true);
eq("upsert replaces one entity", updated["light.a"].state, "off");
eq("a new entity gets a fresh map, so `states` identity tracks the entity set",
   Store.upsertState(updated, { entity_id: "light.new", state: "on" }) === updated,
   false);
eq("the new entity is present",
   Object.keys(Store.upsertState(updated, { entity_id: "light.new", state: "on" })),
   ["light.a", "sensor.b", "light.new"]);
eq("a rejected entity id leaves the map alone",
   Store.upsertState(updated, { entity_id: "__proto__", state: "hostile" }) === updated,
   true);
const removed = Store.removeState(updated, "sensor.b");
eq("remove returns a new map without the entity", Object.keys(removed), ["light.a"]);
eq("remove leaves the input map intact", Object.keys(updated), ["light.a", "sensor.b"]);

const registries = Store.projectRegistries(
  [{ area_id: "k", name: "Kitchen" }, { area_id: "h", name: "Hall" }],
  [{ entity_id: "light.a", device_id: "d1" },
   { entity_id: "sensor.b", device_id: "d2", area_id: "h" }],
  [{ id: "d1", area_id: "k", name: "Lamp",
     manufacturer: "Acme", model: "Light 1" },
   { id: "d2", area_id: "k", name_by_user: "Bedroom air",
     manufacturer: "IKEA of Sweden", model: "VINDSTYRKA" }]
);
eq("area names are projected", registries.areaNames, { k: "Kitchen", h: "Hall" });
eq("entity area wins over its device",
   registries.entityArea, { "light.a": "k", "sensor.b": "h" });
eq("device names and entity membership are projected",
   [registries.deviceNames, registries.deviceInfo,
    registries.deviceEntities, registries.entityRegistry,
    registries.entityDevice],
   [{ d1: "Lamp", d2: "Bedroom air" },
    { d1: { manufacturer: "Acme", model: "Light 1" },
      d2: { manufacturer: "IKEA of Sweden", model: "VINDSTYRKA" } },
    { d1: ["light.a"], d2: ["sensor.b"] },
    { "light.a": { entityCategory: "", name: "", originalName: "" },
      "sensor.b": { entityCategory: "", name: "", originalName: "" } },
    { "light.a": "d1", "sensor.b": "d2" }]);
eq("device membership is stored in a prototype-free map",
   Object.getPrototypeOf(registries.deviceEntities), null);

const prototypeNamedDevice = Store.projectRegistries([], [
  { entity_id: "sensor.safe", device_id: "toString" }
], [
  { id: "toString", manufacturer: "IKEA of Sweden", model: "VINDSTYRKA E2112" }
]);
eq("a device ID named like an object prototype remains indexable",
   prototypeNamedDevice.deviceEntities.toString, ["sensor.safe"]);
eq("device metadata follows the same safe key",
   prototypeNamedDevice.deviceInfo.toString,
   { manufacturer: "IKEA of Sweden", model: "VINDSTYRKA E2112" });

// Favourite colours ride along in the registry entry's options, which is the
// only place Home Assistant publishes them — they are not on the entity state.
const withFavorites = Store.projectRegistries([], [
  { entity_id: "light.a", options: { light: { favorite_colors: [
    { color_temp_kelvin: 2700 }, { rgb_color: [255, 0, 0] }] } } },
  { entity_id: "light.b", options: { light: { favorite_colors: [] } } },
  { entity_id: "light.c", options: { conversation: { should_expose: true } } },
  { entity_id: "light.d" }
], []);
eq("saved favourites are carried through",
   withFavorites.favoriteColors["light.a"],
   [{ color_temp_kelvin: 2700 }, { rgb_color: [255, 0, 0] }]);
eq("a deliberately emptied list is carried as empty",
   withFavorites.favoriteColors["light.b"], []);
eq("and is distinguishable from a light that was never customised",
   "light.b" in withFavorites.favoriteColors
     && !("light.d" in withFavorites.favoriteColors), true);
eq("an unrelated options namespace is ignored",
   withFavorites.favoriteColors["light.c"], undefined);
eq("an entry with no options is ignored",
   withFavorites.favoriteColors["light.d"], undefined);

eq("display names drive the stable index",
   Store.sortedIds(indexed, (id) => id === "sensor.b" ? "Alpha" : "Zulu"),
   ["sensor.b", "light.a"]);

const tabs = Store.computeTabs(
  ["light.a", "sensor.b", "switch.missing"], true,
  registries.areaNames, registries.entityArea
);
eq("favorites remain the first complete tab", tabs[0].entityIds,
   ["light.a", "sensor.b", "switch.missing"]);
eq("areas are alphabetical", tabs.slice(1, 3).map((tab) => tab.title),
   ["Hall", "Kitchen"]);
eq("unassigned favorites remain visible",
   tabs[tabs.length - 1],
   { id: "other", title: "Other", entityIds: ["switch.missing"] });

eq("flat mode doesn't depend on registry readiness",
   Store.computeTabs(["light.a"], false, {}, {}),
   [{ id: "favorites", title: "Favorites", entityIds: ["light.a"] }]);

console.log();
if (failures) {
  console.log(`FAILED: ${failures} of ${checks} checks`);
  process.exit(1);
}
console.log(`all ${checks} checks passed`);

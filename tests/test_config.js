#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const source = fs
  .readFileSync(path.join(__dirname, "..", "ConfigStore.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "");
const names = [...source.matchAll(/^function\s+([A-Za-z0-9_]+)/gm)].map((m) => m[1]);
const constants = [...source.matchAll(/^var\s+([A-Z][A-Z0-9_]*)/gm)].map((m) => m[1]);
const Config = new Function(`${source}\nreturn {${[...names, ...constants].join(",")}};`)();

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

console.log("configuration normalization and serialization");
const invalid = Config.parse("{broken", ["light.demo"]);
eq("invalid JSON is reported", invalid.error, "config.json is not valid JSON");
eq("invalid config keeps safe demo defaults", invalid.config.demoFavorites,
   ["light.demo"]);

const parsed = Config.parse(JSON.stringify({
  baseUrl: 7,
  demoMode: true,
  favorites: ["light.a", 4, "", "light.a"],
  demoFavorites: [],
  showEntityIcons: false,
  showPanelPinOnHover: true,
  displayNameOverrides: { "light.a": "Desk", bad: 4 },
  iconOverrides: [],
  selectedTab: "area:kitchen"
}), ["light.demo"]);
eq("typed values are normalized", parsed.config, {
  baseUrl: "",
  localUrl: "",
  trustedNetwork: "",
  demoMode: true,
  favorites: ["light.a"],
  demoFavorites: [],
  roomReadings: [],
  demoRoomReadings: [],
  pinnedRoomReadings: [],
  demoPinnedRoomReadings: [],
  pinnedEntities: [],
  demoPinnedEntities: [],
  panelOrder: ["light.a"],
  demoPanelOrder: [],
  groupByArea: false,
  showEntityIcons: false,
  showPanelPinOnHover: true,
  selectedTab: "area:kitchen",
  displayNameOverrides: { "light.a": "Desk" },
  iconOverrides: {}
});

const defaults = Config.parse("{}", []);
eq("the panel pin hover shortcut is opt in",
   defaults.config.showPanelPinOnHover, false);

const withLocal = Config.parse(JSON.stringify({
  baseUrl: "https://ha.example.com",
  localUrl: 7,
  trustedNetwork: 9
}), []);
eq("a non-string localUrl falls back to empty", withLocal.config.localUrl, "");
eq("a non-string trustedNetwork falls back to empty",
   withLocal.config.trustedNetwork, "");

const withRooms = Config.parse(JSON.stringify({
  favorites: ["light.desk"],
  roomReadings: ["abc123", "abc123", "device.room", "bad value", "__proto__"],
  demoRoomReadings: ["device.demo"],
  pinnedRoomReadings: ["abc123", "missing", "abc123"],
  demoPinnedRoomReadings: ["device.demo", "missing"],
  pinnedEntities: ["light.desk", "sensor.missing"],
  demoPinnedEntities: ["sensor.missing"],
  panelOrder: ["room_reading:abc123", "light.desk", "room_reading:missing"],
  demoPanelOrder: ["room_reading:device.demo", "bad value"]
}), []);
eq("room-reading device ids are normalized independently from entity ids",
   withRooms.config.roomReadings, ["abc123", "device.room"]);
eq("demo room readings use their own namespace",
   withRooms.config.demoRoomReadings, ["device.demo"]);
eq("only selected room readings remain pinned",
   withRooms.config.pinnedRoomReadings, ["abc123"]);
eq("demo pins use their own selected room namespace",
   withRooms.config.demoPinnedRoomReadings, ["device.demo"]);
eq("only selected entities remain pinned",
   withRooms.config.pinnedEntities, ["light.desk"]);
eq("demo entity pins use their own selected namespace",
   withRooms.config.demoPinnedEntities, []);
eq("one panel order interleaves entities and room-reading cards",
   withRooms.config.panelOrder, ["room_reading:abc123", "light.desk",
                                 "room_reading:device.room"]);
eq("demo panel order is independent",
   withRooms.config.demoPanelOrder, ["room_reading:device.demo"]);

const merged = Config.merge(parsed.config, {
  groupByArea: true,
  localUrl: "https://192.168.1.50:8123",
  token: "must-not-be-serialized",
  unknown: "ignored"
});
eq("known keys merge", merged.groupByArea, true);
eq("localUrl merges like any other known key",
   merged.localUrl, "https://192.168.1.50:8123");
eq("unknown and secret keys are dropped", merged.token, undefined);
eq("serialized config has one trailing newline",
   Config.serialize(merged).endsWith("}\n"), true);
eq("serialized config contains no token", Config.serialize(merged).includes("token"), false);

console.log();
if (failures) {
  console.log(`FAILED: ${failures} of ${checks} checks`);
  process.exit(1);
}
console.log(`all ${checks} checks passed`);

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

const LIGHT = "light.11111111-0000-0000-0000000000000001";

console.log("configuration normalization and serialization");
const invalid = Config.parse("{broken", [LIGHT]);
eq("invalid JSON is reported", invalid.error, "config.json is not valid JSON");
eq("invalid config keeps safe demo defaults", invalid.config.demoFavorites, [LIGHT]);

const parsed = Config.parse(JSON.stringify({
  baseUrl: 7,
  username: 3,
  verifyTls: "yes",
  demoMode: true,
  favorites: [LIGHT, 4, "", LIGHT, "light.tooshort"],
  demoFavorites: [],
  showEntityIcons: false,
  displayNameOverrides: { [LIGHT]: "Desk", bad: 4 },
  iconOverrides: [],
  selectedTab: "area:kitchen"
}), [LIGHT]);
eq("typed values are normalized", parsed.config, {
  baseUrl: "",
  username: "",
  verifyTls: false,
  demoMode: true,
  favorites: [LIGHT],
  demoFavorites: [],
  groupByArea: false,
  showEntityIcons: false,
  selectedTab: "area:kitchen",
  displayNameOverrides: { [LIGHT]: "Desk" },
  iconOverrides: {},
  cameraUrl: "",
  cameraUsername: "",
  cameraVerifyTls: false
});

const withCreds = Config.parse(JSON.stringify({
  baseUrl: "https://192.168.1.77", username: "admin", verifyTls: true
}), []);
eq("username and verifyTls survive a round trip",
   [withCreds.config.baseUrl, withCreds.config.username, withCreds.config.verifyTls],
   ["https://192.168.1.77", "admin", true]);

const withCamera = Config.parse(JSON.stringify({
  cameraUrl: "https://192.168.1.50/mjpg/video.cgi",
  cameraUsername: "cam", cameraVerifyTls: 1
}), []);
eq("camera fields survive a round trip, and typed strictly",
   [withCamera.config.cameraUrl, withCamera.config.cameraUsername,
    withCamera.config.cameraVerifyTls],
   ["https://192.168.1.50/mjpg/video.cgi", "cam", false]);

const merged = Config.merge(parsed.config, {
  groupByArea: true,
  password: "must-not-be-serialized",
  unknown: "ignored"
});
eq("known keys merge", merged.groupByArea, true);
eq("unknown and secret keys are dropped", merged.password, undefined);
eq("serialized config has one trailing newline",
   Config.serialize(merged).endsWith("}\n"), true);
eq("serialized config contains no password",
   Config.serialize(merged).includes("password"), false);

console.log();
if (failures) {
  console.log(`FAILED: ${failures} of ${checks} checks`);
  process.exit(1);
}
console.log(`all ${checks} checks passed`);

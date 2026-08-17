#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const source = fs
  .readFileSync(path.join(__dirname, "..", "Connection.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "");
const names = [...source.matchAll(/^function\s+([A-Za-z0-9_]+)/gm)].map((m) => m[1]);
const Connection = new Function(`${source}\nreturn {${names.join(",")}};`)();

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

console.log("connection identity and generation isolation");
eq("bare host assumes TLS and its effective port",
   Connection.normalizeOrigin("Miniserver.local"),
   "https://miniserver.local:443");
eq("https default port is explicit",
   Connection.normalizeOrigin("https://Miniserver.local/path/"),
   "https://miniserver.local:443");
eq("wss shares the secure HTTP credential origin",
   Connection.normalizeOrigin("wss://Miniserver.local:8123/api/websocket"),
   "https://miniserver.local:8123");
eq("ws shares the plaintext HTTP credential origin",
   Connection.normalizeOrigin("ws://Miniserver.local:8123"),
   "http://miniserver.local:8123");
eq("IPv6 is canonicalized without losing brackets",
   Connection.normalizeOrigin("https://[FD00::1]:8123"),
   "https://[fd00::1]:8123");
eq("a protocol-relative URL is understood",
   Connection.normalizeOrigin("//miniserver.local:8123"), "https://miniserver.local:8123");
// A stray bracket used to pass the host check and produce a plausible origin,
// which the bridge's urlsplit then refused by raising — killing the process
// for what is only a half-pasted URL. Both parsers must call this a non-host.
eq("a trailing bracket is not a host",
   Connection.normalizeOrigin("https://miniserver.local:8123]"), "");
eq("a markdown-wrapped URL is not a host",
   Connection.normalizeOrigin("[https://miniserver.local:8123]"), "");
eq("an unopened bracket is not a host",
   Connection.normalizeOrigin("https://a]b"), "");
eq("brackets around a name are not an IPv6 literal",
   Connection.normalizeOrigin("https://a[b]c"), "");
eq("a bracketed port is not an IPv6 literal",
   Connection.normalizeOrigin("https://[8123]"), "");
eq("userinfo is rejected", Connection.normalizeOrigin("https://u:p@miniserver.local"), "");
eq("bad ports are rejected", Connection.normalizeOrigin("https://miniserver.local:99999"), "");
eq("an empty explicit port is rejected", Connection.normalizeOrigin("https://miniserver.local:"), "");
eq("unknown schemes are rejected", Connection.normalizeOrigin("ftp://miniserver.local"), "");
eq("demo has a separate signature", Connection.signature(true, ""), "demo");
// The signature is what reconcileConnection compares to decide whether the
// running bridge is still the right one, so it has to pin the URL text and not
// just the credential origin.
eq("a live signature pins the origin and the URL it came from",
   Connection.signature(false, "  https://Miniserver.local:8123/status  "),
   "https://miniserver.local:8123|https://Miniserver.local:8123/status");
eq("same origin, different path is a different connection",
   Connection.signature(false, "https://miniserver.local:8123")
     === Connection.signature(false, "https://miniserver.local:8123/sub"),
   false);
eq("the same URL is the same connection",
   Connection.signature(false, "https://miniserver.local:8123")
     === Connection.signature(false, "https://miniserver.local:8123"),
   true);
eq("an unusable URL has no signature",
   Connection.signature(false, "ftp://miniserver.local"), "");
eq("a bracket typo has no signature",
   Connection.signature(false, "https://miniserver.local:8123]"), "");
eq("matching generation is accepted", Connection.acceptsGeneration(4, 4), true);
eq("old generation is rejected", Connection.acceptsGeneration(5, 4), false);
eq("missing generation is rejected", Connection.acceptsGeneration(5, undefined), false);
const reduced = Connection.reducePhase(
  { generation: 5, phase: "connecting", error: "", errorKind: "" },
  { ev: "phase", generation: 5, phase: "connected" }
);
eq("phase reducer accepts the active generation", reduced.accepted, true);
eq("phase reducer advances state", reduced.state.phase, "connected");
eq("phase reducer rejects unknown phases",
   Connection.reducePhase(
     { generation: 5, phase: "connected" },
     { ev: "phase", generation: 5, phase: "ready-ish" }
   ).accepted, false);

console.log();
if (failures) {
  console.log(`FAILED: ${failures} of ${checks} checks`);
  process.exit(1);
}
console.log(`all ${checks} checks passed`);

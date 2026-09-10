#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

function load(name) {
  const source = fs
    .readFileSync(path.join(__dirname, "..", name), "utf8")
    .replace(/^\.pragma library\s*$/m, "");
  const names = [...source.matchAll(/^function\s+([A-Za-z0-9_]+)/gm)]
    .map((match) => match[1]);
  return new Function(`${source}\nreturn {${names.join(",")}};`)();
}

const ListSync = load("ListSync.js");

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

// Minimal stand-in for a QML ListModel that records the structural operations
// applied to it, so a test can assert that a reconcile only touched the rows
// it had to.
function FakeModel(rows) {
  this.rows = (rows || []).map((row) => Object.assign({}, row));
  this.ops = [];
}
Object.defineProperty(FakeModel.prototype, "count", {
  get() { return this.rows.length; }
});
FakeModel.prototype.get = function (i) { return this.rows[i]; };
FakeModel.prototype.set = function (i, row) {
  this.rows[i] = Object.assign({}, row);
  this.ops.push("set:" + i);
};
FakeModel.prototype.insert = function (i, row) {
  this.rows.splice(i, 0, Object.assign({}, row));
  this.ops.push("insert:" + i);
};
FakeModel.prototype.move = function (from, to, n) {
  const slice = this.rows.splice(from, n);
  this.rows.splice(to, 0, ...slice);
  this.ops.push("move:" + from + "->" + to);
};
FakeModel.prototype.remove = function (i) {
  this.rows.splice(i, 1);
  this.ops.push("remove:" + i);
};
FakeModel.prototype.keys = function () {
  return this.rows.map((row) => row.k);
};

function row(k, extra) {
  return Object.assign({ k, name: k.toUpperCase(), favorite: false }, extra);
}

console.log("list model reconcile");

// Empty model gets populated in order.
let model = new FakeModel();
ListSync.sync(model, [row("a"), row("b"), row("c")], "k");
eq("populates an empty model in order", model.keys(), ["a", "b", "c"]);
eq("populating is all inserts", model.ops, ["insert:0", "insert:1", "insert:2"]);

// An identical projection touches nothing.
model = new FakeModel([row("a"), row("b"), row("c")]);
ListSync.sync(model, [row("a"), row("b"), row("c")], "k");
eq("an unchanged projection is a no-op", model.ops, []);

// A single changed field patches exactly one row.
model = new FakeModel([row("a"), row("b"), row("c")]);
ListSync.sync(model,
  [row("a"), row("b", { favorite: true }), row("c")], "k");
eq("one flipped field is one set", model.ops, ["set:1"]);
eq("the flip is applied", model.get(1).favorite, true);

// Reordering keeps every row, only moves.
model = new FakeModel([row("a"), row("b"), row("c")]);
ListSync.sync(model, [row("b"), row("c"), row("a")], "k");
eq("a reorder ends in the target order", model.keys(), ["b", "c", "a"]);
eq("a reorder never sets unchanged rows",
   model.ops.every((op) => op.startsWith("move:")), true);

// Insertion in the middle and removal from the end.
model = new FakeModel([row("a"), row("b"), row("c")]);
ListSync.sync(model, [row("a"), row("x"), row("b")], "k");
eq("insert plus trailing removal reaches the target",
   model.keys(), ["a", "x", "b"]);

// Clearing.
model = new FakeModel([row("a"), row("b")]);
ListSync.sync(model, [], "k");
eq("an empty projection empties the model", model.keys(), []);

// A stale role left on the model row does not force a rewrite.
model = new FakeModel([row("a", { stale: "x" }), row("b")]);
model.ops = [];
ListSync.sync(model, [row("a"), row("b")], "k");
eq("an extra leftover role is ignored", model.ops, []);

console.log(`\n${checks - failures}/${checks} checks passed`);
process.exit(failures ? 1 : 0);

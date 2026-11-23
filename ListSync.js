.pragma library

// Reconcile a QML `ListModel` in place so a bound `ListView` keeps its scroll
// position and only the rows that actually changed re-render.
//
// The device picker's rows come from plain-array projections that are rebuilt
// from scratch on every throttled state tick and on every star toggle.
// Assigning a `ListView` a brand-new array model snaps it back to the top, so
// instead the array is diffed against a persistent `ListModel` and applied as
// the smallest possible run of insert / move / set / remove operations.
//
// Rows are objects that all carry the same set of fields. `keyField` (default
// "id") identifies a row across rebuilds.

function sync(model, rows, keyField) {
  var key = keyField || "id";
  rows = rows || [];

  // Fast path: the model already holds the same keys in the same order, which
  // is what a state tick or a single star toggle produces. Only touch the
  // rows whose fields differ.
  var aligned = model.count === rows.length;
  if (aligned) {
    for (var i = 0; i < rows.length; i++) {
      if (model.get(i)[key] !== rows[i][key]) {
        aligned = false;
        break;
      }
    }
  }
  if (aligned) {
    for (var j = 0; j < rows.length; j++) {
      if (!rowEquals(model.get(j), rows[j])) model.set(j, rows[j]);
    }
    return;
  }

  // General path: membership or order changed (a new search, a filter switch,
  // a reorder). Walk the target order, pulling each key into place.
  for (var t = 0; t < rows.length; t++) {
    var row = rows[t];
    var found = -1;
    for (var s = t; s < model.count; s++) {
      if (model.get(s)[key] === row[key]) {
        found = s;
        break;
      }
    }
    if (found === -1) {
      model.insert(t, row);
    } else {
      if (found !== t) model.move(found, t, 1);
      if (!rowEquals(model.get(t), row)) model.set(t, row);
    }
  }
  while (model.count > rows.length) model.remove(model.count - 1);
}

// Field-wise comparison over the keys `next` defines. A row read back from a
// `ListModel` may carry extra roles left over from an earlier shape; those are
// ignored on purpose, since `next` is the authority on what the row now is.
function rowEquals(current, next) {
  for (var k in next) {
    if (current[k] !== next[k]) return false;
  }
  return true;
}

.pragma library

// Hands the running Home Assistant service to bar modules that Omarchy mounts
// without it. A reading with its own layout id (so it can be dragged on its
// own) is a custom module, and the shell gives those no plugin services.
// Library state is shared by every importer, so Service.qml publishes itself
// here and each reading picks it up.

var current = null
var watchers = []

function service() {
  return current
}

function publish(value) {
  current = value
  for (var i = 0; i < watchers.length; i++) {
    try { watchers[i](value) } catch (e) {}
  }
}

function watch(callback) {
  watchers.push(callback)
  if (current) callback(current)
  return callback
}

function unwatch(callback) {
  var index = watchers.indexOf(callback)
  if (index >= 0) watchers.splice(index, 1)
}

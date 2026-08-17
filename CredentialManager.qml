import QtQuick
import Quickshell.Io

// Serialized system-keyring adapter. It owns every short-lived plaintext copy
// of a Miniserver password and never places one in argv. Service.qml decides
// whether the origin returned by a completed operation is still the active
// connection.
QtObject {
  id: root

  readonly property bool busy: writePending || clearPending || lookupPending

  property bool writePending: false
  property bool writeStarted: false
  property string writePassword: ""
  property string writeOrigin: ""

  property bool clearPending: false
  property bool clearStarted: false
  property string clearOrigin: ""

  property bool lookupPending: false
  property bool lookupStarted: false
  property string lookupOrigin: ""
  property string lookupPassword: ""

  signal passwordReady(string password, string origin)
  signal cleared(string origin)
  signal failed(string message, string origin)

  function store(password, origin) {
    if (root.busy || !password || !origin) {
      root.failed("A keyring operation is already in progress.", origin || "")
      return false
    }
    root.writePassword = String(password)
    root.writeOrigin = String(origin)
    root.writePending = true
    root.writeStarted = false
    storeProcess.command = [
      "secret-tool", "store", "--label=Loxone (Omarchy)",
      "service", "loxone", "origin", root.writeOrigin
    ]
    storeProcess.stdinEnabled = true
    storeProcess.running = true
    writeStartTimeout.restart()
    return true
  }

  function clear(origin) {
    if (root.busy || !origin) {
      root.failed("A keyring operation is already in progress.", origin || "")
      return false
    }
    root.clearOrigin = String(origin)
    root.clearPending = true
    root.clearStarted = false
    clearProcess.command = [
      "secret-tool", "clear", "service", "loxone", "origin", root.clearOrigin
    ]
    clearProcess.running = true
    clearStartTimeout.restart()
    return true
  }

  function lookup(origin) {
    if (root.busy || !origin) return false
    root.lookupOrigin = String(origin)
    root.lookupPassword = ""
    root.lookupPending = true
    root.lookupStarted = false
    lookupProcess.command = [
      "secret-tool", "lookup", "service", "loxone", "origin", root.lookupOrigin
    ]
    lookupProcess.running = true
    lookupStartTimeout.restart()
    return true
  }

  property Timer writeStartTimeout: Timer {
    interval: 5000
    onTriggered: {
      if (!root.writePending || root.writeStarted) return
      var origin = root.writeOrigin
      root.writePassword = ""
      root.writeOrigin = ""
      root.writePending = false
      root.failed("Could not start secret-tool to store the password.", origin)
      if (storeProcess.running) storeProcess.signal(15)
    }
  }

  property Timer clearStartTimeout: Timer {
    interval: 5000
    onTriggered: {
      if (!root.clearPending || root.clearStarted) return
      var origin = root.clearOrigin
      root.clearOrigin = ""
      root.clearPending = false
      root.failed("Could not start secret-tool to remove the password.", origin)
      if (clearProcess.running) clearProcess.signal(15)
    }
  }

  property Timer lookupStartTimeout: Timer {
    interval: 5000
    onTriggered: {
      if (!root.lookupPending || root.lookupStarted) return
      var origin = root.lookupOrigin
      root.lookupPending = false
      root.failed("Could not start secret-tool to read the password.", origin)
      if (lookupProcess.running) lookupProcess.signal(15)
    }
  }

  property Process storeProcess: Process {
    command: []
    stdinEnabled: true
    onStarted: {
      if (!root.writePending) {
        storeProcess.signal(15)
        return
      }
      root.writeStarted = true
      writeStartTimeout.stop()
      storeProcess.write(root.writePassword + "\n")
      storeProcess.stdinEnabled = false
    }
    onExited: function(exitCode) {
      if (!root.writePending) return
      writeStartTimeout.stop()
      var password = root.writePassword
      var origin = root.writeOrigin
      root.writePassword = ""
      root.writeOrigin = ""
      root.writePending = false
      root.writeStarted = false
      if (exitCode !== 0) {
        root.failed("Could not write the password to the keyring.", origin)
        return
      }
      root.passwordReady(password, origin)
    }
  }

  property Process clearProcess: Process {
    command: []
    onStarted: {
      if (!root.clearPending) {
        clearProcess.signal(15)
        return
      }
      root.clearStarted = true
      clearStartTimeout.stop()
    }
    onExited: function(exitCode) {
      if (!root.clearPending) return
      clearStartTimeout.stop()
      var origin = root.clearOrigin
      root.clearOrigin = ""
      root.clearPending = false
      root.clearStarted = false
      // Exit 1 means no matching item; the desired state is already reached.
      if (exitCode !== 0 && exitCode !== 1) {
        root.failed("Could not remove the password from the keyring. Retry removal.",
                    origin)
        return
      }
      root.cleared(origin)
    }
  }

  property Process lookupProcess: Process {
    command: []
    stdout: SplitParser {
      onRead: function(value) {
        if (root.lookupPending && !root.lookupPassword) {
          root.lookupPassword = String(value || "").trim()
        }
      }
    }
    onStarted: {
      if (!root.lookupPending) {
        lookupProcess.signal(15)
        return
      }
      root.lookupStarted = true
      lookupStartTimeout.stop()
    }
    onExited: function(exitCode) {
      if (!root.lookupPending) return
      lookupStartTimeout.stop()
      var origin = root.lookupOrigin
      root.lookupPending = false
      root.lookupStarted = false
      var password = exitCode === 0 ? root.lookupPassword : ""
      root.lookupPassword = ""
      if (password) root.passwordReady(password, origin)
      else root.failed("No password stored for this Loxone origin.", origin)
    }
  }
}

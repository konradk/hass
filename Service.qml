import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model
import "Connection.js" as Connection
import "EntityStore.js" as EntityStore
import "ConfigStore.js" as ConfigStore
import "RowModel.js" as RowModel

// Owner of all Loxone state.
//
// A `service` is mounted once per session, a `bar-widget` once per monitor, so
// the bridge, entities and config live here. Widgets reach them through
// `bar.shell.serviceFor("loxone")`.
QtObject {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: home + "/.config/omarchy/plugins/loxone"
  readonly property string configDir: home + "/.config/omarchy/loxone"
  readonly property string configPath: configDir + "/config.json"

  // idle | connecting | connected | error
  property string phase: "idle"
  property string lastError: ""
  property string lastErrorKind: ""
  property bool configured: false
  property bool demoMode: false
  property string baseUrl: ""
  property string username: ""
  property bool verifyTls: false
  property int connectionGeneration: 0
  property bool connectionSuppressed: false

  readonly property bool connected: phase === "connected"

  // entity_id -> raw entity. Updates replace the map; stateRevision also
  // invalidates bindings that read nested attributes.
  property var states: ({})
  property int stateRevision: 0

  // From the bridge's "registries" event — the Miniserver's rooms. Each
  // entity carries its own room UUID directly (as `area_id`), so unlike Home
  // Assistant there is no separate device layer to join through.
  property var roomsList: []
  property var areaNames: ({})
  property var entityArea: ({})

  // IRoomControllerV2 always works in Celsius; there is no instance-wide unit
  // to negotiate.
  readonly property string temperatureUnit: "°C"

  // ------------------------------------------------------------ camera
  //
  // An arbitrary HTTP(S) camera stream, independent of the Miniserver — it
  // has its own origin, its own credential, and its own lifecycle in the
  // bridge. The frame itself never touches QML property bindings or the
  // NDJSON channel: the bridge writes it straight to `cameraFramePath`, and
  // CameraStream.qml rereads that file on a timer.

  property string cameraUrl: ""
  property string cameraUsername: ""
  property bool cameraVerifyTls: false
  // idle | connecting | streaming | error
  property string cameraStatus: "idle"
  property string cameraError: ""

  readonly property bool cameraConfigured: root.cameraUrl.length > 0
  readonly property string cameraFramePath: root.configDir + "/camera.jpg"

  property string appliedCameraSignature: ""

  function cameraOrigin() {
    return Connection.normalizeOrigin(root.cameraUrl)
  }

  readonly property bool cameraCredentialBusy: cameraCredentials.busy

  property CredentialManager cameraCredentials: CredentialManager {
    onPasswordReady: function(password, origin) {
      if (origin === root.cameraOrigin()) root.pushCameraConfig(password)
    }
    onCleared: function(origin) {
      // Nothing further to do: applyCamera/removeCamera already cleared or
      // set config.json, and the bridge already got camera_disconnect.
    }
    onFailed: function(message, origin) {
      if (origin && origin !== root.cameraOrigin()) return
      root.cameraStatus = "error"
      root.cameraError = message
    }
  }

  // Mirrors applyConnection, but lighter: a camera has no generation to
  // reconcile against QML state and no "requires a fresh password" rule —
  // reusing a stored one for the same origin is exactly the point.
  function applyCamera(url, username, password) {
    var trimmedUrl = String(url || "").trim()
    var trimmedUser = String(username || "").trim()
    if (!trimmedUrl) {
      root.cameraStatus = "error"
      root.cameraError = "Enter a camera stream URL."
      return false
    }
    var origin = Connection.normalizeOrigin(trimmedUrl)
    if (!origin) {
      root.cameraStatus = "error"
      root.cameraError = "Enter a valid http(s) camera stream URL."
      return false
    }
    if (password.length > 0 && !cameraCredentials.store(password, origin)) {
      root.cameraStatus = "error"
      root.cameraError = "Could not start password storage while the keyring is busy."
      return false
    }
    root.saveConfig({ cameraUrl: trimmedUrl, cameraUsername: trimmedUser })
    if (password.length === 0) root.pushCameraCredentials()
    return true
  }

  function removeCamera() {
    if (root.cameraCredentialBusy) {
      root.lastError = "Wait for the current keyring operation to finish."
      return
    }
    var origin = root.cameraOrigin()
    root.send({ op: "camera_disconnect" })
    root.appliedCameraSignature = ""
    root.cameraStatus = "idle"
    root.cameraError = ""
    root.saveConfig({ cameraUrl: "", cameraUsername: "" })
    if (origin) cameraCredentials.clear(origin)
  }

  function pushCameraCredentials() {
    if (!root.cameraConfigured) return
    if (cameraCredentials.writePending) return
    var origin = root.cameraOrigin()
    if (!origin) return
    if (!cameraCredentials.lookup(origin)) cameraCredentialRetry.restart()
  }

  property Timer cameraCredentialRetry: Timer {
    interval: 400
    onTriggered: root.pushCameraCredentials()
  }

  function pushCameraConfig(password) {
    root.send({
      op: "camera_config",
      url: root.cameraUrl,
      username: root.cameraUsername,
      password: password,
      verifyTls: root.cameraVerifyTls,
      framePath: root.cameraFramePath
    })
  }

  function setCameraVerifyTls(enabled) {
    if (root.cameraVerifyTls === enabled) return
    root.saveConfig({ cameraVerifyTls: enabled })
  }

  // Only reconnects the camera when its own identity actually changed —
  // toggling a favorite must not restart a camera stream that is fine.
  function reconcileCamera() {
    if (!root.cameraConfigured) {
      if (root.appliedCameraSignature !== "") {
        root.send({ op: "camera_disconnect" })
      }
      root.appliedCameraSignature = ""
      root.cameraStatus = "idle"
      return
    }
    var signature = root.cameraUrl + "|" + root.cameraUsername + "|" + root.cameraVerifyTls
    if (signature === root.appliedCameraSignature) return
    root.appliedCameraSignature = signature
    root.pushCameraCredentials()
  }

  // A configured camera still costs the camera itself something to serve —
  // network and encoder load — for as long as the bridge is pulling frames.
  // That cost is only worth paying while a surface is actually showing the
  // stream: the bar popover, or Settings' own Camera tab (so "Connect" gives
  // immediate feedback). Panel.qml and Settings.qml each call register/
  // unregister from their own `opened` transitions; the count, not a single
  // bool, is what makes "both happen to be open at once" not a bug.
  property int cameraViewerCount: 0

  function registerCameraViewer() {
    root.cameraViewerCount++
    if (root.cameraViewerCount === 1) root.resumeCamera()
  }

  function unregisterCameraViewer() {
    root.cameraViewerCount = Math.max(0, root.cameraViewerCount - 1)
    if (root.cameraViewerCount === 0) root.pauseCamera()
  }

  function resumeCamera() {
    root.send({ op: "camera_resume" })
  }

  function pauseCamera() {
    root.send({ op: "camera_pause" })
  }

  // Disjoint namespaces: one shared list would show ghosts after a mode switch.
  property var liveFavorites: []
  property var demoFavorites: []
  readonly property var favorites: root.demoMode ? root.demoFavorites : root.liveFavorites

  property var displayNameOverrides: ({})
  property var iconOverrides: ({})
  property bool groupByArea: false
  property bool showEntityIcons: true

  // [{ id, title, entityIds }] — favorites, then areas, then "Other".
  property var tabs: [{ id: "favorites", title: "Favorites", entityIds: [] }]
  property string activeTab: "favorites"

  property Timer selectedTabSaveDebounce: Timer {
    interval: 300
    onTriggered: root.saveConfig({ selectedTab: root.activeTab })
  }

  // A ListModel, not a rebuilt array: one state_changed updates one delegate
  // instead of recreating every row.
  property ListModel rows: ListModel {}

  // ------------------------------------------------------------ config

  property FileView configFile: FileView {
    path: root.configPath
    watchChanges: true
    printErrors: false
    atomicWrites: true
    onLoaded: root.applyConfig(text())
    onLoadFailed: root.applyConfig("")
    onFileChanged: reload()
  }

  function currentConfig() {
    return {
      baseUrl: root.baseUrl,
      username: root.username,
      verifyTls: root.verifyTls,
      demoMode: root.demoMode,
      favorites: root.liveFavorites.slice(),
      demoFavorites: root.demoFavorites.slice(),
      groupByArea: root.groupByArea,
      showEntityIcons: root.showEntityIcons,
      selectedTab: root.activeTab,
      displayNameOverrides: root.displayNameOverrides,
      iconOverrides: root.iconOverrides,
      cameraUrl: root.cameraUrl,
      cameraUsername: root.cameraUsername,
      cameraVerifyTls: root.cameraVerifyTls
    }
  }

  function saveConfig(patch) {
    var config = ConfigStore.merge(root.currentConfig(), patch)
    var text = ConfigStore.serialize(config)

    configFile.setText(text)
    // FileView does not re-emit onLoaded for its own write.
    root.applyConfig(text)
  }

  function setGroupByArea(enabled) {
    if (root.groupByArea === enabled) return
    root.saveConfig({ groupByArea: enabled })
  }

  function setVerifyTls(enabled) {
    if (root.verifyTls === enabled) return
    root.saveConfig({ verifyTls: enabled })
  }

  // FileView will not create a missing parent directory, and starting the
  // process is asynchronous — doing it inside saveConfig races the write it is
  // supposed to enable, which on a fresh install loses the first save silently
  // (printErrors is off). Once, at startup, is early enough for every write.
  property Process configDirProcess: Process {
    command: ["mkdir", "-p", root.configDir]
  }

  Component.onCompleted: root.configDirProcess.running = true

  function toggleFavorite(entityId) {
    var favorites = root.favorites.slice()
    var index = favorites.indexOf(entityId)
    if (index === -1) favorites.push(entityId)
    else favorites.splice(index, 1)
    root.saveFavorites(favorites)
  }

  function moveFavorite(entityId, delta) {
    var favorites = root.favorites.slice()
    var index = favorites.indexOf(entityId)
    if (index === -1) return
    var target = index + delta
    if (target < 0 || target >= favorites.length) return
    favorites.splice(target, 0, favorites.splice(index, 1)[0])
    root.saveFavorites(favorites)
  }

  function saveFavorites(list) {
    root.saveConfig(root.demoMode ? { demoFavorites: list } : { favorites: list })
  }

  function isFavorite(entityId) {
    return root.favorites.indexOf(entityId) !== -1
  }

  // ------------------------------------------------------------ credentials

  readonly property bool credentialBusy: credentials.busy

  property CredentialManager credentials: CredentialManager {
    onPasswordReady: function(password, origin) {
      if (!root.demoMode && !root.connectionSuppressed
          && origin === root.currentOrigin()) {
        root.pushConfig(password)
      } else if (!root.connectionSuppressed) {
        Qt.callLater(root.pushCredentials)
      }
    }
    onCleared: function(origin) {
      if (origin === root.currentOrigin()) root.finishRemoveConnection()
    }
    onFailed: function(message, origin) {
      if (origin && origin !== root.currentOrigin()) return
      root.phase = "error"
      root.lastError = message
      root.lastErrorKind = "credential"
    }
  }

  function currentOrigin() {
    return Connection.normalizeOrigin(root.baseUrl)
  }

  function requiresPasswordFor(url) {
    var origin = Connection.normalizeOrigin(url)
    if (!origin) return true
    return root.demoMode || !root.configured || origin !== root.currentOrigin()
  }

  function removeConnection() {
    if (root.credentialBusy) {
      root.lastError = "Wait for the current keyring operation to finish."
      return
    }
    var origin = root.currentOrigin()
    root.connectionSuppressed = true
    root.disconnectBridge()
    root.appliedConnection = ""
    root.forgetDevices()
    if (!origin) {
      root.finishRemoveConnection()
      return
    }
    if (!credentials.clear(origin)) {
      root.phase = "error"
      root.lastError = "Could not start password removal while the keyring is busy."
    }
  }

  function finishRemoveConnection() {
    root.connectionSuppressed = false
    root.saveConfig({
      baseUrl: "", username: "", demoMode: false, favorites: [],
      displayNameOverrides: {}, iconOverrides: {}, selectedTab: "favorites"
    })   // demoFavorites untouched: not part of the connection
  }

  // A mode switch, not a form field: applies the moment it flips.
  function setDemoMode(enabled) {
    if (root.demoMode === enabled) return
    if (root.credentialBusy) {
      root.lastError = "Wait for the current keyring operation to finish."
      return
    }
    root.connectionSuppressed = false
    root.saveConfig({ demoMode: enabled })
  }

  // Stops the bridge retrying without discarding the configuration.
  function cancelConnection() {
    root.connectionSuppressed = true
    root.disconnectBridge()
    root.appliedConnection = ""
    root.forgetDevices()
    root.phase = "idle"
    root.lastError = "Connection cancelled."
  }

  function retryConnection() {
    root.connectionSuppressed = false
    root.appliedConnection = ""
    root.lastError = ""
    root.reconcileConnection()
  }

  function applyConnection(url, username, password, demo) {
    var origin = demo ? "demo" : Connection.normalizeOrigin(url)
    if (!origin) {
      root.phase = "error"
      root.lastError = "Enter a valid http(s) Miniserver URL."
      return false
    }
    var trimmedUser = String(username || "").trim()
    if (!demo && !trimmedUser) {
      root.phase = "error"
      root.lastError = "Enter the Miniserver username."
      return false
    }
    if (!demo && !password && root.requiresPasswordFor(url)) {
      root.phase = "error"
      root.lastError = "A new Miniserver origin requires its password again."
      return false
    }
    root.connectionSuppressed = false
    // Start the serialized write before applyConfig runs so reconciliation
    // cannot race a lookup of the previous credential.
    if (!demo && password.length > 0 && !credentials.store(password, origin)) {
      root.phase = "error"
      root.lastError = "Could not start password storage while the keyring is busy."
      return false
    }
    root.saveConfig({ baseUrl: url, username: trimmedUser, demoMode: demo })
    return true
  }

  // The text last projected into the properties below. saveConfig applies its
  // own write immediately (FileView doesn't re-emit onLoaded for it), and the
  // watcher then reports the same file a moment later — so every favorite
  // toggle otherwise re-sorted and re-projected the whole list twice.
  property string appliedConfigText: ""

  function applyConfig(text) {
    if (text && text === root.appliedConfigText) {
      // Same bytes, so every property below already holds them. Reconciliation
      // still runs: it is idempotent, and it is what restarts a bridge that
      // exited since the last apply.
      root.reconcileConnection()
      root.reconcileCamera()
      return
    }
    root.appliedConfigText = text
    var parsed = ConfigStore.parse(text, Model.DEMO_DEFAULT_FAVORITES)
    var config = parsed.config
    if (parsed.error) root.lastError = parsed.error

    root.demoMode = config.demoMode
    root.baseUrl = config.baseUrl
    root.username = config.username
    root.verifyTls = config.verifyTls
    root.liveFavorites = config.favorites
    root.demoFavorites = config.demoFavorites
    root.displayNameOverrides = config.displayNameOverrides
    root.iconOverrides = config.iconOverrides
    root.groupByArea = config.groupByArea
    root.showEntityIcons = config.showEntityIcons
    root.activeTab = config.selectedTab
    root.cameraUrl = config.cameraUrl
    root.cameraUsername = config.cameraUsername
    root.cameraVerifyTls = config.cameraVerifyTls

    root.configured = root.demoMode || root.baseUrl.length > 0
    rebuildSortedIds()
    rebuildRows()
    root.reconcileConnection()
    root.reconcileCamera()
  }

  // Which connection the bridge is running for. Config is saved on every
  // favorite toggle, and those must not drop the connection.
  property string appliedConnection: ""

  function forgetDevices() {
    root.states = ({})
    root.stateRevision++
    root.sortedEntityIds = []
    root.roomsList = []
    root.areaNames = ({})
    root.entityArea = ({})
    root.pendingToggles = ({})
    pendingSweep.running = false
    root.rebuildRows()
  }

  function disconnectBridge() {
    root.connectionGeneration++
    root.send({ op: "disconnect", generation: root.connectionGeneration })
  }

  function reconcileConnection() {
    if (root.connectionSuppressed) return

    if (!root.configured) {
      if (root.appliedConnection !== "") {
        // Clearing the config is not enough: the bridge keeps polling the
        // Miniserver with the old password until it is told otherwise, and
        // keeps feeding this service devices the user just removed.
        root.disconnectBridge()
        root.forgetDevices()
      }
      root.appliedConnection = ""
      root.phase = "idle"
      return
    }

    // Connection.js owns this rule, so the definition of "same connection"
    // cannot drift from the one the tests pin.
    var signature = Connection.signature(root.demoMode, root.baseUrl)
    if (!signature) {
      root.phase = "error"
      root.lastError = "Miniserver URL is invalid."
      return
    }
    if (signature === root.appliedConnection && bridgeController.running) return

    // A new generation is visible synchronously in QML before the command can
    // reach Python. Any lines already buffered from the old bridge generation
    // are therefore rejected by handleEvent.
    if (root.appliedConnection !== "") root.forgetDevices()
    root.appliedConnection = signature
    root.connectionGeneration++

    if (root.startBridge()) root.pushCredentials()
  }

  // Split out of reconcileConnection because a bridge restart has to redo it:
  // the push that went to the process we just signalled never arrived.
  function pushCredentials() {
    if (root.demoMode) {
      root.pushConfig("")
      return
    }
    // A password being written pushes itself; reading here would race it.
    if (credentials.writePending) return
    var origin = root.currentOrigin()
    if (!origin) return
    // lookup() refuses while any other keyring process is in flight, and says
    // so only through its return value. Dropping that on the floor leaves the
    // panel stuck on "connecting" with nothing queued to push a password —
    // the window is short (every keyring op has a 5s start timeout) but it is
    // reached whenever the bridge restarts during a lookup already in flight.
    if (!credentials.lookup(origin)) credentialRetry.restart()
  }

  property Timer credentialRetry: Timer {
    interval: 400
    onTriggered: {
      if (root.connectionSuppressed || !root.configured || root.demoMode) return
      root.pushCredentials()
    }
  }

  // ------------------------------------------------------------ bridge

  property BridgeController bridgeController: BridgeController {
    executable: root.pluginDir + "/bin/loxone-bridge"
    protocolVersion: 1
    onLine: function(value) { root.handleEvent(value) }
    onReady: {
      root.phase = "connecting"
      root.pushCredentials()
    }
    onFailed: function(message) {
      root.phase = "error"
      root.lastError = message
    }
  }

  // Settings needs this to tell "retrying" apart from "the helper died and
  // nothing is retrying at all", which otherwise both read as phase "error".
  readonly property bool bridgeRunning: bridgeController.running

  function startBridge() {
    root.phase = "connecting"
    return bridgeController.ensureStarted(root.demoMode)
  }

  function send(command) {
    return bridgeController.send(command)
  }

  function pushConfig(password) {
    root.send({
      op: "config",
      url: root.baseUrl,
      username: root.username,
      password: password,
      verifyTls: root.verifyTls,
      generation: root.connectionGeneration
    })
  }

  function sendCommand(entityId, command, value, tag) {
    var payload = { op: "command", entity_id: entityId, command: command, tag: tag || "" }
    if (value !== undefined) payload.value = value
    return root.send(payload)
  }

  // ------------------------------------------------------------ actions

  // entity_id -> { desired, deadline }. The row flips at once and waits for
  // state_changed to confirm.
  property var pendingToggles: ({})

  property Timer pendingSweep: Timer {
    interval: 250
    repeat: true
    onTriggered: root.sweepPendingToggles()
  }

  function hasPendingToggles() {
    for (var key in root.pendingToggles) return true
    return false
  }

  // Must outlast the bridge's own poll interval, or a slow-but-successful
  // command reports "no response" here while the bridge is still waiting for
  // the answer it goes on to receive.
  readonly property int pendingToggleTimeout: 6500

  function setPendingToggle(entityId, desired) {
    root.pendingToggles[entityId] = {
      desired: desired,
      deadline: Date.now() + root.pendingToggleTimeout
    }
    root.refreshRow(entityId)
    pendingSweep.running = true
  }

  function clearPendingToggle(entityId) {
    if (root.pendingToggles[entityId] === undefined) return
    delete root.pendingToggles[entityId]
    if (!root.hasPendingToggles()) pendingSweep.running = false
  }

  function sweepPendingToggles() {
    var current = Date.now()
    var expired = []
    for (var entityId in root.pendingToggles) {
      if (root.pendingToggles[entityId].deadline <= current) expired.push(entityId)
    }
    for (var i = 0; i < expired.length; i++) {
      delete root.pendingToggles[expired[i]]
      root.refreshRow(expired[i])
      root.lastError = "No response from the Miniserver."
    }
    if (!root.hasPendingToggles()) pendingSweep.running = false
  }

  function capabilities(entityId) {
    return Model.capabilitiesFor(root.states[entityId])
  }

  function rejectAction(message) {
    root.lastError = message
    root.lastErrorKind = "command"
    return false
  }

  function toggleEntity(entityId) {
    var entity = root.states[entityId]
    if (!entity) return false
    if (root.pendingToggles[entityId] !== undefined) return false
    if (!Model.capabilitiesFor(entity).toggle) {
      return root.rejectAction("This entity does not support toggling.")
    }

    var currentlyOn = root.displayIsOn(entityId)
    var call = Model.toggleCall(entity, currentlyOn)
    root.setPendingToggle(entityId, !currentlyOn)
    var sent = root.sendCommand(entityId, call.command, undefined, "toggle:" + entityId)
    if (!sent) {
      root.clearPendingToggle(entityId)
      root.refreshRow(entityId)
    }
    return sent
  }

  function displayIsOn(entityId) {
    var pending = root.pendingToggles[entityId]
    if (pending !== undefined) return pending.desired
    var entity = root.states[entityId]
    return entity ? Model.isOn(entity) : false
  }

  // Every call is tagged. An untagged one has its failure dropped on the floor
  // by the bridge, which is how a rejected pushbutton or a refused cover used
  // to look exactly like a button that does nothing.
  function callTag(entityId) {
    return "call:" + entityId
  }

  function setBrightness(entityId, percent) {
    if (!root.capabilities(entityId).brightness) {
      return root.rejectAction("This light does not support brightness control.")
    }
    var clamped = Math.max(0, Math.min(100, Math.round(percent)))
    root.sendCommand(entityId, "set_brightness", clamped, root.callTag(entityId))
  }

  function setVolume(entityId, level) {
    if (!root.capabilities(entityId).mediaVolume) {
      return root.rejectAction("This media player does not support volume control.")
    }
    var clamped = Math.max(0, Math.min(1, level))
    root.sendCommand(entityId, "set_volume", clamped, root.callTag(entityId))
  }

  function mediaPlayPause(entityId) {
    if (!root.capabilities(entityId).mediaPlayPause) {
      return root.rejectAction("This media player does not support play/pause.")
    }
    root.sendCommand(entityId, "media_play_pause", undefined, root.callTag(entityId))
  }

  function mediaNext(entityId) {
    if (!root.capabilities(entityId).mediaNext) {
      return root.rejectAction("This media player does not support next track.")
    }
    root.sendCommand(entityId, "media_next", undefined, root.callTag(entityId))
  }

  function mediaPrevious(entityId) {
    if (!root.capabilities(entityId).mediaPrevious) {
      return root.rejectAction("This media player does not support previous track.")
    }
    root.sendCommand(entityId, "media_previous", undefined, root.callTag(entityId))
  }

  function coverAction(entityId, service) {
    var caps = root.capabilities(entityId)
    var supported = service === "open_cover" ? caps.coverOpen
      : service === "stop_cover" ? caps.coverStop
      : service === "close_cover" ? caps.coverClose
      : false
    if (!supported) return root.rejectAction("This cover does not support that action.")
    root.sendCommand(entityId, service, undefined, root.callTag(entityId))
  }

  function setLock(entityId, locked) {
    if (!root.capabilities(entityId).lock) {
      return root.rejectAction("This entity does not support lock control.")
    }
    root.setPendingToggle(entityId, locked)
    // toggleEntity's tag prefix, so rollback runs through one path.
    var sent = root.sendCommand(entityId, locked ? "on" : "off", undefined, "toggle:" + entityId)
    if (!sent) {
      root.clearPendingToggle(entityId)
      root.refreshRow(entityId)
    }
    return sent
  }

  // The primary action for a row, whatever that means for its domain. IPC and
  // the panel's Enter key both land here, so `loxone toggleEntity light.desk`
  // does what the row's own switch does instead of reporting the entity as
  // not toggleable — `toggle` capability covers only the on/off domains.
  function activateEntity(entityId) {
    var entity = root.states[entityId]
    if (!entity) return false
    switch (Model.controlKind(entity)) {
    case "toggle": return root.toggleEntity(entityId)
    case "lock": return root.setLock(entityId, !root.displayIsOn(entityId))
    case "activate": return root.activateScene(entityId)
    }
    return root.rejectAction("This entity has no on/off control.")
  }

  function activateScene(entityId) {
    if (!root.capabilities(entityId).activate) {
      return root.rejectAction("Only pushbuttons can be activated.")
    }
    return root.sendCommand(entityId, "activate", undefined, root.callTag(entityId))
  }

  function setClimateTemperature(entityId, target, low, high) {
    var entity = root.states[entityId]
    var data = Model.climateTemperatureData(entity, target, root.temperatureUnit)
    if (Object.keys(data).length === 0) {
      return root.rejectAction("This climate entity does not report a controllable target.")
    }
    root.sendCommand(entityId, "set_temperature", data.temperature, root.callTag(entityId))
  }

  function refresh() {
    root.send({ op: "refresh" })
  }

  // ------------------------------------------------------------ events

  function handleEvent(line) {
    var text = String(line || "").trim()
    if (!text) return

    var event
    try {
      event = JSON.parse(text)
    } catch (e) {
      return
    }
    if (!event || typeof event !== "object") return

    // The camera has its own lifecycle, independent of the Miniserver
    // connection generation — it carries none, so it must not be run through
    // a gate built for one.
    if (event.ev === "camera") {
      root.cameraStatus = String(event.status || "idle")
      root.cameraError = typeof event.error === "string" ? event.error : ""
      return
    }

    if (!Connection.acceptsGeneration(root.connectionGeneration, event.generation)) {
      return
    }

    switch (event.ev) {
    case "phase":
      var transition = Connection.reducePhase({
        generation: root.connectionGeneration,
        phase: root.phase,
        error: root.lastError,
        errorKind: root.lastErrorKind
      }, event)
      if (!transition.accepted) return
      root.phase = transition.state.phase
      root.lastError = transition.state.error
      root.lastErrorKind = transition.state.errorKind
      break
    case "states":
      root.applyStates(event.entities || [])
      break
    case "state_changed":
      root.applyStateChanged(event.entity)
      break
    case "removed":
      root.states = EntityStore.removeState(root.states, event.entity_id)
      root.stateRevision++
      root.rebuildSortedIds()
      root.recomputeAreas()
      root.rebuildRows()
      break
    case "registries":
      root.roomsList = Array.isArray(event.rooms) ? event.rooms : []
      root.recomputeAreas()
      root.rebuildRows()
      break
    case "result":
      root.handleResult(event)
      break
    case "log":
      if (event.level === "warn") console.warn("loxone-bridge: " + event.msg)
      break
    }
  }

  function handleResult(event) {
    if (event.ok === true) return

    var tag = String(event.tag || "")
    if (tag.indexOf("toggle:") === 0) {
      // Drop the guess now rather than at the sweep timer. On success it
      // stays: the confirming state_changed is already on its way.
      var entityId = tag.slice("toggle:".length)
      root.clearPendingToggle(entityId)
      root.refreshRow(entityId)
    }
    root.lastError = event.error || "Command failed."
    root.lastErrorKind = event.errorKind || "command"
  }

  function applyStates(entities) {
    root.states = EntityStore.indexStates(entities)
    root.stateRevision++
    root.rebuildSortedIds()
    root.recomputeAreas()
    root.rebuildRows()
  }

  function applyStateChanged(entity) {
    if (!entity || !entity.entity_id) return
    // The browser walks the sorted index, not `states`, so an entity that
    // appears after the snapshot stays unfindable in settings until the
    // index is rebuilt.
    var isNew = root.states[entity.entity_id] === undefined
    root.states = EntityStore.upsertState(root.states, entity)
    root.stateRevision++
    root.clearPendingToggle(entity.entity_id)
    if (isNew) {
      root.rebuildSortedIds()
      root.recomputeAreas()
      root.rebuildRows()
    } else {
      root.refreshRow(entity.entity_id)
    }
  }

  // Every entity carries its own room UUID directly (`area_id`), so this is a
  // straight projection over the current state map plus the rooms list.
  function recomputeAreas() {
    var list = []
    for (var id in root.states) list.push(root.states[id])
    var projection = EntityStore.projectRegistries(root.roomsList, list)
    root.areaNames = projection.areaNames
    root.entityArea = projection.entityArea
  }

  // Drives EntityRow.reserveExpandSlot.
  property bool rowsHaveExpandable: false

  function recomputeExpandable() {
    for (var i = 0; i < rows.count; i++) {
      if (rows.get(i).reserveExpandSlot) {
        root.rowsHaveExpandable = true
        return
      }
    }
    root.rowsHaveExpandable = false
  }

  function refreshRow(entityId) {
    for (var i = 0; i < rows.count; i++) {
      if (rows.get(i).entityId === entityId) {
        rows.set(i, rowFor(entityId))
        root.recomputeExpandable()
        return
      }
    }
  }

  // ------------------------------------------------------------ rows

  // Attributes the row model does not carry, for the expanded controls.
  function entityFor(entityId) {
    return root.states[entityId]
  }

  // Display order, rebuilt only when the *set* of entities changes: sorting
  // per poll tick is what would make the settings search lag.
  property var sortedEntityIds: []

  function rebuildSortedIds() {
    root.sortedEntityIds = EntityStore.sortedIds(root.states, root.displayName)
  }

  // Walks the pre-sorted index, so this only filters.
  function browseEntities(query, filterId) {
    var out = []
    var ids = root.sortedEntityIds
    for (var i = 0; i < ids.length; i++) {
      var entityId = ids[i]
      var entity = root.states[entityId]
      if (!entity) continue
      if (!Model.filterMatches(filterId, entity)) continue
      var areaId = root.entityArea[entityId]
      var areaName = areaId ? root.areaNames[areaId] : ""
      if (!Model.searchMatches(query, entity, areaName)) continue
      out.push({
        entityId: entityId,
        name: root.displayName(entityId),
        icon: root.iconFor(entityId, entity),
        state: Model.displayState(entity),
        favorite: root.isFavorite(entityId)
      })
    }
    return out
  }

  function favoriteSummaries() {
    return root.favorites.map(function(entityId) {
      var entity = root.states[entityId]
      return {
        entityId: entityId,
        name: root.displayName(entityId),
        icon: root.iconFor(entityId, entity),
        state: entity ? Model.displayState(entity) : "Unavailable",
        available: entity !== undefined
      }
    })
  }

  // Favorites exist before any connection, so row count says nothing about
  // whether anything real is behind them.
  readonly property bool hasDevices: {
    root.stateRevision
    for (var key in root.states) return true
    return false
  }

  readonly property string activitySummary: {
    root.stateRevision
    var picked = []
    for (var i = 0; i < root.favorites.length; i++) {
      var entity = root.states[String(root.favorites[i])]
      if (entity) picked.push(entity)
    }
    return Model.activitySummary(picked)
  }

  function displayName(entityId) {
    var override = root.displayNameOverrides[entityId]
    if (override) return String(override)
    var entity = root.states[entityId]
    // A missing entity still has to be identifiable.
    var base = entity ? Model.name(entity) : entityId
    // Loxone control names repeat across rooms constantly — "Jalousie" in
    // every room with a blind — so the room goes on the end wherever this
    // name is shown, not just in the picker.
    var areaId = root.entityArea[entityId]
    var areaName = areaId ? root.areaNames[areaId] : ""
    // Loxone setups commonly name a room's one light after the room itself
    // ("Empore" the room, "Empore" the light) — "Empore (Empore)" would be
    // noise, not disambiguation.
    if (!areaName || areaName.toLowerCase() === base.toLowerCase()) return base
    return base + " (" + areaName + ")"
  }

  // A literal glyph, so any Nerd Font character works.
  function iconFor(entityId, entity) {
    var override = root.iconOverrides[entityId]
    if (override) return String(override)
    return entity ? Model.iconFor(entity) : Model.FALLBACK_ICON
  }

  function rowFor(entityId) {
    var entity = root.states[entityId]
    return RowModel.project(entityId, entity, {
      name: root.displayName(entityId),
      icon: root.iconFor(entityId, entity),
      isOn: root.displayIsOn(entityId),
      pending: root.pendingToggles[entityId] !== undefined,
      temperatureUnit: root.temperatureUnit,
      entityArea: root.entityArea,
      areaNames: root.areaNames
    }, Model)
  }

  // Falls back to a flat list when it cannot do better: losing rows because
  // area data has not arrived is worse than not grouping.
  function computeTabs() {
    return EntityStore.computeTabs(
      root.favorites, root.groupByArea, root.areaNames, root.entityArea)
  }

  // `activeTab` is the saved intent, `effectiveTab` what exists right now.
  // Area tabs appear only once the rooms list arrives; overwriting the intent
  // in that window would discard the saved tab on every launch.
  readonly property string effectiveTab: {
    root.tabsRevision
    for (var i = 0; i < root.tabs.length; i++) {
      if (root.tabs[i].id === root.activeTab) return root.activeTab
    }
    return root.tabs.length ? root.tabs[0].id : "favorites"
  }
  property int tabsRevision: 0

  function entityIdsForActiveTab() {
    for (var i = 0; i < root.tabs.length; i++) {
      if (root.tabs[i].id === root.effectiveTab) return root.tabs[i].entityIds
    }
    return root.tabs.length ? root.tabs[0].entityIds : []
  }

  function setActiveTab(tabId) {
    if (root.activeTab === tabId) return
    root.activeTab = tabId
    root.rebuildRows()
    selectedTabSaveDebounce.restart()
  }

  function rebuildRows() {
    root.tabs = root.computeTabs()
    root.tabsRevision++
    var entityIds = root.entityIdsForActiveTab()

    rows.clear()
    for (var i = 0; i < entityIds.length; i++) {
      rows.append(rowFor(entityIds[i]))
    }
    root.recomputeExpandable()
  }

}

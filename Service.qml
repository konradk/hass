import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model
import "Connection.js" as Connection
import "EntityStore.js" as EntityStore
import "ConfigStore.js" as ConfigStore
import "RowModel.js" as RowModel

// Owner of all Home Assistant state.
//
// A `service` is mounted once per session, a `bar-widget` once per monitor, so
// the bridge, entities and config live here. Widgets reach them through
// `bar.shell.serviceFor("hass")`.
QtObject {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: home + "/.config/omarchy/plugins/hass"
  readonly property string configDir: home + "/.config/omarchy/hass"
  readonly property string configPath: configDir + "/config.json"

  // idle | connecting | connected | error
  property string phase: "idle"
  property string lastError: ""
  property string lastErrorKind: ""
  property bool configured: false
  property bool demoMode: false
  property string baseUrl: ""
  property int connectionGeneration: 0
  property bool connectionSuppressed: false

  readonly property bool connected: phase === "connected"

  // entity_id -> raw entity. Updates replace the map; stateRevision also
  // invalidates bindings that read nested attributes.
  property var states: ({})
  property int stateRevision: 0

  property var areaNames: ({})
  property var entityArea: ({})

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

  // Instance-wide, from the bridge's get_config. Climate entities carry no
  // unit of their own, so without this every temperature renders bare.
  property string temperatureUnit: ""

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
      demoMode: root.demoMode,
      favorites: root.liveFavorites.slice(),
      demoFavorites: root.demoFavorites.slice(),
      groupByArea: root.groupByArea,
      showEntityIcons: root.showEntityIcons,
      selectedTab: root.activeTab,
      displayNameOverrides: root.displayNameOverrides,
      iconOverrides: root.iconOverrides
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

  readonly property bool tokenWritePending: credentials.writePending
  readonly property bool tokenClearPending: credentials.clearPending
  readonly property bool credentialBusy: credentials.busy

  property CredentialManager credentials: CredentialManager {
    onTokenReady: function(token, origin) {
      if (!root.demoMode && !root.connectionSuppressed
          && origin === root.currentOrigin()) {
        root.pushConfig(token)
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

  function requiresTokenFor(url) {
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
      root.lastError = "Could not start token removal while the keyring is busy."
    }
  }

  function finishRemoveConnection() {
    root.connectionSuppressed = false
    root.saveConfig({
      baseUrl: "", demoMode: false, favorites: [],
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

  function applyConnection(url, token, demo) {
    var origin = demo ? "demo" : Connection.normalizeOrigin(url)
    if (!origin) {
      root.phase = "error"
      root.lastError = "Enter a valid http(s) or ws(s) Home Assistant URL."
      return false
    }
    if (!demo && !token && root.requiresTokenFor(url)) {
      root.phase = "error"
      root.lastError = "A new Home Assistant origin requires a new token."
      return false
    }
    root.connectionSuppressed = false
    // Start the serialized write before applyConfig runs so reconciliation
    // cannot race a lookup of the previous credential.
    if (!demo && token.length > 0 && !credentials.store(token, origin)) {
      root.phase = "error"
      root.lastError = "Could not start token storage while the keyring is busy."
      return false
    }
    root.saveConfig({ baseUrl: url, demoMode: demo })
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
      return
    }
    root.appliedConfigText = text
    var parsed = ConfigStore.parse(text, Model.DEMO_DEFAULT_FAVORITES)
    var config = parsed.config
    if (parsed.error) root.lastError = parsed.error

    root.demoMode = config.demoMode
    root.baseUrl = config.baseUrl
    root.liveFavorites = config.favorites
    root.demoFavorites = config.demoFavorites
    root.displayNameOverrides = config.displayNameOverrides
    root.iconOverrides = config.iconOverrides
    root.groupByArea = config.groupByArea
    root.showEntityIcons = config.showEntityIcons
    root.activeTab = config.selectedTab

    root.configured = root.demoMode || root.baseUrl.length > 0
    rebuildSortedIds()
    rebuildRows()
    root.reconcileConnection()
  }

  // Which connection the bridge is running for. Config is saved on every
  // favorite toggle, and those must not drop the WebSocket.
  property string appliedConnection: ""

  function forgetDevices() {
    root.states = ({})
    root.stateRevision++
    root.sortedEntityIds = []
    root.areaNames = ({})
    root.entityArea = ({})
    root.temperatureUnit = ""
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
        // Clearing the config is not enough: the bridge holds an authenticated
        // socket open with the old token until it is told otherwise, and keeps
        // feeding this service devices the user just removed.
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
      root.lastError = "Home Assistant URL is invalid."
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
    // A token being written pushes itself; reading here would race it.
    if (credentials.writePending) return
    var origin = root.currentOrigin()
    if (!origin) return
    // lookup() refuses while any other keyring process is in flight, and says
    // so only through its return value. Dropping that on the floor leaves the
    // panel stuck on "connecting" with nothing queued to push a token — the
    // window is short (every keyring op has a 5s start timeout) but it is
    // reached whenever the bridge restarts during a legacy-token check.
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
    executable: root.pluginDir + "/bin/hass-bridge"
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

  function pushConfig(token) {
    root.send({
      op: "config",
      url: root.baseUrl,
      token: token,
      generation: root.connectionGeneration
    })
  }

  function callService(domain, service, entityId, data, tag) {
    return root.send({
      op: "call_service",
      domain: domain,
      service: service,
      entity_id: entityId,
      data: data || {},
      tag: tag || ""
    })
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

  // Must outlast the bridge's own REQUEST_TIMEOUT (5s), or a slow-but-successful
  // call reports "no response" here while the bridge is still waiting for the
  // answer it goes on to receive.
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
      root.lastError = "No response from Home Assistant."
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
    var sent = root.callService(
      call.domain, call.service, entityId, {}, "toggle:" + entityId)
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
  // by the bridge, which is how a rejected scene or a refused cover used to
  // look exactly like a button that does nothing.
  property int callSequence: 0

  function callTag(entityId) {
    root.callSequence++
    return Model.callTag(entityId, root.callSequence)
  }

  signal commandFailed(string tag)

  // Returns the tag to match a later failure against, or "" if nothing went out.
  function callTagged(domain, service, entityId, data) {
    var tag = root.callTag(entityId)
    return root.callService(domain, service, entityId, data, tag) ? tag : ""
  }

  function setBrightness(entityId, percent) {
    if (!root.capabilities(entityId).brightness) {
      return root.rejectAction("This light does not support brightness control.")
    }
    if (percent <= 0) {
      return root.callTagged("light", "turn_off", entityId, {})
    }
    return root.callTagged("light", "turn_on", entityId,
                           { brightness_pct: Math.round(percent) })
  }

  function setLightColor(entityId, hue, saturation) {
    if (!root.capabilities(entityId).color) {
      return root.rejectAction("This light does not support colour control.")
    }
    var data = Model.lightColorData(hue, saturation)
    if (!data) return root.rejectAction("Invalid colour value.")
    return root.callTagged("light", "turn_on", entityId, data)
  }

  function setLightColorTemp(entityId, kelvin) {
    if (!root.capabilities(entityId).colorTemp) {
      return root.rejectAction("This light does not support colour temperature.")
    }
    var data = Model.lightColorTempData(root.states[entityId], kelvin)
    if (!data) return root.rejectAction("Invalid colour temperature.")
    return root.callTagged("light", "turn_on", entityId, data)
  }

  function setVolume(entityId, level) {
    if (!root.capabilities(entityId).mediaVolume) {
      return root.rejectAction("This media player does not support volume control.")
    }
    var clamped = Math.max(0, Math.min(1, level))
    return root.callTagged("media_player", "volume_set", entityId,
                           { volume_level: clamped })
  }

  function mediaPlayPause(entityId) {
    if (!root.capabilities(entityId).mediaPlayPause) {
      return root.rejectAction("This media player does not support play/pause.")
    }
    return root.callTagged("media_player", "media_play_pause", entityId, {})
  }

  function mediaNext(entityId) {
    if (!root.capabilities(entityId).mediaNext) {
      return root.rejectAction("This media player does not support next track.")
    }
    return root.callTagged("media_player", "media_next_track", entityId, {})
  }

  function mediaPrevious(entityId) {
    if (!root.capabilities(entityId).mediaPrevious) {
      return root.rejectAction("This media player does not support previous track.")
    }
    return root.callTagged("media_player", "media_previous_track", entityId, {})
  }

  function coverAction(entityId, service) {
    var caps = root.capabilities(entityId)
    var supported = service === "open_cover" ? caps.coverOpen
      : service === "stop_cover" ? caps.coverStop
      : service === "close_cover" ? caps.coverClose
      : false
    if (!supported) return root.rejectAction("This cover does not support that action.")
    return root.callTagged("cover", service, entityId, {})
  }

  function setLock(entityId, locked) {
    if (!root.capabilities(entityId).lock) {
      return root.rejectAction("This entity does not support lock control.")
    }
    root.setPendingToggle(entityId, locked)
    // toggleEntity's tag prefix, so rollback runs through one path.
    var sent = root.callService("lock", locked ? "lock" : "unlock", entityId, {},
                                "toggle:" + entityId)
    if (!sent) {
      root.clearPendingToggle(entityId)
      root.refreshRow(entityId)
    }
    return sent
  }

  // The primary action for a row, whatever that means for its domain. IPC and
  // the panel's Enter key both land here, so `hass toggleEntity lock.front`
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
      return root.rejectAction("Only scenes and scripts can be activated.")
    }
    var domain = Model.domainOf(entityId)
    // A tag, not a bool: IPC and the row both read this for truth alone, and
    // an unsent call still comes back falsy.
    return root.callTagged(domain, "turn_on", entityId, {})
  }

  function setClimateHvacMode(entityId, mode) {
    var data = Model.climateHvacModeData(root.states[entityId], mode)
    if (Object.keys(data).length === 0) {
      return root.rejectAction("This climate entity does not report a controllable HVAC mode.")
    }
    return root.callTagged("climate", "set_hvac_mode", entityId, data)
  }

  function setClimateTemperature(entityId, target, low, high) {
    var entity = root.states[entityId]
    var data = Model.climateTemperatureData(
      entity, target, low, high, root.temperatureUnit)
    if (Object.keys(data).length === 0) {
      return root.rejectAction("This climate entity does not report a controllable target.")
    }
    return root.callTagged("climate", "set_temperature", entityId, data)
  }

  function setClimateFanMode(entityId, mode) {
    var data = Model.climateFanModeData(root.states[entityId], mode)
    if (Object.keys(data).length === 0) {
      return root.rejectAction("This climate entity does not report a controllable fan mode.")
    }
    return root.callTagged("climate", "set_fan_mode", entityId, data)
  }

  function setClimatePresetMode(entityId, mode) {
    var data = Model.climatePresetModeData(root.states[entityId], mode)
    if (Object.keys(data).length === 0) {
      return root.rejectAction("This climate entity does not report a controllable preset.")
    }
    return root.callTagged("climate", "set_preset_mode", entityId, data)
  }

  function setClimateSwingMode(entityId, mode) {
    var data = Model.climateSwingModeData(root.states[entityId], mode)
    if (Object.keys(data).length === 0) {
      return root.rejectAction("This climate entity does not report a controllable swing mode.")
    }
    return root.callTagged("climate", "set_swing_mode", entityId, data)
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
      root.rebuildRows()
      break
    case "registries":
      root.applyRegistries(event)
      break
    case "config":
      root.temperatureUnit = String(event.unit_temperature || "")
      root.rebuildRows()
      break
    case "result":
      root.handleResult(event)
      break
    case "log":
      if (event.level === "warn") console.warn("hass-bridge: " + event.msg)
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
    } else if (Model.isCallTag(tag)) {
      root.commandFailed(tag)
    }
    root.lastError = event.error || "Command failed."
    root.lastErrorKind = event.errorKind || "command"
  }

  function applyStates(entities) {
    root.states = EntityStore.indexStates(entities)
    root.stateRevision++
    root.rebuildSortedIds()
    root.rebuildRows()
  }

  function applyStateChanged(entity) {
    if (!entity || !entity.entity_id) return
    // The browser walks the sorted index, not `states`, so an entity that
    // appears after the snapshot — a new device, a restarted integration —
    // stays unfindable in settings until the index is rebuilt.
    var isNew = root.states[entity.entity_id] === undefined
    root.states = EntityStore.upsertState(root.states, entity)
    root.stateRevision++
    root.clearPendingToggle(entity.entity_id)
    if (isNew) {
      root.rebuildSortedIds()
      root.rebuildRows()
    } else {
      root.refreshRow(entity.entity_id)
    }
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

  function applyRegistries(event) {
    var projection = EntityStore.projectRegistries(
      event.areas, event.entities, event.devices)
    root.areaNames = projection.areaNames
    root.entityArea = projection.entityArea
    root.savedFavoriteColors = projection.favoriteColors
    root.rebuildRows()
  }

  // entity_id -> the light's saved favourite colours, straight from the
  // registry. Absent for a light the user has never customized, which is when
  // Model falls back to the defaults the Home Assistant app computes.
  property var savedFavoriteColors: ({})

  // ------------------------------------------------------------ rows

  // Attributes the row model does not carry, for the expanded controls.
  function entityFor(entityId) {
    return root.states[entityId]
  }

  // Display order, rebuilt only when the *set* of entities changes: sorting
  // per keystroke is what made the settings search lag.
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
      if (!Model.searchMatches(query, entity)) continue
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
    return entity ? Model.name(entity) : entityId
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
  // Area tabs appear only once the registries arrive; overwriting the intent
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

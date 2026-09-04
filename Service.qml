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
  // Optional alternate address for the same instance — a LAN address, say —
  // the bridge tries first, but only on trustedNetwork. Shares baseUrl's
  // credential; never its own keyring origin. See Connection.signature and
  // CredentialManager.
  property string localUrl: ""
  // The Wi-Fi network name localUrl requires a match against before the
  // bridge will ever try it. See bin/hass-bridge's current_wifi_ssid.
  property string trustedNetwork: ""
  // True only while connected through localUrl rather than baseUrl.
  property bool usingLocal: false
  property int connectionGeneration: 0
  property bool connectionSuppressed: false

  readonly property bool connected: phase === "connected"

  // entity_id -> raw entity. Updates replace the map; stateRevision also
  // invalidates bindings that read nested attributes.
  property var states: ({})
  property int stateRevision: 0

  property var areaNames: Object.create(null)
  property var entityArea: Object.create(null)
  property var entityDevice: Object.create(null)
  property var deviceNames: Object.create(null)
  property var deviceInfo: Object.create(null)
  property var deviceArea: Object.create(null)
  property var deviceEntities: Object.create(null)
  property var entityRegistry: Object.create(null)

  // Disjoint namespaces: one shared list would show ghosts after a mode switch.
  property var liveFavorites: []
  property var demoFavorites: []
  readonly property var favorites: root.demoMode ? root.demoFavorites : root.liveFavorites
  property var liveRoomReadings: []
  property var demoRoomReadings: []
  readonly property var roomReadings: root.demoMode
    ? root.demoRoomReadings : root.liveRoomReadings
  property var livePinnedRoomReadings: []
  property var demoPinnedRoomReadings: []
  readonly property var pinnedRoomReadings: root.demoMode
    ? root.demoPinnedRoomReadings : root.livePinnedRoomReadings
  property var livePinnedEntities: []
  property var demoPinnedEntities: []
  readonly property var pinnedEntities: root.demoMode
    ? root.demoPinnedEntities : root.livePinnedEntities
  property var livePanelOrder: []
  property var demoPanelOrder: []
  readonly property var panelOrder: root.demoMode
    ? root.demoPanelOrder : root.livePanelOrder

  property var displayNameOverrides: ({})
  property var iconOverrides: ({})
  property bool groupByArea: false
  property bool showEntityIcons: true
  property bool showPanelPinOnHover: false

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

  // Last requested recorder window per sensor. historyRevision invalidates
  // bindings that walk the nested points array.
  property var historyByEntity: ({})
  property var pendingHistoryTags: ({})
  property int historyRevision: 0

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
      localUrl: root.localUrl,
      trustedNetwork: root.trustedNetwork,
      demoMode: root.demoMode,
      favorites: root.liveFavorites.slice(),
      demoFavorites: root.demoFavorites.slice(),
      roomReadings: root.liveRoomReadings.slice(),
      demoRoomReadings: root.demoRoomReadings.slice(),
      pinnedRoomReadings: root.livePinnedRoomReadings.slice(),
      demoPinnedRoomReadings: root.demoPinnedRoomReadings.slice(),
      pinnedEntities: root.livePinnedEntities.slice(),
      demoPinnedEntities: root.demoPinnedEntities.slice(),
      panelOrder: root.livePanelOrder.slice(),
      demoPanelOrder: root.demoPanelOrder.slice(),
      groupByArea: root.groupByArea,
      showEntityIcons: root.showEntityIcons,
      showPanelPinOnHover: root.showPanelPinOnHover,
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

  function setShowPanelPinOnHover(enabled) {
    if (root.showPanelPinOnHover === enabled) return
    root.saveConfig({ showPanelPinOnHover: enabled })
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
    var order = root.panelOrder.slice()
    var pinned = root.pinnedEntities.slice()
    var index = favorites.indexOf(entityId)
    if (index === -1) {
      favorites.push(entityId)
      if (order.indexOf(entityId) === -1) order.push(entityId)
    } else {
      favorites.splice(index, 1)
      var pinnedIndex = pinned.indexOf(entityId)
      if (pinnedIndex !== -1) pinned.splice(pinnedIndex, 1)
      var orderIndex = order.indexOf(entityId)
      if (orderIndex !== -1) order.splice(orderIndex, 1)
    }
    root.savePanelSelection(favorites, root.roomReadings.slice(), order,
                            undefined, pinned)
  }

  function movePanelItem(itemId, delta) {
    var order = root.panelOrder.slice()
    var index = order.indexOf(itemId)
    if (index === -1) return
    var target = index + delta
    if (target < 0 || target >= order.length) return
    order.splice(target, 0, order.splice(index, 1)[0])
    root.savePanelOrder(order)
  }

  function savePanelOrder(order) {
    root.saveConfig(root.demoMode
      ? { demoPanelOrder: order } : { panelOrder: order })
  }

  function savePanelSelection(favorites, roomReadings, order, pinnedRooms,
                              pinnedEntityIds) {
    var pins = pinnedRooms === undefined
      ? root.pinnedRoomReadings.slice() : pinnedRooms
    var entityPins = pinnedEntityIds === undefined
      ? root.pinnedEntities.slice() : pinnedEntityIds
    root.saveConfig(root.demoMode ? {
      demoFavorites: favorites,
      demoRoomReadings: roomReadings,
      demoPinnedRoomReadings: pins,
      demoPinnedEntities: entityPins,
      demoPanelOrder: order
    } : {
      favorites: favorites,
      roomReadings: roomReadings,
      pinnedRoomReadings: pins,
      pinnedEntities: entityPins,
      panelOrder: order
    })
  }

  function isFavorite(entityId) {
    return root.favorites.indexOf(entityId) !== -1
  }

  function toggleRoomReading(deviceId) {
    var selected = root.roomReadings.slice()
    var order = root.panelOrder.slice()
    var itemId = "room_reading:" + deviceId
    var index = selected.indexOf(deviceId)
    var pinned = root.pinnedRoomReadings.slice()
    if (index === -1) {
      selected.push(deviceId)
      if (order.indexOf(itemId) === -1) order.push(itemId)
    } else {
      selected.splice(index, 1)
      var pinnedIndex = pinned.indexOf(deviceId)
      if (pinnedIndex !== -1) pinned.splice(pinnedIndex, 1)
      var orderIndex = order.indexOf(itemId)
      if (orderIndex !== -1) order.splice(orderIndex, 1)
    }
    root.savePanelSelection(root.favorites.slice(), selected, order, pinned)
  }

  function isRoomReading(deviceId) {
    return root.roomReadings.indexOf(deviceId) !== -1
  }

  function isRoomReadingPinned(deviceId) {
    return root.pinnedRoomReadings.indexOf(deviceId) !== -1
  }

  function toggleRoomReadingPinned(deviceId) {
    if (!root.isRoomReading(deviceId)) return
    var pinned = root.pinnedRoomReadings.slice()
    var index = pinned.indexOf(deviceId)
    if (index === -1) pinned.push(deviceId)
    else pinned.splice(index, 1)
    root.savePanelSelection(root.favorites.slice(), root.roomReadings.slice(),
                            root.panelOrder.slice(), pinned)
  }

  function isEntityPinned(entityId) {
    return root.pinnedEntities.indexOf(entityId) !== -1
  }

  function toggleEntityPinned(entityId) {
    if (!root.isFavorite(entityId)) return
    var pinned = root.pinnedEntities.slice()
    var index = pinned.indexOf(entityId)
    if (index === -1) pinned.push(entityId)
    else pinned.splice(index, 1)
    root.savePanelSelection(root.favorites.slice(), root.roomReadings.slice(),
                            root.panelOrder.slice(), undefined, pinned)
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
      baseUrl: "", localUrl: "", trustedNetwork: "", demoMode: false,
      favorites: [], roomReadings: [], pinnedRoomReadings: [],
      pinnedEntities: [], panelOrder: [],
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

  function applyConnection(url, localUrl, trustedNetwork, token, demo) {
    var origin = demo ? "demo" : Connection.normalizeOrigin(url)
    if (!origin) {
      root.phase = "error"
      root.lastError = "Enter a valid http(s) or ws(s) Home Assistant URL."
      return false
    }
    // Optional, and validated the same way, but blank is always fine — it
    // just means no local fallback.
    var trimmedLocal = String(localUrl || "").trim()
    if (!demo && trimmedLocal && !Connection.normalizeOrigin(trimmedLocal)) {
      root.phase = "error"
      root.lastError = "Enter a valid http(s) or ws(s) local network URL, or leave it blank."
      return false
    }
    // A local URL with no trusted network to gate it would otherwise be tried
    // on every Wi-Fi the laptop ever joins, sending the token to whatever
    // happens to answer at that address. The bridge enforces this too — this
    // check exists to fail fast with a clear message instead of a silently
    // inert field.
    var trimmedTrust = String(trustedNetwork || "").trim()
    if (!demo && trimmedLocal && Connection.trustedNetworkList(trimmedTrust).length === 0) {
      root.phase = "error"
      root.lastError = "Enter at least one trusted Wi-Fi network name for the local URL, or leave the local URL blank."
      return false
    }
    if (!demo && !token && root.requiresTokenFor(url)) {
      root.phase = "error"
      root.lastError = "A new Home Assistant origin requires a new token."
      return false
    }
    root.connectionSuppressed = false
    // Start the serialized write before applyConfig runs so reconciliation
    // cannot race a lookup of the previous credential. The local URL is never
    // its own keyring origin: it shares whatever is stored for `origin`.
    if (!demo && token.length > 0 && !credentials.store(token, origin)) {
      root.phase = "error"
      root.lastError = "Could not start token storage while the keyring is busy."
      return false
    }
    root.saveConfig({
      baseUrl: url, localUrl: demo ? "" : trimmedLocal,
      trustedNetwork: demo ? "" : trimmedTrust, demoMode: demo
    })
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
    root.localUrl = config.localUrl
    root.trustedNetwork = config.trustedNetwork
    root.liveFavorites = config.favorites
    root.demoFavorites = config.demoFavorites
    root.liveRoomReadings = config.roomReadings
    root.demoRoomReadings = config.demoRoomReadings
    root.livePinnedRoomReadings = config.pinnedRoomReadings
    root.demoPinnedRoomReadings = config.demoPinnedRoomReadings
    root.livePinnedEntities = config.pinnedEntities
    root.demoPinnedEntities = config.demoPinnedEntities
    root.livePanelOrder = config.panelOrder
    root.demoPanelOrder = config.demoPanelOrder
    root.displayNameOverrides = config.displayNameOverrides
    root.iconOverrides = config.iconOverrides
    root.groupByArea = config.groupByArea
    root.showEntityIcons = config.showEntityIcons
    root.showPanelPinOnHover = config.showPanelPinOnHover
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
    root.areaNames = Object.create(null)
    root.entityArea = Object.create(null)
    root.entityDevice = Object.create(null)
    root.deviceNames = Object.create(null)
    root.deviceInfo = Object.create(null)
    root.deviceArea = Object.create(null)
    root.deviceEntities = Object.create(null)
    root.entityRegistry = Object.create(null)
    root.temperatureUnit = ""
    root.pendingToggles = ({})
    root.pendingToggleRevision++
    pendingSweep.running = false
    root.clearHistory()
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
    var signature = Connection.signature(
      root.demoMode, root.baseUrl, root.localUrl, root.trustedNetwork)
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
      localUrl: root.localUrl,
      trustedNetwork: root.trustedNetwork,
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

  function historyFor(entityId) {
    root.historyRevision
    return root.historyByEntity[entityId] || null
  }

  function clearHistory(entityId) {
    if (entityId) {
      if (root.historyByEntity[entityId] === undefined
          && root.pendingHistoryTags[entityId] === undefined) return
      delete root.historyByEntity[entityId]
      delete root.pendingHistoryTags[entityId]
    } else {
      root.historyByEntity = ({})
      root.pendingHistoryTags = ({})
    }
    root.historyRevision++
  }

  function sanitizeHistoryPoints(raw) {
    if (!raw || !raw.length) return []
    var out = []
    for (var i = 0; i < raw.length; i++) {
      var point = raw[i]
      if (!point) continue
      if (typeof point.t !== "number" || !isFinite(point.t)) continue
      if (point.v !== null
          && (typeof point.v !== "number" || !isFinite(point.v))) continue
      out.push({ t: point.t, v: point.v })
    }
    return out
  }

  function requestHistory(entityId, hours) {
    var windowHours = Model.normalizeHistoryHours(hours)
    if (!windowHours) return root.rejectAction("Invalid history window.")
    if (!root.capabilities(entityId).historyGraph) {
      return root.rejectAction("This sensor does not have a history graph.")
    }
    var tag = root.callTag(entityId)
    root.pendingHistoryTags[entityId] = tag
    var current = root.historyByEntity[entityId] || {}
    var keepPoints = current.hours === windowHours ? (current.points || []) : []
    root.historyByEntity[entityId] = {
      entityId: entityId,
      hours: windowHours,
      points: keepPoints,
      loading: true,
      error: ""
    }
    root.historyRevision++
    var sent = root.send({
      op: "history",
      entity_id: entityId,
      hours: windowHours,
      tag: tag
    })
    if (!sent) {
      delete root.pendingHistoryTags[entityId]
      root.historyByEntity[entityId] = {
        entityId: entityId,
        hours: windowHours,
        points: [],
        loading: false,
        error: "Not connected to Home Assistant."
      }
      root.historyRevision++
      return false
    }
    return true
  }

  function handleHistory(event) {
    var entityId = String(event.entity_id || "")
    if (!EntityStore.validEntityId(entityId)) return
    var tag = String(event.tag || "")
    var pendingTag = root.pendingHistoryTags[entityId] || ""
    if (pendingTag && tag && tag !== pendingTag) return
    delete root.pendingHistoryTags[entityId]
    var hours = Model.normalizeHistoryHours(event.hours)
    var current = root.historyByEntity[entityId]
    if (current && hours && current.hours && hours !== current.hours) return
    var windowHours = hours || (current && current.hours) || 1
    var points = root.sanitizeHistoryPoints(event.points)
    var axisEnd = Number(event.end_time)
    if (!isFinite(axisEnd)) axisEnd = Model.historyAxisEnd(
      points, windowHours, Date.now() / 1000)
    root.historyByEntity[entityId] = {
      entityId: entityId,
      hours: windowHours,
      points: Model.clampHistoryPoints(
        points,
        windowHours, axisEnd, Model.HISTORY_MAX_POINTS),
      axisEnd: axisEnd,
      loading: false,
      error: ""
    }
    root.historyRevision++
  }

  function appendHistoryPoint(entity) {
    if (!entity || !EntityStore.validEntityId(entity.entity_id)) return
    var entityId = entity.entity_id
    var entry = root.historyByEntity[entityId]
    if (!entry || entry.loading) return
    var value = Model.parseNumericState(entity.state)
    var hours = entry.hours || 1
    var stamp = Date.parse(String(entity.last_updated || entity.last_changed || ""))
    var now = isFinite(stamp) ? stamp / 1000 : entry.axisEnd || Date.now() / 1000
    var existing = entry.points || []
    var points = existing.slice()
    points.push({ t: now, v: value })
    root.historyByEntity[entityId] = {
      entityId: entityId,
      hours: hours,
      points: Model.clampHistoryPoints(
        points, hours, now, Model.HISTORY_MAX_POINTS),
      axisEnd: now,
      loading: false,
      error: entry.error || ""
    }
    root.historyRevision++
  }

  // ------------------------------------------------------------ actions

  // entity_id -> { desired, deadline }. The row flips at once and waits for
  // state_changed to confirm.
  property var pendingToggles: ({})
  // pendingToggles is mutated in place, so bindings need a scalar revision to
  // observe optimistic checked/busy changes immediately.
  property int pendingToggleRevision: 0

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
    root.pendingToggleRevision++
    root.refreshRow(entityId)
    root.refreshRoomReadingForEntity(entityId)
    pendingSweep.running = true
  }

  function clearPendingToggle(entityId) {
    if (root.pendingToggles[entityId] === undefined) return
    delete root.pendingToggles[entityId]
    root.pendingToggleRevision++
    root.refreshRoomReadingForEntity(entityId)
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
      root.refreshRoomReadingForEntity(expired[i])
      root.lastError = "No response from Home Assistant."
    }
    if (expired.length) root.pendingToggleRevision++
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
  signal historyReady(string tag, var histories, string error,
                      real startMs, real endMs)
  property int historySequence: 0

  function requestHistoryBatch(entityIds, hours) {
    if (!Array.isArray(entityIds) || entityIds.length === 0) return ""
    var unique = []
    for (var i = 0; i < entityIds.length && unique.length < 8; i++) {
      var entityId = String(entityIds[i] || "")
      if (!entityId || !root.states[entityId] || unique.indexOf(entityId) !== -1) continue
      unique.push(entityId)
    }
    if (!unique.length) return ""
    var span = Model.normalizeHistoryHours(hours)
    if (!span) return ""
    root.historySequence++
    var tag = "history:" + root.connectionGeneration + ":" + root.historySequence
    return root.send({
      op: "history",
      tag: tag,
      entity_ids: unique,
      hours: span
    }) ? tag : ""
  }

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

  function setCoverPosition(entityId, percent) {
    if (!root.capabilities(entityId).coverPosition) {
      return root.rejectAction("This cover does not support position control.")
    }
    if (typeof percent !== "number" || !isFinite(percent)) {
      return root.rejectAction("Invalid cover position.")
    }
    var clamped = Math.max(0, Math.min(100, Math.round(percent)))
    return root.callTagged("cover", "set_cover_position", entityId,
                           { position: clamped })
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
      root.usingLocal = transition.state.phase === "connected" && event.usingLocal === true
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
    case "history":
      if (event.histories !== undefined)
        root.historyReady(String(event.tag || ""), event.histories || {},
                          String(event.error || ""),
                          Number(event.start_ms || 0), Number(event.end_ms || 0))
      else
        root.handleHistory(event)
      break
    case "log":
      if (event.level === "warn") console.warn("hass-bridge: " + event.msg)
      break
    }
  }

  function handleResult(event) {
    var tag = String(event.tag || "")
    var historyEntityId = ""
    for (var entityId in root.pendingHistoryTags) {
      if (root.pendingHistoryTags[entityId] === tag) {
        historyEntityId = entityId
        break
      }
    }
    if (historyEntityId) {
      delete root.pendingHistoryTags[historyEntityId]
      if (event.ok !== true) {
        var current = root.historyByEntity[historyEntityId] || {}
        root.historyByEntity[historyEntityId] = {
          entityId: historyEntityId,
          hours: current.hours || 1,
          points: current.points || [],
          loading: false,
          error: event.error || "History request failed."
        }
        root.historyRevision++
      }
    }

    if (event.ok === true) return

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
    root.appendHistoryPoint(entity)
    if (isNew) {
      root.rebuildSortedIds()
      root.rebuildRows()
    } else {
      root.refreshRow(entity.entity_id)
      root.refreshRoomReadingForEntity(entity.entity_id)
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

  function refreshRoomReadingForEntity(entityId) {
    for (var i = 0; i < root.roomReadings.length; i++) {
      var deviceId = root.roomReadings[i]
      if ((root.deviceEntities[deviceId] || []).indexOf(entityId) !== -1) {
        root.refreshRow("room_reading:" + deviceId)
      }
    }
  }

  function applyRegistries(event) {
    var projection = EntityStore.projectRegistries(
      event.areas, event.entities, event.devices)
    root.areaNames = projection.areaNames
    root.entityArea = projection.entityArea
    root.entityDevice = projection.entityDevice
    root.savedFavoriteColors = projection.favoriteColors
    root.deviceNames = projection.deviceNames
    root.deviceInfo = projection.deviceInfo
    root.deviceArea = projection.deviceArea
    root.deviceEntities = projection.deviceEntities
    root.entityRegistry = projection.entityRegistry
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
    if (filterId === "room_readings") return root.browseRoomReadings(query)
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
        favorite: root.isFavorite(entityId),
        roomReading: false,
        pinnable: Model.isExpandable(entity),
        pinned: root.isEntityPinned(entityId)
      })
    }
    return out
  }

  function liveEntitiesForDevice(deviceId) {
    var registered = root.deviceEntities[deviceId] || []
    var out = []
    for (var i = 0; i < registered.length; i++) {
      if (root.states[registered[i]] !== undefined) out.push(registered[i])
    }
    return out
  }

  function environmentalReadingsForDevice(deviceId) {
    var entityIds = root.liveEntitiesForDevice(deviceId)
    var readings = []
    for (var i = 0; i < entityIds.length; i++) {
      var reading = Model.environmentalReading(
        root.states[entityIds[i]], root.deviceInfo[deviceId])
      if (reading) readings.push(reading)
    }
    readings = Model.distinguishEnvironmentalReadings(readings)
    readings.sort(function(a, b) {
      return a.order === b.order ? a.label.localeCompare(b.label) : a.order - b.order
    })
    return readings
  }

  function barDataReadingsForEntity(entityId) {
    var deviceId = root.entityDevice[entityId]
    return Model.barDataReadings(root.states[entityId], root.temperatureUnit,
                                 deviceId ? root.deviceInfo[deviceId] : null)
  }

  function deviceDisplayName(deviceId, entityIds) {
    var saved = String(root.deviceNames[deviceId] || "").trim()
    return saved || (entityIds.length ? root.displayName(entityIds[0]) : deviceId)
  }

  function primaryControlForDevice(deviceId) {
    var entityIds = root.liveEntitiesForDevice(deviceId)
    var deviceName = root.deviceDisplayName(deviceId, entityIds)
    var candidates = []
    for (var i = 0; i < entityIds.length; i++) {
      var entityId = entityIds[i]
      if (Model.isSafePrimaryControl(
          root.states[entityId], deviceName, root.entityRegistry[entityId])) {
        candidates.push(entityId)
      }
    }
    return candidates.length === 1 ? candidates[0] : ""
  }

  function roomReadingCard(deviceId) {
    var entityIds = root.liveEntitiesForDevice(deviceId)
    var readings = root.environmentalReadingsForDevice(deviceId)
    var controlEntityId = root.primaryControlForDevice(deviceId)
    var iconEntityId = readings.length ? readings[0].entityId : ""
    var iconEntity = iconEntityId ? root.states[iconEntityId] : null
    var areaId = root.deviceArea[deviceId]
      || (entityIds.length ? root.entityArea[entityIds[0]] : "") || ""
    return {
      deviceId: deviceId,
      name: root.deviceDisplayName(deviceId, entityIds),
      // The registry's first entity is often a battery sensor. The first
      // sorted environmental reading represents the card itself much better.
      icon: iconEntity ? root.iconFor(iconEntityId, iconEntity)
        : (entityIds.length ? root.iconFor(entityIds[0], root.states[entityIds[0]])
           : Model.FALLBACK_ICON),
      areaId: areaId,
      areaName: areaId ? root.areaNames[areaId] || "" : "",
      readings: readings,
      summary: Model.roomReadingSummary(readings, 3),
      controlEntityId: controlEntityId,
      controlOn: controlEntityId ? root.displayIsOn(controlEntityId) : false,
      controlPending: !!(controlEntityId
        && root.pendingToggles[controlEntityId] !== undefined),
      available: readings.length > 0
    }
  }

  function roomReadingMatches(query, card) {
    var needle = String(query || "").trim().toLowerCase()
    if (!needle || card.name.toLowerCase().indexOf(needle) !== -1) return true
    for (var i = 0; i < card.readings.length; i++) {
      if (card.readings[i].label.toLowerCase().indexOf(needle) !== -1) return true
    }
    return false
  }

  function browseRoomReadings(query) {
    var out = []
    for (var deviceId in root.deviceEntities) {
      var card = root.roomReadingCard(deviceId)
      if (card.readings.length < 2 || !root.roomReadingMatches(query, card)) continue
      out.push({
        entityId: deviceId,
        name: card.name,
        icon: card.icon,
        detail: card.readings.length + " readings"
          + (card.controlEntityId ? " · on/off" : ""),
        favorite: root.isRoomReading(deviceId),
        roomReading: true,
        pinnable: true,
        pinned: root.isRoomReadingPinned(deviceId)
      })
    }
    out.sort(function(a, b) {
      return a.name.toLowerCase().localeCompare(b.name.toLowerCase())
    })
    return out
  }

  function favoriteSummaries() {
    return root.panelOrder.map(function(itemId) {
      if (itemId.indexOf("room_reading:") === 0) {
        var deviceId = itemId.slice("room_reading:".length)
        var card = root.roomReadingCard(deviceId)
        return {
          entityId: deviceId,
          panelItemId: itemId,
          name: card.name,
          icon: card.icon,
          state: card.readings.length + " readings",
          available: card.available,
          roomReading: true,
          pinnable: true,
          pinned: root.isRoomReadingPinned(deviceId)
        }
      }
      var entity = root.states[itemId]
      return {
        entityId: itemId,
        panelItemId: itemId,
        name: root.displayName(itemId),
        icon: root.iconFor(itemId, entity),
        state: entity ? Model.displayState(entity) : "Unavailable",
        available: entity !== undefined,
        roomReading: false,
        pinnable: entity !== undefined && Model.isExpandable(entity),
        pinned: root.isEntityPinned(itemId)
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

  function activityEntities() {
    root.stateRevision
    var cards = []
    for (var roomIndex = 0; roomIndex < root.roomReadings.length; roomIndex++) {
      cards.push(root.roomReadingCard(root.roomReadings[roomIndex]))
    }
    return Model.panelActivityEntities(root.favorites, cards, root.states)
  }

  readonly property string activitySummary: Model.activitySummary(
    root.activityEntities())

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
    if (entityId.indexOf("room_reading:") === 0) {
      var deviceId = entityId.slice("room_reading:".length)
      var card = root.roomReadingCard(deviceId)
      return {
        entityId: entityId,
        name: card.name,
        subtitle: card.areaName,
        badge: "",
        icon: card.icon,
        domain: "",
        isOn: card.controlOn,
        pending: card.controlPending,
        control: card.controlEntityId ? "toggle" : "none",
        expandable: true,
        reserveExpandSlot: true,
        available: card.available,
        areaId: card.areaId,
        areaName: card.areaName,
        rowKind: "room_reading",
        roomDeviceId: deviceId,
        controlEntityId: card.controlEntityId
      }
    }
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
    var selected = root.panelOrder.slice()
    var mapping = {}
    for (var entityId in root.entityArea) mapping[entityId] = root.entityArea[entityId]
    for (var i = 0; i < root.roomReadings.length; i++) {
      var card = root.roomReadingCard(root.roomReadings[i])
      if (card.areaId) mapping["room_reading:" + root.roomReadings[i]] = card.areaId
    }
    return EntityStore.computeTabs(
      selected, root.groupByArea, root.areaNames, mapping)
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

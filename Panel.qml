import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Bar button plus popup panel. Owns the keyboard cursor and the tab selection;
// the service owns the devices and the connection.
Panel {
  id: root
  moduleName: "loxone"
  ipcTarget: "loxone"
  // We own the target's single IpcHandler, so the methods below can sit
  // alongside the base open/close/toggle.
  manageIpc: false

  readonly property var loxone: bar && bar.shell ? bar.shell.serviceFor("loxone") : null
  readonly property bool serviceReady: loxone !== null
  readonly property string phase: serviceReady ? loxone.phase : "idle"

  property string expandedEntityId: ""

  // One cursor for keyboard and mouse, per the CursorSurface contract.
  // Dormant until a key is pressed.
  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property int rowCount: serviceReady ? loxone.rows.count : 0
  readonly property bool hasDevices: serviceReady && loxone.hasDevices
  readonly property var tabs: serviceReady ? loxone.tabs : []

  onOpenedChanged: {
    // A camera stream costs the camera something to serve for as long as
    // it's being pulled — only worth it while this popover (or Settings'
    // Camera tab) is actually showing it.
    if (serviceReady) {
      if (opened) loxone.registerCameraViewer()
      else loxone.unregisterCameraViewer()
    }
    if (!opened) {
      expandedEntityId = ""
      cursorActive = false
      cursorIndex = 0
    }
  }

  function moveCursor(delta) {
    if (rowCount === 0) return
    cursorIndex = Math.max(0, Math.min(rowCount - 1, cursorIndex + delta))
  }

  function switchTab(delta) {
    if (!serviceReady || tabs.length < 2) return
    var current = 0
    for (var i = 0; i < tabs.length; i++) {
      if (tabs[i].id === loxone.effectiveTab) { current = i; break }
    }
    var next = (current + delta + tabs.length) % tabs.length
    loxone.setActiveTab(tabs[next].id)
    cursorIndex = 0
    expandedEntityId = ""
  }

  function currentRow() {
    var items = entityRepeater.count
    if (cursorIndex < 0 || cursorIndex >= items) return null
    return entityRepeater.itemAt(cursorIndex)
  }

  function activateCursor() {
    var item = currentRow()
    if (item) item.activate()
  }

  // Already connected, so the useful landing spot is the device picker, not
  // a connection form with nothing new to fill in. Still connection first
  // for anyone who isn't set up yet — that's the only thing to do there.
  function defaultSettingsTab() {
    return (serviceReady && loxone.configured && loxone.phase === "connected")
      ? "entities" : "connection"
  }

  // A separate plugin surface, so it goes through the shell. The popup closes
  // first because the overlay takes exclusive keyboard focus.
  function openSettings(tab) {
    if (!bar || !bar.shell || typeof bar.shell.summon !== "function") return
    close()
    bar.shell.summon("loxone", JSON.stringify({ tab: tab || root.defaultSettingsTab() }))
  }

  function expandCursor() {
    var item = currentRow()
    if (!item || !item.expandable) return
    expandedEntityId = (expandedEntityId === item.entityId) ? "" : item.entityId
  }

  // Colour carries the state, so the button never changes width.
  readonly property string icon: Model.BRAND_ICON

  readonly property color iconColor: {
    var base = bar ? bar.barForeground : Color.foreground
    return phase === "connected" ? base : Qt.darker(base, 1.5)
  }

  // From the bar, as in every built-in panel, not the global defaults.
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string family: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property color hoverFill: Style.hoverFillFor(fg, Color.accent)
  readonly property color selectedFill: Style.selectedFillFor(fg, Color.accent)

  // The hero says which state; the body below says why. The full error here
  // would duplicate it and truncate at hero width.
  readonly property string heroMeta: {
    if (!serviceReady) return "Service unavailable"
    if (!loxone.configured) return "Not connected"
    switch (phase) {
    case "connected":
      return (loxone.demoMode ? "Demo · " : "") + loxone.activitySummary
    case "connecting": return loxone.lastError ? "Retrying" : "Connecting…"
    case "error": return "Disconnected"
    default: return "Idle"
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "loxone"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    function status(): string {
      if (!root.serviceReady) return "service: UNREACHABLE"
      return "phase=" + root.loxone.phase
        + " configured=" + root.loxone.configured
        + " demo=" + root.loxone.demoMode
        + " entities=" + Object.keys(root.loxone.states).length
        + " rows=" + root.loxone.rows.count
        + (root.loxone.lastError ? " error=" + root.loxone.lastError : "")
    }

    function refresh(): void {
      if (root.serviceReady) root.loxone.refresh()
    }

    //   bind = SUPER, L, exec, omarchy-shell loxone toggleEntity light.desk
    // Goes through the row's own primary action, so a lock locks and a
    // pushbutton fires rather than being reported as not toggleable.
    function toggleEntity(entityId: string): string {
      if (!root.serviceReady) return "service unavailable"
      if (!root.loxone.entityFor(entityId)) return "unknown entity " + entityId
      return root.loxone.activateEntity(entityId)
        ? "ok" : (root.loxone.lastError || "entity isn't toggleable")
    }

    function activate(entityId: string): string {
      if (!root.serviceReady) return "service unavailable"
      if (!root.loxone.entityFor(entityId)) return "unknown entity " + entityId
      return root.loxone.activateScene(entityId)
        ? "ok" : (root.loxone.lastError || "entity isn't activatable")
    }

    //   bind = SUPER, T, exec, omarchy-shell loxone expand climate.hallway
    function expand(entityId: string): string {
      if (!root.serviceReady) return "service unavailable"
      var entity = root.loxone.entityFor(entityId)
      if (!entity) return "unknown entity " + entityId
      if (!Model.isExpandable(entity)) return "entity has no expandable controls"
      root.expandedEntityId = entityId
      root.open()
      return "ok"
    }

    function favorite(entityId: string): string {
      if (!root.serviceReady) return "service unavailable"
      if (!root.loxone.entityFor(entityId)) return "unknown entity " + entityId
      // Read before the write: the new state lands only after applyConfig.
      var was = root.loxone.isFavorite(entityId)
      root.loxone.toggleFavorite(entityId)
      return was ? "removed" : "added"
    }

    // Two no-arg calls, not one taking a tab: IpcHandler makes declared
    // arguments mandatory, so `settings` alone would refuse to run.
    function settings(): void { root.openSettings("connection") }
    function devices(): void { root.openSettings("entities") }

    // Attributes are redacted, not dumped whole — see Model.redactAttributes.
    // This output is what people paste into bug reports.
    function entityState(entityId: string): string {
      if (!root.serviceReady) return "service unavailable"
      var entity = root.loxone.entityFor(entityId)
      if (!entity) return "unknown entity " + entityId
      return entity.state + " " + JSON.stringify(Model.redactAttributes(entity))
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    foreground: root.iconColor
    // `active` paints with the bar's urgent colour.
    active: root.phase === "error"
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        // The first key press only wakes the cursor.
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.switchTab(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onTextKey: function(key) {
        var lower = String(key).toLowerCase()
        if (lower === "r" && root.serviceReady) root.loxone.refresh()
        else if (lower === "e" && root.cursorActive) root.expandCursor()
        else if (lower === "s") root.openSettings()
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.spacing.panelGap

        // ---------- hero: mark · title · status ----------
        PanelHero {
          width: parent.width
          title: "Loxone"
          meta: root.heroMeta
          foreground: root.fg
          fontFamily: root.family
          iconOpacity: root.phase === "connected" ? 1.0 : 0.55

          iconComponent: Text {
            textFormat: Text.PlainText
            text: Model.BRAND_ICON
            color: root.phase === "error" ? Color.urgent : root.fg
            font.family: root.family
            font.pixelSize: Style.font.display
          }

          trailingControl: Component {
            PanelActionButton {
              iconText: "󰒓"                  // md-cog
              tooltipText: "Settings"
              foreground: Qt.darker(root.fg, 1.4)
              fontFamily: root.family
              onClicked: root.openSettings()
            }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fg }

        // ---------- area tabs ----------
        // ButtonGroup is a Row and does not wrap, so it scrolls instead of
        // pushing chips off the panel edge.
        ScrollView {
          width: parent.width
          visible: root.tabs.length > 1 && root.hasDevices
          implicitHeight: tabGroup.implicitHeight
          clip: true
          ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
          ScrollBar.vertical.policy: ScrollBar.AlwaysOff

        ButtonGroup {
          id: tabGroup
          // The panel owns the cursor, so this is not its own Tab stop.
          focusable: false
          foreground: root.fg
          fontFamily: root.family
          fontSize: Style.font.caption
          options: root.tabs.map(function(tab) {
            return { value: tab.id, label: tab.title }
          })
          value: root.serviceReady ? root.loxone.effectiveTab : "favorites"
          onChanged: function(value) {
            if (!root.serviceReady) return
            root.loxone.setActiveTab(value)
            root.cursorIndex = 0
            root.expandedEntityId = ""
          }
        }
        }

        // With tabs on screen the group already names the section.
        PanelSectionHeader {
          width: parent.width
          visible: root.tabs.length <= 1 && root.rowCount > 0 && root.hasDevices
          text: "DEVICES"
          foreground: root.fg
          fontFamily: root.family
        }

        // ---------- body ----------
        Column {
          width: parent.width
          visible: !root.serviceReady || !root.loxone.configured
          spacing: Style.spacing.xl

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: !root.serviceReady
              ? "The Loxone service did not start."
              : "Connect to your Miniserver, or try the demo house first."
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.family
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            visible: root.serviceReady
            bordered: true
            text: "Open settings"
            foreground: root.fg
            fontFamily: root.family
            onClicked: root.openSettings("connection")
          }
        }

        // Configured but holding nothing. Rendering favorites anyway gives a
        // column of nameless "Unavailable" rows and no way out.
        Column {
          width: parent.width
          visible: root.serviceReady && root.loxone.configured && !root.hasDevices
          spacing: Style.spacing.xl

          Text {
            textFormat: Text.PlainText
            width: parent.width
            // The credential layer states the condition; the way out is named
            // here, where settings is somewhere else. The settings overlay
            // shows the same lastError without this, since telling a reader
            // who is already in settings to open settings is noise.
            text: {
              if (root.phase !== "connecting" && root.phase !== "error")
                return "Not connected."
              var reason = root.loxone.lastError || "Cannot reach the Miniserver."
              return root.loxone.lastErrorKind === "credential"
                ? reason + " Open settings to connect."
                : reason
            }
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.family
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            spacing: Style.spacing.lg

            Button {
              bordered: true
              text: "Settings"
              foreground: root.fg
              fontFamily: root.family
              onClicked: root.openSettings("connection")
            }

            Button {
              visible: root.phase === "idle"
              bordered: true
              text: "Retry"
              foreground: root.fg
              fontFamily: root.family
              onClicked: root.loxone.retryConnection()
            }
          }
        }

        Column {
          width: parent.width
          visible: root.serviceReady && root.loxone.configured
            && root.hasDevices && root.rowCount === 0
          spacing: Style.spacing.xl

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "No devices picked yet."
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.family
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            bordered: true
            text: "Choose devices"
            foreground: root.fg
            fontFamily: root.family
            onClicked: root.openSettings("entities")
          }
        }

        ScrollView {
          id: listScroller
          visible: root.serviceReady && root.rowCount > 0 && root.hasDevices
          width: parent.width
          implicitHeight: Math.min(rowsColumn.implicitHeight, Style.space(420))
          clip: true
          ScrollBar.vertical.policy: ScrollBar.AsNeeded

          Column {
            id: rowsColumn
            width: listScroller.availableWidth
            spacing: Style.spacing.hairline

            Repeater {
              id: entityRepeater
              model: root.serviceReady ? root.loxone.rows : null
              delegate: EntityRow {
                // EntityRow declares required properties, which puts the
                // delegate in required-properties mode: Qt then stops
                // injecting `index` as a context property and it has to be
                // asked for by name. Without this the cursor silently never
                // matches a row — keyboard navigation and hover highlighting
                // both die, with nothing but a log warning to show for it.
                required property int index

                width: rowsColumn.width
                service: root.loxone
                bar: root.bar
                fill: root.hoverFill
                currentFill: root.selectedFill
                showIcon: root.serviceReady ? root.loxone.showEntityIcons : true
                reserveExpandSlot: root.serviceReady ? root.loxone.rowsHaveExpandable : false
                hasCursor: root.cursorActive && root.cursorIndex === index
                expanded: root.expandedEntityId === entityId
                onCursorRequested: {
                  root.cursorActive = true
                  root.cursorIndex = index
                }
                onExpandToggled: {
                  // One at a time: this is a popup, not a dashboard.
                  root.expandedEntityId = (root.expandedEntityId === entityId)
                    ? "" : entityId
                }
              }
            }
          }
        }

        // ---------- camera, always last ----------
        CameraStream {
          width: parent.width
          visible: root.serviceReady && root.loxone.cameraConfigured
          service: root.loxone
          bar: root.bar
        }
      }
    }
  }
}

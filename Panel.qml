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
  moduleName: "hass"
  ipcTarget: "hass"
  // We own the target's single IpcHandler, so the methods below can sit
  // alongside the base open/close/toggle.
  manageIpc: false

  readonly property var hass: bar && bar.shell ? bar.shell.serviceFor("hass") : null
  readonly property bool serviceReady: hass !== null
  readonly property string phase: serviceReady ? hass.phase : "idle"

  property string expandedEntityId: ""

  // One cursor for keyboard and mouse, per the CursorSurface contract.
  // Dormant until a key is pressed.
  property int cursorIndex: 0
  property bool cursorActive: false
  property int expandedControlCursorIndex: -1

  readonly property int rowCount: serviceReady ? hass.rows.count : 0
  readonly property bool hasDevices: serviceReady && hass.hasDevices
  readonly property var tabs: serviceReady ? hass.tabs : []

  onOpenedChanged: if (!opened) {
    expandedEntityId = ""
    cursorActive = false
    cursorIndex = 0
    expandedControlCursorIndex = -1
  }

  function moveCursor(delta) {
    if (rowCount === 0 || delta === 0) return
    var currentPosition = 0
    var total = 0
    for (var i = 0; i < rowCount; i++) {
      var item = entityRepeater.itemAt(i)
      var controls = item && item.expanded ? item.expandedControlCount : 0
      if (i === cursorIndex) {
        var controlOffset = root.expandedControlCursorIndex >= 0
          && root.expandedControlCursorIndex < controls
          ? root.expandedControlCursorIndex + 1 : 0
        currentPosition = total + controlOffset
      }
      total += 1 + controls
    }

    var nextPosition = Math.max(0, Math.min(total - 1, currentPosition + delta))
    if (nextPosition === currentPosition) return
    for (var rowIndex = 0; rowIndex < rowCount; rowIndex++) {
      var row = entityRepeater.itemAt(rowIndex)
      var rowControls = row && row.expanded ? row.expandedControlCount : 0
      if (nextPosition === 0) {
        cursorIndex = rowIndex
        expandedControlCursorIndex = -1
        return
      }
      if (nextPosition <= rowControls) {
        cursorIndex = rowIndex
        expandedControlCursorIndex = nextPosition - 1
        return
      }
      nextPosition -= 1 + rowControls
    }
  }

  function moveCursorH(delta) {
    var item = currentRow()
    if (!item || root.expandedControlCursorIndex < 0) {
      root.switchTab(delta)
      return
    }
    root.expandedControlCursorIndex = Math.max(
      0, Math.min(item.expandedControlCount - 1,
                  root.expandedControlCursorIndex + delta))
  }

  function switchTab(delta) {
    if (!serviceReady || tabs.length < 2) return
    var current = 0
    for (var i = 0; i < tabs.length; i++) {
      if (tabs[i].id === hass.effectiveTab) { current = i; break }
    }
    var next = (current + delta + tabs.length) % tabs.length
    hass.setActiveTab(tabs[next].id)
    cursorIndex = 0
    expandedControlCursorIndex = -1
    expandedEntityId = ""
  }

  function currentRow() {
    var items = entityRepeater.count
    if (cursorIndex < 0 || cursorIndex >= items) return null
    return entityRepeater.itemAt(cursorIndex)
  }
  readonly property bool expandedControlPopupOpen: {
    if (!root.expandedEntityId) return false
    for (var i = 0; i < entityRepeater.count; i++) {
      var item = entityRepeater.itemAt(i)
      if (item && item.entityId === root.expandedEntityId) {
        return item.expandedControlPopupOpen
      }
    }
    return false
  }

  function activateCursor() {
    var item = currentRow()
    if (!item) return
    if (root.expandedControlCursorIndex >= 0) {
      item.activateExpandedControl(root.expandedControlCursorIndex)
    } else {
      item.activate()
    }
  }

  // A separate plugin surface, so it goes through the shell. The popup closes
  // first because the overlay takes exclusive keyboard focus.
  function openSettings(tab) {
    if (!bar || !bar.shell || typeof bar.shell.summon !== "function") return
    close()
    bar.shell.summon("hass", JSON.stringify({ tab: tab || "connection" }))
  }

  function expandCursor() {
    var item = currentRow()
    if (!item || !item.expandable) return
    expandedEntityId = (expandedEntityId === item.entityId) ? "" : item.entityId
    expandedControlCursorIndex = -1
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
    if (!hass.configured) return "Not connected"
    switch (phase) {
    case "connected":
      return (hass.demoMode ? "Demo · " : "") + hass.activitySummary
    case "connecting": return hass.lastError ? "Retrying" : "Connecting…"
    case "error": return "Disconnected"
    default: return "Idle"
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "hass"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    function status(): string {
      if (!root.serviceReady) return "service: UNREACHABLE"
      return "phase=" + root.hass.phase
        + " configured=" + root.hass.configured
        + " demo=" + root.hass.demoMode
        + " entities=" + Object.keys(root.hass.states).length
        + " rows=" + root.hass.rows.count
        + (root.hass.lastError ? " error=" + root.hass.lastError : "")
    }

    function refresh(): void {
      if (root.serviceReady) root.hass.refresh()
    }

    //   bind = SUPER, L, exec, omarchy-shell hass toggleEntity light.desk
    // Goes through the row's own primary action, so a lock locks and a scene
    // activates rather than being reported as not toggleable.
    function toggleEntity(entityId: string): string {
      if (!root.serviceReady) return "service unavailable"
      if (!root.hass.entityFor(entityId)) return "unknown entity " + entityId
      return root.hass.activateEntity(entityId)
        ? "ok" : (root.hass.lastError || "entity isn't toggleable")
    }

    function activate(entityId: string): string {
      if (!root.serviceReady) return "service unavailable"
      if (!root.hass.entityFor(entityId)) return "unknown entity " + entityId
      return root.hass.activateScene(entityId)
        ? "ok" : (root.hass.lastError || "entity isn't activatable")
    }

    //   bind = SUPER, T, exec, omarchy-shell hass expand climate.hallway
    function expand(entityId: string): string {
      if (!root.serviceReady) return "service unavailable"
      var entity = root.hass.entityFor(entityId)
      if (!entity) return "unknown entity " + entityId
      if (!Model.isExpandable(entity)) return "entity has no expandable controls"
      root.expandedEntityId = entityId
      root.open()
      return "ok"
    }

    function favorite(entityId: string): string {
      if (!root.serviceReady) return "service unavailable"
      if (!root.hass.entityFor(entityId)) return "unknown entity " + entityId
      // Read before the write: the new state lands only after applyConfig.
      var was = root.hass.isFavorite(entityId)
      root.hass.toggleFavorite(entityId)
      return was ? "removed" : "added"
    }

    // Two no-arg calls, not one taking a tab: IpcHandler makes declared
    // arguments mandatory, so `settings` alone would refuse to run.
    function settings(): void { root.openSettings("connection") }
    function devices(): void { root.openSettings("entities") }

    // Attributes are redacted, not dumped whole. A camera carries a live
    // `access_token`, a device_tracker carries GPS coordinates, and
    // `entity_picture` is a signed URL — this output is what people paste
    // into bug reports, so it must not be the easy way to leak any of them.
    function entityState(entityId: string): string {
      if (!root.serviceReady) return "service unavailable"
      var entity = root.hass.entityFor(entityId)
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
      // An open dropdown owns j/k, arrows, Enter, and Escape.
      blocked: root.expandedControlPopupOpen
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        // The first key press only wakes the cursor.
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveCursorH(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onTextKey: function(key) {
        var lower = String(key).toLowerCase()
        if (lower === "r" && root.serviceReady) root.hass.refresh()
        else if (lower === "e" && root.cursorActive) root.expandCursor()
        else if (lower === "s") root.openSettings("connection")
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.spacing.panelGap

        // ---------- hero: mark · title · status ----------
        PanelHero {
          width: parent.width
          title: "Home Assistant"
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
              onClicked: root.openSettings("connection")
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
          value: root.serviceReady ? root.hass.effectiveTab : "favorites"
          onChanged: function(value) {
            if (!root.serviceReady) return
            root.hass.setActiveTab(value)
            root.cursorIndex = 0
            root.expandedControlCursorIndex = -1
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
          visible: !root.serviceReady || !root.hass.configured
          spacing: Style.spacing.xl

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: !root.serviceReady
              ? "The Home Assistant service did not start."
              : "Connect to your Home Assistant, or try the demo house first."
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
          visible: root.serviceReady && root.hass.configured && !root.hasDevices
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
              var reason = root.hass.lastError || "Cannot reach Home Assistant."
              return root.hass.lastErrorKind === "credential"
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
              onClicked: root.hass.retryConnection()
            }
          }
        }

        Column {
          width: parent.width
          visible: root.serviceReady && root.hass.configured
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
              model: root.serviceReady ? root.hass.rows : null
              delegate: EntityRow {
                // EntityRow declares required properties, which puts the
                // delegate in required-properties mode: Qt then stops
                // injecting `index` as a context property and it has to be
                // asked for by name. Without this the cursor silently never
                // matches a row — keyboard navigation and hover highlighting
                // both die, with nothing but a log warning to show for it.
                required property int index

                width: rowsColumn.width
                hass: root.hass
                bar: root.bar
                fill: root.hoverFill
                currentFill: root.selectedFill
                showIcon: root.serviceReady ? root.hass.showEntityIcons : true
                reserveExpandSlot: root.serviceReady ? root.hass.rowsHaveExpandable : false
                hasCursor: root.cursorActive && root.cursorIndex === index
                  && root.expandedControlCursorIndex < 0
                expanded: root.expandedEntityId === entityId
                expandedControlCursorIndex: root.cursorIndex === index
                  ? root.expandedControlCursorIndex : -1
                onCursorRequested: {
                  root.cursorActive = true
                  root.cursorIndex = index
                  root.expandedControlCursorIndex = -1
                }
                onExpandToggled: {
                  // One at a time: this is a popup, not a dashboard.
                  root.expandedEntityId = (root.expandedEntityId === entityId)
                    ? "" : entityId
                  root.expandedControlCursorIndex = -1
                }
                onExpandedControlCursorRequested: function(controlIndex) {
                  if (controlIndex < 0) return
                  root.cursorActive = true
                  root.cursorIndex = index
                  root.expandedControlCursorIndex = controlIndex
                }
              }
            }
          }
        }
      }
    }
  }
}

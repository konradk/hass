import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Connection.js" as Connection

// Connection credentials and device picking.
//
// Summoned by the shell, not by IPC: the bar widget already owns the "hass"
// target and a target routes to one handler.
//   omarchy-shell shell summon hass '{"tab":"entities"}'
Item {
  id: root

  // Injected by the shell's panel loader.
  property var shell: null
  property var manifest: null
  property var service: null

  property bool opened: false
  property string tab: "connection"

  // Local until Connect, so a half-typed URL never reaches the bridge.
  property string urlDraft: ""
  property string localUrlDraft: ""
  // Required whenever localUrlDraft is non-empty: the local URL is only ever
  // tried on this Wi-Fi network. See bin/hass-bridge's current_wifi_ssid.
  property string trustedNetworkDraft: ""
  // Collapsed unless a local URL is already saved: most people never need
  // this field, and a second always-visible URL box with its own warning text
  // outweighs the value of surfacing it up front.
  property bool localUrlExpanded: false
  // Suggestion only, for the trusted-network field — read-only, not used for
  // anything security-relevant. The bridge determines the actual network
  // independently in Python before ever using a local URL.
  property string detectedWifiSsid: ""
  property string tokenDraft: ""

  Process {
    id: wifiSsidProbe
    // --rescan no: only what NetworkManager already knows about the active
    // connection is needed here, not a fresh scan of every nearby network —
    // that forces nmcli to block for several seconds instead of returning
    // near-instantly.
    command: ["nmcli", "-t", "-f", "active,ssid", "dev", "wifi", "list",
              "--rescan", "no"]
    stdout: SplitParser {
      onRead: function(value) {
        var ssid = Connection.parseNmcliActiveSsid(value)
        if (ssid) root.detectedWifiSsid = ssid
      }
    }
  }

  property string query: ""
  // Debounced: a burst of keystrokes costs one pass over the entities.
  property string appliedQuery: ""
  property string domainFilter: "all"

  property Timer queryDebounce: Timer {
    interval: 120
    onTriggered: root.appliedQuery = root.query
  }

  onQueryChanged: queryDebounce.restart()

  // The device list is rebuilt from `stateRevision`, which ticks on every
  // state_changed. A real instance has hundreds of sensors reporting
  // constantly, and each tick means a full pass over every entity — so follow
  // it at a fixed rate rather than per event. Starring stays instant: that
  // binding watches `favorites`, which only the user changes.
  property int shownRevision: 0
  readonly property int liveRevision: root.service ? root.service.stateRevision : 0

  onLiveRevisionChanged: if (!revisionThrottle.running) revisionThrottle.start()

  property Timer revisionThrottle: Timer {
    interval: 400
    onTriggered: root.shownRevision = root.liveRevision
  }

  readonly property string family: Style.font.menuFamily
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property var borderSpec: Border.surfaceSpec(
    "menu", "border", Color.menu.border, Math.max(1, Style.space(2)))

  function open(payloadJson) {
    root.opened = true
    root.resetDrafts()
    try {
      var payload = payloadJson ? JSON.parse(payloadJson) : {}
      if (payload.tab === "entities" || payload.tab === "connection"
          || payload.tab === "general") {
        root.tab = payload.tab
      }
    } catch (e) {
      // Not worth refusing to open over.
    }
    // Fresh on every open, not just the first: the answer can change between
    // sessions, and a stale one from an old network would suggest the wrong
    // name.
    root.detectedWifiSsid = ""
    if (!wifiSsidProbe.running) wifiSsidProbe.running = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function") {
      root.shell.hide((root.manifest && root.manifest.id) || "hass")
    }
  }

  function resetDrafts() {
    if (!service) return
    root.urlDraft = service.baseUrl
    root.localUrlDraft = service.localUrl
    root.trustedNetworkDraft = service.trustedNetwork
    root.localUrlExpanded = service.localUrl.length > 0
    // The stored token never comes back to screen; blank means "keep it".
    root.tokenDraft = ""
    root.query = ""
    root.appliedQuery = ""
    root.domainFilter = "all"
    // The throttle only fires on a change, so an overlay opened after the
    // devices arrived would otherwise start from a stale revision.
    root.shownRevision = service.stateRevision
  }

  function applyConnection() {
    if (!service) return
    if (service.applyConnection(root.urlDraft.trim(), root.localUrlDraft.trim(),
                                root.trustedNetworkDraft.trim(), root.tokenDraft, false)) {
      root.tokenDraft = ""
    }
  }

  PanelWindow {
    id: window
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "hass-settings"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      // The device picker is two full-height columns and needs the room; the
      // connection form is a handful of fields and would look stranded in it.
      // Both still yield to a small screen.
      readonly property int preferredWidth:
        root.tab === "entities" ? Style.space(940) : Style.space(620)
      readonly property int preferredHeight:
        root.tab === "entities" ? Style.space(620) : Style.space(560)
      width: Math.min(card.preferredWidth, window.width - Style.gapsOut * 2)
      height: Math.min(card.preferredHeight, window.height - Style.gapsOut * 2)
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        // BorderSurface.padding only *computes* the insets; callers apply
        // them by hand, as ConfirmDialog and KeyboardPanel do.
        anchors.topMargin: card.contentTopInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        onCloseRequested: root.dismiss()

        // Anchors, not computed heights: deriving the body from the card
        // height silently truncates the list when a scale moves.
        Item {
          id: header
          anchors { top: parent.top; left: parent.left; right: parent.right }
          implicitHeight: Math.max(heading.implicitHeight, tabRow.implicitHeight)
          height: implicitHeight

          Text {
            textFormat: Text.PlainText
            id: heading
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Home Assistant settings"
            color: root.foreground
            font.family: root.family
            font.pixelSize: Style.font.title
            font.weight: Font.Medium
          }

          ButtonGroup {
            id: tabRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            foreground: root.foreground
            fontFamily: root.family
            fontSize: Style.font.caption
            options: [{ value: "connection", label: "Connection" },
                      { value: "general", label: "General" },
                      { value: "entities", label: "Devices" }]
            value: root.tab
            onChanged: function(value) { root.tab = value }
          }
        }

        PanelSeparator {
          id: rule
          anchors { top: header.bottom; left: parent.left; right: parent.right }
          anchors.topMargin: Style.space(12)
        }

        Item {
          id: body
          anchors {
            top: rule.bottom; bottom: parent.bottom
            left: parent.left; right: parent.right
          }
          anchors.topMargin: Style.space(14)

          Loader {
            anchors.fill: parent
            active: root.tab === "connection"
            visible: active
            sourceComponent: connectionTab
          }

          Loader {
            anchors.fill: parent
            active: root.tab === "general"
            visible: active
            sourceComponent: generalTab
          }

          Loader {
            anchors.fill: parent
            active: root.tab === "entities"
            visible: active
            sourceComponent: entitiesTab
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ connection

  Component {
    id: connectionTab

    Item {
      id: connectionPane
      // Nothing here is disabled: Ui/TextField and Ui/Button have no disabled
      // styling, so a blocked field looks exactly like a live one.
      // The bridge retries in `error` too; only a bad token stops it.
      // "Retrying" and "stopped, and nothing will retry" both surface as phase
      // "error", so the two Cancel/Retry states have to be told apart by what
      // is actually still running. Without this, a bridge that exited or a
      // token removal that failed offers only Cancel — and the way back to a
      // working connection is to press Cancel first, which reads as giving up.
      readonly property bool live: root.service && root.service.configured
        && !root.service.demoMode
      readonly property bool stalled: root.service
        && (root.service.connectionSuppressed || !root.service.bridgeRunning
            || root.service.phase === "idle")
      readonly property bool trying: connectionPane.live && !connectionPane.stalled
        && (root.service.phase === "connecting" || root.service.phase === "error")
      readonly property bool paused: connectionPane.live && connectionPane.stalled
      readonly property bool keyringBusy: root.service && root.service.credentialBusy
      readonly property bool needsToken: root.service
        ? root.service.requiresTokenFor(root.urlDraft.trim()) : true
      readonly property bool validUrl: Connection.normalizeOrigin(root.urlDraft) !== ""
      // Blank is fine — it just means no local fallback.
      readonly property bool validLocalUrl: root.localUrlDraft.trim().length === 0
        || Connection.normalizeOrigin(root.localUrlDraft) !== ""
      // A local URL with no trusted network to gate it would be tried on
      // every Wi-Fi the laptop joins.
      readonly property bool localUrlNeedsTrust: root.localUrlDraft.trim().length > 0
        && Connection.trustedNetworkList(root.trustedNetworkDraft).length === 0
      readonly property bool canConnect: validUrl && validLocalUrl && !localUrlNeedsTrust
        && !keyringBusy && (!needsToken || root.tokenDraft.length > 0)

      // Flickable rather than anchoring the column straight to the card: the
      // card's height is fixed (see card.preferredHeight above), and this
      // form has grown past it before — the local URL toggle alone added
      // enough fields to spill content out past the card's border with
      // nothing to contain it. A Column that can outgrow its container has to
      // scroll, not just hope it never does.
      Flickable {
        id: connectionFlick
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: connectionColumn.height
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: connectionColumn
          width: connectionFlick.width
          spacing: Style.spacing.xxxl

          Column {
            width: connectionColumn.width
            spacing: Style.spacing.sm

            Text {
              textFormat: Text.PlainText
              text: "Home Assistant URL"
              color: Color.muted
              font.family: root.family
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              width: connectionColumn.width
              text: root.urlDraft
              placeholderText: "https://homeassistant.local:8123"
              onTextChanged: root.urlDraft = text
            }

            Text {
              textFormat: Text.PlainText
              width: connectionColumn.width
              visible: root.urlDraft.trim().toLowerCase().indexOf("http://") === 0
                || root.urlDraft.trim().toLowerCase().indexOf("ws://") === 0
              text: "Warning: this URL sends your long-lived access token without transport encryption. Use HTTPS unless this is a trusted local network."
              color: Color.muted
              font.family: root.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Column {
            width: connectionColumn.width
            spacing: Style.spacing.sm

            // Ui/Toggle: label + description + switch, row owns the click.
            Toggle {
              width: connectionColumn.width
              label: "Local network URL"
              description: "Try a LAN address first, e.g. your instance's local IP, before falling back to the URL above. Uses the same access token."
              checked: root.localUrlExpanded
              foreground: root.foreground
              fontFamily: root.family
              onClicked: {
                root.localUrlExpanded = !root.localUrlExpanded
                // Collapsing means "no local URL" — a hidden stale draft would
                // otherwise still reach applyConnection.
                if (!root.localUrlExpanded) {
                  root.localUrlDraft = ""
                  root.trustedNetworkDraft = ""
                }
              }
            }

            TextField {
              visible: root.localUrlExpanded
              width: connectionColumn.width
              text: root.localUrlDraft
              placeholderText: "https://192.168.1.50:8123"
              onTextChanged: root.localUrlDraft = text
            }

            Text {
              textFormat: Text.PlainText
              width: connectionColumn.width
              visible: root.localUrlExpanded
                && (root.localUrlDraft.trim().toLowerCase().indexOf("http://") === 0
                  || root.localUrlDraft.trim().toLowerCase().indexOf("ws://") === 0)
              text: "Warning: this URL sends your long-lived access token without transport encryption. Use HTTPS unless this is a trusted local network."
              color: Color.muted
              font.family: root.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              visible: root.localUrlExpanded
              text: "Trusted Wi-Fi network name(s)"
              color: Color.muted
              font.family: root.family
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              visible: root.localUrlExpanded
              width: connectionColumn.width
              text: root.trustedNetworkDraft
              placeholderText: "Home, Home 5G"
              onTextChanged: root.trustedNetworkDraft = text
            }

            // A suggestion, not an autofill: it only offers the network this
            // machine happens to be on right now, so it disappears the moment
            // there's anything to lose by acting on it — a name typed in, or
            // no detectable Wi-Fi at all.
            Row {
              visible: root.localUrlExpanded
                && root.trustedNetworkDraft.trim().length === 0
                && root.detectedWifiSsid.length > 0
              spacing: Style.spacing.sm

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "Currently on “" + root.detectedWifiSsid + "”."
                color: Color.muted
                font.family: root.family
                font.pixelSize: Style.font.caption
              }

              Button {
                anchors.verticalCenter: parent.verticalCenter
                bordered: true
                text: "Use this"
                foreground: root.foreground
                fontFamily: root.family
                onClicked: root.trustedNetworkDraft = root.detectedWifiSsid
              }
            }

            Text {
              textFormat: Text.PlainText
              width: connectionColumn.width
              visible: root.localUrlExpanded
              text: "Required. Comma-separated if your router has more than one (e.g. separate 2.4GHz/5GHz names). The local URL is only ever tried while connected to one of these — never on any other network, so the token can't be sent to whatever happens to answer at that address elsewhere."
              color: Color.muted
              font.family: root.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Column {
            width: connectionColumn.width
            spacing: Style.spacing.sm

            Text {
              textFormat: Text.PlainText
              text: root.service && root.service.configured && !root.service.demoMode
                ? "Access token · leave blank to keep the stored one"
                : "Long-lived access token"
              color: Color.muted
              font.family: root.family
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              width: connectionColumn.width
              text: root.tokenDraft
              password: true
              placeholderText: "Paste from your Home Assistant profile"
              onTextChanged: root.tokenDraft = text
            }

            Text {
              textFormat: Text.PlainText
              width: connectionColumn.width
              visible: connectionPane.needsToken && root.urlDraft.trim().length > 0
              text: "Changing the server origin requires entering its token again."
              color: Color.muted
              font.family: root.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Row {
            spacing: Style.spacing.xl

            Button {
              bordered: true   // Ui/Button is flat otherwise, reading as a label
              text: "Connect"
              opacity: connectionPane.canConnect ? 1.0 : 0.45
              foreground: root.foreground
              fontFamily: root.family
              onClicked: if (connectionPane.canConnect) root.applyConnection()
            }

            Button {
              visible: connectionPane.trying
              bordered: true
              text: "Cancel"
              foreground: root.foreground
              fontFamily: root.family
              onClicked: root.service.cancelConnection()
            }

            Button {
              visible: connectionPane.paused
              bordered: true
              text: "Retry"
              foreground: root.foreground
              fontFamily: root.family
              onClicked: root.service.retryConnection()
            }

            Button {
              bordered: true
              text: "Remove"
              opacity: (root.service && root.service.configured
                        && !connectionPane.keyringBusy) ? 1.0 : 0.45
              foreground: root.foreground
              fontFamily: root.family
              onClicked: {
                if (!root.service || !root.service.configured
                    || connectionPane.keyringBusy) return
                root.service.removeConnection()
                root.resetDrafts()
              }
            }
          }

          PanelSeparator { width: connectionColumn.width }

          // Ui/Toggle: label + description + switch, row owns the click.
          Toggle {
            width: connectionColumn.width
            label: "Demo mode"
            description: "A fake house, so you can try the panel without an instance."
            checked: root.service ? root.service.demoMode : false
            foreground: root.foreground
            fontFamily: root.family
            onClicked: if (root.service) root.service.setDemoMode(!root.service.demoMode)
          }

          // From the live connection, not a probe: a probe on a different path
          // can pass while the real connection fails.
          Row {
            spacing: Style.spacing.lg

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(8); height: width; radius: width / 2
              color: !root.service ? Color.muted
                   : root.service.phase === "connected" ? "#4caf50"
                   : root.service.phase === "error" ? Color.urgent
                   : Color.muted
            }

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              width: connectionColumn.width - Style.space(24)
              text: {
                if (!root.service) return "Service unavailable"
                if (!root.service.configured) return "Not connected"
                switch (root.service.phase) {
                case "connected":
                  return (root.service.demoMode ? "Demo running · "
                    : root.service.usingLocal ? "Connected (local network) · "
                    : "Connected · ")
                    + Object.keys(root.service.states).length + " devices"
                case "connecting": return root.service.lastError
                  ? "Connecting… · " + root.service.lastError
                  : "Connecting…"
                case "error": return root.service.lastError || "Connection failed"
                default: return root.service.lastError || "Idle"
                }
              }
              color: Color.muted
              font.family: root.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ general

  Component {
    id: generalTab

    Item {
      Column {
        anchors { top: parent.top; left: parent.left; right: parent.right }
        spacing: Style.spacing.xl

        Toggle {
          width: parent.width
          label: "Group by area"
          description: "Add area tabs for picked devices, alongside Favorites."
          checked: root.service ? root.service.groupByArea : false
          foreground: root.foreground
          fontFamily: root.family
          onClicked: if (root.service) {
            root.service.setGroupByArea(!root.service.groupByArea)
          }
        }

        Toggle {
          width: parent.width
          label: "Show pin shortcut on hover"
          description: "Replace an expandable device icon with its pin shortcut while the pointer is over the row."
          checked: root.service ? root.service.showPanelPinOnHover : false
          foreground: root.foreground
          fontFamily: root.family
          onClicked: if (root.service) {
            root.service.setShowPanelPinOnHover(
              !root.service.showPanelPinOnHover)
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ devices

  Component {
    id: entitiesTab

    Item {
      id: devices

      // A known entity's state is replaced in place, so `states` identity does
      // not change on the hot path; stateRevision is what fires these.
      readonly property var favorites: root.service
        ? (root.shownRevision, root.service.favorites, root.service.roomReadings,
           root.service.pinnedRoomReadings, root.service.pinnedEntities,
           root.service.favoriteSummaries())
        : []
      readonly property var results: root.service
        ? (root.shownRevision, root.service.favorites, root.service.roomReadings,
           root.service.pinnedRoomReadings, root.service.pinnedEntities,
           root.service.browseEntities(root.appliedQuery, root.domainFilter))
        : []

      TextField {
        id: search
        anchors { top: parent.top; left: parent.left; right: parent.right }
        text: root.query
        placeholderText: "Search devices…"
        onTextChanged: root.query = text
      }

      ButtonGroup {
        id: chips
        anchors { top: search.bottom; left: parent.left; right: parent.right }
        anchors.topMargin: Style.spacing.xl
        foreground: root.foreground
        fontFamily: root.family
        fontSize: Style.font.caption
        options: Model.DOMAIN_FILTERS.map(function(filter) {
          return { value: filter.id, label: filter.title }
        })
        value: root.domainFilter
        onChanged: function(value) { root.domainFilter = value }
      }

      // Side by side, not stacked. Stacked, the picked list grew downwards and
      // the browser it was picked from got whatever height was left — with a
      // real instance's several hundred entities that was a handful of visible
      // rows and a lot of scrolling. Two columns give both lists the full
      // height of the card, and put the source and the destination of a star
      // next to each other.
      Item {
        id: columns
        anchors {
          top: chips.bottom; bottom: parent.bottom
          left: parent.left; right: parent.right
        }
        anchors.topMargin: Style.spacing.xxl

        readonly property int gap: Style.spacing.huge
        readonly property int columnWidth: Math.floor((width - gap) / 2)

        // ---------- left: everything there is ----------
        Item {
          id: browseColumn
          anchors { top: parent.top; bottom: parent.bottom; left: parent.left }
          width: columns.columnWidth

          PanelSectionHeader {
            id: allHeader
            anchors { top: parent.top; left: parent.left; right: parent.right }
            text: root.appliedQuery.length > 0 || root.domainFilter !== "all"
              ? "MATCHING DEVICES" : "ALL DEVICES"
            foreground: root.foreground
            fontFamily: root.family
          }

          Text {
            textFormat: Text.PlainText
            id: emptyNote
            anchors { top: allHeader.bottom; left: parent.left; right: parent.right }
            anchors.topMargin: Style.spacing.lg
            visible: devices.results.length === 0
            height: visible ? implicitHeight : 0
            text: root.service && !root.service.hasDevices
              ? "No devices yet — connect first."
              : "Nothing matches that search."
            color: Color.muted
            font.family: root.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // Virtualized, unlike a Repeater, which would build a delegate per
          // entity on every keystroke.
          ListView {
            id: deviceList
            anchors {
              top: emptyNote.bottom; bottom: parent.bottom
              left: parent.left; right: parent.right
            }
            anchors.topMargin: Style.spacing.sm
            clip: true
            spacing: Style.spacing.xxs
            model: devices.results
            cacheBuffer: Style.space(400)
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            // Jump to the top when the user asks a new question, and only
            // then. `results` is also rebuilt every time the throttled state
            // revision ticks — a live instance does that a few times a second
            // — so resetting on every model change yanked the list back to the
            // top while someone was scrolling through it.
            Connections {
              target: root
              function onAppliedQueryChanged() { deviceList.positionViewAtBeginning() }
              function onDomainFilterChanged() { deviceList.positionViewAtBeginning() }
            }

            delegate: SettingsEntityRow {
              required property var modelData
              width: deviceList.width
              entityId: modelData.entityId
              name: modelData.name
              icon: modelData.icon
              detail: root.domainFilter === "room_readings"
                ? modelData.detail : modelData.entityId
              favorite: modelData.favorite
              reorderable: false
              roomReading: root.domainFilter === "room_readings"
              pinnable: modelData.pinnable === true
              pinned: modelData.pinned === true
              service: root.service
              family: root.family
            }
          }
        }

        // ---------- right: what the panel shows ----------
        Item {
          id: favColumn
          anchors { top: parent.top; bottom: parent.bottom; right: parent.right }
          width: columns.columnWidth

          PanelSectionHeader {
            id: favHeader
            anchors { top: parent.top; left: parent.left; right: parent.right }
            text: devices.favorites.length > 0
              ? "IN THE PANEL · " + devices.favorites.length
              : "IN THE PANEL"
            foreground: root.foreground
            fontFamily: root.family
          }

          // The column keeps its width when empty, so it needs to say why it
          // is blank rather than read as a rendering fault.
          Text {
            textFormat: Text.PlainText
            id: favEmptyNote
            anchors { top: favHeader.bottom; left: parent.left; right: parent.right }
            anchors.topMargin: Style.spacing.lg
            visible: devices.favorites.length === 0
            height: visible ? implicitHeight : 0
            text: "Nothing picked yet. Star a device on the left to put it in the panel."
            color: Color.muted
            font.family: root.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          ListView {
            id: favList
            anchors {
              top: favEmptyNote.bottom; bottom: parent.bottom
              left: parent.left; right: parent.right
            }
            anchors.topMargin: Style.spacing.sm
            clip: true
            spacing: Style.spacing.xxs
            model: devices.favorites
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: SettingsEntityRow {
              required property var modelData
              width: favList.width
              entityId: modelData.entityId
              name: modelData.name
              icon: modelData.icon
              detail: modelData.available ? modelData.state : "Unavailable"
              favorite: true
              reorderable: true
              roomReading: modelData.roomReading
              pinnable: modelData.pinnable === true
              pinned: modelData.pinned
              panelItemId: modelData.panelItemId
              service: root.service
              family: root.family
            }
          }
        }
      }
    }
  }
}

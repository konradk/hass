import Quickshell
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Connection.js" as Connection

// Connection credentials and device picking.
//
// Summoned by the shell, not by IPC: the bar widget already owns the "loxone"
// target and a target routes to one handler.
//   omarchy-shell shell summon loxone '{"tab":"entities"}'
Item {
  id: root

  // Injected by the shell's panel loader.
  property var shell: null
  property var manifest: null
  property var service: null

  property bool opened: false
  property string tab: "connection"

  // A camera stream costs the camera something to serve for as long as the
  // bridge is pulling frames — worth it while this overlay's Camera tab
  // could show live status/feedback, not while it's closed entirely. Panel's
  // popover registers the same way; the count in Service.qml is what keeps
  // both surfaces being open at once from double-stopping each other.
  onOpenedChanged: {
    if (!root.service) return
    if (root.opened) root.service.registerCameraViewer()
    else root.service.unregisterCameraViewer()
  }

  // Local until Connect, so a half-typed URL or password never reaches the
  // bridge.
  property string urlDraft: ""
  property string userDraft: ""
  property string passwordDraft: ""

  property string cameraUrlDraft: ""
  property string cameraUserDraft: ""
  property string cameraPasswordDraft: ""

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
  // poll. A Miniserver with a hundred controls means a full pass over every
  // entity per tick — so follow it at a fixed rate rather than per event.
  // Starring stays instant: that binding watches `favorites`, which only the
  // user changes.
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
          || payload.tab === "camera" || payload.tab === "general") {
        root.tab = payload.tab
      }
    } catch (e) {
      // Not worth refusing to open over.
    }
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function") {
      root.shell.hide((root.manifest && root.manifest.id) || "loxone")
    }
  }

  function resetDrafts() {
    if (!service) return
    root.urlDraft = service.baseUrl
    root.userDraft = service.username
    // The stored password never comes back to screen; blank means "keep it".
    root.passwordDraft = ""
    root.cameraUrlDraft = service.cameraUrl
    root.cameraUserDraft = service.cameraUsername
    root.cameraPasswordDraft = ""
    root.query = ""
    root.appliedQuery = ""
    root.domainFilter = "all"
    // The throttle only fires on a change, so an overlay opened after the
    // devices arrived would otherwise start from a stale revision.
    root.shownRevision = service.stateRevision
  }

  function applyCameraConnection() {
    if (!service) return
    if (service.applyCamera(root.cameraUrlDraft.trim(), root.cameraUserDraft.trim(),
                            root.cameraPasswordDraft)) {
      root.cameraPasswordDraft = ""
    }
  }

  function applyConnection() {
    if (!service) return
    if (service.applyConnection(root.urlDraft.trim(), root.userDraft.trim(),
                                root.passwordDraft, false)) {
      root.passwordDraft = ""
    }
  }

  PanelWindow {
    id: window
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "loxone-settings"
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
        root.tab === "entities" ? Style.space(620) : Style.space(620)
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
            text: "Loxone settings"
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
                      { value: "camera", label: "Camera" },
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
            active: root.tab === "camera"
            visible: active
            sourceComponent: cameraTab
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
      // The bridge retries in `error` too; only a bad credential stops it.
      // "Retrying" and "stopped, and nothing will retry" both surface as
      // phase "error", so the two Cancel/Retry states have to be told apart
      // by what is actually still running. Without this, a bridge that
      // exited or a password removal that failed offers only Cancel — and
      // the way back to a working connection is to press Cancel first, which
      // reads as giving up.
      readonly property bool live: root.service && root.service.configured
        && !root.service.demoMode
      readonly property bool stalled: root.service
        && (root.service.connectionSuppressed || !root.service.bridgeRunning
            || root.service.phase === "idle")
      readonly property bool trying: connectionPane.live && !connectionPane.stalled
        && (root.service.phase === "connecting" || root.service.phase === "error")
      readonly property bool paused: connectionPane.live && connectionPane.stalled
      readonly property bool keyringBusy: root.service && root.service.credentialBusy
      readonly property bool needsPassword: root.service
        ? root.service.requiresPasswordFor(root.urlDraft.trim()) : true
      readonly property bool validUrl: Connection.normalizeOrigin(root.urlDraft) !== ""
      readonly property bool canConnect: validUrl && root.userDraft.trim().length > 0
        && !keyringBusy && (!needsPassword || root.passwordDraft.length > 0)

      Column {
        id: connectionColumn
        anchors { top: parent.top; left: parent.left; right: parent.right }
        spacing: Style.spacing.xxxl

        Column {
          width: connectionColumn.width
          spacing: Style.spacing.sm

          Text {
            textFormat: Text.PlainText
            text: "Miniserver URL"
            color: Color.muted
            font.family: root.family
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            width: connectionColumn.width
            text: root.urlDraft
            placeholderText: "https://192.168.1.77"
            onTextChanged: root.urlDraft = text
          }

          Text {
            textFormat: Text.PlainText
            width: connectionColumn.width
            visible: root.urlDraft.trim().toLowerCase().indexOf("http://") === 0
              || root.urlDraft.trim().toLowerCase().indexOf("ws://") === 0
            text: "Warning: this URL sends your username and password without transport encryption. Use HTTPS unless this is a trusted local network."
            color: Color.muted
            font.family: root.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        Row {
          width: connectionColumn.width
          spacing: Style.spacing.xxxl

          Column {
            width: (parent.width - Style.spacing.xxxl) / 2
            spacing: Style.spacing.sm

            Text {
              textFormat: Text.PlainText
              text: "Username"
              color: Color.muted
              font.family: root.family
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              width: parent.width
              text: root.userDraft
              placeholderText: "admin"
              onTextChanged: root.userDraft = text
            }
          }

          Column {
            width: (parent.width - Style.spacing.xxxl) / 2
            spacing: Style.spacing.sm

            Text {
              textFormat: Text.PlainText
              text: root.service && root.service.configured && !root.service.demoMode
                ? "Password · leave blank to keep the stored one"
                : "Password"
              color: Color.muted
              font.family: root.family
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              width: parent.width
              text: root.passwordDraft
              password: true
              placeholderText: "Miniserver password"
              onTextChanged: root.passwordDraft = text
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          width: connectionColumn.width
          visible: connectionPane.needsPassword && root.urlDraft.trim().length > 0
          text: "Changing the server origin requires entering its password again."
          color: Color.muted
          font.family: root.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
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
          description: "A fake house, so you can try the panel without a Miniserver."
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
                return (root.service.demoMode ? "Demo running · " : "Connected · ")
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

  // ------------------------------------------------------------ camera

  Component {
    id: cameraTab

    Item {
      id: cameraPane

      readonly property bool keyringBusy: root.service && root.service.cameraCredentialBusy
      readonly property bool validUrl: Connection.normalizeOrigin(root.cameraUrlDraft) !== ""
      readonly property bool canConnect: validUrl
        && root.cameraUserDraft.trim().length > 0 && !keyringBusy

      Column {
        id: cameraColumn
        anchors { top: parent.top; left: parent.left; right: parent.right }
        spacing: Style.spacing.xxxl

        Column {
          width: cameraColumn.width
          spacing: Style.spacing.sm

          Text {
            textFormat: Text.PlainText
            text: "Camera stream URL"
            color: Color.muted
            font.family: root.family
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            width: cameraColumn.width
            text: root.cameraUrlDraft
            placeholderText: "https://192.168.1.50/axis-cgi/mjpg/video.cgi"
            onTextChanged: root.cameraUrlDraft = text
          }

          Text {
            textFormat: Text.PlainText
            width: cameraColumn.width
            text: "A plain MJPEG stream URL or a single-image snapshot URL both work — "
              + "whichever the camera answers with is detected automatically."
            color: Color.muted
            font.family: root.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            width: cameraColumn.width
            visible: root.cameraUrlDraft.trim().toLowerCase().indexOf("http://") === 0
            text: "Warning: this URL sends the camera's username and password without transport encryption. Use HTTPS unless this is a trusted local network."
            color: Color.muted
            font.family: root.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        Row {
          width: cameraColumn.width
          spacing: Style.spacing.xxxl

          Column {
            width: (parent.width - Style.spacing.xxxl) / 2
            spacing: Style.spacing.sm

            Text {
              textFormat: Text.PlainText
              text: "Username"
              color: Color.muted
              font.family: root.family
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              width: parent.width
              text: root.cameraUserDraft
              onTextChanged: root.cameraUserDraft = text
            }
          }

          Column {
            width: (parent.width - Style.spacing.xxxl) / 2
            spacing: Style.spacing.sm

            Text {
              textFormat: Text.PlainText
              text: root.service && root.service.cameraConfigured
                ? "Password · leave blank to keep the stored one"
                : "Password"
              color: Color.muted
              font.family: root.family
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              width: parent.width
              text: root.cameraPasswordDraft
              password: true
              onTextChanged: root.cameraPasswordDraft = text
            }
          }
        }

        Row {
          spacing: Style.spacing.xl

          Button {
            bordered: true
            text: "Connect"
            opacity: cameraPane.canConnect ? 1.0 : 0.45
            foreground: root.foreground
            fontFamily: root.family
            onClicked: if (cameraPane.canConnect) root.applyCameraConnection()
          }

          Button {
            bordered: true
            text: "Remove"
            opacity: (root.service && root.service.cameraConfigured
                      && !cameraPane.keyringBusy) ? 1.0 : 0.45
            foreground: root.foreground
            fontFamily: root.family
            onClicked: {
              if (!root.service || !root.service.cameraConfigured
                  || cameraPane.keyringBusy) return
              root.service.removeCamera()
              root.resetDrafts()
            }
          }
        }

        PanelSeparator { width: cameraColumn.width }

        Toggle {
          width: cameraColumn.width
          label: "Verify TLS certificate"
          description: "Most IP cameras use a self-signed certificate; leave this off unless yours has a trusted one."
          checked: root.service ? root.service.cameraVerifyTls : false
          foreground: root.foreground
          fontFamily: root.family
          onClicked: if (root.service) {
            root.service.setCameraVerifyTls(!root.service.cameraVerifyTls)
          }
        }

        Row {
          spacing: Style.spacing.lg

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(8); height: width; radius: width / 2
            color: !root.service ? Color.muted
                 : root.service.cameraStatus === "streaming" ? "#4caf50"
                 : root.service.cameraStatus === "error" ? Color.urgent
                 : Color.muted
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            width: cameraColumn.width - Style.space(24)
            text: {
              if (!root.service || !root.service.cameraConfigured) return "No camera configured"
              switch (root.service.cameraStatus) {
              case "streaming": return "Streaming"
              case "connecting": return "Connecting…"
              case "error": return root.service.cameraError || "Camera unavailable"
              default: return "Idle"
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
          label: "Verify TLS certificate"
          description: "Most Miniservers use a self-signed certificate; leave this off unless yours has a trusted one."
          checked: root.service ? root.service.verifyTls : false
          foreground: root.foreground
          fontFamily: root.family
          onClicked: if (root.service) {
            root.service.setVerifyTls(!root.service.verifyTls)
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
        ? (root.shownRevision, root.service.favorites,
           root.service.favoriteSummaries())
        : []
      readonly property var results: root.service
        ? (root.shownRevision, root.service.favorites,
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
      // real Miniserver's several dozen controls that was a handful of
      // visible rows and a lot of scrolling. Two columns give both lists the
      // full height of the card, and put the source and the destination of a
      // star next to each other.
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
            // revision ticks — a live Miniserver does that a few times a
            // second — so resetting on every model change yanked the list
            // back to the top while someone was scrolling through it.
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
              detail: modelData.entityId
              favorite: modelData.favorite
              reorderable: false
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
              service: root.service
              family: root.family
            }
          }
        }
      }
    }
  }
}

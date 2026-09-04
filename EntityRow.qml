import QtQuick
import qs.Ui
import qs.Commons
import "controls"
import "Model.js" as Model
import "BarData.js" as BarData

// One device in the panel list, shaped after bluetooth/Panel.qml's DeviceRow.
// The switch handles its own click, so on an expandable row the body is free
// to open the controls instead.
CursorSurface {
  id: row

  required property string entityId
  required property string name
  required property string subtitle
  required property string badge
  required property string icon
  required property bool isOn
  required property bool pending
  required property bool available
  required property string control
  required property bool expandable
  required property string domain
  required property string rowKind
  required property string roomDeviceId
  required property string controlEntityId

  property var hass: null
  property QtObject bar: null
  property bool showIcon: true
  // Per-list: reserving always pushes every switch a chevron's width off the
  // edge, reserving never leaves them ragged.
  property bool reserveExpandSlot: false

  signal expandToggled()
  signal cursorRequested()
  signal expandedControlCursorRequested(int index)

  property bool expanded: false
  property int expandedControlCursorIndex: -1
  readonly property int expandedControlCount: (row.domain === "climate"
    || row.domain === "sensor")
    && expansion.item !== null ? expansion.item.selectorCount : 0
  readonly property bool expandedControlPopupOpen: row.domain === "climate"
    && expansion.item !== null && expansion.item.popupOpen

  function activateExpandedControl(index) {
    if ((row.domain !== "climate" && row.domain !== "sensor")
        || expansion.item === null) return false
    return expansion.item.activateSelector(index)
  }

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string family: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property color inactive: Qt.darker(fg, 1.5)
  readonly property bool roomReading: row.rowKind === "room_reading"
  readonly property bool roomPinned: row.roomReading && row.hass !== null
    && row.hass.isRoomReadingPinned(row.roomDeviceId)
  readonly property bool entityPinned: !row.roomReading && row.hass !== null
    && row.hass.isEntityPinned(row.entityId)
  readonly property bool pinned: row.roomPinned || row.entityPinned
  readonly property bool pinPreview: row.expandable && row.hass !== null
    && row.hass.showPanelPinOnHover && rowHover.hovered
  readonly property bool panelActionsVisible: rowHover.hovered
  readonly property string actionEntityId: row.roomReading
    ? row.controlEntityId : row.entityId
  readonly property bool barDataEligible: !row.roomReading
    && Model.barDataEligible(row.entity)
  readonly property var barEntry: BarData.entityEntry(row.entityId)
  readonly property int barConfigRevision: row.bar
    && row.bar.barConfigSerial !== undefined ? row.bar.barConfigSerial : 0
  readonly property bool barInBar: {
    row.barConfigRevision
    var config = row.bar && row.bar.shell ? row.bar.shell.shellConfig : null
    return BarData.contains(config, row.barEntry)
  }

  function toggleBarData() {
    if (!row.bar || !row.bar.shell
        || typeof row.bar.shell.mutateShellConfig !== "function") return
    var remove = row.barInBar
    var target = row.barEntry
    row.bar.shell.mutateShellConfig(function(config) {
      if (remove) BarData.remove(config, target)
      else BarData.add(config, target)
    })
  }

  foreground: fg
  // A fill of its own, or the controls run into the next device.
  current: expanded
  implicitHeight: layout.implicitHeight + Style.spacing.rowPaddingX

  readonly property bool actionable: available
    && (control !== "none" || expandable)

  readonly property string actionTooltip: {
    if (!actionable) return ""
    if (expandable) {
      if (row.domain === "sensor") return row.expanded ? "Collapse" : "Show graph"
      return row.expanded ? "Collapse" : "Show controls"
    }
    switch (control) {
    case "toggle": return isOn ? "Turn off" : "Turn on"
    case "lock": return isOn ? "Unlock" : "Lock"
    case "activate": return "Activate"
    default: return ""
    }
  }

  function bodyClicked() {
    if (!hass || !available) return
    if (expandable) expandToggled()
    else activate()
  }

  // Keyboard Enter. Stays on/off, because `e` already expands.
  function activate() {
    if (!hass || !available) return
    switch (control) {
    case "toggle": hass.toggleEntity(actionEntityId); break
    case "lock": hass.setLock(actionEntityId, !isOn); break
    case "activate": hass.activateScene(actionEntityId); break
    default: if (expandable) expandToggled()
    }
  }

  // stateRevision also re-evaluates bindings after nested attributes change.
  readonly property var entity: {
    if (!hass) return null
    hass.stateRevision
    return hass.entityFor(actionEntityId)
  }

  HoverHandler { id: rowHover }

  // Declared first so the buttons above keep their own clicks.
  MouseArea {
    id: rowMouse
    z: 0
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: row.actionable ? Qt.PointingHandCursor : Qt.ArrowCursor
    onContainsMouseChanged: if (containsMouse) row.cursorRequested()
    onClicked: row.bodyClicked()
  }

  PanelToolTip {
    visible: row.actionTooltip !== "" && rowMouse.containsMouse
    text: row.actionTooltip
    fontFamily: row.family
  }

  Column {
    id: layout
    z: 1
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.spacing.xl
    anchors.rightMargin: Style.spacing.xl
    spacing: Style.spacing.lg

    // ---------- main line ----------
    Item {
      id: entityHeader
      visible: !row.roomReading
      height: visible ? implicitHeight : 0
      width: parent.width
      implicitHeight: Math.max(glyph.implicitHeight, labels.implicitHeight,
                               controlSlot.implicitHeight)

      Text {
        textFormat: Text.PlainText
        id: glyph
        z: 30
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        visible: row.showIcon
        width: row.showIcon ? implicitWidth : 0
        text: row.icon
        color: row.available && row.isOn ? row.fg : row.inactive
        opacity: row.pinPreview ? 0.0 : 1.0
        font.family: row.family
        font.pixelSize: Style.font.heading
      }

      BorderSurface {
        z: 29
        anchors.centerIn: glyph
        width: Math.max(glyph.implicitWidth, Style.space(18))
        height: Style.space(22)
        radius: Style.cornerRadius
        visible: row.showIcon && row.pinPreview
        color: row.entityPinned
          ? Style.selectedFillFor(row.fg, Color.accent)
          : Style.hoverFillFor(row.fg, row.dim)
        borderSpec: row.entityPinned
          ? Border.controlSpec("selected", row.fg, Color.accent) : Border.none()
      }

      Text {
        textFormat: Text.PlainText
        id: pinGlyph
        z: 30
        anchors.centerIn: glyph
        visible: row.showIcon && row.pinPreview
        text: ""                             // Font Awesome thumb tack
        color: row.entityPinned ? Color.accent : row.dim
        font.family: row.family
        font.pixelSize: Style.font.heading
      }

      MouseArea {
        id: glyphPinMouse
        z: 31
        anchors.centerIn: glyph
        width: Math.max(glyph.implicitWidth, Style.space(22))
        height: Style.space(22)
        enabled: row.showIcon && row.expandable && row.hass !== null
          && row.hass.showPanelPinOnHover
        hoverEnabled: true
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: row.hass.toggleEntityPinned(row.entityId)
      }

      PanelToolTip {
        visible: glyphPinMouse.containsMouse
        text: row.entityPinned ? "Unpin expanded view" : "Pin expanded view"
        fontFamily: row.family
      }

      Column {
        id: labels
        anchors.left: glyph.right
        anchors.leftMargin: row.showIcon ? Style.spacing.xl : Style.spacing.sm
        anchors.right: controlSlot.left
        anchors.rightMargin: Style.spacing.lg
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xxs

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: row.name
          color: row.available ? row.fg : row.inactive
          font.family: row.family
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: row.subtitle.length > 0
          text: row.subtitle
          color: row.dim
          font.family: row.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      // ---------- primary control + expander ----------
      Item {
        id: controlSlot
        z: 20
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(54 + 22 + 22) + Style.spacing.sm * 2
        height: Style.space(32)
        readonly property real chevronInkLeft: entityExpandSlot.x
          + (entityExpandSlot.width - entityChevronMetrics.advanceWidth) / 2
          + entityChevronMetrics.tightBoundingRect.x
        readonly property real barInkTarget: ((entityPrimarySlot.x
          + entityPrimarySlot.width) + chevronInkLeft) / 2

        TextMetrics {
          id: entityBarMetrics
          font.family: row.family
          font.pixelSize: Style.font.icon
          text: row.barInBar ? "−" : "+"
        }

        TextMetrics {
          id: entityChevronMetrics
          font.family: row.family
          font.pixelSize: Style.font.icon
          text: row.expanded ? "󰅃" : "󰅀"
        }

        Item {
          id: entityPrimarySlot
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(54)
          height: Style.space(32)

          Text {
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: row.control === "none"
            text: row.badge
            color: row.dim
            font.family: row.family
            font.pixelSize: Style.font.caption
            font.bold: false
          }

          Text {
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: row.control === "activate"
            text: "󰐊"                        // md-play
            color: row.available ? row.fg : row.inactive
            font.family: row.family
            font.pixelSize: Style.font.heading
          }

          ToggleSwitch {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: row.control === "toggle" || row.control === "lock"
            checked: row.isOn
            busy: row.pending
            interactive: true
            cursorRing: false
            foreground: row.fg
            onToggled: {
              if (!row.hass || !row.available) return
              if (row.control === "lock") row.hass.setLock(row.actionEntityId, !row.isOn)
              else row.hass.toggleEntity(row.actionEntityId)
            }
          }
        }

        Item {
          id: entityBarSlot
          anchors.left: entityPrimarySlot.right
          anchors.right: entityExpandSlot.left
          anchors.verticalCenter: parent.verticalCenter
          height: Style.space(32)

          PanelActionButton {
            anchors.verticalCenter: parent.verticalCenter
            x: controlSlot.barInkTarget - entityBarSlot.x - width / 2
              - (entityBarMetrics.tightBoundingRect.x
                + entityBarMetrics.tightBoundingRect.width / 2
                - entityBarMetrics.advanceWidth / 2)
            visible: row.barDataEligible && row.panelActionsVisible
            size: Style.space(20)
            iconText: row.barInBar ? "−" : "+"
            tooltipText: row.barInBar
              ? "Remove from the bar" : "Add to the bar"
            foreground: row.barInBar ? Color.accent : row.fg
            hoverColor: row.barInBar ? Color.accent : row.fg
            fontFamily: row.family
            onClicked: row.toggleBarData()
          }
        }

        Item {
          id: entityExpandSlot
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(22)
          height: Style.space(32)

          PanelActionButton {
            anchors.centerIn: parent
            visible: row.expandable || row.reserveExpandSlot
            enabled: row.expandable
            opacity: row.expandable ? 1.0 : 0.0
            iconText: row.expanded ? "󰅃" : "󰅀" // md-chevron_up / md-chevron_down
            tooltipText: row.expanded ? "Collapse"
              : (row.domain === "sensor" ? "Show graph" : "Show controls")
            foreground: row.dim
            fontFamily: row.family
            onClicked: row.expandToggled()
          }
        }
      }
    }

    Loader {
      id: roomReadingCard
      width: parent.width
      active: row.roomReading && row.hass !== null
      visible: active

      sourceComponent: Component {
        RoomReadingsCard {
          hass: row.hass
          deviceId: row.roomDeviceId
          bar: row.bar
          expanded: row.expanded
          pinned: row.roomPinned
          rowHovered: rowHover.hovered
          showIcon: row.showIcon
          showPanelPinOnHover: row.hass.showPanelPinOnHover
          onExpansionRequested: row.expandToggled()
          onPinRequested: row.hass.toggleRoomReadingPinned(row.roomDeviceId)
        }
      }
    }

    PanelSeparator {
      width: parent.width
      visible: expansion.active
      foreground: row.fg
    }

    // ---------- expanded controls ----------
    Loader {
      id: expansion
      width: parent.width
      // Unloaded on collapse so sliders and timers do not live on.
      active: row.expanded && row.expandable && row.hass !== null
      visible: active

      sourceComponent: {
        if (!row.expandable) return null
        switch (row.domain) {
        case "light": return lightControls
        case "media_player": return mediaControls
        case "climate": return climateControls
        case "cover": return coverControls
        case "sensor": return sensorControls
        default: return null
        }
      }
    }
  }

  Component {
    id: lightControls
    LightControls {
      hass: row.hass; entityId: row.entityId; entity: row.entity; bar: row.bar
    }
  }

  Component {
    id: mediaControls
    MediaControls {
      hass: row.hass; entityId: row.entityId; entity: row.entity; bar: row.bar
    }
  }

  Component {
    id: climateControls
    ClimateControls {
      hass: row.hass; entityId: row.entityId; entity: row.entity; bar: row.bar
      selectorCursorIndex: row.expandedControlCursorIndex
      onSelectorCursorRequested: function(index) {
        row.expandedControlCursorRequested(index)
      }
    }
  }

  Component {
    id: coverControls
    CoverControls {
      hass: row.hass; entityId: row.entityId; entity: row.entity; bar: row.bar
    }
  }

  Component {
    id: sensorControls
    SensorControls {
      hass: row.hass; entityId: row.entityId; entity: row.entity; bar: row.bar
      selectorCursorIndex: row.expandedControlCursorIndex
      onSelectorCursorRequested: function(index) {
        row.expandedControlCursorRequested(index)
      }
    }
  }
}

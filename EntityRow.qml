import QtQuick
import qs.Ui
import qs.Commons
import "controls"
import "Model.js" as Model

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

  property var service: null
  property QtObject bar: null
  property bool showIcon: true
  // Per-list: reserving always pushes every switch a chevron's width off the
  // edge, reserving never leaves them ragged.
  property bool reserveExpandSlot: false

  signal expandToggled()
  signal cursorRequested()

  property bool expanded: false

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string family: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property color inactive: Qt.darker(fg, 1.5)

  foreground: fg
  // A fill of its own, or the controls run into the next device.
  current: expanded
  implicitHeight: layout.implicitHeight + Style.spacing.rowPaddingX

  readonly property bool actionable: available
    && (control !== "none" || expandable)

  readonly property string actionTooltip: {
    if (!actionable) return ""
    if (expandable) return row.expanded ? "Collapse" : "Show controls"
    switch (control) {
    case "toggle": return isOn ? "Turn off" : "Turn on"
    case "lock": return isOn ? "Unlock" : "Lock"
    case "activate": return "Activate"
    default: return ""
    }
  }

  function bodyClicked() {
    if (!service || !available) return
    if (expandable) expandToggled()
    else activate()
  }

  // Keyboard Enter. Stays on/off, because `e` already expands.
  function activate() {
    if (!service || !available) return
    switch (control) {
    case "toggle": service.toggleEntity(entityId); break
    case "lock": service.setLock(entityId, !isOn); break
    case "activate": service.activateScene(entityId); break
    default: if (expandable) expandToggled()
    }
  }

  // stateRevision also re-evaluates bindings after nested attributes change.
  readonly property var entity: {
    if (!service) return null
    service.stateRevision
    return service.entityFor(entityId)
  }

  // Only the row itself needs raw capability flags — the projected `control`/
  // `expandable` strings above cover every other domain. Currently just
  // cover's inline up/stop/down buttons.
  readonly property var capabilities: Model.capabilitiesFor(row.entity)

  // Declared first so the buttons above keep their own clicks.
  MouseArea {
    id: rowMouse
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
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.spacing.xl
    anchors.rightMargin: Style.spacing.xl
    spacing: Style.spacing.lg

    // ---------- main line ----------
    Item {
      width: parent.width
      implicitHeight: Math.max(glyph.implicitHeight, labels.implicitHeight,
                               controlSlot.implicitHeight)

      Text {
        textFormat: Text.PlainText
        id: glyph
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        visible: row.showIcon
        width: row.showIcon ? implicitWidth : 0
        text: row.icon
        color: row.available && row.isOn ? row.fg : row.inactive
        font.family: row.family
        font.pixelSize: Style.font.heading
      }

      Column {
        id: labels
        anchors.left: glyph.right
        anchors.leftMargin: row.showIcon ? Style.spacing.xl : 0
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
      Row {
        id: controlSlot
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.md

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          // A cover's position is shown by its up/stop/down buttons being
          // there at all, not by also repeating it as text next to them.
          visible: row.control === "none" && row.domain !== "cover"
          text: row.badge
          color: row.dim
          font.family: row.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        CoverControls {
          anchors.verticalCenter: parent.verticalCenter
          visible: row.domain === "cover" && row.available
          service: row.service
          entityId: row.entityId
          entity: row.entity
          bar: row.bar
        }

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          visible: row.control === "activate"
          text: "󰐊"                          // md-play
          color: row.available ? row.fg : row.inactive
          font.family: row.family
          font.pixelSize: Style.font.heading
        }

        ToggleSwitch {
          anchors.verticalCenter: parent.verticalCenter
          visible: row.control === "toggle" || row.control === "lock"
          checked: row.isOn
          busy: row.pending
          // cursorRing follows `interactive`; left on it draws a ring on top
          // of the row's own highlight.
          interactive: true
          cursorRing: false
          foreground: row.fg
          onToggled: {
            if (!row.service || !row.available) return
            if (row.control === "lock") row.service.setLock(row.entityId, !row.isOn)
            else row.service.toggleEntity(row.entityId)
          }
        }

        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          visible: row.expandable || row.reserveExpandSlot
          enabled: row.expandable
          opacity: row.expandable ? 1.0 : 0.0
          iconText: row.expanded ? "󰅃" : "󰅀"   // md-chevron_up / md-chevron_down
          tooltipText: row.expanded ? "Collapse" : "Show controls"
          foreground: row.dim
          fontFamily: row.family
          onClicked: row.expandToggled()
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
      active: row.expanded && row.expandable && row.service !== null
      visible: active

      sourceComponent: {
        if (!row.expandable) return null
        switch (row.domain) {
        case "light": return lightControls
        case "media_player": return mediaControls
        case "climate": return climateControls
        default: return null
        }
      }
    }
  }

  Component {
    id: lightControls
    LightControls {
      service: row.service; entityId: row.entityId; entity: row.entity; bar: row.bar
    }
  }

  Component {
    id: mediaControls
    MediaControls {
      service: row.service; entityId: row.entityId; entity: row.entity; bar: row.bar
    }
  }

  Component {
    id: climateControls
    ClimateControls {
      service: row.service; entityId: row.entityId; entity: row.entity; bar: row.bar
    }
  }
}

import QtQuick
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "../Model.js" as Model

// Open / Close / Stop for a cover, plus a position slider for one that
// advertises set_cover_position.
Column {
  id: control

  required property var hass
  required property string entityId
  property var entity: null
  property QtObject bar: null

  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property string family: bar ? bar.fontFamily : Style.font.family
  readonly property var capabilities: Model.capabilitiesFor(entity)

  readonly property real position: {
    var value = entity ? Model.coverPositionPercent(entity) : -1
    return value < 0 ? 0 : value
  }

  // Shown until the cover reports it back; binding to `position` would snap
  // the knob out from under the cursor.
  PendingValue { id: pendingPosition }
  readonly property real shownPosition: pendingPosition.active
    ? pendingPosition.value : control.position

  onEntityChanged: {
    if (pendingPosition.active
        && Model.coverPositionSettled(control.entity, pendingPosition.value)) {
      pendingPosition.clear()
    }
  }

  Connections {
    target: control.hass
    function onCommandFailed(tag) { pendingPosition.rollback(tag) }
  }

  spacing: Style.spacing.lg

  Row {
    id: row
    spacing: Style.space(6)

    PanelActionButton {
      visible: control.capabilities.coverOpen
      iconText: "󰜷"                   // md-arrow_up_bold
      tooltipText: "Open"
      foreground: control.fg
      fontFamily: control.family
      onClicked: control.hass.coverAction(control.entityId, "open_cover")
    }

    PanelActionButton {
      visible: control.capabilities.coverStop
      iconText: "󰓛"                   // md-stop
      tooltipText: "Stop"
      foreground: control.fg
      fontFamily: control.family
      onClicked: control.hass.coverAction(control.entityId, "stop_cover")
    }

    PanelActionButton {
      visible: control.capabilities.coverClose
      iconText: "󰜮"                   // md-arrow_down_bold
      tooltipText: "Close"
      foreground: control.fg
      fontFamily: control.family
      onClicked: control.hass.coverAction(control.entityId, "close_cover")
    }
  }

  SliderRow {
    id: positionSlider
    width: parent.width
    visible: control.capabilities.coverPosition
    bar: control.bar
    label: "POSITION"
    valueText: Math.round(control.shownPosition) + "%"
    value: control.shownPosition
    minimum: 0
    maximum: 100
    step: 1

    onMoved: function(value) { pendingPosition.hold(value) }
    // On release only: a call per pixel floods Home Assistant and makes the
    // cover stutter trying to follow.
    onReleased: function(value) {
      var percent = Math.round(value)
      var tag = control.hass.setCoverPosition(control.entityId, percent)
      if (tag) pendingPosition.commit(percent, tag)
      else pendingPosition.clear()
    }
    onCanceled: pendingPosition.clear()
  }
}

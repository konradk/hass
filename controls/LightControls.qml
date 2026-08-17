import QtQuick
import qs.Commons
import "../Model.js" as Model

// Brightness for a dimmable light, and colour for one that can render it.
// Each section is built only when the light advertises the capability, so an
// on/off-only bulb that somehow expands still shows nothing it cannot do.
Column {
  id: control

  required property var hass
  required property string entityId
  property var entity: null
  property QtObject bar: null

  readonly property var caps: Model.capabilitiesFor(control.entity)

  readonly property real level: {
    var value = entity ? Model.brightnessPercent(entity) : -1
    return value < 0 ? 0 : value
  }

  // Shown until the light reports it back; binding to `level` would snap the
  // knob out from under the cursor.
  PendingValue { id: pendingBrightness }
  readonly property real shownValue: pendingBrightness.active
    ? pendingBrightness.value : level

  onEntityChanged: {
    if (pendingBrightness.active
        && Model.brightnessSettled(control.entity, pendingBrightness.value)) {
      pendingBrightness.clear()
    }
  }

  Connections {
    target: control.hass
    function onCommandFailed(tag) { pendingBrightness.rollback(tag) }
  }

  spacing: Style.spacing.lg

  SliderRow {
    id: brightness
    width: parent.width
    visible: control.caps.brightness
    bar: control.bar
    label: "BRIGHTNESS"
    valueText: Math.round(control.shownValue) + "%"
    value: control.shownValue
    minimum: 0
    maximum: 100
    step: 1

    onMoved: function(value) { pendingBrightness.hold(value) }
    // On release only: a call per pixel floods Home Assistant and makes the
    // light stutter trying to follow.
    onReleased: function(value) {
      // setBrightness sends whole percent; the value held on screen must match.
      var percent = Math.round(value)
      var tag = control.hass.setBrightness(control.entityId, percent)
      if (tag) pendingBrightness.commit(percent, tag)
      else pendingBrightness.clear()
    }
    onCanceled: pendingBrightness.clear()
  }

  ColorControls {
    width: parent.width
    hass: control.hass
    entityId: control.entityId
    entity: control.entity
    caps: control.caps
    bar: control.bar
  }
}

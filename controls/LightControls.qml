import QtQuick
import qs.Commons
import "../Model.js" as Model

// Brightness for a dimmable light.
Item {
  id: control

  required property var service
  required property string entityId
  property var entity: null
  property QtObject bar: null

  implicitHeight: brightness.implicitHeight

  readonly property real level: {
    var value = entity ? Model.brightnessPercent(entity) : -1
    return value < 0 ? 0 : value
  }

  // The slider owns the number while dragging; binding to `level` would snap
  // the knob back under the finger between state updates.
  property real localValue: -1
  readonly property real shownValue: localValue >= 0 ? localValue : level

  SliderRow {
    id: brightness
    width: parent.width
    bar: control.bar
    label: "BRIGHTNESS"
    valueText: Math.round(control.shownValue) + "%"
    value: control.shownValue
    minimum: 0
    maximum: 100
    step: 1

    onMoved: function(value) { control.localValue = value }
    // On release only: a command per pixel floods the Miniserver and makes
    // the light stutter trying to follow.
    onReleased: function(value) {
      control.localValue = -1
      control.service.setBrightness(control.entityId, value)
    }
  }
}

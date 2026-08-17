import QtQuick
import qs.Ui
import qs.Commons
import "../Model.js" as Model

// Target temperature for a climate entity. Two shapes: a single setpoint, or
// a low/high band when the thermostat reports one.
Item {
  id: control

  required property var service
  required property string entityId
  property var entity: null
  property QtObject bar: null

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string family: bar ? bar.fontFamily : Style.font.family

  implicitHeight: column.implicitHeight

  // IRoomControllerV2 is always Celsius; the service exposes a constant unit.
  readonly property string instanceUnit: service ? service.temperatureUnit : ""

  readonly property string unit: entity
    ? Model.temperatureUnit(entity, instanceUnit) : ""
  readonly property real step: entity
    ? Model.temperatureStep(entity, instanceUnit) : 0.5
  readonly property var range: entity
    ? Model.temperatureRange(entity, instanceUnit) : ({ min: 5, max: 35 })
  readonly property var capabilities: Model.capabilitiesFor(entity)
  readonly property bool ranged: capabilities.climateRange

  function attr(key, fallback) {
    if (!entity || !entity.attributes) return fallback
    var value = entity.attributes[key]
    return typeof value === "number" ? value : fallback
  }

  property real localTarget: -999
  property real localLow: -999
  property real localHigh: -999

  readonly property real target: localTarget > -999
    ? localTarget : attr("temperature", range.min)
  readonly property real low: localLow > -999
    ? localLow : attr("target_temp_low", range.min)
  readonly property real high: localHigh > -999
    ? localHigh : attr("target_temp_high", range.max)

  function clamp(value) {
    return Math.max(range.min, Math.min(range.max, value))
  }

  function format(value) {
    return Model.formatTemp(value, control.unit)
  }

  function commitTarget(value) {
    control.localTarget = -999
    control.service.setClimateTemperature(control.entityId, control.clamp(value),
                                          undefined, undefined)
  }

  // Loxone's IRoomControllerV2 has one comfort setpoint, not a low/high band —
  // this stays dead code (`control.ranged` is always false) until a control
  // type that reports one exists, matching MediaControls' "not wired up yet".
  function commitRange(changedLow, value) {
    var low = changedLow ? control.clamp(value) : control.low
    var high = changedLow ? control.high : control.clamp(value)
    var normalizedLow = Math.min(low, high)
    var normalizedHigh = Math.max(low, high)
    control.localLow = -999
    control.localHigh = -999
    control.service.setClimateTemperature(control.entityId, undefined,
                                          normalizedLow, normalizedHigh)
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.spacing.xl

    // ---------- single setpoint ----------
    Column {
      visible: control.capabilities.climateTarget && !control.ranged
      width: parent.width
      spacing: Style.spacing.sm

      SliderRow {
        id: targetSlider
        width: parent.width
        bar: control.bar
        label: "TARGET"
        valueText: control.format(control.target)
        value: control.target
        minimum: control.range.min
        maximum: control.range.max
        step: control.step

        onMoved: function(value) { control.localTarget = value }
        onReleased: function(value) { control.commitTarget(value) }
      }

      // Nudge buttons under the track, for a precise half-degree that is hard
      // to hit by dragging.
      Row {
        spacing: Style.spacing.md

        PanelActionButton {
          iconText: "󰍴"                  // md-minus
          tooltipText: "Cooler"
          foreground: control.fg
          fontFamily: control.family
          onClicked: control.commitTarget(control.target - control.step)
        }

        PanelActionButton {
          iconText: "󰐕"                  // md-plus
          tooltipText: "Warmer"
          foreground: control.fg
          fontFamily: control.family
          onClicked: control.commitTarget(control.target + control.step)
        }
      }
    }

    // ---------- low / high band ----------
    SliderRow {
      visible: control.ranged
      width: parent.width
      bar: control.bar
      label: "LOW"
      valueText: control.format(control.low)
      value: control.low
      minimum: control.range.min
      maximum: Math.min(control.range.max, control.high)
      step: control.step

      onMoved: function(value) { control.localLow = value }
      onReleased: function(value) { control.commitRange(true, value) }
    }

    SliderRow {
      visible: control.ranged
      width: parent.width
      bar: control.bar
      label: "HIGH"
      valueText: control.format(control.high)
      value: control.high
      minimum: Math.max(control.range.min, control.low)
      maximum: control.range.max
      step: control.step

      onMoved: function(value) { control.localHigh = value }
      onReleased: function(value) { control.commitRange(false, value) }
    }
  }
}

import QtQuick
import QtQuick.Controls
import qs.Ui
import qs.Commons
import "../Model.js" as Model

// Target temperature for a climate entity. Two shapes: a single setpoint, or
// a low/high band when the thermostat reports one.
Item {
  id: control

  required property var hass
  required property string entityId
  property var entity: null
  property QtObject bar: null

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string family: bar ? bar.fontFamily : Style.font.family

  implicitHeight: column.implicitHeight

  // Climate entities carry no unit; the instance-wide one comes from the
  // service, which got it from the bridge's get_config.
  readonly property string instanceUnit: hass ? hass.temperatureUnit : ""

  readonly property string unit: entity
    ? Model.temperatureUnit(entity, instanceUnit) : ""
  readonly property real step: entity
    ? Model.temperatureStep(entity, instanceUnit) : 0.5
  readonly property var range: entity
    ? Model.temperatureRange(entity, instanceUnit) : ({ min: 5, max: 35 })
  readonly property var capabilities: Model.capabilitiesFor(entity)
  readonly property bool ranged: capabilities.climateRange
  readonly property var hvacModes: entity ? Model.climateHvacModes(entity) : []
  readonly property string hvacMode: entity ? Model.climateHvacMode(entity) : ""
  readonly property var fanModes: entity ? Model.climateFanModes(entity) : []
  readonly property string fanMode: entity ? Model.climateFanMode(entity) : ""

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
    control.hass.setClimateTemperature(control.entityId, control.clamp(value),
                                       undefined, undefined)
  }

  function commitRange(changedLow, value) {
    // Send both ends together: Home Assistant's set_temperature rejects a
    // partial range, and the untouched end must keep its current value rather
    // than fall back to a default.
    var low = changedLow ? control.clamp(value) : control.low
    var high = changedLow ? control.high : control.clamp(value)
    var normalizedLow = Math.min(low, high)
    var normalizedHigh = Math.max(low, high)
    control.localLow = -999
    control.localHigh = -999
    control.hass.setClimateTemperature(control.entityId, undefined,
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

    Column {
      visible: control.capabilities.climateFanMode
      width: parent.width
      spacing: Style.spacing.sm

      Text {
        textFormat: Text.PlainText
        text: "FAN"
        color: control.fg
        font.family: control.family
        font.pixelSize: Style.font.caption
        font.weight: Font.Medium
      }

      // ButtonGroup is a non-wrapping row. Keep every integration-provided
      // mode reachable instead of letting a long list escape the panel.
      ScrollView {
        width: parent.width
        implicitHeight: fanModeGroup.implicitHeight
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: ScrollBar.AlwaysOff

        ButtonGroup {
          id: fanModeGroup
          focusable: false
          foreground: control.fg
          fontFamily: control.family
          fontSize: Style.font.caption
          options: control.fanModes.map(function(mode) {
            return { value: mode, label: Model.capitalize(mode) }
          })
          value: control.fanMode
          onChanged: function(mode) {
            // A state update also changes value. It is already authoritative,
            // so only dispatch a user selection that differs from that state.
            if (mode !== control.fanMode) {
              control.hass.setClimateFanMode(control.entityId, mode)
            }
          }
        }
      }
    }
    Column {
      visible: control.capabilities.climateHvacMode
      width: parent.width
      spacing: Style.spacing.sm

      Text {
        textFormat: Text.PlainText
        text: "MODE"
        color: control.fg
        font.family: control.family
        font.pixelSize: Style.font.caption
        font.weight: Font.Medium
      }

      // HVAC modes are integration-defined. Keep the selector horizontal so
      // every advertised mode remains reachable in a narrow panel.
      ScrollView {
        width: parent.width
        implicitHeight: hvacModeGroup.implicitHeight
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: ScrollBar.AlwaysOff

        ButtonGroup {
          id: hvacModeGroup
          focusable: false
          foreground: control.fg
          fontFamily: control.family
          fontSize: Style.font.caption
          options: control.hvacModes.map(function(mode) {
            return { value: mode, label: Model.capitalize(mode) }
          })
          value: control.hvacMode
          onChanged: function(mode) {
            // Incoming state is authoritative. Only a different user choice
            // needs the typed service call.
            if (mode !== control.hvacMode) {
              control.hass.setClimateHvacMode(control.entityId, mode)
            }
          }
        }
      }
    }
  }
}

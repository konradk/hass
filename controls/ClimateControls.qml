import QtQuick
import qs.Ui
import qs.Commons
import "../Model.js" as Model

// Temperature and mode controls for a climate entity. Temperature can be a
// single setpoint or a low/high band.
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
  readonly property var presetModes: entity ? Model.climatePresetModes(entity) : []
  readonly property string presetMode: entity ? Model.climatePresetMode(entity) : ""
  readonly property var swingModes: entity ? Model.climateSwingModes(entity) : []
  readonly property string swingMode: entity ? Model.climateSwingMode(entity) : ""
  readonly property bool popupOpen: fanModeDropdown.popupOpen
    || hvacModeDropdown.popupOpen || presetModeDropdown.popupOpen
    || swingModeDropdown.popupOpen
  property int selectorCursorIndex: -1
  readonly property var activeSelectors: {
    var selectors = [
      fanModeDropdown, hvacModeDropdown, presetModeDropdown, swingModeDropdown
    ]
    var active = []
    for (var i = 0; i < selectors.length; i++) {
      if (selectors[i].visible) active.push(selectors[i])
    }
    return active
  }
  readonly property int selectorCount: activeSelectors.length

  signal selectorCursorRequested(int index)

  function selectorIndex(selector) {
    return control.activeSelectors.indexOf(selector)
  }

  function activateSelector(index) {
    if (index < 0 || index >= control.activeSelectors.length) return false
    control.activeSelectors[index].toggle()
    return true
  }

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

    Row {
      visible: control.capabilities.climateFanMode
        || control.capabilities.climateHvacMode
      width: parent.width
      spacing: Style.spacing.md

      readonly property bool bothSelectors: control.capabilities.climateFanMode
        && control.capabilities.climateHvacMode

      ClimateModeSelector {
        id: fanModeDropdown
        hasCursor: control.selectorCursorIndex
          === control.selectorIndex(fanModeDropdown)
        visible: control.capabilities.climateFanMode
        width: parent.bothSelectors
          ? (parent.width - parent.spacing) / 2 : parent.width
        label: "FAN"
        authoritativeValue: control.fanMode
        modes: control.fanModes
        modeLabel: function(mode) { return Model.climateFanModeLabel(mode) }
        foreground: control.fg
        fontFamily: control.family
        onModeSelected: function(mode) {
          control.hass.setClimateFanMode(control.entityId, mode)
        }
        onSelectorHovered: {
          control.selectorCursorRequested(control.selectorIndex(fanModeDropdown))
        }
      }

      ClimateModeSelector {
        id: hvacModeDropdown
        hasCursor: control.selectorCursorIndex
          === control.selectorIndex(hvacModeDropdown)
        visible: control.capabilities.climateHvacMode
        width: parent.bothSelectors
          ? (parent.width - parent.spacing) / 2 : parent.width
        label: "MODE"
        authoritativeValue: control.hvacMode
        modes: control.hvacModes
        modeLabel: function(mode) { return Model.climateHvacModeLabel(mode) }
        foreground: control.fg
        fontFamily: control.family
        onModeSelected: function(mode) {
          control.hass.setClimateHvacMode(control.entityId, mode)
        }
        onSelectorHovered: {
          control.selectorCursorRequested(control.selectorIndex(hvacModeDropdown))
        }
      }
    }

    Row {
      visible: control.capabilities.climatePresetMode
        || control.capabilities.climateSwingMode
      width: parent.width
      spacing: Style.spacing.md

      readonly property bool bothSelectors: control.capabilities.climatePresetMode
        && control.capabilities.climateSwingMode

      ClimateModeSelector {
        id: presetModeDropdown
        hasCursor: control.selectorCursorIndex
          === control.selectorIndex(presetModeDropdown)
        visible: control.capabilities.climatePresetMode
        width: parent.bothSelectors
          ? (parent.width - parent.spacing) / 2 : parent.width
        label: "PRESET"
        authoritativeValue: control.presetMode
        modes: control.presetModes
        modeLabel: function(mode) { return Model.climatePresetModeLabel(mode) }
        foreground: control.fg
        fontFamily: control.family
        onModeSelected: function(mode) {
          control.hass.setClimatePresetMode(control.entityId, mode)
        }
        onSelectorHovered: {
          control.selectorCursorRequested(control.selectorIndex(presetModeDropdown))
        }
      }

      ClimateModeSelector {
        id: swingModeDropdown
        hasCursor: control.selectorCursorIndex
          === control.selectorIndex(swingModeDropdown)
        visible: control.capabilities.climateSwingMode
        width: parent.bothSelectors
          ? (parent.width - parent.spacing) / 2 : parent.width
        label: "SWING"
        authoritativeValue: control.swingMode
        modes: control.swingModes
        modeLabel: function(mode) { return Model.climateSwingModeLabel(mode) }
        foreground: control.fg
        fontFamily: control.family
        onModeSelected: function(mode) {
          control.hass.setClimateSwingMode(control.entityId, mode)
        }
        onSelectorHovered: {
          control.selectorCursorRequested(control.selectorIndex(swingModeDropdown))
        }
      }
    }
  }
}

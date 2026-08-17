import QtQuick
import qs.Ui
import qs.Commons
import "../Model.js" as Model

// Labelled slider in the shape the audio panel uses: a section header on the
// left, the live value on the right, and the track on its own line below at
// full width. Brightness, volume and temperature all render through this so
// they cannot drift apart.
Column {
  id: sliderRow

  property QtObject bar: null
  property string label: ""
  property string valueText: ""
  property real value: 0
  property real minimum: 0
  property real maximum: 1
  property real step: 0.05
  // Off by default: quantizing a drag is right only where the step is the
  // device's own granularity. Where it is a UI nudge size it just makes the
  // track coarse — a 5% volume step leaves twenty-one reachable positions.
  property bool snap: false
  property real stepBase: minimum

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string family: bar ? bar.fontFamily : Style.font.family

  signal moved(real value)
  signal released(real value)
  signal canceled()

  spacing: Style.spacing.sm

  Item {
    width: parent.width
    implicitHeight: Math.max(header.implicitHeight, valueLabel.implicitHeight)

    PanelSectionHeader {
      id: header
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: sliderRow.label
      foreground: sliderRow.fg
      fontFamily: sliderRow.family
    }

    Text {
      textFormat: Text.PlainText
      id: valueLabel
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      text: sliderRow.valueText
      color: Qt.darker(sliderRow.fg, 1.4)
      font.family: sliderRow.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  // The gesture is handled above PanelSlider rather than by it: the panel list
  // is a Flickable, and a drag that wanders a few pixels off the horizontal is
  // otherwise taken for a scroll, stealing the grab mid-drag. Only the area
  // holding the grab can refuse that, and PanelSlider's is private.
  Item {
    width: parent.width
    implicitHeight: slider.implicitHeight

    PanelSlider {
      id: slider
      anchors.fill: parent
      bar: sliderRow.bar
      minimum: sliderRow.minimum
      maximum: sliderRow.maximum
      step: sliderRow.step
      value: sliderRow.value
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      preventStealing: true

      // Step 0 is snapToStep's pass-through: an unsnapped slider is still clamped.
      function settle(value) {
        return Model.snapToStep(value, sliderRow.stepBase,
                                sliderRow.snap ? sliderRow.step : 0,
                                sliderRow.minimum, sliderRow.maximum)
      }

      function valueAt(x) {
        var span = Math.max(0.0001, sliderRow.maximum - sliderRow.minimum)
        var fraction = width > 0 ? Math.max(0, Math.min(1, x / width)) : 0
        return settle(sliderRow.minimum + fraction * span)
      }

      function track(x) {
        var next = valueAt(x)
        slider.liveValue = next
        sliderRow.moved(next)
      }

      onPressed: function(mouse) {
        slider.dragging = true
        track(mouse.x)
      }
      onPositionChanged: function(mouse) {
        if (slider.dragging) track(mouse.x)
      }
      onReleased: function(mouse) {
        if (!slider.dragging) return
        slider.dragging = false
        sliderRow.released(valueAt(mouse.x))
      }
      onCanceled: {
        slider.dragging = false
        sliderRow.canceled()
      }
      onWheel: function(wheel) {
        var delta = wheel.angleDelta.y > 0 ? sliderRow.step : -sliderRow.step
        var next = settle(sliderRow.value + delta)
        sliderRow.moved(next)
        sliderRow.released(next)
      }
    }
  }
}

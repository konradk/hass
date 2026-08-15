import QtQuick
import qs.Ui
import qs.Commons
import "../Model.js" as Model

// Colour for a colour-capable light: the light's favourite colours, then a
// hue/saturation wheel for anything not among them. Colour temperature is a
// separate channel on the light rather than a saturation of zero, so it keeps
// its own slider and is only built when the light advertises color_temp.
Column {
  id: control

  required property var hass
  required property string entityId
  required property var caps
  property var entity: null
  property QtObject bar: null

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string family: bar ? bar.fontFamily : Style.font.family

  readonly property var liveColor: Model.hsColor(control.entity)
  readonly property bool whiteActive: Model.isColorTempActive(control.entity)

  readonly property var favorites: Model.favoriteColors(
    control.entity, control.hass.savedFavoriteColors[control.entityId])

  // The wheel owns the value while dragging; binding straight to the entity
  // snaps the knob back under the finger between state updates.
  property var localColor: null
  property real localKelvin: -1

  readonly property real shownHue:
    localColor ? localColor.hue : (liveColor ? liveColor.hue : 0)
  // A light showing white has no hue position of its own, so the knob parks
  // at the centre until something is picked.
  readonly property real shownSaturation:
    localColor ? localColor.saturation
               : (whiteActive || !liveColor ? 0 : liveColor.saturation)

  readonly property var kelvinLimits: Model.kelvinRange(control.entity)

  // A light rendering a hue reports no colour temperature at all — Home
  // Assistant nulls it while color_mode is anything but color_temp.
  readonly property real liveKelvin: Model.colorTempKelvin(control.entity)
  readonly property bool hasKelvin: liveKelvin >= 0 || localKelvin >= 0

  readonly property real shownKelvin: {
    if (localKelvin >= 0) return localKelvin
    if (liveKelvin >= 0) return liveKelvin
    // Park mid-range rather than at an end, where a slider with no value
    // behind it would read as a real setting of the coldest white.
    return (control.kelvinLimits.min + control.kelvinLimits.max) / 2
  }

  // Wide enough to survive the rounding on the way to the light and back, and
  // narrow enough that two neighbouring favourites never both light up.
  function matchesFavorite(favorite) {
    if (favorite.kind === "colorTemp") {
      return control.whiteActive
        && Math.abs(favorite.kelvin - control.shownKelvin) < 150
    }
    // Hue is circular: 358 and 2 are four degrees apart, not 356.
    var gap = Math.abs(favorite.hue - control.shownHue) % 360
    return !control.whiteActive
      && Math.min(gap, 360 - gap) < 5
      && Math.abs(favorite.saturation - control.shownSaturation) < 8
  }

  function applyFavorite(favorite) {
    control.localColor = null
    control.localKelvin = -1
    if (favorite.kind === "colorTemp") {
      control.hass.setLightColorTemp(control.entityId, favorite.kelvin)
      return
    }
    control.hass.setLightColor(control.entityId,
                               favorite.hue, favorite.saturation)
  }

  visible: control.caps.color || control.caps.colorTemp
  spacing: Style.spacing.lg

  PanelSectionHeader {
    text: "COLOUR"
    foreground: control.fg
    fontFamily: control.family
  }

  // Centred, and never wider than it is tall, so the wheel stays a circle
  // whatever width the panel is given. Sized from the wheel's actual height,
  // not its implicit one, since the panel width can cap it. The extra gap is
  // for the circle: the column's own spacing reads as tight under a round
  // edge sitting above a row of round swatches.
  Item {
    width: parent.width
    visible: control.caps.color
    implicitHeight: picker.height + Style.spacing.md

    ColorWheel {
      id: picker
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.min(parent.width, implicitWidth)
      height: width
      knobBorder: control.bar ? control.bar.background : Color.background

      hue: control.shownHue
      saturation: control.shownSaturation

      onMoved: function(hue, saturation) {
        control.localColor = { hue: hue, saturation: saturation }
      }
      onReleased: function(hue, saturation) {
        control.localColor = null
        control.hass.setLightColor(control.entityId, hue, saturation)
      }
      onCanceled: control.localColor = null
    }
  }

  Flow {
    width: parent.width
    spacing: Style.spacing.md

    Repeater {
      model: control.favorites

      delegate: Rectangle {
        id: swatch
        required property var modelData

        width: Style.space(22)
        height: Style.space(22)
        radius: width / 2
        color: Qt.rgba(swatch.modelData.rgb[0] / 255,
                       swatch.modelData.rgb[1] / 255,
                       swatch.modelData.rgb[2] / 255, 1)
        border.width: Math.max(1, Style.space(2))
        border.color: control.matchesFavorite(swatch.modelData)
          ? control.fg : "transparent"
        scale: swatchMouse.containsMouse ? 1.15 : 1.0

        Behavior on scale {
          NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
        }

        MouseArea {
          id: swatchMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: control.applyFavorite(swatch.modelData)
        }

        PanelToolTip {
          visible: swatchMouse.containsMouse
          text: swatch.modelData.kind === "colorTemp"
            ? swatch.modelData.kelvin + "K"
            : Math.round(swatch.modelData.hue) + "°, "
              + Math.round(swatch.modelData.saturation) + "%"
          fontFamily: control.family
        }
      }
    }
  }

  SliderRow {
    width: parent.width
    visible: control.caps.colorTemp
    bar: control.bar
    label: "WARMTH"
    valueText: control.hasKelvin ? Math.round(control.shownKelvin) + "K" : "—"
    value: control.shownKelvin
    minimum: control.kelvinLimits.min
    maximum: control.kelvinLimits.max
    step: 50

    onMoved: function(value) { control.localKelvin = value }
    onReleased: function(value) {
      control.localKelvin = -1
      control.hass.setLightColorTemp(control.entityId, value)
    }
  }
}

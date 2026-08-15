import QtQuick
import qs.Ui
import qs.Commons

// Hue/saturation wheel: angle around the centre is hue, distance from it is
// saturation, as in the Home Assistant app.
//
// Canvas rather than a shader, because Qt 6 wants shaders precompiled to .qsb
// and this plugin cannot have a build step. Painted once per resize; after
// that only the knob moves.
Item {
  id: wheel

  property real hue: 0
  property real saturation: 0
  property color knobBorder: Color.background

  // `moved` fires continuously while dragging, `released` once at the end;
  // `canceled` means the grab was taken away and nothing was chosen.
  signal moved(real hue, real saturation)
  signal released(real hue, real saturation)
  signal canceled()

  implicitWidth: Style.space(170)
  implicitHeight: implicitWidth

  readonly property real radius: Math.min(width, height) / 2
  readonly property real knobSize: Math.max(Style.space(14),
                                            Math.round(radius * 0.17))

  Canvas {
    id: face
    anchors.fill: parent
    renderStrategy: Canvas.Threaded

    onPaint: {
      var ctx = getContext("2d")
      var centreX = width / 2
      var centreY = height / 2
      var r = Math.min(centreX, centreY)
      ctx.reset()
      if (r <= 0) return

      // One wedge per degree, each drawn wider than its slice: abutting
      // wedges leave hairline seams once antialiasing has had its say.
      var overlap = 1.5 * Math.PI / 180
      for (var angle = 0; angle < 360; angle++) {
        var start = angle * Math.PI / 180
        ctx.beginPath()
        ctx.moveTo(centreX, centreY)
        ctx.arc(centreX, centreY, r, start, start + overlap)
        ctx.closePath()
        ctx.fillStyle = Qt.hsva(angle / 360, 1, 1, 1)
        ctx.fill()
      }

      // Saturation falls off to white at the centre.
      var wash = ctx.createRadialGradient(centreX, centreY, 0, centreX, centreY, r)
      wash.addColorStop(0, Qt.rgba(1, 1, 1, 1))
      wash.addColorStop(1, Qt.rgba(1, 1, 1, 0))
      ctx.beginPath()
      ctx.arc(centreX, centreY, r, 0, 2 * Math.PI)
      ctx.closePath()
      ctx.fillStyle = wash
      ctx.fill()
    }
  }

  readonly property real knobDistance: (Math.min(100, Math.max(0, saturation)) / 100)
    * wheel.radius
  readonly property real knobAngle: wheel.hue * Math.PI / 180

  Rectangle {
    id: knob
    width: wheel.knobSize
    height: wheel.knobSize
    radius: width / 2
    color: Qt.hsva(wheel.hue / 360, wheel.saturation / 100, 1, 1)
    border.width: Math.max(2, Style.space(2))
    border.color: wheel.knobBorder
    x: wheel.width / 2 + Math.cos(wheel.knobAngle) * wheel.knobDistance - width / 2
    y: wheel.height / 2 + Math.sin(wheel.knobAngle) * wheel.knobDistance - height / 2
    scale: pointer.containsMouse || pointer.pressed ? 1.2 : 1.0

    Behavior on scale {
      NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
    }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    // The panel list is a Flickable; without this it takes the grab as soon as
    // a drag strays off the horizontal and the knob is left behind.
    preventStealing: true

    function distanceFrom(x, y) {
      var dx = x - wheel.width / 2
      var dy = y - wheel.height / 2
      return Math.sqrt(dx * dx + dy * dy)
    }

    // Screen coordinates run y-downwards, which makes an increasing atan2
    // sweep clockwise — the direction the app's wheel runs too.
    function pick(x, y) {
      var angle = Math.atan2(y - wheel.height / 2, x - wheel.width / 2)
        * 180 / Math.PI
      if (angle < 0) angle += 360
      return {
        hue: angle,
        saturation: Math.min(100, wheel.radius > 0
          ? distanceFrom(x, y) / wheel.radius * 100 : 0)
      }
    }

    // The MouseArea is square, so the corners are outside the wheel. A press
    // there is not a colour; a drag that strays out keeps its angle and
    // clamps, which is how a knob dragged past the rim should behave.
    onPressed: function(mouse) {
      if (distanceFrom(mouse.x, mouse.y) > wheel.radius) {
        mouse.accepted = false
        return
      }
      var picked = pick(mouse.x, mouse.y)
      wheel.moved(picked.hue, picked.saturation)
    }
    onPositionChanged: function(mouse) {
      if (!pressed) return
      var picked = pick(mouse.x, mouse.y)
      wheel.moved(picked.hue, picked.saturation)
    }
    onReleased: function(mouse) {
      var picked = pick(mouse.x, mouse.y)
      wheel.released(picked.hue, picked.saturation)
    }
    // Without this a stolen grab strands the caller's local value, freezing
    // the knob at a colour the light is not showing.
    onCanceled: wheel.canceled()
  }
}

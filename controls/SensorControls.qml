import QtQuick
import qs.Ui
import qs.Commons
import "../Model.js" as Model

// Recorder history for a numeric sensor. The chips pick 1h / 3h / 6h / 12h / 1d;
// the canvas draws the samples the service already sanitized.
Item {
  id: control

  required property var hass
  required property string entityId
  property var entity: null
  property QtObject bar: null
  property int selectorCursorIndex: -1
  property int hoverIndex: -1
  property real axisNow: Date.now() / 1000

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string family: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property var windows: Model.HISTORY_HOURS
  property int hours: 1
  readonly property int selectorCount: windows.length
  readonly property bool popupOpen: false

  signal selectorCursorRequested(int index)

  function activateSelector(index) {
    if (index < 0 || index >= control.windows.length) return false
    var next = control.windows[index]
    if (control.hours === next) control.reload()
    else control.hours = next
    return true
  }

  readonly property var snapshot: {
    if (!hass) return null
    hass.historyRevision
    return hass.historyFor(entityId)
  }
  readonly property var points: snapshot && snapshot.points ? snapshot.points : []
  readonly property bool loading: snapshot ? snapshot.loading === true : true
  readonly property string errorText: snapshot && snapshot.error ? String(snapshot.error) : ""
  readonly property string unit: entity
    ? Model.cleaned(Model.attrs(entity).unit_of_measurement) : ""
  readonly property int plotRevision: hass ? hass.historyRevision : 0
  readonly property var hoverPoint: {
    if (hoverIndex < 0 || hoverIndex >= points.length) return null
    return points[hoverIndex]
  }

  onHoursChanged: {
    control.hoverIndex = -1
    control.axisNow = Date.now() / 1000
    control.reload()
  }
  onPlotRevisionChanged: {
    control.axisNow = Date.now() / 1000
    chart.requestPaint()
  }
  onHoverIndexChanged: chart.requestPaint()
  Component.onCompleted: control.reload()
  Component.onDestruction: {
    if (control.hass) control.hass.clearHistory(control.entityId)
  }

  function reload() {
    if (control.hass) control.hass.requestHistory(control.entityId, control.hours)
  }

  function formatClock(unix) {
    var date = new Date(unix * 1000)
    var hoursPart = date.getHours()
    var minutes = date.getMinutes()
    return (hoursPart < 10 ? "0" : "") + hoursPart
      + ":" + (minutes < 10 ? "0" : "") + minutes
  }

  function formatValue(value) {
    if (typeof value !== "number" || !isFinite(value)) return ""
    var text = Math.abs(value) >= 100 || Math.abs(value - Math.round(value)) < 0.05
      ? String(Math.round(value))
      : value.toFixed(1)
    return control.unit ? text + " " + control.unit : text
  }

  function statusMessage() {
    if (control.errorText) return control.errorText
    if (control.loading && control.points.length === 0) return "Loading history…"
    if (!control.loading && control.points.length === 0) return "No history yet."
    return ""
  }

  function plotFrame() {
    var samples = control.points
    if (!samples || samples.length === 0 || chart.width < 8 || chart.height < 8)
      return null

    var maxT = control.axisNow
    var minT = maxT - control.hours * 3600
    if (!(maxT > minT)) maxT = minT + 1

    // Scale Y from values that actually appear in the visible window, including
    // the held value from the last sample before minT (step-chart semantics).
    var minV = 0
    var maxV = 0
    var have = false
    var hold = null
    for (var i = 0; i < samples.length; i++) {
      var sample = samples[i]
      if (sample.t < minT) {
        hold = sample.v
        continue
      }
      if (!have) {
        if (hold !== null) {
          minV = hold
          maxV = hold
          have = true
        }
      }
      if (!have) {
        minV = sample.v
        maxV = sample.v
        have = true
      } else {
        if (sample.v < minV) minV = sample.v
        if (sample.v > maxV) maxV = sample.v
      }
    }
    if (!have && hold !== null) {
      minV = hold
      maxV = hold
      have = true
    }
    if (!have) {
      minV = samples[0].v
      maxV = samples[0].v
      for (var j = 1; j < samples.length; j++) {
        if (samples[j].v < minV) minV = samples[j].v
        if (samples[j].v > maxV) maxV = samples[j].v
      }
    }
    if (minV === maxV) {
      minV -= 1
      maxV += 1
    }
    var pad = (maxV - minV) * 0.08
    minV -= pad
    maxV += pad

    var left = Style.space(4)
    var right = chart.width - Style.space(4)
    var top = Style.space(6)
    var bottom = chart.height - Style.space(6)
    var spanX = right - left
    var spanY = bottom - top
    if (spanX <= 0 || spanY <= 0) return null
    return {
      samples: samples, minV: minV, maxV: maxV, minT: minT, maxT: maxT,
      left: left, right: right, top: top, bottom: bottom,
      spanX: spanX, spanY: spanY
    }
  }

  function strokeStepPath(ctx, frame) {
    var samples = frame.samples
    var first = samples[0]
    var startT = Math.max(first.t, frame.minT)
    ctx.moveTo(control.xAt(frame, startT), control.yAt(frame, first.v))
    for (var i = 1; i < samples.length; i++) {
      var prev = samples[i - 1]
      var next = samples[i]
      ctx.lineTo(control.xAt(frame, next.t), control.yAt(frame, prev.v))
      ctx.lineTo(control.xAt(frame, next.t), control.yAt(frame, next.v))
    }
    var last = samples[samples.length - 1]
    ctx.lineTo(control.xAt(frame, frame.maxT), control.yAt(frame, last.v))
  }

  function xAt(frame, t) {
    return frame.left + ((t - frame.minT) / (frame.maxT - frame.minT)) * frame.spanX
  }

  function yAt(frame, v) {
    return frame.top + ((frame.maxV - v) / (frame.maxV - frame.minV)) * frame.spanY
  }

  implicitHeight: column.implicitHeight

  Column {
    id: column
    width: parent.width
    spacing: Style.spacing.md

    Flow {
      id: chips
      width: parent.width
      spacing: Style.spacing.sm

      Repeater {
        model: control.windows
        delegate: Rectangle {
          required property int index
          required property var modelData

          implicitWidth: chipLabel.implicitWidth + Style.spacing.lg
          implicitHeight: chipLabel.implicitHeight + Style.spacing.sm
          radius: height / 2
          color: control.hours === modelData
            ? Qt.rgba(control.fg.r, control.fg.g, control.fg.b, 0.16)
            : "transparent"
          border.width: control.selectorCursorIndex === index
            ? Math.max(1, Style.space(2)) : 0
          border.color: control.fg

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onContainsMouseChanged: {
              if (containsMouse) control.selectorCursorRequested(index)
            }
            onClicked: {
              if (control.hours === modelData) control.reload()
              else control.hours = modelData
            }
          }

          Text {
            textFormat: Text.PlainText
            id: chipLabel
            anchors.centerIn: parent
            text: Model.historyWindowLabel(modelData)
            color: control.hours === modelData ? control.fg : control.dim
            font.family: control.family
            font.pixelSize: Style.font.caption
            font.bold: control.hours === modelData
          }
        }
      }
    }

    Item {
      id: plot
      width: parent.width
      implicitHeight: Style.space(120)

      Canvas {
        id: chart
        anchors.fill: parent
        visible: control.points.length > 0
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var frame = control.plotFrame()
          if (!frame) return
          var samples = frame.samples

          ctx.beginPath()
          control.strokeStepPath(ctx, frame)
          ctx.lineTo(control.xAt(frame, frame.maxT), frame.bottom)
          ctx.lineTo(control.xAt(frame, Math.max(samples[0].t, frame.minT)),
                     frame.bottom)
          ctx.closePath()
          ctx.fillStyle = Qt.rgba(control.fg.r, control.fg.g, control.fg.b, 0.16)
          ctx.fill()

          ctx.beginPath()
          control.strokeStepPath(ctx, frame)
          ctx.strokeStyle = control.fg
          ctx.lineWidth = Math.max(1.5, Style.space(2))
          ctx.stroke()

          if (control.hoverIndex < 0 || control.hoverIndex >= samples.length) return
          var point = samples[control.hoverIndex]
          var hx = control.xAt(frame, point.t)
          var hy = control.yAt(frame, point.v)
          ctx.beginPath()
          ctx.moveTo(hx, frame.top)
          ctx.lineTo(hx, frame.bottom)
          ctx.strokeStyle = Qt.rgba(control.fg.r, control.fg.g, control.fg.b, 0.45)
          ctx.lineWidth = 1
          ctx.stroke()
          var radius = Math.max(3, Style.space(4))
          ctx.beginPath()
          ctx.arc(hx, hy, radius, 0, Math.PI * 2)
          ctx.fillStyle = control.fg
          ctx.fill()
        }
      }

      Timer {
        interval: 30000
        running: chart.visible
        repeat: true
        onTriggered: {
          control.axisNow = Date.now() / 1000
          chart.requestPaint()
        }
      }

      MouseArea {
        id: plotMouse
        anchors.fill: parent
        hoverEnabled: true
        enabled: control.points.length > 0
        cursorShape: Qt.CrossCursor
        onExited: control.hoverIndex = -1
        onCanceled: control.hoverIndex = -1
        onPositionChanged: function(mouse) {
          control.axisNow = Date.now() / 1000
          var frame = control.plotFrame()
          if (!frame) {
            control.hoverIndex = -1
            return
          }
          control.hoverIndex = Model.nearestHistoryIndex(
            frame.samples, mouse.x, frame.left, frame.spanX, frame.minT, frame.maxT)
        }
        onClicked: function(mouse) { mouse.accepted = true }
      }

      Text {
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.top: parent.top
        visible: chart.visible && control.hoverPoint === null
        text: {
          var samples = control.points
          if (!samples.length) return ""
          var maxV = samples[0].v
          for (var i = 1; i < samples.length; i++) {
            if (samples[i].v > maxV) maxV = samples[i].v
          }
          return control.formatValue(maxV)
        }
        color: control.dim
        font.family: control.family
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        visible: chart.visible && control.hoverPoint === null
        text: {
          var samples = control.points
          if (!samples.length) return ""
          var minV = samples[0].v
          for (var i = 1; i < samples.length; i++) {
            if (samples[i].v < minV) minV = samples[i].v
          }
          return control.formatValue(minV)
        }
        color: control.dim
        font.family: control.family
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        visible: control.statusMessage() !== ""
        width: parent.width
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
        text: control.statusMessage()
        color: control.dim
        font.family: control.family
        font.pixelSize: Style.font.caption
      }
    }

    Item {
      width: parent.width
      implicitHeight: startLabel.implicitHeight
      visible: control.points.length > 0

      Text {
        textFormat: Text.PlainText
        id: startLabel
        anchors.left: parent.left
        text: control.formatClock(control.axisNow - control.hours * 3600)
        color: control.dim
        font.family: control.family
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        anchors.horizontalCenter: parent.horizontalCenter
        visible: control.hoverPoint !== null
        text: control.hoverPoint
          ? control.formatClock(control.hoverPoint.t)
            + " · " + control.formatValue(control.hoverPoint.v)
          : ""
        color: control.fg
        font.family: control.family
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        anchors.right: parent.right
        text: control.formatClock(control.axisNow)
        color: control.dim
        font.family: control.family
        font.pixelSize: Style.font.caption
      }
    }
  }
}

import QtQuick
import qs.Ui
import qs.Commons

// Shared Home Assistant recorder renderer. Both an expanded sensor row and a
// bar data popup use this exact plot so gaps, step semantics, bounds, hover,
// area fill, and theme colours cannot drift apart.
Item {
  id: root

  required property var points
  property color foreground: Color.foreground
  property color accent: foreground
  property string fontFamily: Style.font.family
  property bool includeZero: false
  property real axisStart: 0
  property real axisEnd: 0
  property real hoverTime: -1
  property bool showCursor: false
  property real plotLeft: Style.space(38)
  property real plotRight: Style.space(4)

  readonly property var bounds: {
    var values = root.points || []
    var low = null
    var high = null
    for (var i = 0; i < values.length; i++) {
      if (values[i].v === null) continue
      var numeric = Number(values[i].v)
      if (!isFinite(numeric)) continue
      low = low === null ? numeric : Math.min(low, numeric)
      high = high === null ? numeric : Math.max(high, numeric)
    }
    if (low === null) return ({ min: 0, max: 1 })
    if (root.includeZero) low = Math.min(0, low)
    var span = high - low
    if (span <= 0) span = Math.max(1, Math.abs(high) * 0.1)
    var padding = span * 0.04
    return ({ min: root.includeZero && low === 0 ? 0 : low - padding,
              max: high + padding })
  }
  readonly property var hoveredPoint: root.nearestPoint(root.hoverTime)

  function nearestPoint(timestamp) {
    var values = root.points || []
    if (timestamp < 0 || !values.length) return null
    var low = 0
    var high = values.length - 1
    while (low < high) {
      var middle = Math.floor((low + high) / 2)
      if (Number(values[middle].t) < timestamp) low = middle + 1
      else high = middle
    }
    if (low > 0 && Math.abs(Number(values[low - 1].t) - timestamp)
        <= Math.abs(Number(values[low].t) - timestamp)) return values[low - 1]
    return values[low]
  }

  function shortNumber(value) {
    var numeric = Number(value)
    var magnitude = Math.abs(numeric)
    if (magnitude >= 1000) return (numeric / 1000).toFixed(1) + "k"
    if (magnitude >= 100) return String(Math.round(numeric))
    if (magnitude >= 10) return numeric.toFixed(1).replace(/\.0$/, "")
    return numeric.toFixed(2).replace(/0+$/, "").replace(/\.$/, "")
  }

  Text {
    textFormat: Text.PlainText
    width: root.plotLeft - Style.spacing.xs
    anchors.left: parent.left
    anchors.top: parent.top
    text: root.shortNumber(root.bounds.max)
    color: Qt.darker(root.foreground, 1.55)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    horizontalAlignment: Text.AlignRight
  }

  Text {
    textFormat: Text.PlainText
    width: root.plotLeft - Style.spacing.xs
    anchors.left: parent.left
    anchors.bottom: parent.bottom
    text: root.shortNumber(root.bounds.min)
    color: Qt.darker(root.foreground, 1.55)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    horizontalAlignment: Text.AlignRight
  }

  Canvas {
    id: chart
    anchors.left: parent.left
    anchors.leftMargin: root.plotLeft
    anchors.right: parent.right
    anchors.rightMargin: root.plotRight
    anchors.top: parent.top
    anchors.bottom: parent.bottom

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.lineWidth = 1
      ctx.strokeStyle = Qt.rgba(root.foreground.r, root.foreground.g,
                                root.foreground.b, 0.12)
      ctx.beginPath()
      ctx.moveTo(0, height - 0.5)
      ctx.lineTo(width, height - 0.5)
      ctx.stroke()

      var values = root.points || []
      if (!values.length) return
      var minTime = root.axisStart || Number(values[0].t)
      var maxTime = root.axisEnd || Number(values[values.length - 1].t)
      var timeSpan = Math.max(1, maxTime - minTime)
      var valueSpan = Math.max(0.000001, root.bounds.max - root.bounds.min)
      var pad = Style.space(2)
      var segments = []
      var segment = []
      for (var point = 0; point < values.length; point++) {
        var timestamp = Number(values[point].t)
        if (timestamp < minTime || timestamp > maxTime) continue
        if (values[point].v === null || !isFinite(Number(values[point].v))) {
          if (segment.length) segments.push(segment)
          segment = []
          continue
        }
        var x = (timestamp - minTime) / timeSpan * width
        var y = pad + (root.bounds.max - Number(values[point].v)) / valueSpan
          * Math.max(1, height - pad * 2)
        if (segment.length)
          segment.push({ x: x, y: segment[segment.length - 1].y })
        segment.push({ x: x, y: y })
      }
      if (segment.length) segments.push(segment)

      ctx.fillStyle = Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
      for (var fillIndex = 0; fillIndex < segments.length; fillIndex++) {
        var fillSegment = segments[fillIndex]
        ctx.beginPath()
        ctx.moveTo(fillSegment[0].x, fillSegment[0].y)
        for (var fillPoint = 1; fillPoint < fillSegment.length; fillPoint++)
          ctx.lineTo(fillSegment[fillPoint].x, fillSegment[fillPoint].y)
        ctx.lineTo(fillSegment[fillSegment.length - 1].x, height - pad)
        ctx.lineTo(fillSegment[0].x, height - pad)
        ctx.closePath()
        ctx.fill()
      }

      ctx.lineWidth = Math.max(1.5, Style.space(1.5))
      ctx.lineJoin = "round"
      ctx.lineCap = "round"
      ctx.strokeStyle = root.accent
      for (var lineIndex = 0; lineIndex < segments.length; lineIndex++) {
        var lineSegment = segments[lineIndex]
        ctx.beginPath()
        ctx.moveTo(lineSegment[0].x, lineSegment[0].y)
        for (var linePoint = 1; linePoint < lineSegment.length; linePoint++)
          ctx.lineTo(lineSegment[linePoint].x, lineSegment[linePoint].y)
        ctx.stroke()
      }

      if (root.hoveredPoint && root.hoveredPoint.v !== null) {
        var hoverX = (Number(root.hoveredPoint.t) - minTime) / timeSpan * width
        var hoverY = pad + (root.bounds.max - Number(root.hoveredPoint.v))
          / valueSpan * Math.max(1, height - pad * 2)
        if (root.showCursor) {
          ctx.strokeStyle = Qt.rgba(root.foreground.r, root.foreground.g,
                                    root.foreground.b, 0.45)
          ctx.lineWidth = 1
          ctx.beginPath()
          ctx.moveTo(hoverX, 0)
          ctx.lineTo(hoverX, height)
          ctx.stroke()
        }
        ctx.fillStyle = root.accent
        ctx.beginPath()
        ctx.arc(hoverX, hoverY, Style.space(3), 0, Math.PI * 2)
        ctx.fill()
      }
    }

    Connections {
      target: root
      function onPointsChanged() { chart.requestPaint() }
      function onBoundsChanged() { chart.requestPaint() }
      function onWidthChanged() { chart.requestPaint() }
      function onHeightChanged() { chart.requestPaint() }
      function onAccentChanged() { chart.requestPaint() }
      function onForegroundChanged() { chart.requestPaint() }
      function onHoverTimeChanged() { chart.requestPaint() }
      function onAxisStartChanged() { chart.requestPaint() }
      function onAxisEndChanged() { chart.requestPaint() }
      function onShowCursorChanged() { chart.requestPaint() }
    }
  }
}

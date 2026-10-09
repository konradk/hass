import QtQuick
import qs.Ui
import qs.Commons

// One compact plot in a synchronized history stack. The parent owns the
// shared hover time and vertical cursor; this component owns its scale, line,
// nearest sample marker, and optional bottom time axis.
Item {
  id: root

  required property var points
  required property string label
  property string value: ""
  property string unit: ""
  property color foreground: Color.popups.text
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property bool loading: false
  property bool includeZero: false
  property bool showTimeAxis: false
  property real plotStart: 0
  property real plotEnd: 0
  property real hoverTime: -1
  property int windowHours: 24

  readonly property real plotLeft: Style.space(38)
  readonly property real plotRight: Style.space(4)
  readonly property var hoveredPoint: historyPlot.hoveredPoint

  implicitHeight: Style.space(showTimeAxis ? 98 : 86)

  function shortNumber(value) {
    return historyPlot.shortNumber(value)
  }

  function hoveredValue() {
    if (!root.hoveredPoint) return root.value
    if (root.hoveredPoint.v === null) return "Unavailable"
    return root.shortNumber(root.hoveredPoint.v)
      + (root.unit ? " " + root.unit : "")
  }

  function durationLabel(hours) {
    if (hours < 1) return String(Math.round(hours * 60)) + "m ago"
    return (hours % 1 === 0 ? String(hours) : hours.toFixed(1)) + "h ago"
  }

  Text {
    id: title
    textFormat: Text.PlainText
    anchors.left: parent.left
    anchors.top: parent.top
    text: root.label
    color: Qt.darker(root.foreground, 1.28)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }

  Text {
    textFormat: Text.PlainText
    anchors.right: parent.right
    anchors.top: parent.top
    text: root.hoveredValue()
    color: root.hoveredPoint && root.hoveredPoint.v !== null
      ? root.accent : root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.weight: Font.Medium
  }

  Item {
    id: plot
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: title.bottom
    anchors.topMargin: Style.spacing.xs
    anchors.bottom: root.showTimeAxis ? timeStart.top : parent.bottom
    anchors.bottomMargin: root.showTimeAxis ? Style.spacing.xs : 0

    HistoryPlot {
      id: historyPlot
      anchors.fill: parent
      points: root.points
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      includeZero: root.includeZero
      axisStart: root.plotStart
      axisEnd: root.plotEnd
      hoverTime: root.hoverTime
      plotLeft: root.plotLeft
      plotRight: root.plotRight
    }
  }

  Text {
    id: timeStart
    textFormat: Text.PlainText
    visible: root.showTimeAxis
    anchors.left: parent.left
    anchors.leftMargin: root.plotLeft
    anchors.bottom: parent.bottom
    text: root.durationLabel(root.windowHours)
    color: Qt.darker(root.foreground, 1.45)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    textFormat: Text.PlainText
    visible: root.showTimeAxis
    x: root.plotLeft + (root.width - root.plotLeft - root.plotRight) / 2
      - implicitWidth / 2
    anchors.bottom: parent.bottom
    text: root.durationLabel(root.windowHours / 2)
    color: Qt.darker(root.foreground, 1.55)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    textFormat: Text.PlainText
    visible: root.showTimeAxis
    anchors.right: parent.right
    anchors.rightMargin: root.plotRight
    anchors.bottom: parent.bottom
    text: root.loading ? "Loading…" : "Now"
    color: Qt.darker(root.foreground, 1.45)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}

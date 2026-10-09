import QtQuick
import qs.Ui
import qs.Commons
import ".."
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
  property real hoverTime: -1
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
    return historyPlot.hoveredPoint
  }
  readonly property real snapshotAxisEnd: snapshot && snapshot.axisEnd
    ? Number(snapshot.axisEnd) : Date.now() / 1000

  onHoursChanged: {
    control.hoverTime = -1
    control.axisNow = Date.now() / 1000
    control.reload()
  }
  onPlotRevisionChanged: {
    control.axisNow = control.snapshotAxisEnd
  }
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
    if (value === null) return "Unavailable"
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

  function visibleExtreme(maximum) {
    var result = null
    for (var i = 0; i < control.points.length; i++) {
      var value = control.points[i].v
      if (value === null) continue
      if (result === null || (maximum ? value > result : value < result)) result = value
    }
    return result
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

      HistoryPlot {
        id: historyPlot
        anchors.fill: parent
        visible: control.points.length > 0
        points: control.points
        foreground: control.fg
        accent: control.fg
        fontFamily: control.family
        includeZero: String(Model.attrs(control.entity).device_class || "") === "power"
        axisStart: control.axisNow - control.hours * 3600
        axisEnd: control.axisNow
        hoverTime: control.hoverTime
        showCursor: true
      }

      Timer {
        interval: 30000
        running: historyPlot.visible
        repeat: true
        onTriggered: {
          if (!control.loading) control.axisNow = control.snapshotAxisEnd
        }
      }

      MouseArea {
        id: plotMouse
        anchors.fill: parent
        hoverEnabled: true
        enabled: control.points.length > 0
        cursorShape: Qt.CrossCursor
        onExited: control.hoverTime = -1
        onCanceled: control.hoverTime = -1
        onPositionChanged: function(mouse) {
          var left = historyPlot.plotLeft
          var width = Math.max(1, historyPlot.width - left - historyPlot.plotRight)
          var fraction = Math.max(0, Math.min(1, (mouse.x - left) / width))
          control.hoverTime = control.axisNow - control.hours * 3600
            + fraction * control.hours * 3600
        }
        onClicked: function(mouse) { mouse.accepted = true }
      }

      Text {
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.top: parent.top
        visible: historyPlot.visible && control.hoverPoint === null
        text: {
          return control.formatValue(control.visibleExtreme(true))
        }
        color: control.dim
        font.family: control.family
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        visible: historyPlot.visible && control.hoverPoint === null
        text: {
          return control.formatValue(control.visibleExtreme(false))
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

import QtQuick
import qs.Ui
import qs.Commons
import "controls"
import "Model.js" as Model
import "BarData.js" as BarData

// A repeated Home Assistant bar instance. A room instance paints each reading
// as a child of one compact widget; an entity instance paints only that value.
BarWidget {
  id: root

  property var hostWidget: null
  property bool popupOpen: false
  property string historyTag: ""
  property var histories: ({})
  property string historyError: ""
  property bool historyLoading: false
  property real historyStartMs: 0
  property real historyEndMs: 0
  property int historyHours: 24

  readonly property var barIdentity: hostWidget || root
  readonly property bool opened: popupOpen
  readonly property bool popoutSwitchClosing: false
  // Match the open-panel marker to everything this widget actually paints.
  // The bar's default is 55% of the slot, which looks right for one compact
  // glyph but leaves the outer readings of a composed room widget uncovered.
  readonly property real openPanelIndicatorWidth: horizontalContent.implicitWidth
  readonly property real openPanelIndicatorHeight: verticalContent.implicitHeight

  readonly property var hass: bar && bar.shell ? bar.shell.serviceFor("hass") : null
  readonly property string dataKind: String(setting("dataKind", ""))
  readonly property string entityId: String(setting("entityId", ""))
  readonly property string deviceId: String(setting("deviceId", ""))
  readonly property bool valid: hass !== null && ((dataKind === "entity" && entityId)
    || (dataKind === "room" && deviceId))
  readonly property var entity: {
    if (!hass || dataKind !== "entity" || !entityId) return null
    hass.stateRevision
    return hass.entityFor(entityId)
  }
  readonly property var cardData: {
    if (!hass || dataKind !== "room" || !deviceId) return null
    hass.stateRevision
    return hass.roomReadingCard(deviceId)
  }
  readonly property var readings: {
    if (dataKind === "room") {
      if (cardData && cardData.readings.length) return cardData.readings
      return [{ label: "Room", value: "Unavailable", quality: "unknown" }]
    }
    if (entity) {
      var projected = hass.barDataReadingsForEntity(entityId)
      if (projected.length) return projected
    }
    return [{ entityId: entityId, label: entityId,
              value: "Unavailable", quality: "unknown" }]
  }
  readonly property string displayName: dataKind === "room"
    ? (cardData ? cardData.name : deviceId)
    : (hass ? hass.displayName(entityId) : entityId)
  readonly property string glyph: dataKind === "room"
    ? (cardData ? cardData.icon : Model.FALLBACK_ICON)
    : (hass ? hass.iconFor(entityId, entity) : Model.FALLBACK_ICON)
  readonly property color fg: bar ? bar.barForeground : Color.foreground
  readonly property string family: bar ? bar.fontFamily : Style.font.family
  readonly property bool climateWidget: dataKind === "entity"
    && Model.domain(entity) === "climate"
  readonly property color popupFg: Color.popups.text

  function readingColor(reading) {
    switch (String(reading && reading.quality || "unknown")) {
    case "good": return Color.accent
    case "moderate": return root.fg
    case "poor": return bar ? Qt.lighter(bar.urgent, 1.28) : Qt.lighter(Color.urgent, 1.28)
    case "critical": return bar ? bar.urgent : Color.urgent
    default: return Qt.darker(root.fg, 1.45)
    }
  }

  function targetEntry() {
    return dataKind === "room"
      ? BarData.roomEntry(deviceId) : BarData.entityEntry(entityId)
  }

  function removeFromBar() {
    if (!bar || !bar.shell || typeof bar.shell.mutateShellConfig !== "function") return
    var target = targetEntry()
    bar.shell.mutateShellConfig(function(config) { BarData.remove(config, target) })
  }

  function historyEntityIds() {
    var ids = []
    if (dataKind === "entity" && entityId) return [entityId]
    for (var i = 0; i < readings.length; i++) {
      var id = String(readings[i].entityId || "")
      if (id && ids.indexOf(id) === -1) ids.push(id)
    }
    return ids
  }

  function loadHistory(hours) {
    if (!hass || climateWidget) return
    var nextHours = Model.normalizeHistoryHours(hours)
    if (nextHours) root.historyHours = nextHours
    root.historyLoading = true
    root.historyError = ""
    root.histories = ({})
    root.historyTag = hass.requestHistoryBatch(
      root.historyEntityIds(), root.historyHours)
    if (!root.historyTag) {
      root.historyLoading = false
      root.historyError = "History is unavailable."
    }
  }

  function open() {
    root.popupOpen = true
    if (!root.climateWidget) root.loadHistory(root.historyHours)
  }

  function close() { root.popupOpen = false }
  function closeForPopoutSwitch() { root.close() }
  function togglePopup() { root.popupOpen ? root.close() : root.open() }

  Connections {
    target: root.hass
    enabled: root.hass !== null
    function onHistoryReady(tag, result, error, startMs, endMs) {
      if (String(tag) !== root.historyTag) return
      root.historyLoading = false
      root.histories = result || ({})
      root.historyError = String(error || "")
      if (Number(startMs) > 0 && Number(endMs) > Number(startMs)) {
        root.historyStartMs = Number(startMs)
        root.historyEndMs = Number(endMs)
        return
      }
      var newest = root.historyEndMs
      for (var entityId in root.histories) {
        var points = root.histories[entityId] || []
        if (points.length) newest = Math.max(newest, Number(points[points.length - 1].t))
      }
      if (newest > root.historyEndMs) {
        root.historyEndMs = newest
        root.historyStartMs = newest - root.historyHours * 60 * 60 * 1000
      }
    }
  }

  function readingSummary() {
    var parts = []
    for (var i = 0; i < readings.length; i++)
      parts.push(readings[i].label + ": " + readings[i].value)
    return parts.join(" · ")
  }

  function historyEntity(entityId) {
    if (!hass) return null
    hass.stateRevision
    return hass.entityFor(String(entityId || ""))
  }

  function historyUnit(entityId) {
    var item = root.historyEntity(entityId)
    return String(item && item.attributes
      ? item.attributes.unit_of_measurement || "" : "")
  }

  function historyIncludesZero(entityId) {
    var item = root.historyEntity(entityId)
    var deviceClass = String(item && item.attributes
      ? item.attributes.device_class || "" : "")
    return deviceClass === "power"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: root.valid
    fixedWidth: root.vertical ? root.barSize
      : horizontalContent.implicitWidth + Style.spacing.xl * 2
    fixedHeight: root.vertical
      ? verticalContent.implicitHeight + Style.spacing.md * 2 : -1
    tooltipText: root.displayName + "\n" + root.readingSummary()
      + (root.climateWidget ? "\nLeft click for controls" : "\nLeft click for history")
      + "\nRight click to remove from the bar"
    onPressed: function(button) {
      if (button === Qt.RightButton) root.removeFromBar()
      else if (button === Qt.LeftButton) root.togglePopup()
    }

    Row {
      id: horizontalContent
      visible: !root.vertical
      anchors.centerIn: parent
      spacing: Style.spacing.md

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: root.glyph
        color: root.fg
        font.family: root.family
        font.pixelSize: Style.font.body
      }

      Repeater {
        model: root.readings

        delegate: Row {
          required property var modelData
          required property int index
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.md

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            visible: index > 0
            text: "·"
            color: Qt.darker(root.fg, 1.45)
            font.family: root.family
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.value
            color: root.readingColor(modelData)
            font.family: root.family
            font.pixelSize: Style.font.bodySmall
            font.weight: Font.Medium
          }
        }
      }
    }

    Column {
      id: verticalContent
      visible: root.vertical
      anchors.centerIn: parent
      spacing: Style.spacing.xxs

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: root.glyph
        color: root.fg
        font.family: root.family
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
      }

      Repeater {
        model: root.readings

        delegate: Text {
          required property var modelData
          textFormat: Text.PlainText
          width: verticalContent.width
          text: modelData.value
          color: root.readingColor(modelData)
          font.family: root.family
          font.pixelSize: Style.font.caption
          font.weight: Font.Medium
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }

  KeyboardPanel {
    id: dataPanel
    anchorItem: button
    owner: root.barIdentity
    bar: root.bar
    open: root.popupOpen
    focusTarget: keyCatcher
    contentWidth: dataPanel.fittedContentWidth(Style.space(400))
    contentHeight: dataPanel.fittedContentHeight(
      popupColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.climateWidget && climateControls.popupOpen
      onCloseRequested: root.close()

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: popupColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: root.climateWidget && contentHeight > height

        Column {
          id: popupColumn
          width: parent.width
          spacing: Style.spacing.panelGap

          PanelHero {
            width: parent.width
            title: root.displayName
            meta: root.climateWidget ? "Climate controls"
              : (historyStack.hoverActive ? historyStack.hoverLabel
                : (root.historyHours === 1 ? "Last hour"
                  : "Last " + root.historyHours + " hours"))
            foreground: root.popupFg
            fontFamily: root.family

            iconComponent: Text {
              textFormat: Text.PlainText
              text: root.glyph
              color: root.popupFg
              font.family: root.family
              font.pixelSize: Style.font.display
            }
          }

          PanelSeparator { width: parent.width; foreground: root.popupFg }

          ClimateControls {
            id: climateControls
            width: parent.width
            visible: root.climateWidget
            height: visible ? implicitHeight : 0
            hass: root.hass
            entityId: root.entityId
            entity: root.entity
            bar: root.bar
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: !root.climateWidget && root.historyError !== ""
            height: visible ? implicitHeight : 0
            text: root.historyError
            color: Color.urgent
            font.family: root.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }

          Flow {
            id: historyWindows
            width: parent.width
            visible: !root.climateWidget
            height: visible ? implicitHeight : 0
            spacing: Style.spacing.sm

            Repeater {
              model: Model.HISTORY_HOURS

              delegate: Rectangle {
                required property var modelData
                implicitWidth: windowLabel.implicitWidth + Style.spacing.lg
                implicitHeight: windowLabel.implicitHeight + Style.spacing.sm
                radius: height / 2
                color: root.historyHours === modelData
                  ? Qt.rgba(root.popupFg.r, root.popupFg.g, root.popupFg.b, 0.16)
                  : "transparent"

                Text {
                  id: windowLabel
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: Model.historyWindowLabel(modelData)
                  color: root.historyHours === modelData
                    ? root.popupFg : Qt.darker(root.popupFg, 1.4)
                  font.family: root.family
                  font.pixelSize: Style.font.caption
                  font.bold: root.historyHours === modelData
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.loadHistory(modelData)
                }
              }
            }
          }

          Item {
            id: historyStack
            width: parent.width
            visible: !root.climateWidget && root.historyError === ""
            height: visible ? graphColumn.implicitHeight : 0

            property bool hoverActive: false
            property real hoverFraction: 0
            readonly property real hoverTime: root.historyStartMs
              + hoverFraction * Math.max(1, root.historyEndMs - root.historyStartMs)
            readonly property string hoverLabel: {
              if (!hoverActive) return root.historyHours === 1
                ? "Last hour" : "Last " + root.historyHours + " hours"
              return new Date(hoverTime).toLocaleString(Qt.locale(), "ddd HH:mm")
            }

            Column {
              id: graphColumn
              width: parent.width
              spacing: Style.spacing.sm

              Repeater {
                model: root.readings

                delegate: HistoryGraph {
                  required property var modelData
                  required property int index
                  width: graphColumn.width
                  points: root.histories[String(modelData.entityId || "")] || []
                  label: modelData.label
                  value: modelData.value
                  unit: root.historyUnit(modelData.entityId)
                  foreground: root.popupFg
                  accent: root.readingColor(modelData)
                  fontFamily: root.family
                  loading: root.historyLoading
                  includeZero: root.historyIncludesZero(modelData.entityId)
                  showTimeAxis: index === root.readings.length - 1
                  plotStart: root.historyStartMs
                  plotEnd: root.historyEndMs
                  hoverTime: historyStack.hoverActive ? historyStack.hoverTime : -1
                  windowHours: root.historyHours
                }
              }
            }

            Canvas {
              id: sharedCursor
              anchors.fill: parent
              z: 20
              visible: historyStack.hoverActive

              onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                if (!historyStack.hoverActive) return
                var left = Style.space(38)
                var right = Style.space(4)
                var x = left + historyStack.hoverFraction
                  * Math.max(1, width - left - right)
                ctx.strokeStyle = Qt.rgba(root.popupFg.r, root.popupFg.g,
                                          root.popupFg.b, 0.58)
                ctx.lineWidth = 1
                ctx.beginPath()
                for (var y = Style.space(16); y < height - Style.space(12);
                     y += Style.space(6)) {
                  ctx.moveTo(x, y)
                  ctx.lineTo(x, Math.min(height, y + Style.space(3)))
                }
                ctx.stroke()
              }

              Connections {
                target: historyStack
                function onHoverActiveChanged() { sharedCursor.requestPaint() }
                function onHoverFractionChanged() { sharedCursor.requestPaint() }
                function onWidthChanged() { sharedCursor.requestPaint() }
                function onHeightChanged() { sharedCursor.requestPaint() }
              }
            }

            MouseArea {
              anchors.fill: parent
              z: 30
              hoverEnabled: true
              acceptedButtons: Qt.NoButton
              onPositionChanged: function(mouse) {
                var left = Style.space(38)
                var width = Math.max(1, historyStack.width - left - Style.space(4))
                historyStack.hoverFraction = Math.max(0, Math.min(1,
                  (mouse.x - left) / width))
                historyStack.hoverActive = mouse.x >= left
              }
              onExited: historyStack.hoverActive = false
            }
          }
        }
      }
    }
  }
}

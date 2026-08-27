import QtQuick
import qs.Ui
import qs.Commons
import "Model.js" as Model
import "BarData.js" as BarData

// A repeated Home Assistant bar instance. A room instance paints each reading
// as a child of one compact widget; an entity instance paints only that value.
BarWidget {
  id: root

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
      var reading = Model.environmentalReading(entity)
      if (reading) return [reading]
      return [{ entityId: entityId, label: hass.displayName(entityId),
                value: Model.displayState(entity), quality: "neutral" }]
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

  function openPanel() {
    if (bar && bar.shell && typeof bar.shell.summon === "function")
      bar.shell.summon("hass")
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
    tooltipText: root.displayName + "\nLeft click to open Home Assistant"
      + "\nRight click to remove from the bar"
    onPressed: function(button) {
      if (button === Qt.RightButton) root.removeFromBar()
      else if (button === Qt.LeftButton) root.openPanel()
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
}

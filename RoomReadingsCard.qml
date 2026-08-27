import QtQuick
import qs.Ui
import qs.Commons
import "BarData.js" as BarData

// Compact, generic environmental summary for one Home Assistant device.
// Classification lives in Model.js; this component only renders the projected
// values and uses the shell's active theme roles for every colour.
Item {
  id: card

  required property var hass
  required property string deviceId
  property QtObject bar: null

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string family: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property var cardData: {
    hass.stateRevision
    return hass.roomReadingCard(deviceId)
  }

  function shellConfig() {
    return bar && bar.shell ? bar.shell.shellConfig : null
  }

  function inBar(entry) {
    return BarData.contains(shellConfig(), entry)
  }

  function addToBar(entry) {
    if (!bar || !bar.shell || typeof bar.shell.mutateShellConfig !== "function"
        || inBar(entry)) return
    bar.shell.mutateShellConfig(function(config) { BarData.add(config, entry) })
  }

  width: parent ? parent.width : 0
  implicitHeight: header.implicitHeight + Style.spacing.lg + metrics.implicitHeight

  HoverHandler { id: cardHover }

  Item {
    id: header
    width: parent.width
    height: implicitHeight
    anchors.top: parent.top
    implicitHeight: Math.max(glyph.implicitHeight, headerLabels.height,
                             headerActions.implicitHeight)

    Text {
      textFormat: Text.PlainText
      id: glyph
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: card.cardData.icon
      color: card.fg
      font.family: card.family
      font.pixelSize: Style.font.heading
    }

    Column {
      id: headerLabels
      anchors.left: glyph.right
      anchors.leftMargin: Style.spacing.xl
      anchors.right: headerActions.left
      anchors.rightMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      height: name.implicitHeight
        + (areaName.visible ? spacing + areaName.implicitHeight : 0)
      spacing: Style.spacing.xxs

      Text {
        textFormat: Text.PlainText
        id: name
        width: parent.width
        text: card.cardData.name
        color: card.fg
        font.family: card.family
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        id: areaName
        width: parent.width
        visible: card.cardData.areaName.length > 0
        text: card.cardData.areaName
        color: card.dim
        font.family: card.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Row {
      id: headerActions
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.md

      PanelActionButton {
        readonly property var entry: BarData.roomEntry(card.deviceId)
        readonly property bool added: card.inBar(entry)
        anchors.verticalCenter: parent.verticalCenter
        visible: cardHover.hovered && card.cardData.readings.length >= 2
        enabled: !added
        iconText: added ? "󰄬" : "󰐕"       // md-check / md-plus
        tooltipText: added ? "Room readings are in the bar" : "Add room readings to the bar"
        foreground: card.fg
        fontFamily: card.family
        onClicked: card.addToBar(entry)
      }

      ToggleSwitch {
        id: primaryControl
        anchors.verticalCenter: parent.verticalCenter
        visible: card.cardData.controlEntityId.length > 0
        checked: card.cardData.controlOn
        busy: card.cardData.controlPending
        interactive: true
        cursorRing: false
        foreground: card.fg
        onToggled: if (card.cardData.controlEntityId) {
          card.hass.toggleEntity(card.cardData.controlEntityId)
        }
      }
    }
  }

  Grid {
    id: metrics
    width: parent.width
    height: implicitHeight
    anchors.top: header.bottom
    anchors.topMargin: Style.spacing.lg
    columns: 2
    columnSpacing: Style.spacing.sm
    rowSpacing: Style.spacing.sm

    Repeater {
      model: card.cardData.readings

      delegate: Rectangle {
        id: metric
        required property var modelData
        readonly property var reading: modelData
        readonly property var entry: BarData.entityEntry(reading.entityId)
        readonly property bool added: card.inBar(entry)
        readonly property color qualityColor: {
          switch (reading.quality) {
          case "good": return Color.accent
          case "moderate": return card.fg
          case "poor": return Qt.lighter(Color.urgent, 1.28)
          case "critical": return Color.urgent
          default: return card.dim
          }
        }

        width: Math.floor((metrics.width - Style.spacing.sm) / 2)
        height: metricName.implicitHeight + Style.spacing.xxs
          + metricValue.implicitHeight + Style.spacing.md
        radius: Style.cornerRadius
        color: Style.normalFillFor(card.fg, qualityColor, Color.urgent)

        HoverHandler { id: metricHover }

        Column {
          id: metricLabels
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.spacing.md
          anchors.rightMargin: Style.spacing.md
          height: metricName.implicitHeight + spacing + metricValue.implicitHeight
          spacing: Style.spacing.xxs

          Text {
            textFormat: Text.PlainText
            id: metricName
            width: parent.width
            text: reading.label
            color: card.dim
            font.family: card.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            id: metricValue
            width: parent.width
            text: reading.value
            color: qualityColor
            font.family: card.family
            font.pixelSize: Style.font.body
            font.weight: Font.Medium
            elide: Text.ElideRight
          }
        }

        PanelActionButton {
          anchors.top: parent.top
          anchors.right: parent.right
          anchors.margins: Style.spacing.xxs
          visible: metricHover.hovered
          enabled: !metric.added
          iconText: metric.added ? "󰄬" : "󰐕"  // md-check / md-plus
          tooltipText: metric.added
            ? metric.reading.label + " is in the bar"
            : "Add " + metric.reading.label + " to the bar"
          foreground: metric.qualityColor
          fontFamily: card.family
          size: Style.space(20)
          onClicked: card.addToBar(metric.entry)
        }
      }
  }
}
}

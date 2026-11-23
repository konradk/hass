import QtQuick
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// Compact, generic environmental summary for one Home Assistant device.
// Classification lives in Model.js; this component only renders the projected
// values and uses the shell's active theme roles for every colour.
Item {
  id: card

  required property var hass
  required property string deviceId
  property QtObject bar: null
  property bool expanded: false
  property bool pinned: false
  property bool rowHovered: false
  property bool showIcon: true
  property bool showPanelPinOnHover: false

  signal expansionRequested()
  signal pinRequested()

  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property string family: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property bool pinPreview: card.showPanelPinOnHover
    && card.showIcon && card.rowHovered
  readonly property var cardData: {
    hass.stateRevision
    hass.pendingToggleRevision
    return hass.roomReadingCard(deviceId)
  }

  width: parent ? parent.width : 0
  implicitHeight: header.implicitHeight
    + (expanded ? Style.spacing.lg + metrics.implicitHeight : 0)

  Item {
    id: header
    width: parent.width
    height: implicitHeight
    anchors.top: parent.top
    implicitHeight: Math.max(glyph.implicitHeight, headerLabels.height,
                             headerControls.implicitHeight)

    Text {
      textFormat: Text.PlainText
      id: glyph
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      visible: card.showIcon
      width: card.showIcon ? implicitWidth : 0
      text: card.cardData.icon
      color: card.fg
      opacity: card.pinPreview ? 0.0 : 1.0
      font.family: card.family
      font.pixelSize: Style.font.heading
    }

    BorderSurface {
      z: 1
      anchors.centerIn: glyph
      width: Math.max(glyph.implicitWidth, Style.space(18))
      height: Style.space(22)
      radius: Style.cornerRadius
      visible: card.pinPreview
      color: card.pinned
        ? Style.selectedFillFor(card.fg, Commons.Color.accent)
        : Style.hoverFillFor(card.fg, card.dim)
      borderSpec: card.pinned
        ? Border.controlSpec("selected", card.fg, Commons.Color.accent) : Border.none()
    }

    Text {
      textFormat: Text.PlainText
      id: pinGlyph
      z: 2
      anchors.centerIn: glyph
      visible: card.pinPreview
      text: ""                               // Font Awesome thumb tack
      color: card.pinned ? Commons.Color.accent : card.dim
      font.family: card.family
      font.pixelSize: Style.font.heading
    }

    MouseArea {
      id: glyphPinMouse
      z: 3
      anchors.centerIn: glyph
      width: Math.max(glyph.implicitWidth, Style.space(22))
      height: Style.space(22)
      enabled: card.showPanelPinOnHover && card.showIcon
      hoverEnabled: true
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: card.pinRequested()
    }

    PanelToolTip {
      visible: glyphPinMouse.containsMouse
      text: card.pinned ? "Unpin expanded readings" : "Pin expanded readings"
      fontFamily: card.family
    }

    Column {
      id: headerLabels
      anchors.left: glyph.right
      anchors.leftMargin: card.showIcon ? Style.spacing.xl : 0
      anchors.right: headerControls.left
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
        visible: card.cardData.summary.length > 0
        text: card.cardData.summary
        color: card.dim
        font.family: card.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Row {
      id: headerControls
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.md

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

      PanelActionButton {
        anchors.verticalCenter: parent.verticalCenter
        iconText: card.expanded ? "󰅃" : "󰅀"
        tooltipText: card.expanded ? "Collapse readings" : "Show readings"
        foreground: card.dim
        fontFamily: card.family
        onClicked: card.expansionRequested()
      }
    }
  }

  Grid {
    id: metrics
    width: parent.width
    height: implicitHeight
    anchors.top: header.bottom
    anchors.topMargin: Style.spacing.lg
    visible: card.expanded
    columns: 2
    columnSpacing: Style.spacing.sm
    rowSpacing: Style.spacing.sm

    Repeater {
      model: card.cardData.readings

      delegate: Rectangle {
        required property var modelData
        readonly property var reading: modelData
        readonly property color qualityColor: {
          switch (reading.quality) {
          case "good": return Commons.Color.accent
          case "moderate": return card.fg
          case "poor": return Qt.lighter(Commons.Color.urgent, 1.28)
          case "critical": return Commons.Color.urgent
          default: return card.dim
          }
        }

        width: Math.floor((metrics.width - Style.spacing.sm) / 2)
        height: metricName.implicitHeight + Style.spacing.xxs
          + metricValue.implicitHeight + Style.spacing.md
        radius: Style.cornerRadius
        color: Style.normalFillFor(card.fg, qualityColor, Commons.Color.urgent)

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
      }
  }
}
}

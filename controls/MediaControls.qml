import QtQuick
import qs.Ui
import qs.Commons
import "../Model.js" as Model

// Transport and volume for a media player.
Item {
  id: control

  required property var service
  required property string entityId
  property var entity: null
  property QtObject bar: null

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string family: bar ? bar.fontFamily : Style.font.family

  implicitHeight: column.implicitHeight

  readonly property bool playing: entity ? Model.isPlaying(entity) : false
  readonly property var capabilities: Model.capabilitiesFor(entity)
  readonly property real level: {
    var value = entity ? Model.volumeLevel(entity) : -1
    return value < 0 ? 0 : value
  }
  readonly property bool hasVolume: capabilities.mediaVolume

  property real localVolume: -1
  readonly property real shownVolume: localVolume >= 0 ? localVolume : level

  Column {
    id: column
    width: parent.width
    spacing: Style.spacing.xl

    Row {
      spacing: Style.spacing.md

      PanelActionButton {
        visible: control.capabilities.mediaPrevious
        iconText: "󰒮"                 // md-skip_previous
        tooltipText: "Previous"
        foreground: control.fg
        fontFamily: control.family
        onClicked: control.service.mediaPrevious(control.entityId)
      }

      PanelActionButton {
        visible: control.capabilities.mediaPlayPause
        iconText: control.playing ? "󰏤" : "󰐊"   // md-pause / md-play
        tooltipText: control.playing ? "Pause" : "Play"
        foreground: control.fg
        fontFamily: control.family
        onClicked: control.service.mediaPlayPause(control.entityId)
      }

      PanelActionButton {
        visible: control.capabilities.mediaNext
        iconText: "󰒭"                 // md-skip_next
        tooltipText: "Next"
        foreground: control.fg
        fontFamily: control.family
        onClicked: control.service.mediaNext(control.entityId)
      }
    }

    SliderRow {
      visible: control.hasVolume
      width: parent.width
      bar: control.bar
      label: "VOLUME"
      valueText: Math.round(control.shownVolume * 100) + "%"
      value: control.shownVolume
      minimum: 0
      maximum: 1
      step: 0.05

      onMoved: function(value) { control.localVolume = value }
      onReleased: function(value) {
        control.localVolume = -1
        control.service.setVolume(control.entityId, value)
      }
    }
  }
}

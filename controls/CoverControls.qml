import QtQuick
import qs.Ui
import qs.Commons
import "../Model.js" as Model

// Open / Close / Stop for a cover. Sits inline in EntityRow's control slot
// (see there) rather than behind the expand chevron other domains use — a
// Jalousie is not something anyone wants to tap twice to move.
Item {
  id: control

  required property var service
  required property string entityId
  property var entity: null
  property QtObject bar: null

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string family: bar ? bar.fontFamily : Style.font.family
  readonly property var capabilities: Model.capabilitiesFor(entity)

  implicitWidth: row.implicitWidth
  implicitHeight: row.implicitHeight

  Row {
    id: row
    spacing: Style.space(6)

    PanelActionButton {
      visible: control.capabilities.coverOpen
      iconText: "󰜷"                   // md-arrow_up_bold
      tooltipText: "Open"
      foreground: control.fg
      fontFamily: control.family
      onClicked: control.service.coverAction(control.entityId, "open_cover")
    }

    PanelActionButton {
      visible: control.capabilities.coverStop
      iconText: "󰓛"                   // md-stop
      tooltipText: "Stop"
      foreground: control.fg
      fontFamily: control.family
      onClicked: control.service.coverAction(control.entityId, "stop_cover")
    }

    PanelActionButton {
      visible: control.capabilities.coverClose
      iconText: "󰜮"                   // md-arrow_down_bold
      tooltipText: "Close"
      foreground: control.fg
      fontFamily: control.family
      onClicked: control.service.coverAction(control.entityId, "close_cover")
    }
  }
}

import QtQuick
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// One line in the settings device browser: add or remove a favorite, and for
// rows already in the list, move it up or down.
CursorSurface {
  id: row

  required property string entityId
  required property string name
  required property string icon
  required property string detail
  required property bool favorite
  required property bool reorderable
  property bool roomReading: false
  property bool pinnable: false
  property bool pinned: false
  property string panelItemId: entityId
  property var service: null
  property string family: Style.font.menuFamily

  implicitHeight: content.implicitHeight + Style.space(10)

  HoverHandler {
    id: hover
    onHoveredChanged: row.hasCursor = hovered
  }

  Item {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Style.space(8)
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    implicitHeight: Math.max(glyph.implicitHeight, labels.implicitHeight,
                             actions.implicitHeight)

    Text {
      textFormat: Text.PlainText
      id: glyph
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(22)
      text: row.icon
      color: Commons.Color.muted
      font.family: row.family
      font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignHCenter
    }

    Column {
      id: labels
      anchors.left: glyph.right
      anchors.leftMargin: Style.space(8)
      anchors.right: actions.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: row.name
        color: Commons.Color.foreground
        font.family: row.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: row.detail
        color: Commons.Color.muted
        font.family: row.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Row {
      id: actions
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      PanelActionButton {
        id: pinAction
        anchors.verticalCenter: parent.verticalCenter
        visible: row.pinnable && row.reorderable
        iconText: ""                         // Font Awesome thumb tack
        tooltipText: row.pinned
          ? "Do not keep expanded"
          : "Keep expanded when the panel opens"
        foreground: row.pinned ? Commons.Color.accent : Commons.Color.muted
        hoverColor: row.pinned ? Commons.Color.accent : Commons.Color.foreground
        fontFamily: row.family
        onClicked: if (row.service) {
          if (row.roomReading) row.service.toggleRoomReadingPinned(row.entityId)
          else if (typeof row.service.toggleEntityPinned === "function") {
            row.service.toggleEntityPinned(row.entityId)
          }
        }
      }

      PanelActionButton {
        anchors.verticalCenter: parent.verticalCenter
        visible: row.reorderable
        iconText: "󰅃"                       // md-chevron_up
        tooltipText: "Move up"
        foreground: Commons.Color.muted
        fontFamily: row.family
        onClicked: if (row.service) row.service.movePanelItem(row.panelItemId, -1)
      }

      PanelActionButton {
        anchors.verticalCenter: parent.verticalCenter
        visible: row.reorderable
        iconText: "󰅀"                       // md-chevron_down
        tooltipText: "Move down"
        foreground: Commons.Color.muted
        fontFamily: row.family
        onClicked: if (row.service) row.service.movePanelItem(row.panelItemId, 1)
      }

      PanelActionButton {
        anchors.verticalCenter: parent.verticalCenter
        // A filled star for a favorite, an outline for everything else, so
        // the state is legible without relying on colour alone.
        iconText: row.favorite ? "󰓎" : "󰓒"   // md-star / md-star_outline
        tooltipText: row.roomReading
          ? (row.favorite ? "Remove room-reading card" : "Add room-reading card")
          : (row.favorite ? "Remove from panel" : "Add to panel")
        foreground: row.favorite ? Commons.Color.foreground : Commons.Color.muted
        fontFamily: row.family
        onClicked: if (row.service) {
          if (row.roomReading) row.service.toggleRoomReading(row.entityId)
          else row.service.toggleFavorite(row.entityId)
        }
      }
    }
  }
}

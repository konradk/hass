import QtQuick
import qs.Ui
import qs.Commons

// A camera frame at the bottom of the popover. The bridge writes the latest
// frame straight to a local file (see bin/loxone-bridge's module docstring
// for why) — this just rereads that file on a timer.
//
// Two Image elements, not one: with `cache: false`, QtQuick drops the old
// decoded pixmap the moment `source` changes — the display goes blank for
// the async decode's duration regardless of any `visible` binding on that
// same Image, which is what a single reloading Image flashed on every tick.
// The one on screen never has its own `source` touched while it's the one
// showing; the hidden one loads the next frame, and only takes over once it
// is actually `Image.Ready`.
Item {
  id: root

  property var service: null
  property QtObject bar: null

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string family: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(fg, 1.4)

  readonly property string status: service ? service.cameraStatus : "idle"
  readonly property string framePath: service ? service.cameraFramePath : ""

  implicitHeight: Style.space(190)

  property int reloadTick: 0
  // Which buffer is currently the one on screen; the *other* one is always
  // the reload target, so the visible buffer's source is never touched.
  property int frontIndex: 0

  readonly property url pendingSource: (root.status === "streaming" && root.framePath)
    ? ("file://" + root.framePath + "#" + root.reloadTick) : ""

  onPendingSourceChanged: {
    if (root.frontIndex === 0) bufferB.source = root.pendingSource
    else bufferA.source = root.pendingSource
  }

  Timer {
    interval: 1000
    running: root.status === "streaming"
    repeat: true
    onTriggered: root.reloadTick++
  }

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
  }

  Image {
    id: bufferA
    anchors.fill: parent
    visible: root.status === "streaming" && root.frontIndex === 0
      && bufferA.status === Image.Ready
    fillMode: Image.PreserveAspectFit
    cache: false
    asynchronous: true
    onStatusChanged: if (status === Image.Ready) root.frontIndex = 0
  }

  Image {
    id: bufferB
    anchors.fill: parent
    visible: root.status === "streaming" && root.frontIndex === 1
      && bufferB.status === Image.Ready
    fillMode: Image.PreserveAspectFit
    cache: false
    asynchronous: true
    onStatusChanged: if (status === Image.Ready) root.frontIndex = 1
  }

  Text {
    textFormat: Text.PlainText
    anchors.centerIn: parent
    anchors.margins: Style.spacing.lg
    width: parent.width - Style.spacing.xxl
    visible: !bufferA.visible && !bufferB.visible
    text: {
      if (root.status === "connecting") return "Connecting to camera…"
      if (root.status === "error") {
        var reason = service ? service.cameraError : ""
        return reason ? "Camera unavailable: " + reason : "Camera unavailable"
      }
      return "Waiting for the first frame…"
    }
    wrapMode: Text.WordWrap
    horizontalAlignment: Text.AlignHCenter
    color: root.dim
    font.family: root.family
    font.pixelSize: Style.font.bodySmall
  }
}

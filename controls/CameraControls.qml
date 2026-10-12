import QtQuick
import qs.Ui
import qs.Commons
import "../Model.js" as Model

// Live video for a camera that can stream, snapshots for one that cannot.
// Snapshots also cover the moments the stream is starting or has failed. The
// Loader in EntityRow unloads this on collapse, which ends both.
Item {
  id: control

  required property var hass
  required property string entityId
  property var entity: null
  property QtObject bar: null

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string family: bar ? bar.fontFamily : Style.font.family
  readonly property int snapshotInterval: 5000
  readonly property int streamRetryInterval: 30000

  // A camera that advertises streaming, on an install that can play video.
  readonly property bool canStream: Model.capabilitiesFor(entity).cameraStream
    && liveVideo.status !== Loader.Error

  readonly property var snapshot: {
    if (!hass) return null
    hass.snapshotRevision
    return hass.snapshotFor(entityId)
  }
  readonly property var stream: {
    if (!hass) return null
    hass.streamRevision
    return hass.streamFor(entityId)
  }

  // Cleared by the retry timer; a refused stream stays failed until the
  // bridge answers the retry.
  property bool playerFailed: false
  readonly property bool streamFailed: playerFailed
    || (stream !== null && stream.error.length > 0)
  readonly property string streamUrl: !streamFailed && stream ? stream.url : ""
  readonly property bool live: liveVideo.item !== null && liveVideo.item.live

  readonly property string status: {
    if (live) return ""
    if (snapshot && snapshot.error) return snapshot.error
    if (image.status !== Image.Ready) {
      return canStream && !streamFailed ? "Starting live video…" : "Loading snapshot…"
    }
    return ""
  }

  implicitHeight: frame.height

  Component.onCompleted: if (control.canStream) control.hass.startStream(control.entityId)
  Component.onDestruction: {
    if (liveVideo.item) liveVideo.item.stop()
    if (control.canStream) control.hass.stopStream(control.entityId)
  }

  Timer {
    interval: control.snapshotInterval
    running: control.hass !== null && !control.live
    repeat: true
    triggeredOnStart: true
    onTriggered: control.hass.requestSnapshot(control.entityId)
  }

  Timer {
    interval: control.streamRetryInterval
    running: control.canStream && control.streamFailed
    onTriggered: {
      control.playerFailed = false
      control.hass.startStream(control.entityId)
    }
  }

  Rectangle {
    id: frame
    width: parent.width
    height: Math.round(width * 9 / 16)
    radius: Style.cornerRadius
    color: Qt.rgba(control.fg.r, control.fg.g, control.fg.b, 0.06)
    clip: true

    Image {
      id: image
      anchors.fill: parent
      visible: !control.live
      source: control.snapshot && control.snapshot.path
        ? "file://" + control.snapshot.path : ""
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      // Every snapshot is a new file, so caching only holds stale frames.
      cache: false
      // Keep the current frame up until the next one has decoded.
      retainWhileLoading: true
      smooth: true
    }

    Loader {
      id: liveVideo
      anchors.fill: parent
      visible: control.live
      active: Model.capabilitiesFor(control.entity).cameraStream
      source: "CameraLiveVideo.qml"
      onLoaded: item.url = Qt.binding(function() { return control.streamUrl })
    }

    Connections {
      target: liveVideo.item
      function onFailed() { control.playerFailed = true }
    }

    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      width: parent.width - 2 * Style.spacing.lg
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      visible: control.status.length > 0
      text: control.status
      color: control.fg
      opacity: 0.7
      font.family: control.family
      font.pixelSize: Style.font.caption
    }

    Text {
      textFormat: Text.PlainText
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.margins: Style.spacing.md
      visible: control.live
      text: "● LIVE"
      color: Color.urgent
      font.family: control.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }
}

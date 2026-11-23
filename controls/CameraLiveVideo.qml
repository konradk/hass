import QtQuick
import QtMultimedia

// The only file that needs QtMultimedia. CameraControls loads it through a
// Loader, so an install without the module degrades to snapshots instead of
// losing the whole camera view.
Item {
  id: root

  property string url: ""
  readonly property bool live: player.hasVideo
    && player.playbackState === MediaPlayer.PlayingState
    && (player.mediaStatus === MediaPlayer.BufferedMedia
      || player.mediaStatus === MediaPlayer.BufferingMedia)

  signal failed()

  function stop() {
    player.stop()
  }

  MediaPlayer {
    id: player
    source: root.url
    videoOutput: video
    // No audioOutput: a panel row should not start talking.
    onSourceChanged: if (source.toString().length > 0) play()
    // Qt 6.10+: smaller buffers. Set from script so an older Qt still plays.
    Component.onCompleted: {
      try {
        playbackOptions.playbackIntent = PlaybackOptions.LowLatencyStreaming
      } catch (e) {
      }
    }
    onErrorOccurred: root.failed()
  }

  VideoOutput {
    id: video
    anchors.fill: parent
    fillMode: VideoOutput.PreserveAspectFit
  }
}

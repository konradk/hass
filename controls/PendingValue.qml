import QtQuick
import "../Model.js" as Model

// A value someone has chosen that Home Assistant has not confirmed yet. Held
// so a control never falls back to the stale entity value between the command
// going out and the state coming back; `holdMs` bounds the wait in case it
// never does.
QtObject {
  id: pending

  // null means nothing pending; otherwise a number or an object.
  property var value: null
  readonly property bool active: value !== null
  property int holdMs: 6500

  // Lets a control holding two of these tell which one was touched last.
  property real pickedAt: 0

  property string tag: ""

  // Mid-gesture: nothing sent, so no deadline.
  function hold(next) {
    expiry.stop()
    pending.tag = ""
    pending.pickedAt = Date.now()
    pending.value = next
  }

  function commit(next, tag) {
    pending.tag = String(tag || "")
    pending.pickedAt = Date.now()
    pending.value = next
    expiry.restart()
  }

  function clear() {
    expiry.stop()
    pending.tag = ""
    pending.value = null
  }

  function rollback(failedTag) {
    if (Model.callTagMatches(pending.tag, failedTag)) pending.clear()
  }

  property Timer expiry: Timer {
    interval: pending.holdMs
    onTriggered: pending.clear()
  }
}

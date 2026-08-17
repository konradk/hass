import QtQuick
import qs.Ui

// Shared dropdown mechanics for one typed climate mode selector. Callers keep
// the service method explicit while this restores the authoritative value after
// Dropdown imperatively updates its value.
Dropdown {
  id: selector

  required property string authoritativeValue
  required property var modes
  required property var modeLabel

  signal modeSelected(string mode)
  signal selectorHovered()

  value: authoritativeValue
  options: modes.map(function(mode) {
    return { value: mode, label: modeLabel(mode) }
  })

  onChanged: function(mode) {
    selector.value = Qt.binding(function() {
      return selector.authoritativeValue
    })
    if (mode !== selector.authoritativeValue) selector.modeSelected(mode)
  }
  onHovered: function(hovered) {
    if (hovered) selector.selectorHovered()
  }
}

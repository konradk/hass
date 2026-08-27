import QtQuick

// One plugin id can host the original panel button and any number of selected
// data instances. Omarchy injects each layout entry's inline settings here;
// the entry without dataKind remains the original Home Assistant panel.
Loader {
  id: root

  property QtObject bar: null
  property string moduleName: "hass"
  property var settings: ({})

  readonly property string dataKind: String(settings && settings.dataKind || "")
  readonly property bool dataInstance: dataKind !== ""
  readonly property var opened: dataInstance
    ? undefined : (item ? item.opened : false)
  readonly property bool popoutSwitchClosing: !dataInstance && item
    ? item.popoutSwitchClosing === true : false

  sourceComponent: dataInstance ? dataComponent : panelComponent

  function inject() {
    if (!item) return
    if ("bar" in item) item.bar = root.bar
    if ("moduleName" in item) item.moduleName = root.moduleName
    if ("settings" in item) item.settings = root.settings
  }

  // These make only the main instance eligible for the shell's panel routing:
  // data instances deliberately expose opened as undefined.
  function open() { if (!dataInstance && item && item.open) item.open() }
  function close() { if (!dataInstance && item && item.close) item.close() }
  function closeForPopoutSwitch() {
    if (!dataInstance && item && item.closeForPopoutSwitch)
      item.closeForPopoutSwitch()
  }

  onBarChanged: inject()
  onModuleNameChanged: inject()
  onSettingsChanged: inject()
  onLoaded: {
    inject()
    Qt.callLater(inject)
  }

  Component {
    id: panelComponent
    Panel {}
  }

  Component {
    id: dataComponent
    DataBarWidget {}
  }
}

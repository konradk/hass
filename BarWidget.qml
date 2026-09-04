import QtQuick
import "BarData.js" as BarData

// The normal plugin entry hosts the Home Assistant panel. Older releases also
// loaded child readings through this wrapper with the same `hass` id. Keep
// that path long enough to migrate them to independently movable data modules.
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
  property bool migrationScheduled: false

  function migrateDataInstance() {
    if (!dataInstance || migrationScheduled || !bar || !bar.shell
        || typeof bar.shell.mutateShellConfig !== "function") return
    migrationScheduled = true
    var target = dataKind === "room"
      ? BarData.roomEntry(String(settings.deviceId || ""))
      : BarData.entityEntry(String(settings.entityId || ""))
    bar.shell.mutateShellConfig(function(config) { BarData.migrate(config, target) })
  }

  function inject() {
    if (!item) return
    if ("bar" in item) item.bar = root.bar
    if ("moduleName" in item) item.moduleName = root.moduleName
    if ("settings" in item) item.settings = root.settings
    if ("hostWidget" in item) item.hostWidget = root
  }

  // These make only the main instance eligible for the shell's panel routing:
  // data instances deliberately expose opened as undefined.
  function open() { if (item && item.open) item.open() }
  function close() { if (item && item.close) item.close() }
  function closeForPopoutSwitch() {
    if (item && item.closeForPopoutSwitch)
      item.closeForPopoutSwitch()
  }

  onBarChanged: inject()
  onModuleNameChanged: inject()
  onSettingsChanged: inject()
  onLoaded: {
    inject()
    Qt.callLater(inject)
    Qt.callLater(migrateDataInstance)
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

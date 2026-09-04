const BarData = require("../BarData.js")

let checks = 0
function ok(name, condition) {
  checks++
  if (!condition) throw new Error("FAIL " + name)
  console.log("  ok   " + name)
}

function config() {
  return {
    version: 1,
    bar: { layout: {
      left: [{ id: "omarchy.menu" }],
      center: [{ id: "omarchy.clock" }],
      right: [{ id: "omarchy.tray" }, { id: "hass" }, { id: "omarchy.power" }]
    }}
  }
}

console.log("bar data: independently movable widget entries")
const first = BarData.entityEntry("sensor.air_temperature")
const room = BarData.roomEntry("device_air_monitor")
const shell = config()

ok("an entity reading is valid", BarData.valid(first))
ok("the main panel is not a data instance", !BarData.valid({ id: "hass" }))
ok("a child has its own stable widget id",
   first.id === "hass.data.entity.sensor.air_temperature")
ok("a child loads the data widget directly",
   first.source === "$HOME/.config/omarchy/plugins/hass/DataBarWidget.qml")
ok("the first reading is added", BarData.add(shell, first))
ok("the reading is placed beside the main panel",
   shell.bar.layout.right[2].entityId === "sensor.air_temperature")
ok("a room card follows existing data instances", BarData.add(shell, room)
   && shell.bar.layout.right[3].deviceId === "device_air_monitor")
ok("duplicate entity readings are rejected", !BarData.add(shell, first))
ok("entity and room identities are disjoint",
   !BarData.sameInstance(first, room))
ok("removing a room leaves the main panel intact", BarData.remove(shell, room)
   && shell.bar.layout.right.some(entry => entry.id === "hass" && !entry.dataKind))
ok("removing a missing instance is a no op", !BarData.remove(shell, room))

const legacy = {
  bar: { layout: { left: [], center: [], right: [
    { id: "hass" },
    { id: "hass", dataKind: "entity", entityId: "sensor.air_temperature" }
  ] } }
}
ok("legacy repeated ids are still recognized", BarData.contains(legacy, first))
ok("legacy children migrate without touching the main panel",
   BarData.migrate(legacy, first)
   && legacy.bar.layout.right[0].id === "hass"
   && legacy.bar.layout.right[1].id === first.id
   && legacy.bar.layout.right[1].source === first.source)
ok("migrating a canonical child is a no op", !BarData.migrate(legacy, first))

const empty = { version: 1 }
ok("a missing layout is created", BarData.add(empty, first)
   && empty.bar.layout.right[0].entityId === "sensor.air_temperature")

const stringMain = config()
stringMain.bar.layout.right[1] = "hass"
ok("a string main entry is also used as the insertion anchor",
   BarData.add(stringMain, room)
   && stringMain.bar.layout.right[2].deviceId === "device_air_monitor")

console.log("\nall " + checks + " bar data checks passed")

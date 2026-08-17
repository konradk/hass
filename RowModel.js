.pragma library

// One raw Loxone control entity plus display context in, one ListModel row
// out. The model API is injected so this mapper stays independent of QML
// imports and easy to test.
function project(entityId, entity, context, model) {
  var caps = model.capabilitiesFor(entity)
  var areaId = (context.entityArea || {})[entityId] || ""
  var control = caps.toggle ? "toggle"
    : caps.lock ? "lock"
    : caps.activate ? "activate"
    : "none"
  return {
    entityId: entityId,
    name: context.name,
    subtitle: entity ? model.subtitle(entity, context.temperatureUnit) : "",
    badge: entity ? model.badgeText(entity) : "Unavailable",
    icon: context.icon,
    domain: model.domainOf(entityId),
    isOn: context.isOn,
    pending: context.pending,
    control: control,
    expandable: caps.expandable,
    reserveExpandSlot: caps.reserveExpandSlot,
    available: caps.available,
    areaId: areaId,
    areaName: (context.areaNames || {})[areaId] || ""
  }
}

# QML control guidance

These instructions apply to domain controls under `controls/`.

- Controls receive `service`, `entityId`, and the current entity. Keep Loxone
  protocol details (command verbs, control types) out of these components and
  call the typed methods exposed by `Service.qml` — `coverAction`,
  `setClimateTemperature`, `setBrightness`, and so on already translate a UI
  action into the right Loxone command inside the service/bridge.
- Derive visibility and interactivity from `Model.capabilitiesFor(entity)`.
  Unsupported or unavailable controls must not send a command.
- Keep slider state local while dragging and commit once on release. Clamp and
  validate numeric values again in the service/model layer.
- Do not optimistically invent a capability from a currently non-null
  attribute — `capabilitiesFor` already encodes what each Loxone control type
  can do; extend it there rather than adding a second opinion in a control.
- Use `Style`, `Color`, and bar-provided colors/fonts. Every raw `Text` must use
  `Text.PlainText` and an explicit font family.
- Keep controls reusable and free of connection, credential, persistence, and
  IPC concerns.
- `MediaControls.qml` has no reachable domain yet (no Loxone control in this
  plugin's mapping produces `media_player`) — treat it as forward-compatible
  dead code, not something to delete, the same way the original left
  `camera` support unimplemented.

Run `python3 tests/test_qml_style.py`, `node tests/test_model.js`, and QML parser
checks after changing controls.

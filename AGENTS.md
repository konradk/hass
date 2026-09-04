# Home Assistant for Omarchy

## Project overview

This repository is an Omarchy 4 Quickshell plugin for viewing and controlling
Home Assistant entities from the desktop bar. The UI is QML with small pure
JavaScript modules. A long-lived Python helper owns the Home Assistant
WebSocket connection and communicates with QML over versioned NDJSON on
stdin/stdout.

Canonical public repository: `https://github.com/konradk/hass`.

The plugin must remain installable without npm, pip, a virtual environment, or
first-run downloads. Python 3.11 or newer, `secret-tool`, and the vendored
`websockets` package are the runtime dependencies. `nmcli` is an additional,
conditional one, invoked from two places: the bridge (only when a local
network URL is actually configured, to gate every connection attempt — see
the security invariant below) and the settings UI (each time it opens, to
suggest a value for the trusted-network field; read-only, never a security
decision). Its absence must degrade to "never use the local URL" for the
bridge and "no suggestion" for the UI, not an error either way.

## Architecture map

- `Service.qml`: session-wide facade and owner of configuration, connection
  reconciliation, entity state, action dispatch, and projected row models.
- `BridgeController.qml`: lifecycle and NDJSON transport for `bin/hass-bridge`.
- `CredentialManager.qml`: serialized access to the system keyring.
- `Connection.js`: URL/origin identity, connection signatures, and generation
  filtering.
- `ConfigStore.js`: persisted configuration normalization and serialization.
- `EntityStore.js`: state and registry indexing and area projections.
- `Model.js`: entity display policy, capabilities, action classification, and
  attribute redaction.
- `RowModel.js`: projection from an entity into a QML `ListModel` row.
- `BarWidget.qml`: dispatches the main panel entry and repeated data entries.
- `Panel.qml`: popup, keyboard navigation, and IPC surface.
- `DataBarWidget.qml`: themed room and individual reading instances.
- `BarData.js`: repeated bar entry identity, placement, and removal policy.
- `Settings.qml`: connection settings and entity picker.
- `controls/`: domain-specific expanded controls.
- `bin/hass-bridge`: WebSocket protocol adapter and demo backend.
- `tests/fake_ha.py`: local fake Home Assistant used by bridge tests.

Keep transport, credential lifecycle, state projection, and UI policy separate.
Prefer extending the existing pure JavaScript modules over adding more policy
to `Service.qml`.

## Security invariants

- Never persist a Home Assistant token in `config.json`, logs, fixtures, process
  arguments, error text, or IPC output. Tokens may travel only through stdin to
  `secret-tool` and the bridge.
- Scope credentials to a normalized server origin. Changing origin must never
  silently reuse a credential. Credential deletion must target an explicit
  origin and must not remove a saved live credential as a side effect of demo
  mode. The optional local-network URL (`localUrl`) is a deliberate, narrow
  exception: it is an alternate address for the same instance the primary URL
  already names, not a second server, so it intentionally shares the primary
  origin's stored token rather than getting its own keyring entry. Do not add
  separate credential storage for it, and do not let it participate in
  `currentOrigin()`/`requiresTokenFor()` — those stay scoped to the primary
  URL only.
- `localUrl` must never be tried unless `trustedNetwork` is set and one of its
  comma-separated names matches the current Wi-Fi network name
  (`current_wifi_ssid()` and `trusted_network_list()` in `bin/hass-bridge`,
  checked fresh on every connection attempt — the list exists because a
  router commonly broadcasts more than one SSID). This is the only thing standing
  between an alternate address and sending the token to whatever happens to
  answer there on a network the user never trusted — fail closed on every
  path (no NetworkManager, an nmcli error or timeout, no active Wi-Fi, no
  match) rather than defaulting to "trusted". Enforce this in both the bridge
  and `Service.applyConnection` — the settings UI check is a fast-fail
  convenience, not the security boundary.
- Treat `http://` and `ws://` as plaintext transport. Any UI path that permits
  them must make the token-exposure risk explicit; never downgrade an invalid
  or unknown scheme to plaintext.
- TLS verification, proxy bypass, compression disablement, message limits,
  bounded receive queues, and connection timeouts are deliberate hardening.
  Do not weaken them without an explicit security decision and regression test.
- Keep protocol version and connection generation on every bridge command and
  event. Reject data from old generations before mutating UI state.
- Report `connected` only after authentication, event subscription, and the
  initial state snapshot succeed. Reset reconnect backoff only after the full
  connection is ready, not merely after authentication.
- Bound both process startup and completion for every keyring operation. Clear
  plaintext token properties on every success, failure, timeout, and cancel
  path.
- Render Home Assistant-controlled strings as plain text. Debug/IPC output must
  pass through explicit redaction and must not expose location or signed media
  attributes.
- Use argument arrays for `Process`; do not introduce shell interpolation for
  URLs, entity IDs, paths, or secrets.

## Coding conventions

- Keep JavaScript helpers side-effect free where practical and compatible with
  the QML JavaScript engine. Do not add Node-only APIs to production modules.
- Validate external JSON shapes before indexing or rendering them. Use safe map
  keys or prototype-free maps for server-controlled identifiers.
- Derive actions from `Model.capabilitiesFor`; do not expose arbitrary Home
  Assistant service calls through UI or IPC.
- Keep high-frequency `state_changed` handling incremental. Avoid copying or
  rebuilding the entire entity collection for a known entity update.
- Use `Style` and `Color` tokens in QML. Every `Text` must set
  `textFormat: Text.PlainText` and an explicit font family.
- Sliders should send commands on release rather than on every movement.
- Do not edit `vendor/websockets` directly. Dependency updates go through
  `scripts/update-websockets-vendor` after version, hash, license, release-note,
  and advisory review.
- Preserve public IPC commands and the NDJSON protocol unless a versioned
  migration is part of the task.

## Verification

Run the checks relevant to the files changed. Before handing off a broad or
security-sensitive change, run the full suite:

```bash
PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 python3 tests/test_bridge.py
python3 tests/test_vendor.py
python3 tests/test_service_contract.py
python3 tests/test_qml_style.py
node tests/test_config.js
node tests/test_connection.js
node tests/test_store.js
node tests/test_model.js
node tests/test_row_model.js
node tests/test_panel_state.js
python3 -m py_compile bin/hass-bridge tests/*.py
bash -n scripts/update-websockets-vendor
```

When available, also run `qmllint`, `qmlformat` in check/read-only mode, and
`omarchy plugin validate .`. Do not make tests depend on a real Home Assistant,
real credentials, global Python packages, or internet access.

## Code review rules

- Flag every new path that can leak or retain a token, bypass TLS verification,
  honor proxy environment variables, or reuse a credential across origins.
- Flag connection changes that can accept stale generations, claim readiness
  before synchronization, retry indefinitely without exponential backoff, or
  leave authenticated sockets open after configuration removal.
- Flag keyring flows without terminal cleanup and an operation deadline.
- Flag destructive credential actions without a clearly identified target and
  an appropriate confirmation or recovery path.
- Flag raw Home Assistant attributes written to logs or IPC, even when the
  current fixtures do not contain secrets.
- Require behavioral regression tests for security and lifecycle fixes. Source
  string assertions may supplement but must not replace behavior tests.

# Loxone for Omarchy

## Project overview

This repository is an Omarchy 4 Quickshell plugin for viewing and controlling
Loxone Miniserver devices from the desktop bar. The UI is QML with small pure
JavaScript modules. A long-lived Python helper polls the Miniserver's HTTP API
and communicates with QML over versioned NDJSON on stdin/stdout.

Converted from `konradk/hass` (a Home Assistant version of the same panel);
see "Design notes" below for what changed and why.

The plugin must remain installable without npm, pip, a virtual environment, or
first-run downloads. Python 3.11 or newer is the only runtime dependency, plus
`secret-tool` for keyring access.

## Architecture map

- `Service.qml`: session-wide facade and owner of configuration, connection
  reconciliation, entity state, action dispatch, and projected row models.
- `BridgeController.qml`: lifecycle and NDJSON transport for `bin/loxone-bridge`.
- `CredentialManager.qml`: serialized access to the system keyring.
- `Connection.js`: URL/origin identity, connection signatures, and generation
  filtering. Not Loxone-specific — a Miniserver origin is just another
  http(s) URL.
- `ConfigStore.js`: persisted configuration normalization and serialization.
- `EntityStore.js`: state and room indexing.
- `Model.js`: entity display policy, capabilities, command classification.
- `RowModel.js`: projection from an entity into a QML `ListModel` row.
- `Panel.qml`: bar widget, popup, keyboard navigation, and IPC surface.
- `Settings.qml`: connection settings and entity picker.
- `controls/`: domain-specific expanded controls.
- `bin/loxone-bridge`: Miniserver HTTP polling adapter and demo backend.
- `tests/fake_loxone.py`: local fake Miniserver used by bridge tests.

Keep transport, credential lifecycle, state projection, and UI policy separate.
Prefer extending the existing pure JavaScript modules over adding more policy
to `Service.qml`.

## Design notes: HTTP polling, plus one narrow WebSocket exception

`bin/loxone-bridge` mainly uses the Miniserver's plain HTTP API — a single
Basic-auth GET per structure fetch, per poll, and per command (`poll_all`,
`execute_command`), parallelized across `POLL_WORKERS` connections so a
couple-hundred-control install still cycles close to `POLL_INTERVAL`. This is
still a deliberate trade — a few seconds of latency instead of instant push —
for most controls, and it is still true that adding a third-party crypto
library (`pycryptodome`, `cryptography`, ...) to speak the Miniserver's real
push protocol is off the table, since it would break the no-pip/no-venv
install invariant.

What changed: that push protocol's RSA step turns out to need only *public-
key encryption*, never decryption or key generation — DER-parsing plus
`pow(base, exp, mod)`, both squarely within the standard library (see
`RsaPublicKey`/`rsa_pkcs1v15_encrypt`/`WebSocketClient` in the bridge). One
control type, `LightControllerV2`, was verified live against a real
Miniserver to have no reliable HTTP-polled on/off signal at all — its `/all`
response's `value` does not change with the control's actual state — so
`LivePushThread` exists specifically to subscribe to that one control type's
`activeMoods` push state (`[778]` is Loxone's system-reserved "off" mood;
anything else is on). It is a narrow, best-effort *enhancement* layered on
top of the HTTP-polling architecture, not a replacement for it: everything
else — every other control's state, every command, the structure fetch —
still goes through plain HTTP exactly as before, and if the handshake or
connection ever fails (older firmware, network hiccup), `CommandWorker`'s own
optimistic hint (see below) keeps `LightControllerV2` usable regardless. See
the bridge's own module docstring, and `bin/AGENTS.md`, for the full
rationale and the invariants this code has to keep.

Domain mapping (Loxone control type → panel domain) is best-effort, derived
from the public `LoxApp3.json` shape and the reference `lox` CLI's command
verbs, not from testing against every firmware version. `IRoomControllerV2`
current/target temperature attribute names in particular are guessed by
matching substrings in whatever `/dev/sps/io/<uuid>/all` reports — validate
against a real Miniserver before relying on climate control in a security-
sensitive deployment. `LightControllerV2`/`LightController` has no plain
"off" command — it's a mood controller, not a relay — so the bridge sends its
system-defined off mood (`setMood/778`, see `LIGHT_CONTROLLER_OFF` in
`bin/loxone-bridge`) instead of a literal `off`, which the Miniserver would
otherwise silently accept and do nothing with. `media_player` (Music Server
zones) is not implemented; unmapped control types fall back to a state-only
sensor row, the same as an unmapped domain would in the Home Assistant
original.

A camera livestream is a separate, deliberately Loxone-independent feature
(Settings → Camera): an arbitrary HTTP(S) URL behind Basic auth, with its own
credential (same keyring mechanism as the Miniserver's, scoped by origin) and
its own connection lifecycle in the bridge (`CameraWorker`, its own epoch —
see "Design notes" in `bin/AGENTS.md`). The frame is written straight to a
local file rather than sent over NDJSON; the shell rereads that file on a
timer. Both MJPEG (`multipart/x-mixed-replace`) and single-image snapshot
endpoints are supported, detected from the response's Content-Type, so one
"stream URL" field works for either.

## Keeping the panel in sync with the Miniserver

State reaching the panel late or wrong reads as "the button doesn't work,"
even when the command itself succeeded — three separate things guard against
that, and a regression in any one of them will look like the others:

- Every control is genuinely repolled every `POLL_INTERVAL` (`bin/loxone-
  bridge`), not just favorites — an external change (the Loxone app, a
  physical switch) shows up on the next cycle regardless of who caused it.
  Polling is parallelized across `POLL_WORKERS` connections (`poll_all`)
  specifically so that cycle stays close to `POLL_INTERVAL` even with a
  couple hundred controls; polling sequentially over one connection was
  measured taking several times the interval itself on an install that size,
  which means every control was stale by the time it was finally read.
- A *successful* command triggers an immediate single-control reread
  (`CommandWorker._confirm_entity`) instead of waiting for the next scheduled
  poll — this is what makes toggling a light feel instant rather than
  "eventually consistent within a few seconds."
- State-reading heuristics have to match reality, not just compile. An
  earlier `LightControllerV2` off-encoding heuristic looked exactly like a
  toggle that silently did nothing, because the *read* side reported "on"
  forever regardless of what the *write* side actually did — even after
  fixing a real parsing bug (nested `<output>` elements in the XML response
  clobbering the outer element's own `value`, see `parse_all_response`), the
  corrected value *still* didn't track state, live-verified by toggling the
  control and reading it back directly. A command reaching the Miniserver is
  not evidence the resulting state is being read correctly — check both
  independently when debugging a report that a button "doesn't do anything."
  For `LightControllerV2` specifically, this is now resolved two ways at
  once, in priority order: `LivePushThread`'s live `activeMoods` push when
  available (see "Design notes" above), falling back to `CommandWorker`'s own
  optimistic hint — the last on/off command *this bridge* sent — when the
  push connection is not. Never let the known-unreliable `/all` `value`
  override either one for this control type.

## Security invariants

- Never persist a Miniserver password in `config.json`, logs, fixtures, process
  arguments, error text, or IPC output. Passwords may travel only through
  stdin to `secret-tool` and the bridge.
- Scope credentials to a normalized server origin. Changing origin must never
  silently reuse a credential. Credential deletion must target an explicit
  origin and must not remove a saved live credential as a side effect of demo
  mode.
- Treat `http://` as plaintext transport. Any UI path that permits it must
  make the credential-exposure risk explicit; never downgrade an invalid or
  unknown scheme to plaintext.
- TLS verification defaults off (Miniservers overwhelmingly run a self-signed
  local certificate — see `verifyTls` in Settings), but a user who turns it on
  must get real verification, not a silent no-op.
- Block cross-origin HTTP redirects (a Miniserver Gen 2 behind Loxone's
  DynDNS service redirects to a cloud host; following it would leak local
  credentials to that host).
- Keep protocol version and connection generation on every bridge command and
  event. Reject data from old generations before mutating UI state.
- Report `connected` only after the structure and the first full poll succeed.
  Reset reconnect backoff only after that, not merely after an HTTP 200.
- Bound both process startup and completion for every keyring operation. Clear
  plaintext password properties on every success, failure, timeout, and cancel
  path.
- Render Miniserver-controlled strings as plain text. Debug/IPC output must
  pass through explicit redaction.
- Use `http.client`/argument-based requests; do not introduce shell
  interpolation for URLs, entity IDs, paths, or secrets.

## Coding conventions

- Keep JavaScript helpers side-effect free where practical and compatible with
  the QML JavaScript engine. Do not add Node-only APIs to production modules.
- Validate external JSON shapes before indexing or rendering them. Use safe map
  keys or prototype-free maps for server-controlled identifiers.
- Derive actions from `Model.capabilitiesFor`; do not expose arbitrary Loxone
  commands through UI or IPC.
- Keep polling parsing incremental where practical. `apply_snapshot` in the
  bridge already only emits `state_changed` for entities that actually
  changed — do not regress that into unconditionally re-emitting everything.
- Use `Style` and `Color` tokens in QML. Every `Text` must set
  `textFormat: Text.PlainText` and an explicit font family.
- Sliders should send commands on release rather than on every movement.
- Preserve public IPC commands and the NDJSON protocol unless a versioned
  migration is part of the task.

## Verification

Run the checks relevant to the files changed. Before handing off a broad or
security-sensitive change, run the full suite:

```bash
PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 python3 tests/test_loxone_bridge.py
python3 tests/test_service_contract.py
python3 tests/test_qml_style.py
node tests/test_config.js
node tests/test_connection.js
node tests/test_store.js
node tests/test_model.js
node tests/test_row_model.js
python3 -m py_compile bin/loxone-bridge tests/*.py
```

When available, also run `qmllint`, `qmlformat` in check/read-only mode, and
`omarchy plugin validate .`. Do not make tests depend on a real Miniserver,
real credentials, global Python packages, or internet access.

## Code review rules

- Flag every new path that can leak or retain a password, bypass TLS
  verification, follow a cross-origin redirect, or reuse a credential across
  origins.
- Flag connection changes that can accept stale generations, claim readiness
  before the first successful poll, retry indefinitely without exponential
  backoff, or leave a poller/command thread running after configuration
  removal.
- Flag keyring flows without terminal cleanup and an operation deadline.
- Flag destructive credential actions without a clearly identified target and
  an appropriate confirmation or recovery path.
- Flag raw Miniserver attributes written to logs or IPC, even when the
  current fixtures do not contain secrets.
- Require behavioral regression tests for security and lifecycle fixes. Source
  string assertions may supplement but must not replace behavior tests.

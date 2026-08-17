# Python bridge guidance

These instructions apply to `bin/loxone-bridge` in addition to the repository
rules.

- Keep the bridge a Python 3.11+ executable with no dependency on user or
  system site-packages, and no third-party crypto or WebSocket library —
  `RsaPublicKey`/`rsa_pkcs1v15_encrypt`/`WebSocketClient` exist so
  `LivePushThread` can speak the one narrow piece of the Miniserver's
  proprietary push protocol it actually needs without one; see the module
  docstring and root `AGENTS.md`'s design notes before touching either.
  RSA here is *encryption only* — never add decryption or key generation
  without re-reading why that boundary exists.
- stdin is the only command channel and stdout is NDJSON only. Send diagnostics
  through structured events or stderr; never print non-JSON text to stdout.
- The stdin reader thread may only parse and enqueue commands. Connection and
  protocol state stays owned by the main loop.
- Every externally visible event must carry `protocolVersion` and the active
  connection generation (`epoch` internally). Stop the old poller/command
  worker before relabeling state with a new generation — `stop_workers()` is
  the one place that happens.
- Never accept a password through argv. Redact the active password from all
  server-controlled error messages before emitting or logging them — `redact()`
  and `Bridge.safe_error()` are the choke points; route new error paths
  through them rather than formatting a message inline.
- URL parsing must allow only `http` and `https`; a missing scheme assumes
  TLS. Never turn a malformed scheme into `http://`. Reject userinfo in the
  URL.
- Block redirects to a different host (`LoxoneClient.get`) — a Miniserver
  Gen 2 redirects to a cloud DynDNS host, and following it would send local
  credentials to that host.
- TLS verification follows the `verifyTls` config flag (default off — real
  Miniservers overwhelmingly run a self-signed local certificate); when it is
  on, verification must actually run, not silently no-op.
- Poller and command-worker threads each tag their messages with the epoch
  they were started under. The main loop must drop any message whose epoch
  does not match `self.epoch` — that is what makes a stale connection's
  in-flight request harmless after a reconnect.
- Authentication success alone is not readiness. Reset reconnect backoff only
  after the structure fetch and the first full poll succeed.
- Treat `/dev/sps/io/<uuid>/all` and `/data/LoxApp3.json` responses as
  untrusted: validate shapes before indexing them, and never let a
  malformed control crash the poll loop for every other control (see
  `build_entity`'s use of `.get()` throughout, never direct indexing).
- Demo mode (`DemoHouse`) should exercise the same registry/poll/command shape
  as a live connection, so the panel's code paths are the same either way.
- `CameraWorker` is its own independent lifecycle (`self.camera_epoch`, not
  `self.epoch`) — it must never be started, stopped, or gated by Miniserver
  connection/reconnect code, and vice versa. Its `read1()`, not `read()`, on
  the response object during MJPEG streaming: `read(n)` (inherited from
  `BufferedIOBase`) blocks until `n` bytes accumulate, which never happens
  for a slow multipart stream sending one small frame at a time — that bug
  looks exactly like a hang, not an error, so it is easy to ship silently.
  `tests/fake_camera.py`'s MJPEG test exists specifically to catch a
  regression here.
- `LivePushThread` is its own independent lifecycle too, tied to the
  Miniserver's `self.epoch` (unlike the camera, it has nothing to run
  without a Miniserver connection) but never required for one to succeed —
  it must always be possible for `stop_workers()` to tear it down alongside
  the poller/command worker, and for the poller to reach `connected` whether
  or not it ever does. Never let a failure in it affect `self.phase` or
  `self.backoff` — those belong to the Miniserver connection, which this is
  explicitly *not* part of establishing. `_mood_state`'s `"[778]"` encoding
  is a live-verified fact about the Miniserver, not a guess — do not "fix" it
  back to a `value == 0` check without re-verifying against a real Miniserver
  first (see `tests/test_loxone_ws_protocol.py` and the design notes in root
  `AGENTS.md` for why the obvious-looking check was wrong).

For any bridge change, run:

```bash
PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 python3 tests/test_loxone_bridge.py
PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 python3 tests/test_loxone_ws_protocol.py
python3 -m py_compile bin/loxone-bridge tests/*.py
```

Add a fake-server regression test (`tests/fake_loxone.py` for the Miniserver,
`tests/fake_camera.py` for the camera, `tests/fake_loxone_ws.py` for the
RSA/WebSocket push handshake) for authentication, reconnect, timeout,
generation, hostile-input, or command-translation changes.

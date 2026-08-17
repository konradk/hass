# Test guidance

Tests are intentionally runnable on a clean checkout without pytest, npm
packages, a real Loxone Miniserver, or network access.

- Python tests use the standard library and executable test modules. JavaScript
  tests run directly with Node and load production QML-library JavaScript after
  removing `.pragma library`.
- Use `FakeLoxone` for Miniserver HTTP integration behavior, `FakeCamera` for
  camera-stream behavior (snapshot and MJPEG), and `FakeLoxoneWs` for the
  RSA/WebSocket push handshake (`LivePushThread`). Never use real URLs,
  passwords, keyrings, or user configuration in tests.
- `FakeLoxoneWs` shells out to the system `openssl` binary to generate a
  throwaway RSA keypair and to independently decrypt what the bridge's
  client-side encryption produced — this is a system tool, not a Python
  package, and is the only way to verify RSA correctness without
  reimplementing decryption (which the bridge itself never needs) purely to
  test encryption. Skip gracefully (`openssl_available()`), never fail hard,
  if it is absent from the runner.
- Always terminate helper processes and fake servers in `finally` blocks.
- Prefer observable behavioral assertions over matching source text. Contract
  string checks are acceptable only for invariants that cannot reasonably be
  exercised without a Quickshell runtime.
- Security regressions should prove both the unsafe input and the safe outcome:
  no password in output, no plaintext fallback, bounded memory/input handling,
  correct generation, or bounded retry rate.
- Timing tests need generous outer budgets but should assert rate limits or
  state transitions precisely enough to catch reconnect storms and deadlocks.
- Keep bridge tests isolated from global packages with `PYTHONNOUSERSITE=1` and
  avoid creating bytecode with `PYTHONDONTWRITEBYTECODE=1`.

When production behavior changes, update the smallest relevant test first, then
run the complete command list from the root `AGENTS.md` before handoff.

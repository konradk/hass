#!/usr/bin/env python3
"""Integration tests for bin/hass-bridge. Run: python3 tests/test_bridge.py

Drives the bridge as the shell does — NDJSON on stdin, NDJSON on stdout —
against tests/fake_ha.py. Standard library only, no pytest, matching the
bridge's own dependency rule.
"""

import json
import os
import socket
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fake_ha import FakeHA  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRIDGE = os.path.join(ROOT, "bin", "hass-bridge")

FAILURES = []


class BridgeProc:
    def __init__(self, *args, env=None):
        process_env = os.environ.copy()
        if env:
            process_env.update(env)
        self.proc = subprocess.Popen(
            [sys.executable, BRIDGE] + list(args),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1,
            env=process_env)
        self.events = []
        self._lock = threading.Lock()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                continue
            with self._lock:
                self.events.append(event)

    def send(self, obj):
        payload = dict(obj)
        payload.setdefault("protocolVersion", 1)
        self.proc.stdin.write(json.dumps(payload) + "\n")
        self.proc.stdin.flush()

    def snapshot(self):
        with self._lock:
            return list(self.events)

    def wait_for(self, predicate, budget=10.0, after=0):
        end = time.time() + budget
        while time.time() < end:
            for event in self.snapshot()[after:]:
                if predicate(event):
                    return event
            time.sleep(0.05)
        return None

    def phases(self):
        return [e["phase"] for e in self.snapshot() if e["ev"] == "phase"]

    def stop(self):
        try:
            self.send({"op": "shutdown"})
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


def check(name, condition, detail=""):
    if condition:
        print("  ok   %s" % name)
    else:
        print("  FAIL %s %s" % (name, detail))
        FAILURES.append(name)


def test_live_happy_path():
    print("live: connect, snapshot, service call, live event")
    server = FakeHA()
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "token": "tok"})

        connected = bridge.wait_for(
            lambda e: e["ev"] == "phase" and e["phase"] == "connected")
        check("reaches connected", connected is not None)
        check("connection events carry a generation",
              connected is not None and isinstance(connected.get("generation"), int),
              connected)
        check("connection events carry the NDJSON protocol version",
              connected is not None and connected.get("protocolVersion") == 1,
              connected)

        states = bridge.wait_for(lambda e: e["ev"] == "states")
        check("sends state snapshot", states is not None and len(states["entities"]) == 1)

        registries = bridge.wait_for(lambda e: e["ev"] == "registries")
        check("sends registries",
              registries is not None and registries["areas"][0]["area_id"] == "a1")

        bridge.send({"op": "call_service", "domain": "light", "service": "turn_on",
                     "entity_id": "light.test", "data": {"brightness_pct": 40},
                     "tag": "call-1"})

        result = bridge.wait_for(
            lambda e: e["ev"] == "result" and e.get("tag") == "call-1")
        check("acknowledges the service call", result is not None and result["ok"])

        changed = bridge.wait_for(lambda e: e["ev"] == "state_changed")
        check("forwards the state_changed event",
              changed is not None and changed["entity"]["state"] == "on")

        # entity_id belongs in target, and extra arguments in service_data --
        # sending entity_id inside service_data is deprecated in Home Assistant.
        call = server.calls[0] if server.calls else {}
        check("uses target.entity_id",
              call.get("target", {}).get("entity_id") == "light.test", call)
        check("passes service data",
              call.get("service_data", {}).get("brightness_pct") == 40, call)
    finally:
        bridge.stop()
        server.stop()


def test_rejected_service_call_is_reported():
    print("live: a rejected service call comes back tagged and failed")
    # The shell rolls an optimistically flipped switch back when it sees this,
    # so the tag has to survive the round trip or the wrong row gets reverted.
    server = FakeHA(fail_calls=True)
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "token": "tok"})
        bridge.wait_for(lambda e: e["ev"] == "phase" and e["phase"] == "connected")

        bridge.send({"op": "call_service", "domain": "light", "service": "turn_on",
                     "entity_id": "light.test", "tag": "toggle:light.test"})
        result = bridge.wait_for(
            lambda e: e["ev"] == "result" and e.get("tag") == "toggle:light.test")
        check("reports the failure", result is not None and not result["ok"], result)
        check("keeps the server's reason",
              result is not None and "Not allowed" in result.get("error", ""), result)
    finally:
        bridge.stop()
        server.stop()


def test_auth_invalid_once_is_retried():
    print("auth: a single rejection is retried (Home Assistant restart)")
    server = FakeHA(auth_mode="invalid_once")
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "token": "tok"})
        connected = bridge.wait_for(
            lambda e: e["ev"] == "phase" and e["phase"] == "connected", budget=12)
        check("recovers after one auth_invalid", connected is not None)
        check("never surfaced an error phase", "error" not in bridge.phases(),
              bridge.phases())
        check("reconnected a second time", server.connections >= 2, server.connections)
    finally:
        bridge.stop()
        server.stop()


def test_auth_invalid_twice_stops():
    print("auth: repeated rejection surfaces an error and stops retrying")
    server = FakeHA(auth_mode="invalid")
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "token": "bad"})
        error = bridge.wait_for(
            lambda e: e["ev"] == "phase" and e["phase"] == "error", budget=12)
        check("reports the error phase", error is not None)
        check("passes the server's message through",
              error is not None and "Invalid access token" in error.get("error", ""),
              error)

        settled = server.connections
        time.sleep(3)
        check("stops hammering the server after a bad token",
              server.connections == settled,
              "%s -> %s" % (settled, server.connections))

        # A queued command must not hang the shell while disconnected.
        bridge.send({"op": "call_service", "domain": "light", "service": "turn_on",
                     "entity_id": "light.test", "tag": "while-down"})
        refused = bridge.wait_for(
            lambda e: e["ev"] == "result" and e.get("tag") == "while-down")
        check("fails calls fast while disconnected",
              refused is not None and not refused["ok"], refused)
    finally:
        bridge.stop()
        server.stop()


def test_server_cannot_echo_token_into_events():
    print("security: a malicious auth error cannot echo the token into output")
    token = "TOP_SECRET_TEST_TOKEN"
    server = FakeHA(auth_mode="invalid", echo_auth_token=True)
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "token": token})
        error = bridge.wait_for(
            lambda e: e["ev"] == "phase" and e["phase"] == "error", budget=12)
        check("authentication still fails", error is not None, bridge.snapshot())
        serialized = json.dumps(bridge.snapshot())
        check("token is redacted from every NDJSON event", token not in serialized,
              serialized)
        check("redaction marker remains actionable", "[redacted]" in serialized,
              serialized)
    finally:
        bridge.stop()
        server.stop()


def test_protocol_version_mismatch_is_explicit():
    print("protocol: incompatible NDJSON versions fail explicitly")
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": "http://127.0.0.1:1",
                     "token": "tok", "generation": 9,
                     "protocolVersion": 999})
        error = bridge.wait_for(
            lambda e: e["ev"] == "phase" and e["phase"] == "error")
        check("reports a protocol error",
              error is not None and error.get("errorKind") == "protocol", error)
        check("labels the rejected generation",
              error is not None and error.get("generation") == 9, error)
    finally:
        bridge.stop()


def test_reconnects_after_server_drop():
    print("resilience: reconnects when the server hangs up")
    # Drop the connection right after the auth exchange, on the first session.
    server = FakeHA(drop_after=1)
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "token": "tok"})
        time.sleep(6)
        check("retried the connection", server.connections >= 2, server.connections)
    finally:
        bridge.stop()
        server.stop()


def test_unreachable_host_backs_off():
    print("resilience: an unreachable host backs off instead of spinning")
    bridge = BridgeProc()
    try:
        # Port 1 on loopback refuses instantly, so any spin would be visible.
        bridge.send({"op": "config", "url": "http://127.0.0.1:1", "token": "tok"})
        time.sleep(4)
        attempts = len([e for e in bridge.snapshot()
                        if e["ev"] == "phase" and e["phase"] == "connecting"])
        check("stays connecting without a stampede", 1 <= attempts <= 6, attempts)
        check("never claims connected",
              "connected" not in bridge.phases(), bridge.phases())
    finally:
        bridge.stop()


def test_empty_config_stops_a_doomed_attempt():
    print("control: an empty config cancels an in-flight connection")
    # This is what the settings overlay's Cancel button sends. Without it a
    # mistyped hostname retries forever with no way out but editing the file.
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": "http://127.0.0.1:1", "token": "tok"})
        connecting = bridge.wait_for(
            lambda e: e["ev"] == "phase" and e["phase"] == "connecting")
        check("starts trying", connecting is not None)

        bridge.send({"op": "config", "url": "", "token": ""})
        idle = bridge.wait_for(lambda e: e["ev"] == "phase" and e["phase"] == "idle")
        check("goes idle on an empty config", idle is not None)

        before = len(bridge.snapshot())
        time.sleep(3)
        after = [e for e in bridge.snapshot()[before:] if e["ev"] == "phase"]
        check("stops emitting connection attempts", after == [], after)
    finally:
        bridge.stop()


def test_explicit_disconnect_stops_demo():
    print("control: explicit disconnect stops demo events and returns idle")
    bridge = BridgeProc("--demo")
    try:
        bridge.send({"op": "config", "generation": 7})
        connected = bridge.wait_for(
            lambda e: e["ev"] == "phase" and e["phase"] == "connected")
        check("demo connected", connected is not None)

        bridge.send({"op": "disconnect", "generation": 8})
        idle = bridge.wait_for(
            lambda e: e["ev"] == "phase" and e["phase"] == "idle"
            and e.get("generation") == 8)
        check("explicit disconnect reaches idle", idle is not None, bridge.phases())
        marker = len(bridge.snapshot())
        time.sleep(6)
        late = [e for e in bridge.snapshot()[marker:]
                if e.get("ev") in ("state_changed", "states")]
        check("disconnected demo emits no more state", late == [], late)
    finally:
        bridge.stop()


def test_ready_waits_for_subscription_and_snapshot():
    print("sync: connected waits for the subscription and initial snapshot")
    server = FakeHA(delays={"get_states": 1.2})
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "token": "tok"})
        time.sleep(0.5)
        check("does not claim connected during snapshot",
              "connected" not in bridge.phases(), bridge.phases())
        connected = bridge.wait_for(
            lambda e: e["ev"] == "phase" and e["phase"] == "connected")
        check("becomes connected after initial sync", connected is not None)
    finally:
        bridge.stop()
        server.stop()


def test_rejected_subscription_never_becomes_ready():
    print("sync: a rejected state subscription reconnects instead of going ready")
    server = FakeHA(fail_requests={"subscribe_events"})
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "token": "tok"})
        time.sleep(7)
        check("never claims connected", "connected" not in bridge.phases(), bridge.phases())
        check("retries the failed initial sync", server.connections >= 2,
              server.connections)
    finally:
        bridge.stop()
        server.stop()


def test_slow_initial_snapshot_reconnects():
    print("sync: a snapshot beyond the request deadline cannot wedge connecting")
    server = FakeHA(delays={"get_states": 6.0})
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "token": "tok"})
        time.sleep(11)
        check("never claims connected", "connected" not in bridge.phases(), bridge.phases())
        check("retries after the sync timeout", server.connections >= 2,
              server.connections)
    finally:
        bridge.stop()
        server.stop()


def test_partial_registries_are_emitted():
    print("sync: one rejected registry still yields a partial registry event")
    server = FakeHA(fail_requests={"config/device_registry/list"})
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "token": "tok"})
        registries = bridge.wait_for(lambda e: e["ev"] == "registries")
        check("emits partial registries", registries is not None, registries)
        check("marks the missing registry",
              registries is not None
              and registries.get("partial") is True
              and "device_registry" in registries.get("missing", []),
              registries)
        check("keeps successful registry data",
              registries is not None and len(registries.get("areas", [])) == 1,
              registries)
    finally:
        bridge.stop()
        server.stop()


def test_generation_changes_isolate_instances():
    print("lifecycle: events are labeled with the active connection generation")
    first = FakeHA()
    second = FakeHA()
    first.states[0]["entity_id"] = "light.first"
    second.states[0]["entity_id"] = "light.second"
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": first.url, "token": "one",
                     "generation": 41})
        old = bridge.wait_for(
            lambda e: e["ev"] == "states" and e.get("generation") == 41)
        check("first snapshot has generation 41", old is not None, old)

        marker = len(bridge.snapshot())
        bridge.send({"op": "config", "url": second.url, "token": "two",
                     "generation": 42})
        new = bridge.wait_for(
            lambda e: e["ev"] == "states" and e.get("generation") == 42)
        check("second snapshot has generation 42", new is not None, new)
        check("second snapshot belongs to server B",
              new is not None and new["entities"][0]["entity_id"] == "light.second",
              new)
        events = bridge.snapshot()
        new_index = events.index(new) if new in events else marker
        stale = [e for e in events[new_index:]
                 if e.get("generation") == 41
                 and e.get("ev") in ("states", "state_changed", "registries", "config")]
        check("no old data follows the switch", stale == [], stale)
    finally:
        bridge.stop()
        first.stop()
        second.stop()


def test_environment_proxy_is_ignored():
    print("security: proxy environment cannot intercept the Home Assistant token")
    server = FakeHA()
    bridge = BridgeProc(env={
        "HTTP_PROXY": "http://127.0.0.1:1",
        "HTTPS_PROXY": "http://127.0.0.1:1",
        "ALL_PROXY": "http://127.0.0.1:1",
        "NO_PROXY": "",
        "no_proxy": "",
    })
    try:
        bridge.send({"op": "config", "url": server.url, "token": "tok"})
        connected = bridge.wait_for(
            lambda e: e["ev"] == "phase" and e["phase"] == "connected")
        check("connects directly despite proxy variables", connected is not None)
    finally:
        bridge.stop()
        server.stop()


def test_ipv6_websocket_connection():
    print("transport: IPv6 WebSocket connection")
    if not socket.has_ipv6:
        check("IPv6 unavailable on this host (skipped)", True)
        return
    try:
        server = FakeHA(host="::1")
    except OSError:
        check("IPv6 loopback unavailable on this host (skipped)", True)
        return
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "token": "tok"})
        connected = bridge.wait_for(
            lambda e: e["ev"] == "phase" and e["phase"] == "connected")
        check("connects over IPv6", connected is not None, bridge.snapshot())
    finally:
        bridge.stop()
        server.stop()


def test_wss_certificate_policy():
    print("transport: wss verifies certificates unless diagnostics opts out")
    server = FakeHA(tls=True)
    verified = BridgeProc()
    insecure = None
    try:
        verified.send({"op": "config", "url": server.url, "token": "tok"})
        tls_error = verified.wait_for(
            lambda e: e["ev"] == "phase" and e.get("error"), budget=6)
        check("self-signed TLS is rejected by default",
              tls_error is not None
              and "certificate" in tls_error.get("error", "").lower(),
              tls_error)
        check("verified client never claims connected",
              "connected" not in verified.phases(), verified.phases())
        verified.stop()
        verified = None

        insecure = BridgeProc("--insecure")
        insecure.send({"op": "config", "url": server.url, "token": "tok"})
        connected = insecure.wait_for(
            lambda e: e["ev"] == "phase" and e["phase"] == "connected")
        check("explicit diagnostic override can connect", connected is not None,
              insecure.snapshot())
    finally:
        if verified is not None:
            verified.stop()
        if insecure is not None:
            insecure.stop()
        server.stop()


def test_invalid_websocket_message_is_controlled():
    print("security: invalid JSON drops the connection without killing the bridge")
    server = FakeHA(invalid_message=True)
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "token": "tok"})
        time.sleep(7)
        check("bridge survives invalid JSON", bridge.proc.poll() is None)
        check("invalid JSON triggers reconnect", server.connections >= 2,
              server.connections)
        check("never claims connected", "connected" not in bridge.phases(), bridge.phases())
    finally:
        bridge.stop()
        server.stop()


def test_fragment_flood_hits_size_limit():
    print("security: empty fragments plus an oversized tail are bounded")
    server = FakeHA(empty_fragments=2000, giant_frame=True)
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "token": "tok"})
        time.sleep(3)
        check("bridge survives fragmented hostile input", bridge.proc.poll() is None)
        check("fragmented hostile input triggers reconnect", server.connections >= 2,
              server.connections)
    finally:
        bridge.stop()
        server.stop()


def test_reports_the_unit_system():
    print("live: the instance temperature unit reaches the shell")
    # climate entities carry no unit of their own, so this event is the only
    # thing standing between "Target 22°C" and a bare "Target 22".
    server = FakeHA()
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "token": "tok"})
        config = bridge.wait_for(lambda e: e["ev"] == "config")
        check("sends the unit system",
              config is not None and config["unit_temperature"] == "°C", config)
    finally:
        bridge.stop()
        server.stop()


def test_unusable_urls_are_refused_not_downgraded():
    print("security: a bad scheme is an error, never a plaintext fallback")
    # A typo must not put a long-lived access token on the wire unencrypted,
    # so anything that is not http/https/ws/wss stops the attempt outright.
    for url in ("htps://ha.example.com", "ftp://ha.example.com"):
        bridge = BridgeProc()
        try:
            bridge.send({"op": "config", "url": url, "token": "tok"})
            error = bridge.wait_for(
                lambda e: e["ev"] == "phase" and e["phase"] == "error", budget=6)
            check("refuses %s" % url,
                  error is not None and "unsupported scheme" in error.get("error", ""),
                  error)
            check("never reached connected (%s)" % url,
                  "connected" not in bridge.phases(), bridge.phases())
        finally:
            bridge.stop()


def test_unparseable_url_does_not_kill_the_bridge():
    print("resilience: an unparseable URL is an error, not a dead helper")
    # urlsplit raises ValueError("Invalid IPv6 URL") on an unbalanced bracket,
    # and .port raises on a non-numeric one. Uncaught, that took the whole
    # process down: the shell does not restart the helper on its own, so one
    # half-pasted URL left the bar widget dead for the rest of the session.
    for url in ("https://ha.local:8123]", "[https://ha.local:8123]",
                "https://a]b", "https://ha.local:port"):
        bridge = BridgeProc()
        try:
            bridge.send({"op": "config", "url": url, "token": "tok"})
            error = bridge.wait_for(
                lambda e: e["ev"] == "phase" and e["phase"] == "error", budget=6)
            check("reports %s as an error" % url, error is not None, error)
            check("never reached connected (%s)" % url,
                  "connected" not in bridge.phases(), bridge.phases())

            # The point of the test: still alive, still answering commands.
            time.sleep(0.5)
            check("helper is still running (%s)" % url,
                  bridge.proc.poll() is None, bridge.proc.poll())
            bridge.send({"op": "config", "url": "", "token": "",
                         "generation": 9})
            idle = bridge.wait_for(
                lambda e: e["ev"] == "phase" and e["phase"] == "idle"
                and e.get("generation") == 9, budget=6)
            check("still accepts a corrected config (%s)" % url,
                  idle is not None, bridge.phases())
        finally:
            bridge.stop()


def test_scheme_less_host_is_assumed_secure():
    print("usability: 'host:8123' is understood, and assumed to be https")
    bridge = BridgeProc()
    try:
        # Nothing listens on port 1, so this can only get as far as the socket.
        # What matters is that it tries a host at all instead of failing to
        # parse, and that the guess is TLS rather than cleartext.
        bridge.send({"op": "config", "url": "127.0.0.1:1", "token": "tok"})
        attempt = bridge.wait_for(
            lambda e: e["ev"] == "phase" and e.get("error"), budget=6)
        check("parses a bare host:port",
              attempt is not None and "scheme" not in attempt.get("error", ""),
              attempt)
    finally:
        bridge.stop()


def test_oversized_frame_is_refused():
    print("security: an absurd frame length drops the connection, not the shell")
    server = FakeHA(giant_frame=True)
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "token": "tok"})
        # The bridge must survive and go back to retrying rather than sit there
        # allocating until the OOM killer notices.
        time.sleep(3)
        check("bridge is still alive", bridge.proc.poll() is None)
        # Dropping and reconnecting is the proof it refused the frame; hanging
        # on the read would leave a single "connected" and nothing after it.
        phases = bridge.phases()
        check("drops the connection and retries",
              phases.count("connecting") >= 2, phases)
    finally:
        bridge.stop()
        server.stop()


def test_local_url_is_preferred_when_reachable():
    print("local: a reachable local URL is used ahead of the primary URL")
    # HASS_BRIDGE_TEST_SSID is a test-only seam (see current_wifi_ssid in
    # bin/hass-bridge) standing in for actually being joined to trustedNetwork
    # — the bridge has no controllable Wi-Fi to check in CI.
    local = FakeHA()
    bridge = BridgeProc(env={"HASS_BRIDGE_TEST_SSID": "Home"})
    try:
        # Port 1 refuses instantly, so a successful connection can only have
        # gone through localUrl.
        bridge.send({"op": "config", "url": "http://127.0.0.1:1",
                     "localUrl": local.url, "trustedNetwork": "Home", "token": "tok"})
        connected = bridge.wait_for(
            lambda e: e["ev"] == "phase" and e["phase"] == "connected")
        check("reaches connected", connected is not None)
        check("flags the connection as local",
              connected is not None and connected.get("usingLocal") is True,
              connected)
        check("the local server saw the connection", local.connections >= 1,
              local.connections)
    finally:
        bridge.stop()
        local.stop()


def test_falls_back_to_primary_when_local_is_unreachable():
    print("local: an unreachable local URL falls back to the primary URL")
    server = FakeHA()
    bridge = BridgeProc(env={"HASS_BRIDGE_TEST_SSID": "Home"})
    try:
        bridge.send({"op": "config", "url": server.url,
                     "localUrl": "http://127.0.0.1:1", "trustedNetwork": "Home",
                     "token": "tok"})
        connected = bridge.wait_for(
            lambda e: e["ev"] == "phase" and e["phase"] == "connected")
        check("reaches connected", connected is not None)
        check("does not flag the connection as local",
              connected is not None and connected.get("usingLocal") is False,
              connected)
        check("the primary server saw the connection", server.connections >= 1,
              server.connections)
    finally:
        bridge.stop()
        server.stop()


def test_unparseable_local_url_does_not_block_the_primary():
    print("local: a bad local URL is skipped, not fatal")
    # The local URL is optional; a typo there must not stop the primary URL
    # — the one the user actually confirmed — from being tried at all.
    server = FakeHA()
    bridge = BridgeProc(env={"HASS_BRIDGE_TEST_SSID": "Home"})
    try:
        bridge.send({"op": "config", "url": server.url,
                     "localUrl": "https://192.168.1.50:8123]",
                     "trustedNetwork": "Home", "token": "tok"})
        connected = bridge.wait_for(
            lambda e: e["ev"] == "phase" and e["phase"] == "connected")
        check("still reaches connected via the primary URL", connected is not None)
        check("does not flag the connection as local",
              connected is not None and connected.get("usingLocal") is False,
              connected)
    finally:
        bridge.stop()
        server.stop()


def test_local_url_matches_any_of_several_trusted_networks():
    print("local: trustedNetwork accepts a comma-separated list")
    # A router commonly broadcasts more than one SSID (separate 2.4GHz/5GHz
    # names); the current network only has to match one of the list.
    local = FakeHA()
    bridge = BridgeProc(env={"HASS_BRIDGE_TEST_SSID": "Home 5G"})
    try:
        bridge.send({"op": "config", "url": "http://127.0.0.1:1",
                     "localUrl": local.url, "trustedNetwork": "Home, Home 5G",
                     "token": "tok"})
        connected = bridge.wait_for(
            lambda e: e["ev"] == "phase" and e["phase"] == "connected")
        check("reaches connected", connected is not None)
        check("flags the connection as local",
              connected is not None and connected.get("usingLocal") is True,
              connected)
    finally:
        bridge.stop()
        local.stop()


def test_local_url_is_skipped_off_the_trusted_network():
    print("local: a reachable local URL is not used off the trusted network")
    # This is the actual security property: a local URL must never be tried
    # just because it's configured. Home is what's saved; the bridge reports
    # being on CoffeeShop instead, so the local server must never be dialed
    # even though it would happily answer.
    local = FakeHA()
    server = FakeHA()
    bridge = BridgeProc(env={"HASS_BRIDGE_TEST_SSID": "CoffeeShop"})
    try:
        bridge.send({"op": "config", "url": server.url, "localUrl": local.url,
                     "trustedNetwork": "Home", "token": "tok"})
        connected = bridge.wait_for(
            lambda e: e["ev"] == "phase" and e["phase"] == "connected")
        check("reaches connected via the primary URL", connected is not None)
        check("does not flag the connection as local",
              connected is not None and connected.get("usingLocal") is False,
              connected)
        check("the local server was never contacted", local.connections == 0,
              local.connections)
    finally:
        bridge.stop()
        local.stop()
        server.stop()


def test_local_url_without_a_trusted_network_is_never_used():
    print("local: a local URL with no trusted network is never tried")
    # Defense in depth: the settings UI and Service.applyConnection both
    # refuse to save this combination, but the bridge must not rely on that.
    local = FakeHA()
    server = FakeHA()
    bridge = BridgeProc(env={"HASS_BRIDGE_TEST_SSID": "Home"})
    try:
        bridge.send({"op": "config", "url": server.url, "localUrl": local.url,
                     "token": "tok"})
        connected = bridge.wait_for(
            lambda e: e["ev"] == "phase" and e["phase"] == "connected")
        check("reaches connected via the primary URL", connected is not None)
        check("the local server was never contacted", local.connections == 0,
              local.connections)
    finally:
        bridge.stop()
        local.stop()
        server.stop()


def test_unknown_wifi_state_fails_closed():
    print("local: an undeterminable Wi-Fi state never falls back to trusted")
    # HASS_BRIDGE_TEST_SSID="" stands in for current_wifi_ssid() returning
    # None — no NetworkManager, no active Wi-Fi, an nmcli error or timeout.
    local = FakeHA()
    server = FakeHA()
    bridge = BridgeProc(env={"HASS_BRIDGE_TEST_SSID": ""})
    try:
        bridge.send({"op": "config", "url": server.url, "localUrl": local.url,
                     "trustedNetwork": "Home", "token": "tok"})
        connected = bridge.wait_for(
            lambda e: e["ev"] == "phase" and e["phase"] == "connected")
        check("reaches connected via the primary URL", connected is not None)
        check("the local server was never contacted", local.connections == 0,
              local.connections)
    finally:
        bridge.stop()
        local.stop()
        server.stop()


def test_demo_needs_no_server():
    print("demo: runs standalone and drifts on its own")
    bridge = BridgeProc("--demo")
    try:
        bridge.send({"op": "config"})
        states = bridge.wait_for(lambda e: e["ev"] == "states")
        check("serves the demo house", states is not None and len(states["entities"]) == 15)

        climate_id = "climate.living_room_thermostat"
        bridge.send({"op": "call_service", "domain": "climate", "service": "turn_off",
                     "entity_id": climate_id, "tag": "demo-climate-off"})
        climate_off = bridge.wait_for(
            lambda e: e["ev"] == "state_changed"
            and e["entity"]["entity_id"] == climate_id
            and e["entity"]["state"] == "off")
        check("turns off demo climate", climate_off is not None, climate_off)

        bridge.send({"op": "call_service", "domain": "climate", "service": "turn_on",
                     "entity_id": climate_id, "tag": "demo-climate-on"})
        climate_on = bridge.wait_for(
            lambda e: e["ev"] == "state_changed"
            and e["entity"]["entity_id"] == climate_id
            and e["entity"]["state"] == "heat")
        check("turns on demo climate", climate_on is not None, climate_on)

        bridge.send({"op": "call_service", "domain": "climate", "service": "set_hvac_mode",
                     "entity_id": climate_id, "data": {"hvac_mode": "cool"},
                     "tag": "demo-climate-hvac"})
        hvac_mode = bridge.wait_for(
            lambda e: e["ev"] == "state_changed"
            and e["entity"]["entity_id"] == climate_id
            and e["entity"]["state"] == "cool")
        check("sets the advertised demo HVAC mode", hvac_mode is not None, hvac_mode)


        bridge.send({"op": "call_service", "domain": "climate", "service": "set_fan_mode",
                     "entity_id": climate_id, "data": {"fan_mode": "high"},
                     "tag": "demo-climate-fan"})
        fan_mode = bridge.wait_for(
            lambda e: e["ev"] == "state_changed"
            and e["entity"]["entity_id"] == climate_id
            and e["entity"]["attributes"].get("fan_mode") == "high")
        check("sets the advertised demo climate fan mode", fan_mode is not None, fan_mode)

        bridge.send({"op": "call_service", "domain": "climate", "service": "set_preset_mode",
                     "entity_id": climate_id, "data": {"preset_mode": "away"},
                     "tag": "demo-climate-preset"})
        preset_mode = bridge.wait_for(
            lambda e: e["ev"] == "state_changed"
            and e["entity"]["entity_id"] == climate_id
            and e["entity"]["attributes"].get("preset_mode") == "away")
        check("sets the advertised demo climate preset", preset_mode is not None, preset_mode)

        bridge.send({"op": "call_service", "domain": "climate", "service": "set_swing_mode",
                     "entity_id": climate_id, "data": {"swing_mode": "both"},
                     "tag": "demo-climate-swing"})
        swing_mode = bridge.wait_for(
            lambda e: e["ev"] == "state_changed"
            and e["entity"]["entity_id"] == climate_id
            and e["entity"]["attributes"].get("swing_mode") == "both")
        check("sets the advertised demo climate swing mode", swing_mode is not None, swing_mode)


        bridge.send({"op": "call_service", "domain": "cover", "service": "open_cover",
                     "entity_id": "cover.garage_door", "tag": "demo-1"})
        changed = bridge.wait_for(
            lambda e: e["ev"] == "state_changed"
            and e["entity"]["entity_id"] == "cover.garage_door")
        check("mutates demo state", changed is not None and changed["entity"]["state"] == "open")

        blinds_id = "cover.living_room_blinds"
        bridge.send({"op": "call_service", "domain": "cover", "service": "set_cover_position",
                     "entity_id": blinds_id, "data": {"position": 42},
                     "tag": "demo-cover-position"})
        positioned = bridge.wait_for(
            lambda e: e["ev"] == "state_changed"
            and e["entity"]["entity_id"] == blinds_id
            and e["entity"]["attributes"].get("current_position") == 42)
        check("sets the demo cover position", positioned is not None, positioned)
        check("a partial position reads as open",
              positioned is not None and positioned["entity"]["state"] == "open")

        bridge.send({"op": "call_service", "domain": "cover", "service": "set_cover_position",
                     "entity_id": blinds_id, "data": {"position": 0},
                     "tag": "demo-cover-position-closed"})
        closed = bridge.wait_for(
            lambda e: e["ev"] == "state_changed"
            and e["entity"]["entity_id"] == blinds_id
            and e["entity"]["attributes"].get("current_position") == 0)
        check("zero position reads as closed",
              closed is not None and closed["entity"]["state"] == "closed")

        # Home Assistant's own schema rejects an out-of-range position rather
        # than clamping it, so the demo backend must fail the call the same
        # way instead of silently accepting 150 as 100.
        bridge.send({"op": "call_service", "domain": "cover", "service": "set_cover_position",
                     "entity_id": blinds_id, "data": {"position": 150},
                     "tag": "demo-cover-position-range"})
        rejected_range = bridge.wait_for(
            lambda e: e["ev"] == "result" and e.get("tag") == "demo-cover-position-range")
        check("rejects an out-of-range demo cover position",
              rejected_range is not None and rejected_range.get("ok") is False,
              rejected_range)

        bridge.send({"op": "call_service", "domain": "cover", "service": "set_cover_position",
                     "entity_id": blinds_id, "data": {"position": "half"},
                     "tag": "demo-cover-position-bad"})
        rejected_position = bridge.wait_for(
            lambda e: e["ev"] == "result" and e.get("tag") == "demo-cover-position-bad")
        check("rejects a non-numeric demo cover position",
              rejected_position is not None and rejected_position.get("ok") is False,
              rejected_position)

        bridge.send({"op": "call_service", "domain": "cover", "service": "teleport",
                     "entity_id": "cover.garage_door", "tag": "demo-bad"})
        rejected = bridge.wait_for(
            lambda e: e["ev"] == "result" and e.get("tag") == "demo-bad")
        check("rejects an unknown demo service",
              rejected is not None and rejected.get("ok") is False, rejected)

        drift_after = len(bridge.snapshot())
        drift = bridge.wait_for(
            lambda e: e["ev"] == "state_changed"
            and e["entity"]["entity_id"].startswith("climate."),
            budget=12, after=drift_after)
        check("emits unprompted events", drift is not None)
    finally:
        bridge.stop()


# -- camera snapshots ----------------------------------------------------------

def connected_bridge(server, env=None, *args):
    bridge = BridgeProc(*args, env=env)
    bridge.send({"op": "config", "url": server.url, "token": "tok"})
    connected = bridge.wait_for(
        lambda e: e["ev"] == "phase" and e["phase"] == "connected")
    check("connects first", connected is not None,
          [e for e in bridge.snapshot() if e["ev"] in ("phase", "log")])
    return bridge


def snapshot_event(bridge, entity_id, after=0, budget=10.0):
    return bridge.wait_for(
        lambda e: e["ev"] == "snapshot" and e.get("entity_id") == entity_id,
        budget=budget, after=after)


def test_camera_snapshot_is_fetched():
    print("camera: a snapshot is fetched over HTTP and handed over as a private file")
    image = b"\xff\xd8" + os.urandom(2048) + b"\xff\xd9"
    server = FakeHA(camera_image=image)
    bridge = connected_bridge(server)
    path = ""
    try:
        bridge.send({"op": "snapshot", "entity_id": "camera.front"})
        event = snapshot_event(bridge, "camera.front")
        check("reports a snapshot", event is not None and event.get("ok") is True, event)
        path = (event or {}).get("path", "")
        check("snapshot events carry a generation",
              event is not None and isinstance(event.get("generation"), int), event)
        check("the file holds the image bytes",
              os.path.isfile(path) and open(path, "rb").read() == image, path)
        check("the snapshot directory is private",
              os.path.isdir(os.path.dirname(path))
              and os.stat(os.path.dirname(path)).st_mode & 0o077 == 0, path)
        check("the snapshot file is private",
              os.path.isfile(path) and os.stat(path).st_mode & 0o077 == 0, path)
        request = server.camera_requests[0] if server.camera_requests else ("", "")
        check("asks the camera proxy for that entity",
              request[0] == "/api/camera_proxy/camera.front", request)
        check("authenticates with the bearer token", request[1] == "Bearer tok", request)
        check("the token never reaches the shell",
              all("Bearer" not in json.dumps(e) and '"tok"' not in json.dumps(e)
                  for e in bridge.snapshot()), bridge.snapshot())

        after = len(bridge.snapshot())
        bridge.send({"op": "snapshot", "entity_id": "camera.front"})
        second = snapshot_event(bridge, "camera.front", after=after)
        check("a refresh lands in a new file so the image reloads",
              second is not None and second.get("path") != path, second)
        bridge.wait_for(lambda e: False, budget=0.3)
        check("superseded snapshots are deleted", not os.path.exists(path), path)
        path = (second or {}).get("path", path)
    finally:
        bridge.stop()
        server.stop()
    check("snapshots are removed when the bridge exits",
          path and not os.path.exists(os.path.dirname(path)), path)


def test_snapshot_refuses_anything_but_a_camera_id():
    print("camera: only well-formed camera entity ids are fetched")
    server = FakeHA()
    bridge = connected_bridge(server)
    try:
        for bad in ("light.test", "camera.../../api/states", "camera.a?b=1",
                    "camera.a/b", "camera.", "", 7):
            bridge.send({"op": "snapshot", "entity_id": bad})
        bridge.wait_for(lambda e: False, budget=1.0)
        refusals = [e for e in bridge.snapshot()
                    if e["ev"] == "snapshot" and e.get("ok") is False]
        check("each refusal is reported", len(refusals) == 7, refusals)
        check("nothing was requested", server.camera_requests == [],
              server.camera_requests)
    finally:
        bridge.stop()
        server.stop()


def test_snapshot_needs_a_connection():
    print("camera: no snapshot is attempted before the connection is ready")
    bridge = BridgeProc()
    try:
        bridge.send({"op": "snapshot", "entity_id": "camera.front"})
        event = snapshot_event(bridge, "camera.front")
        check("reports not connected",
              event is not None and event.get("ok") is False, event)
    finally:
        bridge.stop()


def test_snapshot_failures_never_echo_the_token():
    print("camera: a failed snapshot is reported without the token")
    server = FakeHA(camera_status=401, camera_content_type="text/plain",
                    camera_body=b"bad token tok-secret-value")
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "token": "tok-secret-value"})
        bridge.wait_for(lambda e: e["ev"] == "phase" and e["phase"] == "connected")
        bridge.send({"op": "snapshot", "entity_id": "camera.front"})
        event = snapshot_event(bridge, "camera.front")
        check("reports the failure", event is not None and event.get("ok") is False, event)
        check("no path for a failure", event is not None and "path" not in event, event)
        check("the token is not in any event",
              all("tok-secret-value" not in json.dumps(e) for e in bridge.snapshot()))
    finally:
        bridge.stop()
        server.stop()


def test_snapshot_must_be_an_image():
    print("camera: a non-image response is refused")
    server = FakeHA(camera_content_type="text/html", camera_image=b"<html></html>")
    bridge = connected_bridge(server)
    try:
        bridge.send({"op": "snapshot", "entity_id": "camera.front"})
        event = snapshot_event(bridge, "camera.front")
        check("refuses it", event is not None and event.get("ok") is False, event)
    finally:
        bridge.stop()
        server.stop()


def test_oversized_snapshot_is_refused():
    print("camera: an oversized snapshot is refused rather than buffered")
    server = FakeHA(camera_image=b"\0" * (9 * 1024 * 1024))
    bridge = connected_bridge(server)
    try:
        bridge.send({"op": "snapshot", "entity_id": "camera.front"})
        event = snapshot_event(bridge, "camera.front")
        check("refuses it", event is not None and event.get("ok") is False, event)
    finally:
        bridge.stop()
        server.stop()


def test_snapshot_ignores_proxy_environment():
    print("security: proxy environment cannot intercept a snapshot request")
    server = FakeHA()
    bridge = connected_bridge(server, env={
        "HTTP_PROXY": "http://127.0.0.1:1",
        "HTTPS_PROXY": "http://127.0.0.1:1",
        "ALL_PROXY": "http://127.0.0.1:1",
        "NO_PROXY": "",
        "no_proxy": "",
    })
    try:
        bridge.send({"op": "snapshot", "entity_id": "camera.front"})
        event = snapshot_event(bridge, "camera.front")
        check("fetches directly", event is not None and event.get("ok") is True, event)
    finally:
        bridge.stop()
        server.stop()


def test_snapshot_over_tls():
    print("camera: snapshots follow the connection over https")
    server = FakeHA(tls=True)
    bridge = connected_bridge(server, None, "--insecure")
    try:
        bridge.send({"op": "snapshot", "entity_id": "camera.front"})
        event = snapshot_event(bridge, "camera.front")
        check("fetches over https", event is not None and event.get("ok") is True, event)
    finally:
        bridge.stop()
        server.stop()


def test_snapshot_uses_the_connected_local_url():
    print("camera: a snapshot goes to the address the connection went through")
    local = FakeHA()
    bridge = BridgeProc(env={"HASS_BRIDGE_TEST_SSID": "Home"})
    try:
        bridge.send({"op": "config", "url": "http://127.0.0.1:1",
                     "localUrl": local.url, "trustedNetwork": "Home", "token": "tok"})
        bridge.wait_for(lambda e: e["ev"] == "phase" and e["phase"] == "connected")
        bridge.send({"op": "snapshot", "entity_id": "camera.front"})
        event = snapshot_event(bridge, "camera.front")
        check("fetches through the local URL",
              event is not None and event.get("ok") is True
              and len(local.camera_requests) == 1, event)
    finally:
        bridge.stop()
        local.stop()


def test_demo_camera_snapshot():
    print("demo: the demo camera produces a snapshot")
    bridge = BridgeProc("--demo")
    try:
        bridge.send({"op": "config"})
        bridge.wait_for(lambda e: e["ev"] == "phase" and e["phase"] == "connected")
        bridge.send({"op": "snapshot", "entity_id": "camera.garage_driveway"})
        event = snapshot_event(bridge, "camera.garage_driveway")
        check("reports a snapshot", event is not None and event.get("ok") is True, event)
        path = (event or {}).get("path", "")
        check("writes an image file", os.path.isfile(path) and os.path.getsize(path) > 0,
              path)
    finally:
        bridge.stop()


# -- camera streams ------------------------------------------------------------

def stream_event(bridge, entity_id, after=0, budget=10.0):
    return bridge.wait_for(
        lambda e: e["ev"] == "stream" and e.get("entity_id") == entity_id,
        budget=budget, after=after)


def local_get(url, raw_path=None):
    """GET from the bridge's relay without any proxy, returning (status, body).

    raw_path sends that request target verbatim, past any client-side
    normalisation, to probe what the relay itself accepts.
    """
    import http.client
    import urllib.parse
    parts = urllib.parse.urlsplit(url)
    if not parts.hostname:
        return None, b"no stream url"
    conn = http.client.HTTPConnection(parts.hostname, parts.port, timeout=5)
    try:
        target = raw_path if raw_path is not None else (
            parts.path + ("?" + parts.query if parts.query else ""))
        conn.request("GET", target)
        response = conn.getresponse()
        return response.status, response.read()
    finally:
        conn.close()


def sibling(url, name):
    return url.rsplit("/", 1)[0] + "/" + name


def test_camera_stream_is_relayed_over_loopback():
    print("stream: Home Assistant's HLS stream is relayed through loopback")
    server = FakeHA()
    bridge = connected_bridge(server, env={
        "HTTP_PROXY": "http://127.0.0.1:1",
        "HTTPS_PROXY": "http://127.0.0.1:1",
        "ALL_PROXY": "http://127.0.0.1:1",
        "NO_PROXY": "",
        "no_proxy": "",
    })
    try:
        bridge.send({"op": "stream_start", "entity_id": "camera.front"})
        event = stream_event(bridge, "camera.front")
        check("reports a stream", event is not None and event.get("ok") is True, event)
        url = (event or {}).get("url", "")
        check("the stream is served from loopback only",
              url.startswith("http://127.0.0.1:"), url)
        check("asks Home Assistant for an HLS stream of that camera",
              server.stream_calls
              and server.stream_calls[0].get("entity_id") == "camera.front"
              and server.stream_calls[0].get("format") == "hls", server.stream_calls)
        check("Home Assistant's stream token does not reach the shell",
              server.stream_token not in json.dumps(bridge.snapshot()), url)

        status, body = local_get(url)
        check("relays the master playlist",
              status == 200 and body == server.hls_files["master_playlist.m3u8"],
              (status, body))
        status, body = local_get(sibling(url, "playlist.m3u8?_HLS_msn=3&_HLS_part=1"))
        check("relays a blocking playlist request", status == 200, (status, body))
        status, body = local_get(sibling(url, "segment/0.m4s"))
        check("relays a segment", status == 200 and body == b"segment-bytes",
              (status, body))
        paths = [p for p, _ in server.hls_requests]
        check("forwards to the stream's own path, query included",
              "/api/hls/hlstoken123/playlist.m3u8?_HLS_msn=3&_HLS_part=1" in paths,
              paths)
        check("never sends the long-lived token with stream requests",
              all(auth == "" for _, auth in server.hls_requests),
              server.hls_requests)
    finally:
        bridge.stop()
        server.stop()


def test_compressed_playlists_keep_their_encoding():
    print("stream: a gzipped playlist is relayed with its Content-Encoding")
    import gzip
    import http.client
    import urllib.parse
    server = FakeHA(hls_gzip=True)
    bridge = connected_bridge(server)
    try:
        bridge.send({"op": "stream_start", "entity_id": "camera.front"})
        url = (stream_event(bridge, "camera.front") or {}).get("url", "")
        parts = urllib.parse.urlsplit(url)
        encoding, body = "", b""
        if parts.hostname:
            conn = http.client.HTTPConnection(parts.hostname, parts.port, timeout=5)
            conn.request("GET", parts.path)
            response = conn.getresponse()
            encoding = response.getheader("Content-Encoding") or ""
            body = response.read()
            conn.close()
        check("passes Content-Encoding through", encoding == "gzip", encoding)
        check("the body is the gzipped playlist",
              body[:2] == b"\x1f\x8b"
              and gzip.decompress(body) == server.hls_files["master_playlist.m3u8"],
              body[:20])
    finally:
        bridge.stop()
        server.stop()


# Home Assistant's live playlist, as served for a real camera: three 2 s
# segments with per-segment timestamps and a start offset.
LIVE_PLAYLIST = (
    b"#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-INDEPENDENT-SEGMENTS\n"
    b"#EXT-X-MAP:URI=\"init.mp4\"\n#EXT-X-TARGETDURATION:2\n"
    b"#EXT-X-MEDIA-SEQUENCE:6\n#EXT-X-DISCONTINUITY-SEQUENCE:0\n"
    b"#EXT-X-START:TIME-OFFSET=-3.003,PRECISE=YES\n"
    b"#EXT-X-PROGRAM-DATE-TIME:2026-10-12T10:46:29.962Z\n#EXTINF:2.002,\n"
    b"./segment/6.m4s\n"
    b"#EXT-X-DISCONTINUITY\n"
    b"#EXT-X-PROGRAM-DATE-TIME:2026-10-12T10:46:31.964Z\n#EXTINF:2.001,\n"
    b"./segment/7.m4s\n"
    b"#EXT-X-PROGRAM-DATE-TIME:2026-10-12T10:46:33.965Z\n#EXTINF:2.002,\n"
    b"./segment/8.m4s\n")


def live_stream(**fake_options):
    files = {"master_playlist.m3u8": b"#EXTM3U\nplaylist.m3u8\n",
             "playlist.m3u8": LIVE_PLAYLIST,
             "init.mp4": b"init-bytes",
             "segment/8.m4s": b"segment-8"}
    server = FakeHA(hls_files=files, **fake_options)
    bridge = connected_bridge(server)
    bridge.send({"op": "stream_start", "entity_id": "camera.front"})
    url = (stream_event(bridge, "camera.front") or {}).get("url", "")
    return server, bridge, url


def test_first_playlist_starts_at_the_live_edge():
    print("stream: playback starts at the newest segment, not three back")
    server, bridge, url = live_stream(hls_gzip=True)
    try:
        status, master = local_get(url)
        check("the master playlist is untouched", status == 200, (status, master))
        status, body = local_get(sibling(url, "playlist.m3u8"))
        text = body.decode("utf-8", "replace")
        check("relays the media playlist uncompressed",
              status == 200 and text.startswith("#EXTM3U"), body[:20])
        check("keeps only the newest segment",
              "segment/8.m4s" in text and "segment/7.m4s" not in text
              and "segment/6.m4s" not in text, text)
        check("renumbers the media sequence to that segment",
              "#EXT-X-MEDIA-SEQUENCE:8\n" in text, text)
        check("counts the dropped discontinuity",
              "#EXT-X-DISCONTINUITY-SEQUENCE:1\n" in text, text)
        check("keeps the init section and target duration",
              '#EXT-X-MAP:URI="init.mp4"' in text and "#EXT-X-TARGETDURATION:2" in text,
              text)
        check("keeps the kept segment's timestamp",
              "2026-10-12T10:46:33.965Z" in text
              and "2026-10-12T10:46:31.964Z" not in text, text)
        check("drops the start offset that points back into removed segments",
              "EXT-X-START" not in text, text)
    finally:
        bridge.stop()
        server.stop()


def test_playlists_pass_through_once_playing():
    print("stream: once a segment has played, playlists are relayed whole")
    server, bridge, url = live_stream()
    try:
        local_get(url)
        local_get(sibling(url, "playlist.m3u8"))
        status, _ = local_get(sibling(url, "segment/8.m4s"))
        check("serves the segment", status == 200, status)
        status, body = local_get(sibling(url, "playlist.m3u8"))
        check("the next playlist is Home Assistant's own",
              status == 200 and body == LIVE_PLAYLIST, body)
    finally:
        bridge.stop()
        server.stop()


def test_stream_relay_refuses_strangers():
    print("stream: the relay serves only its own secret path")
    server = FakeHA()
    bridge = connected_bridge(server)
    try:
        bridge.send({"op": "stream_start", "entity_id": "camera.front"})
        url = (stream_event(bridge, "camera.front") or {}).get("url", "")
        base = url.rsplit("/", 1)[0]
        prefix = base[len(base.split("/", 3)[0] + "//" + base.split("/", 3)[2]):]
        before = len(server.hls_requests)
        for raw in ("/wrongsecret/master_playlist.m3u8",
                    "/master_playlist.m3u8",
                    prefix + "/../../api/states",
                    prefix + "/%2e%2e/%2e%2e/api/states",
                    prefix + "/segment/../../../api/config",
                    prefix + "//api/states",
                    prefix + "/playlist.m3u8?x=<script>"):
            status, _ = local_get(url, raw_path=raw)
            check("refuses %s" % raw, status in (400, 404), status)
        check("none of them reached Home Assistant",
              len(server.hls_requests) == before, server.hls_requests[before:])
    finally:
        bridge.stop()
        server.stop()


def test_stopped_stream_is_gone():
    print("stream: stopping a stream closes its relay path")
    server = FakeHA()
    bridge = connected_bridge(server)
    try:
        bridge.send({"op": "stream_start", "entity_id": "camera.front"})
        url = (stream_event(bridge, "camera.front") or {}).get("url", "")
        bridge.send({"op": "stream_stop", "entity_id": "camera.front"})
        bridge.wait_for(lambda e: False, budget=0.5)
        status, _ = local_get(url)
        check("the stopped stream is no longer served", status == 404, status)
    finally:
        bridge.stop()
        server.stop()


def test_reconfiguring_ends_streams():
    print("stream: a new connection generation ends every stream")
    server = FakeHA()
    bridge = connected_bridge(server)
    try:
        bridge.send({"op": "stream_start", "entity_id": "camera.front"})
        url = (stream_event(bridge, "camera.front") or {}).get("url", "")
        bridge.send({"op": "config", "url": server.url, "token": "other",
                     "generation": 5})
        bridge.wait_for(lambda e: e["ev"] == "phase" and e.get("generation") == 5)
        status, _ = local_get(url)
        check("the old stream is no longer served", status == 404, status)
    finally:
        bridge.stop()
        server.stop()


def test_stream_failure_is_reported():
    print("stream: a camera that cannot stream is reported, for the snapshot fallback")
    server = FakeHA(stream_fail=True)
    bridge = connected_bridge(server)
    try:
        bridge.send({"op": "stream_start", "entity_id": "camera.front"})
        event = stream_event(bridge, "camera.front")
        check("reports the failure",
              event is not None and event.get("ok") is False and "url" not in event,
              event)
    finally:
        bridge.stop()
        server.stop()


def test_stream_refuses_anything_but_a_camera_id():
    print("stream: only well-formed camera entity ids are streamed")
    server = FakeHA()
    bridge = connected_bridge(server)
    try:
        for bad in ("light.test", "camera.a/b", "", None):
            bridge.send({"op": "stream_start", "entity_id": bad})
        bridge.wait_for(lambda e: False, budget=1.0)
        refusals = [e for e in bridge.snapshot()
                    if e["ev"] == "stream" and e.get("ok") is False]
        check("each refusal is reported", len(refusals) == 4, refusals)
        check("nothing was asked of Home Assistant", server.stream_calls == [],
              server.stream_calls)
    finally:
        bridge.stop()
        server.stop()


def test_demo_has_no_stream():
    print("demo: the demo camera falls back to snapshots")
    bridge = BridgeProc("--demo")
    try:
        bridge.send({"op": "config"})
        bridge.wait_for(lambda e: e["ev"] == "phase" and e["phase"] == "connected")
        bridge.send({"op": "stream_start", "entity_id": "camera.garage_driveway"})
        event = stream_event(bridge, "camera.garage_driveway")
        check("reports no stream", event is not None and event.get("ok") is False, event)
    finally:
        bridge.stop()


def test_stale_snapshot_directories_are_swept():
    print("camera: snapshot directories left by a killed bridge are removed")
    import tempfile
    runtime = tempfile.mkdtemp(prefix="hass-test-runtime-")
    dead = os.path.join(runtime, "hass-snapshots-%d-abc" % 2 ** 22)
    alive = os.path.join(runtime, "hass-snapshots-%d-def" % os.getpid())
    unrelated = os.path.join(runtime, "something-else")
    for path in (dead, alive, unrelated):
        os.mkdir(path, 0o700)
    bridge = BridgeProc("--demo", env={"XDG_RUNTIME_DIR": runtime})
    try:
        bridge.send({"op": "config"})
        bridge.wait_for(lambda e: e["ev"] == "phase" and e["phase"] == "connected")
        check("removes a dead bridge's directory", not os.path.exists(dead))
        check("keeps a running bridge's directory", os.path.isdir(alive))
        check("leaves unrelated directories alone", os.path.isdir(unrelated))
    finally:
        bridge.stop()
        import shutil
        shutil.rmtree(runtime, ignore_errors=True)


def main():
    for test in (test_live_happy_path,
                 test_rejected_service_call_is_reported,
                 test_reports_the_unit_system,
                 test_auth_invalid_once_is_retried,
                 test_auth_invalid_twice_stops,
                 test_server_cannot_echo_token_into_events,
                 test_protocol_version_mismatch_is_explicit,
                 test_reconnects_after_server_drop,
                 test_unreachable_host_backs_off,
                 test_unusable_urls_are_refused_not_downgraded,
                 test_unparseable_url_does_not_kill_the_bridge,
                 test_scheme_less_host_is_assumed_secure,
                 test_oversized_frame_is_refused,
                 test_empty_config_stops_a_doomed_attempt,
                 test_explicit_disconnect_stops_demo,
                 test_ready_waits_for_subscription_and_snapshot,
                 test_rejected_subscription_never_becomes_ready,
                 test_slow_initial_snapshot_reconnects,
                 test_partial_registries_are_emitted,
                 test_generation_changes_isolate_instances,
                 test_environment_proxy_is_ignored,
                 test_ipv6_websocket_connection,
                 test_wss_certificate_policy,
                 test_invalid_websocket_message_is_controlled,
                 test_fragment_flood_hits_size_limit,
                 test_local_url_is_preferred_when_reachable,
                 test_falls_back_to_primary_when_local_is_unreachable,
                 test_unparseable_local_url_does_not_block_the_primary,
                 test_local_url_matches_any_of_several_trusted_networks,
                 test_local_url_is_skipped_off_the_trusted_network,
                 test_local_url_without_a_trusted_network_is_never_used,
                 test_unknown_wifi_state_fails_closed,
                 test_demo_needs_no_server,
                 test_camera_snapshot_is_fetched,
                 test_snapshot_refuses_anything_but_a_camera_id,
                 test_snapshot_needs_a_connection,
                 test_snapshot_failures_never_echo_the_token,
                 test_snapshot_must_be_an_image,
                 test_oversized_snapshot_is_refused,
                 test_snapshot_ignores_proxy_environment,
                 test_snapshot_over_tls,
                 test_snapshot_uses_the_connected_local_url,
                 test_demo_camera_snapshot,
                 test_camera_stream_is_relayed_over_loopback,
                 test_compressed_playlists_keep_their_encoding,
                 test_first_playlist_starts_at_the_live_edge,
                 test_playlists_pass_through_once_playing,
                 test_stream_relay_refuses_strangers,
                 test_stopped_stream_is_gone,
                 test_reconfiguring_ends_streams,
                 test_stream_failure_is_reported,
                 test_stream_refuses_anything_but_a_camera_id,
                 test_demo_has_no_stream,
                 test_stale_snapshot_directories_are_swept):
        test()
        print()

    if FAILURES:
        print("FAILED: %s" % ", ".join(FAILURES))
        return 1
    print("all tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

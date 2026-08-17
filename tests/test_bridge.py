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


def test_demo_needs_no_server():
    print("demo: runs standalone and drifts on its own")
    bridge = BridgeProc("--demo")
    try:
        bridge.send({"op": "config"})
        states = bridge.wait_for(lambda e: e["ev"] == "states")
        check("serves the demo house", states is not None and len(states["entities"]) == 14)

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
                 test_demo_needs_no_server):
        test()
        print()

    if FAILURES:
        print("FAILED: %s" % ", ".join(FAILURES))
        return 1
    print("all tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

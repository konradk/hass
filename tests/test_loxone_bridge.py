#!/usr/bin/env python3
"""Integration tests for bin/loxone-bridge. Run: python3 tests/test_loxone_bridge.py

Drives the bridge as the shell does — NDJSON on stdin, NDJSON on stdout —
against tests/fake_loxone.py. Standard library only, no pytest, matching the
bridge's own dependency rule.
"""

import json
import os
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fake_loxone import FakeLoxone  # noqa: E402
from fake_camera import FakeCamera  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRIDGE = os.path.join(ROOT, "bin", "loxone-bridge")

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

    def wait_for(self, predicate, budget=10.0):
        end = time.time() + budget
        while time.time() < end:
            for event in self.snapshot():
                if predicate(event):
                    return event
            time.sleep(0.05)
        return None

    def phases(self):
        return [e["phase"] for e in self.snapshot() if e["ev"] == "phase"]

    def stop(self):
        try:
            if self.proc.poll() is None:
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


LIGHT_UUID = "11111111-0000-0000-0000000000000001"
LIGHT_ENTITY = "light." + LIGHT_UUID


def test_live_happy_path():
    print("live: connect, snapshot, command, live update")
    server = FakeLoxone()
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "username": "admin",
                     "password": "secret", "verifyTls": False})

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
        check("dimmer state is on with a brightness attribute",
              states is not None
              and states["entities"][0]["state"] == "on"
              and states["entities"][0]["attributes"]["brightness"] == 70.0,
              states)

        registries = bridge.wait_for(lambda e: e["ev"] == "registries")
        check("sends rooms",
              registries is not None
              and registries["rooms"][0]["area_id"] == "room-1",
              registries)

        bridge.send({"op": "command", "entity_id": LIGHT_ENTITY, "command": "off",
                     "tag": "call-1"})

        result = bridge.wait_for(
            lambda e: e["ev"] == "result" and e.get("tag") == "call-1")
        check("acknowledges the command", result is not None and result["ok"])
        check("the command actually reached the Miniserver",
              ("11111111-0000-0000-0000000000000001", "off") in server.commands)

        changed = bridge.wait_for(
            lambda e: e["ev"] == "state_changed"
            and e["entity"]["state"] == "off", budget=6.0)
        check("the next poll reports the new state", changed is not None)
    finally:
        bridge.stop()
        server.stop()


def test_light_controller_off_uses_the_off_mood():
    print("live: turning off a LightControllerV2 sends its off mood, not a plain off")
    structure = {
        "rooms": {"room-1": {"name": "Living Room"}},
        "cats": {},
        "controls": {
            "22222222-0000-0000-0000000000000002": {
                "name": "Empore", "type": "LightControllerV2", "room": "room-1",
            },
        },
    }
    states = {"22222222-0000-0000-0000000000000002": {"Code": "200", "value": "1"}}
    server = FakeLoxone(structure=structure, states=states)
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "username": "admin",
                     "password": "secret", "verifyTls": False})
        bridge.wait_for(lambda e: e["ev"] == "phase" and e["phase"] == "connected")

        entity_id = "light.22222222-0000-0000-0000000000000002"
        bridge.send({"op": "command", "entity_id": entity_id, "command": "off",
                     "tag": "off-1"})
        result = bridge.wait_for(
            lambda e: e["ev"] == "result" and e.get("tag") == "off-1")
        check("the command is acknowledged", result is not None and result["ok"])
        check("the Miniserver received the off mood, not a plain off",
              ("22222222-0000-0000-0000000000000002", "setMood/778")
              in server.commands,
              server.commands)

        bridge.send({"op": "command", "entity_id": entity_id, "command": "on",
                     "tag": "on-1"})
        bridge.wait_for(lambda e: e["ev"] == "result" and e.get("tag") == "on-1")
        check("turning on still sends a plain on",
              ("22222222-0000-0000-0000000000000002", "on") in server.commands,
              server.commands)
    finally:
        bridge.stop()
        server.stop()


def test_light_controller_off_prefers_its_colorpicker_sub_control():
    print("live: turning off a LightControllerV2 with an RGB sub-control "
          "targets that sub-control's hsv(0,0,0), not the mood system")
    parent = "33333333-0000-0000-0000000000000003"
    structure = {
        "rooms": {"room-1": {"name": "Living Room"}},
        "cats": {},
        "controls": {
            parent: {
                "name": "Empore", "type": "LightControllerV2", "room": "room-1",
                "subControls": {
                    parent + "/AI1": {
                        "name": "Empore", "type": "ColorPickerV2",
                        "uuidAction": parent + "/AI1",
                    },
                },
            },
        },
    }
    states = {parent: {"Code": "200", "value": "1"}}
    server = FakeLoxone(structure=structure, states=states)
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "username": "admin",
                     "password": "secret", "verifyTls": False})
        bridge.wait_for(lambda e: e["ev"] == "phase" and e["phase"] == "connected")

        entity_id = "light.%s" % parent
        bridge.send({"op": "command", "entity_id": entity_id, "command": "off",
                     "tag": "off-1"})
        result = bridge.wait_for(
            lambda e: e["ev"] == "result" and e.get("tag") == "off-1")
        check("the command is acknowledged", result is not None and result["ok"])
        check("the Miniserver received hsv(0,0,0) on the sub-control, not a mood",
              (parent, "AI1/hsv(0,0,0)") in server.commands,
              server.commands)
        check("the off mood was never sent — live-verified to have no effect",
              (parent, "setMood/778") not in server.commands,
              server.commands)
    finally:
        bridge.stop()
        server.stop()


def test_poll_covers_every_control_across_worker_chunks():
    print("live: a registry larger than one worker chunk is still polled completely")
    count = 17  # deliberately not a multiple of POLL_WORKERS
    structure = {"rooms": {}, "cats": {}, "controls": {}}
    states = {}
    for i in range(count):
        uuid = "aaaaaaaa-0000-0000-0000-%012d" % i
        structure["controls"][uuid] = {"name": "Switch %d" % i, "type": "Switch"}
        states[uuid] = {"Code": "200", "value": "1" if i % 2 == 0 else "0"}
    server = FakeLoxone(structure=structure, states=states)
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "username": "admin",
                     "password": "secret", "verifyTls": False})
        states_ev = bridge.wait_for(lambda e: e["ev"] == "states")
        check("every control is present, none dropped or duplicated",
              states_ev is not None
              and len(states_ev["entities"]) == count
              and len({e["entity_id"] for e in states_ev["entities"]}) == count,
              states_ev and len(states_ev["entities"]))
        check("each control's own state was read correctly, not another's",
              states_ev is not None and all(
                  e["state"] == ("on" if i % 2 == 0 else "off")
                  for i, e in enumerate(sorted(
                      states_ev["entities"], key=lambda e: e["entity_id"]))),
              states_ev)
    finally:
        bridge.stop()
        server.stop()


def test_command_confirms_state_immediately():
    print("live: a successful command confirms its own effect without waiting for the poll")
    server = FakeLoxone()
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "username": "admin",
                     "password": "secret", "verifyTls": False})
        bridge.wait_for(lambda e: e["ev"] == "phase" and e["phase"] == "connected")

        start = time.time()
        bridge.send({"op": "command", "entity_id": LIGHT_ENTITY, "command": "off",
                     "tag": "fast-1"})
        changed = bridge.wait_for(
            lambda e: e["ev"] == "state_changed" and e["entity"]["state"] == "off",
            budget=2.0)
        elapsed = time.time() - start
        # POLL_INTERVAL is 2.5s; a confirmation that took that long would mean
        # this rode the scheduled poll rather than the immediate re-read a
        # successful command triggers on its own.
        check("the new state lands well under one poll interval",
              changed is not None and elapsed < 2.0, elapsed)
    finally:
        bridge.stop()
        server.stop()


def test_light_controller_off_state_is_not_a_plain_zero():
    print("live: a LightControllerV2's off encoding is read as off, not just literal 0")
    uuid = "33333333-0000-0000-0000000000000003"
    structure = {
        "rooms": {}, "cats": {},
        "controls": {uuid: {"name": "Empore", "type": "LightControllerV2"}},
    }
    # The real Miniserver encodes "no mood active" as a large number with
    # this exact prefix, not as 0 — see build_entity's light branch.
    states = {uuid: {"Code": "200", "value": "200002700123456789"}}
    server = FakeLoxone(structure=structure, states=states)
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "username": "admin",
                     "password": "secret", "verifyTls": False})
        states_ev = bridge.wait_for(lambda e: e["ev"] == "states")
        check("the off encoding reads as off, not on",
              states_ev is not None and states_ev["entities"][0]["state"] == "off",
              states_ev)

        server.states[uuid]["value"] = "42"
        changed = bridge.wait_for(
            lambda e: e["ev"] == "state_changed"
            and e["entity"]["entity_id"] == "light." + uuid, budget=6.0)
        check("a genuine mood value reads as on",
              changed is not None and changed["entity"]["state"] == "on", changed)
    finally:
        bridge.stop()
        server.stop()


def test_wrong_credentials_do_not_connect():
    print("live: bad credentials never reach connected")
    server = FakeLoxone()
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "username": "admin",
                     "password": "wrong", "verifyTls": False})
        errored = bridge.wait_for(
            lambda e: e["ev"] == "phase" and e["phase"] in ("error", "connecting")
            and e.get("error"))
        check("reports a connection problem", errored is not None)
        check("never reaches connected",
              "connected" not in bridge.phases())
    finally:
        bridge.stop()
        server.stop()


def test_password_never_in_output():
    print("security: the password never appears in any emitted event")
    server = FakeLoxone(username="admin", password="s3cr3t-password")
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "username": "admin",
                     "password": "s3cr3t-password", "verifyTls": False})
        bridge.wait_for(lambda e: e["ev"] == "phase" and e["phase"] == "connected")
        bridge.send({"op": "config", "url": "http://127.0.0.1:1",
                     "username": "admin", "password": "s3cr3t-password",
                     "verifyTls": False, "generation": 99})
        bridge.wait_for(lambda e: e.get("generation") == 99, budget=4.0)
        time.sleep(0.3)
        dump = json.dumps(bridge.snapshot())
        check("password is redacted from every event", "s3cr3t-password" not in dump)
    finally:
        bridge.stop()
        server.stop()


def test_unknown_entity_is_rejected():
    print("live: a command for an entity outside the structure is rejected")
    server = FakeLoxone()
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server.url, "username": "admin",
                     "password": "secret", "verifyTls": False})
        bridge.wait_for(lambda e: e["ev"] == "phase" and e["phase"] == "connected")
        bridge.send({"op": "command", "entity_id": "light.does-not-exist",
                     "command": "on", "tag": "call-missing"})
        result = bridge.wait_for(
            lambda e: e["ev"] == "result" and e.get("tag") == "call-missing")
        check("rejects the unknown entity", result is not None and result["ok"] is False)
    finally:
        bridge.stop()
        server.stop()


def test_reconnect_bumps_generation_and_drops_stale_events():
    print("live: a config with a new generation supersedes the old connection")
    server_a = FakeLoxone()
    server_b = FakeLoxone()
    bridge = BridgeProc()
    try:
        bridge.send({"op": "config", "url": server_a.url, "username": "admin",
                     "password": "secret", "verifyTls": False, "generation": 1})
        bridge.wait_for(lambda e: e["ev"] == "phase" and e["phase"] == "connected"
                        and e.get("generation") == 1)

        bridge.send({"op": "config", "url": server_b.url, "username": "admin",
                     "password": "secret", "verifyTls": False, "generation": 2})
        second = bridge.wait_for(lambda e: e["ev"] == "phase" and e["phase"] == "connected"
                                 and e.get("generation") == 2)
        check("reconnects under the new generation", second is not None)

        for event in bridge.snapshot():
            if event["ev"] in ("states", "state_changed", "registries", "phase"):
                check("no stale-generation event leaks through",
                      event.get("generation") in (1, 2), event)
                break
    finally:
        bridge.stop()
        server_a.stop()
        server_b.stop()


def test_shutdown_stops_the_process():
    print("lifecycle: shutdown ends the process")
    bridge = BridgeProc()
    try:
        bridge.send({"op": "shutdown"})
        code = bridge.proc.wait(timeout=5)
        check("exits cleanly", code == 0, code)
    finally:
        bridge.stop()


def _wait_for_file_bytes(path, expected, budget=4.0):
    end = time.time() + budget
    while time.time() < end:
        if os.path.exists(path):
            with open(path, "rb") as handle:
                if handle.read() == expected:
                    return True
        time.sleep(0.05)
    return False


def test_camera_snapshot_mode():
    print("camera: a plain image response is polled on an interval")
    with tempfile.TemporaryDirectory() as tmp:
        frame_path = os.path.join(tmp, "camera.jpg")
        camera = FakeCamera(mode="snapshot", frames=[b"SNAP-1"])
        bridge = BridgeProc()
        try:
            bridge.send({"op": "camera_config", "url": camera.url,
                         "username": "cam", "password": "camsecret",
                         "verifyTls": False, "framePath": frame_path})
            bridge.send({"op": "camera_resume"})
            streaming = bridge.wait_for(
                lambda e: e["ev"] == "camera" and e["status"] == "streaming")
            check("reaches streaming", streaming is not None)
            check("no generation on a camera event — it has its own lifecycle",
                  streaming is not None and "generation" not in streaming, streaming)
            check("the first snapshot is written to the frame path",
                  _wait_for_file_bytes(frame_path, b"SNAP-1"))

            camera.frames[0] = b"SNAP-2"
            check("a later poll picks up the new snapshot",
                  _wait_for_file_bytes(frame_path, b"SNAP-2", budget=4.0))

            bridge.send({"op": "camera_disconnect"})
            idle = bridge.wait_for(
                lambda e: e["ev"] == "camera" and e["status"] == "idle",
                budget=4.0)
            check("disconnecting reports idle", idle is not None)
        finally:
            bridge.stop()
            camera.stop()


def test_camera_mjpeg_mode():
    print("camera: a multipart/x-mixed-replace response streams frames")
    with tempfile.TemporaryDirectory() as tmp:
        frame_path = os.path.join(tmp, "camera.jpg")
        camera = FakeCamera(mode="mjpeg",
                            frames=[b"AAAA", b"BBBB", b"CCCC"], frame_delay=0.05)
        bridge = BridgeProc()
        try:
            bridge.send({"op": "camera_config", "url": camera.url,
                         "username": "cam", "password": "camsecret",
                         "verifyTls": False, "framePath": frame_path})
            bridge.send({"op": "camera_resume"})
            bridge.wait_for(
                lambda e: e["ev"] == "camera" and e["status"] == "streaming")
            check("the last frame of the stream lands on disk",
                  _wait_for_file_bytes(frame_path, b"CCCC"))
        finally:
            bridge.stop()
            camera.stop()


def test_camera_wrong_credentials_report_error():
    print("camera: bad credentials surface as a camera error, not a crash")
    with tempfile.TemporaryDirectory() as tmp:
        frame_path = os.path.join(tmp, "camera.jpg")
        camera = FakeCamera(mode="snapshot", frames=[b"SNAP-1"])
        bridge = BridgeProc()
        try:
            bridge.send({"op": "camera_config", "url": camera.url,
                         "username": "cam", "password": "wrong",
                         "verifyTls": False, "framePath": frame_path})
            bridge.send({"op": "camera_resume"})
            errored = bridge.wait_for(
                lambda e: e["ev"] == "camera" and e["status"] == "error")
            check("reports a camera error", errored is not None
                  and bool(errored.get("error")), errored)
            check("never writes a frame", not os.path.exists(frame_path))
        finally:
            bridge.stop()
            camera.stop()


def test_camera_password_never_in_output():
    print("security: the camera password never appears in any emitted event")
    with tempfile.TemporaryDirectory() as tmp:
        frame_path = os.path.join(tmp, "camera.jpg")
        camera = FakeCamera(mode="snapshot", frames=[b"SNAP-1"],
                            password="very-secret-camera-pw")
        bridge = BridgeProc()
        try:
            bridge.send({"op": "camera_config", "url": camera.url,
                         "username": "cam", "password": "very-secret-camera-pw",
                         "verifyTls": False, "framePath": frame_path})
            bridge.send({"op": "camera_resume"})
            bridge.wait_for(
                lambda e: e["ev"] == "camera" and e["status"] == "streaming")
            bridge.send({"op": "camera_config", "url": "http://127.0.0.1:1/x",
                         "username": "cam", "password": "very-secret-camera-pw",
                         "verifyTls": False, "framePath": frame_path})
            bridge.wait_for(
                lambda e: e["ev"] == "camera" and e["status"] == "error",
                budget=6.0)
            dump = json.dumps(bridge.snapshot())
            check("camera password is redacted from every event",
                  "very-secret-camera-pw" not in dump)
        finally:
            bridge.stop()
            camera.stop()


def test_camera_pauses_and_resumes_without_a_fresh_password():
    print("camera: configuring alone does not stream; pause actually stops it")
    with tempfile.TemporaryDirectory() as tmp:
        frame_path = os.path.join(tmp, "camera.jpg")
        camera = FakeCamera(mode="snapshot", frames=[b"SNAP-1"])
        bridge = BridgeProc()
        try:
            bridge.send({"op": "camera_config", "url": camera.url,
                         "username": "cam", "password": "camsecret",
                         "verifyTls": False, "framePath": frame_path})
            # No camera_resume yet — nobody is looking at it.
            time.sleep(0.5)
            check("configuring alone does not start streaming",
                  not os.path.exists(frame_path))
            check("no requests reached the camera before a viewer opened",
                  camera.requests == [])

            bridge.send({"op": "camera_resume"})
            bridge.wait_for(
                lambda e: e["ev"] == "camera" and e["status"] == "streaming")
            check("resuming starts the stream",
                  _wait_for_file_bytes(frame_path, b"SNAP-1"))

            bridge.send({"op": "camera_pause"})
            idle = bridge.wait_for(
                lambda e: e["ev"] == "camera" and e["status"] == "idle")
            check("pausing reports idle", idle is not None)

            os.remove(frame_path)
            camera.frames[0] = b"SNAP-2"
            time.sleep(1.5)
            check("a paused camera does not keep polling in the background",
                  not os.path.exists(frame_path))

            # Resuming again must not need the password re-sent — the whole
            # point is that a viewer reopening the popover just says "go".
            bridge.send({"op": "camera_resume"})
            check("resuming again picks the stream back up with no new password",
                  _wait_for_file_bytes(frame_path, b"SNAP-2"))
        finally:
            bridge.stop()
            camera.stop()


def main():
    test_live_happy_path()
    test_light_controller_off_uses_the_off_mood()
    test_light_controller_off_prefers_its_colorpicker_sub_control()
    test_light_controller_off_state_is_not_a_plain_zero()
    test_command_confirms_state_immediately()
    test_poll_covers_every_control_across_worker_chunks()
    test_wrong_credentials_do_not_connect()
    test_password_never_in_output()
    test_unknown_entity_is_rejected()
    test_reconnect_bumps_generation_and_drops_stale_events()
    test_camera_snapshot_mode()
    test_camera_mjpeg_mode()
    test_camera_wrong_credentials_report_error()
    test_camera_password_never_in_output()
    test_camera_pauses_and_resumes_without_a_fresh_password()
    test_shutdown_stops_the_process()

    print()
    if FAILURES:
        print("FAILED: %s" % ", ".join(FAILURES))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

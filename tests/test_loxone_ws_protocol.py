#!/usr/bin/env python3
"""Unit and integration tests for the RSA / WebSocket / token-handshake /
binary-push pieces of bin/loxone-bridge (LivePushThread and friends).

This is authentication code running against a real Miniserver, so it gets
tested more thoroughly than a source-string check: RSA correctness is
verified by actually decrypting what the bridge encrypted (via the system
`openssl`, skipped if unavailable — see tests/fake_loxone_ws.py), WebSocket
framing is verified over a real loopback socket, and the full handshake is
verified end-to-end against a fake Miniserver that independently recomputes
the expected HMAC signature rather than just accepting anything.

Run: python3 tests/test_loxone_ws_protocol.py
"""

import os
import queue
import socket
import subprocess
import sys
import threading
import time
from importlib.machinery import SourceFileLoader

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fake_loxone_ws import FakeLoxoneWs, openssl_available  # noqa: E402

bridge = SourceFileLoader("loxone_bridge_module",
                          os.path.join(ROOT, "bin", "loxone-bridge")).load_module()

FAILURES = []


def check(name, condition, detail=""):
    if condition:
        print("  ok   %s" % name)
    else:
        print("  FAIL %s %s" % (name, detail))
        FAILURES.append(name)


def section(title):
    print(title)


# ---------------------------------------------------------------- RSA

def test_rsa_round_trip():
    section("RSA: PKCS#1 v1.5 encryption round-trips through a real key")
    if not openssl_available():
        print("  skip (openssl not available)")
        return
    keypair = _make_keypair()
    try:
        pubkey = bridge.parse_rsa_public_key_pem(keypair.pub_pem)
        check("modulus is a real 2048-bit key", pubkey.n.bit_length() in (2047, 2048))
        for msg in (b"hello", b"a" * 200, b"", os.urandom(245)):
            ct = bridge.rsa_pkcs1v15_encrypt(pubkey, msg)
            plain = keypair.decrypt(ct)
            check("round-trips a %d-byte message" % len(msg), plain == msg)
        try:
            bridge.rsa_pkcs1v15_encrypt(pubkey, os.urandom(300))
            check("rejects an oversized message", False)
        except bridge.LoxoneError:
            check("rejects an oversized message", True)
    finally:
        keypair.close()


def _make_keypair():
    from fake_loxone_ws import _Keypair
    return _Keypair()


def test_rsa_rejects_malformed_der():
    section("RSA: malformed key material is rejected, not crashed on")
    try:
        bridge.parse_rsa_public_key_der(b"not a der structure at all")
        check("malformed DER raises LoxoneError", False)
    except bridge.LoxoneError:
        check("malformed DER raises LoxoneError", True)
    try:
        bridge.parse_rsa_public_key_pem("-----BEGIN CERTIFICATE-----\nnotbase64!!\n"
                                        "-----END CERTIFICATE-----")
        check("malformed PEM raises LoxoneError", False)
    except bridge.LoxoneError:
        check("malformed PEM raises LoxoneError", True)


# ---------------------------------------------------------------- WebSocket


def test_websocket_frame_round_trip():
    section("WebSocket: handshake and frame round-trip over a real loopback socket")
    port_holder = []
    ready = threading.Event()

    def server():
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", 0))
        port_holder.append(srv.getsockname()[1])
        srv.listen(1)
        ready.set()
        conn, _ = srv.accept()
        buf = b""
        while b"\r\n\r\n" not in buf:
            buf += conn.recv(4096)
        head, _, buf = buf.partition(b"\r\n\r\n")
        key = None
        for line in head.split(b"\r\n")[1:]:
            if line.lower().startswith(b"sec-websocket-key:"):
                key = line.split(b":", 1)[1].strip()
        import base64
        import hashlib
        accept = base64.b64encode(
            hashlib.sha1(key + bridge.WS_GUID.encode()).digest()).decode()
        conn.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                      "Connection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n"
                      % accept).encode())
        server_side = bridge.WebSocketClient(conn)
        server_side._buf = buf
        opcode, payload = server_side.recv()
        assert opcode == 0x1 and payload == b"ping from client"
        server_side.send_text("pong from server")
        conn.close()

    t = threading.Thread(target=server, daemon=True)
    t.start()
    ready.wait(2.0)
    time.sleep(0.05)

    client = bridge.WebSocketClient.connect("127.0.0.1", port_holder[0], "/test",
                                            use_tls=False, verify_tls=False)
    check("client handshake succeeds", client is not None)
    client.send_text("ping from client")
    opcode, payload = client.recv(deadline=time.monotonic() + 3.0)
    check("message round-trips correctly", opcode == 0x1 and payload == b"pong from server",
          payload)
    t.join(timeout=2.0)


# ---------------------------------------------------------------- binary parsing


def test_binary_header_parsing():
    section("binary protocol: header and UUID parsing")
    header = bytes([0x03, 0x03, 0x00, 0x00]) + (48).to_bytes(4, "little")
    msg_type, estimated, payload_len = bridge.parse_bin_header(header)
    check("message type parsed", msg_type == 0x03)
    check("estimated flag parsed", estimated is False)
    check("payload length parsed", payload_len == 48)

    try:
        bridge.parse_bin_header(b"\x00\x03\x00\x00\x30\x00\x00\x00")
        check("wrong magic byte is rejected", False)
    except bridge.LoxoneError:
        check("wrong magic byte is rejected", True)

    # 0f8e1234-036e-e9ad-ffffed57184a04d2, little-endian on the wire — the
    # same worked example bin/loxone-bridge's own module (and the reference
    # `lox` CLI's tests) use.
    raw = bytes([0x34, 0x12, 0x8e, 0x0f, 0x6e, 0x03, 0xad, 0xe9,
                0xff, 0xff, 0xed, 0x57, 0x18, 0x4a, 0x04, 0xd2])
    check("UUID bytes decode to the expected string",
          bridge.parse_loxone_uuid(raw) == "0f8e1234-036e-e9ad-ffffed57184a04d2")


def test_text_state_parsing():
    section("binary protocol: text-state records")
    from fake_loxone_ws import loxone_uuid_to_le_hex, _encode_text_state
    state_uuid = "15c2a003-024c-770c-ffff7239db7fa8de"
    icon_uuid = "00000000-0000-0000-0000000000000000"
    body = _encode_text_state(loxone_uuid_to_le_hex(state_uuid),
                              loxone_uuid_to_le_hex(icon_uuid), "[778]")
    records = bridge.parse_text_states(body)
    check("one record parsed", len(records) == 1, records)
    check("UUID round-trips", records[0][0] == state_uuid, records[0])
    check("text round-trips", records[0][1] == "[778]", records[0])

    # Two records back to back, second text length not a multiple of 4 —
    # exercises the padding-to-4-bytes logic actually mattering.
    body2 = (_encode_text_state(loxone_uuid_to_le_hex(state_uuid),
                                loxone_uuid_to_le_hex(icon_uuid), "[777]")
             + _encode_text_state(loxone_uuid_to_le_hex(state_uuid),
                                  loxone_uuid_to_le_hex(icon_uuid), "hi"))
    records2 = bridge.parse_text_states(body2)
    check("two consecutive records both parsed", len(records2) == 2, records2)
    check("second record's text is correct despite odd length",
          records2[1][1] == "hi", records2)


def test_mood_state_interpretation():
    section("LivePushThread._mood_state: the confirmed live encoding")
    check('"[778]" (system off mood) is off',
          bridge.LivePushThread._mood_state("[778]") == "off")
    check('"[]" (no active mood) is off',
          bridge.LivePushThread._mood_state("[]") == "off")
    check('"[777]" is on', bridge.LivePushThread._mood_state("[777]") == "on")
    check('"[777,778]" (778 plus something else) is on',
          bridge.LivePushThread._mood_state("[777,778]") == "on")
    check("malformed text does not raise",
          bridge.LivePushThread._mood_state("not json") is None)


# ---------------------------------------------------------------- end to end


def test_live_push_end_to_end():
    section("LivePushThread: full handshake + push against a fake Miniserver")
    if not openssl_available():
        print("  skip (openssl not available)")
        return

    state_uuid = "15c2a003-024c-770c-ffff7239db7fa8de"
    entity_id = "light.15c2a003-024d-777c-ffff24b3ef2f8379"
    server = FakeLoxoneWs(expected_user="admin", expected_password="secret")
    server.queue_push(state_uuid, "[778]")
    try:
        out_queue = queue.Queue()
        cfg = {"host": server.host, "port": server.port, "use_tls": False,
               "username": "admin", "password": "secret", "verify_tls": False}
        thread = bridge.LivePushThread(1, out_queue, cfg, {state_uuid: entity_id})
        thread.start()
        try:
            kinds = []
            deadline = time.time() + 8.0
            while time.time() < deadline:
                try:
                    item = out_queue.get(timeout=0.5)
                except queue.Empty:
                    continue
                kinds.append(item)
                if item[0] == "light_push":
                    break
            check("connects and authenticates",
                  any(k[0] == "light_push_available" for k in kinds), kinds)
            push = next((k for k in kinds if k[0] == "light_push"), None)
            check("receives the queued push", push is not None, kinds)
            check("resolves to the right entity", push and push[2] == entity_id, push)
            check("[778] is interpreted as off", push and push[3] == "off", push)
        finally:
            thread.stop_event.set()
    finally:
        server.stop()


def test_live_push_wrong_password_is_unavailable_not_a_crash():
    section("LivePushThread: a rejected handshake reports unavailable, doesn't crash")
    if not openssl_available():
        print("  skip (openssl not available)")
        return
    state_uuid = "15c2a003-024c-770c-ffff7239db7fa8de"
    server = FakeLoxoneWs(expected_user="admin", expected_password="secret")
    try:
        out_queue = queue.Queue()
        cfg = {"host": server.host, "port": server.port, "use_tls": False,
               "username": "admin", "password": "wrong", "verify_tls": False}
        thread = bridge.LivePushThread(1, out_queue, cfg, {state_uuid: "light.x"})
        thread.start()
        try:
            item = None
            deadline = time.time() + 8.0
            while time.time() < deadline:
                try:
                    item = out_queue.get(timeout=0.5)
                    break
                except queue.Empty:
                    continue
            check("reports light_push_unavailable rather than crashing",
                  item is not None and item[0] == "light_push_unavailable", item)
        finally:
            thread.stop_event.set()
    finally:
        server.stop()


def main():
    test_rsa_round_trip()
    test_rsa_rejects_malformed_der()
    test_websocket_frame_round_trip()
    test_binary_header_parsing()
    test_text_state_parsing()
    test_mood_state_interpretation()
    test_live_push_end_to_end()
    test_live_push_wrong_password_is_unavailable_not_a_crash()

    print()
    if FAILURES:
        print("FAILED: %s" % ", ".join(FAILURES))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

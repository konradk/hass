"""A throwaway Home Assistant WebSocket server, for exercising the bridge.

Only the server half of RFC 6455 lives here. It lets tests send malformed,
oversized and fragmented input independently of the vendored client while also
covering the protocol layered on top: auth, event subscription, results, TLS,
IPv6, and what happens when the server hangs up.
"""

import base64
import email.utils
import hashlib
import json
import os
import socket
import ssl
import struct
import threading
import time

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")


def _recv_exact(conn, count, buf):
    while len(buf[0]) < count:
        chunk = conn.recv(65536)
        if not chunk:
            raise ConnectionError("client closed")
        buf[0] += chunk
    out, buf[0] = buf[0][:count], buf[0][count:]
    return out


def read_frame(conn, buf):
    header = _recv_exact(conn, 2, buf)
    opcode = header[0] & 0x0F
    masked = bool(header[1] & 0x80)
    length = header[1] & 0x7F
    if length == 126:
        length = struct.unpack("!H", _recv_exact(conn, 2, buf))[0]
    elif length == 127:
        length = struct.unpack("!Q", _recv_exact(conn, 8, buf))[0]
    mask = _recv_exact(conn, 4, buf) if masked else None
    payload = _recv_exact(conn, length, buf) if length else b""
    if mask:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    if opcode == 0x8:
        raise ConnectionError("client sent close")
    if opcode == 0x9:
        send_frame(conn, 0xA, payload)
        return None
    if opcode == 0xA:
        return None
    return payload.decode("utf-8")


def send_frame(conn, opcode, payload, fin=True):
    header = bytearray([(0x80 if fin else 0) | opcode])
    length = len(payload)
    if length < 126:
        header.append(length)
    elif length < 65536:
        header.append(126)
        header += struct.pack("!H", length)
    else:
        header.append(127)
        header += struct.pack("!Q", length)
    conn.sendall(bytes(header) + payload)


def send_json(conn, obj):
    send_frame(conn, 0x1, json.dumps(obj).encode("utf-8"))


def send_declared_frame(conn, opcode, length, fin=True):
    """Send only a frame header, for testing size validation before allocation."""
    conn.sendall(bytes([(0x80 if fin else 0) | opcode, 127])
                 + struct.pack("!Q", length))


def handshake(conn, server_time=None):
    raw = b""
    while b"\r\n\r\n" not in raw:
        chunk = conn.recv(4096)
        if not chunk:
            raise ConnectionError("client closed during handshake")
        raw += chunk
    head, _, rest = raw.partition(b"\r\n\r\n")
    key = ""
    for line in head.decode("latin-1").split("\r\n")[1:]:
        name, _, value = line.partition(":")
        if name.strip().lower() == "sec-websocket-key":
            key = value.strip()
    accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
    conn.sendall((
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Date: %s\r\n"
        "Sec-WebSocket-Accept: %s\r\n\r\n"
        % (email.utils.formatdate(server_time or time.time(), usegmt=True), accept)
    ).encode())
    return [rest]


class FakeHA:
    """Serves one connection at a time on localhost.

    auth_mode:
      "ok"            accept any token
      "invalid"       always reject
      "invalid_once"  reject the first connection, accept afterwards --
                      the restart behaviour the retry rule exists for
    """

    def __init__(self, auth_mode="ok", drop_after=None, fail_calls=False,
                 giant_frame=False, fail_requests=None, delays=None,
                 invalid_message=False, empty_fragments=0,
                 host="127.0.0.1", tls=False, echo_auth_token=False,
                 server_time_offset=0):
        self.auth_mode = auth_mode
        self.drop_after = drop_after
        # Reject every call_service. Home Assistant does this for a service
        # the user's token is not allowed to call, and the client has to put
        # an optimistically flipped switch back.
        self.fail_calls = fail_calls
        # Announce a frame far larger than anything real. A client that trusts
        # the declared length allocates until it dies.
        self.giant_frame = giant_frame
        self.fail_requests = set(fail_requests or [])
        self.delays = dict(delays or {})
        self.invalid_message = invalid_message
        self.empty_fragments = max(0, int(empty_fragments))
        self.host = host
        self.tls = tls
        self.echo_auth_token = echo_auth_token
        self.server_time_offset = float(server_time_offset)
        self.connections = 0
        self.states = [
            {"entity_id": "light.test", "state": "off",
             "attributes": {"friendly_name": "Test Light",
                            "supported_color_modes": ["brightness"]}},
        ]
        self.calls = []
        self.history_requests = []
        self.history_point_count = 12
        family = socket.AF_INET6 if ":" in host else socket.AF_INET
        self._server = socket.socket(family)
        self._server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server.bind((host, 0))
        self._server.listen(5)
        self.port = self._server.getsockname()[1]
        self._tls_context = None
        if tls:
            self._tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            self._tls_context.load_cert_chain(
                os.path.join(FIXTURES, "localhost-cert.pem"),
                os.path.join(FIXTURES, "localhost-key.pem"),
            )
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    @property
    def url(self):
        scheme = "https" if self.tls else "http"
        host = "[%s]" % self.host if ":" in self.host else self.host
        return "%s://%s:%d" % (scheme, host, self.port)

    def stop(self):
        self._stop.set()
        try:
            self._server.close()
        except Exception:
            pass

    def _serve(self):
        while not self._stop.is_set():
            try:
                conn, _ = self._server.accept()
            except OSError:
                return
            self.connections += 1
            threading.Thread(target=self._session, args=(conn, self.connections),
                             daemon=True).start()

    def _session(self, conn, index):
        try:
            if self._tls_context is not None:
                conn = self._tls_context.wrap_socket(conn, server_side=True)
            buf = handshake(conn, time.time() + self.server_time_offset)
            send_json(conn, {"type": "auth_required", "ha_version": "test"})
            handled = 0
            while not self._stop.is_set():
                text = read_frame(conn, buf)
                if text is None:
                    continue
                msg = json.loads(text)
                self._handle(conn, msg, index)
                handled += 1
                if self.drop_after is not None and handled >= self.drop_after:
                    conn.close()
                    return
        except Exception:
            pass
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def _handle(self, conn, msg, index):
        kind = msg.get("type")
        msg_id = msg.get("id")

        if kind == "auth":
            reject = (self.auth_mode == "invalid"
                      or (self.auth_mode == "invalid_once" and index == 1))
            if reject:
                message = "Invalid access token"
                if self.echo_auth_token:
                    message += ": " + str(msg.get("access_token") or "")
                send_json(conn, {"type": "auth_invalid", "message": message})
            else:
                send_json(conn, {"type": "auth_ok", "ha_version": "test"})
                if self.invalid_message:
                    send_frame(conn, 0x1, b"not-json")
                elif self.empty_fragments:
                    send_frame(conn, 0x1, b"", fin=False)
                    for _ in range(self.empty_fragments):
                        send_frame(conn, 0x0, b"", fin=False)
                    if self.giant_frame:
                        send_declared_frame(conn, 0x0, 1 << 40)
                    else:
                        send_frame(conn, 0x0, b"{}", fin=True)
                elif self.giant_frame:
                    # A header claiming 2^40 bytes, with nothing behind it.
                    send_declared_frame(conn, 0x1, 1 << 40)
            return

        delay = float(self.delays.get(kind, 0))
        if delay > 0:
            time.sleep(delay)

        if kind in self.fail_requests:
            send_json(conn, {"id": msg_id, "type": "result", "success": False,
                             "error": {"code": "forced_failure",
                                       "message": "Forced failure for %s" % kind}})
            return

        if kind == "get_config":
            send_json(conn, {"id": msg_id, "type": "result", "success": True,
                             "result": {"unit_system": {"temperature": "°C",
                                                        "length": "km"}}})
        elif kind == "get_states":
            send_json(conn, {"id": msg_id, "type": "result", "success": True,
                             "result": self.states})
        elif kind == "subscribe_events":
            send_json(conn, {"id": msg_id, "type": "result", "success": True, "result": None})
        elif kind == "config/area_registry/list":
            send_json(conn, {"id": msg_id, "type": "result", "success": True,
                             "result": [{"area_id": "a1", "name": "Area One"}]})
        elif kind == "config/entity_registry/list":
            send_json(conn, {"id": msg_id, "type": "result", "success": True,
                             "result": [{
                                 "entity_id": "light.test", "device_id": "d1",
                                 # Saved favourite colours ride along in the
                                 # registry entry's options, which is the only
                                 # place Home Assistant publishes them.
                                 "options": {"light": {"favorite_colors": [
                                     {"color_temp_kelvin": 2700},
                                     {"rgb_color": [255, 110, 84]}]}}}]})
        elif kind == "config/device_registry/list":
            send_json(conn, {"id": msg_id, "type": "result", "success": True,
                             "result": [{"id": "d1", "area_id": "a1"}]})
        elif kind == "call_service":
            self.calls.append(msg)
            if self.fail_calls:
                send_json(conn, {"id": msg_id, "type": "result", "success": False,
                                 "error": {"code": "unauthorized",
                                           "message": "Not allowed to call this service"}})
                return
            send_json(conn, {"id": msg_id, "type": "result", "success": True, "result": None})
            self.states[0]["state"] = "on" if msg.get("service") == "turn_on" else "off"
            send_json(conn, {"type": "event", "event": {
                "event_type": "state_changed",
                "data": {"entity_id": "light.test", "new_state": self.states[0]}}})
        elif kind == "history/history_during_period":
            self.history_requests.append(msg)
            result = {}
            for entity_id in msg.get("entity_ids") or []:
                if entity_id == "sensor.dense_power":
                    result[entity_id] = [
                        {"s": str(100 + index % 30), "lu": 1787824800 + index}
                        for index in range(700)
                    ] + [
                        {"s": "0", "lu": 1787828400 + index * 900}
                        for index in range(12)
                    ]
                elif entity_id == "sensor.air_temperature":
                    result[entity_id] = [
                        {"s": "20.5", "lu": 1787824800},
                        {"s": "unknown", "lu": 1787828400},
                        {"s": "21.25", "lu": 1787832000},
                    ]
                else:
                    now = time.time()
                    rows = [{
                        "s": "unavailable",
                        "lu": now - (self.history_point_count + 1) * 10,
                        "a": {"access_token": "leak-me", "friendly_name": "Secret"},
                    }]
                    for index in range(self.history_point_count):
                        rows.append({
                            "s": str(round(20 + index * 0.01, 2)),
                            "lu": now - (self.history_point_count - index) * 10,
                            "a": {"access_token": "leak-me"},
                        })
                    result[entity_id] = rows
            send_json(conn, {"id": msg_id, "type": "result", "success": True,
                             "result": result})
        else:
            send_json(conn, {"id": msg_id, "type": "result", "success": False,
                             "error": {"code": "unknown", "message": "no such command"}})

"""A minimal fake Loxone Miniserver HTTP API, for bridge integration tests.

Serves exactly the three endpoints bin/loxone-bridge uses:
  GET /data/LoxApp3.json            the structure
  GET /dev/sps/io/<uuid>/all        one control's current state, as XML
  GET /jdev/sps/io/<uuid>/<cmd>     act on a control

Standard library only — http.server, no third-party test dependencies,
matching the bridge's own dependency rule.
"""

import base64
import http.server
import json
import re
import threading


class _Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # noqa: A003 — silence per-request logs
        pass

    def _authorized(self):
        server = self.server
        if server.username is None:
            return True
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return False
        try:
            decoded = base64.b64decode(header[6:]).decode("utf-8")
        except Exception:
            return False
        return decoded == "%s:%s" % (server.username, server.password)

    def _send(self, status, body, content_type="application/json"):
        payload = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):  # noqa: N802 — BaseHTTPRequestHandler's own naming
        server = self.server
        server.requests.append(self.path)
        if not self._authorized():
            self._send(401, '{"error":"unauthorized"}')
            return

        if self.path == "/data/LoxApp3.json":
            self._send(200, json.dumps(server.structure))
            return

        if self.path.startswith("/dev/sps/io/") and self.path.endswith("/all"):
            uuid = self.path[len("/dev/sps/io/"):-len("/all")]
            attrs = server.states.get(uuid)
            if attrs is None:
                self._send(404, "not found", content_type="text/xml")
                return
            xml_attrs = " ".join('%s="%s"' % (k, v) for k, v in attrs.items())
            self._send(200, "<LL %s/>" % xml_attrs, content_type="text/xml")
            return

        if self.path.startswith("/jdev/sps/io/"):
            rest = self.path[len("/jdev/sps/io/"):]
            uuid, _, cmd = rest.partition("/")
            if uuid not in server.states:
                self._send(200, json.dumps({"LL": {"Code": "404", "value": ""}}))
                return
            server.commands.append((uuid, cmd))
            server.on_command(uuid, cmd)
            self._send(200, json.dumps({"LL": {"Code": "200", "value": "1"}}))
            return

        self._send(404, '{"error":"not found"}')


class FakeLoxone(http.server.ThreadingHTTPServer):
    """A background Miniserver. `structure` is the LoxApp3.json payload;
    `states` maps control UUID -> the attribute dict `/all` should answer
    with (as strings, matching the real XML wire format)."""

    daemon_threads = True

    def __init__(self, structure=None, states=None, username="admin", password="secret"):
        super().__init__(("127.0.0.1", 0), _Handler)
        self.structure = structure if structure is not None else default_structure()
        self.states = states if states is not None else default_states()
        self.username = username
        self.password = password
        self.requests = []
        self.commands = []
        self._thread = threading.Thread(target=self.serve_forever, daemon=True)
        self._thread.start()

    @property
    def url(self):
        return "http://127.0.0.1:%d" % self.server_address[1]

    def on_command(self, uuid, cmd):
        """Default command handling: mutate `states` the way a real
        Miniserver would for the control types the test fixtures use."""
        attrs = self.states.get(uuid, {})
        if cmd in ("on", "off"):
            attrs["value"] = "1" if cmd == "on" else "0"
        elif cmd == "FullUp":
            attrs["StatePos"] = "1"
        elif cmd == "FullDown":
            attrs["StatePos"] = "0"
        elif re.match(r"^\d+(\.\d+)?$", cmd):
            attrs["value"] = cmd

    def stop(self):
        self.shutdown()
        self.server_close()


def default_structure():
    return {
        "rooms": {"room-1": {"name": "Living Room"}},
        "cats": {},
        "controls": {
            "11111111-0000-0000-0000000000000001": {
                "name": "Test Light", "type": "Dimmer", "room": "room-1",
            },
        },
    }


def default_states():
    return {
        "11111111-0000-0000-0000000000000001": {"Code": "200", "value": "70"},
    }

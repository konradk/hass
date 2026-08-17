"""A fake Loxone Miniserver implementing just enough of the RSA/HMAC token
handshake and binary push protocol to test LivePushThread end-to-end.

Generates its own RSA keypair via the system `openssl` binary (decryption —
needed only here, to verify what the bridge's client-side encryption
produced — is not something the bridge itself ever needs, so it is not
reimplemented in Python; shelling out to openssl for this one test-only
operation is simpler and no less trustworthy than a from-scratch decrypt).
Skip any test using this fixture if openssl is unavailable.
"""

import base64
import hashlib
import hmac
import http.server
import json
import shutil
import socket
import struct
import subprocess
import tempfile
import threading

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

OPENSSL = shutil.which("openssl")


def openssl_available():
    return OPENSSL is not None


class _Keypair:
    def __init__(self):
        self._dir = tempfile.TemporaryDirectory()
        self.priv_path = self._dir.name + "/priv.pem"
        self.pub_path = self._dir.name + "/pub.pem"
        subprocess.run([OPENSSL, "genrsa", "-out", self.priv_path, "2048"],
                       capture_output=True, check=True)
        subprocess.run([OPENSSL, "rsa", "-in", self.priv_path, "-pubout",
                        "-out", self.pub_path], capture_output=True, check=True)
        self.pub_pem = open(self.pub_path).read()

    def decrypt(self, ciphertext):
        result = subprocess.run(
            [OPENSSL, "pkeyutl", "-decrypt", "-inkey", self.priv_path,
             "-pkeyopt", "rsa_padding_mode:pkcs1"],
            input=ciphertext, capture_output=True, check=True)
        return result.stdout

    def close(self):
        self._dir.cleanup()


def _ws_accept_key(client_key):
    return base64.b64encode(
        hashlib.sha1((client_key + WS_GUID).encode("ascii")).digest()).decode("ascii")


def _send_frame(sock, opcode, payload):
    length = len(payload)
    header = bytes([0x80 | opcode])
    if length < 126:
        header += bytes([length])
    elif length < 65536:
        header += bytes([126]) + struct.pack(">H", length)
    else:
        header += bytes([127]) + struct.pack(">Q", length)
    sock.sendall(header + payload)  # server frames are never masked


def _recv_frame(sock, buf):
    def recv_exact(n):
        nonlocal buf
        while len(buf) < n:
            chunk = sock.recv(4096)
            if not chunk:
                raise ConnectionError("closed")
            buf += chunk
        data, buf = buf[:n], buf[n:]
        return data, buf

    b12, buf = recv_exact(2)
    b1, b2 = b12
    opcode = b1 & 0x0F
    masked = b2 & 0x80
    length = b2 & 0x7F
    if length == 126:
        data, buf = recv_exact(2)
        (length,) = struct.unpack(">H", data)
    elif length == 127:
        data, buf = recv_exact(8)
        (length,) = struct.unpack(">Q", data)
    mask_key = None
    if masked:
        mask_key, buf = recv_exact(4)
    payload, buf = recv_exact(length)
    if mask_key:
        payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))
    return opcode, payload, buf


def _encode_text_state(state_uuid_hex_le, icon_uuid_hex_le, text):
    text_bytes = text.encode("utf-8")
    padded_len = (len(text_bytes) + 3) & ~3
    return (bytes.fromhex(state_uuid_hex_le) + bytes.fromhex(icon_uuid_hex_le)
            + struct.pack("<I", len(text_bytes))
            + text_bytes + b"\x00" * (padded_len - len(text_bytes)))


def loxone_uuid_to_le_hex(uuid_str):
    """Inverse of parse_loxone_uuid in bin/loxone-bridge: standard-looking
    "d1-d2-d3-rest" string -> the 16 little-endian bytes Loxone puts on the
    wire, as a hex string."""
    d1, d2, d3, rest = uuid_str.split("-", 3)
    b = struct.pack("<I", int(d1, 16)) + struct.pack("<H", int(d2, 16)) \
        + struct.pack("<H", int(d3, 16)) + bytes.fromhex(rest)
    return b.hex()


class FakeLoxoneWs:
    """Serves the HTTP getPublicKey endpoint and the WS handshake + push on
    one socket pair, matching real Miniserver behavior close enough for
    LivePushThread. `expected_user`/`expected_password` gate the HMAC check —
    a wrong password makes gettoken fail, same as a real Miniserver."""

    def __init__(self, expected_user="admin", expected_password="secret"):
        if not openssl_available():
            raise RuntimeError("openssl not available")
        self.keypair = _Keypair()
        self.expected_user = expected_user
        self.expected_password = expected_password
        self.key2_key = "aa" * 32
        self.key2_salt = "deadbeef"
        self._pushes = []  # [(state_uuid_str, text)], sent after subscribe
        self._push_lock = threading.Lock()
        self._srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._srv.bind(("127.0.0.1", 0))
        self.port = self._srv.getsockname()[1]
        self._srv.listen(5)
        self._stop = threading.Event()
        self._threads = []
        self._accept_thread = threading.Thread(target=self._accept_loop, daemon=True)
        self._accept_thread.start()

    @property
    def host(self):
        return "127.0.0.1"

    def queue_push(self, state_uuid_str, text):
        with self._push_lock:
            self._pushes.append((state_uuid_str, text))

    def _accept_loop(self):
        self._srv.settimeout(0.2)
        while not self._stop.is_set():
            try:
                conn, _ = self._srv.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            t = threading.Thread(target=self._handle_conn, args=(conn,), daemon=True)
            t.start()
            self._threads.append(t)

    def _handle_conn(self, conn):
        try:
            buf = b""
            while b"\r\n\r\n" not in buf:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                buf += chunk
            head, _, buf = buf.partition(b"\r\n\r\n")
            request_line = head.split(b"\r\n", 1)[0]
            path = request_line.split(b" ")[1].decode()

            if path.startswith("/jdev/sys/getPublicKey"):
                pem_oneline = self.keypair.pub_pem.replace(
                    "-----BEGIN PUBLIC KEY-----", "-----BEGIN CERTIFICATE-----"
                ).replace("-----END PUBLIC KEY-----", "-----END CERTIFICATE-----")
                body = json.dumps(
                    {"LL": {"control": path, "value": pem_oneline, "Code": "200"}}
                ).encode()
                resp = (b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                       b"Content-Length: %d\r\n\r\n" % len(body)) + body
                conn.sendall(resp)
                return

            if path.startswith("/ws/rfc6455"):
                self._serve_ws(conn, head, buf)
                return

            conn.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
        except Exception:
            pass
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def _serve_ws(self, conn, head, buf):
        client_key = None
        for line in head.split(b"\r\n")[1:]:
            if line.lower().startswith(b"sec-websocket-key:"):
                client_key = line.split(b":", 1)[1].strip().decode("ascii")
        accept = _ws_accept_key(client_key or "")
        resp = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            "Sec-WebSocket-Accept: %s\r\n\r\n" % accept
        ).encode("ascii")
        conn.sendall(resp)

        def send_json(code, value=None):
            payload = json.dumps({"LL": {"Code": str(code), "value": value}}).encode()
            _send_frame(conn, 0x1, payload)

        while True:
            opcode, payload, buf = _recv_frame(conn, buf)
            if opcode == 0x8:
                return
            if opcode != 0x1:
                continue
            command = payload.decode("utf-8", "replace")

            if command.startswith("jdev/sys/keyexchange/"):
                b64 = command[len("jdev/sys/keyexchange/"):]
                ciphertext = base64.b64decode(b64)
                try:
                    self.keypair.decrypt(ciphertext)  # just prove it decrypts
                    send_json(200, "1")
                except subprocess.CalledProcessError:
                    send_json(500, None)
                continue

            if command.startswith("jdev/sys/getkey2/"):
                send_json(200, {"key": self.key2_key, "salt": self.key2_salt,
                                "hashAlg": "SHA1"})
                continue

            if command.startswith("jdev/sys/gettoken/"):
                parts = command[len("jdev/sys/gettoken/"):].split("/")
                sig, user = parts[0], parts[1]
                pw_hash = hashlib.sha1(
                    ("%s:%s" % (self.expected_password, self.key2_salt)).encode()
                ).hexdigest().upper()
                expected_sig = hmac.new(
                    bytes.fromhex(self.key2_key),
                    ("%s:%s" % (self.expected_user, pw_hash)).encode(),
                    hashlib.sha256).hexdigest()
                if user != self.expected_user or sig != expected_sig:
                    send_json(401, None)
                    continue
                send_json(200, {"token": "faketoken", "key": "ab" * 16,
                                "validUntil": 1000000})
                continue

            if command == "jdev/sps/enablebinstatusupdate":
                send_json(200, "1")
                with self._push_lock:
                    pushes = list(self._pushes)
                for state_uuid_str, text in pushes:
                    body = _encode_text_state(
                        loxone_uuid_to_le_hex(state_uuid_str),
                        loxone_uuid_to_le_hex("00000000-0000-0000-0000000000000000"),
                        text)
                    header = bytes([0x03, 0x03, 0x00, 0x00]) + struct.pack("<I", len(body))
                    _send_frame(conn, 0x2, header)
                    _send_frame(conn, 0x2, body)
                continue

            send_json(0, None)

    def stop(self):
        self._stop.set()
        try:
            self._srv.close()
        except Exception:
            pass
        self.keypair.close()

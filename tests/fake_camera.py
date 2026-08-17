"""A minimal fake HTTP camera, for CameraWorker tests.

Serves either a plain JPEG snapshot (re-fetched by the worker on an interval)
or a real `multipart/x-mixed-replace` MJPEG stream, depending on `mode`.
Frame bytes are arbitrary in these tests — the bridge never decodes them, it
only writes what it received — so plain placeholder bytes stand in for JPEG
data.
"""

import base64
import http.server
import threading
import time


class _Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # noqa: A003
        pass

    def _authorized(self):
        server = self.server
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return False
        try:
            decoded = base64.b64decode(header[6:]).decode("utf-8")
        except Exception:
            return False
        return decoded == "%s:%s" % (server.username, server.password)

    def do_GET(self):  # noqa: N802
        server = self.server
        server.requests.append(self.path)
        if not self._authorized():
            self.send_response(401)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if server.mode == "snapshot":
            body = server.frames[-1]
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        # mode == "mjpeg": one long-lived multipart response.
        self.send_response(200)
        self.send_header(
            "Content-Type", 'multipart/x-mixed-replace; boundary=%s' % server.boundary)
        self.end_headers()
        try:
            for frame in server.frames:
                part = (
                    ("--%s\r\n" % server.boundary).encode("ascii")
                    + b"Content-Type: image/jpeg\r\n"
                    + ("Content-Length: %d\r\n\r\n" % len(frame)).encode("ascii")
                    + frame + b"\r\n"
                )
                self.wfile.write(part)
                self.wfile.flush()
                time.sleep(server.frame_delay)
        except (BrokenPipeError, ConnectionResetError):
            pass


class FakeCamera(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, mode="snapshot", frames=None, username="cam",
                 password="camsecret", frame_delay=0.05):
        super().__init__(("127.0.0.1", 0), _Handler)
        self.mode = mode
        self.frames = frames if frames is not None else [b"frame-1"]
        self.username = username
        self.password = password
        self.boundary = "camboundary"
        self.frame_delay = frame_delay
        self.requests = []
        self._thread = threading.Thread(target=self.serve_forever, daemon=True)
        self._thread.start()

    @property
    def url(self):
        return "http://127.0.0.1:%d/stream" % self.server_address[1]

    def stop(self):
        self.shutdown()
        self.server_close()

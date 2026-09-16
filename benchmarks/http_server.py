from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
import time


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    disable_nagle_algorithm = True
    timeout = 30

    def log_message(self, format, *args):
        pass

    def do_POST(self):
        if self.headers.get("Transfer-Encoding"):
            self.send_error(501, "Transfer-Encoding is not supported by this fixture")
            return
        try:
            lengths = self.headers.get_all("Content-Length", [])
            if len(lengths) != 1 or not lengths[0].isascii() or not lengths[0].isdecimal():
                raise ValueError("Expected one Content-Length")
            length = int(lengths[0])
        except ValueError:
            self.send_error(400, "Invalid Content-Length")
            return

        with self.server.lock:
            self.server.active += 1
            self.server.peak_active = max(self.server.peak_active, self.server.active)
        try:
            remaining = length
            while remaining:
                chunk = self.rfile.read(min(remaining, 65536))
                if not chunk:
                    raise ConnectionError("Incomplete request body")
                remaining -= len(chunk)
            if self.server.delay_ms:
                time.sleep(self.server.delay_ms / 1000)
            with self.server.lock:
                self.server.counts["requests"] += 1
                self.server.counts["request_bytes"] += length
                self.server.counts["response_bytes"] += len(self.server.body)
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(self.server.body)))
            self.end_headers()
            self.wfile.write(self.server.body)
        except OSError:
            self.close_connection = True
            with self.server.lock:
                self.server.counts["errors"] += 1
        finally:
            with self.server.lock:
                self.server.active -= 1


class HttpFixture(ThreadingHTTPServer):
    request_queue_size = 128

    def __init__(self, response_bytes, delay_ms):
        self.body = b"x" * response_bytes
        self.delay_ms = delay_ms
        self.lock = threading.Lock()
        self.counts = dict(connections=0, requests=0, request_bytes=0, response_bytes=0, errors=0)
        self.active = 0
        self.peak_active = 0
        super().__init__(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server_port}/"

    def get_request(self):
        connection = super().get_request()
        with self.lock:
            self.counts["connections"] += 1
        return connection

    def snapshot(self):
        with self.lock:
            return dict(self.counts)

    def reset_peak(self):
        with self.lock:
            self.peak_active = self.active

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.shutdown()
        self.server_close()
        self.thread.join()
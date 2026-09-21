import argparse
import http.client
import http.server
import json
from pathlib import Path
import socketserver
import ssl
import subprocess
import sys
import threading
import time
from urllib.parse import parse_qs, urlsplit


HOST = "pg-durable-mi.blob.core.windows.net"
CLIENT_ID = "11111111-1111-1111-1111-111111111111"
FAILING_CLIENT_ID = "22222222-2222-2222-2222-222222222222"
RESOURCE = "https://storage.azure.com/"
TOKENS = {"system": "MI_PRIVATE_SYSTEM_TOKEN", CLIENT_ID: "MI_PRIVATE_USER_TOKEN"}


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.token_requests = {}
        self.requests = []


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, status, body=None, headers=None):
        encoded = json.dumps(body).encode() if body is not None else b""
        self.send_response(status)
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Content-Type", "application/json")
        self.send_header("Connection", "close")
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(encoded)
        self.close_connection = True


class TokenHandler(Handler):
    def do_GET(self):
        url = urlsplit(self.path)
        query = parse_qs(url.query, keep_blank_values=True)
        client_id = query.get("client_id", ["system"])[0]
        if (
            url.path != "/metadata/identity/oauth2/token"
            or self.headers.get("Metadata") != "true"
            or query.get("api-version") != ["2018-02-01"]
            or query.get("resource") != [RESOURCE]
            or set(query) - {"resource", "api-version", "client_id"}
        ):
            self.reply(400, {"error": "invalid_request"})
            return
        with self.server.state.lock:
            counts = self.server.state.token_requests
            counts[client_id] = counts.get(client_id, 0) + 1
        if client_id == FAILING_CLIENT_ID:
            self.reply(400, {"error": "invalid_request", "error_description": "MI_PRIVATE_PROVIDER_ERROR"})
            return
        if client_id not in TOKENS:
            self.reply(400, {"error": "unknown_identity"})
            return
        self.reply(200, {
            "access_token": TOKENS[client_id],
            "token_type": "Bearer",
            "resource": RESOURCE,
            "expires_on": str(int(time.time()) + 3600),
        })


class DestinationHandler(Handler):
    def do_GET(self):
        self.respond()

    def do_POST(self):
        self.respond()

    def respond(self):
        path = urlsplit(self.path).path
        identity = CLIENT_ID if path.startswith("/user/") else "system"
        if self.headers.get_all("Authorization") != ["Bearer " + TOKENS[identity]]:
            self.reply(401, {"error": "unexpected authorization"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        if length > 8192:
            self.reply(413)
            return
        body = self.rfile.read(length)
        multipart = self.headers.get("Content-Type", "").startswith("multipart/form-data;")
        if self.command == "POST" and (not multipart or b"hello" not in body):
            self.reply(400, {"error": "expected multipart upload"})
            return
        with self.server.state.lock:
            if path == "/system/stats":
                result = {
                    "token_requests": dict(self.server.state.token_requests),
                    "requests": list(self.server.state.requests),
                }
            else:
                self.server.state.requests.append({"method": self.command, "path": path, "multipart": multipart})
                result = None
        if path == "/system/stats":
            self.reply(200, result)
        elif path.endswith("/redirect"):
            self.reply(302, headers={"Location": "https://unapproved.invalid/"})
        elif path.endswith("/unauthorized"):
            self.reply(401)
        else:
            self.reply(204)


class ProxyHandler(socketserver.StreamRequestHandler):
    def handle(self):
        self.request.settimeout(15)
        request = self.rfile.readline(4096).decode("ascii").strip()
        while self.rfile.readline(4096) not in (b"\r\n", b"", b"\n"):
            pass
        if request != f"CONNECT {HOST}:443 HTTP/1.1":
            self.wfile.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
            return
        self.wfile.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        self.wfile.flush()
        with self.server.tls.wrap_socket(self.request, server_side=True) as connection:
            DestinationHandler(connection, self.client_address, self.server)


class ProxyServer(socketserver.ThreadingTCPServer):
    daemon_threads = True


def self_test(token_server, proxy_server, certificate):
    connection = http.client.HTTPConnection(*token_server.server_address, timeout=5)
    connection.request("GET", "/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F", headers={"Metadata": "true"})
    response = connection.getresponse()
    assert response.status == 200
    assert json.loads(response.read())["access_token"] == TOKENS["system"]
    connection.close()
    context = ssl.create_default_context(cafile=certificate)
    connection = http.client.HTTPSConnection(*proxy_server.server_address, context=context, timeout=5)
    connection.set_tunnel(HOST, 443)
    connection.request("GET", "/system/data", headers={"Authorization": "Bearer " + TOKENS["system"]})
    response = connection.getresponse()
    assert response.status == 204
    response.read()
    connection.close()
    print("Managed identity mock self-test passed", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    args.directory.mkdir(parents=True, exist_ok=True)
    certificate = str(args.directory / "certificate.pem")
    private_key = str(args.directory / "key.pem")
    subprocess.run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
        "-subj", f"/CN={HOST}", "-addext", f"subjectAltName=DNS:{HOST}",
        "-keyout", private_key, "-out", certificate,
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    state = State()
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), TokenHandler) as token_server, ProxyServer(("127.0.0.1", 0), ProxyHandler) as proxy_server:
        token_server.state = state
        proxy_server.state = state
        proxy_server.tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        proxy_server.tls.load_cert_chain(certificate, private_key)
        for server in (token_server, proxy_server):
            threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            if args.self_test:
                self_test(token_server, proxy_server, certificate)
            else:
                print(f"http://127.0.0.1:{token_server.server_port}/metadata/identity/oauth2/token\thttp://127.0.0.1:{proxy_server.server_address[1]}\t{certificate}", flush=True)
                sys.stdin.readline()
        finally:
            token_server.shutdown()
            proxy_server.shutdown()


if __name__ == "__main__":
    main()
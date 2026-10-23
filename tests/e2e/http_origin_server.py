#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

"""Loopback-only TLS fixture for origin credentials and HTTP capacity tests."""

import http.server
import json
import pathlib
import ssl
import sys
import threading
import time
import urllib.parse

counts = {}
counts_lock = threading.Lock()
counts_path = pathlib.Path(sys.argv[1]).with_name("requests.json")
counts_path.write_text("{}", encoding="ascii")
capacity_release = counts_path.with_name("capacity-release")


def write_counts():
    temporary = counts_path.with_suffix(".tmp")
    temporary.write_text(json.dumps(counts), encoding="ascii")
    temporary.replace(counts_path)


class Handler(http.server.BaseHTTPRequestHandler):
    def handle_request(self):
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path.strip("/")
        case = urllib.parse.parse_qs(parsed.query).get("case", ["default"])[0]
        with counts_lock:
            counts[case] = counts.get(case, 0) + 1
            if path == "capacity":
                capacity = counts.setdefault("_capacity", {"active": 0, "peak": 0})
                capacity["active"] += 1
                capacity["peak"] = max(capacity["peak"], capacity["active"])
            write_counts()
        if path == "capacity":
            self.handle_capacity(case)
            return
        expected = {
            "control": "E80_CONTROL",
            "a": "E80_A",
            "c": "E80_C",
            "a-rotated": "E80_A_ROTATED",
        }.get(path)
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        valid = expected is not None and self.headers.get("X-Origin") == expected
        self.send_response(204 if valid else 403)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def handle_capacity(self, case):
        try:
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
            self.send_response(500 if case == "error" else 200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"o")
            self.wfile.flush()
            deadline = time.monotonic() + 60
            while not capacity_release.exists():
                if time.monotonic() >= deadline:
                    raise TimeoutError("HTTP capacity fixture was not released")
                time.sleep(0.01)
        finally:
            # Count down before the last byte lets the client dispatch its successor.
            with counts_lock:
                counts["_capacity"]["active"] -= 1
                write_counts()
        self.wfile.write(b"k")

    do_GET = handle_request
    do_POST = handle_request

    def log_message(self, *_args):
        pass


with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(sys.argv[2], sys.argv[3])
    server.socket = context.wrap_socket(server.socket, server_side=True)
    pathlib.Path(sys.argv[1]).write_text(str(server.server_port), encoding="ascii")
    server.serve_forever()

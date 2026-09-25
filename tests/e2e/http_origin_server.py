#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

"""Loopback-only, non-echoing credential oracle for origin-routing tests."""

import http.server
import json
import pathlib
import ssl
import sys
import threading
import urllib.parse

counts = {}
counts_lock = threading.Lock()
counts_path = pathlib.Path(sys.argv[1]).with_name("requests.json")
counts_path.write_text("{}", encoding="ascii")


class Handler(http.server.BaseHTTPRequestHandler):
    def handle_request(self):
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path.strip("/")
        case = urllib.parse.parse_qs(parsed.query).get("case", ["default"])[0]
        with counts_lock:
            counts[case] = counts.get(case, 0) + 1
            temporary = counts_path.with_suffix(".tmp")
            temporary.write_text(json.dumps(counts), encoding="ascii")
            temporary.replace(counts_path)
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

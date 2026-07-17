#!/usr/bin/env python3
"""Tiny HTTP mock for testing opencode-provider-login.sh.

This is a test fixture, not project runtime code. It exposes the three endpoints
used by the client OAuth flow and records the last User-Agent it received.
"""
import http.server
import json
import socket
import sys
import threading

PORT_FILE = sys.argv[1]
LOG_FILE = sys.argv[2]
lock = threading.Lock()
last_user_agent = ""


def log(msg):
    with open(LOG_FILE, "a") as f:
        f.write(msg + "\n")


class Handler(http.server.BaseHTTPRequestHandler):
    def _send_json(self, body, status=200):
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _capture_ua(self):
        global last_user_agent
        ua = self.headers.get("User-Agent", "")
        with lock:
            last_user_agent = ua
        log(f"{self.command} {self.path} UA={ua}")

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length:
            return self.rfile.read(length)
        return b""

    def do_GET(self):
        self._capture_ua()
        if self.path.startswith("/gateway/providers/test-oauth/opencode"):
            self._send_json({
                "provider": {
                    "name": "Test OAuth",
                    "npm": "test-oauth",
                    "options": {"baseURL": "http://gateway/test"},
                    "models": {"m1": {"name": "M1"}},
                },
                "auth_type": "oauth",
                "auth_route": "/gateway/providers/test-oauth/auth",
            })
            return
        if self.path.startswith("/gateway/providers/test-api-key/opencode"):
            self._send_json({
                "provider": {
                    "name": "Test API Key",
                    "npm": "test-api-key",
                    "options": {"baseURL": "http://gateway/test"},
                    "models": {"m1": {"name": "M1"}},
                },
                "auth_type": "api_key",
            })
            return
        self._send_json({"error": "not found"}, 404)

    def do_POST(self):
        self._capture_ua()
        body = self._read_body()
        log(f"  body={body.decode('utf-8', errors='replace')}")
        if self.path.startswith("/gateway/providers/test-oauth/auth/device"):
            if self.path.endswith("/poll"):
                self._send_json({"access_token": "test-access-token"})
            else:
                self._send_json({
                    "user_code": "TESTCODE",
                    "device_code": "DEVCODE",
                    "verification_uri_complete": "http://example.com/verify",
                    "interval": 1,
                    "expires_in": 300,
                })
            return
        self._send_json({"error": "not found"}, 404)

    def log_message(self, fmt, *args):
        pass


# Bind to an ephemeral port and write it out.
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.bind(("127.0.0.1", 0))
port = sock.getsockname()[1]
sock.close()

with open(PORT_FILE, "w") as f:
    f.write(str(port))

with http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler) as httpd:
    httpd.serve_forever()

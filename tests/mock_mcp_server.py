#!/usr/bin/env python3
"""Minimal MCP-over-HTTP mock server for CI provisioning tests.

Speaks JSON-RPC 2.0 on http://127.0.0.1:<port>/mcp with Bearer PSK auth.
Python stdlib only -- no pip dependencies.
"""

import argparse
import json
import signal
import sys
import uuid
from http.server import HTTPServer, BaseHTTPRequestHandler

EXPECTED_PSK = ""
SESSION_ID = str(uuid.uuid4())


class McpHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[mock-mcp] {fmt % args}", file=sys.stderr)

    def _check_auth(self):
        auth = self.headers.get("Authorization", "")
        if auth != f"Bearer {EXPECTED_PSK}":
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": "unauthorized"}).encode())
            return False
        return True

    def _json_response(self, status, body, extra_headers=None):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def do_POST(self):
        if self.path != "/mcp":
            self.send_error(404)
            return

        if not self._check_auth():
            return

        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""

        try:
            request = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            self._json_response(400, {"error": "invalid json"})
            return

        method = request.get("method", "")
        req_id = request.get("id")

        if method == "initialize":
            self._json_response(200, {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "protocolVersion": "2025-11-25",
                    "serverInfo": {"name": "mock-edamame", "version": "0.0.1"},
                    "capabilities": {"tools": {}},
                },
            }, extra_headers={"Mcp-Session-Id": SESSION_ID})
            return

        if method == "notifications/initialized":
            self.send_response(202)
            self.end_headers()
            return

        if method == "tools/call":
            tool_name = request.get("params", {}).get("name", "unknown")
            stub = {"stub": True, "tool": tool_name}
            self._json_response(200, {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "content": [{"type": "text", "text": json.dumps(stub)}],
                },
            }, extra_headers={"Mcp-Session-Id": SESSION_ID})
            return

        if method == "tools/list":
            self._json_response(200, {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {"tools": [
                    {"name": "get_score", "description": "mock", "inputSchema": {"type": "object"}},
                ]},
            }, extra_headers={"Mcp-Session-Id": SESSION_ID})
            return

        self._json_response(200, {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {},
        })


def main():
    global EXPECTED_PSK

    parser = argparse.ArgumentParser(description="Mock MCP server for CI")
    parser.add_argument("--psk", required=True, help="Expected PSK token")
    parser.add_argument("--port", type=int, default=3000, help="Listen port")
    args = parser.parse_args()
    EXPECTED_PSK = args.psk

    server = HTTPServer(("127.0.0.1", args.port), McpHandler)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    print(f"[mock-mcp] Listening on http://127.0.0.1:{args.port}/mcp (PSK: {args.psk[:4]}...)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()

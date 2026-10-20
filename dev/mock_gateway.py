#!/usr/bin/env python3
"""B-3 (2026-10-20 audit, ported from welite's mock service design):
fault-injection mock WeRead gateway, Python stdlib only.

The CI specs (spec/mock_service_spec.lua) point weread_K4's REAL luasocket
transport at this server via Client.set_test_origin, so the "slow / broken /
empty server" classes get CI-grade regression coverage instead of relying on
stubbed socket.http.

Control plane (/__admin/*, JSON):
  POST /__admin/mode     {"mode": "ok|slow|drop|empty|error",
                          "delay_ms": 3000, "status": 502}
  POST /__admin/reset    clear mode (-> ok) + request log
  GET  /__admin/requests {"requests": [{"method","path","body","ts"}, ...]}
  GET  /__admin/health   -> "ok"

Business endpoints (anything else): logged, then served per the active mode.
The only response body the specs parse is the read-report shape:
  POST /web/book/read -> {"succ": 1}   (the endpoint progress reporting uses)

Fault modes:
  ok     respond normally
  slow   sleep delay_ms (default 3000) BEFORE responding — drives the F-21
         total-deadline timeout path
  drop   receive the request, log it, close the socket with NO response —
         the client sees a "closed" transport error (F-23 retryable class)
  empty  200 with an empty body — decode must fail cleanly, never crash
  error  respond with `status` (default 502)

Usage: python3 dev/mock_gateway.py [--port PORT]   (default 18473)
"""
import argparse
import json
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_lock = threading.Lock()
_state = {"mode": "ok", "delay_ms": 3000, "status": 502}
_requests = []


class GatewayHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # silence stderr noise
        pass

    # -- helpers -----------------------------------------------------------

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return ""
        raw = self.rfile.read(length)
        try:
            return raw.decode("utf-8", "replace")
        except Exception:
            return "<binary %d bytes>" % len(raw)

    def _send_json(self, obj, status=200):
        payload = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _record(self, body):
        with _lock:
            _requests.append({
                "method": self.command,
                "path": self.path,
                "body": body,
                "ts": time.time(),
            })

    # -- control plane -----------------------------------------------------

    def _serve_admin(self):
        if self.path == "/__admin/health":
            self._send_json({"ok": True})
        elif self.path == "/__admin/requests":
            with _lock:
                self._send_json({"requests": list(_requests)})
        elif self.path == "/__admin/reset":
            with _lock:
                _state.update(mode="ok", delay_ms=3000, status=502)
                del _requests[:]
            self._send_json({"ok": True})
        elif self.path == "/__admin/mode":
            body = self._read_body()
            try:
                patch = json.loads(body)
            except ValueError:
                self._send_json({"ok": False, "error": "bad json"}, 400)
                return
            with _lock:
                if "mode" in patch:
                    _state["mode"] = str(patch["mode"])
                if "delay_ms" in patch:
                    _state["delay_ms"] = int(patch["delay_ms"])
                if "status" in patch:
                    _state["status"] = int(patch["status"])
            self._send_json({"ok": True, "state": dict(_state)})
        else:
            self._send_json({"ok": False, "error": "unknown admin path"}, 404)

    # -- business endpoints ------------------------------------------------

    def _serve_business(self):
        body = self._read_body()
        self._record(body)
        with _lock:
            mode, delay_ms, status = (
                _state["mode"], _state["delay_ms"], _state["status"])
        if mode == "drop":
            # Receive + log, then cut the socket without any response bytes.
            # The client must classify this as a transient transport error.
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.connection.close()
            self.close_connection = True
            return
        if mode == "slow":
            time.sleep(delay_ms / 1000.0)
        if mode == "error":
            self._send_json({"error": "mock injected failure"}, status)
            return
        if mode == "empty":
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        # ok (and the tail of slow): the minimal shapes the client consumes.
        if self.path.startswith("/web/book/read"):
            self._send_json({"succ": 1, "errCode": 0})
        else:
            self._send_json({"succ": 1, "errCode": 0, "path": self.path})

    # -- dispatch ----------------------------------------------------------

    def _handle(self):
        if self.path.startswith("/__admin/"):
            self._serve_admin()
        else:
            self._serve_business()

    def do_GET(self):
        self._handle()

    def do_POST(self):
        self._handle()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18473)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), GatewayHandler)
    server.daemon_threads = True
    print("mock gateway on 127.0.0.1:%d" % args.port, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

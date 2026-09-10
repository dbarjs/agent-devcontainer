#!/usr/bin/env python3
"""Fake clipboard daemon for the xclip shim's tier 1 suite (tests/xclip).

Stands in for the clipboard extension's daemon (ADR-0012) with canned answers
read from FAKE_CLIPD_DIR on every request, so a test sets the "clipboard" by
writing files:

  types   body of GET /types (200; missing -> 200 with an empty body)
  png     body of GET /png   (200, even when empty; missing -> 404)
  text    body of GET /text  (200, even when empty; missing -> 404)
  delay   seconds to sleep before answering anything (shim timeout tests)

Every request is appended to FAKE_CLIPD_DIR/requests.log as "METHOD PATH".
Binds 127.0.0.1 on a free port and writes it to FAKE_CLIPD_DIR/port.
"""
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE = os.environ["FAKE_CLIPD_DIR"]


def state_file(name):
    return os.path.join(STATE, name)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # keep the test output clean
        pass

    def record(self):
        with open(state_file("requests.log"), "a") as log:
            log.write(f"{self.command} {self.path}\n")

    def reply(self, code, body=b""):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.record()
        if os.path.exists(state_file("delay")):
            with open(state_file("delay")) as f:
                time.sleep(float(f.read().strip() or "0"))
        if self.path == "/health":
            return self.reply(200, b'{"adc":"fake-clipd"}')
        if self.path == "/types":
            body = b""
            if os.path.exists(state_file("types")):
                with open(state_file("types"), "rb") as f:
                    body = f.read()
            return self.reply(200, body)
        if self.path in ("/png", "/text"):
            name = self.path.lstrip("/")
            if not os.path.exists(state_file(name)):
                return self.reply(404, b"nothing of that kind on the clipboard\n")
            with open(state_file(name), "rb") as f:
                return self.reply(200, f.read())
        return self.reply(404)

    def do_POST(self):
        self.record()
        return self.reply(405)


def main():
    server = HTTPServer(("127.0.0.1", 0), Handler)
    with open(state_file("port"), "w") as f:
        f.write(str(server.server_address[1]))
    sys.stdout.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()

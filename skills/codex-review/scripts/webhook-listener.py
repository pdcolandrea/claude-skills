#!/usr/bin/env python3
"""Minimal local receiver for `gh webhook forward`.

`gh webhook forward` POSTs each GitHub webhook delivery to a local URL. This
server answers 200 to every request and appends one byte to a signal file, so the
wait loop in poll-review.sh learns "something happened on the PR, re-check now" —
turning the up-to-CODEX_POLL_INTERVAL wait into a near-instant wake.

It deliberately does NOT parse the payload. poll-review.sh re-runs the canonical
gh-api detection to classify CLEAN vs FINDINGS; the webhook is only a nudge. That
keeps verdict logic in one place and means a malformed/unexpected payload can
never produce a wrong verdict — at worst it triggers a harmless extra re-check.

Usage: webhook-listener.py <port> <signal_file>
Exits non-zero if the port can't be bound (poll-review.sh treats that as a
webhook-setup failure and falls back to polling).
"""
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


def main():
    port = int(sys.argv[1])
    signal_file = sys.argv[2]

    class Handler(BaseHTTPRequestHandler):
        def _nudge(self):
            # Drain the body so gh's HTTP client sees a clean, complete response.
            length = int(self.headers.get("Content-Length", 0) or 0)
            if length:
                self.rfile.read(length)
            self.send_response(200)
            self.end_headers()
            with open(signal_file, "a") as fh:
                fh.write("x")

        def do_POST(self):
            self._nudge()

        def do_GET(self):
            self._nudge()

        def log_message(self, *args):
            pass  # stay quiet; poll-review.sh owns all output

    HTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()

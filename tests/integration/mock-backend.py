"""A stand-in for Datadog's Series API and an OpenTelemetry collector's
OTLP/HTTP receiver, for the backend integration tests.

    mock-backend.py <dir>

Serves plain HTTP on 127.0.0.1 (Vigil allows http only to this host), on a
free port written to <dir>/port once it listens. Every request is appended
to <dir>/requests.log as one JSON line: method, path, headers and body. It
is answered with the status in <dir>/status (default 202 for Datadog and
200 for OTLP, read again for every request so a test can make the backend
fail) and the body in <dir>/reply (default {}).

Test only: never use it for anything else.
"""

import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR = sys.argv[1]
LOCK = threading.Lock()


def read(name, default):
    try:
        with open(os.path.join(DIR, name), encoding="utf-8") as f:
            return f.read().strip() or default
    except OSError:
        return default


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode("utf-8", "replace")
        record = {"method": "POST", "path": self.path, "headers": dict(self.headers.items()), "body": body}
        with LOCK, open(os.path.join(DIR, "requests.log"), "a", encoding="utf-8") as f:
            f.write(json.dumps(record) + "\n")
        status = int(read("status", "202" if self.path.startswith("/api/") else "200"))
        reply = read("reply", "{}").encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(DIR, "port.tmp"), "w", encoding="utf-8") as f:
    f.write(str(server.server_address[1]))
os.replace(os.path.join(DIR, "port.tmp"), os.path.join(DIR, "port"))
server.serve_forever()

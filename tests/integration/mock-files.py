"""A stand-in for an HTTPS file server and a Git server, for the fetcher
integration tests.

    mock-files.py <dir>

Serves the files under <dir>/www over plain HTTP on 127.0.0.1 (Vigil allows
http only to this host), on a free port written to <dir>/port once it
listens. A bare repository under www, prepared with git update-server-info,
is served by Git's "dumb" HTTP protocol. When <dir>/require holds a path
prefix and a header line ("/files/ Name: value"), every request for a path
under that prefix must carry that header or gets 401. Every request is
appended to <dir>/requests.log as one JSON line: method, path and headers.
A file <dir>/redirects holds "<path> <target>" lines: those paths answer
302, as GitHub's /releases/latest does.

Test only: never use it for anything else.
"""

import json
import os
import socketserver
import sys
import threading
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

DIR = sys.argv[1]
LOCK = threading.Lock()


class Handler(SimpleHTTPRequestHandler):
    def redirected(self):
        try:
            with open(os.path.join(DIR, "redirects"), encoding="utf-8") as f:
                moves = dict(line.split() for line in f if line.strip())
        except OSError:
            return False
        if self.path not in moves:
            return False
        self.send_response(302)
        self.send_header("Location", moves[self.path])
        self.send_header("Content-Length", "0")
        self.end_headers()
        return True

    def do_HEAD(self):
        if not self.redirected():
            super().do_HEAD()

    def do_GET(self):
        if self.redirected():
            return
        record = {"method": "GET", "path": self.path, "headers": dict(self.headers.items())}
        with LOCK, open(os.path.join(DIR, "requests.log"), "a", encoding="utf-8") as f:
            f.write(json.dumps(record) + "\n")
        try:
            with open(os.path.join(DIR, "require"), encoding="utf-8") as f:
                prefix, _, header = f.read().strip().partition(" ")
                name, _, value = header.partition(":")
        except OSError:
            prefix = name = ""
        if name and self.path.startswith(prefix) and self.headers.get(name.strip()) != value.strip():
            self.send_error(401)
            return
        super().do_GET()

    def log_message(self, *args):
        pass


class Server(ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer.server_bind looks up the host's full name, which can
        # stall for many seconds on a CI machine; this server needs no name.
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]


server = Server(("127.0.0.1", 0), partial(Handler, directory=os.path.join(DIR, "www")))
with open(os.path.join(DIR, "port.tmp"), "w", encoding="utf-8") as f:
    f.write(str(server.server_address[1]))
os.replace(os.path.join(DIR, "port.tmp"), os.path.join(DIR, "port"))
server.serve_forever()

"""A stand-in for HashiCorp Vault, Azure Key Vault, Microsoft Entra ID, AWS
Secrets Manager (checking every request's SigV4 signature) and the
Azure and AWS instance metadata endpoints, for the secret store integration
tests.

    mock-store.py <dir> <cert.pem> <key.pem>

Serves HTTPS (the stores and the sign-in) and plain HTTP (the metadata
endpoint) on 127.0.0.1, on free ports written to <dir>/ports as
"<https> <http>" once both listen. Answers from <dir>/data.json, read again
for every request so a test can rotate values. Every request's path and
query is appended to <dir>/urls.log, so a test can check that no secret
ever travels in a URL. A path containing "slow" is answered after 5s.

Test only: never use it for anything else.
"""

import hashlib
import hmac
import json
import os
import ssl
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR, CERT, KEY = sys.argv[1], sys.argv[2], sys.argv[3]
LOCK = threading.Lock()


def data():
    with open(os.path.join(DIR, "data.json"), encoding="utf-8") as f:
        return json.load(f)


def sigv4_valid(handler, body, keys):
    """Whether a request carries a valid AWS Signature Version 4, for a key
    pair in keys: {access key id: (secret key, session token or None)}.
    Written from AWS's documentation, independently of Vigil's signer."""
    auth = handler.headers.get("Authorization", "")
    if not auth.startswith("AWS4-HMAC-SHA256 "):
        return "IncompleteSignature"
    parts = dict(p.strip().split("=", 1) for p in auth[len("AWS4-HMAC-SHA256 "):].split(","))
    akid, date, region, service, _ = parts["Credential"].split("/")
    if akid not in keys:
        return "UnrecognizedClientException"
    secret, session = keys[akid]
    if session is not None and handler.headers.get("X-Amz-Security-Token") != session:
        return "UnrecognizedClientException"
    signed = parts["SignedHeaders"].split(";")
    canon = "".join(f"{n}:{handler.headers.get(n, '').strip()}\n" for n in signed)
    amzdate = handler.headers.get("X-Amz-Date", "")
    creq = f"{handler.command}\n/\n\n{canon}\n{parts['SignedHeaders']}\n{hashlib.sha256(body).hexdigest()}"
    sts = f"AWS4-HMAC-SHA256\n{amzdate}\n{date}/{region}/{service}/aws4_request\n{hashlib.sha256(creq.encode()).hexdigest()}"
    k = ("AWS4" + secret).encode()
    for m in (date, region, service, "aws4_request"):
        k = hmac.new(k, m.encode(), hashlib.sha256).digest()
    want = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(want, parts["Signature"]) or "host" not in signed or "x-amz-date" not in signed:
        return "InvalidSignatureException"
    return None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, status, body):
        raw = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def text(self, status, body):
        raw = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n).decode("utf-8")

    def route(self, method):
        with LOCK:
            with open(os.path.join(DIR, "urls.log"), "a", encoding="utf-8") as f:
                f.write(f"{method} {self.path}\n")
        if "slow" in self.path:
            time.sleep(5)
        d = data()
        url = urllib.parse.urlsplit(self.path)
        path = urllib.parse.unquote(url.path)
        if self.server.plain:
            # The instance metadata endpoint: a token for the managed identity.
            if method == "GET" and path == "/metadata/identity/oauth2/token" and self.headers.get("Metadata") == "true":
                return self.answer(200, {"access_token": d["imds_token"], "token_type": "Bearer"})
            # AWS IMDSv2: a session token first, then the role and its credentials.
            if method == "PUT" and path == "/latest/api/token" and self.headers.get("X-aws-ec2-metadata-token-ttl-seconds"):
                return self.text(200, d["imds_session"])
            if path.startswith("/latest/meta-data/iam/security-credentials/"):
                if self.headers.get("X-aws-ec2-metadata-token") != d["imds_session"]:
                    return self.text(401, "")
                role = path[len("/latest/meta-data/iam/security-credentials/"):]
                if role == "":
                    return self.text(200, "vigil-role")
                if role == "vigil-role":
                    return self.answer(200, {"Code": "Success", "AccessKeyId": d["aws_ip_key_id"],
                                             "SecretAccessKey": d["aws_ip_secret"], "Token": d["aws_ip_session"]})
                return self.text(404, "")
            return self.answer(400, {"error": "invalid_request"})
        if method == "POST" and path == "/" and self.headers.get("X-Amz-Target") == "secretsmanager.GetSecretValue":
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            error = sigv4_valid(self, body, {d["aws_key_id"]: (d["aws_secret"], None),
                                             d["aws_ip_key_id"]: (d["aws_ip_secret"], d["aws_ip_session"])})
            if error:
                return self.answer(400, {"__type": error})
            value = d["aws"].get(json.loads(body)["SecretId"])
            if value is None:
                return self.answer(400, {"__type": "ResourceNotFoundException"})
            return self.answer(200, {"Name": json.loads(body)["SecretId"], "SecretString": value})
        if method == "POST" and path == "/v1/auth/approle/login":
            b = json.loads(self.body())
            if b.get("role_id") == d["role_id"] and b.get("secret_id") == d["secret_id"]:
                return self.answer(200, {"auth": {"client_token": d["approle_token"]}})
            return self.answer(400, {"errors": ["invalid role or secret id"]})
        if method == "GET" and path.startswith("/v1/"):
            if self.headers.get("X-Vault-Token") not in (d["vault_token"], d["approle_token"]):
                return self.answer(403, {"errors": ["permission denied"]})
            item = d["vault"].get(path[len("/v1/"):])
            if item is None:
                return self.answer(404, {"errors": []})
            return self.answer(200, {"data": {"data": item, "metadata": {"version": 1}}})
        if method == "POST" and path.endswith("/oauth2/v2.0/token"):
            form = urllib.parse.parse_qs(self.body())
            if form.get("client_secret") == [d["sp_secret"]] and form.get("grant_type") == ["client_credentials"]:
                return self.answer(200, {"access_token": d["sp_token"], "token_type": "Bearer"})
            return self.answer(401, {"error": "invalid_client"})
        if method == "GET" and path.startswith("/secrets/"):
            if self.headers.get("Authorization") not in ("Bearer " + d["imds_token"], "Bearer " + d["sp_token"]):
                return self.answer(401, {"error": {"code": "Unauthorized"}})
            value = d["kv"].get(path[len("/secrets/"):])
            if value is None:
                return self.answer(404, {"error": {"code": "SecretNotFound"}})
            return self.answer(200, {"value": value, "attributes": {"enabled": True}})
        return self.answer(404, {"error": "no such endpoint"})

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PUT(self):
        self.route("PUT")


def serve(tls):
    s = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    s.plain = not tls
    if tls:
        c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        c.load_cert_chain(CERT, KEY)
        s.socket = c.wrap_socket(s.socket, server_side=True)
    threading.Thread(target=s.serve_forever, daemon=True).start()
    return s.server_address[1]


https_port = serve(True)
http_port = serve(False)
with open(os.path.join(DIR, "ports.tmp"), "w", newline="\n") as f:
    f.write(f"{https_port} {http_port}\n")
os.replace(os.path.join(DIR, "ports.tmp"), os.path.join(DIR, "ports"))
while True:
    time.sleep(3600)

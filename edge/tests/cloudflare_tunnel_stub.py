#!/usr/bin/env python3
"""A stub of the Cloudflare endpoints edge.sh tunnel calls: zones, tunnels, their
configuration, DNS records and the connector token.

It exists so tunnel_test.sh can run the REAL script. State lives in JSON files
so the test can seed it (a zone, a stray A record, a deleted tunnel) and
inspect what was done. Every request must carry the expected API token.
"""
import json
import os
import sys
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

PORT, STATE, TOKEN = int(sys.argv[1]), sys.argv[2], sys.argv[3]


def load(name):
    path = os.path.join(STATE, name + ".json")
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        return json.load(f)


def save(name, data):
    with open(os.path.join(STATE, name + ".json"), "w") as f:
        json.dump(data, f)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, result, success=True, status=200):
        body = json.dumps({"success": success, "errors": [] if success else [{"message": "stub: refused"}],
                           "result": result}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorised(self):
        if self.headers.get("Authorization") == "Bearer " + TOKEN:
            return True
        self._send(None, success=False, status=403)
        return False

    def _parts(self):
        u = urlparse(self.path)
        return [p for p in u.path.split("/") if p], parse_qs(u.query)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or "{}")

    def do_GET(self):
        if self.path == "/health":
            return self._send([])
        if not self._authorised():
            return
        p, q = self._parts()
        if p == ["zones"]:
            return self._send([z for z in load("zones").values() if z["name"] == q.get("name", [""])[0]])
        if len(p) == 3 and p[0] == "accounts" and p[2] == "cfd_tunnel":
            name = q.get("name", [""])[0]
            deleted = q.get("is_deleted", [""])[0]
            return self._send([t for t in load("tunnels").values()
                               if t["name"] == name and (deleted != "false" or not t["deleted"])])
        if len(p) == 5 and p[2] == "cfd_tunnel" and p[4] == "token":
            return self._send("connector-token-" + p[3])
        if len(p) == 3 and p[0] == "zones" and p[2] == "dns_records":
            name = q.get("name", [""])[0]
            return self._send([r for r in load("dns").values() if r["zone"] == p[1] and r["name"] == name])
        return self._send([])

    def do_POST(self):
        body = self._body()
        if not self._authorised():
            return
        p, _ = self._parts()
        if len(p) == 3 and p[2] == "cfd_tunnel":
            t = load("tunnels"); tid = str(uuid.uuid4())
            t[tid] = {"id": tid, "name": body["name"], "deleted": False, "config_src": body.get("config_src")}
            save("tunnels", t)
            return self._send(t[tid])
        if len(p) == 3 and p[2] == "dns_records":
            d = load("dns"); rid = uuid.uuid4().hex
            d[rid] = {"id": rid, "zone": p[1], **body}
            save("dns", d)
            return self._send(d[rid])
        return self._send({})

    def do_PUT(self):
        body = self._body()
        if not self._authorised():
            return
        p, _ = self._parts()
        if len(p) == 5 and p[4] == "configurations":
            c = load("configs"); c[p[3]] = body; save("configs", c)
            return self._send(body)
        if len(p) == 4 and p[2] == "dns_records":
            d = load("dns"); d[p[3]] = {"id": p[3], "zone": p[1], **body}; save("dns", d)
            return self._send(d[p[3]])
        return self._send({})

    def do_DELETE(self):
        if not self._authorised():
            return
        p, _ = self._parts()
        if len(p) == 4 and p[2] == "dns_records":
            d = load("dns"); d.pop(p[3], None); save("dns", d)
            return self._send({"id": p[3]})
        return self._send({})


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

#!/usr/bin/env python3
"""A stub of the Cloudflare Access endpoints cf-access.sh calls.

It exists so cf-access_test.sh can run the REAL script — its jq pipelines, its
reuse branches, its guard against a second policy — instead of a
re-implementation. State lives in JSON files so the test can inspect what was
created and tamper with it.

Creating a service token whose name contains "fail" returns an API error, so
the test can make a run die after it has already minted something.
"""
import json
import os
import sys
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
STATE = sys.argv[2]

for name in ("tokens", "apps", "policies"):
    path = os.path.join(STATE, name + ".json")
    if not os.path.exists(path):
        with open(path, "w") as f:
            json.dump({}, f)


def load(name):
    with open(os.path.join(STATE, name + ".json")) as f:
        return json.load(f)


def save(name, data):
    with open(os.path.join(STATE, name + ".json"), "w") as f:
        json.dump(data, f)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, result, success=True):
        errors = [] if success else [{"code": 1000, "message": "stub: refused"}]
        body = json.dumps({"success": success, "errors": errors, "result": result}).encode()
        self.send_response(200 if success else 400)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length) or "{}")

    @staticmethod
    def _app_id(path):
        return path.split("/access/apps/")[1].split("/")[0]

    def do_GET(self):
        if self.path == "/health":
            return self._send([])
        if self.path.endswith("/access/service_tokens"):
            return self._send(list(load("tokens").values()))
        if self.path.endswith("/access/apps"):
            return self._send(list(load("apps").values()))
        if self.path.endswith("/policies"):
            app = self._app_id(self.path)
            return self._send([p for p in load("policies").values() if p["app"] == app])
        return self._send([])

    def do_POST(self):
        body = self._body()

        if self.path.endswith("/access/service_tokens"):
            if "fail" in body["name"]:
                return self._send(None, success=False)
            tokens = load("tokens")
            tid = uuid.uuid4().hex
            # The secret is returned ONCE, at creation — the behaviour that makes
            # a half-failed run so expensive, so the stub reproduces it.
            tokens[tid] = {"id": tid, "name": body["name"], "client_id": tid + ".access"}
            save("tokens", tokens)
            return self._send({**tokens[tid], "client_secret": "secret-" + tid})

        if self.path.endswith("/rotate"):
            tid = self.path.split("/service_tokens/")[1].split("/")[0]
            return self._send({"id": tid, "client_id": tid + ".access",
                               "client_secret": "rotated-" + uuid.uuid4().hex})

        if self.path.endswith("/access/apps"):
            apps = load("apps")
            aid = uuid.uuid4().hex
            apps[aid] = {"id": aid, "name": body["name"], "domain": body["domain"],
                         "session_duration": body.get("session_duration")}
            save("apps", apps)
            return self._send(apps[aid])

        if self.path.endswith("/policies"):
            policies = load("policies")
            pid = uuid.uuid4().hex
            policies[pid] = {"id": pid, "app": self._app_id(self.path), **body}
            save("policies", policies)
            return self._send(policies[pid])

        return self._send({})

    def do_PUT(self):
        body = self._body()
        if "/policies/" in self.path:
            pid = self.path.rsplit("/", 1)[1]
            policies = load("policies")
            policies[pid] = {"id": pid, "app": self._app_id(self.path), **body}
            save("policies", policies)
            return self._send(policies[pid])
        return self._send({})


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

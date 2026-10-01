#!/usr/bin/env bash
# upgrade_test.sh — run container.sh upgrade against a fake docker and a health stub,
# and check the branches that decide whether data survives.
#
#   upgrade/tests/upgrade_test.sh
#
# The fake's every start "migrates" the data (see fake-docker), so a rollback
# that restores only the image, not the data, is caught.
#
# What it asserts:
#   1. a healthy upgrade: new version running, version written, snapshot kept
#   2. a new version that starts, migrates, and is unhealthy: rolled back, and
#      the data is exactly what it was before the upgrade
#   3. a new version that fails to start: rolled back
#   4. a snapshot without the expected file: no upgrade, service restarted
#   5. the service coming back on other storage: stopped loudly
#   6. --app pocketbase: logs in with a password holding a quote, JSON-escaped,
#      and the password never in curl's arguments
#   7. old snapshots pruned to --keep; bad input refused
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../container.sh"
W="$(mktemp -d)"
trap 'rm -rf "$W"; [ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null || true' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$W/bin"; cp "$HERE/fake-docker" "$W/bin/docker"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/curl.argv"\nexec %s "$@"\n' "$W" "$(command -v curl)" > "$W/bin/curl"
chmod +x "$W/bin/curl"
export FAKE_DOCKER="$W/docker"
reset() { # version
  rm -rf "$FAKE_DOCKER"; mkdir -p "$FAKE_DOCKER/volumes/vol1"
  echo vol1 > "$FAKE_DOCKER/mount"; echo 1 > "$FAKE_DOCKER/running"; echo "$1" > "$FAKE_DOCKER/version"
  printf 'original data\n' > "$FAKE_DOCKER/volumes/vol1/data.db"
  printf 'APPV=%s\nOTHER=kept\n' "$1" > "$W/app.env"
}

# Health: 200 unless the running version is "unhealthy". PocketBase's login
# endpoint accepts exactly the expected identity and password, sent as JSON.
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 - "$PORT" "$FAKE_DOCKER" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port, state = int(sys.argv[1]), sys.argv[2]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, body=b"{}"):
        self.send_response(code); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        try: v = open(state + "/version").read().strip()
        except OSError: v = ""
        if self.path.startswith("/api/collections/notes/records"):
            return self.reply(200 if self.headers.get("Authorization") == "tok123" else 401)
        self.reply(503 if v == "unhealthy" else 200)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        try: body = json.loads(self.rfile.read(n))
        except ValueError: return self.reply(400)
        ok = body == {"identity": "admin@example.com", "password": 'p"ss w0rd!'}
        self.reply(200 if ok else 400, b'{"token":"tok123"}' if ok else b"{}")
HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
STUB_PID=$!
for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break; sleep 0.1; done
touch "$W/compose.yml"

run() { PATH="$W/bin:$PATH" bash "$SCRIPT" upgrade --compose "$W/compose.yml" --service app --version-var APPV \
          --env-file "$W/app.env" --data /data --expect data.db --snapshots "$W/snaps" \
          --health-url "http://127.0.0.1:$PORT/health" --health-retries 2 --helper-image fake "$@" 2>"$W/stderr"; }
data() { cat "$FAKE_DOCKER/volumes/$(cat "$FAKE_DOCKER/mount")/data.db"; }

echo "== a healthy upgrade =="
reset 1.0
run --to 2.0 || fail "upgrade failed: $(cat "$W/stderr")"
[ "$(cat "$FAKE_DOCKER/version")" = 2.0 ] || fail "not running 2.0"
grep -qx 'APPV=2.0' "$W/app.env" && grep -qx 'OTHER=kept' "$W/app.env" || fail "env file: $(cat "$W/app.env")"
[ "$(ls "$W/snaps" | wc -l)" = 1 ] || fail "expected one snapshot"
tar tzf "$W/snaps"/*.tar.gz | grep -q 'data.db' || fail "the snapshot has no data.db"

echo "== started, migrated, unhealthy: the data is rolled back too =="
reset 2.0
before="$(data)"
run --to unhealthy && fail "an unhealthy version was kept"
[ "$(cat "$FAKE_DOCKER/version")" = 2.0 ] || fail "not back on 2.0"
grep -q "migrated by unhealthy" <<<"$(data)" && fail "the data the bad version migrated was kept: $(data)"
[ "$(data | head -c ${#before})" = "$before" ] || fail "the data was not restored: $(data)"
grep -qx 'APPV=2.0' "$W/app.env" || fail "the env file moved to the failed version"
grep -q "rolled back: 2.0 is healthy" "$W/stderr" || fail "no rollback reported: $(cat "$W/stderr")"

echo "== fails to start: rolled back =="
reset 2.0
run --to broken && fail "a version that would not start was kept"
[ "$(cat "$FAKE_DOCKER/version")" = 2.0 ] && [ "$(cat "$FAKE_DOCKER/running")" = 1 ] || fail "2.0 is not running again"

echo "== a snapshot without the expected file: no upgrade, service restarted =="
reset 2.0
rm "$FAKE_DOCKER/volumes/vol1/data.db"; echo other > "$FAKE_DOCKER/volumes/vol1/other.txt"
run --to 3.0 && fail "upgraded without a usable snapshot"
grep -q "has no data.db" "$W/stderr" || fail "not said: $(cat "$W/stderr")"
[ "$(cat "$FAKE_DOCKER/running")" = 1 ] && [ "$(cat "$FAKE_DOCKER/version")" = 2.0 ] || fail "the service was left stopped"
grep -q "up -d app" "$FAKE_DOCKER/calls" || fail "the service was not started again"

echo "== coming back on other storage: stopped loudly =="
reset 2.0
run --to moves && fail "accepted the service on different storage"
grep -q "moved during the upgrade" "$W/stderr" || fail "not said: $(cat "$W/stderr")"

echo "== --app pocketbase: login with a quoted password, never in argv =="
reset 2.0
printf 'PB_SUPERUSER_EMAIL=admin@example.com\nPB_SUPERUSER_PASSWORD=p"ss w0rd!\n' > "$W/creds"
: > "$W/curl.argv"
run --to 3.0 --app pocketbase --url "http://127.0.0.1:$PORT" --credentials-file "$W/creds" --health-collection notes --min-snapshot-bytes 1 \
  || fail "pocketbase health failed: $(cat "$W/stderr")"
grep -q 'w0rd' "$W/curl.argv" && fail "the password appeared in curl's arguments"
grep -q 'tok123' "$W/curl.argv" && fail "the auth token appeared in curl's arguments"
printf 'PB_SUPERUSER_EMAIL=admin@example.com\nPB_SUPERUSER_PASSWORD=wrong\n' > "$W/creds"
reset 2.0
run --to 3.0 --app pocketbase --url "http://127.0.0.1:$PORT" --credentials-file "$W/creds" --min-snapshot-bytes 1 \
  && fail "a failed login counted as healthy"

echo "== --keep prunes old snapshots =="
rm -rf "$W/snaps"; reset 1.0
for v in 2 3 4 5; do run --to "$v.0" --keep 2 || fail "upgrade to $v.0: $(cat "$W/stderr")"; sleep 1; done
[ "$(ls "$W/snaps" | wc -l)" = 2 ] || fail "--keep 2 left $(ls "$W/snaps" | wc -l)"

echo "== bad input =="
bad() { local want="$1" out; shift; out="$(PATH="$W/bin:$PATH" bash "$SCRIPT" upgrade "$@" 2>&1)" && fail "accepted: $*"; grep -q -- "$want" <<<"$out" || fail "$*: $out"; }
bad "--to is required"       --compose "$W/compose.yml" --service app --data /d --health-url http://x
bad "--health-url is required" --compose "$W/compose.yml" --service app --to 2 --data /d
bad "is not a version"       --compose "$W/compose.yml" --service app --to 'a b' --data /d --health-url http://x
bad "known applications"     --compose "$W/compose.yml" --service app --to 2 --app wordpress
bad "need --app"             --compose "$W/compose.yml" --service app --to 2 --data /d --health-url http://x --credentials-file "$W/creds"
reset 2.0; rm "$W/app.env"
bad "current version is unknown" --compose "$W/compose.yml" --service app --to 3 --data /d --health-url http://x

echo "PASS"

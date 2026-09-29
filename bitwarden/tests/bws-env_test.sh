#!/usr/bin/env bash
# bws-env_test.sh — run bws-env.sh against a fake bws and check what is
# expensive to get wrong: a value mangled on the way to a service, the wrong
# project winning, or a token leaking.
#
#   bitwarden/tests/bws-env_test.sh
#
# What it asserts:
#   1. awkward values (quotes, $, backticks, newlines, spaces) survive being
#      sourced exactly
#   2. precedence: --vars, then each --project in order, later wins; each key
#      once
#   3. --out writes mode 0600, and a failed run leaves the old file untouched
#   4. the token comes from a file or stdin, reaches bws in its environment and
#      never in its argv; a wrong one fails
#   5. BWS_* already in the caller's environment is not used
#   6. an unreadable project, an empty one, a bad key and bad input all fail
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../bws-env.sh"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# bws on PATH is the fake, under its real name.
mkdir -p "$W/bin" "$W/bws"
cp "$HERE/fake-bws" "$W/bin/bws"
export FAKE_BWS_DIR="$W/bws"
export PATH="$W/bin:$PATH"
printf 'machine-token-123\n' > "$W/bws/token"
cp "$W/bws/token" "$W/token"

# Written by python so the awkward values are exactly what the test says.
python3 - "$W/bws" <<'PY'
import json, sys
d = sys.argv[1]
shared = [
    {"key": "SHARED_ONLY", "value": "from-shared"},
    {"key": "OVERRIDDEN", "value": "shared-loses"},
    {"key": "QUOTES", "value": "it's \"quoted\""},
    {"key": "DOLLAR", "value": "$HOME `id` $(id)"},
    {"key": "MULTILINE", "value": "-----BEGIN KEY-----\nline two\n-----END KEY-----"},
    {"key": "SPACES", "value": "  padded  and   spaced  "},
]
env = [
    {"key": "OVERRIDDEN", "value": "env-wins"},
    {"key": "ENV_ONLY", "value": "from-env"},
    {"key": "FROM_VARS", "value": "project-beats-vars"},
]
json.dump(shared, open(f"{d}/shared.json", "w"))
json.dump(env, open(f"{d}/env.json", "w"))
json.dump([], open(f"{d}/empty.json", "w"))
json.dump([{"key": "OK", "value": "1"}, {"key": "BAD-NAME", "value": "x"},
           {"key": "1BAD", "value": "y"}], open(f"{d}/badkeys.json", "w"))
PY
cat > "$W/app.vars" <<'VARS'
# non-secret settings
FROM_VARS=vars-loses
VARS_ONLY=plain value with = sign

LOG_LEVEL=info
VARS

run() { bash "$SCRIPT" --access-token-file "$W/token" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
bad() { # expected-message args… — must fail
  local want="$1" out; shift
  out="$(bash "$SCRIPT" "$@" 2>&1 </dev/null)" && fail "accepted: $*"
  grep -q -- "$want" <<<"$out" || fail "$*: expected '$want', got: $out"
}

echo "== values survive being sourced, precedence holds =="
run --vars "$W/app.vars" --project shared --project env > "$W/out.env"
python3 - "$W/out.env" <<'PY' || fail "sourced values differ from Bitwarden's"
import subprocess, sys
got = subprocess.run(["bash", "-c", 'set -a; . "$1"; env -0', "_", sys.argv[1]],
                     capture_output=True, check=True).stdout.decode()
env = dict(kv.split("=", 1) for kv in got.split("\0") if "=" in kv)
want = {
    "SHARED_ONLY": "from-shared", "OVERRIDDEN": "env-wins", "ENV_ONLY": "from-env",
    "QUOTES": "it's \"quoted\"", "DOLLAR": "$HOME `id` $(id)",
    "MULTILINE": "-----BEGIN KEY-----\nline two\n-----END KEY-----",
    "SPACES": "  padded  and   spaced  ",
    "FROM_VARS": "project-beats-vars", "VARS_ONLY": "plain value with = sign",
    "LOG_LEVEL": "info",
}
for k, v in want.items():
    assert env.get(k) == v, (k, env.get(k), v)
PY
[ "$(grep -c '^OVERRIDDEN=' "$W/out.env")" = "1" ] || fail "a key appears more than once"

echo "== --out is 0600, and a failed run leaves the old file =="
run --project shared --out "$W/prod.env" 2>/dev/null
[ "$(stat -c %a "$W/prod.env")" = "600" ] || fail "--out mode is $(stat -c %a "$W/prod.env"), not 600"
cp "$W/prod.env" "$W/prod.before"
run --project shared --project no-such-project --out "$W/prod.env" 2>/dev/null && fail "unreadable project succeeded"
cmp -s "$W/prod.env" "$W/prod.before" || fail "a failed run changed the existing --out file"
[ -z "$(find "$W" -maxdepth 1 -name '.bws-env.*')" ] || fail "a failed run left a temp file behind"

echo "== the token: file or stdin, in bws's environment, never its argv =="
: > "$W/bws/argv.log"
out="$(printf 'machine-token-123' | bash "$SCRIPT" --access-token-file - --project env)" \
  || fail "--access-token-file - (stdin) did not work"
grep -q '^ENV_ONLY=' <<<"$out" || fail "stdin run printed nothing useful"
grep -q 'machine-token' "$W/bws/argv.log" && fail "the token was passed to bws as an argument"
printf 'wrong\n' > "$W/wrong"
bad "could not read project" --access-token-file "$W/wrong" --project env

echo "== BWS_* in the caller's environment is ignored =="
: > "$W/bws/server.log"
BWS_ACCESS_TOKEN=wrong BWS_SERVER_URL=https://evil.example run --project env >/dev/null \
  || fail "an exported BWS_ACCESS_TOKEN overrode --access-token-file"
[ -z "$(tr -d '\n' < "$W/bws/server.log")" ] || fail "an exported BWS_SERVER_URL reached bws"
run --project env --server-url https://vault.example >/dev/null
grep -qx 'https://vault.example' "$W/bws/server.log" || fail "--server-url did not reach bws"

echo "== bad projects, keys and input fail =="
bad "returned no secrets"            --access-token-file "$W/token" --project empty
bad "not valid variable names"       --access-token-file "$W/token" --project badkeys
bad "BAD-NAME"                       --access-token-file "$W/token" --project badkeys
bad "--project is required"          --access-token-file "$W/token"
bad "--access-token-file is required" --project env
bad "cannot read"                    --access-token-file /nonexistent --project env
: > "$W/empty-token"
bad "is empty"                       --access-token-file "$W/empty-token" --project env
bad "unknown argument '--bogus'"     --access-token-file "$W/token" --project env --bogus
printf 'GOOD=1\nthis line has no equals\n' > "$W/broken.vars"
bad "must be KEY=value"              --access-token-file "$W/token" --project env --vars "$W/broken.vars"
PATH="/usr/bin:/bin" bad "bws not installed" --access-token-file "$W/token" --project env

echo "PASS"

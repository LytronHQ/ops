#!/usr/bin/env bash
# cf-access_test.sh — run cf-access.sh against a stub Cloudflare API and check
# the things that are expensive to get wrong in production.
#
#   cloudflare/tests/cf-access_test.sh
#
# What it asserts:
#   1. a first run creates the app, ONE non_identity policy and the tokens, and
#      prints every secret
#   2. a re-run creates nothing and prints no secret it cannot know
#   3. a run managing only some tokens keeps the others in the policy — and
#      drops a token that no longer exists
#   4. rotation is scoped to the tokens named
#   5. a run that dies after minting still prints what it minted
#   6. an extra policy on the application is refused
#   7. bad input is refused before any API call
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../cf-access.sh"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"; [ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null || true' EXIT

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 "$HERE/cf_api_stub.py" "$PORT" "$STATE" &
STUB_PID=$!
for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 && break
  sleep 0.1
done

run() { # extra env assignments as args; stdout only
  env CF_API_BASE="http://127.0.0.1:${PORT}" CF_API_TOKEN=stub CF_ACCOUNT_ID=acct \
    ACCESS_HOSTNAME=api.test.local "$@" bash "$SCRIPT" 2>/dev/null
}

count() { python3 -c "import json;print(len(json.load(open('$STATE/$1.json'))))"; }
token_id() { python3 -c "
import json
print([t['id'] for t in json.load(open('$STATE/tokens.json')).values() if t['name']=='$1'][0])"; }
policy_ids() { python3 -c "
import json
p = list(json.load(open('$STATE/policies.json')).values())[0]
print(' '.join(sorted(i['service_token']['token_id'] for i in p['include'])))"; }

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "== the default is one token named after the application =="
out="$(run)"
grep -q '^CF_ACCESS_CLIENT_ID_API_TEST_LOCAL_CLIENT=' <<<"$out"     || fail "no client id for the default token: $out"
grep -q '^CF_ACCESS_CLIENT_SECRET_API_TEST_LOCAL_CLIENT=' <<<"$out" || fail "no secret for the default token"
[ "$(count apps)" = "1" ] && [ "$(count policies)" = "1" ] || fail "expected one app and one policy"

echo "== a first run with named tokens prints every secret =="
out="$(run ACCESS_TOKENS="ci backup")"
for n in CI BACKUP; do
  grep -q "^CF_ACCESS_CLIENT_ID_${n}=" <<<"$out"     || fail "no client id for $n"
  grep -q "^CF_ACCESS_CLIENT_SECRET_${n}=" <<<"$out" || fail "no secret for $n"
done
[ "$(count tokens)" = "3" ] || fail "expected 3 tokens, got $(count tokens)"

echo "== the policy: one, non_identity, every token =="
python3 - "$STATE" <<'PY' || fail "policy shape is wrong"
import json, sys
ps = list(json.load(open(sys.argv[1] + '/policies.json')).values())
assert len(ps) == 1, ps
p = ps[0]
assert p['decision'] == 'non_identity', p['decision']
ids = [i['service_token']['token_id'] for i in p['include']]
assert len(ids) == 3 and len(set(ids)) == 3, ids
PY

echo "== a re-run creates nothing and prints no secret =="
out="$(run ACCESS_TOKENS="ci backup")"
[ "$(count tokens)" = "3" ] && [ "$(count apps)" = "1" ] && [ "$(count policies)" = "1" ] \
  || fail "a re-run created something"
grep -q '^CF_ACCESS_CLIENT_SECRET_' <<<"$out" && fail "a re-run printed a secret it cannot know"
grep -q '^CF_ACCESS_CLIENT_ID_CI=' <<<"$out" || fail "a re-run must still print client ids"

echo "== a run managing one token keeps the others in the policy =="
before="$(policy_ids)"
run ACCESS_TOKENS="ci" >/dev/null
[ "$(policy_ids)" = "$before" ] || fail "a partial run changed the policy: [$before] -> [$(policy_ids)]"

echo "== ...but drops a token that no longer exists =="
gone="$(token_id backup)"
python3 - "$STATE" "$gone" <<'PY'
import json, sys
path = sys.argv[1] + '/tokens.json'
tokens = json.load(open(path)); del tokens[sys.argv[2]]; json.dump(tokens, open(path, 'w'))
PY
run ACCESS_TOKENS="ci" >/dev/null
grep -qw "$gone" <<<"$(policy_ids)" && fail "a deleted token is still in the policy"
[ "$(wc -w <<<"$(policy_ids)")" = "2" ] || fail "expected 2 tokens left, have: $(policy_ids)"

echo "== rotation is scoped =="
out="$(run ACCESS_TOKENS="ci api.test.local-client" ACCESS_ROTATE="ci")"
grep -q '^CF_ACCESS_CLIENT_SECRET_CI=' <<<"$out" || fail "ACCESS_ROTATE=ci did not mint a secret for ci"
grep -q '^CF_ACCESS_CLIENT_SECRET_API_TEST_LOCAL_CLIENT=' <<<"$out" && fail "rotating ci rotated the other token too"

echo "== a run that dies after minting still prints the secret =="
set +e
out="$(run ACCESS_TOKENS="fresh then-fail")"; rc=$?
set -e
[ "$rc" != "0" ] || fail "a failed mint did not fail the run"
grep -q '^CF_ACCESS_CLIENT_SECRET_FRESH=' <<<"$out" || fail "the secret minted before the failure was lost"
python3 -c "
import json
assert all(t['name'] != 'then-fail' for t in json.load(open('$STATE/tokens.json')).values())" \
  || fail "the stub created the failing token"

echo "== bad input is refused before any API call =="
# Captured first: piped straight into grep, pipefail would report the script's
# (correct) non-zero exit as a failed match.
out="$(env CF_API_BASE="http://127.0.0.1:1" CF_API_TOKEN=x CF_ACCOUNT_ID=x ACCESS_HOSTNAME=x \
  ACCESS_TOKENS="a" ACCESS_ROTATE="b" bash "$SCRIPT" 2>&1)" && fail "rotating an unmanaged token succeeded"
grep -q "not in ACCESS_TOKENS" <<<"$out" || fail "rotating an unmanaged token: unexpected error: $out"

echo "== an extra policy is refused =="
python3 - "$STATE" <<'PY'
import json, sys
path = sys.argv[1] + '/policies.json'
ps = json.load(open(path))
app = list(ps.values())[0]['app']
ps['rogue'] = {'id': 'rogue', 'app': app, 'name': 'a-second-door', 'decision': 'allow', 'include': []}
json.dump(ps, open(path, 'w'))
PY
if run ACCESS_TOKENS="ci" >/dev/null 2>&1; then
  fail "accepted an application with a second policy"
fi

echo "PASS"

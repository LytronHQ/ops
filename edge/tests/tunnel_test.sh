#!/usr/bin/env bash
# tunnel_test.sh — run edge.sh tunnel against a stub of the Cloudflare API and check
# what it creates, what it refuses, and what it prints.
#
#   tunnel/tests/tunnel_test.sh
#
# What it asserts:
#   1. a first run creates a remotely managed tunnel, an ingress to the origin
#      with the catch-all 404, a PROXIED CNAME, and prints only the token
#   2. a re-run creates nothing new; a changed origin updates the ingress
#   3. a deleted tunnel with the same name is not reused
#   4. a DNS record that is not this tunnel's stops the run BEFORE anything is
#      created; --replace-dns replaces every record at the name
#   5. the zone is found from the hostname, apex included
#   6. the API token is sent, and never appears in curl's arguments
#   7. bad input fails
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../edge.sh"
S="$(mktemp -d)"
trap 'rm -rf "$S"; [ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null || true' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

printf 'api-token-xyz\n' > "$S/token"
printf '{"z1": {"id": "z1", "name": "example.com"}, "z2": {"id": "z2", "name": "eu.example.org"}}' > "$S/zones.json"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 "$HERE/cloudflare_tunnel_stub.py" "$PORT" "$S" api-token-xyz &
STUB_PID=$!
for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 0.1; done

# curl through a shim that records its arguments, to prove the token is not one.
mkdir -p "$S/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/curl.argv"\nexec %s "$@"\n' "$S" "$(command -v curl)" > "$S/bin/curl"
chmod +x "$S/bin/curl"

run() { PATH="$S/bin:$PATH" bash "$SCRIPT" tunnel --api-base "http://127.0.0.1:$PORT" --account-id acct \
          --api-token-file "$S/token" "$@" 2>"$S/stderr"; }
j() { python3 -c "import json,sys; d=json.load(open('$S/$1.json')); $2"; }

echo "== a first run =="
out="$(run --hostname app.example.com --origin http://app:8080)"
[ "$(wc -l <<<"$out")" = 1 ] && [[ "$out" == TUNNEL_TOKEN=connector-token-* ]] || fail "stdout should be only the token: $out"
tid="${out#TUNNEL_TOKEN=connector-token-}"
j tunnels "t=d['$tid']; assert t['name']=='app.example.com' and t['config_src']=='cloudflare', t" || fail "tunnel"
j configs "i=d['$tid']['config']['ingress']; assert i==[{'hostname':'app.example.com','service':'http://app:8080'},{'service':'http_status:404'}], i" \
  || fail "ingress"
j dns "r=[x for x in d.values() if x['name']=='app.example.com']; assert len(r)==1 and r[0]['type']=='CNAME' and r[0]['content']=='$tid.cfargotunnel.com' and r[0]['proxied'] is True and r[0]['zone']=='z1', r" \
  || fail "DNS should be one proxied CNAME to the tunnel"
grep -q api-token-xyz "$S/curl.argv" && fail "the API token appeared in curl's arguments"

echo "== a re-run creates nothing; a new origin updates the ingress =="
out2="$(run --hostname app.example.com --origin http://app:9090)"
[ "$out2" = "$out" ] || fail "a re-run gave a different tunnel: $out2"
j tunnels "assert len(d)==1, d" || fail "a re-run created another tunnel"
j dns "assert len(d)==1, d" || fail "a re-run created another record"
j configs "assert d['$tid']['config']['ingress'][0]['service']=='http://app:9090'" || fail "the origin was not updated"

echo "== a deleted tunnel of the same name is not reused =="
python3 - "$S" <<'PY'
import json, sys
p = sys.argv[1] + "/tunnels.json"; d = json.load(open(p))
d["old"] = {"id": "old", "name": "api.example.com", "deleted": True}; json.dump(d, open(p, "w"))
PY
out="$(run --hostname api.example.com --origin http://api:8000)"
[ "$out" != "TUNNEL_TOKEN=connector-token-old" ] || fail "reused a deleted tunnel"

echo "== someone else's DNS record stops the run before anything is created =="
python3 - "$S" <<'PY'
import json, sys
p = sys.argv[1] + "/dns.json"; d = json.load(open(p))
d["a1"] = {"id": "a1", "zone": "z1", "name": "www.example.com", "type": "A", "content": "203.0.113.7", "proxied": False}
d["a2"] = {"id": "a2", "zone": "z1", "name": "www.example.com", "type": "AAAA", "content": "2001:db8::7", "proxied": False}
json.dump(d, open(p, "w"))
PY
before="$(cat "$S/tunnels.json")"
run --hostname www.example.com --origin http://web:80 >/dev/null && fail "replaced an A record without --replace-dns"
grep -q "A 203.0.113.7; AAAA 2001:db8::7" "$S/stderr" || fail "the existing records were not named: $(cat "$S/stderr")"
[ "$(cat "$S/tunnels.json")" = "$before" ] || fail "a refused run created a tunnel"
j dns "assert 'a1' in d and 'a2' in d" || fail "a refused run changed DNS"
out="$(run --hostname www.example.com --origin http://web:80 --replace-dns)" || fail "--replace-dns failed: $(cat "$S/stderr")"
j dns "r=[x for x in d.values() if x['name']=='www.example.com']; assert len(r)==1 and r[0]['type']=='CNAME', r" \
  || fail "--replace-dns should leave exactly one CNAME"

echo "== the zone is found from the hostname =="
run --hostname deep.app.eu.example.org --origin http://x:1 >/dev/null || fail "zone discovery: $(cat "$S/stderr")"
j dns "assert any(x['name']=='deep.app.eu.example.org' and x['zone']=='z2' for x in d.values())" || fail "picked the wrong zone"
run --hostname example.com --origin http://apex:1 >/dev/null || fail "apex: $(cat "$S/stderr")"
run --hostname app.nowhere.net --origin http://x:1 >/dev/null && fail "found a zone that does not exist"
grep -q "no zone found for app.nowhere.net" "$S/stderr" || fail "missing zone: $(cat "$S/stderr")"

echo "== a wrong API token is refused =="
printf 'wrong' > "$S/wrong"
bash "$SCRIPT" tunnel --api-base "http://127.0.0.1:$PORT" --account-id acct --api-token-file "$S/wrong" \
  --hostname app.example.com --origin http://app:8080 >/dev/null 2>&1 && fail "a wrong token was accepted"

echo "== bad input =="
bad() { local want="$1" out; shift; out="$(bash "$SCRIPT" tunnel "$@" 2>&1 </dev/null)" && fail "accepted: $*"; grep -q -- "$want" <<<"$out" || fail "$*: $out"; }
base=(--account-id a --api-token-file "$S/token")
bad "--origin is required"            "${base[@]}" --hostname app.example.com
bad "is not a URL"                    "${base[@]}" --hostname app.example.com --origin app:8080
bad "is not a hostname"               "${base[@]}" --hostname 'not a host' --origin http://a:1
bad "--provider 'ngrok' is not implemented" "${base[@]}" --provider ngrok --hostname app.example.com --origin http://a:1
bad "cannot read"                     --account-id a --api-token-file /nonexistent --hostname app.example.com --origin http://a:1
bad "unknown argument"                "${base[@]}" --bogus

echo "PASS"

#!/usr/bin/env bash
#
# edge.sh — how traffic reaches a service from outside: a tunnel to it, and a
# gate in front of it that only lets machines with a service token through.
#
# platforms: linux
#
#   ./edge.sh tunnel --hostname app.example.com --origin http://app:8080 …
#   ./edge.sh access --hostname app.example.com --token ci …
#   ./edge.sh <action> --help        every option of that action
#
# Actions:
#   tunnel   make a private service reachable at a hostname without opening a
#            port, and print the connector token
#   access   put an Access application with one Service Auth policy and its
#            service tokens in front of a hostname, and print the tokens
#
# Providers: cloudflare (Cloudflare Tunnel, Cloudflare Access), the default.
#
# One file for both, so one fetch and one checksum cover the whole edge.
set -euo pipefail
shopt -s inherit_errexit

# ============================================================================
# edge.sh tunnel
# ============================================================================

help_tunnel() {
cat <<'HELP_END'
edge.sh tunnel — make a private service reachable at a hostname through a tunnel,
without opening a port: create, or find, the tunnel, point its ingress at the
service, publish the hostname, and print the connector token. Idempotent;
safe to re-run. With edge.sh access in front, only machines holding a service
token get through.


  ./edge.sh tunnel --hostname app.example.com --origin http://app:8080 \
    --account-id <id> --api-token-file ~/.config/cloudflare/token

  # then, wherever the connector runs:
  docker run cloudflare/cloudflared tunnel run --token "$TUNNEL_TOKEN"

Prints `TUNNEL_TOKEN=<token>` on stdout and nothing else; progress goes to
stderr. The token lets anyone run a connector for this tunnel: store it as a
secret, never in a log.

Providers: cloudflare (Cloudflare Tunnel). The API token needs Cloudflare
Tunnel Edit (account) and DNS Edit (zone).

Options — every input is one; nothing is read from the environment:
  --provider <name>        cloudflare (the default, and the only one so far)
  --hostname <host>        the public name, e.g. app.example.com (required)
  --origin <url>           where the connector sends traffic, e.g.
                           http://app:8080 (required). See "The origin" below
  --account-id <id>        Cloudflare account id (required)
  --api-token-file <path>  file holding the API token, or - for stdin
                           (required). A file, never a value: argv is
                           readable by every user through ps
  --zone <name>            the DNS zone (default: found from the hostname)
  --name <name>            the tunnel's name (default: the hostname)
  --replace-dns            replace a DNS record for the hostname that is not
                           already this tunnel's. Without it, such a record
                           stops the run before anything is created
  --api-base <url>         API base URL (default Cloudflare's; tests use a stub)
  -h, --help               this text

The origin. It is resolved where the connector runs, not here. When the
connector is a container beside the service, use the service's container
name (http://app:8080): Docker's DNS resolves it on their shared network.
The host's private address looks equivalent and is not — the traffic leaves
the container from the Docker bridge and meets the host firewall, which, if
it only allows the private subnet to that port, drops it: every request
times out while the service answers fine from the host itself.

Needs curl and jq (and bash 4.4+). Runs on a workstation or in CI.
HELP_END
}

action_tunnel() {

log() { echo "$*" >&2; }
die() { echo "error: $*" >&2; exit 1; }
usage() { help_tunnel; }

PROVIDER="cloudflare" HOSTNAME_="" ORIGIN="" ACCOUNT_ID="" TOKEN_FILE="" ZONE="" NAME=""
REPLACE_DNS=0 API="https://api.cloudflare.com/client/v4"
while [ $# -gt 0 ]; do
  case "$1" in --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;; esac
  case "$1" in
    --provider|--hostname|--origin|--account-id|--api-token-file|--zone|--name|--api-base)
      [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value (try --help)" ;;
  esac
  case "$1" in
    --provider)       PROVIDER="$2"; shift 2 ;;
    --hostname)       HOSTNAME_="${2%.}"; shift 2 ;;
    --origin)         ORIGIN="$2"; shift 2 ;;
    --account-id)     ACCOUNT_ID="$2"; shift 2 ;;
    --api-token-file) TOKEN_FILE="$2"; shift 2 ;;
    --zone)           ZONE="${2%.}"; shift 2 ;;
    --name)           NAME="$2"; shift 2 ;;
    --replace-dns)    REPLACE_DNS=1; shift ;;
    --api-base)       API="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "unknown argument '$1' (try --help)" ;;
  esac
done
case "$PROVIDER" in
  cloudflare) ;;
  *) die "--provider '$PROVIDER' is not implemented. Implemented: cloudflare" ;;
esac
[ -n "$HOSTNAME_" ]  || die "--hostname is required (e.g. app.example.com)"
[[ "$HOSTNAME_" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$ ]] || die "--hostname '$HOSTNAME_' is not a hostname"
[ -n "$ORIGIN" ]     || die "--origin is required (e.g. http://app:8080)"
[[ "$ORIGIN" =~ ^(https?|tcp|ssh|rdp|unix)://. ]] || die "--origin '$ORIGIN' is not a URL (http://app:8080)"
[ -n "$ACCOUNT_ID" ] || die "--account-id is required"
[ -n "$TOKEN_FILE" ] || die "--api-token-file is required (a file, or - for stdin)"
NAME="${NAME:-$HOSTNAME_}"

if [ "$TOKEN_FILE" = "-" ]; then
  API_TOKEN="$(cat)"
else
  [ -r "$TOKEN_FILE" ] || die "--api-token-file: cannot read $TOKEN_FILE"
  API_TOKEN="$(cat "$TOKEN_FILE")"
fi
API_TOKEN="${API_TOKEN%%[[:space:]]}"
[ -n "$API_TOKEN" ] || die "--api-token-file: $TOKEN_FILE is empty"
command -v jq >/dev/null || die "missing jq"
command -v curl >/dev/null || die "missing curl"

# cf METHOD PATH [json] — fail loudly on API errors, which come back inside a
# 200 body as {"success": false, "errors": [...]}. The token reaches curl
# through a file descriptor, never its argv.
cf() {
  local method="$1" path="$2" body="${3:-}" out args=()
  [ -z "$body" ] || args=(-H 'Content-Type: application/json' -d "$body")
  out="$(curl -sS -X "$method" "$API$path" \
    -H @<(printf 'Authorization: Bearer %s\n' "$API_TOKEN") "${args[@]}")"
  jq -e '.success == true' >/dev/null <<<"$out" \
    || die "Cloudflare API $method $path: $(jq -c '.errors // .' <<<"$out" 2>/dev/null || echo "$out")"
  echo "$out"
}
uri() { jq -rn --arg s "$1" '$s | @uri'; }

# --- the zone ---------------------------------------------------------------------
# Not given: the longest suffix of the hostname that is a zone this token sees,
# so app.eu.example.com finds eu.example.com if that is delegated, else
# example.com.
if [ -n "$ZONE" ]; then
  ZONE_ID="$(cf GET "/zones?name=$(uri "$ZONE")" | jq -r '.result[0].id // empty')"
  [ -n "$ZONE_ID" ] || die "zone '$ZONE' not found (is the DNS Edit permission scoped to it?)"
else
  # The hostname itself first — a tunnel can sit on a zone's apex — then each
  # shorter suffix down to two labels.
  candidate="$HOSTNAME_" ZONE_ID=""
  while :; do
    ZONE_ID="$(cf GET "/zones?name=$(uri "$candidate")" | jq -r '.result[0].id // empty')"
    if [ -n "$ZONE_ID" ]; then ZONE="$candidate"; break; fi
    [[ "$candidate" == *.*.* ]] || break
    candidate="${candidate#*.}"
  done
  [ -n "$ZONE_ID" ] || die "no zone found for $HOSTNAME_ — pass --zone, or check the token's DNS Edit scope"
fi
log "· zone $ZONE"

# --- the tunnel, found by name ----------------------------------------------------
# is_deleted=false: a deleted tunnel keeps its name and would shadow the lookup.
TUNNEL_ID="$(cf GET "/accounts/${ACCOUNT_ID}/cfd_tunnel?name=$(uri "$NAME")&is_deleted=false" \
  | jq -r '.result[0].id // empty')"

# --- DNS, checked BEFORE anything is created --------------------------------------
# A record already at this name that is not this tunnel's CNAME is someone's —
# the original of this script replaced it silently, A records included. Refuse
# unless told, and refuse before creating a tunnel, so a refusal changes nothing.
RECORDS="$(cf GET "/zones/${ZONE_ID}/dns_records?name=$(uri "$HOSTNAME_")")"
mine() { # record-json -> true when it is the CNAME of THIS tunnel
  [ -n "$TUNNEL_ID" ] && jq -e --arg t "${TUNNEL_ID}.cfargotunnel.com" '.type == "CNAME" and .content == $t' >/dev/null <<<"$1"
}
FOREIGN="$(jq -c '.result[]' <<<"$RECORDS" | while read -r r; do mine "$r" || jq -r '"\(.type) \(.content)"' <<<"$r"; done)"
if [ -n "$FOREIGN" ] && [ "$REPLACE_DNS" != 1 ]; then
  die "$HOSTNAME_ already has DNS records that are not this tunnel's: $(tr '\n' ';' <<<"$FOREIGN" | sed 's/;$//; s/;/; /g'). Nothing was changed. Pass --replace-dns to replace them."
fi

if [ -n "$TUNNEL_ID" ]; then
  log "· tunnel $NAME exists ($TUNNEL_ID)"
else
  log "==> creating tunnel $NAME"
  # config_src=cloudflare: remotely managed, so the ingress lives in the API and
  # the connector needs nothing but the token.
  TUNNEL_ID="$(cf POST "/accounts/${ACCOUNT_ID}/cfd_tunnel" \
    "$(jq -nc --arg n "$NAME" '{name: $n, config_src: "cloudflare"}')" | jq -r '.result.id')"
  log "   created ($TUNNEL_ID)"
fi

# --- ingress ------------------------------------------------------------------------
# The catch-all 404 is required: a configuration without one is rejected.
log "==> ingress: $HOSTNAME_ -> $ORIGIN"
cf PUT "/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
  "$(jq -nc --arg h "$HOSTNAME_" --arg o "$ORIGIN" '{config: {ingress: [{hostname: $h, service: $o}, {service: "http_status:404"}]}}')" >/dev/null

# --- DNS ----------------------------------------------------------------------------
# Proxied, always: an unproxied record would publish the tunnel's address and
# skip everything Cloudflare puts in front of it, Access included.
TARGET="${TUNNEL_ID}.cfargotunnel.com"
BODY="$(jq -nc --arg n "$HOSTNAME_" --arg c "$TARGET" '{type: "CNAME", name: $n, content: $c, proxied: true, comment: "edge.sh tunnel"}')"
OURS=""
while read -r r; do
  [ -n "$r" ] || continue
  id="$(jq -r .id <<<"$r")"
  if jq -e --arg t "$TARGET" '.type == "CNAME" and .content == $t' >/dev/null <<<"$r"; then
    OURS="$id"
  else
    # Only reached with --replace-dns. A CNAME cannot sit beside other records
    # of the same name, so every one of them goes, not just the first.
    log "==> removing $(jq -r '"\(.type) \(.content)"' <<<"$r") at $HOSTNAME_ (--replace-dns)"
    cf DELETE "/zones/${ZONE_ID}/dns_records/${id}" >/dev/null
  fi
done < <(jq -c '.result[]' <<<"$RECORDS")
if [ -n "$OURS" ]; then
  log "· DNS $HOSTNAME_ -> $TARGET (made proxied if it was not)"
  cf PUT "/zones/${ZONE_ID}/dns_records/${OURS}" "$BODY" >/dev/null
else
  log "==> creating DNS $HOSTNAME_ -> $TARGET"
  cf POST "/zones/${ZONE_ID}/dns_records" "$BODY" >/dev/null
fi

TOKEN="$(cf GET "/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token" | jq -r '.result // empty')"
[ -n "$TOKEN" ] || die "the tunnel exists but no connector token was returned"
log "==> done. The tunnel is DOWN until a connector runs with this token."
echo "TUNNEL_TOKEN=${TOKEN}"
}

# ============================================================================
# edge.sh access
# ============================================================================

help_access() {
cat <<'HELP_END'
edge.sh access — gate a hostname so only machines holding a service token get
through. Idempotent; safe to re-run. Replaces the dashboard walkthrough.


Providers: cloudflare (Cloudflare Access) — creates, or finds, the Access
application, ONE Service Auth policy, and the service tokens it admits.
The capability is the name; the vendor is a --provider, the way the OS is
for server.sh harden. Another provider is another branch here, not another script.

  ./edge.sh access --hostname api.example.com --account-id <id> \
    --api-token-file ~/.config/cloudflare/token --token ci --token backup

  # in CI, the secret on stdin:
  printf '%s' "$CF_API_TOKEN" | ./edge.sh access --api-token-file - …

cloudflare: the API token needs Access: Apps and Policies Write + Access: Service Tokens
Edit (both account-level).

Prints, on stdout, for each --token:
  CF_ACCESS_CLIENT_ID_<NAME>=…
  CF_ACCESS_CLIENT_SECRET_<NAME>=…   ONLY when this run created or rotated it
<NAME> is the token name upper-cased, anything not A-Z0-9 turned into _.
Cloudflare returns a secret exactly once, at creation, so a re-run cannot
reprint it: store what you see. Everything else goes to stderr.

Options — every input is one; nothing is read from the environment:
  --provider <name>        who provides the gate: cloudflare (the default,
                           and the only one so far)
  --hostname <host>        the hostname to protect (required)
  --account-id <id>        cloudflare: account id (required)
  --api-token-file <path>  file holding the API token, or - for stdin
                           (required). A file, never a value: argv is
                           readable by every user through ps.
  --token <name>           a service token this run manages, created if
                           missing; repeatable (default "<app name>-client")
  --rotate <name>          rotate one of the --token names: a new secret, and
                           the old one stops working immediately; repeatable
  --app-name <name>        application name (default: the hostname)
  --policy-name <name>     policy name (default "service-tokens")
  --session <duration>     application session duration (default "24h")
  --api-base <url>         API base URL (default Cloudflare's; tests use a stub)
  -h, --help               this text

Tokens already in the policy but not named in this run are KEPT, as long as
they still exist. So each consumer can manage its own token from wherever its
secret needs to end up, and one run cannot lock another consumer out.

Needs curl and jq (and bash 4.4+). Runs on a workstation or in CI, not on a
target host.
HELP_END
}

action_access() {
# Without this, set -e does not apply INSIDE $(…): a failed API call in the
# middle of ensure_token let it carry on and return success, and the run went
# on with an empty token id. Found by the test that makes a mint fail.
shopt -s inherit_errexit

log() { echo "$*" >&2; }
die() { echo "error: $*" >&2; exit 1; }
usage() { help_access; }

PROVIDER="cloudflare" HOSTNAME_="" ACCOUNT_ID="" TOKEN_FILE="" APP_NAME="" POLICY_NAME="service-tokens"
SESSION="24h" API="https://api.cloudflare.com/client/v4" TOKENS=() ROTATE=()
while [ $# -gt 0 ]; do
  case "$1" in --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;; esac
  case "$1" in
    --provider|--hostname|--account-id|--api-token-file|--token|--rotate|--app-name|--policy-name|--session|--api-base)
      [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value (try --help)" ;;
  esac
  case "$1" in
    --provider)       PROVIDER="$2"; shift 2 ;;
    --hostname)       HOSTNAME_="$2"; shift 2 ;;
    --account-id)     ACCOUNT_ID="$2"; shift 2 ;;
    --api-token-file) TOKEN_FILE="$2"; shift 2 ;;
    --token)          TOKENS+=("$2"); shift 2 ;;
    --rotate)         ROTATE+=("$2"); shift 2 ;;
    --app-name)       APP_NAME="$2"; shift 2 ;;
    --policy-name)    POLICY_NAME="$2"; shift 2 ;;
    --session)        SESSION="$2"; shift 2 ;;
    --api-base)       API="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "unknown argument '$1' (try --help)" ;;
  esac
done
case "$PROVIDER" in
  cloudflare) ;;
  *) die "--provider '$PROVIDER' is not implemented. Implemented: cloudflare" ;;
esac
[ -n "$HOSTNAME_" ]  || die "--hostname is required (e.g. api.example.com)"
[ -n "$ACCOUNT_ID" ] || die "--account-id is required"
[ -n "$TOKEN_FILE" ] || die "--api-token-file is required (a file, or - for stdin)"
APP_NAME="${APP_NAME:-$HOSTNAME_}"
# Default derives from the application, so two applications never share a
# token by accident. They used to, where this came from: a secret is retrievable
# only at creation, so the second application found the first one's token,
# reused it, stored a client id with no secret, and could not authenticate —
# while rotating it to fix one silently broke the other.
[ "${#TOKENS[@]}" -gt 0 ] || TOKENS=("${APP_NAME}-client")
for r in "${ROTATE[@]}"; do
  case " ${TOKENS[*]} " in *" $r "*) ;; *) die "--rotate '$r' is not one of the --token names" ;; esac
done

if [ "$TOKEN_FILE" = "-" ]; then
  API_TOKEN="$(cat)"
else
  [ -r "$TOKEN_FILE" ] || die "--api-token-file: cannot read $TOKEN_FILE"
  API_TOKEN="$(cat "$TOKEN_FILE")"
fi
API_TOKEN="${API_TOKEN%%[[:space:]]}"
[ -n "$API_TOKEN" ] || die "--api-token-file: $TOKEN_FILE is empty"

command -v jq >/dev/null || die "missing jq"
command -v curl >/dev/null || die "missing curl"

cf() {
  local method="$1" path="$2" body="${3:-}" out args=()
  [ -z "$body" ] || args=(-H 'Content-Type: application/json' -d "$body")
  # The token goes to curl through a file descriptor (-H @file), not as an
  # argument: `-H "Authorization: Bearer …"` put it in curl's argv, readable by
  # every user through ps for as long as each request ran.
  out="$(curl -sS -X "$method" "$API$path" \
    -H @<(printf 'Authorization: Bearer %s\n' "$API_TOKEN") "${args[@]}")"
  jq -e '.success == true' >/dev/null <<<"$out" \
    || die "Cloudflare API $method $path: $(jq -c '.errors // .' <<<"$out" 2>/dev/null || echo "$out")"
  echo "$out"
}

var_name() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_'; }

# A minted secret exists exactly once, in this process. Every Cloudflare call
# after the mint can fail, so a first run that died later used to leave a token
# whose secret was gone for good: every re-run took the reuse branch and could
# never recover it. One failed run permanently burned the token.
#
# So whatever has been minted is printed on ANY exit path. A later failure costs
# a re-run rather than a credential; the caller stores what it sees, then honours
# the exit status.
#
# To the stdout the script STARTED with, saved here as fd 3 — not to whatever
# stdout is current when it dies. The policy update is `cf … >/dev/null`; a
# `die` inside it runs this trap with that redirection still in force, and the
# secret went into /dev/null while the log said it was being printed (#85).
OUTPUT="" MINTED=0 EMITTED=0
exec 3>&1
on_exit() {
  local rc=$?
  if [ "$EMITTED" = "0" ] && [ "$MINTED" = "1" ]; then
    log "!! exiting with status $rc AFTER minting a service-token secret."
    log "!! printing it anyway — it cannot be retrieved again."
    printf '%s' "$OUTPUT" >&3
  fi
}
trap on_exit EXIT

# --- service tokens ----------------------------------------------------------
ALL_TOKENS="$(cf GET "/accounts/${ACCOUNT_ID}/access/service_tokens")"

# ensure_token NAME ROTATE -> "<token_id> <client_id> <client_secret>"; the
# secret is empty when an existing token was reused.
ensure_token() {
  local name="$1" rotate="$2" id cid csec="" res
  id="$(jq -r --arg n "$name" '.result[] | select(.name==$n) | .id' <<<"$ALL_TOKENS" | head -1)"
  if [ -z "$id" ]; then
    log "==> creating service token $name"
    res="$(cf POST "/accounts/${ACCOUNT_ID}/access/service_tokens" \
      "$(jq -nc --arg n "$name" '{name:$n, duration:"forever"}')")"
    id="$(jq -r '.result.id' <<<"$res")"
    cid="$(jq -r '.result.client_id' <<<"$res")"
    csec="$(jq -r '.result.client_secret' <<<"$res")"
  elif [ "$rotate" = "1" ]; then
    log "==> rotating service token $name (the old secret stops working NOW)"
    res="$(cf POST "/accounts/${ACCOUNT_ID}/access/service_tokens/${id}/rotate")"
    cid="$(jq -r '.result.client_id' <<<"$res")"
    csec="$(jq -r '.result.client_secret' <<<"$res")"
  else
    log "· service token $name exists — secret not retrievable (rotate it to mint a new one)"
    cid="$(jq -r --arg n "$name" '.result[] | select(.name==$n) | .client_id' <<<"$ALL_TOKENS" | head -1)"
  fi
  echo "$id $cid $csec"
}

MANAGED_IDS=()
for name in "${TOKENS[@]}"; do
  rotate=0
  case " ${ROTATE[*]} " in *" $name "*) rotate=1 ;; esac
  # Assigned, not `read <<<"$(…)"`: set -e ignores a failed command substitution
  # inside a here-string, so a failed mint used to carry on with an empty id.
  res="$(ensure_token "$name" "$rotate")"
  read -r id cid csec <<<"$res"
  MANAGED_IDS+=("$id")
  v="$(var_name "$name")"
  OUTPUT+="CF_ACCESS_CLIENT_ID_${v}=${cid}"$'\n'
  if [ -n "$csec" ]; then
    OUTPUT+="CF_ACCESS_CLIENT_SECRET_${v}=${csec}"$'\n'
    MINTED=1
  fi
done

# --- application --------------------------------------------------------------
APPS="$(cf GET "/accounts/${ACCOUNT_ID}/access/apps")"
APP_ID="$(jq -r --arg d "$HOSTNAME_" '.result[] | select(.domain==$d) | .id' <<<"$APPS" | head -1)"
if [ -z "$APP_ID" ]; then
  log "==> creating Access application for $HOSTNAME_"
  body="$(jq -nc --arg n "$APP_NAME" --arg d "$HOSTNAME_" --arg s "$SESSION" \
    '{name:$n, domain:$d, type:"self_hosted", session_duration:$s}')"
  res="$(cf POST "/accounts/${ACCOUNT_ID}/access/apps" "$body")"
  APP_ID="$(jq -r '.result.id' <<<"$res")"
else
  log "· Access application for $HOSTNAME_ exists ($APP_ID)"
fi

# --- policy -------------------------------------------------------------------
# decision=non_identity is what makes a service-token rule actually gate: an
# "allow" policy would also admit browser identity flows, which is a second door.
POLICIES="$(cf GET "/accounts/${ACCOUNT_ID}/access/apps/${APP_ID}/policies")"
POLICY_ID="$(jq -r --arg n "$POLICY_NAME" '.result[] | select(.name==$n) | .id' <<<"$POLICIES" | head -1)"
# A reusable policy is listed under the application but can only be changed at
# the account level: Cloudflare refuses the app endpoint for it with error
# 12130 (#85). A legacy, app-scoped policy is still updated where it lives.
POLICY_REUSABLE="$(jq -r --arg n "$POLICY_NAME" \
  '[.result[] | select(.name==$n)][0].reusable // false' <<<"$POLICIES")"

# Every token in ONE policy: include entries are ORed, so this admits any of
# them and nothing else, and revoking one leaves the rest working. The tokens
# this run manages, plus any already in the policy that still exist — rewriting
# the policy from this run's list alone would lock out every consumer that
# manages its token elsewhere, silently and from somewhere unrelated.
KEPT="$(jq -r --arg n "$POLICY_NAME" \
  '.result[] | select(.name==$n) | .include[]? | .service_token.token_id // empty' <<<"$POLICIES")"
EXISTING="$(jq -r '.result[].id' <<<"$ALL_TOKENS")"
ids="$(printf '%s\n' "${MANAGED_IDS[@]}"
       for k in $KEPT; do grep -qxF "$k" <<<"$EXISTING" && echo "$k"; done)"
ids="$(awk 'NF && !seen[$0]++' <<<"$ids")"
for k in $KEPT; do
  grep -qxF "$k" <<<"$ids" && ! printf '%s\n' "${MANAGED_IDS[@]}" | grep -qxF "$k" \
    && log "· keeping token $k already in the policy"
done

pbody="$(jq -nc --arg n "$POLICY_NAME" --arg ids "$ids" \
  '{name:$n, decision:"non_identity",
    include:[$ids | split("\n")[] | select(. != "") | {service_token:{token_id:.}}]}')"
if [ -z "$POLICY_ID" ]; then
  log "==> creating Service Auth policy $POLICY_NAME"
  cf POST "/accounts/${ACCOUNT_ID}/access/apps/${APP_ID}/policies" "$pbody" >/dev/null
else
  if [ "$POLICY_REUSABLE" = "true" ]; then
    log "==> updating Service Auth policy $POLICY_NAME (reusable)"
    cf PUT "/accounts/${ACCOUNT_ID}/access/policies/${POLICY_ID}" "$pbody" >/dev/null
  else
    log "==> updating Service Auth policy $POLICY_NAME"
    cf PUT "/accounts/${ACCOUNT_ID}/access/apps/${APP_ID}/policies/${POLICY_ID}" "$pbody" >/dev/null
  fi
fi

# Any other policy on this application is a way in that bypasses the tokens.
# Refuse to leave one in place silently.
OTHERS="$(jq -r --arg n "$POLICY_NAME" '[.result[] | select(.name != $n) | .name] | join(", ")' <<<"$POLICIES")"
[ -z "$OTHERS" ] || die "extra policies on this application: ${OTHERS}. Access ORs policies, so each one is another way past the service tokens. Remove them and re-run."

log "==> done."
EMITTED=1
printf '%s' "$OUTPUT"
}

# ============================================================================

subject_usage() { sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }
case "${1:-}" in
  tunnel) shift; action_tunnel "$@" ;;
  access) shift; action_access "$@" ;;
  -h|--help|help) subject_usage ;;
  "") subject_usage >&2; exit 1 ;;
  *) echo "edge.sh: unknown action '$1'. Actions: tunnel, access" >&2; exit 1 ;;
esac

#!/usr/bin/env bash
#
# access.sh — gate a hostname so only machines holding a service token get
# through. Idempotent; safe to re-run. Replaces the dashboard walkthrough.
#
# Providers: cloudflare (Cloudflare Access) — creates, or finds, the Access
# application, ONE Service Auth policy, and the service tokens it admits.
# The capability is the name; the vendor is a --provider, the way the OS is
# for harden.sh. Another provider is another branch here, not another script.
#
#   ./access.sh --hostname api.example.com --account-id <id> \
#     --api-token-file ~/.config/cloudflare/token --token ci --token backup
#
#   # in CI, the secret on stdin:
#   printf '%s' "$CF_API_TOKEN" | ./access.sh --api-token-file - …
#
# cloudflare: the API token needs Access: Apps and Policies Write + Access: Service Tokens
# Edit (both account-level).
#
# Prints, on stdout, for each --token:
#   CF_ACCESS_CLIENT_ID_<NAME>=…
#   CF_ACCESS_CLIENT_SECRET_<NAME>=…   ONLY when this run created or rotated it
# <NAME> is the token name upper-cased, anything not A-Z0-9 turned into _.
# Cloudflare returns a secret exactly once, at creation, so a re-run cannot
# reprint it: store what you see. Everything else goes to stderr.
#
# Options — every input is one; nothing is read from the environment:
#   --provider <name>        who provides the gate: cloudflare (the default,
#                            and the only one so far)
#   --hostname <host>        the hostname to protect (required)
#   --account-id <id>        cloudflare: account id (required)
#   --api-token-file <path>  file holding the API token, or - for stdin
#                            (required). A file, never a value: argv is
#                            readable by every user through ps.
#   --token <name>           a service token this run manages, created if
#                            missing; repeatable (default "<app name>-client")
#   --rotate <name>          rotate one of the --token names: a new secret, and
#                            the old one stops working immediately; repeatable
#   --app-name <name>        application name (default: the hostname)
#   --policy-name <name>     policy name (default "service-tokens")
#   --session <duration>     application session duration (default "24h")
#   --api-base <url>         API base URL (default Cloudflare's; tests use a stub)
#   -h, --help               this text
#
# Tokens already in the policy but not named in this run are KEPT, as long as
# they still exist. So each consumer can manage its own token from wherever its
# secret needs to end up, and one run cannot lock another consumer out.
#
# Needs curl and jq (and bash 4.4+). Runs on a workstation or in CI, not on a
# target host.
set -euo pipefail
# Without this, set -e does not apply INSIDE $(…): a failed API call in the
# middle of ensure_token let it carry on and return success, and the run went
# on with an empty token id. Found by the test that makes a mint fail.
shopt -s inherit_errexit

log() { echo "$*" >&2; }
die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

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
OUTPUT="" MINTED=0 EMITTED=0
on_exit() {
  local rc=$?
  if [ "$EMITTED" = "0" ] && [ "$MINTED" = "1" ]; then
    log "!! exiting with status $rc AFTER minting a service-token secret."
    log "!! printing it anyway — it cannot be retrieved again."
    printf '%s' "$OUTPUT"
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
  log "==> updating Service Auth policy $POLICY_NAME"
  cf PUT "/accounts/${ACCOUNT_ID}/access/apps/${APP_ID}/policies/${POLICY_ID}" "$pbody" >/dev/null
fi

# Any other policy on this application is a way in that bypasses the tokens.
# Refuse to leave one in place silently.
OTHERS="$(jq -r --arg n "$POLICY_NAME" '[.result[] | select(.name != $n) | .name] | join(", ")' <<<"$POLICIES")"
[ -z "$OTHERS" ] || die "extra policies on this application: ${OTHERS}. Access ORs policies, so each one is another way past the service tokens. Remove them and re-run."

log "==> done."
EMITTED=1
printf '%s' "$OUTPUT"

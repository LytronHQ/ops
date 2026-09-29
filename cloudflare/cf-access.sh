#!/usr/bin/env bash
#
# cf-access.sh — put a hostname behind Cloudflare Access for machines: create,
# or find, the Access application, ONE Service Auth policy, and the service
# tokens that policy admits. Idempotent; safe to re-run. Replaces the dashboard
# walkthrough.
#
#   CF_API_TOKEN=… CF_ACCOUNT_ID=… ACCESS_HOSTNAME=api.example.com \
#   ACCESS_TOKENS="ci backup" ./cf-access.sh
#
# Token permissions: Access: Apps and Policies Write + Access: Service Tokens
# Edit (both account-level).
#
# Prints, on stdout, for each token in ACCESS_TOKENS:
#   CF_ACCESS_CLIENT_ID_<NAME>=…
#   CF_ACCESS_CLIENT_SECRET_<NAME>=…   ONLY when this run created or rotated it
# <NAME> is the token name upper-cased, anything not A-Z0-9 turned into _.
# Cloudflare returns a secret exactly once, at creation, so a re-run cannot
# reprint it: store what you see. Everything else goes to stderr.
#
# Env:
#   CF_API_TOKEN, CF_ACCOUNT_ID, ACCESS_HOSTNAME   required
#   ACCESS_TOKENS        service token names this run manages, space separated;
#                        created if missing (default "<app name>-client")
#   ACCESS_ROTATE        which of them to rotate: a new secret, and the old one
#                        stops working immediately
#   ACCESS_APP_NAME      application name (default: the hostname)
#   ACCESS_POLICY_NAME   policy name (default "service-tokens")
#   ACCESS_SESSION       session duration (default "24h")
#   CF_API_BASE          API base URL, for tests (default Cloudflare's)
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

: "${CF_API_TOKEN:?set CF_API_TOKEN (Access Apps and Policies Write + Service Tokens Edit)}"
: "${CF_ACCOUNT_ID:?set CF_ACCOUNT_ID}"
: "${ACCESS_HOSTNAME:?set ACCESS_HOSTNAME (e.g. api.example.com)}"
APP_NAME="${ACCESS_APP_NAME:-$ACCESS_HOSTNAME}"
POLICY_NAME="${ACCESS_POLICY_NAME:-service-tokens}"
SESSION="${ACCESS_SESSION:-24h}"
# Default derives from the application, so two applications never share a
# token by accident. They used to, where this came from: a secret is retrievable
# only at creation, so the second application found the first one's token,
# reused it, stored a client id with no secret, and could not authenticate —
# while rotating it to fix one silently broke the other.
read -r -a TOKENS <<<"${ACCESS_TOKENS:-${APP_NAME}-client}"
read -r -a ROTATE <<<"${ACCESS_ROTATE:-}"

# Overridable so tests/cf-access_test.sh can point it at a stub API and run
# the real script rather than a copy of its logic.
API="${CF_API_BASE:-https://api.cloudflare.com/client/v4}"
log() { echo "$*" >&2; }
die() { echo "error: $*" >&2; exit 1; }
command -v jq >/dev/null || die "missing jq"
command -v curl >/dev/null || die "missing curl"

[ "${#TOKENS[@]}" -gt 0 ] || die "ACCESS_TOKENS is empty"
for r in "${ROTATE[@]}"; do
  case " ${TOKENS[*]} " in *" $r "*) ;; *) die "ACCESS_ROTATE names '$r', which is not in ACCESS_TOKENS" ;; esac
done

cf() {
  local method="$1" path="$2" body="${3:-}" out
  if [ -n "$body" ]; then
    out="$(curl -sS -X "$method" "$API$path" -H "Authorization: Bearer $CF_API_TOKEN" \
      -H 'Content-Type: application/json' -d "$body")"
  else
    out="$(curl -sS -X "$method" "$API$path" -H "Authorization: Bearer $CF_API_TOKEN")"
  fi
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
ALL_TOKENS="$(cf GET "/accounts/${CF_ACCOUNT_ID}/access/service_tokens")"

# ensure_token NAME ROTATE -> "<token_id> <client_id> <client_secret>"; the
# secret is empty when an existing token was reused.
ensure_token() {
  local name="$1" rotate="$2" id cid csec="" res
  id="$(jq -r --arg n "$name" '.result[] | select(.name==$n) | .id' <<<"$ALL_TOKENS" | head -1)"
  if [ -z "$id" ]; then
    log "==> creating service token $name"
    res="$(cf POST "/accounts/${CF_ACCOUNT_ID}/access/service_tokens" \
      "$(jq -nc --arg n "$name" '{name:$n, duration:"forever"}')")"
    id="$(jq -r '.result.id' <<<"$res")"
    cid="$(jq -r '.result.client_id' <<<"$res")"
    csec="$(jq -r '.result.client_secret' <<<"$res")"
  elif [ "$rotate" = "1" ]; then
    log "==> rotating service token $name (the old secret stops working NOW)"
    res="$(cf POST "/accounts/${CF_ACCOUNT_ID}/access/service_tokens/${id}/rotate")"
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
APPS="$(cf GET "/accounts/${CF_ACCOUNT_ID}/access/apps")"
APP_ID="$(jq -r --arg d "$ACCESS_HOSTNAME" '.result[] | select(.domain==$d) | .id' <<<"$APPS" | head -1)"
if [ -z "$APP_ID" ]; then
  log "==> creating Access application for $ACCESS_HOSTNAME"
  body="$(jq -nc --arg n "$APP_NAME" --arg d "$ACCESS_HOSTNAME" --arg s "$SESSION" \
    '{name:$n, domain:$d, type:"self_hosted", session_duration:$s}')"
  res="$(cf POST "/accounts/${CF_ACCOUNT_ID}/access/apps" "$body")"
  APP_ID="$(jq -r '.result.id' <<<"$res")"
else
  log "· Access application for $ACCESS_HOSTNAME exists ($APP_ID)"
fi

# --- policy -------------------------------------------------------------------
# decision=non_identity is what makes a service-token rule actually gate: an
# "allow" policy would also admit browser identity flows, which is a second door.
POLICIES="$(cf GET "/accounts/${CF_ACCOUNT_ID}/access/apps/${APP_ID}/policies")"
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
  cf POST "/accounts/${CF_ACCOUNT_ID}/access/apps/${APP_ID}/policies" "$pbody" >/dev/null
else
  log "==> updating Service Auth policy $POLICY_NAME"
  cf PUT "/accounts/${CF_ACCOUNT_ID}/access/apps/${APP_ID}/policies/${POLICY_ID}" "$pbody" >/dev/null
fi

# Any other policy on this application is a way in that bypasses the tokens.
# Refuse to leave one in place silently.
OTHERS="$(jq -r --arg n "$POLICY_NAME" '[.result[] | select(.name != $n) | .name] | join(", ")' <<<"$POLICIES")"
[ -z "$OTHERS" ] || die "extra policies on this application: ${OTHERS}. Access ORs policies, so each one is another way past the service tokens. Remove them and re-run."

log "==> done."
EMITTED=1
printf '%s' "$OUTPUT"

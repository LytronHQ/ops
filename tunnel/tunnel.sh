#!/usr/bin/env bash
#
# tunnel.sh — make a private service reachable at a hostname through a tunnel,
# without opening a port: create, or find, the tunnel, point its ingress at the
# service, publish the hostname, and print the connector token. Idempotent;
# safe to re-run. With access.sh in front, only machines holding a service
# token get through.
#
# platforms: linux
#
#   ./tunnel.sh --hostname app.example.com --origin http://app:8080 \
#     --account-id <id> --api-token-file ~/.config/cloudflare/token
#
#   # then, wherever the connector runs:
#   docker run cloudflare/cloudflared tunnel run --token "$TUNNEL_TOKEN"
#
# Prints `TUNNEL_TOKEN=<token>` on stdout and nothing else; progress goes to
# stderr. The token lets anyone run a connector for this tunnel: store it as a
# secret, never in a log.
#
# Providers: cloudflare (Cloudflare Tunnel). The API token needs Cloudflare
# Tunnel Edit (account) and DNS Edit (zone).
#
# Options — every input is one; nothing is read from the environment:
#   --provider <name>        cloudflare (the default, and the only one so far)
#   --hostname <host>        the public name, e.g. app.example.com (required)
#   --origin <url>           where the connector sends traffic, e.g.
#                            http://app:8080 (required). See "The origin" below
#   --account-id <id>        Cloudflare account id (required)
#   --api-token-file <path>  file holding the API token, or - for stdin
#                            (required). A file, never a value: argv is
#                            readable by every user through ps
#   --zone <name>            the DNS zone (default: found from the hostname)
#   --name <name>            the tunnel's name (default: the hostname)
#   --replace-dns            replace a DNS record for the hostname that is not
#                            already this tunnel's. Without it, such a record
#                            stops the run before anything is created
#   --api-base <url>         API base URL (default Cloudflare's; tests use a stub)
#   -h, --help               this text
#
# The origin. It is resolved where the connector runs, not here. When the
# connector is a container beside the service, use the service's container
# name (http://app:8080): Docker's DNS resolves it on their shared network.
# The host's private address looks equivalent and is not — the traffic leaves
# the container from the Docker bridge and meets the host firewall, which, if
# it only allows the private subnet to that port, drops it: every request
# times out while the service answers fine from the host itself.
#
# Needs curl and jq (and bash 4.4+). Runs on a workstation or in CI.
set -euo pipefail
shopt -s inherit_errexit

log() { echo "$*" >&2; }
die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

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
BODY="$(jq -nc --arg n "$HOSTNAME_" --arg c "$TARGET" '{type: "CNAME", name: $n, content: $c, proxied: true, comment: "tunnel.sh"}')"
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

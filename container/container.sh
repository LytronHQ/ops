#!/usr/bin/env bash
#
# container.sh — looking after a containerised service on its host.
#
# platforms: linux
#
#   sudo ./container.sh upgrade --compose /opt/app/compose.yml --service app --to 2.4.0 …
#   ./container.sh <action> --help        every option of that action
#
# Actions:
#   upgrade   move a compose service to a new version: snapshot its data first,
#             and roll back the image and the data if it does not come back
#             healthy
set -euo pipefail
shopt -s inherit_errexit

# ============================================================================
# container.sh upgrade
# ============================================================================

help_upgrade() {
cat <<'HELP_END'
container.sh upgrade — upgrade a containerised service to a new version, with a
consistent snapshot of its data taken first and an automatic rollback — of
the image AND the data — if it does not come back healthy. Run on the host.


  ./container.sh upgrade --compose /opt/app/compose.yml --service app --to 2.4.0 \
    --version-var APP_VERSION --env-file /etc/app/app.env \
    --data /data --health-url http://127.0.0.1:8080/healthz

  ./container.sh upgrade --app pocketbase --compose /opt/pb/compose.yml --service pocketbase \
    --to 0.29.0 --env-file /etc/pb/pb.env --credentials-file /etc/pb/pb.env --build

Why stop first: a database writing as it is copied — SQLite with a WAL, most
of all — does not give a copy you can roll back to. A short, deliberate
outage is the price of a snapshot that is actually consistent. And why the
data rolls back too: an application that migrates its data on start leaves
it unreadable to the old version, so putting the old image back alone does
not undo an upgrade.

The local snapshot is the rollback source; rollback never depends on a
download. --after-snapshot can ship a copy elsewhere, in the background,
without ever holding the upgrade up.

The compose file must take the version from a variable — image: app:${APP_VERSION}
or a build argument — which this sets for the new version and, on success,
writes into --env-file.

Options — every input is one; nothing is read from the environment:
  --compose <file>         the compose file (required)
  --service <name>         the service to upgrade (required)
  --to <version>           the version to upgrade to (required)
  --version-var <name>     the variable the compose file reads the version
                           from (default VERSION; pocketbase: PB_VERSION)
  --env-file <file>        KEY=VALUE file handed to compose; the current
                           version is read from it and the new one written to
                           it. Read as data, never run
  --from <version>         the current version, when no env file says
  --data <path>            the data directory INSIDE the container to
                           snapshot (required; pocketbase: /pb_data)
  --health-url <url>       must answer 2xx for the service to count as up
                           (required; pocketbase: <url>/api/health)
  --health-retries <n>     tries, 2s apart (default 30)
  --expect <name>          a file the snapshot must contain, or the upgrade
                           stops before starting (pocketbase: data.db)
  --min-snapshot-bytes <n> a smaller snapshot stops the upgrade (default 1;
                           pocketbase: 65536)
  --snapshots <dir>        where snapshots go (default /var/backups/<service>)
  --keep <n>               snapshots kept after a successful upgrade (3)
  --build                  rebuild the image (compose up --build)
  --after-snapshot <cmd>   run as `<cmd> <snapshot>` in the background, best
                           effort — an offsite copy, say
  --helper-image <image>   small image used to read and write the volume
                           (default alpine:3.20)
  --app <name>             defaults for a known application: pocketbase
  --url <url>              pocketbase: its base URL (default http://127.0.0.1:8090)
  --credentials-file <f>   pocketbase: PB_SUPERUSER_EMAIL / _PASSWORD lines;
                           the health check then also logs in, which proves
                           the database is readable, not just the port open
  --health-collection <c>  pocketbase: also read a record of this collection
  -h, --help               this text
HELP_END
}

action_upgrade() {

ts()  { date -u +%FT%TZ; }
log() { echo "[upgrade $(ts)] $*" >&2; }
die() { echo "[upgrade $(ts)] ERROR: $*" >&2; exit 1; }
usage() { help_upgrade; }

COMPOSE="" SERVICE="" TARGET="" VVAR="" ENV_FILE="" CURRENT="" DATA="" HEALTH_URL="" RETRIES=30
EXPECT="" MIN_BYTES="" SNAP_DIR="" KEEP=3 BUILD=0 AFTER="" HELPER="alpine:3.20" APP="" URL="" CREDS="" COLLECTION=""
while [ $# -gt 0 ]; do
  case "$1" in --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;; esac
  case "$1" in
    --build|-h|--help) ;;
    --*) [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value (try --help)" ;;
  esac
  case "$1" in
    --compose)            COMPOSE="$2"; shift 2 ;;
    --service)            SERVICE="$2"; shift 2 ;;
    --to)                 TARGET="$2"; shift 2 ;;
    --version-var)        VVAR="$2"; shift 2 ;;
    --env-file)           ENV_FILE="$2"; shift 2 ;;
    --from)               CURRENT="$2"; shift 2 ;;
    --data)               DATA="$2"; shift 2 ;;
    --health-url)         HEALTH_URL="$2"; shift 2 ;;
    --health-retries)     RETRIES="$2"; shift 2 ;;
    --expect)             EXPECT="$2"; shift 2 ;;
    --min-snapshot-bytes) MIN_BYTES="$2"; shift 2 ;;
    --snapshots)          SNAP_DIR="$2"; shift 2 ;;
    --keep)               KEEP="$2"; shift 2 ;;
    --build)              BUILD=1; shift ;;
    --after-snapshot)     AFTER="$2"; shift 2 ;;
    --helper-image)       HELPER="$2"; shift 2 ;;
    --app)                APP="$2"; shift 2 ;;
    --url)                URL="$2"; shift 2 ;;
    --credentials-file)   CREDS="$2"; shift 2 ;;
    --health-collection)  COLLECTION="$2"; shift 2 ;;
    -h|--help)            usage; exit 0 ;;
    *)                    die "unknown argument '$1' (try --help)" ;;
  esac
done

# --- application defaults -----------------------------------------------------------
case "$APP" in
  "") [ -z "$CREDS$COLLECTION$URL" ] || die "--url, --credentials-file and --health-collection need --app" ;;
  pocketbase)
    # PocketBase: an embedded SQLite under /pb_data that it migrates when a newer
    # binary starts — the case this script exists for.
    VVAR="${VVAR:-PB_VERSION}"; DATA="${DATA:-/pb_data}"; EXPECT="${EXPECT:-data.db}"
    MIN_BYTES="${MIN_BYTES:-65536}"; URL="${URL:-http://127.0.0.1:8090}"
    HEALTH_URL="${HEALTH_URL:-${URL%/}/api/health}"
    TARGET="${TARGET#v}"; CURRENT="${CURRENT#v}" ;;
  *) die "--app '$APP': known applications are pocketbase" ;;
esac
VVAR="${VVAR:-VERSION}"; MIN_BYTES="${MIN_BYTES:-1}"

[ -n "$COMPOSE" ] || die "--compose is required"
[ -f "$COMPOSE" ] || die "--compose: no such file $COMPOSE"
[ -n "$SERVICE" ] || die "--service is required"
[ -n "$TARGET" ]  || die "--to is required: the version to upgrade to"
[ -n "$DATA" ]    || die "--data is required: the data directory inside the container"
[ -n "$HEALTH_URL" ] || die "--health-url is required: how to tell the new version is up"
[[ "$VVAR" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "--version-var '$VVAR' is not a variable name"
[[ "$TARGET" =~ ^[A-Za-z0-9._+-]+$ ]] || die "--to '$TARGET' is not a version"
for n in RETRIES KEEP MIN_BYTES; do [[ "${!n}" =~ ^[0-9]+$ ]] || die "--${n,,} must be a number"; done
[ -z "$ENV_FILE" ] || [ -f "$ENV_FILE" ] || die "--env-file: no such file $ENV_FILE"
[ -z "$CREDS" ] || [ -r "$CREDS" ] || die "--credentials-file: cannot read $CREDS"
SNAP_DIR="${SNAP_DIR:-/var/backups/$SERVICE}"
command -v docker >/dev/null 2>&1 || die "docker not found"
command -v curl >/dev/null 2>&1 || die "curl not found"

# KEY=VALUE lines, as data. The script this came from `source`d its env file,
# which runs whatever the file contains.
read_env() { # file key
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$2=//p" "$1" | tail -1 | sed "s/^[\"']//; s/[\"']$//"
}
ENVVARS=()
if [ -n "$ENV_FILE" ]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    v="${BASH_REMATCH[3]}"; v="${v#[\"\']}"; v="${v%[\"\']}"
    ENVVARS+=("${BASH_REMATCH[2]}=$v")
  done < "$ENV_FILE"
  [ -n "$CURRENT" ] || CURRENT="$(read_env "$ENV_FILE" "$VVAR")"
  [ "$APP" != pocketbase ] || CURRENT="${CURRENT#v}"
fi
[ -n "$CURRENT" ] || die "the current version is unknown: no $VVAR in --env-file, and no --from. It is the rollback target."

log "$SERVICE: current=$CURRENT target=$TARGET"
[ "$CURRENT" != "$TARGET" ] || { log "already on $TARGET — nothing to do"; exit 0; }

# compose, with the env file's variables and the given version.
compose() { # version args…
  local v="$1"; shift
  env "${ENVVARS[@]}" "$VVAR=$v" docker compose -f "$COMPOSE" "$@"
}
up() { # version
  if [ "$BUILD" = 1 ]; then compose "$1" up -d --build "$SERVICE"; else compose "$1" up -d "$SERVICE"; fi
}

# --- health ----------------------------------------------------------------------
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}
health_ok() {
  curl -fsS --max-time 5 -o /dev/null "$HEALTH_URL" 2>/dev/null || return 1
  [ "$APP" = pocketbase ] && [ -n "$CREDS" ] || return 0
  # A login reads the database, so it proves PocketBase migrated and can query,
  # not only that the port is open. The password goes to curl on stdin, never
  # its arguments, and is JSON-escaped: printf-built JSON broke on a quote.
  local email pw token
  email="$(read_env "$CREDS" PB_SUPERUSER_EMAIL)"; pw="$(read_env "$CREDS" PB_SUPERUSER_PASSWORD)"
  [ -n "$email" ] && [ -n "$pw" ] || { log "no PB_SUPERUSER_EMAIL/PASSWORD in $CREDS"; return 1; }
  token="$(printf '{"identity":%s,"password":%s}' "$(json_str "$email")" "$(json_str "$pw")" |
    curl -fsS --max-time 5 "${URL%/}/api/collections/_superusers/auth-with-password" \
      -H 'Content-Type: application/json' --data-binary @- 2>/dev/null |
    sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
  [ -n "$token" ] || return 1
  [ -n "$COLLECTION" ] || return 0
  curl -fsS --max-time 5 -o /dev/null "${URL%/}/api/collections/${COLLECTION}/records?perPage=1&skipTotal=true" \
    -H @<(printf 'Authorization: %s\n' "$token") 2>/dev/null
}
wait_healthy() {
  local i
  for i in $(seq 1 "$RETRIES"); do health_ok && return 0; sleep 2; done
  return 1
}

# --- storage ------------------------------------------------------------------------
# What backs the data directory, read from the RUNNING container before it is
# stopped: a named volume's name, or a bind mount's host path. Reading only the
# name would miss a bind mount and snapshot a stale — or new and EMPTY —
# volume, with every later step reporting success.
mount_source() {
  local id; id="$(compose "$CURRENT" ps -q "$SERVICE" 2>/dev/null | head -1)"
  [ -n "$id" ] || return 0
  docker inspect -f "{{ range .Mounts }}{{ if eq .Destination \"$DATA\" }}{{ if .Name }}{{ .Name }}{{ else }}{{ .Source }}{{ end }}{{ end }}{{ end }}" "$id" 2>/dev/null || true
}
VOL="$(mount_source)"
[ -n "$VOL" ] || die "cannot tell what backs $DATA in the running $SERVICE container — is it running, and is --data right? Nothing was changed."
log "$DATA is backed by: $VOL"
# After every start, the container must be on the SAME storage. A missing
# variable in the compose project (a bind path, say) silently falls back to a
# default volume, and the service starts on an EMPTY data directory that passes
# its health check — the data intact, and invisible.
assert_same_storage() { # context
  local now; now="$(mount_source)"
  [ "$now" = "$VOL" ] || die "$DATA moved during $1: was '$VOL', now '$now'. $SERVICE is running on the WRONG storage — usually a variable the compose file needs is missing. The data is intact at '$VOL'; stop this container before it takes writes."
}

mkdir -p "$SNAP_DIR"
SNAP="$SNAP_DIR/$SERVICE-$(date -u +%Y%m%dT%H%M%SZ)-$CURRENT.tar.gz"
in_helper() { # mode command — run in the helper image with the data at /data and snapshots at /backup
  docker run --rm -v "$VOL:/data$1" -v "$SNAP_DIR:/backup" "$HELPER" sh -c "$2"
}
# The script stopped the service; any way out before the upgrade starts it
# again on the version it was on, rather than leaving it down.
restart_current() {
  log "starting $SERVICE again on $CURRENT"
  up "$CURRENT" >/dev/null 2>&1 || log "could not start $SERVICE on $CURRENT — start it by hand"
}

# --- 1. stop, for a consistent snapshot ------------------------------------------
log "stopping $SERVICE for a consistent snapshot"
compose "$CURRENT" stop "$SERVICE" >/dev/null

# --- 2. snapshot --------------------------------------------------------------------
log "snapshotting $DATA -> $SNAP"
if ! in_helper :ro "tar czf /backup/$(basename "$SNAP") -C /data ." >/dev/null; then
  restart_current; die "the snapshot failed; nothing was upgraded."
fi
# tar succeeds on an empty directory, so success is not evidence. Listed into a
# variable, not piped to grep -q: grep exits at the match, tar takes SIGPIPE,
# and pipefail fails a perfectly good snapshot whenever the file is not last.
SNAP_BYTES="$(stat -c %s "$SNAP" 2>/dev/null || echo 0)"
if [ -n "$EXPECT" ]; then
  listing="$(tar tzf "$SNAP" 2>/dev/null || true)"
  if ! grep -qE "(^|/)${EXPECT//./\\.}$" <<<"$listing"; then
    rm -f "$SNAP"; restart_current
    die "the snapshot has no $EXPECT ('$VOL' looks wrong or empty); nothing was upgraded."
  fi
fi
if [ "$SNAP_BYTES" -lt "$MIN_BYTES" ]; then
  rm -f "$SNAP"; restart_current
  die "the snapshot is implausibly small (${SNAP_BYTES}B from '$VOL', minimum $MIN_BYTES); nothing was upgraded."
fi
log "snapshot done ($(du -h "$SNAP" | cut -f1))"

if [ -n "$AFTER" ]; then
  log "after-snapshot, in the background: $AFTER $SNAP"
  ( sh -c "$AFTER \"\$1\"" _ "$SNAP" >/dev/null 2>&1 && log "after-snapshot done" \
      || log "after-snapshot failed (the local snapshot is intact)" ) &
fi

rollback() {
  log "ROLLBACK to $CURRENT: restoring the previous image and the snapshot"
  compose "$TARGET" stop "$SERVICE" >/dev/null 2>&1 || true
  in_helper "" "find /data -mindepth 1 -delete && tar xzf /backup/$(basename "$SNAP") -C /data" >/dev/null \
    || die "RESTORE FAILED. The snapshot is $SNAP; restore it by hand before starting $SERVICE."
  up "$CURRENT" >/dev/null || die "ROLLBACK could not start $CURRENT. Data restored from $SNAP."
  assert_same_storage "the rollback"
  wait_healthy || die "ROLLBACK started $CURRENT but it is not healthy. Data restored from $SNAP. MANUAL INTERVENTION NEEDED."
  log "rolled back: $CURRENT is healthy"
}

# --- 3. start the new version ---------------------------------------------------------
log "starting $SERVICE $TARGET"
if ! up "$TARGET" >/dev/null; then
  log "starting $TARGET failed"; rollback; exit 1
fi
assert_same_storage "the upgrade to $TARGET"

# --- 4. healthy? ---------------------------------------------------------------------
if ! wait_healthy; then
  log "$TARGET did not become healthy"; rollback; exit 1
fi
log "$TARGET is healthy"

# --- 5. remember the new version --------------------------------------------------------
if [ -n "$ENV_FILE" ]; then
  if grep -qE "^[[:space:]]*(export[[:space:]]+)?$VVAR=" "$ENV_FILE"; then
    sed -i -E "s|^([[:space:]]*(export[[:space:]]+)?$VVAR=).*|\1$TARGET|" "$ENV_FILE"
  else
    echo "$VVAR=$TARGET" >> "$ENV_FILE"
  fi
  log "$VVAR=$TARGET written to $ENV_FILE"
fi

# --- 6. keep the last N snapshots ---------------------------------------------------------
find "$SNAP_DIR" -maxdepth 1 -name "$SERVICE-*.tar.gz" -printf '%T@ %p\n' | sort -rn | tail -n +$((KEEP + 1)) |
  cut -d' ' -f2- | while IFS= read -r old; do rm -f -- "$old"; done
log "upgraded $SERVICE: $CURRENT -> $TARGET (kept the last $KEEP snapshot(s) in $SNAP_DIR)"
}

# ============================================================================

subject_usage() { sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }
case "${1:-}" in
  upgrade) shift; action_upgrade "$@" ;;
  -h|--help|help) subject_usage ;;
  "") subject_usage >&2; exit 1 ;;
  *) echo "container.sh: unknown action '$1'. Actions: upgrade" >&2; exit 1 ;;
esac

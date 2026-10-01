#!/usr/bin/env bash
#
# db.sh — looking after a database, unattended: from a timer or cron.
#
# platforms: linux
#
#   ./db.sh maintain --db /var/lib/app/app.db
#   ./db.sh <action> --help        every option of that action
#
# Actions:
#   maintain   SQLite: fold the WAL back, reclaim a bounded number of free
#              pages, have the application take a backup, ping a heartbeat
set -euo pipefail
shopt -s inherit_errexit

# ============================================================================
# db.sh maintain
# ============================================================================

help_maintain() {
cat <<'HELP_END'
db.sh maintain — routine maintenance of a database, run unattended (a systemd
timer, cron). For SQLite: fold the WAL back, reclaim a bounded number of free
pages, optionally have the application take a backup, and ping a heartbeat
only when all of it worked.


  ./db.sh maintain --db /var/lib/app/app.db
  ./db.sh maintain --container pocketbase --db /pb_data/data.db \
    --app pocketbase --credentials-file /etc/pb/pb.env \
    --heartbeat-url-file /etc/pb/heartbeat.url

maintain, in this order — and the order is load-bearing:
  1. PRAGMA wal_checkpoint(TRUNCATE): fold the WAL into the main file and
     reset it, so a backup does not depend on WAL state and the WAL cannot
     grow without bound. Blocked by a reader mid-transaction, it says so and
     the next run catches up.
  2. PRAGMA incremental_vacuum(N): reclaim at most N free pages, so every run
     is short. After the checkpoint, or the pages are still in the WAL.
     Skipped, and said so, unless the database is in INCREMENTAL auto-vacuum
     mode: converting needs a full VACUUM, which rewrites the whole file under
     an exclusive lock — a maintenance-window job, never a timer's.
  3. With --app pocketbase: a backup through PocketBase's own API, so it is
     consistent and restores the normal way. After the vacuum, or the archive
     carries the dead pages.
  4. With --heartbeat-url-file: a ping, only when everything above worked. A
     silent failure looks like no failure on a host nobody watches; the monitor
     alerts on the ping's absence instead.

Deliberately absent: a recurring full VACUUM, and backup retention — the
backup destination's own lifecycle prunes it, and two policies on one bucket
is how backups get deleted early.

Options — every input is one; nothing is read from the environment:
  --engine <name>            sqlite (the default, and the only one so far)
  --db <path>                the database file (required); inside the
                             container with --container
  --container <name>         run sqlite3 inside this running container
  --vacuum-pages <n>         most free pages reclaimed per run (default 20000,
                             about 80 MiB of 4 KiB pages)
  --busy-ms <ms>             wait this long for a write lock before giving up
                             (default 15000)
  --app <name>               the application, for its backup: pocketbase
  --url <url>                pocketbase: base URL (default http://127.0.0.1:8090)
  --credentials-file <file>  pocketbase: PB_SUPERUSER_EMAIL / _PASSWORD lines
  --backup-prefix <name>     pocketbase: backup name prefix (default backup)
  --no-backup                skip the backup
  --heartbeat-url-file <f>   file holding the heartbeat URL. A file, not a
                             value: anyone holding the URL can fake the ping
  -h, --help                 this text

Needs bash, curl, and sqlite3 on the host or in the container.
HELP_END
}

action_maintain() {

log() { echo "[database $(date -u +%FT%TZ)] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }
usage() { help_maintain; }


ENGINE="sqlite" DB="" CONTAINER="" PAGES=20000 BUSY=15000 APP="" URL="" CREDS="" PREFIX="backup" BACKUP=1 HB=""
while [ $# -gt 0 ]; do
  case "$1" in --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;; esac
  case "$1" in
    --no-backup|-h|--help) ;;
    --*) [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value (try --help)" ;;
  esac
  case "$1" in
    --engine)             ENGINE="$2"; shift 2 ;;
    --db)                 DB="$2"; shift 2 ;;
    --container)          CONTAINER="$2"; shift 2 ;;
    --vacuum-pages)       PAGES="$2"; shift 2 ;;
    --busy-ms)            BUSY="$2"; shift 2 ;;
    --app)                APP="$2"; shift 2 ;;
    --url)                URL="$2"; shift 2 ;;
    --credentials-file)   CREDS="$2"; shift 2 ;;
    --backup-prefix)      PREFIX="$2"; shift 2 ;;
    --no-backup)          BACKUP=0; shift ;;
    --heartbeat-url-file) HB="$2"; shift 2 ;;
    -h|--help)            usage; exit 0 ;;
    *)                    die "unknown argument '$1' (try --help)" ;;
  esac
done
case "$ENGINE" in sqlite) ;; *) die "--engine '$ENGINE' is not implemented. Implemented: sqlite" ;; esac
case "$APP" in "") [ -z "$CREDS$URL" ] || die "--url and --credentials-file need --app" ;;
  pocketbase) URL="${URL:-http://127.0.0.1:8090}" ;;
  *) die "--app '$APP': known applications are pocketbase" ;; esac
[ -n "$DB" ] || die "--db is required"
[[ "$PAGES" =~ ^[0-9]+$ ]] || die "--vacuum-pages must be a number"
[[ "$BUSY" =~ ^[0-9]+$ ]] || die "--busy-ms must be a number"
[[ "$PREFIX" =~ ^[A-Za-z0-9._-]+$ ]] || die "--backup-prefix '$PREFIX': letters, digits, . _ -"
if [ "$APP" = pocketbase ] && [ "$BACKUP" = 1 ]; then
  [ -n "$CREDS" ] || die "--app pocketbase backs up through its API, which needs --credentials-file (or --no-backup)"
  [ -r "$CREDS" ] || die "--credentials-file: cannot read $CREDS"
fi
if [ -n "$HB" ]; then [ -r "$HB" ] || die "--heartbeat-url-file: cannot read $HB"; fi

if [ -n "$CONTAINER" ]; then
  command -v docker >/dev/null 2>&1 || die "docker not found"
  [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" = true ] || die "container '$CONTAINER' is not running"
  sql() { docker exec "$CONTAINER" sqlite3 -cmd ".timeout $BUSY" "$DB" "$1"; }
else
  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 not found (or pass --container)"
  [ -f "$DB" ] || die "--db: no such file $DB"
  sql() { sqlite3 -cmd ".timeout $BUSY" "$DB" "$1"; }
fi

# --- 1. checkpoint -------------------------------------------------------------------
# "busy|log|checkpointed": a non-zero busy means a reader kept the WAL from
# being reset. Not fatal — the next run gets it — but a WAL that never
# truncates is worth seeing.
log "checkpoint: folding the WAL into $DB"
ck="$(sql 'PRAGMA wal_checkpoint(TRUNCATE);')" || die "the checkpoint failed"
log "  wal_checkpoint(TRUNCATE) -> ${ck:-<no result>} (busy|log|checkpointed)"
case "$ck" in 0\|*) ;; *) log "  WARN: the checkpoint was blocked; the WAL was not reset this run" ;; esac

# --- 2. bounded incremental vacuum ---------------------------------------------------
mode="$(sql 'PRAGMA auto_vacuum;')" || die "could not read auto_vacuum"
if [ "$mode" = 2 ]; then
  before="$(sql 'PRAGMA freelist_count;')"
  log "vacuum: reclaiming up to $PAGES page(s) of $before free"
  sql "PRAGMA incremental_vacuum($PAGES);" >/dev/null || die "incremental_vacuum failed"
  log "  free pages now $(sql 'PRAGMA freelist_count;')"
else
  # 0 is none, 1 is full: incremental_vacuum silently does nothing in either.
  log "vacuum: SKIPPED — auto_vacuum is ${mode:-unknown}, not INCREMENTAL (2). Converting needs a"
  log "  full VACUUM, which rewrites the file under an exclusive lock: a maintenance-window job."
fi

# --- 3. backup -------------------------------------------------------------------------
read_env() { sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$2=//p" "$1" | tail -1 | sed "s/^[\"']//; s/[\"']$//"; }
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}
if [ "$APP" = pocketbase ] && [ "$BACKUP" = 1 ]; then
  command -v curl >/dev/null 2>&1 || die "curl not found"
  email="$(read_env "$CREDS" PB_SUPERUSER_EMAIL)"; pw="$(read_env "$CREDS" PB_SUPERUSER_PASSWORD)"
  [ -n "$email" ] && [ -n "$pw" ] || die "no PB_SUPERUSER_EMAIL / PB_SUPERUSER_PASSWORD in $CREDS"
  # The password on stdin and JSON-escaped; the token through a file descriptor.
  # printf-built JSON on the command line broke on a quote and showed in ps.
  token="$(printf '{"identity":%s,"password":%s}' "$(json_str "$email")" "$(json_str "$pw")" |
    curl -fsS --max-time 30 "${URL%/}/api/collections/_superusers/auth-with-password" \
      -H 'Content-Type: application/json' --data-binary @- 2>/dev/null |
    sed -n 's/.*"token":"\([^"]*\)".*/\1/p')" || true
  [ -n "$token" ] || die "superuser login to ${URL%/} failed; no backup was taken"
  name="$PREFIX-$(date -u +%Y%m%d-%H%M%S).zip"
  log "backup: requesting $name"
  out="$(mktemp)"; trap 'rm -f "$out"' EXIT
  code="$(curl -sS --max-time 600 -o "$out" -w '%{http_code}' -X POST "${URL%/}/api/backups" \
    -H @<(printf 'Authorization: %s\n' "$token") -H 'Content-Type: application/json' \
    --data-binary "{\"name\":\"$name\"}" || echo 000)"
  case "$code" in
    200|204) log "  backup created (and uploaded, when PocketBase's S3 backups are set up)" ;;
    *) die "the backup request returned HTTP $code: $(head -c 300 "$out")" ;;
  esac
fi

# --- 4. heartbeat ------------------------------------------------------------------------
if [ -n "$HB" ]; then
  if curl -fsS --max-time 10 -o /dev/null -K <(printf 'url = "%s"\n' "$(head -1 "$HB")") 2>/dev/null; then
    log "heartbeat sent"
  else
    log "WARN: the heartbeat ping failed"
  fi
fi
log "maintenance complete"
}

# ============================================================================

subject_usage() { sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }
case "${1:-}" in
  maintain) shift; action_maintain "$@" ;;
  -h|--help|help) subject_usage ;;
  "") subject_usage >&2; exit 1 ;;
  *) echo "db.sh: unknown action '$1'. Actions: maintain" >&2; exit 1 ;;
esac

#!/usr/bin/env bash
#
# server.sh — preparing and looking after a Linux machine: harden it, clean it
# up, take stock of what is installed on it.
#
# platforms: linux
#
#   sudo ./server.sh harden --allow 10.0.0.0/16:5432
#   ./server.sh cleanup                 # a report; --apply to clean
#   ./server.sh inventory --wide
#   ./server.sh <action> --help         every option of that action
#
# Actions:
#   harden     firewall, automatic security updates, fail2ban, key-only SSH —
#              without locking out whoever runs it
#   cleanup    reclaim disk space from caches, old temp files, the journal, old
#              logs, dumps; reports first
#   inventory  what is installed, and which package manager put it there
#
# Windows has server.ps1, with cleanup and inventory.
set -euo pipefail
shopt -s inherit_errexit

# ============================================================================
# server.sh harden
# ============================================================================

help_harden() {
cat <<'HELP_END'
server.sh harden — bring a fresh Linux host to a sane baseline. Idempotent; safe to
run again to re-apply.


  sudo ./server.sh harden [options]
  sudo ./server.sh harden --allow 10.0.0.0/16:5432 --allow 203.0.113.4:8090/udp

Options — every input is one; nothing else is read from the environment
except who ran sudo:
  --allow <source>:<port>[/tcp|udp]
                    keep this port open to this source. Repeatable, or
                    comma separated. Everything else inbound is denied.
  --skip <step>     leave a step alone: firewall, updates, fail2ban or ssh.
                    Repeatable, or comma separated.
  --login-user <u>  whose key must exist before password SSH is turned off
                    (default: the user who ran sudo, else root)
  --ssh-tag <name>  names the sshd drop-in and fail2ban jail file it writes
                    (default: hardening)
  -h, --help        this text

SELF-CONTAINED ON PURPOSE. It knows nothing about the project deploying it, so
it can be copied into an unrelated one as-is. Everything project-specific is
one of the options above.

What it does: a firewall denying inbound except SSH, unattended security
updates, fail2ban, and key-only SSH.

LOCKOUT SAFETY, which is the part worth copying. Every way this script used to
be able to cut off the person running it was found by running it, not by
reading it, and each now has a check:
  * the firewall allows the port sshd ACTUALLY listens on, not "port 22"
  * password SSH is only disabled when the person running this has a key
  * the sshd drop-in is validated with `sshd -t` and removed if that fails,
    and the service is RELOADED, not restarted, so this session survives
It exits non-zero whenever it declined or failed to do something, so a
provisioning run cannot mistake a half-hardened host for a hardened one.
HELP_END
}

action_harden() {

say()  { echo "==> [harden] $*"; }
die()  { echo "!! [harden] $*" >&2; exit 1; }
problems=0
warn() { echo "!! [harden] $*" >&2; problems=$((problems + 1)); }

usage() { help_harden; }

# --- options, parsed and validated before anything changes -------------------
# Flags, not environment variables: a misspelt variable is silently ignored,
# a misspelt flag is an error, and the command line shows everything a run used.
allow_args=() skip=() login_user="" ssh_tag="hardening"
while [ $# -gt 0 ]; do
  case "$1" in --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;; esac
  case "$1" in
    --allow|--skip|--login-user|--ssh-tag)
      [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value (try --help)" ;;
  esac
  case "$1" in
    --allow)      IFS=', ' read -r -a v <<<"$2"; allow_args+=("${v[@]}"); shift 2 ;;
    --skip)       IFS=', ' read -r -a v <<<"$2"; skip+=("${v[@]}"); shift 2 ;;
    --login-user) login_user="$2"; shift 2 ;;
    --ssh-tag)    ssh_tag="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "unknown argument '$1' (try --help)" ;;
  esac
done
for st in "${skip[@]}"; do
  case "$st" in firewall|updates|fail2ban|ssh) ;; *) die "--skip: unknown step '$st' (firewall, updates, fail2ban, ssh)" ;; esac
done
[[ "$ssh_tag" =~ ^[A-Za-z0-9_-]+$ ]] || die "--ssh-tag: '$ssh_tag' must be letters, digits, - or _ (it becomes a file name)"

[ "$(id -u)" = "0" ] || die "must run as root"

skipped() { case " ${skip[*]} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# --- platform ----------------------------------------------------------------
# Only what differs between distributions sits behind $family: how packages are
# installed. The rest — which ports, the lockout checks, the verification — is
# the same everywhere, so supporting another family means a new case here, not a
# second script. Not a dispatcher fetching per-distro scripts either: ops-get
# verifies exactly one file, and anything this fetched would run unverified.
os_id="" os_like="" os_name=""
if [ -r /etc/os-release ]; then
  os_id="$(. /etc/os-release; echo "${ID:-}")"
  os_like="$(. /etc/os-release; echo "${ID_LIKE:-}")"
  os_name="$(. /etc/os-release; echo "${PRETTY_NAME:-}")"
fi
case " $os_id $os_like " in
  *" debian "*|*" ubuntu "*) family=debian ;;
  *) die "unsupported OS '${os_name:-unknown}'. Implemented: the Debian family (Debian, Ubuntu). Nothing was changed." ;;
esac

# A freshly booted server is exactly when this runs, and exactly when cloud-init
# or apt-daily is still holding apt's locks. Waiting is the only right answer;
# failing makes the first run on every new host a coin toss.
APT_LOCK_WAIT=600

# apt/dpkg print hundreds of lines that bury this script's own warnings. Keep
# their output and show it only if they fail.
quietly() { # description cmd...
  local what="$1" out; shift
  out="$("$@" 2>&1)" || { echo "$out" >&2; die "$what failed"; }
}

apt_update() {
  # DPkg::Lock::Timeout makes `apt-get install` wait for the lock, but not
  # `apt-get update` (apt 2.8), which fails at once. So update waits here.
  local waited=0 out
  until out="$(apt-get -q update 2>&1)"; do
    case "$out" in
      *"Could not get lock"*|*"Unable to lock"*) ;;
      *) echo "$out" >&2; die "apt-get update failed" ;;
    esac
    [ "$waited" -lt "$APT_LOCK_WAIT" ] || { echo "$out" >&2; die "apt is still locked after ${APT_LOCK_WAIT}s"; }
    [ "$waited" -gt 0 ] || say "apt is busy (another update is running); waiting up to $((APT_LOCK_WAIT / 60)) min"
    sleep 5; waited=$((waited + 5))
  done
}

install_packages() {
  case "$family" in
    debian)
      export DEBIAN_FRONTEND=noninteractive
      apt_update
      quietly "installing $*" apt-get -q -y -o DPkg::Lock::Timeout="$APT_LOCK_WAIT" install "$@"
      ;;
  esac
}

# --- inputs, validated before anything changes ---------------------------------
# A rule the caller asked for and did not get is an unreachable service with
# nothing saying why. So a bad rule stops the run here, while the host is still
# untouched, rather than being skipped with a note that scrolls away.
rules=()
for rule in "${allow_args[@]}"; do
  case "$rule" in *:*) ;; *) die "--allow '$rule' is not <source>:<port>[/proto]. Nothing was changed." ;; esac
  # Split on the LAST colon, so an IPv6 source (2001:db8::/32:5432) survives.
  src="${rule%:*}"; portproto="${rule##*:}"
  port="${portproto%%/*}"; proto="tcp"
  case "$portproto" in */*) proto="${portproto##*/}" ;; esac
  case "$port" in ''|*[!0-9]*) die "--allow '$rule': '$port' is not a port. Nothing was changed." ;; esac
  { [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; } || die "--allow '$rule': port $port is out of range. Nothing was changed."
  case "$proto" in tcp|udp) ;; *) die "--allow '$rule': protocol must be tcp or udp. Nothing was changed." ;; esac
  [ -n "$src" ] || die "--allow '$rule' has no source. Nothing was changed."
  rules+=("$src $port $proto")
done

# Whoever has to be able to log in again afterwards: the person running this,
# unless told otherwise. SUDO_USER is not configuration — sudo sets it to say
# who invoked it.
operator="${login_user:-${SUDO_USER:-$(id -un)}}"
getent passwd "$operator" >/dev/null || die "--login-user: no such user '$operator'"
sshd_as() { sshd -T -C "user=$operator,host=localhost,addr=127.0.0.1" 2>/dev/null; }

has_authorized_key() {
  local home files f
  home="$(getent passwd "$operator" | cut -d: -f6)"
  [ -n "$home" ] || return 1
  # Keys supplied by a command (LDAP, a CA lookup) cannot be checked from here;
  # whoever configured that already made sure logins work without passwords.
  sshd_as | awk '$1 == "authorizedkeyscommand" && $2 != "none" {found=1} END {exit !found}' && return 0
  # Ask sshd where it looks rather than assuming ~/.ssh/authorized_keys.
  files="$(sshd_as | awk '$1 == "authorizedkeysfile" {$1 = ""; print}')"
  for f in ${files:-.ssh/authorized_keys}; do
    f="${f//%h/$home}"; f="${f//%u/$operator}"; f="${f//%%/%}"
    case "$f" in /*) ;; *) f="$home/$f" ;; esac
    grep -qE '^[^#]*(ssh-|ecdsa-|sk-)' "$f" 2>/dev/null && return 0
  done
  return 1
}

# Every port sshd listens on. The ufw "OpenSSH" profile means port 22, and a
# host with sshd elsewhere was locked out the moment the firewall came up. A
# socket-activated sshd (Ubuntu 24.04+) listens where ssh.socket says, which
# normally matches its config but is what actually decides.
ssh_ports() {
  {
    sshd -T 2>/dev/null | awk '$1 == "port" {print $2}'
    # Only when it is active: Debian ships ssh.socket disabled, still saying
    # port 22, and counting it opened 22 on a host whose sshd was on 2222.
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
      systemctl show -p Listen ssh.socket | grep -oE ':[0-9]+ ' | tr -d ': '
    fi
  } | sort -un
}

say "packages"
# python3-systemd lets fail2ban read journald, below.
install_packages ufw unattended-upgrades fail2ban python3-systemd

if ! skipped firewall; then
  ports="$(ssh_ports)"
  [ -n "$ports" ] || die "cannot tell which port sshd listens on; not enabling a firewall that might cut it off"

  # Dry-run every extra rule first: ufw is the one that knows a valid source
  # address, and a rejection here still leaves the firewall as it was.
  for r in "${rules[@]}"; do
    read -r src port proto <<<"$r"
    out="$(ufw --dry-run allow from "$src" to any port "$port" proto "$proto" 2>&1)" \
      || die "ufw rejects --allow $src:$port/$proto: $out. Firewall not changed."
  done

  for p in $ports; do
    ufw allow "$p/tcp" >/dev/null
    say "firewall: allow SSH on $p/tcp"
  done
  for r in "${rules[@]}"; do
    read -r src port proto <<<"$r"
    ufw allow from "$src" to any port "$port" proto "$proto" >/dev/null
    say "firewall: allow $src -> $port/$proto"
  done

  ufw --force default deny incoming >/dev/null
  ufw --force default allow outgoing >/dev/null
  ufw --force enable >/dev/null
  say "firewall: on, everything else inbound denied"
fi

if ! skipped updates; then
  say "automatic security updates"
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
  systemctl is-active --quiet unattended-upgrades || warn "unattended-upgrades is not running (systemctl status unattended-upgrades)"
fi

if ! skipped fail2ban; then
  say "fail2ban"
  # The stock sshd jail fails on both counts that matter. It reads
  # /var/log/auth.log, which Debian 12 does not have — journald only — so
  # fail2ban refused to start there. And it bans port 22, so with sshd
  # elsewhere it banned a port nobody uses. Name the jail's source and ports
  # explicitly; journald has sshd's log on every systemd distribution.
  f2b_ports="$(ssh_ports | paste -sd, -)"
  cat >"/etc/fail2ban/jail.d/${ssh_tag}.local" <<EOF
[sshd]
enabled = true
backend = systemd
port    = ${f2b_ports:-ssh}
EOF
  systemctl enable fail2ban >/dev/null 2>&1 || true
  # Restart, not enable --now: a fail2ban already running would not re-read
  # the jail. Restarting it does not touch sshd or this session.
  systemctl restart fail2ban >/dev/null 2>&1 || true
  # The server answers before its jails are loaded; give it a moment.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    fail2ban-client status sshd >/dev/null 2>&1 && break
    sleep 1
  done
  fail2ban-client status sshd >/dev/null 2>&1 \
    || warn "fail2ban's sshd jail is not running (journalctl -u fail2ban)"
fi

if ! skipped ssh; then
  if ! has_authorized_key; then
    # The session running this would survive, and the next login would not. A
    # VPS handed over as root + password is exactly this case.
    warn "SSH: NOT disabling password login — '$operator' has no authorised SSH key, so the next login would be refused. Add one (ssh-copy-id) and run this again, or pass --login-user <user> if you log in as a different user who has one."
  else
    say "SSH: key-only (password auth off)"
    dropin="/etc/ssh/sshd_config.d/10-${ssh_tag}.conf"
    mkdir -p /etc/ssh/sshd_config.d
    cat >"$dropin" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
EOF
    # Validate BEFORE reloading, and undo rather than leave a host that refuses
    # every login. Reload, never restart: a restart would drop this session.
    if out="$(sshd -t 2>&1)"; then
      systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
      # sshd keeps the FIRST value it reads, so any file sorting before ours
      # that says "yes" wins, and writing ours changed nothing. Check what sshd
      # will actually do instead of trusting that the file was written.
      eff="$(sshd_as | awk '$1 == "passwordauthentication" || $1 == "kbdinteractiveauthentication" {print $2}' | sort -u)"
      if [ "$eff" != "no" ]; then
        warn "SSH: password login is STILL ON — a setting read before $dropin overrides it. sshd keeps the first value it finds; look at:"
        grep -lsiE '^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication)[[:space:]]+yes' \
          /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf | sed 's/^/     /' >&2 || true
      fi
    else
      rm -f "$dropin"
      warn "SSH: sshd rejected the config, change reverted, auth left untouched: $out"
    fi
  fi
fi

# What the host looks like now, read back from the system rather than echoed
# from what this script meant to do.
summary() {
  local pw
  echo "--- [harden] this host now"
  if ufw status 2>/dev/null | grep -q '^Status: active'; then
    echo "firewall   on, inbound allowed only to:"
    ufw status | awk '/ALLOW/ {printf "             %s\n", $0}'
  else
    echo "firewall   OFF"
  fi
  echo "updates    unattended-upgrades $(systemctl is-active unattended-upgrades 2>/dev/null || true)"
  echo "fail2ban   $(systemctl is-active fail2ban 2>/dev/null || true)"
  pw="$(sshd_as | awk '$1 == "passwordauthentication" {print $2}')"
  echo "ssh        password login $([ "$pw" = "no" ] && echo off || echo ON)"
}
summary

if [ "$problems" -gt 0 ]; then
  echo "!! [harden] finished with $problems problem(s) above — this host is NOT fully hardened" >&2
  exit 1
fi
say "done"
}

# ============================================================================
# server.sh cleanup
# ============================================================================

help_cleanup() {
cat <<'HELP_END'
server.sh cleanup — reclaim disk space from what a Linux machine accumulates and
does not need: package caches, old temp files, an oversized journal, old
rotated logs, crash dumps, thumbnails. REPORTS BY DEFAULT; deletes nothing
without --apply.


  ./server.sh cleanup                      # what each category would free
  sudo ./server.sh cleanup --apply         # clean, and report what was freed
  ./server.sh cleanup --only journal,temp
  sudo ./server.sh cleanup --apply --older-than 14

Categories (all run unless --only or --skip says otherwise):
  package-cache  downloaded packages: apt-get clean, dnf clean packages,
                 pacman -Sc (keeps the versions installed)
  temp           files in /tmp and /var/tmp untouched (modified, accessed,
                 changed) for 7 days; never service-private directories,
                 sockets or the X11 directories
  journal        the systemd journal above --journal-max, via journalctl
                 --vacuum-size
  rotated-logs   compressed or numbered logs in /var/log older than 30 days
  crash-dumps    /var/crash and systemd coredumps older than 7 days
  thumbnails     each user's ~/.cache/thumbnails, regenerated on demand

Opt-in categories, run only when named with --include (or --only):
  docker         dangling images and the build cache — never tagged images,
                 containers, volumes or networks
  autoremove     packages installed only as dependencies of something since
                 removed, old kernels included: apt-get autoremove, dnf
                 autoremove, pacman orphans. Opt-in because "a dependency" is
                 the package manager's record, not the user's intent
  snap-revisions disabled snap revisions, kept by snapd after each refresh

With --root, autoremove and snap-revisions are reported and never applied:
apt's -o Dir moves where it reads, but removing still runs the host's dpkg.

Never touched: documents, downloads, the trash, anything a user made.

Options — every input is one; nothing else is read from the environment
except HOME (whose thumbnails, when not root):
  --apply              clean; without it nothing is deleted. Without root,
                       only what needs none (thumbnails, docker) is cleaned,
                       and the rest is said to need root
  --only <list>        only these categories; repeatable or commas
  --skip <list>        all but these
  --include <list>     add opt-in categories to the default ones
  --older-than <days>  one age limit for temp, rotated-logs and crash-dumps
                       (default 7, 30, 7). 0 means any age — for emptying a
                       machine about to become an image, not a live one
  --journal-max <size> keep the journal to this size (default 500M); K, M, G
  --format <f>         table (default), tsv or json
  --root <dir>         clean the system mounted at <dir> instead of this one
  -h, --help           this text

The cleaning is done by each package manager's own tool where there is one:
it knows what is in use. What was freed is measured, not assumed: each
category is sized again afterwards.
HELP_END
}

action_cleanup() {

die()  { echo "cleanup: $*" >&2; exit 1; }
note() { echo "cleanup: $*" >&2; }
usage() { help_cleanup; }

ALL="package-cache temp journal rotated-logs crash-dumps thumbnails"
OPTIN="docker autoremove snap-revisions"
# What can be cleaned without root: a user's own files, and a Docker daemon
# the user can reach — rootless, or through the docker group.
USERLEVEL="thumbnails docker"
APPLY=0 ONLY=() SKIP=() INCLUDE=() AGE="" JMAX="500M" FORMAT="table" ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;; esac
  case "$1" in
    --only|--skip|--include|--older-than|--journal-max|--format|--root)
      [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value (try --help)" ;;
  esac
  case "$1" in
    --apply)       APPLY=1; shift ;;
    --only)        IFS=', ' read -r -a v <<<"$2"; ONLY+=("${v[@]}"); shift 2 ;;
    --skip)        IFS=', ' read -r -a v <<<"$2"; SKIP+=("${v[@]}"); shift 2 ;;
    --include)     IFS=', ' read -r -a v <<<"$2"; INCLUDE+=("${v[@]}"); shift 2 ;;
    --older-than)  [[ "$2" =~ ^[0-9]+$ ]] || die "--older-than '$2' is not a number of days"; AGE="$2"; shift 2 ;;
    --journal-max) [[ "$2" =~ ^[0-9]+[KMG]?$ ]] || die "--journal-max '$2': a size like 500M or 2G"; JMAX="$2"; shift 2 ;;
    --format)      FORMAT="$2"; shift 2 ;;
    --root)        ROOT="${2%/}"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown argument '$1' (try --help)" ;;
  esac
done
case "$FORMAT" in table|tsv|json) ;; *) die "--format '$FORMAT': table, tsv or json" ;; esac
for c in "${ONLY[@]}" "${SKIP[@]}" "${INCLUDE[@]}"; do
  case " $ALL $OPTIN " in *" $c "*) ;; *) die "unknown category '$c'. Categories: $ALL; opt-in: $OPTIN" ;; esac
done
[ -z "$ROOT" ] || [ -d "$ROOT" ] || die "--root: $ROOT is not a directory"
IS_ROOT=0; [ "$(id -u)" = 0 ] && IS_ROOT=1
# Without root, --apply cleans what needs none and leaves the rest, saying so —
# as server.ps1 cleanup does on Windows.
NOROOT_APPLY=0
[ "$APPLY" = 1 ] && [ "$IS_ROOT" = 0 ] && [ -z "$ROOT" ] && NOROOT_APPLY=1

TEMP_AGE="${AGE:-7}" LOG_AGE="${AGE:-30}" DUMP_AGE="${AGE:-7}"
# find arguments for "older than N days by every measure"; nothing for 0.
older() { # days measure…
  local d="$1"; shift
  [ "$d" = 0 ] && return 0
  local m; for m in "$@"; do printf -- '-%s\0+%s\0' "$m" "$d"; done
}
# Read into arrays once, so paths and flags stay separate words.
mapfile -d '' TEMP_OLD < <(older "$TEMP_AGE" mtime atime ctime)
mapfile -d '' LOG_OLD < <(older "$LOG_AGE" mtime)
mapfile -d '' DUMP_OLD < <(older "$DUMP_AGE" mtime)

# Default categories run unless left out; opt-in ones only when named.
selected() {
  local c="$1"
  if [ "${#ONLY[@]}" -gt 0 ]; then case " ${ONLY[*]} " in *" $c "*) ;; *) return 1 ;; esac
  else
    case " $OPTIN " in *" $c "*) case " ${INCLUDE[*]} " in *" $c "*) ;; *) return 1 ;; esac ;; esac
  fi
  case " ${SKIP[*]} " in *" $c "*) return 1 ;; esac
  return 0
}

# Every category is two functions: size_<c> prints "<bytes> <items>" for what
# would go, clean_<c> removes it. Freed is size before minus size after.
#
# clean_<c> runs inside `if !`, and there bash switches set -e off for the
# whole function: a failed apt-get was carried past and reported as success.
# So every step checks its own result, `|| return 1`, instead of relying on it.

# Sum of sizes and count from a NUL-separated list of files.
sum_files() { xargs -0 -r stat -c %s -- 2>/dev/null | awk '{ b += $1; n++ } END { printf "%d %d\n", b, n }'; }
bytes_of() { # 500M -> bytes
  local n="${1%[KMG]}"
  case "$1" in *K) echo $((n * 1024)) ;; *M) echo $((n * 1048576)) ;; *G) echo $((n * 1073741824)) ;; *) echo "$n" ;; esac
}

# --- package-cache --------------------------------------------------------------

apt_cache_files() {
  find "$ROOT/var/cache/apt" -xdev \( -path "$ROOT/var/cache/apt/archives/*.deb" -o \
    -path "$ROOT/var/cache/apt/archives/partial/*" -o -name '*.bin' \) -type f -print0 2>/dev/null || true
}
dnf_cache_files() {
  find "$ROOT/var/cache/dnf" "$ROOT/var/cache/libdnf5" -xdev -type f -name '*.rpm' -print0 2>/dev/null || true
}
# pacman -Sc keeps the version of each package that is installed and removes
# the rest; sized by the same rule, read from the local database.
pacman_cache_files() {
  local cache="$ROOT/var/cache/pacman/pkg" f base rest arch rel ver name
  [ -d "$cache" ] || return 0
  for f in "$cache"/*.pkg.tar.*; do
    [ -f "$f" ] || continue
    case "$f" in *.sig) continue ;; esac
    base="$(basename "$f")"; rest="${base%.pkg.tar.*}"
    arch="${rest##*-}"; rest="${rest%-*}"; rel="${rest##*-}"; rest="${rest%-*}"
    ver="${rest##*-}"; name="${rest%-*}"
    [ -d "$ROOT/var/lib/pacman/local/$name-$ver-$rel" ] && continue
    printf '%s\0' "$f"
    # An if, not `[ ] && printf`: as the loop's last command, a package with no
    # signature made the whole function fail, and the cache "could not be sized".
    if [ -f "$f.sig" ]; then printf '%s\0' "$f.sig"; fi
  done
  return 0
}
size_package_cache() {
  { apt_cache_files; dnf_cache_files; pacman_cache_files; } | sum_files
}
how_package_cache() {
  local h=()
  [ -d "$ROOT/var/cache/apt" ] && h+=("apt-get clean")
  { [ -d "$ROOT/var/cache/dnf" ] || [ -d "$ROOT/var/cache/libdnf5" ]; } && h+=("dnf clean packages")
  [ -d "$ROOT/var/cache/pacman/pkg" ] && h+=("pacman -Sc")
  local IFS=,; echo "${h[*]:-no package manager cache}"
}
clean_package_cache() {
  if [ -d "$ROOT/var/cache/apt" ] && command -v apt-get >/dev/null 2>&1; then
    if [ -n "$ROOT" ]; then apt-get -o "Dir=$ROOT/" clean || return 1; else apt-get clean || return 1; fi
  fi
  if { [ -d "$ROOT/var/cache/dnf" ] || [ -d "$ROOT/var/cache/libdnf5" ]; } && command -v dnf >/dev/null 2>&1; then
    dnf ${ROOT:+--installroot "$ROOT"} -q clean packages >/dev/null || return 1
  fi
  if [ -d "$ROOT/var/cache/pacman/pkg" ] && command -v pacman >/dev/null 2>&1; then
    pacman ${ROOT:+--root "$ROOT" --cachedir "$ROOT/var/cache/pacman/pkg"} -Sc --noconfirm >/dev/null || return 1
  fi
}

# --- temp ---------------------------------------------------------------------

# Untouched by every measure systemd-tmpfiles uses — modified, accessed, and
# changed — and never inside what belongs to a running service or a session.
temp_files() {
  local d
  for d in "$ROOT/tmp" "$ROOT/var/tmp"; do
    [ -d "$d" ] || continue
    find "$d" -xdev -mindepth 1 \
      \( -name 'systemd-private-*' -o -name 'snap-private-tmp' -o -name '.X11-unix' -o -name '.ICE-unix' \
         -o -name '.XIM-unix' -o -name '.font-unix' -o -name '.Test-unix' \) -prune -o \
      -type f "${TEMP_OLD[@]}" -print0 2>/dev/null || true
  done
}
size_temp() { temp_files | sum_files; }
how_temp() { [ "$TEMP_AGE" = 0 ] && echo "any age" || echo "untouched for ${TEMP_AGE}+ days"; }
clean_temp() {
  # Directories old enough to go once empty — listed BEFORE their files are
  # removed, because removing a file makes its directory new again, and then
  # it stayed behind. Deepest first, and rmdir only ever removes an empty one.
  local d dirs
  dirs="$(for d in "$ROOT/tmp" "$ROOT/var/tmp"; do
    [ -d "$d" ] || continue
    find "$d" -xdev -mindepth 1 \( -name 'systemd-private-*' -o -name 'snap-private-tmp' -o -name '.*-unix' \) -prune -o \
      -type d "${TEMP_OLD[@]:0:2}" -print 2>/dev/null || true
  done | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2-)"
  temp_files | xargs -0 -r rm -f -- || return 1
  while IFS= read -r d; do [ -n "$d" ] && rmdir -- "$d" 2>/dev/null || true; done <<<"$dirs"
}

# --- journal ------------------------------------------------------------------

journal_dir() {
  if [ -n "$ROOT" ]; then echo "$ROOT/var/log/journal"
  elif [ -d /var/log/journal ]; then echo /var/log/journal
  else echo /run/log/journal; fi
}
journal_usage() { # bytes the journal takes
  local d; d="$(journal_dir)"
  [ -d "$d" ] && command -v journalctl >/dev/null 2>&1 || { echo 0; return; }
  local out
  out="$(journalctl -D "$d" --disk-usage 2>/dev/null | sed -n 's/.*take up \([0-9.]*[BKMGT]\?\).*/\1/p')"
  awk -v s="${out:-0}" 'BEGIN {
    n = s + 0; u = substr(s, length(s))
    if (u == "K") n *= 1024; else if (u == "M") n *= 1048576; else if (u == "G") n *= 1073741824; else if (u == "T") n *= 1099511627776
    printf "%d\n", n }'
}
# Only ARCHIVED journal files can be vacuumed; the active ones stay whatever
# the limit. So what can go is the excess over the limit, but never more than
# the archived files hold — otherwise the report promised space that no
# cleaning could ever free, and said so again after every run.
size_journal() {
  local used max d archived
  used="$(journal_usage)"; max="$(bytes_of "$JMAX")"; d="$(journal_dir)"
  [ "$used" -gt "$max" ] || { echo "0 -"; return; }
  archived="$(find "$d" -xdev -type f \( -name '*@*.journal' -o -name '*.journal~' \) -print0 2>/dev/null | sum_files | cut -d' ' -f1 || true)"
  archived="${archived:-0}"
  local excess=$((used - max))
  if [ "$archived" -lt "$excess" ]; then echo "$archived -"; else echo "$excess -"; fi
}
how_journal() { echo "kept to $JMAX (journalctl --vacuum-size)"; }
clean_journal() {
  local d; d="$(journal_dir)"
  [ -d "$d" ] || return 0
  journalctl -D "$d" --vacuum-size="$JMAX" >/dev/null 2>&1 || return 1
}

# --- rotated-logs -------------------------------------------------------------

rotated_files() {
  [ -d "$ROOT/var/log" ] || return 0
  # Unreadable directories are expected without root, which is said once up
  # front; they must not make a category look failed. Hence || true on finds.
  find "$ROOT/var/log" -xdev -path "$ROOT/var/log/journal" -prune -o -type f \
    \( -name '*.gz' -o -name '*.xz' -o -name '*.bz2' -o -name '*.zst' -o -name '*.old' -o -regex '.*\.[0-9]+' \) \
    "${LOG_OLD[@]}" -print0 2>/dev/null || true
}
size_rotated_logs() { rotated_files | sum_files; }
how_rotated_logs() { [ "$LOG_AGE" = 0 ] && echo "any age" || echo "older than $LOG_AGE days"; }
clean_rotated_logs() { rotated_files | xargs -0 -r rm -f -- || return 1; }

# --- crash-dumps --------------------------------------------------------------

dump_files() {
  local d
  for d in "$ROOT/var/crash" "$ROOT/var/lib/systemd/coredump"; do
    [ -d "$d" ] || continue
    find "$d" -xdev -mindepth 1 -type f "${DUMP_OLD[@]}" -print0 2>/dev/null || true
  done
}
size_crash_dumps() { dump_files | sum_files; }
how_crash_dumps() { [ "$DUMP_AGE" = 0 ] && echo "any age" || echo "older than $DUMP_AGE days"; }
clean_crash_dumps() { dump_files | xargs -0 -r rm -f -- || return 1; }

# --- thumbnails ---------------------------------------------------------------

thumbnail_dirs() {
  if [ "$IS_ROOT" = 1 ] || [ -n "$ROOT" ]; then
    local d
    for d in "$ROOT"/home/*/.cache/thumbnails "$ROOT/root/.cache/thumbnails"; do [ -d "$d" ] && echo "$d"; done
  else
    [ -d "$HOME/.cache/thumbnails" ] && echo "$HOME/.cache/thumbnails"
  fi
  return 0
}
thumbnail_files() { local d; while read -r d; do find "$d" -xdev -type f -print0 2>/dev/null || true; done < <(thumbnail_dirs); }
size_thumbnails() { thumbnail_files | sum_files; }
how_thumbnails() { echo "regenerated on demand"; }
clean_thumbnails() { thumbnail_files | xargs -0 -r rm -f -- || return 1; }

# --- docker (opt-in) ------------------------------------------------------------

# Only what nothing refers to: images left untagged by a newer build, and the
# build cache. Docker's own reclaimable figure counts every unused image and
# every unused volume — data, as far as this script can know — so it is not
# what is offered here.
docker_ok() { [ -z "$ROOT" ] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }
docker_bytes() { # Docker's "1.2GB" (decimal units) -> bytes
  awk -v s="$1" 'BEGIN { n = s + 0; u = s; sub(/^[0-9.]+/, "", u)
    m = (u == "kB" || u == "KB") ? 1e3 : (u == "MB") ? 1e6 : (u == "GB") ? 1e9 : (u == "TB") ? 1e12 : 1
    printf "%d\n", n * m }'
}
size_docker() {
  docker_ok || { echo "0 0"; return 0; }
  # Each image's UNIQUE size — layers no other image shares. Adding up their
  # plain sizes counted shared base layers once per image: 10.3G claimed where
  # Docker itself put every unused image together at 5.1G.
  local img cache
  img="$(docker system df -v --format '{{range .Images}}{{.Repository}}|{{.Tag}}|{{.UniqueSize}}{{println}}{{end}}' |
    awk -F'|' '$1 == "<none>" && $2 == "<none>" { print $3 }')"
  cache="$(docker system df --format '{{.Type}}|{{.Reclaimable}}|{{.TotalCount}}' | awk -F'|' '$1 == "Build Cache" { split($2, a, " "); print a[1] "|" $3 }')"
  local bytes=0 n=0 u
  while read -r u; do [ -n "$u" ] || continue; bytes=$((bytes + $(docker_bytes "$u"))); n=$((n + 1)); done <<<"$img"
  bytes=$((bytes + $(docker_bytes "${cache%%|*}")))
  echo "$bytes $((n + ${cache##*|}))"
}
how_docker() { docker_ok && echo "dangling images, build cache" || echo "no Docker daemon reachable"; }
clean_docker() {
  docker image prune --force >/dev/null || return 1
  docker builder prune --force >/dev/null || return 1
}

# --- autoremove (opt-in) -------------------------------------------------------

# "<manager> <package>" for each package its manager would autoremove.
autoremove_list() {
  if command -v apt-get >/dev/null 2>&1 && [ -e "$ROOT/var/lib/dpkg/status" ]; then
    local aptopts=()
    [ -z "$ROOT" ] || aptopts=(-o "Dir=$ROOT/" -o "Dir::State::status=$ROOT/var/lib/dpkg/status")
    apt-get "${aptopts[@]}" -s autoremove 2>/dev/null | awk '$1 == "Remv" { print "apt " $2 }' || true
  fi
  if command -v dnf >/dev/null 2>&1 && command -v rpm >/dev/null 2>&1; then
    dnf ${ROOT:+--installroot "$ROOT"} -C -q repoquery --unneeded --qf '%{name}\n' 2>/dev/null | awk 'NF { print "dnf " $1 }' || true
  fi
  if [ -d "$ROOT/var/lib/pacman/local" ] && command -v pacman >/dev/null 2>&1; then
    pacman ${ROOT:+--root "$ROOT"} -Qtdq 2>/dev/null | awk 'NF { print "pacman " $1 }' || true
  fi
  return 0
}
size_autoremove() {
  local list; list="$(autoremove_list)"
  [ -n "$list" ] || { echo "0 0"; return 0; }
  local apt dnf pac kb=0 b=0
  apt="$(awk '$1 == "apt" { print $2 }' <<<"$list")"
  dnf="$(awk '$1 == "dnf" { print $2 }' <<<"$list")"
  pac="$(awk '$1 == "pacman" { print $2 }' <<<"$list")"
  if [ -n "$apt" ]; then
    kb="$(dpkg-query --admindir="$ROOT/var/lib/dpkg" -W -f='${Installed-Size}\n' $apt 2>/dev/null | awk '{ s += $1 } END { printf "%d", s }')"
    b=$((b + kb * 1024))
  fi
  if [ -n "$dnf" ]; then
    b=$((b + $(rpm ${ROOT:+--root "$ROOT"} -q --qf '%{SIZE}\n' $dnf 2>/dev/null | awk '{ s += $1 } END { printf "%d", s }')))
  fi
  if [ -n "$pac" ]; then
    b=$((b + $(find "$ROOT/var/lib/pacman/local" -mindepth 2 -maxdepth 2 -name desc -print0 | xargs -0 -r awk -v want=" $(tr '\n' ' ' <<<"$pac")" '
      FNR == 1 { if (keep) s += size; keep = 0; size = 0 }
      /^%NAME%$/ { getline; keep = index(want, " " $0 " ") > 0 }
      /^%SIZE%$/ { getline; size = $0 }
      END { if (keep) s += size; printf "%d", s }')))
  fi
  echo "$b $(wc -l <<<"$list")"
}
how_autoremove() {
  local m=()
  command -v apt-get >/dev/null 2>&1 && [ -e "$ROOT/var/lib/dpkg/status" ] && m+=("apt-get autoremove")
  command -v dnf >/dev/null 2>&1 && m+=("dnf autoremove")
  [ -d "$ROOT/var/lib/pacman/local" ] && m+=("pacman orphans")
  local IFS=,; local h="${m[*]:-no package manager}"
  [ -z "$ROOT" ] || h="$h; reported only under --root"
  echo "$h"
}
clean_autoremove() {
  [ -z "$ROOT" ] || return 0             # see the header: never under --root
  local list; list="$(autoremove_list)"
  if grep -q '^apt ' <<<"$list"; then
    DEBIAN_FRONTEND=noninteractive apt-get -y -q autoremove >/dev/null || return 1
  fi
  if grep -q '^dnf ' <<<"$list"; then dnf -y -q autoremove >/dev/null || return 1; fi
  if grep -q '^pacman ' <<<"$list"; then
    # shellcheck disable=SC2046
    pacman -Rns --noconfirm $(awk '$1 == "pacman" { print $2 }' <<<"$list") >/dev/null || return 1
  fi
}

# --- snap-revisions (opt-in) ---------------------------------------------------

# "<name> <revision>" for each revision snap lists as disabled. snapd answers
# only for the running system, so nothing under --root.
snap_disabled() {
  [ -z "$ROOT" ] && command -v snap >/dev/null 2>&1 || return 0
  snap list --all --unicode=never --color=never 2>/dev/null | awk 'NR > 1 && $NF ~ /(^|,)disabled(,|$)/ { print $1, $3 }' || true
}
size_snap_revisions() {
  local b=0 n=0 name rev f
  while read -r name rev; do
    [ -n "$name" ] || continue
    n=$((n + 1)); f="/var/lib/snapd/snaps/${name}_${rev}.snap"
    [ -f "$f" ] && b=$((b + $(stat -c %s "$f")))
  done < <(snap_disabled)
  echo "$b $n"
}
how_snap_revisions() { echo "snap remove --revision, disabled ones only"; }
clean_snap_revisions() {
  local name rev
  while read -r name rev; do
    [ -n "$name" ] || continue
    snap remove "$name" --revision="$rev" >/dev/null || return 1
  done < <(snap_disabled)
}

# --- run -----------------------------------------------------------------------

[ "$IS_ROOT" = 1 ] || [ -n "$ROOT" ] || note "not root: some files cannot be read, so sizes may be incomplete"
FAILED="" RESULTS="" LEFT=""
for c in $ALL $OPTIN; do
  selected "$c" || continue
  fn="${c//-/_}"
  if [ "$NOROOT_APPLY" = 1 ]; then
    case " $USERLEVEL " in *" $c "*) ;; *) LEFT+=" $c"; continue ;; esac
  fi
  if ! before="$("size_$fn")"; then note "could not size $c"; FAILED+=" $c"; continue; fi
  read -r bytes items <<<"$before"
  how="$("how_$fn")"
  # Something to clean: bytes, or items whose size could not be read.
  if [ "$APPLY" = 1 ] && { [ "$bytes" -gt 0 ] || { [ "$items" != "-" ] && [ "$items" -gt 0 ]; }; }; then
    if ! err="$("clean_$fn" 2>&1)"; then
      note "could not clean $c: $(head -1 <<<"$err")"; FAILED+=" $c"
    fi
    read -r after _ <<<"$("size_$fn")"
    bytes=$((bytes - after))
  fi
  RESULTS+="$c	$bytes	$items	$how"$'\n'
done

[ -z "$LEFT" ] || note "not root: left for root:$LEFT"
awk -F'\t' -v fmt="$FORMAT" -v apply="$APPLY" '
  function human(b) {
    if (b >= 1073741824) return sprintf("%.1fG", b / 1073741824)
    if (b >= 1048576) return sprintf("%.1fM", b / 1048576)
    if (b >= 1024) return sprintf("%.1fK", b / 1024)
    return b "B"
  }
  function js(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return "\"" s "\"" }
  NF >= 4 { n++; c[n] = $1; b[n] = $2; it[n] = $3; h[n] = $4; total += $2 }
  END {
    col = apply ? "FREED" : "RECLAIMABLE"
    if (fmt == "tsv") {
      print "category\t" tolower(col) "_bytes\titems\thow"
      for (i = 1; i <= n; i++) print c[i] "\t" b[i] "\t" it[i] "\t" h[i]
    } else if (fmt == "json") {
      printf "{\"applied\": %s, \"total_bytes\": %d, \"categories\": [", (apply ? "true" : "false"), total
      for (i = 1; i <= n; i++)
        printf "%s\n  {\"category\": %s, \"bytes\": %d, \"items\": %s, \"how\": %s}", (i > 1 ? "," : ""), js(c[i]), b[i], (it[i] == "-" ? "null" : it[i]), js(h[i])
      print (n ? "\n]}" : "]}")
    } else {
      w = 8; for (i = 1; i <= n; i++) if (length(c[i]) > w) w = length(c[i])
      printf "%-" w "s  %11s  %6s  %s\n", "CATEGORY", col, "ITEMS", "HOW"
      for (i = 1; i <= n; i++) printf "%-" w "s  %11s  %6s  %s\n", c[i], human(b[i]), it[i], h[i]
      printf "%-" w "s  %11s\n", "total", human(total)
      if (!apply) print "(a report: nothing was deleted. --apply to clean.)" > "/dev/stderr"
    }
  }' <<<"$RESULTS"

[ -z "$FAILED" ] || exit 1
}

# ============================================================================
# server.sh inventory
# ============================================================================

help_inventory() {
cat <<'HELP_END'
server.sh inventory — list the software installed on this machine, and which package
manager put each piece there.


  ./server.sh inventory                         # name, version, package manager
  ./server.sh inventory --wide                  # + arch, size, installed, explicit, source, update, summary
  ./server.sh inventory --pm snap,flatpak --search firefox
  ./server.sh inventory --explicit              # only what someone installed on purpose
  ./server.sh inventory --format json > inventory.json
  ./server.sh inventory --refresh               # rescan instead of reading the saved list

Every scan is saved IN FULL — every column, whatever format was asked for —
and later runs read that saved list instead of scanning again. --refresh
rescans; --no-cache neither reads nor writes it.

Package managers (PM column):
  apt      a .deb from a configured repository
  dpkg     a .deb installed by hand, found in no repository
  rpm, pacman, snap, flatpak
  manual   no package manager: an executable in /usr/local/bin, or a
           directory in /opt that no package owns — the curl | sh installs

Options — every input is one; nothing else is read from the environment
except HOME and XDG_CACHE_HOME, which say where the saved list lives:
  --wide               the wide table (same as --format wide)
  --format <f>         table (default), wide, tsv (every column, with a
                       header) or json
  --pm <list>          only these package managers; repeatable or commas
  --search <text>      only names or summaries containing this (any case)
  --explicit           only what was installed on purpose, not as a dependency
  --updates            only what has a newer version known locally
  --refresh            scan now, and replace the saved list
  --no-cache           scan now, and neither read nor write the saved list
  --cache <path>       where the saved list lives
                       (default ~/.cache/ops/inventory.tsv)
  --root <dir>         inventory the system mounted at <dir> — a disk, a
                       chroot, an unpacked container image — instead of this
                       one. dpkg/apt, rpm, pacman and manual are read from it;
                       snap and flatpak describe the running system and are
                       skipped. Not saved unless --cache is given.
  -h, --help           this text

Needs bash and the usual tools (awk, stat, find); nothing to install. It only
reads: it never asks a package manager to refresh or touch the network.
HELP_END
}

action_inventory() {

die()  { echo "inventory: $*" >&2; exit 1; }
note() { echo "inventory: $*" >&2; }
usage() { help_inventory; }

FORMAT="table" PMS=() SEARCH="" EXPLICIT=0 UPDATES=0 MODE="cached" ROOT="" CACHE=""
while [ $# -gt 0 ]; do
  case "$1" in --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;; esac
  case "$1" in
    --format|--pm|--search|--cache|--root)
      [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value (try --help)" ;;
  esac
  case "$1" in
    --wide)     FORMAT="wide"; shift ;;
    --format)   FORMAT="$2"; shift 2 ;;
    --pm)       IFS=', ' read -r -a v <<<"$2"; PMS+=("${v[@]}"); shift 2 ;;
    --search)   SEARCH="$2"; shift 2 ;;
    --explicit) EXPLICIT=1; shift ;;
    --updates)  UPDATES=1; shift ;;
    --refresh)  MODE="refresh"; shift ;;
    --no-cache) MODE="none"; shift ;;
    --cache)    CACHE="$2"; shift 2 ;;
    --root)     ROOT="${2%/}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "unknown argument '$1' (try --help)" ;;
  esac
done
case "$FORMAT" in table|wide|tsv|json) ;; *) die "--format '$FORMAT': table, wide, tsv or json" ;; esac
if [ -n "$ROOT" ]; then
  [ -d "$ROOT" ] || die "--root: $ROOT is not a directory"
  # Another machine's list must not replace this one's saved list.
  [ -n "$CACHE" ] || MODE="none"
fi
CACHE="${CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/ops/inventory.tsv}"
for p in "${PMS[@]}"; do
  case "$p" in apt|dpkg|rpm|pacman|snap|flatpak|manual) ;;
    *) die "--pm '$p': one of apt, dpkg, rpm, pacman, snap, flatpak, manual" ;; esac
done

# The saved list: a marker line, a header, then one row per package. The marker
# is how it knows a file is its own — it refuses to overwrite anything else,
# since --cache can point anywhere.
MARKER="# ops-inventory v1"
COLUMNS_="name	version	pm	arch	size_kb	installed	explicit	source	update	summary"

# Fields must not carry the separators. A summary with a tab or a newline would
# otherwise shift every column after it.
clean() { tr -d '\r' | awk -F'\t' -v OFS='\t' '{ for (i = 1; i <= NF; i++) gsub(/[[:cntrl:]]/, " ", $i); print }'; }

# --- collectors: each prints rows in COLUMNS_ order, "-" for unknown --------

collect_dpkg() {
  command -v dpkg-query >/dev/null 2>&1 || return 0
  [ -e "$ROOT/var/lib/dpkg/status" ] || return 0
  local apt_list="" have_lists=0 aptopts=()
  # Pointed at another root, apt reads that root's status, lists and marks.
  [ -z "$ROOT" ] || aptopts=(-o "Dir=$ROOT/" -o "Dir::State::status=$ROOT/var/lib/dpkg/status")
  if command -v apt >/dev/null 2>&1; then
    # Without package lists (apt update never ran, or they were cleaned, as in
    # most container images) apt calls EVERY package "local". Then repository
    # and hand-installed cannot be told apart, and saying "dpkg" for all of
    # them would be a false alarm on every line.
    if compgen -G "$ROOT/var/lib/apt/lists/*_Packages*" >/dev/null; then
      have_lists=1
    else
      note "apt has no package lists (apt update never ran here), so repository and hand-installed .debs cannot be told apart"
    fi
    apt_list="$(apt "${aptopts[@]}" list --installed 2>/dev/null | tail -n +2 || true)"
  fi
  # Why each was installed comes from apt-mark, not from apt list's flags:
  # apt list drops "automatic" from any package that has an update, which made
  # every upgradable dependency look installed on purpose.
  local auto=""
  command -v apt-mark >/dev/null 2>&1 && auto="$(apt-mark "${aptopts[@]}" showauto 2>/dev/null || true)"
  # When each package was installed: the mtime of its file list, one stat call.
  local dates
  dates="$(find "$ROOT/var/lib/dpkg/info" -maxdepth 1 -name '*.list' -printf '%TY-%Tm-%Td\t%f\n' 2>/dev/null || true)"

  dpkg-query --admindir="$ROOT/var/lib/dpkg" -W -f='${db:Status-Abbrev}\t${Package}\t${Architecture}\t${Version}\t${Installed-Size}\t${binary:Summary}\n' 2>/dev/null |
  awk -F'\t' -v OFS='\t' -v havelists="$have_lists" -v hasapt="$([ -n "$apt_list" ] && echo 1 || echo 0)" \
      -v hasmark="$([ -n "$auto" ] && echo 1 || echo 0)" '
    FILENAME == "/dev/fd/5" { if ($0 != "") isauto[$0] = 1; next }
    FILENAME == "/dev/fd/3" {           # dates: "YYYY-MM-DD<TAB>pkg[:arch].list"
      f = $2; sub(/\.list$/, "", f); date[f] = $1; next
    }
    FILENAME == "/dev/fd/4" {           # apt: "name/suite,now ver arch [flags]"
      split($0, w, " "); split(w[1], ns, "/")
      key = ns[1] ":" w[3]
      suites = ns[2]; gsub(/(^|,)now(,|$)/, ",", suites); gsub(/^,|,$/, "", suites)
      flags = $0; sub(/.*\[/, "", flags); sub(/\].*/, "", flags)
      local_[key] = (flags ~ /local/)
      upd[key] = ""
      if (flags ~ /upgradable to: /) { u = flags; sub(/.*upgradable to: /, "", u); sub(/[,\]].*/, "", u); upd[key] = u }
      src[key] = suites
      seen[key] = 1
      next
    }
    $1 !~ /^ii/ { next }
    {
      name = $2; arch = $3; key = name ":" arch
      d = (key in date) ? date[key] : ((name in date) ? date[name] : "-")
      pm = hasapt ? "apt" : "dpkg"; explicit = "-"; source = "-"; update = "-"
      if (hasmark) explicit = ((name in isauto) || (key in isauto)) ? "no" : "yes"
      if (key in seen) {
        if (havelists && local_[key]) { pm = "dpkg"; source = "local .deb" }
        else if (src[key] != "") source = src[key]
        if (upd[key] != "") update = upd[key]
      }
      print name, $4, pm, arch, ($5 == "" ? "-" : $5), d, explicit, source, update, ($6 == "" ? "-" : $6)
    }' /dev/fd/5 /dev/fd/3 /dev/fd/4 - 3<<<"$dates" 4<<<"$apt_list" 5<<<"$auto"
}

collect_rpm() {
  command -v rpm >/dev/null 2>&1 || return 0
  local rootopt=() dnfroot=()
  [ -z "$ROOT" ] || { rootopt=(--root "$ROOT"); dnfroot=(--installroot "$ROOT"); }
  # rpm does not record why a package was installed; dnf does. -C: from its
  # local state only, never the network. Without dnf, explicit is unknown.
  local user=""
  if command -v dnf >/dev/null 2>&1; then
    user="$(dnf "${dnfroot[@]}" -C -q repoquery --userinstalled --qf '%{name}\n' 2>/dev/null || true)"
  fi
  rpm "${rootopt[@]}" -qa --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\t%{SIZE}\t%{INSTALLTIME}\t%{VENDOR}\t%{SUMMARY}\n' 2>/dev/null |
  awk -F'\t' -v OFS='\t' -v hasdnf="$([ -n "$user" ] && echo 1 || echo 0)" '
    FILENAME == "/dev/fd/3" { if ($0 != "") byuser[$0] = 1; next }
    $1 == "gpg-pubkey" { next }         # signing keys, not software
    {
      v = $2; sub(/^0:/, "", v)         # epoch 0 is the default; do not show it
      vendor = ($6 == "(none)" || $6 == "") ? "-" : $6
      explicit = hasdnf ? (($1 in byuser) ? "yes" : "no") : "-"
      print $1, v, "rpm", $3, int($4 / 1024), strftime("%Y-%m-%d", $5), explicit, vendor, "-", $7
    }' /dev/fd/3 - 3<<<"$user"
}

collect_pacman() {
  [ -d "$ROOT/var/lib/pacman/local" ] || return 0
  # The local database directly: one awk over every desc file, no pacman
  # process per package. %REASON% 1 means installed as a dependency; absent
  # means installed explicitly.
  find "$ROOT/var/lib/pacman/local" -mindepth 2 -maxdepth 2 -name desc -print0 2>/dev/null |
  xargs -0 -r awk -v OFS='\t' '
    function flush() {
      if (n != "") print n, v, "pacman", a, int(s / 1024), (d == "" ? "-" : strftime("%Y-%m-%d", d)),
                         (r == "1" ? "no" : "yes"), "-", "-", (desc == "" ? "-" : desc)
      n = v = a = s = d = r = desc = ""
    }
    FNR == 1 { flush() }
    /^%[A-Z]+%$/ { field = $0; next }
    /^$/ { field = ""; next }
    field == "%NAME%" { n = $0 } field == "%VERSION%" { v = $0 } field == "%ARCH%" { a = $0 }
    field == "%SIZE%" { s = $0 } field == "%INSTALLDATE%" { d = $0 } field == "%REASON%" { r = $0 }
    field == "%DESC%" { desc = $0 }
    END { flush() }'
}

collect_snap() {
  [ -z "$ROOT" ] || return 0            # snapd answers for the running system only
  command -v snap >/dev/null 2>&1 || return 0
  snap list --unicode=never --color=never 2>/dev/null | tail -n +2 |
  while read -r name version rev tracking publisher notes; do
    local file="/var/lib/snapd/snaps/${name}_${rev}.snap" size="-" date="-" explicit="yes"
    if [ -f "$file" ]; then
      size=$(( $(stat -c %s "$file") / 1024 ))
      date="$(date -d "@$(stat -c %Y "$file")" +%Y-%m-%d)"
    fi
    # Bases, snapd itself and the like are there because another snap needs them.
    case " ${notes:-} " in *" base "*|*" snapd "*|*" core "*) explicit="no" ;; esac
    case "$name" in core|core[0-9]*|snapd|bare) explicit="no" ;; esac
    # --unicode=never draws the verified-publisher check mark as "**".
    publisher="${publisher%\*\*}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$name" "$version" snap - "$size" "$date" "$explicit" "${tracking} (${publisher})" - -
  done
}

collect_flatpak() {
  [ -z "$ROOT" ] || return 0            # flatpak answers for the running system only
  command -v flatpak >/dev/null 2>&1 || return 0
  local kind
  for kind in app runtime; do
    flatpak list --"$kind" --columns=application,version,branch,arch,origin,installation,size,name 2>/dev/null |
    awk -F'\t' -v OFS='\t' -v explicit="$([ "$kind" = app ] && echo yes || echo no)" '
      function kb(s,   n, u) {         # "12.3 MB" -> KB
        n = s + 0; u = s; sub(/^[0-9.]+[[:space:]]*/, "", u)
        if (u ~ /^G/) return int(n * 1024 * 1024); if (u ~ /^M/) return int(n * 1024)
        if (u ~ /^k|^K/) return int(n); return (n > 0 ? int(n / 1024) : "-")
      }
      NF >= 5 {
        v = ($2 == "" ? $3 : $2)
        # Runtimes are installed side by side in several branches; flatpak
        # itself tells them apart as name//branch, and so does this.
        id = (explicit == "no" && $3 != "") ? $1 "//" $3 : $1
        print id, (v == "" ? "-" : v), "flatpak", ($4 == "" ? "-" : $4), kb($7), "-", explicit,
              $5 " (" $6 ")", "-", ($8 == "" ? "-" : $8)
      }'
  done
}

collect_manual() {
  # Owned by a package? Then it is that package's, not manual.
  # $1 is a path as the inspected system sees it (/opt/x), under $ROOT here.
  owned() {
    { [ -e "$ROOT/var/lib/dpkg/status" ] && dpkg --admindir="$ROOT/var/lib/dpkg" -S "$1" >/dev/null 2>&1; } ||
    { command -v rpm >/dev/null 2>&1 && rpm ${ROOT:+--root "$ROOT"} -qf "$1" >/dev/null 2>&1; } ||
    { command -v pacman >/dev/null 2>&1 && pacman ${ROOT:+--root "$ROOT"} -Qo "$1" >/dev/null 2>&1; }
  }
  local f path
  for f in "$ROOT"/usr/local/bin/* "$ROOT"/opt/*; do
    [ -e "$f" ] || continue
    [ -d "$f" ] || [ -x "$f" ] || continue
    path="${f#"$ROOT"}"
    owned "$path" && continue
    local size date
    size="$(du -sk "$f" 2>/dev/null | cut -f1)"
    date="$(date -d "@$(stat -c %Y "$f")" +%Y-%m-%d)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(basename "$f")" - manual - "${size:--}" "$date" yes "$path" - -
  done
}

# One package manager that cannot be read must not cost the whole list, nor
# pass for a complete one. Each collector runs on its own; a failure is named,
# the rest is still shown, the run exits non-zero, and the partial list is not
# saved — a later run would otherwise read it back as the truth.
INCOMPLETE=""
scan() {
  [ -z "$ROOT" ] || note "inventory of $ROOT; snap and flatpak are skipped (they describe the running system only)"
  local c raw; raw="$(mktemp)"
  for c in dpkg rpm pacman snap flatpak manual; do
    if ! "collect_$c" >> "$raw"; then
      note "could not read $c's package database; the list below is missing it"
      INCOMPLETE+=" $c"
    fi
  done
  clean < "$raw" | awk -F'\t' 'NF == 10' | LC_ALL=C sort -t$'\t' -f -k1,1 -k3,3
  rm -f "$raw"
}

# --- the saved list ------------------------------------------------------------

is_inventory() { case "$(head -1 "$1" 2>/dev/null)" in "$MARKER"|"$MARKER "*) return 0 ;; esac; return 1; }

save() { # rows-file
  local dir; dir="$(dirname "$CACHE")"
  if [ -e "$CACHE" ] && ! is_inventory "$CACHE"; then
    note "not saving: $CACHE exists and is not an inventory file (choose another --cache)"
    return 0
  fi
  mkdir -p "$dir"
  local tmp; tmp="$(mktemp "$dir/.inventory.XXXXXX")"
  { echo "$MARKER host=${ROOT:-$(hostname)} scanned=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "$COLUMNS_"
    cat "$1"; } > "$tmp"
  mv "$tmp" "$CACHE"
}

# A package database newer than the saved list means the list may be out of
# date. Said, not acted on: reading the saved list was asked for.
stale() {
  local db
  for db in /var/lib/dpkg/status /var/lib/rpm /var/lib/pacman/local /var/lib/snapd/state.json \
            /var/lib/flatpak /usr/local/bin /opt; do
    [ -e "$ROOT$db" ] && [ "$ROOT$db" -nt "$CACHE" ] && return 0
  done
  return 1
}

ROWS="$(mktemp)"
trap 'rm -f "$ROWS"' EXIT

if [ "$MODE" = "cached" ] && is_inventory "$CACHE"; then
  tail -n +3 "$CACHE" > "$ROWS"
  scanned="$(head -1 "$CACHE" | sed -n 's/.*scanned=\([^ ]*\).*/\1/p')"
  note "from the list saved $scanned in $CACHE (--refresh to scan again)"
  stale && note "a package database has changed since then; this list may be out of date"
else
  [ "$MODE" = "cached" ] && [ -e "$CACHE" ] && ! is_inventory "$CACHE" \
    && die "$CACHE is not an inventory file; choose another --cache"
  scan > "$ROWS"
  if [ -n "$INCOMPLETE" ]; then
    [ "$MODE" = "none" ] || note "not saving an incomplete list"
  elif [ "$MODE" != "none" ]; then
    save "$ROWS"
  fi
fi

# --- filter and render ----------------------------------------------------------

awk -F'\t' -v OFS='\t' -v fmt="$FORMAT" -v pms=" ${PMS[*]} " -v q="$SEARCH" \
    -v onlyexplicit="$EXPLICIT" -v onlyupdates="$UPDATES" -v cols="$COLUMNS_" '
  function human(kb) {
    if (kb !~ /^[0-9]+$/) return "-"
    if (kb >= 1048576) return sprintf("%.1fG", kb / 1048576)
    if (kb >= 1024) return sprintf("%.1fM", kb / 1024)
    return kb "K"
  }
  function cut(s, n) { return length(s) > n ? substr(s, 1, n - 1) "~" : s }
  function js(s) {
    gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s)
    return "\"" s "\""
  }
  BEGIN { split(cols, name, "\t") }
  {
    if (pms != "  " && index(pms, " " $3 " ") == 0) next
    if (q != "" && index(tolower($1 " " $10), tolower(q)) == 0) next
    if (onlyexplicit && $7 != "yes") next
    if (onlyupdates && ($9 == "-" || $9 == "")) next
    n++; for (i = 1; i <= 10; i++) row[n, i] = $i
    count[$3]++
  }
  END {
    if (fmt == "tsv") {
      print cols
      for (r = 1; r <= n; r++) { line = row[r, 1]; for (i = 2; i <= 10; i++) line = line "\t" row[r, i]; print line }
    } else if (fmt == "json") {
      printf "["
      for (r = 1; r <= n; r++) {
        printf "%s\n  {", (r > 1 ? "," : "")
        for (i = 1; i <= 10; i++) printf "%s%s: %s", (i > 1 ? ", " : ""), js(name[i]), js(row[r, i])
        printf "}"
      }
      print (n ? "\n]" : "]")
    } else {
      if (fmt == "table") { nc = split("1 2 3", c, " "); split("NAME VERSION PM", h, " ") }
      else { nc = split("1 2 3 4 5 6 7 8 9 10", c, " ")
             split("NAME VERSION PM ARCH SIZE INSTALLED EXPLICIT SOURCE UPDATE SUMMARY", h, " ") }
      for (r = 1; r <= n; r++) {
        row[r, 5] = human(row[r, 5]); row[r, 1] = cut(row[r, 1], 60)
        row[r, 2] = cut(row[r, 2], 36); row[r, 8] = cut(row[r, 8], 40)
      }
      for (j = 1; j <= nc; j++) { w[j] = length(h[j]); for (r = 1; r <= n; r++) if (length(row[r, c[j]]) > w[j]) w[j] = length(row[r, c[j]]) }
      line = ""; for (j = 1; j <= nc; j++) line = line (j < nc ? sprintf("%-" w[j] "s  ", h[j]) : h[j]); print line
      for (r = 1; r <= n; r++) {
        line = ""; for (j = 1; j <= nc; j++) line = line (j < nc ? sprintf("%-" w[j] "s  ", row[r, c[j]]) : row[r, c[j]]); print line
      }
      fflush()                           # the table first, then the count after it
      summary = ""; for (p in count) summary = summary sprintf("%s %d, ", p, count[p]); sub(/, $/, "", summary)
      printf "%d packages%s\n", n, (n ? " — " summary : "") > "/dev/stderr"
    }
  }' "$ROWS"

[ -z "$INCOMPLETE" ] || exit 1
}

# ============================================================================

subject_usage() { sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }
case "${1:-}" in
  harden) shift; action_harden "$@" ;;
  cleanup) shift; action_cleanup "$@" ;;
  inventory) shift; action_inventory "$@" ;;
  -h|--help|help) subject_usage ;;
  "") subject_usage >&2; exit 1 ;;
  *) echo "server.sh: unknown action '$1'. Actions: harden, cleanup, inventory" >&2; exit 1 ;;
esac

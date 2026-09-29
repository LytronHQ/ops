#!/usr/bin/env bash
#
# harden.sh — bring a fresh Linux host to a sane baseline. Idempotent; safe to
# run again to re-apply.
#
#   sudo ./harden.sh [options]
#   sudo ./harden.sh --allow 10.0.0.0/16:5432 --allow 203.0.113.4:8090/udp
#
# Options — every input is one; nothing else is read from the environment
# except who ran sudo:
#   --allow <source>:<port>[/tcp|udp]
#                     keep this port open to this source. Repeatable, or
#                     comma separated. Everything else inbound is denied.
#   --skip <step>     leave a step alone: firewall, updates, fail2ban or ssh.
#                     Repeatable, or comma separated.
#   --login-user <u>  whose key must exist before password SSH is turned off
#                     (default: the user who ran sudo, else root)
#   --ssh-tag <name>  names the sshd drop-in and fail2ban jail file it writes
#                     (default: hardening)
#   -h, --help        this text
#
# SELF-CONTAINED ON PURPOSE. It knows nothing about the project deploying it, so
# it can be copied into an unrelated one as-is. Everything project-specific is
# one of the options above.
#
# What it does: a firewall denying inbound except SSH, unattended security
# updates, fail2ban, and key-only SSH.
#
# LOCKOUT SAFETY, which is the part worth copying. Every way this script used to
# be able to cut off the person running it was found by running it, not by
# reading it, and each now has a check:
#   * the firewall allows the port sshd ACTUALLY listens on, not "port 22"
#   * password SSH is only disabled when the person running this has a key
#   * the sshd drop-in is validated with `sshd -t` and removed if that fails,
#     and the service is RELOADED, not restarted, so this session survives
# It exits non-zero whenever it declined or failed to do something, so a
# provisioning run cannot mistake a half-hardened host for a hardened one.
set -euo pipefail

say()  { echo "==> [harden] $*"; }
die()  { echo "!! [harden] $*" >&2; exit 1; }
problems=0
warn() { echo "!! [harden] $*" >&2; problems=$((problems + 1)); }

usage() { sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

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

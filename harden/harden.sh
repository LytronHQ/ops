#!/usr/bin/env bash
#
# harden.sh — bring a fresh Linux host to a sane baseline. Idempotent; safe to
# run again to re-apply.
#
# SELF-CONTAINED ON PURPOSE. It knows nothing about the project deploying it, so
# it can be copied into an unrelated one as-is. Everything project-specific is an
# input:
#
#   HARDEN_ALLOW    extra inbound rules, "<source>:<port>[/proto]", space or
#                   comma separated. Everything else inbound is denied.
#                   e.g. HARDEN_ALLOW="10.0.0.0/16:8090 203.0.113.4:5432"
#   HARDEN_SSH_TAG  name for the sshd drop-in (default "hardening")
#   HARDEN_SKIP     space-separated steps to skip: firewall updates fail2ban ssh
#   HARDEN_SSH_KEY_CHECK
#                   "0" to disable password SSH even though the user running
#                   this has no authorised key (default "1": refuse)
#
#   ./harden.sh
#   HARDEN_ALLOW="10.0.0.0/16:8090" ./harden.sh
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

[ "$(id -u)" = "0" ] || die "must run as root"

skipped() { case " ${HARDEN_SKIP:-} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

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
allow="${HARDEN_ALLOW:-}"
for rule in ${allow//,/ }; do
  case "$rule" in *:*) ;; *) die "HARDEN_ALLOW entry '$rule' is not <source>:<port>[/proto]. Nothing was changed." ;; esac
  # Split on the LAST colon, so an IPv6 source (2001:db8::/32:5432) survives.
  src="${rule%:*}"; portproto="${rule##*:}"
  port="${portproto%%/*}"; proto="tcp"
  case "$portproto" in */*) proto="${portproto##*/}" ;; esac
  case "$port" in ''|*[!0-9]*) die "HARDEN_ALLOW entry '$rule': '$port' is not a port. Nothing was changed." ;; esac
  { [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; } || die "HARDEN_ALLOW entry '$rule': port $port is out of range. Nothing was changed."
  case "$proto" in tcp|udp) ;; *) die "HARDEN_ALLOW entry '$rule': protocol must be tcp or udp. Nothing was changed." ;; esac
  [ -n "$src" ] || die "HARDEN_ALLOW entry '$rule' has no source. Nothing was changed."
  rules+=("$src $port $proto")
done

# Whoever has to be able to log in again afterwards: the person running this.
operator="${SUDO_USER:-$(id -un)}"
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
    systemctl show -p Listen ssh.socket 2>/dev/null | grep -oE ':[0-9]+ ' | tr -d ': '
  } | sort -un
}

say "packages"
install_packages ufw unattended-upgrades fail2ban

if ! skipped firewall; then
  ports="$(ssh_ports)"
  [ -n "$ports" ] || die "cannot tell which port sshd listens on; not enabling a firewall that might cut it off"

  # Dry-run every extra rule first: ufw is the one that knows a valid source
  # address, and a rejection here still leaves the firewall as it was.
  for r in "${rules[@]}"; do
    read -r src port proto <<<"$r"
    out="$(ufw --dry-run allow from "$src" to any port "$port" proto "$proto" 2>&1)" \
      || die "ufw rejects HARDEN_ALLOW rule $src:$port/$proto: $out. Firewall not changed."
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
fi

if ! skipped fail2ban; then
  say "fail2ban"
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
fi

if ! skipped ssh; then
  if [ "${HARDEN_SSH_KEY_CHECK:-1}" != "0" ] && ! has_authorized_key; then
    # The session running this would survive, and the next login would not. A
    # VPS handed over as root + password is exactly this case.
    warn "SSH: NOT disabling password login — '$operator' has no authorised SSH key, so the next login would be refused. Add one (ssh-copy-id) and run this again, or set HARDEN_SSH_KEY_CHECK=0 if you log in as a different user who has one."
  else
    say "SSH: key-only (password auth off)"
    tag="${HARDEN_SSH_TAG:-hardening}"
    dropin="/etc/ssh/sshd_config.d/10-${tag}.conf"
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

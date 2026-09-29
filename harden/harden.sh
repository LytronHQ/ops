#!/usr/bin/env bash
#
# harden.sh — bring a fresh Ubuntu/Debian host to a sane baseline. Idempotent;
# safe to run again to re-apply.
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
#
#   ./harden.sh
#   HARDEN_ALLOW="10.0.0.0/16:8090" ./harden.sh
#
# What it does: ufw defaulting to deny inbound with SSH allowed, unattended
# security updates, fail2ban, and key-only SSH.
#
# LOCKOUT SAFETY, which is the part worth copying. The SSH change disables
# PASSWORD auth only — key login keeps working — and it is written as a drop-in,
# validated with `sshd -t`, and removed again if that validation fails. The
# service is then RELOADED, not restarted, so the session running this script is
# never dropped. It assumes you are connected with a key.
set -euo pipefail

[ "$(id -u)" = "0" ] || { echo "harden.sh must run as root" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive

skipped() { case " ${HARDEN_SKIP:-} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

echo "==> [harden] packages"
apt-get update -y
apt-get install -y ufw unattended-upgrades fail2ban

if ! skipped firewall; then
  echo "==> [harden] firewall: allow SSH only, deny other inbound"
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp

  # Extra inbound, if the caller asked for any. Nothing is opened by default:
  # a host that publishes no ports should be reachable on SSH and nothing else.
  # Assigned first: under `set -u` a bare ${HARDEN_ALLOW//,/ } on an unset
  # variable aborts the whole script, and "no extra rules" is the normal case for
  # every node that serves nothing.
  allow="${HARDEN_ALLOW:-}"
  for rule in ${allow//,/ }; do
    src="${rule%%:*}"; portproto="${rule#*:}"
    port="${portproto%%/*}"; proto="tcp"
    case "$portproto" in */*) proto="${portproto##*/}" ;; esac
    [ -n "$src" ] && [ -n "$port" ] || { echo "!! [harden] ignoring malformed HARDEN_ALLOW entry '$rule'" >&2; continue; }
    echo "==> [harden] allow ${src} -> ${port}/${proto}"
    ufw allow from "$src" to any port "$port" proto "$proto" >/dev/null 2>&1 || true
  done

  ufw --force default deny incoming
  ufw --force default allow outgoing
  ufw --force enable
fi

if ! skipped updates; then
  echo "==> [harden] automatic security updates"
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
fi

if ! skipped fail2ban; then
  echo "==> [harden] fail2ban"
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
fi

if ! skipped ssh; then
  echo "==> [harden] SSH: key-only (password auth off)"
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
  if sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  else
    echo "!! [harden] sshd config test failed — reverting SSH change, leaving auth untouched" >&2
    rm -f "$dropin"
  fi
fi

echo "==> [harden] done"

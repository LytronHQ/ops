#!/usr/bin/env bash
# harden_test.sh — run `server.sh harden` for real, as root, on a machine that
# will be thrown away, and check what it did — including that a new SSH login
# still works afterwards.
#
#   sudo env OPS_TEST_DISPOSABLE=1 server/tests/harden_test.sh
#
# It changes the firewall, sshd and packages of the machine it runs on, so it
# runs only when OPS_TEST_DISPOSABLE=1 says that machine is disposable — the CI
# runner — and as root. Anywhere else it exits 77: skipped, not passed.
#
# What it asserts:
#   1. a bad --allow rule stops the run before the firewall changes
#   2. a login user with no authorised key keeps password login, exit 1
#   3. with a key: firewall on with SSH and the --allow rule, everything else
#      denied; password login off; fail2ban's sshd jail running; exit 0
#   4. a NEW key login still works afterwards — the point of all the checks
#   5. running it again changes nothing and exits 0
set -euo pipefail

[ "${OPS_TEST_DISPOSABLE:-}" = 1 ] || { echo "changes the machine it runs on; set OPS_TEST_DISPOSABLE=1 on a disposable one"; exit 77; }
[ "$(id -u)" = 0 ] || { echo "needs root"; exit 77; }
command -v apt-get >/dev/null || { echo "Debian/Ubuntu only"; exit 77; }

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../server.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# sshd, if the machine has none — it is what harden protects.
if ! command -v sshd >/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get -qq install -y openssh-server >/dev/null
fi
mkdir -p /run/sshd
systemctl start ssh 2>/dev/null || systemctl start ssh.socket 2>/dev/null || true

# A user to log in as, with no key yet.
U=opstest
id "$U" >/dev/null 2>&1 || useradd -m -s /bin/bash "$U"
H="$(getent passwd "$U" | cut -d: -f6)"
rm -rf "$H/.ssh"

echo "== a bad rule stops the run before the firewall changes =="
before="$(ufw status 2>/dev/null | head -1 || true)"
out="$(bash "$SCRIPT" harden --login-user "$U" --allow 10.0.0.0/33:5432 2>&1)" && fail "a bad rule was accepted"
grep -q "Bad source address" <<<"$out" || fail "the bad rule was not named: $out"
[ "$(ufw status 2>/dev/null | head -1 || true)" = "$before" ] || fail "the firewall changed after a bad rule"

echo "== no key: password login is kept =="
out="$(bash "$SCRIPT" harden --login-user "$U" 2>&1)" && fail "disabled password login for a user with no key"
grep -q "NOT disabling password login — '$U' has no authorised SSH key" <<<"$out" || fail "not said: $out"
[ ! -e /etc/ssh/sshd_config.d/10-hardening.conf ] || fail "the SSH drop-in was written anyway"

echo "== with a key: hardened =="
K="$(mktemp -d)"; ssh-keygen -q -t ed25519 -N '' -f "$K/id"
install -d -m 700 -o "$U" -g "$U" "$H/.ssh"
install -m 600 -o "$U" -g "$U" "$K/id.pub" "$H/.ssh/authorized_keys"
out="$(bash "$SCRIPT" harden --login-user "$U" --allow 10.0.0.0/16:5432 2>&1)" || fail "harden failed: $out"
status="$(ufw status)"
grep -q '^Status: active' <<<"$status" || fail "the firewall is not on"
grep -qE '^22/tcp +ALLOW +Anywhere' <<<"$status" || fail "SSH is not allowed: $status"
grep -qE '^5432/tcp +ALLOW +10\.0\.0\.0/16' <<<"$status" || fail "the --allow rule is missing: $status"
ufw status verbose | grep -q 'deny (incoming)' || fail "inbound is not denied by default"
[ "$(sshd -T -C "user=$U,host=localhost,addr=127.0.0.1" | awk '$1 == "passwordauthentication" { print $2 }')" = no ] \
  || fail "password login is still on"
fail2ban-client status sshd >/dev/null 2>&1 || fail "fail2ban's sshd jail is not running"
grep -q "==> \[harden\] done" <<<"$out" || fail "it did not finish: $out"

echo "== a new key login still works =="
who="$(ssh -i "$K/id" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR "$U@127.0.0.1" whoami 2>&1)" || fail "SSH login failed after hardening: $who"
[ "$who" = "$U" ] || fail "logged in as '$who'"
# Which methods sshd offers, from its refusal: only publickey once hardened.
offered="$(ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive -o BatchMode=yes \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 \
  "$U@127.0.0.1" true 2>&1 || true)"
grep -q 'Permission denied (publickey)' <<<"$offered" || fail "the server still offers more than keys: $offered"

echo "== again: nothing changes =="
cp /etc/ssh/sshd_config.d/10-hardening.conf "$K/before.conf"; ufw status > "$K/before.ufw"
bash "$SCRIPT" harden --login-user "$U" --allow 10.0.0.0/16:5432 >/dev/null 2>&1 || fail "a second run failed"
cmp -s /etc/ssh/sshd_config.d/10-hardening.conf "$K/before.conf" || fail "a second run changed the SSH drop-in"
ufw status | cmp -s - "$K/before.ufw" || fail "a second run changed the firewall"

echo "PASS"

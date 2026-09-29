#!/usr/bin/env bash
#
# vmlab.sh — libvirt/KVM VMs on your own machine, with NO sudo and no
# virt-install: a lab of several for testing against real separate hosts, or a
# single one (a lab of one). Everything comes from what an unprivileged account
# already has:
#
#   * membership of the `libvirt` group  -> qemu:///system without sudo
#   * an ACL on /dev/kvm                 -> real acceleration
#   * libvirt's `default` network        -> 192.168.122.0/24
#
#   ./vmlab.sh create    # create + boot, print IPs
#   ./vmlab.sh ips       # name -> IP
#   ./vmlab.sh status    # name, state, RAM, IP
#   ./vmlab.sh stop      # shut the VMs down, keep them (frees the RAM)
#   ./vmlab.sh start     # boot them again
#   ./vmlab.sh destroy   # destroy, undefine, delete the disks
#
#   VMLAB_VMS="web-1:2048:2:40" ./vmlab.sh create    # one VM, 40 GB disk
#
# Then point whatever you are testing at the printed IPs. The guests are
# unmodified cloud images: cloud-init creates the user and nothing else.
#
# Env: VMLAB_KEY (private key; default the first of ~/.ssh/id_ed25519,
#                 id_ecdsa, id_rsa that has a .pub beside it)
#      VMLAB_USER (login user, default `dev`)
#      VMLAB_PREFIX (VM name prefix, default `vmlab-`)
#      VMLAB_IMAGE (cloud image URL)
#      VMLAB_LAUNCHPAD (Launchpad id whose SSH keys to authorise too)
#      VMLAB_VMS (the lab, "name:ram_mb:vcpu[:disk_gb] ...", default the VMS
#                 list below; disk defaults to 20 GB)
#      VMLAB_DIR (where disks live, default /var/tmp/vmlab)
#
# Prereqs: qemu-utils, genisoimage, libvirt-clients. No virtinst, no sudo.
set -euo pipefail

# Disks live outside $HOME on purpose: a 0750 home directory cannot be traversed
# by the qemu user, and the failure is an opaque permission error at domain start.
LAB="${VMLAB_DIR:-/var/tmp/vmlab}"
CONN="qemu:///system"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/vmlab"
IMAGE="${VMLAB_IMAGE:-https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img}"
CACHED="$CACHE/$(basename "$IMAGE")"
# The BACKING file every overlay reads from has to live beside them, not in the
# cache: qemu opens it as its own uid, and it cannot traverse a 0750 home
# directory. The cache is the download, this is the copy qemu actually reads.
BASE="$LAB/base.img"
# ssh-keygen has defaulted to ed25519 for years, so ~/.ssh/id_rsa alone missed
# most people's key.
KEY="${VMLAB_KEY:-}"
if [ -z "$KEY" ]; then
  for k in id_ed25519 id_ecdsa id_rsa; do
    [ -f "$HOME/.ssh/$k.pub" ] && { KEY="$HOME/.ssh/$k"; break; }
  done
fi
LAUNCHPAD="${VMLAB_LAUNCHPAD:-}"
USER_NAME="${VMLAB_USER:-dev}"
PREFIX="${VMLAB_PREFIX:-vmlab-}"

# name:ram_mb:vcpu[:disk_gb] — a database host and three small app hosts. `start` boots
# them in this order, so list first whatever the others depend on.
VMS=(
  "db:2048:2"
  "app1:1536:2"
  "app2:1536:2"
  "app3:1024:1"
)
# Overridable without editing: this file is fetched pinned and checksummed, and
# a local edit is both lost on the next version and indistinguishable from
# tampering. `destroy` needs the same value `create` had, to know what to remove.
if [ -n "${VMLAB_VMS:-}" ]; then
  read -r -a VMS <<<"${VMLAB_VMS//,/ }"
fi
for e in "${VMS[@]}"; do
  [[ "$e" =~ ^[a-z0-9][a-z0-9-]*:[0-9]+:[0-9]+(:[0-9]+)?$ ]] \
    || { echo "error: VMLAB_VMS entry '$e' is not name:ram_mb:vcpu[:disk_gb]" >&2; exit 1; }
done

die() { echo "error: $*" >&2; exit 1; }
log() { echo "$*" >&2; }
v() { virsh -c "$CONN" "$@"; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing '$1' — on Ubuntu/Debian: sudo apt install -y qemu-utils genisoimage libvirt-clients curl"; }

# Everything that can fail, checked before a 600 MB download rather than after.
preflight() {
  need qemu-img; need genisoimage; need virsh; need curl
  collect_keys
  v list >/dev/null 2>&1 \
    || die "cannot reach $CONN. Are you in the libvirt group? sudo usermod -aG libvirt \$USER, then log out and in"
  # Captured, not piped into grep -q: grep exits at the first match, virsh
  # takes SIGPIPE, and under pipefail an ACTIVE network then reads as inactive.
  local net; net="$(v net-info default 2>/dev/null || true)"
  [[ "$net" =~ Active:[[:space:]]+yes ]] \
    || die "libvirt network 'default' is not active: virsh -c $CONN net-start default (and net-autostart default)"
}

# The guests are key-only, so no key means no way in. Gather every key to
# authorise — the local one, Launchpad's, or both — and refuse to build a VM
# nobody can log into.
collect_keys() {
  AUTH_KEYS=""
  if [ -n "${VMLAB_KEY:-}" ] && [ ! -f "$KEY.pub" ]; then
    die "no public key at $KEY.pub (set VMLAB_KEY to a private key that has a .pub beside it)"
  fi
  if [ -n "$KEY" ] && [ -f "$KEY.pub" ]; then AUTH_KEYS="$(cat "$KEY.pub")"; fi
  if [ -n "$LAUNCHPAD" ]; then
    # Fetched here, on the host, and written into the seed — not ssh_import_id
    # inside the guest: Ubuntu *minimal* images do not ship ssh-import-id, and
    # there an in-guest import silently imports nothing.
    local lp
    lp="$(curl -fsSL "https://launchpad.net/~$LAUNCHPAD/+sshkeys" 2>/dev/null || true)"
    lp="$(printf '%s\n' "$lp" | grep -E '^(ssh-|ecdsa-|sk-)' || true)"
    [ -n "$lp" ] || die "Launchpad user '$LAUNCHPAD' has no SSH keys, or does not exist: https://launchpad.net/~$LAUNCHPAD/+sshkeys"
    AUTH_KEYS="$(printf '%s\n%s\n' "$AUTH_KEYS" "$lp" | sed '/^$/d')"
  fi
  [ -n "$AUTH_KEYS" ] || die "no SSH key found in ~/.ssh (id_ed25519, id_ecdsa, id_rsa). Make one with ssh-keygen, or set VMLAB_KEY or VMLAB_LAUNCHPAD"
}

create_one() { # name ram vcpu disk_gb
  local name="$PREFIX$1" ram="$2" cpu="$3" size="${4:-20}"
  local disk="$LAB/$name.qcow2" seed="$LAB/$name-seed.iso"

  if v dominfo "$name" >/dev/null 2>&1; then
    log "· $name already defined"
    return 0
  fi

  # A thin overlay on the shared base: each VM costs a few hundred MB, not 3.5G.
  # The size is only a ceiling; cloud-init grows the root partition to it.
  qemu-img create -q -f qcow2 -F qcow2 -b "$BASE" "$disk" "${size}G"

  # NoCloud seed. The label MUST be `cidata`, and it is attached as a virtio-blk
  # disk rather than a CD-ROM: a CD enumerates too late, so cloud-init's
  # ds-identify misses it at boot and disables itself entirely — no user, no
  # keys, no network.
  local work; work="$(mktemp -d)"
  cat > "$work/user-data" <<EOF
#cloud-config
hostname: $name
preserve_hostname: false
package_update: false
package_upgrade: false
ssh_pwauth: false
users:
  - name: $USER_NAME
    groups: [sudo]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
$(printf '%s\n' "$AUTH_KEYS" | sed 's/"/\\"/g; s/^/      - "/; s/$/"/')
EOF
  printf 'instance-id: %s\nlocal-hostname: %s\n' "$name" "$name" > "$work/meta-data"
  genisoimage -quiet -output "$seed" -volid cidata -joliet -rock \
    "$work/user-data" "$work/meta-data"
  rm -rf "$work"

  v define /dev/stdin >/dev/null <<EOF
<domain type='kvm'>
  <name>$name</name>
  <memory unit='MiB'>$ram</memory>
  <vcpu>$cpu</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features><acpi/><apic/></features>
  <cpu mode='host-passthrough'/>
  <clock offset='utc'/>
  <on_reboot>restart</on_reboot>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$disk'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='disk'>
      <driver name='qemu' type='raw'/>
      <source file='$seed'/>
      <target dev='vdb' bus='virtio'/>
      <readonly/>
    </disk>
    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'><target port='0'/></serial>
    <console type='pty'><target type='serial' port='0'/></console>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
    <memballoon model='virtio'/>
  </devices>
</domain>
EOF
  v start "$name" >/dev/null
  log "▶ created and started $name (${ram}MB, ${cpu} vCPU, ${size}G disk)"
}

names() { local e; for e in "${VMS[@]}"; do echo "$PREFIX${e%%:*}"; done; }

print_ips() { for n in $(names); do printf '%-14s %s\n' "$n" "$(ip_of "$n")"; done; }

ip_of() { # name
  # Ask the domain, not the network. Leases outlive their VMs by up to an hour,
  # and a new lab reuses the old names, so looking a lease up by hostname
  # returned the PREVIOUS lab's address — and the wait below was satisfied by
  # it at once. domifaddr matches on this domain's MAC, which is new each time.
  v -q domifaddr "$1" --source lease 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -1
}

case "${1:-status}" in
  -h|--help|help)
    sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
    ;;
  create)
    preflight
    mkdir -p "$LAB" "$CACHE"
    if [ ! -f "$CACHED" ]; then
      log "==> downloading $(basename "$IMAGE") (once; cached in $CACHE)"
      curl -fL --progress-bar "$IMAGE" -o "$CACHED.part" && mv "$CACHED.part" "$CACHED"
    fi
    if [ ! -f "$BASE" ]; then
      # --reflink=auto: free on a filesystem that supports it, a plain copy
      # otherwise. Either way it happens once per lab, not once per VM.
      cp --reflink=auto "$CACHED" "$BASE"
      chmod a+r "$BASE"
    fi
    for e in "${VMS[@]}"; do
      IFS=: read -r n ram cpu size <<<"$e"
      create_one "$n" "$ram" "$cpu" "$size"
    done
    log "==> waiting for DHCP leases"
    for _ in $(seq 1 60); do
      missing=0
      for n in $(names); do [ -n "$(ip_of "$n")" ] || missing=1; done
      [ "$missing" = "0" ] && break
      sleep 5
    done

    # Drop any host key left over for these addresses. The lab reuses the
    # 192.168.122.0/24 pool, so a previous lab's key for the same IP makes ssh
    # refuse outright — and `accept-new`, which the deploy uses, accepts unknown
    # hosts but never a CHANGED one. Cleaning here rather than only at teardown
    # is what makes it reliable: at this point the address is known and the VM is
    # new, so any existing key is stale by definition. Teardown misses whatever
    # was already destroyed by hand.
    for n in $(names); do
      ip="$(ip_of "$n")"
      [ -n "$ip" ] && ssh-keygen -R "$ip" >/dev/null 2>&1 || true
    done

    print_ips
    log ""
    if [ -n "$KEY" ] && [ -f "$KEY.pub" ]; then
      log "connect:  ssh -i $KEY $USER_NAME@<address>"
    else
      log "connect:  ssh $USER_NAME@<address>   (with a key from lp:$LAUNCHPAD)"
    fi
    log "(cloud-init may need a few more seconds after an address appears)"
    ;;
  ips) print_ips ;;
  status)
    total=0
    for e in "${VMS[@]}"; do
      IFS=: read -r n ram _ <<<"$e"; n="$PREFIX$n"
      # virsh prints a trailing blank line; without trimming, the table wraps.
      st="$(v domstate "$n" 2>/dev/null | head -1 || true)"
      [ "$st" = "running" ] && total=$((total + ram))
      printf '%-14s %-10s %6s MiB  %s\n' "$n" "${st:-undefined}" "$ram" "$(ip_of "$n")"
    done
    echo "running: ${total} MiB"
    ;;
  start)
    # In the order the lab lists them, so a VM others depend on comes up first.
    for n in $(names); do
      st="$(v domstate "$n" 2>/dev/null | head -1 || true)"
      case "$st" in
        "")      log "· $n does not exist (run: $0 create)" ;;
        running) log "· $n already running" ;;
        *)       v start "$n" >/dev/null && log "▶ started $n" ;;
      esac
    done
    ;;
  stop)
    for n in $(names); do
      [ "$(v domstate "$n" 2>/dev/null | head -1 || true)" = "running" ] \
        && v shutdown "$n" >/dev/null && log "⏻ shutting down $n"
    done
    # Wait for the guests to power off. Returning at once meant an immediate
    # `start` saw them still "running" and skipped them all.
    for _ in $(seq 1 60); do
      up=0
      for n in $(names); do [ "$(v domstate "$n" 2>/dev/null | head -1 || true)" = "running" ] && up=1; done
      [ "$up" = "0" ] && break
      sleep 2
    done
    [ "$up" = "0" ] || die "some VMs are still running after 2 minutes (force: virsh -c $CONN destroy <name>)"
    log "lab stopped; disks kept. '$0 start' boots it again, '$0 destroy' deletes it."
    ;;
  destroy)
    for n in $(names); do
      # The next lab reuses these addresses with new host keys, so leaving the
      # old ones behind turns the following run's first ssh into a hard failure.
      ip="$(ip_of "$n")"; [ -n "$ip" ] && ssh-keygen -R "$ip" >/dev/null 2>&1 || true
      v destroy "$n" >/dev/null 2>&1 || true
      v undefine "$n" --nvram >/dev/null 2>&1 || v undefine "$n" >/dev/null 2>&1 || true
      rm -f "$LAB/$n.qcow2" "$LAB/$n-seed.iso"
      log "✗ removed $n"
    done
    rm -f "$LAB/base.img"
    rmdir "$LAB" 2>/dev/null || true
    log "(base image kept in $CACHE so the next 'create' needs no download)"
    ;;
  *) die "usage: $0 {create|ips|status|start|stop|destroy|help}" ;;
esac

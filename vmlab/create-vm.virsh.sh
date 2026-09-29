#!/usr/bin/env bash
#
# create-vm.virsh.sh — a throwaway libvirt/KVM lab of several VMs, for testing
# against real separate hosts, with NO sudo and no virt-install.
#
# Part of the create-vm.<provider>.<ext> family. The sibling
# create-vm.virt-manager.sh creates ONE production-shaped VM and needs virtinst
# plus sudo (its disks land in /var/lib/libvirt/images, which is root-owned).
# This one creates a whole disposable LAB from what an unprivileged account
# already has:
#
#   * membership of the `libvirt` group  -> qemu:///system without sudo
#   * an ACL on /dev/kvm                 -> real acceleration
#   * libvirt's `default` network        -> 192.168.122.0/24
#
#   ./create-vm.virsh.sh up       # create + boot, print IPs
#   ./create-vm.virsh.sh ips      # name -> IP
#   ./create-vm.virsh.sh status
#   ./create-vm.virsh.sh down     # destroy, undefine, delete the disks
#
# Then point whatever you are testing at the printed IPs. The guests are
# unmodified cloud images: cloud-init creates the user and nothing else.
#
# Env: VMLAB_KEY (ssh key, default ~/.ssh/id_rsa)
#      VMLAB_USER (login user, default `dev`)
#      VMLAB_PREFIX (VM name prefix, default `vmlab-`)
#      VMLAB_IMAGE (cloud image URL)
#
# Prereqs: qemu-utils, genisoimage, libvirt-clients. No virtinst, no sudo.
set -euo pipefail

# Disks live outside $HOME on purpose: a 0750 home directory cannot be traversed
# by the qemu user, and the failure is an opaque permission error at domain start.
LAB="${VMLAB_DIR:-/var/tmp/vmlab}"
CONN="qemu:///system"
# Cached in the same place create-vm.virt-manager.sh caches, so the two scripts
# share one download.
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/vmlab"
IMAGE="${VMLAB_IMAGE:-https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img}"
CACHED="$CACHE/$(basename "$IMAGE")"
# The BACKING file every overlay reads from has to live beside them, not in the
# cache: qemu opens it as its own uid, and it cannot traverse a 0750 home
# directory. The cache is the download, this is the copy qemu actually reads.
BASE="$LAB/base.img"
KEY="${VMLAB_KEY:-$HOME/.ssh/id_rsa}"
USER_NAME="${VMLAB_USER:-dev}"
PREFIX="${VMLAB_PREFIX:-vmlab-}"

# name:ram_mb:vcpu — a database host and three small app hosts. Edit to suit;
# vms.virt-manager.sh starts anything named *db* first.
VMS=(
  "db:2048:2"
  "app1:1536:2"
  "app2:1536:2"
  "app3:1024:1"
)

die() { echo "error: $*" >&2; exit 1; }
log() { echo "$*" >&2; }
v() { virsh -c "$CONN" "$@"; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing '$1'"; }

create_one() { # name ram vcpu
  local name="$PREFIX$1" ram="$2" cpu="$3"
  local disk="$LAB/$name.qcow2" seed="$LAB/$name-seed.iso"

  if v dominfo "$name" >/dev/null 2>&1; then
    log "· $name already defined"
    return 0
  fi

  # A thin overlay on the shared base: each VM costs a few hundred MB, not 3.5G.
  qemu-img create -q -f qcow2 -F qcow2 -b "$BASE" "$disk" 20G

  # NoCloud seed. The label MUST be `cidata`, and it is attached as a virtio-blk
  # disk rather than a CD-ROM: a CD enumerates too late, so cloud-init's
  # ds-identify misses it at boot and disables itself entirely — no user, no
  # keys, no network. (The same lesson is written into
  # create-vm.virt-manager.sh.)
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
      - $(cat "$KEY.pub")
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
  log "▶ created and started $name (${ram}MB, ${cpu} vCPU)"
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
  up)
    need qemu-img; need genisoimage; need virsh; need curl
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
    [ -f "$KEY.pub" ] || die "no public key at $KEY.pub (set VMLAB_KEY)"
    for e in "${VMS[@]}"; do
      IFS=: read -r n ram cpu <<<"$e"
      create_one "$n" "$ram" "$cpu"
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
    ;;
  ips) print_ips ;;
  status)
    for n in $(names); do
      # virsh prints a trailing blank line; without trimming, the table wraps.
      st="$(v domstate "$n" 2>/dev/null | head -1 || true)"
      printf '%-14s %-10s %s\n' "$n" "${st:-undefined}" "$(ip_of "$n")"
    done
    ;;
  down)
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
    log "(base image kept in $CACHE so the next 'up' needs no download)"
    ;;
  *) die "usage: $0 {up|ips|status|down}" ;;
esac

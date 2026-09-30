#!/usr/bin/env bash
#
# vmlab.sh — libvirt/KVM VMs on your own machine, with NO sudo and no
# virt-install: a lab of several for testing against real separate hosts, or a
# single VM that stays.
#
# platforms: linux
#
#   ./vmlab.sh create                          # the default lab: db, app1, app2, app3
#   ./vmlab.sh create --name web-1 --memory 2048 --vcpu 2 --disk 40gb
#   ./vmlab.sh status                          # every vmlab VM: state, RAM, address
#   ./vmlab.sh stop  [--name web-1]            # shut down, keep the disks
#   ./vmlab.sh start [--name web-1]            # boot again
#   ./vmlab.sh destroy --name web-1            # delete one VM and its disks
#   ./vmlab.sh destroy --all                   # delete every vmlab VM
#   ./vmlab.sh ips                             # name -> address
#
# Options — every input is one; nothing else is read from the environment
# except HOME and XDG_CACHE_HOME, which say where your keys and cache are:
#   --name <name>      the VM to act on; repeatable. The VM is called
#                      <prefix><name>, so vmlab never touches a VM it did not
#                      make. Without it: create makes the default lab, and
#                      status/start/stop/ips act on every vmlab VM.
#   --all              destroy: every vmlab VM (destroy needs --name or --all)
#   --memory <size>    create: RAM, in MB or with mb/gb (default 2048)
#   --vcpu <n>         create: vCPUs (default 2)
#   --disk <size>      create: disk, in GB or with gb (default 20gb)
#   --key <path>       create: private key whose .pub is authorised (default:
#                      the first of ~/.ssh/id_ed25519, id_ecdsa, id_rsa)
#   --launchpad <id>   create: also authorise this Launchpad id's SSH keys;
#                      repeatable
#   --user <name>      create: login user, with passwordless sudo (default dev)
#   --image <url>      create: qcow2 cloud image (default Ubuntu 24.04)
#   --prefix <p>       VM name prefix (default vmlab-)
#   --dir <path>       where disks live (default /var/tmp/vmlab)
#   -h, --help         this text
#
# The guests are unmodified cloud images: cloud-init creates the user and
# nothing else.
#
# Needs: the `libvirt` group (qemu:///system without sudo), an ACL on
# /dev/kvm, libvirt's `default` network, and qemu-utils, genisoimage,
# libvirt-clients, curl.
set -euo pipefail
# set -e does not reach inside $(…) without this, so a die() there only ended
# the subshell: `--disk 40tb` was rejected, ignored, and a lab got built.
shopt -s inherit_errexit

die() { echo "error: $*" >&2; exit 1; }
log() { echo "$*" >&2; }
usage() { sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

# Sizes as a person types them: 40, 40g, 40gb, 40G. Sets SIZE_MB; a bare
# number is taken in the default unit, so "2048" is MB as memory and "40" is GB
# as disk. A variable, not output: run inside $(…), a die here would only end
# the subshell.
to_mb() { # flag value default-unit(mb|gb)
  local v="${2,,}" n
  n="${v%%[a-z]*}"
  [[ "$n" =~ ^[0-9]+$ ]] || die "$1 '$2' is not a size"
  case "${v#"$n"}" in
    "") [ "$3" = gb ] && n=$((n * 1024)) ;;
    m|mb|mib) ;;
    g|gb|gib) n=$((n * 1024)) ;;
    *) die "$1 '$2' is not a size (use mb or gb)" ;;
  esac
  SIZE_MB="$n"
}

CMD="${1:-status}"; [ $# -gt 0 ] && shift
case "$CMD" in -h|--help) CMD=help ;; esac
NAMES=() ALL=0 MEMORY=2048 VCPU=2 DISK_GB=20 KEY="" KEY_GIVEN=0 LAUNCHPADS=()
USER_NAME="dev" IMAGE="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
PREFIX="vmlab-" LAB="/var/tmp/vmlab"
while [ $# -gt 0 ]; do
  case "$1" in --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;; esac
  case "$1" in
    --name|--memory|--vcpu|--disk|--key|--launchpad|--user|--image|--prefix|--dir)
      [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value (try --help)" ;;
  esac
  case "$1" in
    --name)      [[ "$2" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "--name '$2': lower-case letters, digits and -"
                 NAMES+=("$2"); shift 2 ;;
    --all)       ALL=1; shift ;;
    --memory)    to_mb "$1" "$2" mb; MEMORY="$SIZE_MB"; shift 2 ;;
    --vcpu)      [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "--vcpu '$2' is not a number"; VCPU="$2"; shift 2 ;;
    --disk)      to_mb "$1" "$2" gb; DISK_GB=$((SIZE_MB / 1024))
                 [ "$DISK_GB" -ge 1 ] || die "--disk '$2' is under 1 GB"; shift 2 ;;
    --key)       KEY="$2"; KEY_GIVEN=1; shift 2 ;;
    --launchpad) LAUNCHPADS+=("$2"); shift 2 ;;
    --user)      USER_NAME="$2"; shift 2 ;;
    --image)     IMAGE="$2"; shift 2 ;;
    --prefix)    [[ "$2" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "--prefix '$2': lower-case letters, digits and -"
                 PREFIX="$2"; shift 2 ;;
    --dir)       LAB="$2"; shift 2 ;;
    -h|--help)   CMD=help; shift ;;
    *)           die "unknown argument '$1' (try --help)" ;;
  esac
done
[ -n "$LAB" ] || die "--dir is empty"

CONN="qemu:///system"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/vmlab"
CACHED="$CACHE/$(basename "$IMAGE")"
# Disks live outside $HOME on purpose: a 0750 home directory cannot be traversed
# by the qemu user, and the failure is an opaque permission error at domain start.
# The BACKING file every overlay reads from has to live beside them, not in the
# cache: qemu opens it as its own uid, and it cannot traverse a 0750 home
# directory. The cache is the download, this is the copy qemu actually reads.
BASE="$LAB/base.img"
# ssh-keygen has defaulted to ed25519 for years, so ~/.ssh/id_rsa alone missed
# most people's key.
if [ -z "$KEY" ]; then
  for k in id_ed25519 id_ecdsa id_rsa; do
    [ -f "$HOME/.ssh/$k.pub" ] && { KEY="$HOME/.ssh/$k"; break; }
  done
fi

# The default lab — name:ram_mb:vcpu — a database host and three small app
# hosts, created in this order.
DEFAULT_LAB=("db:2048:2" "app1:1536:2" "app2:1536:2" "app3:1024:1")

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
  if [ "$KEY_GIVEN" = "1" ] && [ ! -f "$KEY.pub" ]; then
    die "--key: no public key at $KEY.pub"
  fi
  if [ -n "$KEY" ] && [ -f "$KEY.pub" ]; then AUTH_KEYS="$(cat "$KEY.pub")"; fi
  local id lp
  for id in "${LAUNCHPADS[@]}"; do
    # Fetched here, on the host, and written into the seed — not ssh_import_id
    # inside the guest: Ubuntu *minimal* images do not ship ssh-import-id, and
    # there an in-guest import silently imports nothing.
    lp="$(curl -fsSL "https://launchpad.net/~$id/+sshkeys" 2>/dev/null || true)"
    lp="$(printf '%s\n' "$lp" | grep -E '^(ssh-|ecdsa-|sk-)' || true)"
    [ -n "$lp" ] || die "Launchpad user '$id' has no SSH keys, or does not exist: https://launchpad.net/~$id/+sshkeys"
    AUTH_KEYS="$(printf '%s\n%s\n' "$AUTH_KEYS" "$lp" | sed '/^$/d')"
  done
  [ -n "$AUTH_KEYS" ] || die "no SSH key found in ~/.ssh (id_ed25519, id_ecdsa, id_rsa). Make one with ssh-keygen, or pass --key or --launchpad"
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

# Every VM this script made: the prefix is how it knows.
lab_vms() { v list --all --name 2>/dev/null | grep -E "^${PREFIX}" || true; }

# The VMs a command acts on: those named, or every vmlab VM.
targets() {
  local n
  if [ "${#NAMES[@]}" -gt 0 ]; then
    for n in "${NAMES[@]}"; do echo "$PREFIX$n"; done
  else
    lab_vms
  fi
}

state() { v domstate "$1" 2>/dev/null | head -1 || true; }

print_ips() { local n; for n in $(targets); do printf '%-16s %s\n' "$n" "$(ip_of "$n")"; done; }

ip_of() { # name
  # Ask the domain, not the network. Leases outlive their VMs by up to an hour,
  # and a new lab reuses the old names, so looking a lease up by hostname
  # returned the PREVIOUS lab's address — and the wait below was satisfied by
  # it at once. domifaddr matches on this domain's MAC, which is new each time.
  v -q domifaddr "$1" --source lease 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -1
}

case "$CMD" in
  help)
    usage
    ;;
  create)
    # What to create: the named VMs at the given size, or the default lab.
    SPECS=()
    if [ "${#NAMES[@]}" -gt 0 ]; then
      for n in "${NAMES[@]}"; do SPECS+=("$n:$MEMORY:$VCPU:$DISK_GB"); done
    else
      SPECS=("${DEFAULT_LAB[@]}")
      for e in "${SPECS[@]}"; do NAMES+=("${e%%:*}"); done
    fi
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
    for e in "${SPECS[@]}"; do
      IFS=: read -r n ram cpu size <<<"$e"
      create_one "$n" "$ram" "$cpu" "$size"
    done
    log "==> waiting for DHCP leases"
    for _ in $(seq 1 60); do
      missing=0
      for n in $(targets); do [ -n "$(ip_of "$n")" ] || missing=1; done
      [ "$missing" = "0" ] && break
      sleep 5
    done

    # Drop any host key left over for these addresses. The lab reuses the
    # 192.168.122.0/24 pool, so a previous VM's key for the same IP makes ssh
    # refuse outright — and `accept-new` accepts unknown hosts but never a
    # CHANGED one. Cleaning here rather than only at teardown is what makes it
    # reliable: at this point the address is known and the VM is new, so any
    # existing key is stale by definition. Teardown misses whatever was already
    # destroyed by hand.
    for n in $(targets); do
      ip="$(ip_of "$n")"
      [ -n "$ip" ] && ssh-keygen -R "$ip" >/dev/null 2>&1 || true
    done

    print_ips
    log ""
    if [ -n "$KEY" ] && [ -f "$KEY.pub" ]; then
      log "connect:  ssh -i $KEY $USER_NAME@<address>"
    else
      log "connect:  ssh $USER_NAME@<address>   (with a key from lp:${LAUNCHPADS[0]})"
    fi
    log "(cloud-init may need a few more seconds after an address appears)"
    ;;
  ips)
    print_ips
    ;;
  status)
    total=0 any=0
    for n in $(targets); do
      any=1
      st="$(state "$n")"
      mem="$(v dominfo "$n" 2>/dev/null | awk '/^Max memory/ {print int($3 / 1024)}')"
      [ "$st" = "running" ] && total=$((total + ${mem:-0}))
      printf '%-16s %-10s %6s MiB  %s\n' "$n" "${st:-undefined}" "${mem:--}" "$(ip_of "$n")"
    done
    [ "$any" = "1" ] || log "no vmlab VMs (prefix '$PREFIX'). Make some: $0 create"
    echo "running: ${total} MiB"
    ;;
  start)
    # In the order given, so a VM others depend on can be named first.
    for n in $(targets); do
      case "$(state "$n")" in
        "")      log "· $n does not exist (run: $0 create --name ${n#"$PREFIX"})" ;;
        running) log "· $n already running" ;;
        *)       v start "$n" >/dev/null && log "▶ started $n" ;;
      esac
    done
    ;;
  stop)
    for n in $(targets); do
      [ "$(state "$n")" = "running" ] && v shutdown "$n" >/dev/null && log "⏻ shutting down $n"
    done
    # Wait for the guests to power off. Returning at once meant an immediate
    # `start` saw them still "running" and skipped them all.
    up=0
    for _ in $(seq 1 60); do
      up=0
      for n in $(targets); do [ "$(state "$n")" = "running" ] && up=1; done
      [ "$up" = "0" ] && break
      sleep 2
    done
    [ "$up" = "0" ] || die "some VMs are still running after 2 minutes (force: virsh -c $CONN destroy <name>)"
    log "stopped; disks kept. '$0 start' boots again, '$0 destroy' deletes."
    ;;
  destroy)
    # Deleting is the one command that must not default to everything.
    [ "${#NAMES[@]}" -gt 0 ] || [ "$ALL" = "1" ] \
      || die "destroy needs --name <name> or --all"
    for n in $(targets); do
      # The next VM reuses these addresses with new host keys, so leaving the
      # old ones behind turns the following run's first ssh into a hard failure.
      ip="$(ip_of "$n")"; [ -n "$ip" ] && ssh-keygen -R "$ip" >/dev/null 2>&1 || true
      v destroy "$n" >/dev/null 2>&1 || true
      v undefine "$n" --nvram >/dev/null 2>&1 || v undefine "$n" >/dev/null 2>&1 || true
      # ${…:?}: --dir is user input now, and an empty one must stop here rather
      # than turn these into paths at the root.
      rm -f "${LAB:?}/${n:?}.qcow2" "${LAB:?}/${n:?}-seed.iso"
      log "✗ removed $n"
    done
    # Every remaining VM's disk is an overlay reading from base.img, so it goes
    # only with the last of them. Deleting it after removing one VM would break
    # all the others at their next boot.
    if [ -z "$(lab_vms)" ]; then
      rm -f "${LAB:?}/base.img"
      rmdir "$LAB" 2>/dev/null || true
      log "(base image kept in $CACHE so the next 'create' needs no download)"
    fi
    ;;
  *)
    die "unknown command '$CMD'. Commands: create, destroy, start, stop, status, ips, help"
    ;;
esac

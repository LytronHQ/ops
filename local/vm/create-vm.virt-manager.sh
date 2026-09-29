#!/usr/bin/env bash
#
# create-vm.virt-manager.sh — create a minimal Ubuntu cloud VM under libvirt/KVM
# (the hypervisor virt-manager drives), with SSH keys imported from Launchpad.
#
# Part of the create-vm.<provider>.<ext> family: pick the file for your provider,
# no need to remember which command. This one = local libvirt/KVM.
# Siblings later: create-vm.gnome-boxes.sh, create-vm.virtualbox.ps1 (Windows), ...
#
# The VM is intentionally boring: an unmodified Ubuntu *cloud image*, no package
# updates or extra installs — cloud-init only creates the login user, imports its
# SSH keys from Launchpad (`lp:<id>`), sets the hostname, and disables password
# SSH. That keeps it a clean base you then deploy onto.
#
# Usage:
#   deploy/vm/create-vm.virt-manager.sh \
#     --name mon-eu --user dev \
#     --image https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img \
#     --cpu 2 --ram 2048 --disk 20
#
# Required: --name, --user, --image (a local path OR an https URL to an Ubuntu
#           *cloud* image; downloaded once and cached if a URL).
# Optional: --launchpad <id>  Launchpad id for SSH keys (default: --user)
#           --cpu <n>         vCPUs         (default 2)
#           --ram <MB>        memory in MB  (default 2048)
#           --disk <GB>       disk in GB    (default 20)
#           --os-variant <v>  libvirt osinfo id (default ubuntu24.04; see `osinfo-query os`)
# Env overrides: IMAGES_DIR (default /var/lib/libvirt/images), LIBVIRT_NETWORK (default default)
#
# Prereqs: virtinst qemu-utils libvirt-clients cloud-image-utils genisoimage; your
#          user in the `libvirt` and `kvm` groups; sudo (disk + seed land in the
#          libvirt images pool).
set -euo pipefail

NAME="" USER_NAME="" LAUNCHPAD="" IMAGE="" CPU=2 RAM=2048 DISK=20 OS_VARIANT="ubuntu24.04"
IMAGES_DIR="${IMAGES_DIR:-/var/lib/libvirt/images}"
NETWORK="${LIBVIRT_NETWORK:-default}"
CONN="qemu:///system"

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name)       NAME="${2:?}"; shift 2 ;;
    --user)       USER_NAME="${2:?}"; shift 2 ;;
    --launchpad)  LAUNCHPAD="${2:?}"; shift 2 ;;
    --image)      IMAGE="${2:?}"; shift 2 ;;
    --cpu)        CPU="${2:?}"; shift 2 ;;
    --ram)        RAM="${2:?}"; shift 2 ;;
    --disk)       DISK="${2:?}"; shift 2 ;;
    --os-variant) OS_VARIANT="${2:?}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "unknown argument: $1  (try --help)" ;;
  esac
done

[ -n "$NAME" ]      || die "--name is required"
[ -n "$USER_NAME" ] || die "--user is required"
[ -n "$IMAGE" ]     || die "--image is required (Ubuntu cloud image path or https URL)"
LAUNCHPAD="${LAUNCHPAD:-$USER_NAME}"

for c in virt-install qemu-img virsh curl; do
  command -v "$c" >/dev/null 2>&1 || die "missing '$c' — sudo apt install -y virtinst qemu-utils libvirt-clients cloud-image-utils curl"
done

virsh -c "$CONN" dominfo "$NAME" >/dev/null 2>&1 && die "a VM named '$NAME' already exists (virsh destroy/undefine it first)"
virsh -c "$CONN" -q net-info "$NETWORK" >/dev/null 2>&1 || die "libvirt network '$NETWORK' not found (try: virsh net-list --all)"

# --- pre-flight: the Launchpad account must actually have SSH keys -----------
# The VM is key-only; if lp:<id> imports zero keys, the login user has no way in
# and you're locked out. Fail here, before anything is built. (This is exactly
# the trap of defaulting --launchpad to a local username that isn't your LP id.)
echo "==> checking Launchpad SSH keys for lp:$LAUNCHPAD"
LP_KEYS="$(curl -fsSL "https://launchpad.net/~$LAUNCHPAD/+sshkeys" 2>/dev/null || true)"
printf '%s\n' "$LP_KEYS" | grep -qE '^(ssh-|ecdsa-|sk-)' \
  || die "Launchpad user '$LAUNCHPAD' has no SSH keys (or doesn't exist). Pass --launchpad <your-launchpad-id> — otherwise the key-only '$USER_NAME' user would have no way in. Check: https://launchpad.net/~$LAUNCHPAD/+sshkeys"

# Embed the keys directly (fetched here, on the host) rather than relying on
# ssh-import-id inside the guest — the Ubuntu *minimal* cloud images don't ship
# ssh-import-id, so an in-guest `ssh_import_id: [lp:...]` silently imports nothing.
AUTHORIZED_KEYS="$(printf '%s\n' "$LP_KEYS" | grep -E '^(ssh-|ecdsa-|sk-)' | sed 's/^/      - "/; s/$/"/')"

# best-effort: find the matching local private key, for a copy-paste ssh line
# that pins it (avoids 'too many authentication failures' when you have many keys)
SSH_KEY_OPT=""
for pub in "$HOME"/.ssh/*.pub; do
  [ -e "$pub" ] || continue
  b="$(awk '{print $2}' "$pub" 2>/dev/null)"
  [ -n "$b" ] && printf '%s' "$LP_KEYS" | grep -qF "$b" && { SSH_KEY_OPT="-o IdentitiesOnly=yes -i ${pub%.pub} "; break; }
done

# --- resolve the base image (download + cache if a URL) ---------------------
if [[ "$IMAGE" =~ ^https?:// ]]; then
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/vmlab"
  mkdir -p "$cache"
  BASE="$cache/$(basename "$IMAGE")"
  if [ -f "$BASE" ]; then
    echo "==> using cached image $BASE"
  else
    echo "==> downloading $IMAGE"
    curl -fL --progress-bar "$IMAGE" -o "$BASE.part" && mv "$BASE.part" "$BASE"
  fi
else
  BASE="$IMAGE"
  [ -f "$BASE" ] || die "image not found: $BASE"
fi

# --- cloud-init NoCloud seed: user + Launchpad keys + hostname, nothing else -
# Delivery matters as much as content (learned the hard way on Ubuntu *minimal*):
#   * We build our own seed ISO — volume label MUST be "cidata" — carrying
#     user-data + meta-data, and attach it as an early **virtio disk**.
#   * NOT `virt-install --cloud-init` and NOT an SMBIOS "ds=nocloud" serial:
#     both hand cloud-init an EMPTY dmi seed that satisfies NoCloud, so it never
#     reads our data (boots "seed=dmi", no user/keys).
#   * NOT a SATA CD-ROM: it enumerates too late, so cloud-init's boot-time
#     ds-identify misses the cidata label, finds no datasource, and DISABLES
#     cloud-init entirely (no user, no netplan, no network).
#   A virtio-blk disk is present before ds-identify runs, so it detects the
#   cidata label and NoCloud reads the real seed.
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/user-data" <<EOF
#cloud-config
hostname: $NAME
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
$AUTHORIZED_KEYS
EOF
cat > "$WORK/meta-data" <<EOF
instance-id: $NAME
local-hostname: $NAME
EOF

echo "==> building cloud-init seed (NoCloud, label=cidata)"
if command -v cloud-localds >/dev/null 2>&1; then
  cloud-localds "$WORK/seed.iso" "$WORK/user-data" "$WORK/meta-data"
elif command -v genisoimage >/dev/null 2>&1; then
  genisoimage -quiet -output "$WORK/seed.iso" -volid cidata -joliet -rock "$WORK/user-data" "$WORK/meta-data"
elif command -v mkisofs >/dev/null 2>&1; then
  mkisofs -quiet -output "$WORK/seed.iso" -volid cidata -joliet -rock "$WORK/user-data" "$WORK/meta-data"
else
  die "need cloud-localds, genisoimage, or mkisofs to build the seed — sudo apt install -y cloud-image-utils genisoimage"
fi

# --- per-VM disk + seed into the libvirt images pool ------------------------
# libvirt (dynamic_ownership) chowns attached volumes to the qemu user when the
# domain starts, so root-owned copies in the images pool are fine.
DISK_PATH="$IMAGES_DIR/$NAME.qcow2"
SEED_PATH="$IMAGES_DIR/$NAME-seed.iso"
[ -e "$DISK_PATH" ] && die "disk already exists: $DISK_PATH"
echo "==> creating disk $DISK_PATH (${DISK}G) from $(basename "$BASE")"
sudo cp --reflink=auto "$BASE" "$DISK_PATH"
sudo qemu-img resize "$DISK_PATH" "${DISK}G"
sudo cp "$WORK/seed.iso" "$SEED_PATH"

# --- create + boot the VM ---------------------------------------------------
echo "==> virt-install $NAME (${CPU} vCPU, ${RAM}MB, net=$NETWORK)"
virt-install \
  --connect "$CONN" \
  --name "$NAME" \
  --memory "$RAM" \
  --vcpus "$CPU" \
  --disk "path=$DISK_PATH,format=qcow2,bus=virtio" \
  --disk "path=$SEED_PATH,format=raw,bus=virtio,readonly=on" \
  --os-variant "$OS_VARIANT" \
  --import \
  --network "network=$NETWORK,model=virtio" \
  --graphics none \
  --noautoconsole

# --- report the DHCP-assigned IP (read from the network's leases) -----------
echo -n "==> waiting for IP (cloud-init runs on first boot) "
IP=""
for _ in $(seq 1 60); do
  IP="$(virsh -c "$CONN" -q domifaddr "$NAME" --source lease 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -1)"
  [ -n "$IP" ] && break
  echo -n "."; sleep 2
done
echo

if [ -n "$IP" ]; then
  cat <<EOF

VM '$NAME' is up.
  IP:   $IP
  SSH:  ssh ${SSH_KEY_OPT}$USER_NAME@$IP        (key-only; keys from lp:$LAUNCHPAD)

Deploy onto it: set up deploy/dev.env (copy deploy/dev.env.example — it also
needs SSH_KEY, PB_URL and the worker PB creds), with:
  SSH_USER=$USER_NAME
  SSH_KEY=<the private key whose pubkey is on lp:$LAUNCHPAD>
  NODES="
  worker $IP eu
  "
then: deploy onto the printed IPs

(Headless VM — virt-manager's graphical console stays black by design;
 use 'virsh console $NAME' for a terminal, Ctrl-] to exit.)
EOF
else
  cat <<EOF

VM '$NAME' was created but no IP yet (cloud-init may still be importing keys).
Check again in a moment:  virsh domifaddr $NAME --source lease
Console:                  virsh console $NAME     (Ctrl-] to exit)
EOF
fi

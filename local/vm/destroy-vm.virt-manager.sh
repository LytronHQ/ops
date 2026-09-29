#!/usr/bin/env bash
#
# destroy-vm.virt-manager.sh — tear down a VM made by create-vm.virt-manager.sh:
# force it off, undefine it, and delete its disks (the qcow2 + the cloud-init seed).
# Part of the create-vm.<provider>.<ext> family — same provider suffix, opposite verb.
#
#   deploy/vm/destroy-vm.virt-manager.sh mon-w-eu
#   deploy/vm/destroy-vm.virt-manager.sh --name mon-w-eu --yes    # no prompt
set -euo pipefail

CONN="qemu:///system"
NAME="" ASSUME_YES=0
die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name)    NAME="${2:?}"; shift 2 ;;
    -y|--yes)  ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        die "unknown argument: $1  (try --help)" ;;
    *)         NAME="$1"; shift ;;
  esac
done

[ -n "$NAME" ] || die "usage: $0 <vm-name> [--yes]"
command -v virsh >/dev/null 2>&1 || die "missing 'virsh'"
virsh -c "$CONN" dominfo "$NAME" >/dev/null 2>&1 || die "no such VM: '$NAME'  (see: virsh list --all)"

echo "About to destroy VM '$NAME' and DELETE its storage:"
virsh -c "$CONN" domblklist "$NAME" | awk 'NR>2 && $2 != "" && $2 != "-" {print "  - " $2}'
if [ "$ASSUME_YES" != "1" ]; then
  printf "Proceed? [y/N] "; read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "aborted."; exit 0 ;; esac
fi

[ "$(virsh -c "$CONN" domstate "$NAME" 2>/dev/null || true)" = "running" ] && virsh -c "$CONN" destroy "$NAME"
# --nvram also clears UEFI varstore; fall back for VMs/virsh without it.
virsh -c "$CONN" undefine "$NAME" --remove-all-storage --nvram 2>/dev/null \
  || virsh -c "$CONN" undefine "$NAME" --remove-all-storage

echo "Removed '$NAME'."

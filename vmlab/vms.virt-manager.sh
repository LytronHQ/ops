#!/usr/bin/env bash
#
# vms.virt-manager.sh — power a group of dev VMs on/off (libvirt/KVM),
# so you can free their RAM when you're not using them. Acts on every VM whose
# name starts with the prefix (default "vmlab-", what
# create-vm.virsh.sh names its lab), leaving unrelated VMs alone.
#
#   ./vms.virt-manager.sh up        # start them all (skips already-running)
#   ./vms.virt-manager.sh down      # graceful shutdown of the running ones
#   ./vms.virt-manager.sh status    # name · state · RAM
#   ./vms.virt-manager.sh down web-     # only VMs matching a custom prefix
#
# Env: VM_PREFIX overrides the default "vmlab-".
set -euo pipefail

CONN="qemu:///system"
CMD="${1:-status}"
PREFIX="${2:-${VM_PREFIX:-vmlab-}}"

die() { echo "error: $*" >&2; exit 1; }
# Before looking for VMs: with none defined, that lookup fails, and help is
# most needed exactly when you have none yet.
case "$CMD" in -h|--help|help) sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;; esac
command -v virsh >/dev/null 2>&1 || die "missing 'virsh'"

mapfile -t VMS < <(virsh -c "$CONN" list --all --name 2>/dev/null | grep -E "^${PREFIX}" || true)
[ "${#VMS[@]}" -gt 0 ] || die "no VMs matching '${PREFIX}*' (see: virsh list --all)"

state() { virsh -c "$CONN" domstate "$1" 2>/dev/null || echo "unknown"; }

case "$CMD" in
	up|start)
		# Bring anything matching *db* up first; the rest usually depend on it.
		db=(); rest=()
		for v in "${VMS[@]}"; do [[ "$v" == *db* ]] && db+=("$v") || rest+=("$v"); done
		for v in "${db[@]}" "${rest[@]}"; do
			if [ "$(state "$v")" = "running" ]; then
				echo "· $v already running"
			else
				virsh -c "$CONN" start "$v" >/dev/null && echo "▶ started $v"
			fi
		done
		;;
	down|stop)
		for v in "${VMS[@]}"; do
			if [ "$(state "$v")" = "running" ]; then
				virsh -c "$CONN" shutdown "$v" >/dev/null && echo "⏻ shutting down $v"
			else
				echo "· $v not running"
			fi
		done
		echo "(graceful ACPI shutdown — RAM frees as each guest powers off; check: $0 status)"
		;;
	status)
		printf "%-16s %-10s %s\n" "VM" "STATE" "RAM"
		total=0
		for v in "${VMS[@]}"; do
			st="$(state "$v")"
			mem_kib="$(virsh -c "$CONN" dominfo "$v" 2>/dev/null | awk -F': *' '/Max memory/{print $2}' | awk '{print $1}')"
			mem_mib=$(( ${mem_kib:-0} / 1024 ))
			[ "$st" = "running" ] && total=$(( total + mem_mib ))
			printf "%-16s %-10s %s MiB\n" "$v" "$st" "$mem_mib"
		done
		echo "-----"
		echo "running RAM total: ${total} MiB"
		;;
	*)
		die "unknown command '$CMD' (use: up | down | status)"
		;;
esac

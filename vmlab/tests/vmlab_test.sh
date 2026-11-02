#!/usr/bin/env bash
# vmlab_test.sh — check vmlab.sh refuses a lab directory it does not control
# (LytronHQ/ops#105). Nothing here reaches libvirt: virsh is a stub that fails.
#
#   vmlab/tests/vmlab_test.sh
#
# What it asserts:
#   1. a --dir writable by group or others is refused, naming why
#   2. a --dir that is a symlink is refused
#   3. a --dir owned by the caller with mode 0755 passes the check
#   4. --help works whatever the lab directory is
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../vmlab.sh"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$W/bin"
printf '#!/bin/sh\nexit 1\n' > "$W/bin/virsh"; chmod +x "$W/bin/virsh"
run() { PATH="$W/bin:$PATH" HOME="$W" bash "$SCRIPT" "$@" 2>&1 </dev/null; }

echo "== a group/other-writable lab directory is refused =="
mkdir -m 0777 "$W/shared"; chmod 0777 "$W/shared"
out="$(run status --dir "$W/shared")" && fail "accepted a 0777 lab directory"
grep -q "writable by group or others" <<<"$out" || fail "0777: unexpected message: $out"
out="$(run create --name db --dir "$W/shared")" && fail "create accepted a 0777 lab directory"
grep -q "writable by group or others" <<<"$out" || fail "create 0777: unexpected message: $out"

echo "== a symlinked lab directory is refused =="
mkdir -m 0755 "$W/real"; ln -s "$W/real" "$W/link"
out="$(run status --dir "$W/link")" && fail "accepted a symlinked lab directory"
grep -q "not a directory (or a symlink)" <<<"$out" || fail "symlink: unexpected message: $out"

echo "== a private lab directory passes the check =="
mkdir -m 0755 "$W/mine"
out="$(run status --dir "$W/mine" || true)"
grep -q -- "--dir $W/mine is" <<<"$out" && fail "a private 0755 directory was refused: $out"

echo "== --help works whatever the lab directory is =="
run --help --dir "$W/shared" >/dev/null || fail "--help failed on a refused lab directory"

echo PASS

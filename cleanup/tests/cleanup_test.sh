#!/usr/bin/env bash
# cleanup_test.sh — run cleanup.sh against a fake system under --root and
# check that it removes exactly the junk, and nothing else.
#
#   cleanup/tests/cleanup_test.sh
#
# apt-get is the REAL one, cleaning a cache under the fake root. pacman's and
# dnf's caches are checked for what would be reported: the tools themselves are
# not on a Debian machine, and were run in Fedora and Arch containers instead.
#
# What it asserts:
#   1. a report deletes nothing
#   2. --apply removes the junk in each category, and what it reports as freed
#      is what went
#   3. it never touches user files, protected temp directories, the current
#      log, or anything younger than the age limit
#   4. pacman's cache is sized by pacman -Sc's rule: installed versions stay
#   5. a category whose tool fails is named and fails the run
#   6. --only, --skip, formats, and bad input
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../cleanup.sh"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v apt-get >/dev/null || { echo "needs apt-get (Debian/Ubuntu)" >&2; exit 1; }

R="$W/root"
mk() { mkdir -p "$(dirname "$1")"; head -c "${2:-1000}" /dev/zero > "$1"; }

# junk
mk "$R/var/cache/apt/archives/a_1.0_amd64.deb" 5000
mk "$R/var/cache/apt/archives/b_2.0_amd64.deb" 3000
mk "$R/var/cache/apt/archives/partial/c_1.0_amd64.deb" 700
mk "$R/var/cache/apt/pkgcache.bin" 400
mkdir -p "$R/var/lib/apt/lists/partial" "$R/var/lib/dpkg" "$R/etc/apt/apt.conf.d" "$R/etc/apt/preferences.d" "$R/etc/apt/sources.list.d"
touch "$R/var/lib/dpkg/status" "$R/etc/apt/sources.list"
mk "$R/tmp/old.bin" 2000
mk "$R/tmp/nested/deeper/old.txt" 10
mk "$R/var/tmp/old.bin" 3000
mk "$R/var/log/syslog.1" 600
mk "$R/var/log/nginx/access.log.2.gz" 300
mk "$R/var/crash/app.crash" 900
mk "$R/var/lib/systemd/coredump/core.app.1" 800
mk "$R/home/alice/.cache/thumbnails/normal/a.png" 250
mk "$R/root/.cache/thumbnails/large/b.png" 150
# what must survive
mk "$R/home/alice/Downloads/keep.iso" 10
mk "$R/home/alice/.local/share/Trash/files/keep.txt" 10
mk "$R/home/alice/.cache/other/keep.cache" 10
mk "$R/tmp/systemd-private-abc-nginx.service-xyz/tmp/keep" 10
mk "$R/tmp/.X11-unix/X0" 10
mk "$R/var/log/syslog" 10
mk "$R/var/log/journal/keep.journal" 10
mk "$R/var/cache/apt/archives/lock" 0

snapshot() { (cd "$R" && find . -type f | sort); }
run() { bash "$SCRIPT" --root "$R" "$@" 2>"$W/stderr"; }
row() { run --format tsv "$@" | awk -F'\t' -v c="$CAT" '$1 == c'; }

echo "== a report deletes nothing =="
before="$(snapshot)"
out="$(run --older-than 0)"
[ "$(snapshot)" = "$before" ] || fail "a report changed files"
grep -q "nothing was deleted" "$W/stderr" || fail "the report did not say it deleted nothing"

echo "== the default age keeps everything just made =="
for CAT in temp rotated-logs crash-dumps; do
  [ "$(row --only "$CAT" | cut -f3)" = 0 ] || fail "$CAT selected a file younger than its age limit"
done

echo "== sizes =="
CAT=package-cache; [ "$(row | cut -f2,3)" = $'9100\t4' ] || fail "package-cache size: $(row)"
CAT=temp;          [ "$(row --older-than 0 | cut -f2,3)" = $'5010\t3' ] || fail "temp size: $(row --older-than 0)"
CAT=rotated-logs;  [ "$(row --older-than 0 | cut -f2,3)" = $'900\t2' ] || fail "rotated-logs: $(row --older-than 0)"
CAT=crash-dumps;   [ "$(row --older-than 0 | cut -f2,3)" = $'1700\t2' ] || fail "crash-dumps: $(row --older-than 0)"
CAT=thumbnails;    [ "$(row | cut -f2,3)" = $'400\t2' ] || fail "thumbnails: $(row)"

echo "== --apply removes the junk, and reports what went =="
out="$(run --apply --older-than 0 --format tsv)"
for c in package-cache:9100 temp:5010 rotated-logs:900 crash-dumps:1700 thumbnails:400; do
  [ "$(awk -F'\t' -v c="${c%%:*}" '$1 == c { print $2 }' <<<"$out")" = "${c#*:}" ] || fail "freed for ${c%%:*}: $out"
done
left="$(snapshot)"
for gone in var/cache/apt/archives/a_1.0_amd64.deb var/cache/apt/archives/partial/c_1.0_amd64.deb tmp/old.bin \
            var/tmp/old.bin var/log/syslog.1 var/log/nginx/access.log.2.gz var/crash/app.crash \
            var/lib/systemd/coredump/core.app.1 home/alice/.cache/thumbnails/normal/a.png root/.cache/thumbnails/large/b.png; do
  grep -qx "./$gone" <<<"$left" && fail "$gone is still there"
done
[ ! -d "$R/tmp/nested" ] || fail "emptied old directories were left in /tmp"
for kept in home/alice/Downloads/keep.iso home/alice/.local/share/Trash/files/keep.txt home/alice/.cache/other/keep.cache \
            tmp/systemd-private-abc-nginx.service-xyz/tmp/keep tmp/.X11-unix/X0 var/log/syslog var/log/journal/keep.journal; do
  grep -qx "./$kept" <<<"$left" || fail "$kept was deleted"
done

echo "== pacman: what pacman -Sc removes, nothing installed =="
P="$W/pac"
mk "$P/var/cache/pacman/pkg/nano-9.2-1-x86_64.pkg.tar.zst" 4000
mk "$P/var/cache/pacman/pkg/nano-9.2-1-x86_64.pkg.tar.zst.sig" 100
mk "$P/var/cache/pacman/pkg/tree-2.3.2-1-x86_64.pkg.tar.zst" 5000
mk "$P/var/cache/pacman/pkg/lib32-gcc-libs-15.1.1+r7-1-x86_64.pkg.tar.zst" 6000
# Last in the cache, not installed and without a signature: that combination
# once made the whole category fail to size.
mk "$P/var/cache/pacman/pkg/zstd-1.5.7-1-x86_64.pkg.tar.zst" 900
mkdir -p "$P/var/lib/pacman/local/tree-2.3.2-1" "$P/var/lib/pacman/local/lib32-gcc-libs-15.1.1+r7-1"
out="$(bash "$SCRIPT" --root "$P" --only package-cache --format tsv 2>"$W/stderr" | tail -1)" \
  || fail "sizing the pacman cache failed: $(cat "$W/stderr")"
[ "$(cut -f2,3 <<<"$out")" = $'5000\t3' ] || fail "pacman cache should be nano, its signature and zstd: $out"

echo "== dnf: cached packages =="
D="$W/dnf"
mk "$D/var/cache/libdnf5/fedora-1234/packages/tree-2.2.1-1.fc44.x86_64.rpm" 7000
mk "$D/var/cache/libdnf5/fedora-1234/repodata/primary.xml.zst" 300
out="$(bash "$SCRIPT" --root "$D" --only package-cache --format tsv 2>/dev/null | tail -1)"
[ "$(cut -f2,3 <<<"$out")" = $'7000\t1' ] || fail "dnf cache: $out"

echo "== a tool that fails is named and fails the run =="
mk "$R/var/cache/apt/archives/again_1.0_amd64.deb" 100
mkdir -p "$W/bin"; printf '#!/bin/sh\necho "E: Could not lock" >&2; exit 100\n' > "$W/bin/apt-get"; chmod +x "$W/bin/apt-get"
PATH="$W/bin:$PATH" bash "$SCRIPT" --root "$R" --apply --only package-cache >/dev/null 2>"$W/stderr" && fail "a failed apt-get did not fail the run"
grep -q "could not clean package-cache" "$W/stderr" || fail "not named: $(cat "$W/stderr")"

echo "== --only, --skip, formats, bad input =="
[ "$(run --only temp,journal --format tsv | tail -n +2 | cut -f1 | tr '\n' ' ')" = "temp journal " ] || fail "--only"
run --skip package-cache --format tsv | cut -f1 | grep -qx package-cache && fail "--skip"
run --format json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["applied"] is False and len(d["categories"]) == 6' \
  || fail "json"
bad() { local want="$1" out; shift; out="$(bash "$SCRIPT" "$@" 2>&1)" && fail "accepted: $*"; grep -q -- "$want" <<<"$out" || fail "$*: $out"; }
bad "unknown category 'tmp'"   --root "$R" --only tmp
bad "is not a number of days"  --root "$R" --older-than week
bad "a size like 500M"         --root "$R" --journal-max lots
bad "unknown argument"         --root "$R" --bogus
if [ "$(id -u)" != 0 ]; then
  bad "--apply needs root" --apply
fi

echo "PASS"

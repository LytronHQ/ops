#!/usr/bin/env bash
# inventory_test.sh — run inventory.sh against a fake system under --root and
# check what it reports: which package manager, installed on purpose or not,
# updates, the saved list and its rules.
#
#   inventory/tests/inventory_test.sh
#
# dpkg and apt are the REAL ones (this runs on Debian/Ubuntu, as CI does),
# reading a status file, a repository index and apt's marks built here.
# pacman's database is plain files, so it is real too. rpm and dnf are fakes on
# PATH, since neither is on a Debian machine.
#
# What it asserts:
#   1. apt vs dpkg: from a repository, or a .deb no repository has
#   2. explicit vs dependency, for apt, pacman and rpm
#   3. updates known locally, install dates, epochs hidden, keys skipped
#   4. manual: /usr/local/bin and /opt, except what a package owns
#   5. table, wide, tsv and json, and every filter
#   6. the saved list: always in full, read back, stale warning, --refresh,
#      --no-cache, and never overwriting a file that is not an inventory
#   7. without apt's package lists, nothing is called a hand-installed .deb
#   8. bad input fails
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../inventory.sh"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v dpkg-query >/dev/null && command -v apt >/dev/null \
  || { echo "needs dpkg-query and apt (Debian/Ubuntu)" >&2; exit 1; }

R="$W/root"
mkdir -p "$R/var/lib/dpkg/info" "$R/var/lib/dpkg/updates" "$R/var/lib/apt/lists/partial" \
         "$R/etc/apt/sources.list.d" "$R/etc/apt/apt.conf.d" "$R/etc/apt/preferences.d" \
         "$R/var/cache/apt/archives/partial" "$R/usr/local/bin" "$R/opt"

# --- dpkg: three installed packages, and one removed ---------------------------
cat > "$R/var/lib/dpkg/status" <<'EOF'
Package: fromrepo
Status: install ok installed
Priority: optional
Architecture: amd64
Version: 1.0
Installed-Size: 2048
Maintainer: t <t@example.com>
Description: A Package From The Repository

Package: handmade
Status: install ok installed
Priority: optional
Architecture: all
Version: 0.1
Maintainer: t <t@example.com>
Description: built by hand

Package: somelib
Status: install ok installed
Priority: optional
Architecture: amd64
Version: 2.0
Maintainer: t <t@example.com>
Description: pulled in as a dependency

Package: gone
Status: deinstall ok config-files
Priority: optional
Architecture: amd64
Version: 9.9
Maintainer: t <t@example.com>
Description: removed, config left behind

EOF
touch "$R/var/lib/dpkg/available"
printf '/.\n/opt\n/opt/owned-app\n' > "$R/var/lib/dpkg/info/fromrepo.list"
: > "$R/var/lib/dpkg/info/handmade.list"
: > "$R/var/lib/dpkg/info/somelib.list"
touch -d 2026-01-02 "$R/var/lib/dpkg/info/fromrepo.list"

# --- apt: a repository with a newer fromrepo, and somelib marked automatic ----
echo "deb [trusted=yes] http://repo.invalid/debian stable main" > "$R/etc/apt/sources.list"
LISTS="$R/var/lib/apt/lists/repo.invalid_debian_dists_stable_main_binary-amd64_Packages"
cat > "$LISTS" <<'EOF'
Package: fromrepo
Architecture: amd64
Version: 1.1
Filename: pool/f/fromrepo_1.1_amd64.deb
Size: 1
Description: A Package From The Repository

Package: fromrepo
Architecture: amd64
Version: 1.0
Filename: pool/f/fromrepo_1.0_amd64.deb
Size: 1
Description: A Package From The Repository

Package: somelib
Architecture: amd64
Version: 2.0
Filename: pool/s/somelib_2.0_amd64.deb
Size: 1
Description: pulled in as a dependency
EOF
printf 'Package: somelib\nArchitecture: amd64\nAuto-Installed: 1\n\n' > "$R/var/lib/apt/extended_states"

# --- pacman: one explicit, one dependency -------------------------------------
mkdir -p "$R/var/lib/pacman/local/ripgrep-14.1.0-1" "$R/var/lib/pacman/local/pcre2-10.44-1"
printf '%%NAME%%\nripgrep\n\n%%VERSION%%\n14.1.0-1\n\n%%DESC%%\nA search tool\n\n%%ARCH%%\nx86_64\n\n%%INSTALLDATE%%\n1767312000\n\n%%SIZE%%\n4194304\n\n' \
  > "$R/var/lib/pacman/local/ripgrep-14.1.0-1/desc"
printf '%%NAME%%\npcre2\n\n%%VERSION%%\n10.44-1\n\n%%DESC%%\nRegex library\n\n%%ARCH%%\nx86_64\n\n%%INSTALLDATE%%\n1767312000\n\n%%SIZE%%\n1048576\n\n%%REASON%%\n1\n\n' \
  > "$R/var/lib/pacman/local/pcre2-10.44-1/desc"

# --- manual: a binary and a directory no package owns, one directory owned ----
printf '#!/bin/sh\n' > "$R/usr/local/bin/mytool"; chmod +x "$R/usr/local/bin/mytool"
mkdir -p "$R/opt/curl-sh-app" "$R/opt/owned-app"

# --- rpm and dnf: fakes, on PATH only where asked -----------------------------
mkdir -p "$W/rpmbin"
cat > "$W/rpmbin/rpm" <<'EOF'
#!/bin/sh
for a in "$@"; do case "$a" in -qf|-qo) exit 1 ;; esac; done    # owns no files
printf 'curl\t0:8.9.1-2.fc41\tx86_64\t524288\t1767312000\tFedora Project\ta URL tool\n'
printf 'gpg-pubkey\t0:abc-def\t(none)\t0\t1767312000\t(none)\tpublic key\n'
printf 'vim-enhanced\t2:9.1.1-1.fc41\tx86_64\t4194304\t1767312000\tFedora Project\tthe editor\n'
EOF
printf '#!/bin/sh\necho vim-enhanced\n' > "$W/rpmbin/dnf"
chmod +x "$W/rpmbin/rpm" "$W/rpmbin/dnf"

inv() { bash "$SCRIPT" --root "$R" "$@" 2>"$W/stderr"; }
row() { # name -> its tsv row
  inv --format tsv "$@" | awk -F'\t' -v n="$ROWNAME" '$1 == n'
}
field() { # name column-number [flags…]
  local n="$1" c="$2"; shift 2
  inv --format tsv "$@" | awk -F'\t' -v n="$n" -v c="$c" '$1 == n { print $c }'
}

echo "== apt vs dpkg, explicit, update, date =="
[ "$(field fromrepo 3)" = apt ]          || fail "fromrepo should be apt"
[ "$(field handmade 3)" = dpkg ]         || fail "handmade should be dpkg (local .deb)"
[ "$(field handmade 8)" = "local .deb" ] || fail "handmade source: $(field handmade 8)"
[ "$(field somelib 7)" = no ]            || fail "somelib is a dependency"
[ "$(field fromrepo 7)" = yes ]          || fail "fromrepo was installed on purpose"
[ "$(field fromrepo 9)" = 1.1 ]          || fail "fromrepo's update: $(field fromrepo 9)"
[ "$(field fromrepo 6)" = 2026-01-02 ]   || fail "fromrepo's install date: $(field fromrepo 6)"
[ "$(field fromrepo 5)" = 2048 ]         || fail "fromrepo's size: $(field fromrepo 5)"
[ -z "$(field gone 1)" ]                 || fail "a removed package was listed"

echo "== pacman =="
[ "$(field ripgrep 3)" = pacman ] && [ "$(field ripgrep 7)" = yes ] || fail "ripgrep: $(inv --format tsv | grep ripgrep)"
[ "$(field pcre2 7)" = no ]              || fail "pcre2 is a dependency"
[ "$(field ripgrep 6)" = 2026-01-02 ]    || fail "ripgrep's date: $(field ripgrep 6)"
[ "$(field ripgrep 5)" = 4096 ]          || fail "ripgrep's size: $(field ripgrep 5)"

echo "== manual: unowned only =="
[ "$(field mytool 3)" = manual ] && [ "$(field mytool 8)" = /usr/local/bin/mytool ] || fail "mytool: $(field mytool 8)"
[ "$(field curl-sh-app 3)" = manual ]    || fail "/opt/curl-sh-app not listed as manual"
[ -z "$(field owned-app 1)" ]            || fail "/opt/owned-app belongs to fromrepo, not manual"

echo "== rpm: epoch, keys, explicit from dnf =="
out="$(PATH="$W/rpmbin:$PATH" inv --format tsv --pm rpm)"
grep -q $'^curl\t8.9.1-2.fc41\trpm' <<<"$out"           || fail "epoch 0 not hidden: $out"
grep -q $'^vim-enhanced\t2:9.1.1-1.fc41' <<<"$out"      || fail "a real epoch was hidden: $out"
grep -q '^gpg-pubkey' <<<"$out"                         && fail "a signing key was listed"
[ "$(awk -F'\t' '$1=="vim-enhanced"{print $7}' <<<"$out")" = yes ] || fail "vim-enhanced was user-installed"
[ "$(awk -F'\t' '$1=="curl"{print $7}' <<<"$out")" = no ]          || fail "curl was not user-installed"

echo "== a package database that cannot be read =="
mkdir -p "$W/badrpm"; printf '#!/bin/sh\necho "error: rpmdb: damaged" >&2; exit 1\n' > "$W/badrpm/rpm"; chmod +x "$W/badrpm/rpm"
rm -f "$W/partial.tsv"
out="$(PATH="$W/badrpm:$PATH" bash "$SCRIPT" --root "$R" --cache "$W/partial.tsv" --format tsv 2>"$W/stderr")" \
  && fail "a failed package manager did not fail the run"
grep -q "could not read rpm" "$W/stderr"      || fail "the failure was not named: $(cat "$W/stderr")"
grep -q $'^fromrepo\t' <<<"$out"              || fail "the rest of the list was lost"
[ ! -e "$W/partial.tsv" ]                     || fail "an incomplete list was saved"

echo "== formats =="
out="$(inv)"
[ "$(head -1 <<<"$out" | tr -s ' ')" = "NAME VERSION PM" ] || fail "table header: $(head -1 <<<"$out")"
out="$(inv --wide)"
head -1 <<<"$out" | grep -q "EXPLICIT  SOURCE" || fail "wide header: $(head -1 <<<"$out")"
grep -q '^fromrepo .* 2.0M ' <<<"$out"         || fail "wide size not human-readable"
out="$(inv --format tsv)"
[ "$(head -1 <<<"$out")" = $'name\tversion\tpm\tarch\tsize_kb\tinstalled\texplicit\tsource\tupdate\tsummary' ] || fail "tsv header"
awk -F'\t' 'NF != 10 { exit 1 }' <<<"$out"     || fail "a tsv row does not have 10 columns"
inv --format json | python3 -c '
import json, sys
rows = json.load(sys.stdin)
names = {r["name"]: r for r in rows}
assert names["handmade"]["pm"] == "dpkg", names["handmade"]
assert names["fromrepo"]["update"] == "1.1"
assert set(rows[0]) == {"name","version","pm","arch","size_kb","installed","explicit","source","update","summary"}
' || fail "json is wrong"

echo "== filters =="
[ "$(inv --format tsv --pm dpkg,manual | tail -n +2 | cut -f3 | sort -u | tr '\n' ' ')" = "dpkg manual " ] || fail "--pm"
[ "$(inv --format tsv --search 'from the REPOSITORY' | tail -n +2 | cut -f1)" = fromrepo ] || fail "--search should match summaries, any case"
inv --format tsv --explicit | tail -n +2 | cut -f7 | grep -qv yes && fail "--explicit let a dependency through"
[ "$(inv --format tsv --updates | tail -n +2 | cut -f1)" = fromrepo ] || fail "--updates"

echo "== the saved list =="
C="$W/saved.tsv"
inv --cache "$C" >/dev/null                           # asked for the simple table
head -1 "$C" | grep -q '^# ops-inventory v1 '          || fail "no marker line"
[ "$(sed -n 2p "$C" | tr '\t' '\n' | wc -l)" = 10 ]    || fail "saved list is not in full"
inv --cache "$C" >/dev/null; grep -q "from the list saved" "$W/stderr" || fail "second run did not read the saved list"
grep -q "may be out of date" "$W/stderr"               && fail "stale warning with nothing changed"
sleep 1; touch "$R/var/lib/dpkg/status"
inv --cache "$C" >/dev/null; grep -q "may be out of date" "$W/stderr" || fail "no warning after the package database changed"
cp "$C" "$W/before"; inv --cache "$C" --refresh >/dev/null
grep -q "from the list saved" "$W/stderr"              && fail "--refresh read the saved list"
cmp -s "$C" "$W/before"                                && fail "--refresh did not replace the saved list"
rm -f "$W/none.tsv"; inv --cache "$W/none.tsv" --no-cache >/dev/null
[ ! -e "$W/none.tsv" ]                                 || fail "--no-cache wrote a file"
echo precious > "$W/notes.txt"
inv --cache "$W/notes.txt" >/dev/null && fail "read a file that is not an inventory"
inv --cache "$W/notes.txt" --refresh >/dev/null
[ "$(cat "$W/notes.txt")" = precious ]                 || fail "overwrote a file that is not an inventory"
# Another machine's list must not replace this one's: --root alone saves nothing.
XDG_CACHE_HOME="$W/xdg" bash "$SCRIPT" --root "$R" >/dev/null 2>"$W/stderr"
[ ! -e "$W/xdg/ops/inventory.tsv" ]                    || fail "--root without --cache wrote the default saved list"
grep -q "inventory of $R" "$W/stderr"                  || fail "--root did not say what it inspected"

echo "== without apt's package lists, nothing is called hand-installed =="
mv "$LISTS" "$W/lists.away"
[ "$(field handmade 3)" = apt ]                        || fail "handmade called dpkg with no lists to compare against"
grep -q "cannot be told apart" "$W/stderr"             || fail "no note about the missing lists"
mv "$W/lists.away" "$LISTS"

echo "== bad input =="
bad() { local want="$1" out; shift; out="$(bash "$SCRIPT" "$@" 2>&1)" && fail "accepted: $*"; grep -q -- "$want" <<<"$out" || fail "$*: $out"; }
bad "--format 'html'"            --no-cache --format html
bad "--pm 'npm'"                 --no-cache --pm npm
bad "unknown argument '--bogus'" --no-cache --bogus
bad "is not a directory"         --root "$W/nowhere"

echo "PASS"

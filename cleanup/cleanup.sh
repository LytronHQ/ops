#!/usr/bin/env bash
#
# cleanup.sh — reclaim disk space from what a Linux machine accumulates and
# does not need: package caches, old temp files, an oversized journal, old
# rotated logs, crash dumps, thumbnails. REPORTS BY DEFAULT; deletes nothing
# without --apply.
#
# platforms: linux
#
#   ./cleanup.sh                      # what each category would free
#   sudo ./cleanup.sh --apply         # clean, and report what was freed
#   ./cleanup.sh --only journal,temp
#   sudo ./cleanup.sh --apply --older-than 14
#
# Categories (all run unless --only or --skip says otherwise):
#   package-cache  downloaded packages: apt-get clean, dnf clean packages,
#                  pacman -Sc (keeps the versions installed)
#   temp           files in /tmp and /var/tmp untouched (modified, accessed,
#                  changed) for 7 days; never service-private directories,
#                  sockets or the X11 directories
#   journal        the systemd journal above --journal-max, via journalctl
#                  --vacuum-size
#   rotated-logs   compressed or numbered logs in /var/log older than 30 days
#   crash-dumps    /var/crash and systemd coredumps older than 7 days
#   thumbnails     each user's ~/.cache/thumbnails, regenerated on demand
#
# Opt-in categories, run only when named with --include (or --only):
#   docker         dangling images and the build cache — never tagged images,
#                  containers, volumes or networks
#   autoremove     packages installed only as dependencies of something since
#                  removed, old kernels included: apt-get autoremove, dnf
#                  autoremove, pacman orphans. Opt-in because "a dependency" is
#                  the package manager's record, not the user's intent
#   snap-revisions disabled snap revisions, kept by snapd after each refresh
#
# With --root, autoremove and snap-revisions are reported and never applied:
# apt's -o Dir moves where it reads, but removing still runs the host's dpkg.
#
# Never touched: documents, downloads, the trash, anything a user made.
#
# Options — every input is one; nothing else is read from the environment
# except HOME (whose thumbnails, when not root):
#   --apply              clean; without it nothing is deleted. Without root,
#                        only what needs none (thumbnails, docker) is cleaned,
#                        and the rest is said to need root
#   --only <list>        only these categories; repeatable or commas
#   --skip <list>        all but these
#   --include <list>     add opt-in categories to the default ones
#   --older-than <days>  one age limit for temp, rotated-logs and crash-dumps
#                        (default 7, 30, 7). 0 means any age — for emptying a
#                        machine about to become an image, not a live one
#   --journal-max <size> keep the journal to this size (default 500M); K, M, G
#   --format <f>         table (default), tsv or json
#   --root <dir>         clean the system mounted at <dir> instead of this one
#   -h, --help           this text
#
# The cleaning is done by each package manager's own tool where there is one:
# it knows what is in use. What was freed is measured, not assumed: each
# category is sized again afterwards.
set -euo pipefail
shopt -s inherit_errexit

die()  { echo "cleanup: $*" >&2; exit 1; }
note() { echo "cleanup: $*" >&2; }
usage() { sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

ALL="package-cache temp journal rotated-logs crash-dumps thumbnails"
OPTIN="docker autoremove snap-revisions"
# What can be cleaned without root: a user's own files, and a Docker daemon
# the user can reach — rootless, or through the docker group.
USERLEVEL="thumbnails docker"
APPLY=0 ONLY=() SKIP=() INCLUDE=() AGE="" JMAX="500M" FORMAT="table" ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;; esac
  case "$1" in
    --only|--skip|--include|--older-than|--journal-max|--format|--root)
      [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value (try --help)" ;;
  esac
  case "$1" in
    --apply)       APPLY=1; shift ;;
    --only)        IFS=', ' read -r -a v <<<"$2"; ONLY+=("${v[@]}"); shift 2 ;;
    --skip)        IFS=', ' read -r -a v <<<"$2"; SKIP+=("${v[@]}"); shift 2 ;;
    --include)     IFS=', ' read -r -a v <<<"$2"; INCLUDE+=("${v[@]}"); shift 2 ;;
    --older-than)  [[ "$2" =~ ^[0-9]+$ ]] || die "--older-than '$2' is not a number of days"; AGE="$2"; shift 2 ;;
    --journal-max) [[ "$2" =~ ^[0-9]+[KMG]?$ ]] || die "--journal-max '$2': a size like 500M or 2G"; JMAX="$2"; shift 2 ;;
    --format)      FORMAT="$2"; shift 2 ;;
    --root)        ROOT="${2%/}"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown argument '$1' (try --help)" ;;
  esac
done
case "$FORMAT" in table|tsv|json) ;; *) die "--format '$FORMAT': table, tsv or json" ;; esac
for c in "${ONLY[@]}" "${SKIP[@]}" "${INCLUDE[@]}"; do
  case " $ALL $OPTIN " in *" $c "*) ;; *) die "unknown category '$c'. Categories: $ALL; opt-in: $OPTIN" ;; esac
done
[ -z "$ROOT" ] || [ -d "$ROOT" ] || die "--root: $ROOT is not a directory"
IS_ROOT=0; [ "$(id -u)" = 0 ] && IS_ROOT=1
# Without root, --apply cleans what needs none and leaves the rest, saying so —
# as cleanup.ps1 does on Windows.
NOROOT_APPLY=0
[ "$APPLY" = 1 ] && [ "$IS_ROOT" = 0 ] && [ -z "$ROOT" ] && NOROOT_APPLY=1

TEMP_AGE="${AGE:-7}" LOG_AGE="${AGE:-30}" DUMP_AGE="${AGE:-7}"
# find arguments for "older than N days by every measure"; nothing for 0.
older() { # days measure…
  local d="$1"; shift
  [ "$d" = 0 ] && return 0
  local m; for m in "$@"; do printf -- '-%s\0+%s\0' "$m" "$d"; done
}
# Read into arrays once, so paths and flags stay separate words.
mapfile -d '' TEMP_OLD < <(older "$TEMP_AGE" mtime atime ctime)
mapfile -d '' LOG_OLD < <(older "$LOG_AGE" mtime)
mapfile -d '' DUMP_OLD < <(older "$DUMP_AGE" mtime)

# Default categories run unless left out; opt-in ones only when named.
selected() {
  local c="$1"
  if [ "${#ONLY[@]}" -gt 0 ]; then case " ${ONLY[*]} " in *" $c "*) ;; *) return 1 ;; esac
  else
    case " $OPTIN " in *" $c "*) case " ${INCLUDE[*]} " in *" $c "*) ;; *) return 1 ;; esac ;; esac
  fi
  case " ${SKIP[*]} " in *" $c "*) return 1 ;; esac
  return 0
}

# Every category is two functions: size_<c> prints "<bytes> <items>" for what
# would go, clean_<c> removes it. Freed is size before minus size after.
#
# clean_<c> runs inside `if !`, and there bash switches set -e off for the
# whole function: a failed apt-get was carried past and reported as success.
# So every step checks its own result, `|| return 1`, instead of relying on it.

# Sum of sizes and count from a NUL-separated list of files.
sum_files() { xargs -0 -r stat -c %s -- 2>/dev/null | awk '{ b += $1; n++ } END { printf "%d %d\n", b, n }'; }
bytes_of() { # 500M -> bytes
  local n="${1%[KMG]}"
  case "$1" in *K) echo $((n * 1024)) ;; *M) echo $((n * 1048576)) ;; *G) echo $((n * 1073741824)) ;; *) echo "$n" ;; esac
}

# --- package-cache --------------------------------------------------------------

apt_cache_files() {
  find "$ROOT/var/cache/apt" -xdev \( -path "$ROOT/var/cache/apt/archives/*.deb" -o \
    -path "$ROOT/var/cache/apt/archives/partial/*" -o -name '*.bin' \) -type f -print0 2>/dev/null || true
}
dnf_cache_files() {
  find "$ROOT/var/cache/dnf" "$ROOT/var/cache/libdnf5" -xdev -type f -name '*.rpm' -print0 2>/dev/null || true
}
# pacman -Sc keeps the version of each package that is installed and removes
# the rest; sized by the same rule, read from the local database.
pacman_cache_files() {
  local cache="$ROOT/var/cache/pacman/pkg" f base rest arch rel ver name
  [ -d "$cache" ] || return 0
  for f in "$cache"/*.pkg.tar.*; do
    [ -f "$f" ] || continue
    case "$f" in *.sig) continue ;; esac
    base="$(basename "$f")"; rest="${base%.pkg.tar.*}"
    arch="${rest##*-}"; rest="${rest%-*}"; rel="${rest##*-}"; rest="${rest%-*}"
    ver="${rest##*-}"; name="${rest%-*}"
    [ -d "$ROOT/var/lib/pacman/local/$name-$ver-$rel" ] && continue
    printf '%s\0' "$f"
    # An if, not `[ ] && printf`: as the loop's last command, a package with no
    # signature made the whole function fail, and the cache "could not be sized".
    if [ -f "$f.sig" ]; then printf '%s\0' "$f.sig"; fi
  done
  return 0
}
size_package_cache() {
  { apt_cache_files; dnf_cache_files; pacman_cache_files; } | sum_files
}
how_package_cache() {
  local h=()
  [ -d "$ROOT/var/cache/apt" ] && h+=("apt-get clean")
  { [ -d "$ROOT/var/cache/dnf" ] || [ -d "$ROOT/var/cache/libdnf5" ]; } && h+=("dnf clean packages")
  [ -d "$ROOT/var/cache/pacman/pkg" ] && h+=("pacman -Sc")
  local IFS=,; echo "${h[*]:-no package manager cache}"
}
clean_package_cache() {
  if [ -d "$ROOT/var/cache/apt" ] && command -v apt-get >/dev/null 2>&1; then
    if [ -n "$ROOT" ]; then apt-get -o "Dir=$ROOT/" clean || return 1; else apt-get clean || return 1; fi
  fi
  if { [ -d "$ROOT/var/cache/dnf" ] || [ -d "$ROOT/var/cache/libdnf5" ]; } && command -v dnf >/dev/null 2>&1; then
    dnf ${ROOT:+--installroot "$ROOT"} -q clean packages >/dev/null || return 1
  fi
  if [ -d "$ROOT/var/cache/pacman/pkg" ] && command -v pacman >/dev/null 2>&1; then
    pacman ${ROOT:+--root "$ROOT" --cachedir "$ROOT/var/cache/pacman/pkg"} -Sc --noconfirm >/dev/null || return 1
  fi
}

# --- temp ---------------------------------------------------------------------

# Untouched by every measure systemd-tmpfiles uses — modified, accessed, and
# changed — and never inside what belongs to a running service or a session.
temp_files() {
  local d
  for d in "$ROOT/tmp" "$ROOT/var/tmp"; do
    [ -d "$d" ] || continue
    find "$d" -xdev -mindepth 1 \
      \( -name 'systemd-private-*' -o -name 'snap-private-tmp' -o -name '.X11-unix' -o -name '.ICE-unix' \
         -o -name '.XIM-unix' -o -name '.font-unix' -o -name '.Test-unix' \) -prune -o \
      -type f "${TEMP_OLD[@]}" -print0 2>/dev/null || true
  done
}
size_temp() { temp_files | sum_files; }
how_temp() { [ "$TEMP_AGE" = 0 ] && echo "any age" || echo "untouched for ${TEMP_AGE}+ days"; }
clean_temp() {
  # Directories old enough to go once empty — listed BEFORE their files are
  # removed, because removing a file makes its directory new again, and then
  # it stayed behind. Deepest first, and rmdir only ever removes an empty one.
  local d dirs
  dirs="$(for d in "$ROOT/tmp" "$ROOT/var/tmp"; do
    [ -d "$d" ] || continue
    find "$d" -xdev -mindepth 1 \( -name 'systemd-private-*' -o -name 'snap-private-tmp' -o -name '.*-unix' \) -prune -o \
      -type d "${TEMP_OLD[@]:0:2}" -print 2>/dev/null || true
  done | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2-)"
  temp_files | xargs -0 -r rm -f -- || return 1
  while IFS= read -r d; do [ -n "$d" ] && rmdir -- "$d" 2>/dev/null || true; done <<<"$dirs"
}

# --- journal ------------------------------------------------------------------

journal_dir() {
  if [ -n "$ROOT" ]; then echo "$ROOT/var/log/journal"
  elif [ -d /var/log/journal ]; then echo /var/log/journal
  else echo /run/log/journal; fi
}
journal_usage() { # bytes the journal takes
  local d; d="$(journal_dir)"
  [ -d "$d" ] && command -v journalctl >/dev/null 2>&1 || { echo 0; return; }
  local out
  out="$(journalctl -D "$d" --disk-usage 2>/dev/null | sed -n 's/.*take up \([0-9.]*[BKMGT]\?\).*/\1/p')"
  awk -v s="${out:-0}" 'BEGIN {
    n = s + 0; u = substr(s, length(s))
    if (u == "K") n *= 1024; else if (u == "M") n *= 1048576; else if (u == "G") n *= 1073741824; else if (u == "T") n *= 1099511627776
    printf "%d\n", n }'
}
# Only ARCHIVED journal files can be vacuumed; the active ones stay whatever
# the limit. So what can go is the excess over the limit, but never more than
# the archived files hold — otherwise the report promised space that no
# cleaning could ever free, and said so again after every run.
size_journal() {
  local used max d archived
  used="$(journal_usage)"; max="$(bytes_of "$JMAX")"; d="$(journal_dir)"
  [ "$used" -gt "$max" ] || { echo "0 -"; return; }
  archived="$(find "$d" -xdev -type f \( -name '*@*.journal' -o -name '*.journal~' \) -print0 2>/dev/null | sum_files | cut -d' ' -f1 || true)"
  archived="${archived:-0}"
  local excess=$((used - max))
  if [ "$archived" -lt "$excess" ]; then echo "$archived -"; else echo "$excess -"; fi
}
how_journal() { echo "kept to $JMAX (journalctl --vacuum-size)"; }
clean_journal() {
  local d; d="$(journal_dir)"
  [ -d "$d" ] || return 0
  journalctl -D "$d" --vacuum-size="$JMAX" >/dev/null 2>&1 || return 1
}

# --- rotated-logs -------------------------------------------------------------

rotated_files() {
  [ -d "$ROOT/var/log" ] || return 0
  # Unreadable directories are expected without root, which is said once up
  # front; they must not make a category look failed. Hence || true on finds.
  find "$ROOT/var/log" -xdev -path "$ROOT/var/log/journal" -prune -o -type f \
    \( -name '*.gz' -o -name '*.xz' -o -name '*.bz2' -o -name '*.zst' -o -name '*.old' -o -regex '.*\.[0-9]+' \) \
    "${LOG_OLD[@]}" -print0 2>/dev/null || true
}
size_rotated_logs() { rotated_files | sum_files; }
how_rotated_logs() { [ "$LOG_AGE" = 0 ] && echo "any age" || echo "older than $LOG_AGE days"; }
clean_rotated_logs() { rotated_files | xargs -0 -r rm -f -- || return 1; }

# --- crash-dumps --------------------------------------------------------------

dump_files() {
  local d
  for d in "$ROOT/var/crash" "$ROOT/var/lib/systemd/coredump"; do
    [ -d "$d" ] || continue
    find "$d" -xdev -mindepth 1 -type f "${DUMP_OLD[@]}" -print0 2>/dev/null || true
  done
}
size_crash_dumps() { dump_files | sum_files; }
how_crash_dumps() { [ "$DUMP_AGE" = 0 ] && echo "any age" || echo "older than $DUMP_AGE days"; }
clean_crash_dumps() { dump_files | xargs -0 -r rm -f -- || return 1; }

# --- thumbnails ---------------------------------------------------------------

thumbnail_dirs() {
  if [ "$IS_ROOT" = 1 ] || [ -n "$ROOT" ]; then
    local d
    for d in "$ROOT"/home/*/.cache/thumbnails "$ROOT/root/.cache/thumbnails"; do [ -d "$d" ] && echo "$d"; done
  else
    [ -d "$HOME/.cache/thumbnails" ] && echo "$HOME/.cache/thumbnails"
  fi
  return 0
}
thumbnail_files() { local d; while read -r d; do find "$d" -xdev -type f -print0 2>/dev/null || true; done < <(thumbnail_dirs); }
size_thumbnails() { thumbnail_files | sum_files; }
how_thumbnails() { echo "regenerated on demand"; }
clean_thumbnails() { thumbnail_files | xargs -0 -r rm -f -- || return 1; }

# --- docker (opt-in) ------------------------------------------------------------

# Only what nothing refers to: images left untagged by a newer build, and the
# build cache. Docker's own reclaimable figure counts every unused image and
# every unused volume — data, as far as this script can know — so it is not
# what is offered here.
docker_ok() { [ -z "$ROOT" ] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }
docker_bytes() { # Docker's "1.2GB" (decimal units) -> bytes
  awk -v s="$1" 'BEGIN { n = s + 0; u = s; sub(/^[0-9.]+/, "", u)
    m = (u == "kB" || u == "KB") ? 1e3 : (u == "MB") ? 1e6 : (u == "GB") ? 1e9 : (u == "TB") ? 1e12 : 1
    printf "%d\n", n * m }'
}
size_docker() {
  docker_ok || { echo "0 0"; return 0; }
  # Each image's UNIQUE size — layers no other image shares. Adding up their
  # plain sizes counted shared base layers once per image: 10.3G claimed where
  # Docker itself put every unused image together at 5.1G.
  local img cache
  img="$(docker system df -v --format '{{range .Images}}{{.Repository}}|{{.Tag}}|{{.UniqueSize}}{{println}}{{end}}' |
    awk -F'|' '$1 == "<none>" && $2 == "<none>" { print $3 }')"
  cache="$(docker system df --format '{{.Type}}|{{.Reclaimable}}|{{.TotalCount}}' | awk -F'|' '$1 == "Build Cache" { split($2, a, " "); print a[1] "|" $3 }')"
  local bytes=0 n=0 u
  while read -r u; do [ -n "$u" ] || continue; bytes=$((bytes + $(docker_bytes "$u"))); n=$((n + 1)); done <<<"$img"
  bytes=$((bytes + $(docker_bytes "${cache%%|*}")))
  echo "$bytes $((n + ${cache##*|}))"
}
how_docker() { docker_ok && echo "dangling images, build cache" || echo "no Docker daemon reachable"; }
clean_docker() {
  docker image prune --force >/dev/null || return 1
  docker builder prune --force >/dev/null || return 1
}

# --- autoremove (opt-in) -------------------------------------------------------

# "<manager> <package>" for each package its manager would autoremove.
autoremove_list() {
  if command -v apt-get >/dev/null 2>&1 && [ -e "$ROOT/var/lib/dpkg/status" ]; then
    local aptopts=()
    [ -z "$ROOT" ] || aptopts=(-o "Dir=$ROOT/" -o "Dir::State::status=$ROOT/var/lib/dpkg/status")
    apt-get "${aptopts[@]}" -s autoremove 2>/dev/null | awk '$1 == "Remv" { print "apt " $2 }' || true
  fi
  if command -v dnf >/dev/null 2>&1 && command -v rpm >/dev/null 2>&1; then
    dnf ${ROOT:+--installroot "$ROOT"} -C -q repoquery --unneeded --qf '%{name}\n' 2>/dev/null | awk 'NF { print "dnf " $1 }' || true
  fi
  if [ -d "$ROOT/var/lib/pacman/local" ] && command -v pacman >/dev/null 2>&1; then
    pacman ${ROOT:+--root "$ROOT"} -Qtdq 2>/dev/null | awk 'NF { print "pacman " $1 }' || true
  fi
  return 0
}
size_autoremove() {
  local list; list="$(autoremove_list)"
  [ -n "$list" ] || { echo "0 0"; return 0; }
  local apt dnf pac kb=0 b=0
  apt="$(awk '$1 == "apt" { print $2 }' <<<"$list")"
  dnf="$(awk '$1 == "dnf" { print $2 }' <<<"$list")"
  pac="$(awk '$1 == "pacman" { print $2 }' <<<"$list")"
  if [ -n "$apt" ]; then
    kb="$(dpkg-query --admindir="$ROOT/var/lib/dpkg" -W -f='${Installed-Size}\n' $apt 2>/dev/null | awk '{ s += $1 } END { printf "%d", s }')"
    b=$((b + kb * 1024))
  fi
  if [ -n "$dnf" ]; then
    b=$((b + $(rpm ${ROOT:+--root "$ROOT"} -q --qf '%{SIZE}\n' $dnf 2>/dev/null | awk '{ s += $1 } END { printf "%d", s }')))
  fi
  if [ -n "$pac" ]; then
    b=$((b + $(find "$ROOT/var/lib/pacman/local" -mindepth 2 -maxdepth 2 -name desc -print0 | xargs -0 -r awk -v want=" $(tr '\n' ' ' <<<"$pac")" '
      FNR == 1 { if (keep) s += size; keep = 0; size = 0 }
      /^%NAME%$/ { getline; keep = index(want, " " $0 " ") > 0 }
      /^%SIZE%$/ { getline; size = $0 }
      END { if (keep) s += size; printf "%d", s }')))
  fi
  echo "$b $(wc -l <<<"$list")"
}
how_autoremove() {
  local m=()
  command -v apt-get >/dev/null 2>&1 && [ -e "$ROOT/var/lib/dpkg/status" ] && m+=("apt-get autoremove")
  command -v dnf >/dev/null 2>&1 && m+=("dnf autoremove")
  [ -d "$ROOT/var/lib/pacman/local" ] && m+=("pacman orphans")
  local IFS=,; local h="${m[*]:-no package manager}"
  [ -z "$ROOT" ] || h="$h; reported only under --root"
  echo "$h"
}
clean_autoremove() {
  [ -z "$ROOT" ] || return 0             # see the header: never under --root
  local list; list="$(autoremove_list)"
  if grep -q '^apt ' <<<"$list"; then
    DEBIAN_FRONTEND=noninteractive apt-get -y -q autoremove >/dev/null || return 1
  fi
  if grep -q '^dnf ' <<<"$list"; then dnf -y -q autoremove >/dev/null || return 1; fi
  if grep -q '^pacman ' <<<"$list"; then
    # shellcheck disable=SC2046
    pacman -Rns --noconfirm $(awk '$1 == "pacman" { print $2 }' <<<"$list") >/dev/null || return 1
  fi
}

# --- snap-revisions (opt-in) ---------------------------------------------------

# "<name> <revision>" for each revision snap lists as disabled. snapd answers
# only for the running system, so nothing under --root.
snap_disabled() {
  [ -z "$ROOT" ] && command -v snap >/dev/null 2>&1 || return 0
  snap list --all --unicode=never --color=never 2>/dev/null | awk 'NR > 1 && $NF ~ /(^|,)disabled(,|$)/ { print $1, $3 }' || true
}
size_snap_revisions() {
  local b=0 n=0 name rev f
  while read -r name rev; do
    [ -n "$name" ] || continue
    n=$((n + 1)); f="/var/lib/snapd/snaps/${name}_${rev}.snap"
    [ -f "$f" ] && b=$((b + $(stat -c %s "$f")))
  done < <(snap_disabled)
  echo "$b $n"
}
how_snap_revisions() { echo "snap remove --revision, disabled ones only"; }
clean_snap_revisions() {
  local name rev
  while read -r name rev; do
    [ -n "$name" ] || continue
    snap remove "$name" --revision="$rev" >/dev/null || return 1
  done < <(snap_disabled)
}

# --- run -----------------------------------------------------------------------

[ "$IS_ROOT" = 1 ] || [ -n "$ROOT" ] || note "not root: some files cannot be read, so sizes may be incomplete"
FAILED="" RESULTS="" LEFT=""
for c in $ALL $OPTIN; do
  selected "$c" || continue
  fn="${c//-/_}"
  if [ "$NOROOT_APPLY" = 1 ]; then
    case " $USERLEVEL " in *" $c "*) ;; *) LEFT+=" $c"; continue ;; esac
  fi
  if ! before="$("size_$fn")"; then note "could not size $c"; FAILED+=" $c"; continue; fi
  read -r bytes items <<<"$before"
  how="$("how_$fn")"
  # Something to clean: bytes, or items whose size could not be read.
  if [ "$APPLY" = 1 ] && { [ "$bytes" -gt 0 ] || { [ "$items" != "-" ] && [ "$items" -gt 0 ]; }; }; then
    if ! err="$("clean_$fn" 2>&1)"; then
      note "could not clean $c: $(head -1 <<<"$err")"; FAILED+=" $c"
    fi
    read -r after _ <<<"$("size_$fn")"
    bytes=$((bytes - after))
  fi
  RESULTS+="$c	$bytes	$items	$how"$'\n'
done

[ -z "$LEFT" ] || note "not root: left for root:$LEFT"
awk -F'\t' -v fmt="$FORMAT" -v apply="$APPLY" '
  function human(b) {
    if (b >= 1073741824) return sprintf("%.1fG", b / 1073741824)
    if (b >= 1048576) return sprintf("%.1fM", b / 1048576)
    if (b >= 1024) return sprintf("%.1fK", b / 1024)
    return b "B"
  }
  function js(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return "\"" s "\"" }
  NF >= 4 { n++; c[n] = $1; b[n] = $2; it[n] = $3; h[n] = $4; total += $2 }
  END {
    col = apply ? "FREED" : "RECLAIMABLE"
    if (fmt == "tsv") {
      print "category\t" tolower(col) "_bytes\titems\thow"
      for (i = 1; i <= n; i++) print c[i] "\t" b[i] "\t" it[i] "\t" h[i]
    } else if (fmt == "json") {
      printf "{\"applied\": %s, \"total_bytes\": %d, \"categories\": [", (apply ? "true" : "false"), total
      for (i = 1; i <= n; i++)
        printf "%s\n  {\"category\": %s, \"bytes\": %d, \"items\": %s, \"how\": %s}", (i > 1 ? "," : ""), js(c[i]), b[i], (it[i] == "-" ? "null" : it[i]), js(h[i])
      print (n ? "\n]}" : "]}")
    } else {
      w = 8; for (i = 1; i <= n; i++) if (length(c[i]) > w) w = length(c[i])
      printf "%-" w "s  %11s  %6s  %s\n", "CATEGORY", col, "ITEMS", "HOW"
      for (i = 1; i <= n; i++) printf "%-" w "s  %11s  %6s  %s\n", c[i], human(b[i]), it[i], h[i]
      printf "%-" w "s  %11s\n", "total", human(total)
      if (!apply) print "(a report: nothing was deleted. --apply to clean.)" > "/dev/stderr"
    }
  }' <<<"$RESULTS"

[ -z "$FAILED" ] || exit 1

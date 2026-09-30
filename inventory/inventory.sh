#!/usr/bin/env bash
#
# inventory.sh — list the software installed on this machine, and which package
# manager put each piece there.
#
# platforms: linux
#
#   ./inventory.sh                         # name, version, package manager
#   ./inventory.sh --wide                  # + arch, size, installed, explicit, source, update, summary
#   ./inventory.sh --pm snap,flatpak --search firefox
#   ./inventory.sh --explicit              # only what someone installed on purpose
#   ./inventory.sh --format json > inventory.json
#   ./inventory.sh --refresh               # rescan instead of reading the saved list
#
# Every scan is saved IN FULL — every column, whatever format was asked for —
# and later runs read that saved list instead of scanning again. --refresh
# rescans; --no-cache neither reads nor writes it.
#
# Package managers (PM column):
#   apt      a .deb from a configured repository
#   dpkg     a .deb installed by hand, found in no repository
#   rpm, pacman, snap, flatpak
#   manual   no package manager: an executable in /usr/local/bin, or a
#            directory in /opt that no package owns — the curl | sh installs
#
# Options — every input is one; nothing else is read from the environment
# except HOME and XDG_CACHE_HOME, which say where the saved list lives:
#   --wide               the wide table (same as --format wide)
#   --format <f>         table (default), wide, tsv (every column, with a
#                        header) or json
#   --pm <list>          only these package managers; repeatable or commas
#   --search <text>      only names or summaries containing this (any case)
#   --explicit           only what was installed on purpose, not as a dependency
#   --updates            only what has a newer version known locally
#   --refresh            scan now, and replace the saved list
#   --no-cache           scan now, and neither read nor write the saved list
#   --cache <path>       where the saved list lives
#                        (default ~/.cache/ops/inventory.tsv)
#   --root <dir>         inventory the system mounted at <dir> — a disk, a
#                        chroot, an unpacked container image — instead of this
#                        one. dpkg/apt, rpm, pacman and manual are read from it;
#                        snap and flatpak describe the running system and are
#                        skipped. Not saved unless --cache is given.
#   -h, --help           this text
#
# Needs bash and the usual tools (awk, stat, find); nothing to install. It only
# reads: it never asks a package manager to refresh or touch the network.
set -euo pipefail
shopt -s inherit_errexit

die()  { echo "inventory: $*" >&2; exit 1; }
note() { echo "inventory: $*" >&2; }
usage() { sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

FORMAT="table" PMS=() SEARCH="" EXPLICIT=0 UPDATES=0 MODE="cached" ROOT="" CACHE=""
while [ $# -gt 0 ]; do
  case "$1" in --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;; esac
  case "$1" in
    --format|--pm|--search|--cache|--root)
      [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value (try --help)" ;;
  esac
  case "$1" in
    --wide)     FORMAT="wide"; shift ;;
    --format)   FORMAT="$2"; shift 2 ;;
    --pm)       IFS=', ' read -r -a v <<<"$2"; PMS+=("${v[@]}"); shift 2 ;;
    --search)   SEARCH="$2"; shift 2 ;;
    --explicit) EXPLICIT=1; shift ;;
    --updates)  UPDATES=1; shift ;;
    --refresh)  MODE="refresh"; shift ;;
    --no-cache) MODE="none"; shift ;;
    --cache)    CACHE="$2"; shift 2 ;;
    --root)     ROOT="${2%/}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "unknown argument '$1' (try --help)" ;;
  esac
done
case "$FORMAT" in table|wide|tsv|json) ;; *) die "--format '$FORMAT': table, wide, tsv or json" ;; esac
if [ -n "$ROOT" ]; then
  [ -d "$ROOT" ] || die "--root: $ROOT is not a directory"
  # Another machine's list must not replace this one's saved list.
  [ -n "$CACHE" ] || MODE="none"
fi
CACHE="${CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/ops/inventory.tsv}"
for p in "${PMS[@]}"; do
  case "$p" in apt|dpkg|rpm|pacman|snap|flatpak|manual) ;;
    *) die "--pm '$p': one of apt, dpkg, rpm, pacman, snap, flatpak, manual" ;; esac
done

# The saved list: a marker line, a header, then one row per package. The marker
# is how it knows a file is its own — it refuses to overwrite anything else,
# since --cache can point anywhere.
MARKER="# ops-inventory v1"
COLUMNS_="name	version	pm	arch	size_kb	installed	explicit	source	update	summary"

# Fields must not carry the separators. A summary with a tab or a newline would
# otherwise shift every column after it.
clean() { tr -d '\r' | awk -F'\t' -v OFS='\t' '{ for (i = 1; i <= NF; i++) gsub(/[[:cntrl:]]/, " ", $i); print }'; }

# --- collectors: each prints rows in COLUMNS_ order, "-" for unknown --------

collect_dpkg() {
  command -v dpkg-query >/dev/null 2>&1 || return 0
  [ -e "$ROOT/var/lib/dpkg/status" ] || return 0
  local apt_list="" have_lists=0 aptopts=()
  # Pointed at another root, apt reads that root's status, lists and marks.
  [ -z "$ROOT" ] || aptopts=(-o "Dir=$ROOT/" -o "Dir::State::status=$ROOT/var/lib/dpkg/status")
  if command -v apt >/dev/null 2>&1; then
    # Without package lists (apt update never ran, or they were cleaned, as in
    # most container images) apt calls EVERY package "local". Then repository
    # and hand-installed cannot be told apart, and saying "dpkg" for all of
    # them would be a false alarm on every line.
    if compgen -G "$ROOT/var/lib/apt/lists/*_Packages*" >/dev/null; then
      have_lists=1
    else
      note "apt has no package lists (apt update never ran here), so repository and hand-installed .debs cannot be told apart"
    fi
    apt_list="$(apt "${aptopts[@]}" list --installed 2>/dev/null | tail -n +2 || true)"
  fi
  # Why each was installed comes from apt-mark, not from apt list's flags:
  # apt list drops "automatic" from any package that has an update, which made
  # every upgradable dependency look installed on purpose.
  local auto=""
  command -v apt-mark >/dev/null 2>&1 && auto="$(apt-mark "${aptopts[@]}" showauto 2>/dev/null || true)"
  # When each package was installed: the mtime of its file list, one stat call.
  local dates
  dates="$(find "$ROOT/var/lib/dpkg/info" -maxdepth 1 -name '*.list' -printf '%TY-%Tm-%Td\t%f\n' 2>/dev/null || true)"

  dpkg-query --admindir="$ROOT/var/lib/dpkg" -W -f='${db:Status-Abbrev}\t${Package}\t${Architecture}\t${Version}\t${Installed-Size}\t${binary:Summary}\n' 2>/dev/null |
  awk -F'\t' -v OFS='\t' -v havelists="$have_lists" -v hasapt="$([ -n "$apt_list" ] && echo 1 || echo 0)" \
      -v hasmark="$([ -n "$auto" ] && echo 1 || echo 0)" '
    FILENAME == "/dev/fd/5" { if ($0 != "") isauto[$0] = 1; next }
    FILENAME == "/dev/fd/3" {           # dates: "YYYY-MM-DD<TAB>pkg[:arch].list"
      f = $2; sub(/\.list$/, "", f); date[f] = $1; next
    }
    FILENAME == "/dev/fd/4" {           # apt: "name/suite,now ver arch [flags]"
      split($0, w, " "); split(w[1], ns, "/")
      key = ns[1] ":" w[3]
      suites = ns[2]; gsub(/(^|,)now(,|$)/, ",", suites); gsub(/^,|,$/, "", suites)
      flags = $0; sub(/.*\[/, "", flags); sub(/\].*/, "", flags)
      local_[key] = (flags ~ /local/)
      upd[key] = ""
      if (flags ~ /upgradable to: /) { u = flags; sub(/.*upgradable to: /, "", u); sub(/[,\]].*/, "", u); upd[key] = u }
      src[key] = suites
      seen[key] = 1
      next
    }
    $1 !~ /^ii/ { next }
    {
      name = $2; arch = $3; key = name ":" arch
      d = (key in date) ? date[key] : ((name in date) ? date[name] : "-")
      pm = hasapt ? "apt" : "dpkg"; explicit = "-"; source = "-"; update = "-"
      if (hasmark) explicit = ((name in isauto) || (key in isauto)) ? "no" : "yes"
      if (key in seen) {
        if (havelists && local_[key]) { pm = "dpkg"; source = "local .deb" }
        else if (src[key] != "") source = src[key]
        if (upd[key] != "") update = upd[key]
      }
      print name, $4, pm, arch, ($5 == "" ? "-" : $5), d, explicit, source, update, ($6 == "" ? "-" : $6)
    }' /dev/fd/5 /dev/fd/3 /dev/fd/4 - 3<<<"$dates" 4<<<"$apt_list" 5<<<"$auto"
}

collect_rpm() {
  command -v rpm >/dev/null 2>&1 || return 0
  local rootopt=() dnfroot=()
  [ -z "$ROOT" ] || { rootopt=(--root "$ROOT"); dnfroot=(--installroot "$ROOT"); }
  # rpm does not record why a package was installed; dnf does. -C: from its
  # local state only, never the network. Without dnf, explicit is unknown.
  local user=""
  if command -v dnf >/dev/null 2>&1; then
    user="$(dnf "${dnfroot[@]}" -C -q repoquery --userinstalled --qf '%{name}\n' 2>/dev/null || true)"
  fi
  rpm "${rootopt[@]}" -qa --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\t%{SIZE}\t%{INSTALLTIME}\t%{VENDOR}\t%{SUMMARY}\n' 2>/dev/null |
  awk -F'\t' -v OFS='\t' -v hasdnf="$([ -n "$user" ] && echo 1 || echo 0)" '
    FILENAME == "/dev/fd/3" { if ($0 != "") byuser[$0] = 1; next }
    $1 == "gpg-pubkey" { next }         # signing keys, not software
    {
      v = $2; sub(/^0:/, "", v)         # epoch 0 is the default; do not show it
      vendor = ($6 == "(none)" || $6 == "") ? "-" : $6
      explicit = hasdnf ? (($1 in byuser) ? "yes" : "no") : "-"
      print $1, v, "rpm", $3, int($4 / 1024), strftime("%Y-%m-%d", $5), explicit, vendor, "-", $7
    }' /dev/fd/3 - 3<<<"$user"
}

collect_pacman() {
  [ -d "$ROOT/var/lib/pacman/local" ] || return 0
  # The local database directly: one awk over every desc file, no pacman
  # process per package. %REASON% 1 means installed as a dependency; absent
  # means installed explicitly.
  find "$ROOT/var/lib/pacman/local" -mindepth 2 -maxdepth 2 -name desc -print0 2>/dev/null |
  xargs -0 -r awk -v OFS='\t' '
    function flush() {
      if (n != "") print n, v, "pacman", a, int(s / 1024), (d == "" ? "-" : strftime("%Y-%m-%d", d)),
                         (r == "1" ? "no" : "yes"), "-", "-", (desc == "" ? "-" : desc)
      n = v = a = s = d = r = desc = ""
    }
    FNR == 1 { flush() }
    /^%[A-Z]+%$/ { field = $0; next }
    /^$/ { field = ""; next }
    field == "%NAME%" { n = $0 } field == "%VERSION%" { v = $0 } field == "%ARCH%" { a = $0 }
    field == "%SIZE%" { s = $0 } field == "%INSTALLDATE%" { d = $0 } field == "%REASON%" { r = $0 }
    field == "%DESC%" { desc = $0 }
    END { flush() }'
}

collect_snap() {
  [ -z "$ROOT" ] || return 0            # snapd answers for the running system only
  command -v snap >/dev/null 2>&1 || return 0
  snap list --unicode=never --color=never 2>/dev/null | tail -n +2 |
  while read -r name version rev tracking publisher notes; do
    local file="/var/lib/snapd/snaps/${name}_${rev}.snap" size="-" date="-" explicit="yes"
    if [ -f "$file" ]; then
      size=$(( $(stat -c %s "$file") / 1024 ))
      date="$(date -d "@$(stat -c %Y "$file")" +%Y-%m-%d)"
    fi
    # Bases, snapd itself and the like are there because another snap needs them.
    case " ${notes:-} " in *" base "*|*" snapd "*|*" core "*) explicit="no" ;; esac
    case "$name" in core|core[0-9]*|snapd|bare) explicit="no" ;; esac
    # --unicode=never draws the verified-publisher check mark as "**".
    publisher="${publisher%\*\*}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$name" "$version" snap - "$size" "$date" "$explicit" "${tracking} (${publisher})" - -
  done
}

collect_flatpak() {
  [ -z "$ROOT" ] || return 0            # flatpak answers for the running system only
  command -v flatpak >/dev/null 2>&1 || return 0
  local kind
  for kind in app runtime; do
    flatpak list --"$kind" --columns=application,version,branch,arch,origin,installation,size,name 2>/dev/null |
    awk -F'\t' -v OFS='\t' -v explicit="$([ "$kind" = app ] && echo yes || echo no)" '
      function kb(s,   n, u) {         # "12.3 MB" -> KB
        n = s + 0; u = s; sub(/^[0-9.]+[[:space:]]*/, "", u)
        if (u ~ /^G/) return int(n * 1024 * 1024); if (u ~ /^M/) return int(n * 1024)
        if (u ~ /^k|^K/) return int(n); return (n > 0 ? int(n / 1024) : "-")
      }
      NF >= 5 {
        v = ($2 == "" ? $3 : $2)
        # Runtimes are installed side by side in several branches; flatpak
        # itself tells them apart as name//branch, and so does this.
        id = (explicit == "no" && $3 != "") ? $1 "//" $3 : $1
        print id, (v == "" ? "-" : v), "flatpak", ($4 == "" ? "-" : $4), kb($7), "-", explicit,
              $5 " (" $6 ")", "-", ($8 == "" ? "-" : $8)
      }'
  done
}

collect_manual() {
  # Owned by a package? Then it is that package's, not manual.
  # $1 is a path as the inspected system sees it (/opt/x), under $ROOT here.
  owned() {
    { [ -e "$ROOT/var/lib/dpkg/status" ] && dpkg --admindir="$ROOT/var/lib/dpkg" -S "$1" >/dev/null 2>&1; } ||
    { command -v rpm >/dev/null 2>&1 && rpm ${ROOT:+--root "$ROOT"} -qf "$1" >/dev/null 2>&1; } ||
    { command -v pacman >/dev/null 2>&1 && pacman ${ROOT:+--root "$ROOT"} -Qo "$1" >/dev/null 2>&1; }
  }
  local f path
  for f in "$ROOT"/usr/local/bin/* "$ROOT"/opt/*; do
    [ -e "$f" ] || continue
    [ -d "$f" ] || [ -x "$f" ] || continue
    path="${f#"$ROOT"}"
    owned "$path" && continue
    local size date
    size="$(du -sk "$f" 2>/dev/null | cut -f1)"
    date="$(date -d "@$(stat -c %Y "$f")" +%Y-%m-%d)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(basename "$f")" - manual - "${size:--}" "$date" yes "$path" - -
  done
}

# One package manager that cannot be read must not cost the whole list, nor
# pass for a complete one. Each collector runs on its own; a failure is named,
# the rest is still shown, the run exits non-zero, and the partial list is not
# saved — a later run would otherwise read it back as the truth.
INCOMPLETE=""
scan() {
  [ -z "$ROOT" ] || note "inventory of $ROOT; snap and flatpak are skipped (they describe the running system only)"
  local c raw; raw="$(mktemp)"
  for c in dpkg rpm pacman snap flatpak manual; do
    if ! "collect_$c" >> "$raw"; then
      note "could not read $c's package database; the list below is missing it"
      INCOMPLETE+=" $c"
    fi
  done
  clean < "$raw" | awk -F'\t' 'NF == 10' | LC_ALL=C sort -t$'\t' -f -k1,1 -k3,3
  rm -f "$raw"
}

# --- the saved list ------------------------------------------------------------

is_inventory() { case "$(head -1 "$1" 2>/dev/null)" in "$MARKER"|"$MARKER "*) return 0 ;; esac; return 1; }

save() { # rows-file
  local dir; dir="$(dirname "$CACHE")"
  if [ -e "$CACHE" ] && ! is_inventory "$CACHE"; then
    note "not saving: $CACHE exists and is not an inventory file (choose another --cache)"
    return 0
  fi
  mkdir -p "$dir"
  local tmp; tmp="$(mktemp "$dir/.inventory.XXXXXX")"
  { echo "$MARKER host=${ROOT:-$(hostname)} scanned=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "$COLUMNS_"
    cat "$1"; } > "$tmp"
  mv "$tmp" "$CACHE"
}

# A package database newer than the saved list means the list may be out of
# date. Said, not acted on: reading the saved list was asked for.
stale() {
  local db
  for db in /var/lib/dpkg/status /var/lib/rpm /var/lib/pacman/local /var/lib/snapd/state.json \
            /var/lib/flatpak /usr/local/bin /opt; do
    [ -e "$ROOT$db" ] && [ "$ROOT$db" -nt "$CACHE" ] && return 0
  done
  return 1
}

ROWS="$(mktemp)"
trap 'rm -f "$ROWS"' EXIT

if [ "$MODE" = "cached" ] && is_inventory "$CACHE"; then
  tail -n +3 "$CACHE" > "$ROWS"
  scanned="$(head -1 "$CACHE" | sed -n 's/.*scanned=\([^ ]*\).*/\1/p')"
  note "from the list saved $scanned in $CACHE (--refresh to scan again)"
  stale && note "a package database has changed since then; this list may be out of date"
else
  [ "$MODE" = "cached" ] && [ -e "$CACHE" ] && ! is_inventory "$CACHE" \
    && die "$CACHE is not an inventory file; choose another --cache"
  scan > "$ROWS"
  if [ -n "$INCOMPLETE" ]; then
    [ "$MODE" = "none" ] || note "not saving an incomplete list"
  elif [ "$MODE" != "none" ]; then
    save "$ROWS"
  fi
fi

# --- filter and render ----------------------------------------------------------

awk -F'\t' -v OFS='\t' -v fmt="$FORMAT" -v pms=" ${PMS[*]} " -v q="$SEARCH" \
    -v onlyexplicit="$EXPLICIT" -v onlyupdates="$UPDATES" -v cols="$COLUMNS_" '
  function human(kb) {
    if (kb !~ /^[0-9]+$/) return "-"
    if (kb >= 1048576) return sprintf("%.1fG", kb / 1048576)
    if (kb >= 1024) return sprintf("%.1fM", kb / 1024)
    return kb "K"
  }
  function cut(s, n) { return length(s) > n ? substr(s, 1, n - 1) "~" : s }
  function js(s) {
    gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s)
    return "\"" s "\""
  }
  BEGIN { split(cols, name, "\t") }
  {
    if (pms != "  " && index(pms, " " $3 " ") == 0) next
    if (q != "" && index(tolower($1 " " $10), tolower(q)) == 0) next
    if (onlyexplicit && $7 != "yes") next
    if (onlyupdates && ($9 == "-" || $9 == "")) next
    n++; for (i = 1; i <= 10; i++) row[n, i] = $i
    count[$3]++
  }
  END {
    if (fmt == "tsv") {
      print cols
      for (r = 1; r <= n; r++) { line = row[r, 1]; for (i = 2; i <= 10; i++) line = line "\t" row[r, i]; print line }
    } else if (fmt == "json") {
      printf "["
      for (r = 1; r <= n; r++) {
        printf "%s\n  {", (r > 1 ? "," : "")
        for (i = 1; i <= 10; i++) printf "%s%s: %s", (i > 1 ? ", " : ""), js(name[i]), js(row[r, i])
        printf "}"
      }
      print (n ? "\n]" : "]")
    } else {
      if (fmt == "table") { nc = split("1 2 3", c, " "); split("NAME VERSION PM", h, " ") }
      else { nc = split("1 2 3 4 5 6 7 8 9 10", c, " ")
             split("NAME VERSION PM ARCH SIZE INSTALLED EXPLICIT SOURCE UPDATE SUMMARY", h, " ") }
      for (r = 1; r <= n; r++) {
        row[r, 5] = human(row[r, 5]); row[r, 1] = cut(row[r, 1], 60)
        row[r, 2] = cut(row[r, 2], 36); row[r, 8] = cut(row[r, 8], 40)
      }
      for (j = 1; j <= nc; j++) { w[j] = length(h[j]); for (r = 1; r <= n; r++) if (length(row[r, c[j]]) > w[j]) w[j] = length(row[r, c[j]]) }
      line = ""; for (j = 1; j <= nc; j++) line = line (j < nc ? sprintf("%-" w[j] "s  ", h[j]) : h[j]); print line
      for (r = 1; r <= n; r++) {
        line = ""; for (j = 1; j <= nc; j++) line = line (j < nc ? sprintf("%-" w[j] "s  ", row[r, c[j]]) : row[r, c[j]]); print line
      }
      fflush()                           # the table first, then the count after it
      summary = ""; for (p in count) summary = summary sprintf("%s %d, ", p, count[p]); sub(/, $/, "", summary)
      printf "%d packages%s\n", n, (n ? " — " summary : "") > "/dev/stderr"
    }
  }' "$ROWS"

[ -z "$INCOMPLETE" ] || exit 1

#!/usr/bin/env bash
#
# bws-env.sh — materialise an environment's configuration from Bitwarden
# Secrets Manager: secrets from one or more projects, plus optional non-secret
# settings, as KEY='value' lines ready to source.
#
#   ./bws-env.sh --access-token-file ~/.config/bws/production \
#     --project <shared-project-id> --project <production-project-id> \
#     --vars production.vars --out .env.production
#
#   # in CI, the machine account's token on stdin:
#   printf '%s' "$BWS_ACCESS_TOKEN" | ./bws-env.sh --access-token-file - --project <id>
#
#   set -a; . ./.env.production; set +a        # use it
#
# Later wins: the --vars file first, then each --project in the order given. So
# list a shared project before an environment's own, and the environment can
# override anything shared. Each key appears once in the output, sorted.
#
# Options — every input is one; nothing is read from the environment:
#   --project <id>             a Secrets Manager project to read; repeatable,
#                              later ones win (at least one required)
#   --access-token-file <path> file holding the machine account's access
#                              token, or - for stdin (required). A file, never
#                              a value: argv is readable by every user via ps.
#   --vars <file>              non-secret KEY=value lines, read first; # starts
#                              a comment. For settings that belong in git.
#   --out <file>               write here, mode 0600, instead of stdout. Written
#                              whole or not at all.
#   --server-url <url>         a self-hosted Bitwarden server
#   -h, --help                 this text
#
# Values are single-quoted for the shell, so spaces, quotes, $, backticks and
# newlines — an SSH key, a cron expression — survive being sourced. A key that
# is not a valid shell variable name stops the run, rather than breaking
# whatever sources the output.
#
# Needs bws (Bitwarden's Secrets Manager CLI) and jq. Runs on a workstation or
# in CI, not on a target host.
set -euo pipefail
# set -e does not reach inside $(…) without this; a failed bws call there
# would otherwise be carried past.
shopt -s inherit_errexit

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '3,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

PROJECTS=() TOKEN_FILE="" VARS="" OUT="" SERVER_URL=""
while [ $# -gt 0 ]; do
  case "$1" in --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;; esac
  case "$1" in
    --project|--access-token-file|--vars|--out|--server-url)
      [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value (try --help)" ;;
  esac
  case "$1" in
    --project)           PROJECTS+=("$2"); shift 2 ;;
    --access-token-file) TOKEN_FILE="$2"; shift 2 ;;
    --vars)              VARS="$2"; shift 2 ;;
    --out)               OUT="$2"; shift 2 ;;
    --server-url)        SERVER_URL="$2"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *)                   die "unknown argument '$1' (try --help)" ;;
  esac
done
[ "${#PROJECTS[@]}" -gt 0 ] || die "--project is required (the Secrets Manager project id)"
[ -n "$TOKEN_FILE" ] || die "--access-token-file is required (a file, or - for stdin)"
[ -z "$VARS" ] || [ -r "$VARS" ] || die "--vars: cannot read $VARS"

command -v bws >/dev/null 2>&1 || die "bws not installed: https://bitwarden.com/help/secrets-manager-cli/"
command -v jq >/dev/null 2>&1 || die "jq not installed"

if [ "$TOKEN_FILE" = "-" ]; then
  ACCESS_TOKEN="$(cat)"
else
  [ -r "$TOKEN_FILE" ] || die "--access-token-file: cannot read $TOKEN_FILE"
  ACCESS_TOKEN="$(cat "$TOKEN_FILE")"
fi
ACCESS_TOKEN="${ACCESS_TOKEN%%[[:space:]]}"
[ -n "$ACCESS_TOKEN" ] || die "--access-token-file: $TOKEN_FILE is empty"

# bws reads its token, server, profile and config file from the environment
# too. Clear them all and hand over exactly what this run was given, so an
# unrelated `export` in the caller's shell cannot point it somewhere else. The
# token goes in the child's environment — readable only by this user — never
# in its argv.
bws_list() { # project-id
  local env=(-u BWS_ACCESS_TOKEN -u BWS_SERVER_URL -u BWS_PROFILE -u BWS_CONFIG_FILE
             "BWS_ACCESS_TOKEN=$ACCESS_TOKEN")
  [ -z "$SERVER_URL" ] || env+=("BWS_SERVER_URL=$SERVER_URL")
  env "${env[@]}" bws secret list "$1" --output json --color no
}

# Everything is merged as one JSON object, later keys replacing earlier ones,
# so the output has each key once — not a file that is only right if the reader
# happens to let the last duplicate win.
merged='{}'

if [ -n "$VARS" ]; then
  vars_json="$(jq -Rn '
    [inputs
     | select(test("^\\s*(#|$)") | not)
     | if test("=") then . else error("--vars: not KEY=value: \(.)") end
     | capture("^(?<k>[^=]*)=(?<v>.*)$")
     | {(.k): .v}] | add // {}' <"$VARS")" \
    || die "--vars $VARS: every line must be KEY=value, a # comment or blank"
  merged="$(jq -c --argjson add "$vars_json" '. + $add' <<<"$merged")"
fi

for id in "${PROJECTS[@]}"; do
  out="$(bws_list "$id" 2>&1)" \
    || die "bws could not read project $id — wrong access token, no access to that project, or a wrong id: $(head -1 <<<"$out")"
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$out" || die "bws returned something unexpected for project $id: $(head -c 200 <<<"$out")"
  [ "$(jq 'length' <<<"$out")" -gt 0 ] || die "project $id returned no secrets — wrong project id?"
  merged="$(jq -c --argjson add "$(jq -c 'map({(.key): .value}) | add' <<<"$out")" '. + $add' <<<"$merged")"
done

# A key that is not a shell name would break `set -a; . file` for everything
# after it, far from here. Name them now.
bad="$(jq -r 'keys[] | select(test("^[A-Za-z_][A-Za-z0-9_]*$") | not)' <<<"$merged")"
[ -z "$bad" ] || die "not valid variable names, rename them in Bitwarden or --vars: $(tr '\n' ' ' <<<"$bad")"

# @sh single-quotes the value and escapes any quote inside it.
render() { jq -r 'to_entries | sort_by(.key)[] | "\(.key)=\(.value | tostring | @sh)"' <<<"$merged"; }

if [ -z "$OUT" ]; then
  render
  exit 0
fi

# Written beside the target and moved into place: a run that fails half way
# leaves the previous file, never a truncated one, and the secrets are never
# on disk with a wider mode than 0600.
umask 077
tmp="$(mktemp "$(dirname "$OUT")/.bws-env.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
render >"$tmp"
chmod 600 "$tmp"
mv "$tmp" "$OUT"
trap - EXIT
echo "$OUT" >&2

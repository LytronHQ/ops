# secrets

An environment's secrets, from the secrets manager that holds them. One
action so far: **`env`**.

```sh
./secrets.sh env --help
```


Materialise an environment's configuration from a secrets manager: secrets from
one or more projects, plus optional non-secret settings, as `KEY='value'` lines
ready to source. The secrets manager holds the values; your repository holds, at
most, the non-secret settings and the project ids.

**Providers:** `bitwarden` — Bitwarden Secrets Manager. The module is named for
what it does; where the secrets live is `--provider`, so another secrets
manager would be a new branch in the same script, not a new script.

**Runs on:** your workstation or CI. Not on a target host.
**Needs:** bash 4.4+, [`bws`](https://bitwarden.com/help/secrets-manager-cli/)
and `jq`, and a machine-account access token with read access to the projects.

## Get it

```sh
./ops-get secrets.sh v5.0.0
```

## Use it

```sh
./secrets.sh env --access-token-file ~/.config/bws/production \
  --project <shared-project-id> --project <production-project-id> \
  --vars production.vars --out .env.production

set -a; . ./.env.production; set +a
```

In CI, where the token is already a secret variable, hand it over on stdin:

```sh
printf '%s' "$BWS_ACCESS_TOKEN" | ./secrets.sh env --access-token-file - --project <id>
```

**Later wins.** The `--vars` file is read first, then each `--project` in the
order given. List a shared project before an environment's own, and the
environment can override anything shared. Each key appears once in the output,
sorted.

One machine account per environment, each with read access to its own project
(and a shared one), and nothing else: then the wrong token fails to read the
project rather than quietly crossing environments.

## Options

Every input is a flag; `--help` lists them. Nothing is read from the
environment — `bws` itself is run with `BWS_ACCESS_TOKEN`, `BWS_SERVER_URL`,
`BWS_PROFILE` and `BWS_CONFIG_FILE` cleared and set only from these flags, so an
unrelated `export` in your shell cannot redirect it.

| Flag | Default | Meaning |
|---|---|---|
| `--provider <name>` | `bitwarden` | where the secrets live. Only `bitwarden` is implemented; anything else is refused before anything runs |
| `--project <id>` | required | a Secrets Manager project to read. Repeatable; later ones win |
| `--access-token-file <path>` | required | a file holding the machine account's access token, or `-` for stdin. Never the token itself as a value: a command line is readable by every user through `ps`. It reaches `bws` in that process's environment, not its arguments |
| `--vars <file>` | none | non-secret `KEY=value` lines, read first. Blank lines and `#` comments are skipped; the value is everything after the first `=`, taken literally |
| `--out <file>` | stdout | write here instead, mode `0600`. Written to a temporary file beside it and moved into place, so a failed run leaves the previous file as it was |
| `--server-url <url>` | Bitwarden's cloud | `bitwarden`: a self-hosted server |
| `-h`, `--help` | | print the options |

## What it guarantees

- **Values survive.** Each value is single-quoted for the shell, so quotes, `$`,
  backticks, newlines and leading spaces — an SSH key, a cron expression — come
  out of `set -a; . file` exactly as stored.
- **It fails closed.** A project it cannot read, a project with no secrets (most
  likely a wrong id), or a key that is not a valid shell variable name stops the
  run with the reason. A bad key would otherwise break whatever sources the file,
  somewhere far from here.
- **The token stays out of sight** of other users: never in an argument list,
  and the output file is `0600` from the moment it exists.

## Tests

`tests/secrets_test.sh` runs this script against `tests/fake-bws`, a stand-in
for the CLI serving known projects: awkward values round-tripping through
`source`, precedence, `--out` mode and an existing file surviving a failed run,
the token by file and stdin and never in `bws`'s argv, the caller's `BWS_*`
being ignored, and each failure case.

# cloudflare

Put a hostname behind Cloudflare Access for machines: an Access application,
one Service Auth policy, and the service tokens it admits. Replaces the
dashboard walkthrough, and is safe to re-run.

**Runs on:** your workstation or CI — wherever the secrets it prints need to
end up. Not on a target host.
**Needs:** bash 4.4+, `curl`, `jq`, and an API token with **Access: Apps and
Policies Write** and **Access: Service Tokens Edit** (both account-level).

## Get it

```sh
./ops-get cf-access.sh v3.0.0
```

## Use it

```sh
./cf-access.sh --hostname api.example.com --account-id <account id> \
  --api-token-file ~/.config/cloudflare/token \
  --token ci --token backup > credentials.env
```

In CI, where the API token is already a secret variable, hand it over on stdin:

```sh
printf '%s' "$CF_API_TOKEN" | ./cf-access.sh --api-token-file - --hostname … --account-id … --token ci
```

The first run creates everything and prints, for each token:

```
CF_ACCESS_CLIENT_ID_CI=…
CF_ACCESS_CLIENT_SECRET_CI=…
CF_ACCESS_CLIENT_ID_BACKUP=…
CF_ACCESS_CLIENT_SECRET_BACKUP=…
```

A client then sends `CF-Access-Client-Id` and `CF-Access-Client-Secret` headers
with those values. Progress goes to stderr, so stdout is only these lines.

**Store the secrets from that first run.** Cloudflare returns a service token's
secret once, at creation. A re-run prints the client ids but cannot print a
secret it does not have; to get a new one, rotate the token.

## Options

Every input is a flag; `--help` lists them. Nothing is read from the
environment. Unknown flags and missing values stop the run before any API call.

| Flag | Default | Meaning |
|---|---|---|
| `--hostname <host>` | required | the hostname to protect, e.g. `api.example.com` |
| `--account-id <id>` | required | Cloudflare account id |
| `--api-token-file <path>` | required | a file holding the API token, or `-` to read it from stdin. Never the token itself as a value: a command line is readable by every user through `ps`. The script passes it on to `curl` through a file descriptor, not as an argument, for the same reason |
| `--token <name>` | `<app name>-client` | a service token this run manages, created if missing. Repeatable. In the output, the name becomes upper case with anything not `A-Z0-9` turned into `_` |
| `--rotate <name>` | none | rotate one of the `--token` names: a new secret is printed and **the old one stops working immediately**. Repeatable. Naming a token that is not a `--token` is refused |
| `--app-name <name>` | the hostname | name of the Access application |
| `--policy-name <name>` | `service-tokens` | name of the policy |
| `--session <duration>` | `24h` | the application's session duration |
| `--api-base <url>` | Cloudflare's API | base URL; the tests point it at a stub |

## What it changes

| Object | Result |
|---|---|
| Access application | created for `--hostname` if none exists, type `self_hosted` |
| Service tokens | each `--token` created if missing, duration `forever`; rotated if also a `--rotate` |
| Policy | one policy, `decision: non_identity`, including this run's tokens **and** any already in it that still exist |

It never deletes a token. To revoke one, delete it in Cloudflare; the next run
drops it from the policy.

## What it protects you from

Each of these happened where this script came from.

- **Losing a secret to a failed run.** A secret exists once, in the process
  that minted it. Whatever it has minted is printed on *every* exit path, so a
  failure later in the run costs a re-run rather than a credential. Store what
  it prints, then honour the exit status.
- **Locking out another consumer.** Tokens already in the policy are kept even
  when this run does not name them, so each consumer can manage its own token
  from wherever that secret needs to go.
- **A second door.** Access ORs policies. If the application has any policy
  besides this one, the run fails and names it.
- **Two applications sharing a token.** The default token name comes from the
  application, so a second application never silently reuses the first one's
  token — whose secret it could not know.

## Tests

`tests/cf-access_test.sh` runs this script against a stub of the Access API
(`tests/cf_api_stub.py`): first run, idempotent re-run, partial runs keeping
other tokens, a deleted token dropping out, scoped rotation, a run dying after a
mint, the second-policy guard, bad input, and that the API token is read from
the file or stdin and sent.

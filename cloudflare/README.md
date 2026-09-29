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
./ops-get cf-access.sh v2.0.0
```

## Use it

```sh
CF_API_TOKEN=… CF_ACCOUNT_ID=… ACCESS_HOSTNAME=api.example.com \
ACCESS_TOKENS="ci backup" ./cf-access.sh > credentials.env
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

## Parameters

Environment variables, because the usual caller is another script or a CI job.

| Variable | Default | Meaning |
|---|---|---|
| `CF_API_TOKEN` | required | API token with the permissions above |
| `CF_ACCOUNT_ID` | required | Cloudflare account id |
| `ACCESS_HOSTNAME` | required | the hostname to protect, e.g. `api.example.com` |
| `ACCESS_TOKENS` | `<app name>-client` | service tokens this run manages, space separated. Each is created if missing. In the output, a name becomes upper case with anything not `A-Z0-9` turned into `_` |
| `ACCESS_ROTATE` | none | which of `ACCESS_TOKENS` to rotate. A new secret is printed and **the old one stops working immediately**. Naming a token not in `ACCESS_TOKENS` is refused |
| `ACCESS_APP_NAME` | the hostname | name of the Access application |
| `ACCESS_POLICY_NAME` | `service-tokens` | name of the policy |
| `ACCESS_SESSION` | `24h` | the application's session duration |
| `CF_API_BASE` | Cloudflare's API | base URL; the tests point it at a stub |

## What it changes

| Object | Result |
|---|---|
| Access application | created for `ACCESS_HOSTNAME` if none exists, type `self_hosted` |
| Service tokens | each in `ACCESS_TOKENS` created if missing, duration `forever`; rotated if in `ACCESS_ROTATE` |
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
mint, and the second-policy guard.

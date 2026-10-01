# edge

How traffic reaches a service from outside: a **tunnel** to it, so it needs no
open port, and an **access** gate in front of it, so only machines holding a
service token get through. Together they put a private service behind
Cloudflare.

**Runs on:** your workstation or CI.
**Providers:** `cloudflare`, the default.
**Needs:** bash 4.4+, `curl`, `jq`.

## Get it

```sh
./ops-get edge.sh v5.0.0
```

```sh
./edge.sh tunnel --help
./edge.sh access --help
```

## tunnel

Make a private service reachable at a hostname through a tunnel, without opening
a port: create, or find, the tunnel, point it at the service, publish the
hostname, and print the token a connector runs with. Safe to re-run.

With [`access`](#access) in front, only machines holding a service token get
through — the two together put a private service behind Cloudflare.

**Runs on:** your workstation or CI. The *connector* runs beside the service.
**Providers:** `cloudflare` (Cloudflare Tunnel).
**Needs:** bash 4.4+, `curl`, `jq`, and an API token with **Cloudflare Tunnel
Edit** (account) and **DNS Edit** (zone).

### Use it

```sh
./edge.sh tunnel --hostname app.example.com --origin http://app:8080 \
  --account-id <account id> --api-token-file ~/.config/cloudflare/token > tunnel.env
```

```
TUNNEL_TOKEN=eyJhIjoi…
```

Only that line goes to stdout; progress goes to stderr. Then, beside the service:

```sh
docker run -d --network <the service's network> cloudflare/cloudflared:latest \
  tunnel --no-autoupdate run --token "$TUNNEL_TOKEN"
```

The token lets anyone run a connector for this tunnel: keep it as a secret.

### The origin

`--origin` is resolved **where the connector runs**, not here. When the connector
is a container beside the service, use the service's container name —
`http://app:8080` — which Docker's DNS resolves on their shared network.

The host's private address looks equivalent and is not. The traffic leaves the
container from the Docker bridge and meets the host's firewall; if that allows
the port only from the private subnet — as [`server.sh harden --allow`](../server/)
sets it up — it is dropped, and every request times out while the service
answers fine from the host itself.

### Options

Every input is a flag; `--help` lists them. Nothing is read from the environment.

| Flag | Default | Meaning |
|---|---|---|
| `--provider <name>` | `cloudflare` | who provides the tunnel; only `cloudflare` is implemented |
| `--hostname <host>` | required | the public name |
| `--origin <url>` | required | where the connector sends traffic: `http://`, `https://`, `tcp://`, `ssh://`… |
| `--account-id <id>` | required | Cloudflare account id |
| `--api-token-file <path>` | required | a file holding the API token, or `-` for stdin. Passed to `curl` through a file descriptor, never as an argument |
| `--zone <name>` | from the hostname | the DNS zone. Without it, the longest suffix of the hostname that is a zone the token can see — the hostname itself first, for an apex |
| `--name <name>` | the hostname | the tunnel's name; how a re-run finds it |
| `--replace-dns` | | replace DNS records at the hostname that are not this tunnel's |
| `--api-base <url>` | Cloudflare's API | the tests point it at a stub |

### What it changes

| Object | Result |
|---|---|
| Tunnel | created if no live tunnel has `--name`, remotely managed — the connector needs only the token. A deleted tunnel with the same name is never reused |
| Ingress | `--hostname` → `--origin`, then the catch-all `http_status:404` the API requires |
| DNS | one **proxied** CNAME to `<tunnel>.cfargotunnel.com`. Proxied always: an unproxied record would publish the tunnel's address and skip everything in front of it, Access included |

**An existing DNS record that is not this tunnel's stops the run**, before
anything is created, and is named. The script this came from replaced it
silently — an `A` record pointing at a real server included. `--replace-dns`
says that is intended, and then every record at the name goes: a CNAME cannot
share a name with other records.

### Tests

`tests/tunnel_test.sh` runs the script against a stub of the API
(`tests/cloudflare_tunnel_stub.py`) with `curl` behind a shim that records its
arguments: the first run's tunnel, ingress, proxied CNAME and token-only output;
idempotent re-runs and an updated origin; a deleted tunnel not reused; a stray
`A`/`AAAA` refused before any change, and replaced with `--replace-dns`; zone
discovery including an apex; a wrong token; the token never in `curl`'s argv;
bad input.

## access

Gate a hostname so only machines holding a service token get through. Replaces
the dashboard walkthrough, and is safe to re-run.

**Providers:** `cloudflare` — Cloudflare Access: an Access application, one
Service Auth policy, and the service tokens it admits. The module is named for
what it does; who does it is `--provider`, so another provider would be a new
branch in the same script, not a new script.

**Runs on:** your workstation or CI — wherever the secrets it prints need to
end up. Not on a target host.
**Needs:** bash 4.4+, `curl`, `jq`, and for `cloudflare` an API token with **Access: Apps and
Policies Write** and **Access: Service Tokens Edit** (both account-level).

### Use it

```sh
./edge.sh access --hostname api.example.com --account-id <account id> \
  --api-token-file ~/.config/cloudflare/token \
  --token ci --token backup > credentials.env
```

In CI, where the API token is already a secret variable, hand it over on stdin:

```sh
printf '%s' "$CF_API_TOKEN" | ./edge.sh access --api-token-file - --hostname … --account-id … --token ci
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

### Options

Every input is a flag; `--help` lists them. Nothing is read from the
environment. Unknown flags and missing values stop the run before any API call.

| Flag | Default | Meaning |
|---|---|---|
| `--provider <name>` | `cloudflare` | who provides the gate. Only `cloudflare` is implemented; anything else is refused before any API call |
| `--hostname <host>` | required | the hostname to protect, e.g. `api.example.com` |
| `--account-id <id>` | required | `cloudflare`: account id |
| `--api-token-file <path>` | required | a file holding the API token, or `-` to read it from stdin. Never the token itself as a value: a command line is readable by every user through `ps`. The script passes it on to `curl` through a file descriptor, not as an argument, for the same reason |
| `--token <name>` | `<app name>-client` | a service token this run manages, created if missing. Repeatable. In the output, the name becomes upper case with anything not `A-Z0-9` turned into `_` |
| `--rotate <name>` | none | rotate one of the `--token` names: a new secret is printed and **the old one stops working immediately**. Repeatable. Naming a token that is not a `--token` is refused |
| `--app-name <name>` | the hostname | name of the Access application |
| `--policy-name <name>` | `service-tokens` | name of the policy |
| `--session <duration>` | `24h` | the application's session duration |
| `--api-base <url>` | Cloudflare's API | base URL; the tests point it at a stub |

### What it changes

| Object | Result |
|---|---|
| Access application | created for `--hostname` if none exists, type `self_hosted` |
| Service tokens | each `--token` created if missing, duration `forever`; rotated if also a `--rotate` |
| Policy | one policy, `decision: non_identity`, including this run's tokens **and** any already in it that still exist |

It never deletes a token. To revoke one, delete it in Cloudflare; the next run
drops it from the policy.

### What it protects you from

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

### Tests

`tests/access_test.sh` runs this script against a stub of the Access API
(`tests/cloudflare_api_stub.py`): first run, idempotent re-run, partial runs keeping
other tokens, a deleted token dropping out, scoped rotation, a run dying after a
mint, the second-policy guard, bad input, and that the API token is read from
the file or stdin and sent.

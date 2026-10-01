# tunnel

Make a private service reachable at a hostname through a tunnel, without opening
a port: create, or find, the tunnel, point it at the service, publish the
hostname, and print the token a connector runs with. Safe to re-run.

With [`access`](../access/) in front, only machines holding a service token get
through — the two together put a private service behind Cloudflare.

**Runs on:** your workstation or CI. The *connector* runs beside the service.
**Providers:** `cloudflare` (Cloudflare Tunnel).
**Needs:** bash 4.4+, `curl`, `jq`, and an API token with **Cloudflare Tunnel
Edit** (account) and **DNS Edit** (zone).

## Get it

```sh
./ops-get tunnel.sh v4.3.0
```

## Use it

```sh
./tunnel.sh --hostname app.example.com --origin http://app:8080 \
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

## The origin

`--origin` is resolved **where the connector runs**, not here. When the connector
is a container beside the service, use the service's container name —
`http://app:8080` — which Docker's DNS resolves on their shared network.

The host's private address looks equivalent and is not. The traffic leaves the
container from the Docker bridge and meets the host's firewall; if that allows
the port only from the private subnet — as [`harden.sh --allow`](../harden/)
sets it up — it is dropped, and every request times out while the service
answers fine from the host itself.

## Options

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

## What it changes

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

## Tests

`tests/tunnel_test.sh` runs the script against a stub of the API
(`tests/cloudflare_tunnel_stub.py`) with `curl` behind a shim that records its
arguments: the first run's tunnel, ingress, proxied CNAME and token-only output;
idempotent re-runs and an updated origin; a deleted tunnel not reused; a stray
`A`/`AAAA` refused before any change, and replaced with `--replace-dns`; zone
discovery including an apex; a wrong token; the token never in `curl`'s argv;
bad input.

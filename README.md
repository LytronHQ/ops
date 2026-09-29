# ops

Scripts for the boring parts of running a machine. Each one is a single
self-contained file with no imports and nothing about my projects baked in.

| Module | What it does | Runs on |
|---|---|---|
| [`harden/`](harden/) | firewall, auto-updates, fail2ban, key-only SSH | the server you are configuring |
| [`vmlab/`](vmlab/) | throwaway libvirt VMs, with or without sudo | your own machine |

Every script is fetched the same way, whichever machine it runs on: `ops-get`
downloads it from a pinned release and verifies its checksum. There is no second
route to document or to forget to verify. Cloning the repo is for working on
it, not for using it.

Each module is a folder with its own README: what its scripts do, every
parameter, and what it changes on the machine. This page is about `ops-get`.

## ops-get

A fresh server has `curl` and little else. `ops-get` fetches one script from a
pinned release and verifies it before it ever runs.

```sh
curl -fsSL https://github.com/LytronHQ/ops/releases/download/v1.0.0/ops-get -o ops-get
chmod +x ops-get

./ops-get harden.sh v1.0.0 /tmp/harden.sh
sudo /tmp/harden.sh
```

### Arguments

```sh
ops-get <script> <version> [destination]
```

| Argument | Required | Meaning |
|---|---|---|
| `<script>` | yes | the asset filename, e.g. `harden.sh`. No path — release assets are flat |
| `<version>` | yes | a release tag, e.g. `v1.0.0`. There is deliberately no "latest" |
| `[destination]` | no | where to write it. Default: `./<script>` |

| Variable | Default | Meaning |
|---|---|---|
| `OPS_REPO` | `LytronHQ/ops` | whose releases to fetch from — point it at your fork |
| `OPS_BASE_URL` | GitHub releases | the whole base URL, for a mirror or an air-gapped copy |

Needs `curl` or `wget`, plus `sha256sum` or `shasum`. It is POSIX `sh`, because
it is the first thing that runs on a new host and cannot afford a dependency.

### What it guarantees

It downloads the script **and** the release's `SHA256SUMS`, compares them, and
only then writes the file.

It refuses, leaving nothing behind, when:

- the release has no `SHA256SUMS`
- the script is not listed in it
- the hash does not match

A provisioning run that stops loudly beats one that quietly configures a host
with the wrong bytes.

### Two things it does not do

**Verify itself.** Whatever fetches `ops-get` has nothing to check it against.
If that matters, vendor the file into your own repository — it is 40 lines — so
it carries your git history instead.

**Work against a private repo.** Fetching an asset from a private release needs
a token, and putting a GitHub token on every host you are about to harden trades
one problem for a worse one.

## Releasing

Push a tag. The workflow checks every script parses, publishes them as flat
release assets, and writes the `SHA256SUMS` that `ops-get` verifies against.
Nothing is consumable from a branch on purpose: a consumer pins a version or
does not run at all.

Script filenames must be unique across the whole repo, since assets are flat.

## Licence

MIT.

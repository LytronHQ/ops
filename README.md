# ops

Scripts for the boring parts of running a machine. Each one is a single
self-contained file with no imports and nothing about my projects baked in.

| Module | What it does | Runs on | Scripts |
|---|---|---|---|
| [`harden/`](harden/) | firewall, auto-updates, fail2ban, key-only SSH | the server you are configuring | `harden.sh` |
| [`vmlab/`](vmlab/) | libvirt VMs without sudo: a throwaway lab or a single VM | your own machine | `vmlab.sh` |
| [`cloudflare/`](cloudflare/) | Cloudflare Access for machines: app, policy, service tokens | your machine or CI | `cf-access.sh` |

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
curl -fsSL https://github.com/LytronHQ/ops/releases/download/v1.1.0/ops-get -o ops-get
echo "4609e46737242a91b3d17c049d0d64ae91dd01d2f04c6bcb9913d446deca9450  ops-get" | sha256sum -c
chmod +x ops-get

./ops-get harden.sh v1.1.0 /tmp/harden.sh
sudo /tmp/harden.sh
```

The second line checks `ops-get` itself against the hash printed here, before
it runs. Everything after that, `ops-get` checks for you.

### Arguments

```sh
ops-get <script> <version> [destination]
```

| Argument | Required | Meaning |
|---|---|---|
| `<script>` | yes | the asset filename, e.g. `harden.sh`. No path — release assets are flat |
| `<version>` | yes | a release tag, e.g. `v1.1.0`. There is deliberately no "latest" |
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

**Verify itself.** Something has to check `ops-get` before it can check
anything else. That is the hash on this page: it is only as trustworthy as this
repository, which is also true of the release. For more than that, vendor the
file into your own repository — it is about 50 lines — so it carries your own
reviewed history instead.

**Work against a private repo.** Fetching an asset from a private release needs
a token, and putting a GitHub token on every host you are about to harden trades
one problem for a worse one.

## Releasing

A release is every script as a flat asset, `ops-get`, and the `SHA256SUMS` that
`ops-get` verifies against. Nothing is consumable from a branch on purpose: a
consumer pins a version or does not run at all.

Script filenames must be unique across the whole repo, since assets are flat.
Anything under a `tests/` directory is never an asset. Working on the repo —
module shape, tests — is in [CONTRIBUTING.md](CONTRIBUTING.md).

`.github/workflows/release.yml` does all of this when a `v*` tag is pushed. When
Actions is unavailable, build the same thing locally from a clean checkout of
the tag:

```sh
for f in $(find . -name '*.sh' -not -path './.git/*') ops-get; do
  sh -n "$f" 2>/dev/null || bash -n "$f" || echo "does not parse: $f"
done
./run-tests
find . -mindepth 2 -name '*.sh' -not -path './.git/*' -not -path '*/tests/*' -printf '%f\n' | sort | uniq -d   # must print nothing

rm -rf dist && mkdir dist
find . -mindepth 2 -name '*.sh' -not -path './.git/*' -not -path './dist/*' -not -path '*/tests/*' -exec cp {} dist/ \;
cp ops-get dist/
(cd dist && sha256sum * > SHA256SUMS)
gh release create vX.Y.Z dist/* --verify-tag --title vX.Y.Z --notes "..."
```

If a release changes `ops-get`, update its hash in the quick start above in
the same commit.

## Licence

MIT.

# ops

Scripts for the boring parts of running a machine. Each one is a single
self-contained file with no imports and nothing about my projects baked in.

| Module | What it does | Runs on | Scripts |
|---|---|---|---|
| [`harden/`](harden/) | firewall, auto-updates, fail2ban, key-only SSH | the server you are configuring | `harden.sh` |
| [`vmlab/`](vmlab/) | libvirt VMs without sudo: a throwaway lab or a single VM | your own machine | `vmlab.sh` |
| [`access/`](access/) | gate a hostname so only machines with a service token get through (Cloudflare) | your machine or CI | `access.sh` |
| [`tunnel/`](tunnel/) | reach a private service at a hostname without opening a port (Cloudflare) | your machine or CI | `tunnel.sh` |
| [`secrets/`](secrets/) | an environment's config from a secrets manager, ready to source (Bitwarden) | your machine or CI | `secrets.sh` |
| [`inventory/`](inventory/) | installed software, and which package manager put it there | the machine being inspected, Linux or Windows | `inventory.sh`, `inventory.ps1` |
| [`cleanup/`](cleanup/) | reclaim disk space: package caches, old temp files, journal, logs, dumps — reports first | the machine being cleaned, Linux or Windows | `cleanup.sh`, `cleanup.ps1` |
| [`upgrade/`](upgrade/) | upgrade a containerised service, snapshot first, roll back image and data on failure | the host running it | `upgrade.sh` |

Every script is fetched the same way, whichever machine it runs on: `ops-get`
downloads it from a pinned release and verifies its checksum. There is no second
route to document or to forget to verify. Cloning the repo is for working on
it, not for using it.

Each module is a folder with its own README: what its scripts do, every
option, and what it changes on the machine. Every input is a flag, and `--help`
lists them. This page is about `ops-get`; how the repo is built and why is in
[CONTRIBUTING.md](CONTRIBUTING.md) and [DECISIONS.md](DECISIONS.md).

## ops-get

A fresh server has `curl` and little else. `ops-get` fetches one script from a
pinned release and verifies it before it ever runs.

```sh
curl -fsSL https://github.com/LytronHQ/ops/releases/download/v4.3.0/ops-get -o ops-get
echo "841b8f34d7d4481f966f1026e935c770291d2f82cac13eebd7cf1c0944f63081  ops-get" | sha256sum -c
chmod +x ops-get

./ops-get --list v4.3.0                    # what this version has
./ops-get harden.sh v4.3.0 /tmp/harden.sh
sudo /tmp/harden.sh
```

The second line checks `ops-get` itself against the hash printed here, before
it runs. Everything after that, `ops-get` checks for you.

### On Windows

`ops-get.ps1` does the same in PowerShell — Windows PowerShell 5.1, which every
Windows has, or PowerShell 7:

```powershell
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'   # Windows PowerShell 5.1 needs this for GitHub
Invoke-WebRequest https://github.com/LytronHQ/ops/releases/download/v4.3.0/ops-get.ps1 -OutFile ops-get.ps1 -UseBasicParsing
if ((Get-FileHash .\ops-get.ps1).Hash -ne '922D98A16DE563C299DBF8D3692B193215ED566FABA1B024639C09876F43DE9B') { throw 'ops-get.ps1 does not match' }

powershell -ExecutionPolicy Bypass -File .\ops-get.ps1 -List v4.3.0
powershell -ExecutionPolicy Bypass -File .\ops-get.ps1 inventory.ps1 v4.3.0
```

`-ExecutionPolicy Bypass` because Windows blocks unsigned downloaded scripts by
default; the hash check above is what stands in for a signature. Options are
PowerShell-style — `-List`, `-Repo`, `-BaseUrl`, `-Help` — with the same
meaning as below.

### Usage

```sh
ops-get <script> <version> [destination]
ops-get --list <version>
```

| Argument | Required | Meaning |
|---|---|---|
| `<script>` | yes | the asset filename, e.g. `harden.sh`. No path — release assets are flat |
| `<version>` | yes | a release tag, e.g. `v4.3.0`. There is deliberately no "latest" |
| `[destination]` | no | where to write it. Default: `./<script>` |

| Flag | Default | Meaning |
|---|---|---|
| `--list <version>` | | print the scripts in that version — the ones its `SHA256SUMS` vouches for. A script that does not run on this machine is still listed, marked `unsupported on <platform> (runs on: …)`, from the release's `MANIFEST`. Releases before v4.3.0 have no `MANIFEST`, and nothing is marked |
| `--repo <owner/name>` | `LytronHQ/ops` | whose releases to fetch from — point it at your fork |
| `--base-url <url>` | GitHub releases | the whole release URL, for a mirror or an air-gapped copy |
| `-h`, `--help` | | print usage; so does running it with no arguments |

Nothing is read from the environment. Before v4.3.0 the last two were the
`OPS_REPO` and `OPS_BASE_URL` variables; they are no longer read.

Needs `curl` or `wget`, plus `sha256sum` or `shasum`. It is POSIX `sh`, because
it is the first thing that runs on a new host and cannot afford a dependency.

### What it guarantees

It downloads the script **and** the release's `SHA256SUMS`, compares them, and
only then writes the file.

It refuses, leaving nothing behind, when:

- the version's `SHA256SUMS` cannot be fetched — the version does not exist,
  or was published minutes ago and is not served yet, or has no checksums
- the script is not listed in it; the error names the scripts that are
- the hash does not match; the error prints both
- the release's `MANIFEST` does not match `SHA256SUMS` — it says where scripts
  run, so an unverified one is a claim nobody checked

Fetching a script that does not run on this machine still works — it may be
for another machine — with a note saying so.

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

A release is every script as a flat asset, `ops-get`, a `MANIFEST`, and the
`SHA256SUMS` that `ops-get` verifies against. Nothing is consumable from a branch on purpose: a
consumer pins a version or does not run at all.

Script filenames must be unique across the whole repo, since assets are flat.
Anything under a `tests/` directory is never an asset. Working on the repo —
module shape, tests — is in [CONTRIBUTING.md](CONTRIBUTING.md).

`./build-release` builds exactly that into `dist/`, plus a `MANIFEST` of where
each script runs, from its `# platforms:` line. The release workflow runs it
when a `v*` tag is pushed. When Actions is unavailable, run it yourself from a
clean checkout of the tag:

```sh
./run-tests
./build-release
gh release create vX.Y.Z dist/* --verify-tag --title vX.Y.Z --notes "..."
```

It refuses to build when a script does not parse, has no `# platforms:` line,
or shares a name with another module's script.

If a release changes `ops-get`, update its hash in the quick start above in
the same commit.

## Licence

MIT.

# Decisions

Why the repository is shaped the way it is, newest first. Each entry is a
decision someone might otherwise undo without knowing what it cost. The rules
that follow from them are in [CONTRIBUTING.md](CONTRIBUTING.md).

A new decision is added here in the PR that makes it.

---

### Modules are named for the capability; the vendor is a provider

2026-09-30 · #36

`bws-env.sh` was named after Bitwarden's CLI and the file format it produced,
`cf-access.sh` after an abbreviated vendor — both carried over from where they
came from without being revisited. Names are now the operational capability,
from this repository's point of view: `access/access.sh` gates a service,
`secrets/secrets.sh` gets an environment's secrets. Cloudflare and Bitwarden
became `--provider`, the same pattern as the OS for `harden.sh`: a future
provider is a branch in the same script, not a new script and not a breaking
change. Renamed scripts are a major version, v4.0.0.

### ops-get lists a release, explains what is missing, and takes flags

2026-09-29 · #33

Using v2.0.0 on a fresh server: with no arguments `ops-get` printed a shell
error with a line number; there was no way to see which scripts a version had;
and a fetch in the seconds before v2.0.0 was published reported "no harden.sh
in v2.0.0" when the whole release did not exist yet. It now fetches
`SHA256SUMS` first — the proof and the table of contents — says when a version
is missing or still being published, names the scripts a release has, and
lists them with `--list`.

`OPS_REPO` and `OPS_BASE_URL` became `--repo` and `--base-url`, finishing #24.
Removing them is breaking, so this went straight to v3.0.0 rather than a
v2.1.0 with a deprecation period: v2.0.0 was minutes old.

### Every input is a flag; secrets come from files, never argv

2026-09-29 · #24, #25, #26, #27, #28

Modules read their inputs from environment variables. A misspelt one
(`HARDEN_ALOW`) was silently ignored, a value could leak in from an unrelated
`export`, and the command that ran did not show what it used. Every input
became a flag; unknown flags are errors.

Secrets are the exception to "a flag with a value": argv is readable by every
user through `ps`. They come from `--…-file`, or `-` for stdin. Converting
`cf-access.sh` showed the rule has to reach child processes too: it had been
passing the API token to `curl` as `-H "Authorization: Bearer …"` on every
request. A `curl` shim logging its argv found the token in 36 of 38 calls;
after the change, in none.

### One vmlab script, named for what it does

2026-09-29 · #17, #18

Four scripts were named after tools in a `create-vm.<provider>.<ext>` scheme
that was never finished; two names said `virt-manager`, which none of them
used. A single VM turned out to be a lab of one, so the sudo + `virt-install`
path was folded into `vmlab.sh` with its useful part (Launchpad keys) and
removed.

Renamed without compatibility aliases: published releases never change, so
anyone pinned to v1.x keeps working, and aliases would be duplicate code to
maintain. A rename is a major version.

### Tests run the real script against stubs, and must be shown to fail

2026-09-29 · #19, #22

Until then everything was verified by hand on VMs: thorough, not repeatable.
From the project these scripts came from: a test runs the real script against
a stub server or a fake CLI, never a copy of its logic. Tests live in their
module's `tests/` and are never release assets.

Each suite is mutation-checked — break the guarded behaviour, watch it fail.
That is how two bugs were found in the Cloudflare script brought over for
#20: `set -e` does not see a failed `$(…)` in a here-string, and does not apply
inside `$(…)` at all without `inherit_errexit`. Both let a failed API call
carry on with an empty token id.

### Reproducible releases; ops-get's own hash in the README

2026-09-29 · #3, #16

v1.1.0 was built both by the release workflow and locally from the same signed
tag; the `SHA256SUMS` were identical. When Actions is unavailable — it was, for
a while — the local build is the documented fallback, not an improvisation.

`ops-get` cannot verify itself, so its SHA-256 is printed beside the download
command. That hash is fixed before the tag exists, and trusting it means
trusting this repository — which is what trusting the release already meant.

### Changed defaults are a major version

2026-09-29 · #2, and in hindsight

v1.1.0 changed vmlab's default VM name prefix (`mon-` to `vmlab-`) in a minor
release. Nothing was published that depended on it, but it was a breaking
change under the wrong number. Since then: a changed default, like a renamed or
removed script or flag, is a major version.

### Verify on real machines; report the machine's actual state

2026-09-29 · #6, #7, #8, #9, #12

Running v1.0.0 on lab VMs the way a user would found problems that reading had
not, and every one had exited `0`:

- the firewall allowed port 22 while sshd listened on 2222 — locked out
- password SSH was disabled for an operator with no key — locked out
- an earlier sshd drop-in overrode the change, which was reported as done
- a firewall rule ufw rejected was reported as added
- fail2ban did not start on Debian 12, and banned the wrong port elsewhere
- apt was locked on a freshly booted server, the one time this script runs
- vmlab printed the previous lab's IP addresses

Hence: exit non-zero whenever a step was declined or failed; read the result
back from the system (`sshd -T`, `ufw status`, `systemctl is-active`) instead of
trusting that a file was written; and test on Ubuntu and Debian VMs before
merging anything that touches a host.

### One script per capability, branching by OS family inside it

2026-09-29 · #6

To support another distribution later, the choice was a script per
distribution, a dispatcher fetching one, or one script branching inside.
`harden.sh` reads `/etc/os-release`, refuses an unimplemented family before
changing anything, and keeps what differs behind one function. A dispatcher was
ruled out: `ops-get` verifies exactly one file, and anything that file fetched
would run unverified.

### Every module is fetched with ops-get, including those for your own machine

2026-09-29 · #1, #4

The module table said servers get scripts with `ops-get` and workstations
clone the repo. Two ways meant two sets of instructions, and one skipped the
checksum. This repo exists to hand out single, pinned, checksummed files; clone
it to work on it.

### Every change is an issue and a PR; everything is written in English

2026-09-29

Nothing lands on `main` directly. One problem, one issue, one PR that says how
it was verified. Code, comments, commits, issues and PRs are in English.

### One folder, one capability, one README

2026-09-29 · 10d3315

The first layout split scripts into `remote/` and `local/`, which is a property
of a script, not a way to organise a repository. Folders became modules, each
with a README covering every option and what it changes on the machine. The
root README is only about `ops-get`.

### Pinned releases, verified, and no "latest"

2026-09-29 · b321082, 8926bbf

The scripts were extracted from a real deployment so they could be reused
anywhere. They are distributed as flat release assets with a `SHA256SUMS`, and
`ops-get` fetches one, verifies it and fails closed — a provisioning run that
stops loudly beats one that configures a host with the wrong bytes. There is no
"latest": a consumer pins a version or does not run. Flat assets mean script
names must be unique across modules, which the release enforces.

The repository stays public. Fetching from a private release needs a token,
and putting a GitHub token on every host you are about to harden is worse than
the problem it solves.

What runs on a target host is shell with no dependencies: a fresh server is
where you cannot install a runtime first.

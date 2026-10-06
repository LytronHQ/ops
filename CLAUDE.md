# CLAUDE.md

Instructions for coding agents working on this repo. The details live in
[CONTRIBUTING.md](CONTRIBUTING.md) (how a module is built, tested and named),
[DECISIONS.md](DECISIONS.md) (why) and [README.md](README.md) (ops-get and
releasing); read the relevant one before changing something.

## Project
- Purpose: standalone ops scripts (server hardening, cleanup, inventory,
  container upgrades, database maintenance, edge tunnels, secrets, throwaway
  VMs), published as GitHub releases and fetched onto machines by `ops-get`,
  which verifies each one against the release's `SHA256SUMS`.
- Stack: bash and POSIX sh (Linux), PowerShell 5.1 and 7 (Windows), Python 3
  only for test stubs. No Cloudflare Workers, no web UI, no database, no
  deployment: the product is a release.

## Commands
- Install: nothing to install. Tests need `bash`, `python3` and `curl`;
  PowerShell suites need `pwsh` (Linux) or `powershell`/`pwsh` (Windows).
- Build: `./build-release --out dist` (assets, `MANIFEST`, `SHA256SUMS`).
- Test: `./run-tests` (exit 77 from a suite means skipped, not passed).
- Lint: no linter is enforced. CI checks every shell script parses:
  `sh -n <file> || bash -n <file>`; `build-release` parse-checks `.ps1` files
  and refuses non-ASCII ones.
- Local dev: not applicable (no server). Run a script directly, with
  `--help`, against fakes or `--root`.
- Real-machine test of `server.sh harden`: only on a disposable machine, as
  CI does: `sudo env OPS_TEST_DISPOSABLE=1 bash server/tests/harden_test.sh`.

## GitHub workflow
- For every feature, bug, or problem, create a GitHub issue first.
- Create a branch and a PR that closes the issue. Never commit or push to
  `main` directly (an org ruleset enforces this). When the work is done, tests
  pass and CI is green, merge the PR yourself.
- The PR says what changed, why, how it was verified (commands and output),
  and what was not verified.
- If a task must be done by the repo owner (a GitHub or Cloudflare setting,
  anything that cannot be done in code), create an issue, assign it to the
  owner, label it `needs-owner`, and do not try to do it yourself.
- Commits are GPG-signed; never disable signing.
- No AI attribution anywhere: no Co-Authored-By trailer, no "Generated with"
  footer, in commits, PRs, issues or release notes.
- Everything in the repo and on GitHub is in English. Conversation with the
  owner may be in Persian.

## Writing owner issues — accuracy rule (IMPORTANT)
- Never invent UI steps for an external service (GitHub, Cloudflare,
  Bitwarden, etc.). Before writing step-by-step instructions, read the
  official current docs for that exact service and base the steps on them.
- If a step cannot be verified from the docs, say plainly: "Could not verify
  this step — please check," and link the relevant docs page.

## Repo rules that have cost a bug or a near-miss
- Every input is a flag, never an environment variable. Secrets come in via a
  `--…-file` flag or `-` (stdin), never as an argv value.
- Destructive modes run only against fakes, a `--root` fake filesystem, or a
  disposable VM or CI runner — never against the machine you are working on.
- Run the script, do not only read it. Tests run the real script against
  stubs; a new check gets a mutation test (break the code, see the test fail).
- PowerShell files are ASCII only (5.1 reads a BOM-less file as
  Windows-1252). The bash and PowerShell pitfalls already hit are listed in
  CONTRIBUTING.md; check them before writing either.

## Versioning & release
- Versions are semver tags `vX.Y.Z` with no "latest"; CONTRIBUTING.md says
  what is major, minor and patch.
- There is no sandbox environment and no `sandbox` branch: features and fixes
  go through issue → branch → PR into `main`. A release is a signed tag on
  `main` (`git tag -s vX.Y.Z`), pushed; the release workflow runs the tests,
  builds the assets and publishes them. Published releases never change.
- After a release: verify from an empty directory (ops-get's hash against the
  new `SHA256SUMS`, `ops-get --list`, a fetch), set the release notes (what
  changed, a migration table for a major, the new `ops-get` and
  `ops-get.ps1` hashes), and update the hashes in README.md through a PR.
- Visual testing, PWA updates and a visible build version do not apply: there
  is no UI. The version is the release tag.

## Environments
- Local: the scripts and `./run-tests`. CI: GitHub Actions (Linux tests, the
  real harden job, Windows PowerShell 5.1 and 7).
- No sandbox or production deployment. Consumers (e.g. nabz) pin a release
  tag and the `ops-get` hash.

## Data safety
- Tests use stubs and fake CLIs on `PATH`, never real services, real
  credentials or real servers.

## Open tasks
- Kept on GitHub: https://github.com/LytronHQ/ops/issues

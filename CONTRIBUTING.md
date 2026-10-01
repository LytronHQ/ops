# Working on ops

The [README](README.md) is for using these scripts. This is for changing them:
the rules the repo is built by. Why each rule exists, and when it was decided,
is in [DECISIONS.md](DECISIONS.md) — read the entry before changing a rule, and
add one when you make a new decision.

## A module

One folder, one capability, one README.

- **Every script says where it runs** in a `# platforms: linux macos windows`
  header line — only platforms it has actually been run on. The release turns
  these into `MANIFEST`, and `ops-get --list` marks what does not run on the
  machine asking. A script without the line does not build.
- **Scripts are single files.** No imports, no sourcing a sibling: a user fetches
  one file with `ops-get` and runs it. Anything shared is copied, not linked.
- **Every module is got the same way**, with `ops-get`, whichever machine it
  runs on. Cloning is for working on the repo.
- **Nothing about a particular project.** Every project-specific value is an
  option. Before adding a module extracted from somewhere, search it for
  hostnames, account ids, product names and paths from where it came from, and
  say in the PR that you did.
- **Windows scripts are PowerShell** (`.ps1`), and run on **Windows PowerShell
  5.1** — the one every Windows has — as well as PowerShell 7: no `??`, no
  ternary, TLS 1.2 set explicitly for web requests. They are **plain ASCII**:
  5.1 reads a file without a BOM as Windows-1252, where part of a UTF-8 em
  dash is a curly quote, which PowerShell treats as a string delimiter. The
  build refuses a `.ps1` with anything else. Options are PowerShell-style
  (`-List`, `-Wide`) with the same names as the shell twin's flags.
- **What runs on a target host is POSIX-ish shell with no dependencies.** A
  fresh server is exactly where you cannot install a runtime first. What runs on
  your own machine or in CI may need `jq`, `curl` and the like; the module
  README says so.
- **The module README covers every option** — name, default, meaning — and what
  the script changes on the machine, and is updated in the same commit as the
  script.
- **Comments say why**, especially where something non-obvious cost real time.
  If a line looks removable and is not, the comment says what breaks.

## Inputs

- **Every input is a flag.** A script reads nothing from the environment except
  what describes the invocation itself (`HOME`, `XDG_CACHE_HOME`, `SUDO_USER`).
  A misspelt variable is silently ignored; a misspelt flag is an error.
- `--help` lists every flag with its default. Unknown flags and missing values
  are errors. `--flag value` and `--flag=value` both work. A list is a
  repeatable flag, and may also take commas.
- **Validate everything before changing anything.** A bad value stops the run
  while the machine is still untouched, with a message naming the flag.
- **Secrets are never values on a command line** — argv is readable by every
  user through `ps` and ends up in shell history. A secret comes from a
  `--<thing>-file <path>` flag, where `-` means stdin.
- **Nor on a child's command line.** Pass a secret on to `curl` through a file
  descriptor (`-H @<(…)`), and to a CLI through its environment. Test it: a shim
  first on `PATH` that logs its argv.
- **A child reads only what you give it.** Clear the environment variables a
  tool would read on its own (as `secrets.sh` does with `bws`'s `BWS_*`), then set them
  from flags.

## Behaviour

- **Idempotent.** Running it twice is the same as running it once.
- **Honest exit status.** `0` only when every step that ran actually took
  effect. Anything declined or failed is printed with `!!` and exits non-zero.
- **Check the result, not the intent.** Read back what the system will actually
  do (`sshd -T`, `ufw status`, `systemctl is-active`) instead of trusting that a
  file was written.
- **Destructive commands never default to everything.** `destroy` needs a name
  or `--all`. `rm` on a path built from a variable uses `${var:?}`.
- **Never cut off the person running it.** Anything touching SSH or the firewall
  checks first that the next login will still work.

## Platforms and providers

One script per capability, not per distribution or vendor. The script reads
`/etc/os-release`, refuses a family it does not implement before changing
anything, and keeps what differs between families behind one function. Adding a
family is a new branch in that function, tested on that family's cloud image in
the lab (`vmlab.sh create --image …`). A vendor works the same way, behind
`--provider`. Never a dispatcher that fetches
per-distribution scripts: `ops-get` verifies exactly one file.

## Names and versions

- **A name is the operational capability**, from this repo's point of view —
  harden a host, run a VM lab, gate a service, get an environment's secrets.
  Not the tool it wraps (`bws`, `virsh`), not the vendor (Bitwarden,
  Cloudflare), not the form of its output (an env file). The module folder and
  the script share that name.
- **The vendor is a `--provider`**, as the OS is for `server.sh harden`: a branch
  inside the one script, defaulting to the one implemented and refusing the
  rest. Flags only one provider uses are documented as that provider's.
- **Names are unique across the whole repo**: release assets are flat, and the
  release refuses two scripts with the same filename.
- **Versions are semver, and there is no `latest`.** Consumers pin a tag.
  - **major**: a script renamed or removed, a flag renamed or removed, a default
    changed, an output format changed
  - **minor**: a new script, module or flag
  - **patch**: a fix that changes nothing a caller relies on
- **A rename has no compatibility alias.** Published releases never change, so
  whoever pinned the old version keeps working; the new major is where the new
  name lives.

## Verifying a change

Run it; do not only read it. Most bugs fixed here were found by executing the
script, and several looked like correct code.

### Tests

```sh
./run-tests
```

A test runs the **real** script against a stub — a small HTTP server, or a fake
CLI first on `PATH` — never a re-implementation of its logic, then checks what
the stub recorded and what the script printed.

- It lives in the module it tests: `<module>/tests/<script>_test.sh`, with its
  stubs beside it. Tests for `ops-get` live in `tests/` at the root.
- It is a bash script that exits 0 and prints `PASS` last on success, and
  cleans up after itself. It may need what a developer machine has — bash,
  curl, python3, jq — and nothing else.
- It picks a free port rather than a fixed one.
- PowerShell suites are `*_test.ps1`. `./run-tests` runs them with `pwsh` when
  it is installed; CI runs them on Windows under both 5.1 and 7. A suite ends
  with an explicit `exit 0` — otherwise its exit code is whatever the last
  deliberately failing command left behind.
- A suite that does not apply to the platform it is on exits **77** and is
  reported as skipped, never as passed.
- **Check that it can fail**: break the behaviour it guards and watch it go red.
  A test that has never failed has not been shown to test anything. Say in the
  PR which mutations you tried.
- `tests/` directories are never release assets.

CI runs the parse check and `./run-tests` on every PR, and again before a
release is published.

### On real machines

What a stub cannot stand in for — a kernel, a firewall, sshd, libvirt — is run
on VMs made with `vmlab.sh`: Ubuntu by default, Debian with
`--image` pointing at its `genericcloud` image. Use a fresh VM per scenario; a
test that locks SSH out of a VM is a success, not a problem. The PR records what
was run and what came back.

Something not verified is said to be not verified, in the PR, with the reason.

**A destructive mode runs only against fakes, a `--root` copy, or a lab VM —
never the machine you develop on**, not even "just to see the message". A
`--apply` run meant to check a note about root once pruned the development
machine's own Docker images.

## Shell pitfalls that have already cost a bug here

- `set -e` does not apply inside `$(…)` unless `shopt -s inherit_errexit` is on:
  a `die` in a command substitution ends only the subshell.
- `set -e` is also off for everything inside a function called from `if`,
  `!`, `&&` or `||`: a function run as `if ! clean_x; then` carries on past its
  own failures. Such a function checks each step, `cmd || return 1`.
- `[ -f x ] && cmd` as the last line of a loop or function makes it return 1
  when the test is false. Use `if`, and end with `return 0`.
- `read x <<<"$(cmd)"` does not fail when `cmd` does. Assign first
  (`out="$(cmd)"`), then `read`.
- Under `pipefail`, `producer | grep -q` can fail *after a match*: grep exits,
  the producer gets SIGPIPE. Capture the output, then test it.
- `pwsh -Command '<script>' a b` does not pass `a b` to the script — it appends
  them to the command and runs them. To hand PowerShell arguments, use `-File`.
- Through `powershell -File`, an array argument (`-Only a,b`) arrives as
  separate arguments, and the extra ones bind by position to other parameters.
  Scripts declare `PositionalBinding = $false` so that is an error, and
  callers through `-File` pass a list as one string: `-Only 'a,b'`.
- In PowerShell 5.1, `ConvertFrom-Json` returns a JSON array as one object;
  pipe it on (`| ForEach-Object { $_ }`) to enumerate it on both engines.
- An action is a scriptblock inside `<subject>.ps1`, so two things behave
  unlike a script of its own: `$script:` is the file's scope, not the action's
  — share state through an object mutated in place, a list's `.Add()` — and a
  function returning an empty array returns `$null`, which a typed parameter
  no longer turns back into an array: return arrays as `return ,@(…)`.
- `ssh` inside `while read` eats the loop's input; use `ssh -n`.
- In zsh, `$var` does not word-split. Test harness loops belong in bash.

## Changes

- Every change starts as an **issue** and lands as a **PR** that closes it, from
  a branch, never straight to `main`. One problem, one issue, one PR.
- The PR says what changed, why, how it was verified — commands and output —
  and what was not verified.
- CI must be green before merging.
- Commits are signed. Messages explain why, not only what.
- Everything in the repository and on GitHub is written in **English**: code,
  comments, commits, issues, PRs, release notes.

## Releasing

See [Releasing](README.md#releasing) in the README.

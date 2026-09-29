# Working on ops

The [README](README.md) is for using these scripts. This is for changing them.

## A module

One folder, one capability, one README.

- **Scripts are single files.** No imports, no sourcing a sibling: a user fetches
  one file with `ops-get` and runs it. Anything shared is copied, not linked.
- **Names say what the script does**, not which tool it wraps, and are unique
  across the whole repo: release assets are flat, and the release refuses two
  scripts with the same filename.
- **Nothing about a particular project.** Every project-specific value is a
  parameter. Before adding a module extracted from somewhere, search it for
  hostnames, account ids, product names and paths from where it came from.
- **What runs on a target host is POSIX-ish shell with no dependencies.** A
  fresh server is exactly where you cannot install a runtime first. What runs on
  your own machine or in CI can need `jq`, `curl` and the like; say so in the
  module README.
- **The module README covers every parameter** — name, default, meaning — and
  what the script changes. Change it in the same commit as the script.
- **Comments say why**, especially where something non-obvious cost real time.

## Tests

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
- Check that it can fail: break the behaviour it guards, and watch it go red.
- `tests/` directories are never release assets.

Some things a stub cannot stand in for: `harden.sh` needs a real kernel, firewall
and sshd, and `vmlab.sh` needs libvirt. Those are verified on lab VMs made with
`vmlab.sh` itself, and the PR records what was run and what came back.

CI runs the parse check and `./run-tests` on every PR, and again before a
release is published.

## Changes

Every change starts as an issue and lands as a PR that closes it, from a
branch, never straight to `main`. Commits are signed.

## Releasing

See [Releasing](README.md#releasing) in the README.

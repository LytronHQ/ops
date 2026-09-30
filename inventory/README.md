# inventory

What software is on a machine, and which package manager put each piece there.
The first question when taking over a server, auditing one, or rebuilding it.

**Runs on:** the machine being inspected — or any machine, pointed at another
system's files with `--root`.
**Platforms:** Linux. Windows is next.
**Needs:** bash and the usual tools. Nothing to install. It only reads: it never
asks a package manager to refresh, and never touches the network.

## Get it

```sh
./ops-get inventory.sh v4.2.0
```

## Use it

```sh
./inventory.sh                            # name, version, package manager
./inventory.sh --wide                     # every column
./inventory.sh --pm dpkg,manual           # what did not come from a repository
./inventory.sh --explicit                 # only what someone installed on purpose
./inventory.sh --updates --wide           # what has a newer version known locally
./inventory.sh --search firefox
./inventory.sh --format json > inventory.json
./inventory.sh --refresh                  # scan again instead of reading the saved list
```

```
NAME           VERSION  PM      ARCH  SIZE  INSTALLED   EXPLICIT  SOURCE                 UPDATE  SUMMARY
curl-sh-app    -        manual  -     4K    2026-09-30  yes       /opt/curl-sh-app       -       -
in-house-tool  1.2.3    dpkg    all   -     2026-09-30  yes       local .deb             -       built by hand
mytool         -        manual  -     4K    2026-09-30  yes       /usr/local/bin/mytool  -       -
3 packages — dpkg 1, manual 2
```

## The PM column

| PM | Means |
|---|---|
| `apt` | a `.deb` from a configured repository |
| `dpkg` | a `.deb` installed by hand, found in no repository — usually what deserves a second look |
| `rpm` | Fedora, RHEL and relatives |
| `pacman` | Arch and relatives |
| `snap`, `flatpak` | app stores |
| `manual` | no package manager: an executable in `/usr/local/bin`, or a directory in `/opt` that no package owns — the `curl \| sh` installs, which most inventories miss |

When apt has no package lists — `apt update` never ran, or they were cleaned,
as in most container images — every package looks "local" to apt. Then it
cannot tell a repository package from a hand-installed one, says so, and calls
them all `apt` rather than raising a false alarm on every line.

## Columns

| Column | table | wide | Meaning |
|---|---|---|---|
| name, version, PM | ✓ | ✓ | flatpak runtimes, installed side by side, are `name//branch`; an rpm epoch of 0 is not shown |
| arch | | ✓ | |
| size | | ✓ | installed size |
| installed | | ✓ | date installed, where the package manager records one |
| explicit | | ✓ | `yes` installed on purpose, `no` pulled in as a dependency, `-` unknown. From `apt-mark`, pacman's install reason, and dnf's history for rpm |
| source | | ✓ | repository suite, snap channel and publisher, flatpak remote, rpm vendor, or the path of a manual install |
| update | | ✓ | a newer version known from apt's local package lists — no network |
| summary | | ✓ | one line |

## The saved list

Every scan is saved **in full** — every column, whatever format was asked for
— and later runs read that list instead of scanning again. By default it is
`~/.cache/ops/inventory.tsv`.

- `--refresh` scans again and replaces it.
- `--no-cache` scans without reading or writing it.
- Reading it, a note says when it was made, and warns when a package database
  has changed since. It does not rescan on its own.
- It never overwrites a file that is not an inventory, wherever `--cache`
  points.
- A scan that could not read one of the package managers is shown, with the
  failure named and exit status `1`, but **not saved**: a later run would read
  a partial list back as the whole.

## Options

Every input is a flag; `--help` lists them. Nothing is read from the environment
except `HOME` and `XDG_CACHE_HOME`, which say where the saved list lives.

| Flag | Default | Meaning |
|---|---|---|
| `--wide` | | the wide table; same as `--format wide` |
| `--format <f>` | `table` | `table`, `wide`, `tsv` (every column, with a header) or `json` |
| `--pm <list>` | all | only these package managers; repeatable, or comma separated |
| `--search <text>` | | only names or summaries containing this, in any case |
| `--explicit` | | only what was installed on purpose |
| `--updates` | | only what has a newer version known locally |
| `--refresh` | | scan now and replace the saved list |
| `--no-cache` | | scan now; neither read nor write the saved list |
| `--cache <path>` | `~/.cache/ops/inventory.tsv` | where the saved list lives |
| `--root <dir>` | `/` | inventory the system mounted at `<dir>`: a disk, a chroot, an unpacked container image. dpkg/apt, rpm, pacman and manual installs are read from it; snap and flatpak answer only for the running system and are skipped. Not saved unless `--cache` is given, so another system's list never replaces this one's |
| `-h`, `--help` | | print the options |

## Tests

`tests/inventory_test.sh` builds a fake system and runs the script with
`--root` against it: the real `dpkg-query` and `apt` read a status file, a
repository index and apt's marks; pacman's database is real files; `rpm` and
`dnf` are fakes on `PATH`. It covers apt vs dpkg, explicit, updates, dates,
manual installs and ownership, every format and filter, the saved list's rules,
a package database that cannot be read, and bad input.

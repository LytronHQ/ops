# server

Preparing and looking after a machine: **harden** it, **clean** it up, take
**inventory** of what is installed on it.

| Action | Linux (`server.sh`) | Windows (`server.ps1`) |
|---|---|---|
| `harden` | firewall, automatic security updates, fail2ban, key-only SSH | — |
| `cleanup` | reclaim disk space; reports first | the same, for Windows |
| `inventory` | installed software, and which package manager put it there | the same, for Windows |

## Get it

```sh
./ops-get server.sh v5.0.0
./server.sh <action> --help
```

```powershell
powershell -ExecutionPolicy Bypass -File .\ops-get.ps1 server.ps1 v5.0.0
.\server.ps1 <action> -Help
```

## harden

Bring a fresh Linux host to a sane baseline: ufw denying inbound except SSH,
unattended security updates, fail2ban, and password SSH login disabled.

**Runs on:** the host being hardened.
**Supports:** the Debian family (Ubuntu, Debian). Anything else is refused
before a single change is made.
**Language:** POSIX-ish bash, no dependencies beyond what Ubuntu ships. A fresh
server is the one place you cannot install a runtime first.

### Use it

```sh
./ops-get server.sh v5.0.0 /tmp/server.sh
sudo /tmp/server.sh harden
```

Keep one extra port open — say a database only your private network reaches:

```sh
sudo /tmp/server.sh harden --allow 10.0.0.0/16:5432
```

[`ops-get`](../README.md#ops-get) is how every module is fetched: a pinned
release, checked against its `SHA256SUMS` before it is written.

### Options

Every input is a flag; `--help` lists them. Nothing is read from the
environment except `SUDO_USER`, which sudo sets to say who ran it. Unknown
flags and bad values stop the run before anything changes. `--flag value` and
`--flag=value` both work.

| Flag | Default | Meaning |
|---|---|---|
| `--allow <source>:<port>[/proto]` | none | keep a port open to a source. Repeatable, or comma separated: `--allow 10.0.0.0/16:5432,192.168.1.0/24:8090/udp` is two rules. Protocol is `tcp` or `udp`, default `tcp`. An IPv6 source works: `2001:db8::/32:5432`. Anything not listed, other than SSH, is denied. Every rule is checked before anything changes, and one bad rule stops the run |
| `--skip <step>` | none | a step to leave alone: `firewall`, `updates`, `fail2ban` or `ssh`. Repeatable, or comma separated. Use it when one of them is managed elsewhere |
| `--login-user <user>` | whoever ran sudo, else root | the user whose authorised key must exist before password SSH is turned off. Set it when you log in as a different user from the one running the script |
| `--ssh-tag <name>` | `hardening` | names the files it writes: `/etc/ssh/sshd_config.d/10-<name>.conf` and `/etc/fail2ban/jail.d/<name>.local`. Change it if something else on the host already uses that name |
| `-h`, `--help` | | print the options |

Must run as root. Rerunning is safe: every step is idempotent.

On a freshly booted server apt is often still locked by cloud-init or
`apt-daily`; it waits up to 10 minutes for the lock rather than failing. apt's
own output is hidden unless it fails, and the run ends with the host's actual
state — firewall rules, services, SSH password login — read back from the
system.

Exit status is `0` only when every step that was not skipped actually took
effect. Anything it declined or failed to do is printed with `!!` and makes it
exit `1`, so a provisioning run cannot mistake a half-hardened host for a
hardened one.

### What it actually changes

| Step | Result |
|---|---|
| firewall | `ufw` enabled, default deny inbound, allow outbound, the port(s) sshd listens on allowed, plus anything in `--allow` |
| updates | `unattended-upgrades` enabled with a daily package-list refresh |
| fail2ban | installed and enabled; its `sshd` jail reads journald and bans the same port(s) the firewall allows SSH on, via `/etc/fail2ban/jail.d/<name>.local`. The stock jail reads `/var/log/auth.log`, which Debian 12 does not have, and bans port 22 whatever sshd uses |
| ssh | a drop-in disabling password and keyboard-interactive auth, and root password login |

### It will not lock you out

The part worth reading even if you use nothing else here. Each of these was a
real lockout, found by running the script on a VM rather than by reading it.

- **SSH on another port.** The firewall allows the port sshd actually listens
  on — from its config and from `ssh.socket` — not "port 22".
- **No key yet.** It disables **password** SSH only, and only when the user
  logging in (`--login-user`, default whoever ran sudo) has an authorised key. A server handed over
  as root + password keeps its password login, and the run exits `1` saying why.
- **Something else re-enabling passwords.** sshd keeps the first value it reads,
  so a drop-in that sorts earlier silently wins. After reloading, it asks sshd
  for the effective setting, and if passwords are still on it names the file
  responsible and exits `1`.
- **A broken config.** The change is a drop-in validated with `sshd -t` and
  **removed again if that fails**. The service is *reloaded*, not restarted, so
  the session you are running it from is never dropped.

Hardening scripts that lock you out of the machine you are hardening are a
genre. This one tries not to join it.

## cleanup

Reclaim disk space from what a machine accumulates and does not need. **It
reports by default** — how much each category would free — and deletes nothing
without `--apply`.

**Runs on:** the machine being cleaned, or another system's files with `--root`.
**Platforms:** Linux (`server.sh cleanup`) and Windows (`server.ps1 cleanup`).
**Needs:** bash and the usual tools; `--apply` needs root.

### Use it

```sh
./server.sh cleanup                          # what would be freed; nothing is deleted
sudo ./server.sh cleanup --apply             # clean, and report what was freed
./server.sh cleanup --only journal,temp
sudo ./server.sh cleanup --apply --older-than 14 --journal-max 1G
```

```
CATEGORY       RECLAIMABLE   ITEMS  HOW
package-cache       111.6M       7  apt-get clean
temp                  3.0M       3  untouched for 7+ days
journal              15.6M       -  kept to 500M (journalctl --vacuum-size)
rotated-logs          1.0M       3  older than 30 days
crash-dumps           1.0M       1  older than 7 days
thumbnails           58.6K       3  regenerated on demand
total               132.3M
(a report: nothing was deleted. --apply to clean.)
```

With `--apply` the column is **FREED**: each category is sized again afterwards,
so the number is what actually went, not what was hoped for.

### Categories

| Category | What goes | How |
|---|---|---|
| `package-cache` | downloaded packages | `apt-get clean`, `dnf clean packages`, `pacman -Sc` — pacman keeps the versions installed |
| `temp` | files in `/tmp` and `/var/tmp` untouched for 7 days — by modification, access *and* change time, as `systemd-tmpfiles` judges — and directories that become empty | deleted; never inside `systemd-private-*`, `snap-private-tmp` or the X11 socket directories |
| `journal` | the systemd journal beyond `--journal-max` | `journalctl --vacuum-size`. Only archived journal files can go, so that is all it ever claims |
| `rotated-logs` | `.gz`, `.xz`, `.bz2`, `.zst`, `.old` and numbered logs in `/var/log` older than 30 days | deleted; never the current log, never the journal |
| `crash-dumps` | `/var/crash` and systemd coredumps older than 7 days | deleted |
| `thumbnails` | each user's `~/.cache/thumbnails` | deleted; regenerated when needed |

**Never touched:** documents, downloads, the trash, other caches — anything a
user made.

#### Opt-in categories

Run only when named, with `--include` (or `--only`): each removes something
that is junk on most machines and wanted on some.

| Category | What goes | How |
|---|---|---|
| `docker` | dangling images — untagged leftovers of rebuilt ones — and the build cache | `docker image prune` (never `--all`), `docker builder prune`. **Never** tagged images, containers, volumes or networks. Sized by each image's *unique* size: plain sizes count shared layers once per image and overstate it |
| `autoremove` | packages installed only as dependencies of something since removed — old kernels included, by apt's own policy of keeping two | `apt-get autoremove`, `dnf autoremove`, pacman orphans (`-Qtdq` → `-Rns`). Opt-in because "a dependency" is the package manager's record, not the user's intent |
| `snap-revisions` | revisions snap lists as **disabled** — kept after each refresh, often hundreds of MB each | `snap remove <name> --revision=<rev>`; the active revision is never touched |

Under `--root`, `autoremove` and `snap-revisions` are reported and never
applied. apt's `-o Dir` moves where it *reads*, but removing a package still
runs the host's `dpkg` — applying there could remove packages from the machine
itself. snapd answers only for the running system.

```sh
./server.sh cleanup --include docker
./server.sh cleanup --apply --include docker      # as anyone who can reach the daemon, rootless too
sudo ./server.sh cleanup --apply --include autoremove,snap-revisions
```

### On Windows

```powershell
powershell -ExecutionPolicy Bypass -File .\\server.ps1 cleanup             # report
powershell -ExecutionPolicy Bypass -File .\\server.ps1 cleanup -Apply      # clean
.\\server.ps1 cleanup -Only temp,crash-dumps -OlderThan 14
```

| Category | What goes | How |
|---|---|---|
| `temp` | your `%TEMP%` and `C:\Windows\Temp`: files neither written nor created for 7 days, and folders that become empty | deleted |
| `update-downloads` | `C:\Windows\SoftwareDistribution\Download`, not written for 7 days | deleted |
| `delivery-optimization` | the Delivery Optimization cache | `Delete-DeliveryOptimizationCache` |
| `crash-dumps` | `C:\Windows\Minidump`, `C:\Windows\MEMORY.DMP`, your `CrashDumps`, older than 7 days | deleted |
| `error-reports` | Windows Error Reporting `ReportArchive` and `ReportQueue`, yours and the system's, older than 7 days | deleted |
| `thumbnails` | Explorer's `thumbcache_*.db` | deleted; rebuilt on demand |

- A file in use is left, and the report says how many — not a failure.
- **Without administrator rights** your own files are sized and cleaned and the
  system's are left alone, which it says. Cleaning your own files needs no
  elevation.
- Options are PowerShell-style — `-Apply`, `-Only`, `-Skip`, `-Include`,
  `-OlderThan`, `-Format`, `-Help` — with the same meaning as below.

Opt-in on Windows, with `-Include`:

| Category | What goes | How |
|---|---|---|
| `components` | superseded components in the component store (WinSxS) | `DISM /StartComponentCleanup`. DISM reports how many packages are reclaimable but not how many bytes, so the size shows as `?` until cleaned; then freed is the store's actual size before minus after. Administrator; minutes, not seconds |
| `recycle-bin` | the Recycle Bin on every drive | `Clear-RecycleBin`. User data — the reason it is opt-in |
| `package-caches` | Scoop's download cache and old app versions — never the one `current` points to — and Chocolatey's download cache | `scoop cache rm` / `scoop cleanup` where Scoop is installed, the same folders otherwise |

### Options

Every input is a flag; `--help` lists them. Nothing is read from the environment
except `HOME`, for whose thumbnails when not root.

| Flag | Default | Meaning |
|---|---|---|
| `--apply` | | clean. Without it nothing is deleted. Without root, only what needs none — your thumbnails, a Docker daemon you can reach — is cleaned, and the rest is named as left for root |
| `--only <list>` | all | only these categories; repeatable, or comma separated |
| `--skip <list>` | none | all but these |
| `--include <list>` | none | add opt-in categories |
| `--older-than <days>` | 7, 30, 7 | one age limit for `temp`, `rotated-logs` and `crash-dumps`. `0` means any age — for a machine about to become an image, not a live one |
| `--journal-max <size>` | `500M` | keep the journal to this size: `K`, `M` or `G` |
| `--format <f>` | `table` | `table`, `tsv` or `json` |
| `--root <dir>` | `/` | clean the system mounted at `<dir>` |
| `-h`, `--help` | | print the options |

Without root it still reports, with a note that some files cannot be read and
sizes may be incomplete.

Exit status is `1` when a category could not be sized or cleaned; it is named,
and the others still run.

### Tests

`tests/cleanup_test.ps1` runs `server.ps1 cleanup` on a real Windows — GitHub's
runners, under Windows PowerShell 5.1 and PowerShell 7 — with `TEMP` and
`LOCALAPPDATA` pointed at test folders, ages set back through `CreationTime`
and `LastWriteTime`, a test file in `C:\Windows\Temp`, a locked file, and files
that must survive.

`tests/cleanup_test.sh` builds a fake system and runs the script with `--root`:
the real `apt-get` cleans its cache; pacman's and dnf's are checked for what
would be reported (both tools were run for real in Fedora and Arch containers).
It covers a report deleting nothing, every category's junk going and the exact
amount reported, user files and protected directories surviving, the default
ages keeping fresh files, pacman's rule of keeping installed versions, a
failing tool failing the run, and bad input. A fake `docker` on `PATH` records
every call: the only changes it may be asked for are `image prune --force` and
`builder prune --force`.

## inventory

What software is on a machine, and which package manager put each piece there.
The first question when taking over a server, auditing one, or rebuilding it.

**Runs on:** the machine being inspected — or any machine, pointed at another
system's files with `--root`.
**Platforms:** Linux (`server.sh inventory`) and Windows (`server.ps1 inventory`) — the same
columns, formats, filters and saved list on both.
**Needs:** bash and the usual tools. Nothing to install. It only reads: it never
asks a package manager to refresh, and never touches the network.

### Use it

```sh
./server.sh inventory                            # name, version, package manager
./server.sh inventory --wide                     # every column
./server.sh inventory --pm dpkg,manual           # what did not come from a repository
./server.sh inventory --explicit                 # only what someone installed on purpose
./server.sh inventory --updates --wide           # what has a newer version known locally
./server.sh inventory --search firefox
./server.sh inventory --format json > inventory.json
./server.sh inventory --refresh                  # scan again instead of reading the saved list
```

```
NAME           VERSION  PM      ARCH  SIZE  INSTALLED   EXPLICIT  SOURCE                 UPDATE  SUMMARY
curl-sh-app    -        manual  -     4K    2026-09-30  yes       /opt/curl-sh-app       -       -
in-house-tool  1.2.3    dpkg    all   -     2026-09-30  yes       local .deb             -       built by hand
mytool         -        manual  -     4K    2026-09-30  yes       /usr/local/bin/mytool  -       -
3 packages — dpkg 1, manual 2
```

### The PM column

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

### Columns

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

### On Windows

```powershell
powershell -ExecutionPolicy Bypass -File .\\server.ps1 inventory -Wide
.\\server.ps1 inventory -Pm choco,scoop -Search git
.\\server.ps1 inventory -Format json > inventory.json
```

Options are PowerShell-style — `-Wide`, `-Format`, `-Pm`, `-Search`,
`-Explicit`, `-Updates`, `-Refresh`, `-NoCache`, `-Cache`, `-Help` — with the
same meaning as the flags below. It runs on Windows PowerShell 5.1, which every
Windows has, and on PowerShell 7.

| PM | Means | Read from |
|---|---|---|
| `msi` | installed by Windows Installer | the registry's uninstall entries: machine (`x64`), 32-bit (`x86`) and per-user |
| `exe` | installed by any other installer | the same |
| `winget` | known to winget | `winget export` — winget consults its sources for this, which may use the network |
| `choco` | Chocolatey | each package's `.nuspec` in its `lib` folder — no `choco` process |
| `scoop` | Scoop | each app's `manifest.json` and `install.json`, user and global |
| `store` | Microsoft Store and MSIX | `Get-AppxPackage`; frameworks are marked as dependencies, parts of Windows itself are left out |

Hidden system components and Windows updates are not listed: they are not
software someone installed. Chocolatey does not record why a package was
installed, but a package another installed package depends on is marked as a
dependency.

An app installed through winget, or a Chocolatey package that runs an
installer, usually also registered an uninstall entry — so it can appear twice,
once for the manager and once for the installer. That is what Windows records;
it is shown rather than guessed away.

The saved list is `%LOCALAPPDATA%\ops\inventory.tsv`, in the same format as on
Linux. It is warned stale when anything under Program Files, per-user
Programs, or the Chocolatey and Scoop folders changed after it was made.

### The saved list

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

### Options

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

### Tests

`tests/inventory_test.ps1` runs `server.ps1 inventory` on a real Windows — GitHub's
Windows runners, under Windows PowerShell 5.1 and PowerShell 7 — with test
uninstall entries added under `HKCU` and removed afterwards, and fake Chocolatey
and Scoop folders. Elsewhere it reports itself skipped.

`tests/inventory_test.sh` builds a fake system and runs the script with
`--root` against it: the real `dpkg-query` and `apt` read a status file, a
repository index and apt's marks; pacman's database is real files; `rpm` and
`dnf` are fakes on `PATH`. It covers apt vs dpkg, explicit, updates, dates,
manual installs and ownership, every format and filter, the saved list's rules,
a package database that cannot be read, and bad input.

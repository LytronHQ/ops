# cleanup

Reclaim disk space from what a machine accumulates and does not need. **It
reports by default** — how much each category would free — and deletes nothing
without `--apply`.

**Runs on:** the machine being cleaned, or another system's files with `--root`.
**Platforms:** Linux (`cleanup.sh`) and Windows (`cleanup.ps1`).
**Needs:** bash and the usual tools; `--apply` needs root.

## Get it

```sh
./ops-get cleanup.sh v4.3.0
```

```powershell
powershell -ExecutionPolicy Bypass -File .\ops-get.ps1 cleanup.ps1 v4.3.0
```

## Use it

```sh
./cleanup.sh                          # what would be freed; nothing is deleted
sudo ./cleanup.sh --apply             # clean, and report what was freed
./cleanup.sh --only journal,temp
sudo ./cleanup.sh --apply --older-than 14 --journal-max 1G
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

## Categories

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

### Opt-in categories

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
./cleanup.sh --include docker
./cleanup.sh --apply --include docker      # as anyone who can reach the daemon, rootless too
sudo ./cleanup.sh --apply --include autoremove,snap-revisions
```

## On Windows

```powershell
powershell -ExecutionPolicy Bypass -File .\cleanup.ps1             # report
powershell -ExecutionPolicy Bypass -File .\cleanup.ps1 -Apply      # clean
.\cleanup.ps1 -Only temp,crash-dumps -OlderThan 14
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

## Options

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

## Tests

`tests/cleanup_test.ps1` runs `cleanup.ps1` on a real Windows — GitHub's
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

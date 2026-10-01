# cleanup

Reclaim disk space from what a machine accumulates and does not need. **It
reports by default** — how much each category would free — and deletes nothing
without `--apply`.

**Runs on:** the machine being cleaned, or another system's files with `--root`.
**Platforms:** Linux.
**Needs:** bash and the usual tools; `--apply` needs root.

## Get it

```sh
./ops-get cleanup.sh v4.3.0
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

## Options

Every input is a flag; `--help` lists them. Nothing is read from the environment
except `HOME`, for whose thumbnails when not root.

| Flag | Default | Meaning |
|---|---|---|
| `--apply` | | clean. Without it nothing is deleted. Needs root, except with `--root` |
| `--only <list>` | all | only these categories; repeatable, or comma separated |
| `--skip <list>` | none | all but these |
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

`tests/cleanup_test.sh` builds a fake system and runs the script with `--root`:
the real `apt-get` cleans its cache; pacman's and dnf's are checked for what
would be reported (both tools were run for real in Fedora and Arch containers).
It covers a report deleting nothing, every category's junk going and the exact
amount reported, user files and protected directories surviving, the default
ages keeping fresh files, pacman's rule of keeping installed versions, a
failing tool failing the run, and bad input.

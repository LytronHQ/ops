# db

Routine maintenance of a database, run unattended — a systemd timer, cron. For
SQLite: fold the WAL back, reclaim a bounded number of free pages, optionally
have the application take a backup, and ping a heartbeat only when all of it
worked.

**Runs on:** the host with the database, or the host running its container.
**Engines:** `sqlite`.
**Needs:** bash, `curl`, and `sqlite3` on the host or in the container.

## Get it

```sh
./ops-get db.sh v4.4.0
```

## Use it

```sh
./db.sh maintain --db /var/lib/app/app.db

# PocketBase in a container, with its own backup and a heartbeat:
./db.sh maintain --container pocketbase --db /pb_data/data.db \
  --app pocketbase --credentials-file /etc/pb/pb.env \
  --heartbeat-url-file /etc/pb/heartbeat.url
```

```
checkpoint: folding the WAL into /pb_data/data.db
  wal_checkpoint(TRUNCATE) -> 0|0|0 (busy|log|checkpointed)
vacuum: reclaiming up to 20000 page(s) of 5341 free
  free pages now 0
backup: requesting backup-20261001-063429.zip
  backup created (and uploaded, when PocketBase's S3 backups are set up)
heartbeat sent
maintenance complete
```

## What `maintain` does, in this order

The order is load-bearing.

1. **`PRAGMA wal_checkpoint(TRUNCATE)`** — folds the WAL into the main file and
   resets it, so a backup does not depend on WAL state and the WAL cannot grow
   without bound. A reader mid-transaction can block it: that is a warning, and
   the next run catches up.
2. **`PRAGMA incremental_vacuum(N)`** — reclaims at most `--vacuum-pages` free
   pages, so every run is short and predictable. After the checkpoint, or the
   pages to reclaim are still in the WAL.
3. **A backup**, with `--app pocketbase` — through PocketBase's own API, so it
   is consistent and restores the normal way. After the vacuum, or the archive
   carries the dead pages.
4. **A heartbeat**, with `--heartbeat-url-file` — only when everything above
   worked. A failure that says nothing looks like no failure on a host nobody
   watches; the monitor alerts on the ping's *absence* instead.

Deliberately absent: a recurring full `VACUUM` — an exclusive lock for its
whole duration, the whole file rewritten — and backup retention, which the
backup destination's lifecycle does: two policies on one bucket is how backups
get deleted early.

### Incremental vacuum has to be switched on once

`incremental_vacuum` does nothing unless the database is in incremental
auto-vacuum mode, and SQLite — PocketBase included — creates databases with it
off. `maintain` then skips the vacuum and says so. Switching it on rewrites the
whole file, so do it once, with the service stopped:

```sh
sqlite3 data.db 'PRAGMA auto_vacuum = INCREMENTAL; VACUUM;'
```

## Options

Every input is a flag; `--help` lists them. Nothing is read from the environment.

| Flag | Default | Meaning |
|---|---|---|
| `--engine <name>` | `sqlite` | the only one implemented |
| `--db <path>` | required | the database file; the path inside the container with `--container` |
| `--container <name>` | | run `sqlite3` inside this running container |
| `--vacuum-pages <n>` | `20000` | most free pages reclaimed per run — about 80 MiB of 4 KiB pages |
| `--busy-ms <ms>` | `15000` | wait this long for a lock before giving up |
| `--app <name>` | | the application, for its backup: `pocketbase` |
| `--url <url>` | `http://127.0.0.1:8090` | PocketBase's base URL |
| `--credentials-file <file>` | | `PB_SUPERUSER_EMAIL=` and `PB_SUPERUSER_PASSWORD=` lines, read as data. The password goes to `curl` on stdin, JSON-escaped |
| `--backup-prefix <name>` | `backup` | backups are named `<prefix>-YYYYmmdd-HHMMSS.zip` |
| `--no-backup` | | skip the backup |
| `--heartbeat-url-file <file>` | | a file holding the heartbeat URL. A file, not a value: anyone holding the URL can fake the ping |

Exit status is `1` when the checkpoint, the vacuum, the login or the backup
fails — and then there is no heartbeat.

## Tests

`tests/maintain_test.sh` runs the script against real SQLite files and a stub
PocketBase: the WAL folded in and the vacuum bounded to exactly
`--vacuum-pages`; a non-incremental database skipped, not converted; a reader
blocking the checkpoint as a warning; the backup requested only after the
vacuum (the stub reads the free-page count at that moment); a quoted password;
the password, token and heartbeat URL never in `curl`'s arguments; no heartbeat
after a failed backup or login; bad input.

Verified against a real PocketBase 0.40.4 container: checkpoint, the vacuum
skipped as PocketBase's database is not incremental, and a backup created
through its API.

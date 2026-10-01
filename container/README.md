# container

Looking after a containerised service on its host. One action so far:
**`upgrade`**.

```sh
./container.sh upgrade --help
```

## upgrade


Upgrade a containerised service to a new version with a consistent snapshot of
its data taken first, and an automatic rollback — of the image **and** the data
— if it does not come back healthy. Run on the host.

**Runs on:** the host running the service.
**Platforms:** Linux.
**Needs:** bash, `docker` with `docker compose`, `curl`; a small helper image
(`alpine:3.20` by default) to read and write the data volume.

## Get it

```sh
./ops-get container.sh v4.4.0
```

## Use it

```sh
sudo ./container.sh upgrade --compose /opt/app/compose.yml --service app --to 2.4.0 \
  --version-var APP_VERSION --env-file /etc/app/app.env \
  --data /data --health-url http://127.0.0.1:8080/healthz

# PocketBase, with its defaults filled in:
sudo ./container.sh upgrade --app pocketbase --compose /opt/pb/compose.yml --service pocketbase \
  --to 0.40.4 --env-file /etc/pb/pb.env --credentials-file /etc/pb/pb.env --build
```

The compose file takes the version from a variable — `image: app:${APP_VERSION}`,
or a build argument — which the script sets for the new version and, once it is
healthy, writes into `--env-file`.

## What it does

1. **Stops the service.** A database writing while it is copied — SQLite with a
   WAL above all — gives a copy you cannot roll back to. A short, deliberate
   outage is the price of a consistent one.
2. **Snapshots the data directory** to `--snapshots`, and checks the snapshot
   holds `--expect` and is at least `--min-snapshot-bytes`: `tar` succeeds on an
   empty directory, so success alone is not evidence. A bad snapshot stops here,
   and the service is **started again** on the version it was on.
3. **Starts the new version**, then checks it is on the **same storage** it was
   snapshotted from. A missing compose variable — a bind path — silently falls
   back to a default volume, and the service starts on an empty data directory
   that passes its health check.
4. **Checks health**: `--health-url` answers 2xx, `--health-retries` tries 2s
   apart. With `--app pocketbase` and credentials, it also logs in as a
   superuser — which reads the database — and can read a record of
   `--health-collection`.
5. **Rolls back** if it did not start, or is not healthy: stops it, restores
   the snapshot over the data, starts the previous version, checks it. The data
   rolls back with the image because an application that migrates its data on
   start leaves it unreadable to the old version.
6. On success, writes the new version into `--env-file` and keeps the last
   `--keep` snapshots.

The local snapshot is the rollback source; rollback never depends on a download.
`--after-snapshot` can ship a copy elsewhere in the background without holding
the upgrade up.

## Options

Every input is a flag; `--help` lists them. Nothing is read from the environment.

| Flag | Default | Meaning |
|---|---|---|
| `--compose <file>` | required | the compose file |
| `--service <name>` | required | the service to upgrade |
| `--to <version>` | required | the version to upgrade to |
| `--version-var <name>` | `VERSION` | the variable the compose file reads the version from |
| `--env-file <file>` | | `KEY=VALUE` lines handed to compose; the current version is read from it and the new one written to it. **Read as data, never run** |
| `--from <version>` | from `--env-file` | the current version — the rollback target |
| `--data <path>` | required | the data directory **inside** the container |
| `--health-url <url>` | required | must answer 2xx |
| `--health-retries <n>` | `30` | tries, 2 seconds apart |
| `--expect <name>` | | a file the snapshot must contain |
| `--min-snapshot-bytes <n>` | `1` | a smaller snapshot stops the upgrade |
| `--snapshots <dir>` | `/var/backups/<service>` | where snapshots go |
| `--keep <n>` | `3` | snapshots kept after a successful upgrade |
| `--build` | | rebuild the image (`compose up --build`) |
| `--after-snapshot <cmd>` | | run as `<cmd> <snapshot>` in the background, best effort |
| `--helper-image <image>` | `alpine:3.20` | used to read and write the data volume |
| `--app <name>` | | defaults for a known application: `pocketbase` |

### `--app pocketbase`

| Flag | Default | Meaning |
|---|---|---|
| (defaults) | | `--version-var PB_VERSION`, `--data /pb_data`, `--expect data.db`, `--min-snapshot-bytes 65536`, `--health-url <url>/api/health`; a leading `v` in versions is dropped |
| `--url <url>` | `http://127.0.0.1:8090` | PocketBase's base URL |
| `--credentials-file <file>` | | `PB_SUPERUSER_EMAIL=` and `PB_SUPERUSER_PASSWORD=` lines; the health check then logs in. The password goes to `curl` on stdin, JSON-escaped — never as an argument |
| `--health-collection <name>` | | also read one record of this collection |

## Tests

`tests/upgrade_test.sh` runs the script against `tests/fake-docker` — each
start of a version "migrates" the data, so a rollback that restores only the
image is caught — and a health stub: a healthy upgrade; a version that starts,
migrates and is unhealthy, rolled back with the data exactly as before; one that
fails to start; a snapshot without the expected file, with the service started
again; a move to other storage; PocketBase's login with a quoted password that
never appears in `curl`'s arguments; snapshot pruning; bad input.

Verified on a VM against real PocketBase: 0.39.11 → 0.40.4 with a record
surviving the migration and a superuser password containing a quote, and an
upgrade to a version that does not exist rolled back with the record intact.

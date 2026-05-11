# verify-restore

Restore a pgBackRest backup to a throwaway Docker container and verify the backup is valid and
row counts match the live TimescaleDB instance. Used for periodic disaster-recovery validation
and the BKUP-14 "restore to new instance" scenario (e.g. restoring to a laptop or cloud server
without access to the live Pi).

The script pulls secrets from the HAOS host over SSH, starts a disposable container, restores
the latest backup from the chosen repo, starts PostgreSQL, and checks both backup freshness and
row count integrity. The container is removed automatically on exit — even on failure.

## Prerequisites

- `docker` (running locally on the operator's workstation)
- `ssh` with the HAOS host reachable via the configured alias (default: `ha`)
- `jq` (for parsing pgBackRest info JSON)
- `pass` (optional — required only for `--pass-path` offline fallback)
- Linux amd64 workstation (script tested on this platform; `gosu` and `pg_ctl` are inside the container)

## Quick start

```bash
./verify-restore.sh --repo 1
```

This uses SSH alias `ha` (default) to pull secrets directly from the live HAOS host and queries
the live TimescaleDB instance for row count comparison. Run from the repo root or from
`scripts/verify-restore/`.

## Flags reference

| Flag | Default | Description |
|------|---------|-------------|
| `--ha-ssh <alias>` | `ha` | SSH alias for the HAOS host. Overrides the `HA_SSH` env var. |
| `--container <name>` | auto-detected | TimescaleDB container name on the HAOS host. Auto-detected via `docker ps \| grep -i timescale` if not set. |
| `--repo <1\|2>` | `1` | pgBackRest repo to restore from. repo1 = rolling operational; repo2 = annual archival. |
| `--secrets-dir <path>` | none | Path to a local directory containing pre-copied secret files (last resort, priority 3). |
| `--pass-path <prefix>` | none | Pass store path prefix for offline secret retrieval (priority 2). e.g. `home-assistant/backups`. |
| `--pgbackrest-conf <path>` | none | Path to a local `pgbackrest.conf` file. Use this when the live Pi or container is unavailable (offline DR scenario). Skips the `docker exec … cat /etc/pgbackrest/pgbackrest.conf` step. Obtain a reference copy from `timescaledb/DOCS.md` or a prior container snapshot. |
| `--keep` | off | After a successful verify, leave the verify container and PostgreSQL running so the restored database can be inspected interactively. The script prints the exact `docker exec … psql` connection command and the `docker rm -f` cleanup command when it exits. On failure the container is still removed. |

## Credential acquisition

Secrets (cipher passphrase, SSH private key, known hosts file) are fetched in priority order.
The script tries each method in sequence and uses the first that succeeds.

### Priority 1: Live HAOS host via SSH (recommended)

```bash
ssh <ha-ssh> "docker exec <container> cat /data/secrets/<filename>"
```

Secrets live inside the TimescaleDB addon container at `/data/secrets/`; that path is
not visible on the HAOS host filesystem, so the script pipes `cat` output through
`docker exec`. Requires SSH access to the HAOS host and a running container (auto-detected
unless `--container` is supplied). No SCP needed — HAOS SSH does not support SCP. This is
the default and works for routine drills when the Pi is online.

### Priority 2: `pass` password store (offline fallback)

Use `--pass-path <prefix>`. The script calls `pass show <prefix>/<filename>` for each secret.

Use this when the Pi is offline (disaster scenario). The `pass` entry names must match the
secret filenames: `pgbackrest_cipher_pass_repo1`, `pgbackrest_id_ed25519_repo1`,
`pgbackrest_known_hosts_repo1` (and the `_repo2` variants for repo2).

### Priority 3: Local secrets directory (last resort)

Use `--secrets-dir <path>`. The script copies files from that directory using the canonical
filenames. Use this when secrets were manually extracted to a USB drive or local backup.

If all three methods fail for any secret, the script exits with an error describing which
methods were attempted.

## Verification logic

### Primary: Backup freshness (pgBackRest stop timestamp)

The script calls `pgbackrest info --output=json` and extracts the `timestamp.stop` field from
the most recent backup entry for the selected repo. This is the Unix epoch when pgBackRest
finished writing the backup to Hetzner.

This is the authoritative freshness signal. Row timestamps (`max(time)` in the `states` table)
are NOT used as the primary gate: if no Home Assistant entity changed state recently, even a
current and valid backup would fail a `max(time)` freshness check, producing false alarms.

Thresholds:

| Repo | Schedule | Max age |
|------|----------|---------|
| repo1 | Daily (BKUP-06) | 25 hours (90 000 s) |
| repo2 | Annual (Jan 1) | 1 year (31 536 000 s) |

### Secondary: Row count exact match

Requires live Pi access. The script queries `count(*), max(time), min(time)` from the
`states` table in the restored database, then queries the live TimescaleDB with a
`WHERE time <= <restored_max_time>` filter to get a comparable slice. Results must match
exactly. If the live Pi is offline (offline mode), this check is skipped with an `INFO`
message.

`max(time)` from the restored database is also logged separately as a data sanity indicator.

## Offline DR scenario

When the Pi is unavailable, provide a local `pgbackrest.conf` and use the `pass` fallback:

```bash
./verify-restore.sh --repo 1 \
  --pgbackrest-conf ~/path/to/pgbackrest.conf \
  --pass-path home-assistant/backups
```

The `pgbackrest.conf` can be obtained from a prior snapshot, the `timescaledb/DOCS.md`
configuration reference, or by manually reconstructing the stanza from known parameters.

In offline mode, the row count exact match is skipped because there is no live database to
compare against. The primary backup freshness check still runs.

## Cleanup

The `EXIT` trap removes the temporary Docker container (`pgbackrest-verify-<PID>`) and the
secrets temp directory on every exit path — failures, interrupts, and default successful
runs alike. The one exception is `--keep` on a successful run: the trap is disarmed so the
container and its PostgreSQL stay reachable, and the script prints the `docker rm -f` line
the operator should run when finished inspecting.

The restore container is started with a `sleep infinity` entrypoint so PostgreSQL does not
run until the pgBackRest restore completes. This is by design: PostgreSQL cannot be running
while pgBackRest restores into its data directory.

# Quarterly Restore Drill Playbook

This playbook walks the TimescaleDB addon operator through a manual deep restore drill, run on the operator's workstation. The drill is triggered by the quarterly Home Assistant notification (mobile push + sticky persistent notification) that the addon fires on Jan 1, Apr 1, Jul 1, and Oct 1.

The weekly automated `pgbackrest verify` (also part of this addon) proves repository manifest integrity; this manual drill complements it by exercising the **full restore path** end-to-end — cipher passphrase, SSH key, SFTP reachability, byte-for-byte intact backup, and queryable restored database.

## When

Run quarterly on receipt of the HA notification

## Why

The weekly automated `pgbackrest verify` only proves that manifest checksums match what pgBackRest wrote to the SFTP repo. It does NOT prove that:

- The cipher passphrase still decrypts the latest backup
- The SSH private key still authenticates against the SFTP target
- The SFTP host is reachable from the operator's workstation (the path used in a real disaster, when the HAOS host may be unavailable)
- The decrypted, decompressed bytes can be replayed into a running PostgreSQL
- The restored database is queryable and row counts match the live instance

The quarterly drill exercises the entire restore pipeline against both repos.

## Pre-requisites

- Workstation with `docker` running
- "Admin `ssh`" access to the HAOS host (port 22222) (default alias: `ha`)
- `jq` (used by the verify script to parse `pgbackrest info --output=json`)
- Password manager (e.g. `pass`) containing the per-repo cipher passphrases and SSH private keys, for the offline-fallback path
- Local clone of this repository (the script lives at `scripts/verify-restore/verify-restore.sh` in `ha-timescaledb`)

See [`README.md`](./README.md) for the full tooling reference, all flags, and the credential acquisition priority order.

## Drill steps

The canonical invocation, run from this directory:

```bash
./verify-restore.sh --repo 1
./verify-restore.sh --repo 2
```

Defaults are sufficient when the HAOS host is online:

- `--ha-ssh ha` — SSH alias for the HAOS host
- `--container` — auto-detected via `docker ps` on the HAOS host
- Secrets are pulled live from the addon container at `/data/secrets/`

If the HAOS host is offline, fall back to the `pass` password manager:

```bash
./verify-restore.sh --repo 1 \
  --pgbackrest-conf ~/path/to/pgbackrest.conf \
  --pass-path home-assistant/backups
```

The pass-store entry names must match the secret filenames exactly — see [`README.md`](./README.md) §"Priority 2: `pass` password store".

Run repo1 first, then repo2. Each invocation restores into a fresh disposable Docker container that is removed on exit (even on failure).

## Pass criteria

For each repo, all of the following must hold:

1. Script exits 0.
2. Backup freshness check passes: `pgbackrest info`'s `timestamp.stop` is within the per-repo threshold (25 h for repo1, 1 y for repo2 — see [`README.md`](./README.md) §"Backup freshness").
3. Row count exact match: `count(*)` from the restored `states` table equals the live TimescaleDB's `count(*)` filtered to `time <= <restored_max_time>`.
4. The script prints `min(time)`, `max(time)`, and `count(*)` for the restored database; the values are plausible (not zero, not the epoch).

If both repos pass, the drill succeeds. Record the result in the sign-off log below.

## Fail criteria

The drill fails if any of the following occurs for either repo:

- Non-zero exit code from `verify-restore.sh`
- Freshness threshold breach (backup older than the per-repo `Max age`)
- Row count mismatch between the restored database and the live instance
- Missing or undecryptable secret (cipher passphrase, SSH key, known hosts)
- SFTP or SSH error connecting to the storage host
- Restored PostgreSQL fails to start or the `states` table is missing

Triage path on failure:

1. Re-read the script output and the addon log on the HAOS host (Settings → System → Logs → TimescaleDB).
2. Fix the root cause and re-run the failing repo's drill.
3. If the failure persists after a re-run, open a P1 issue in [`ha-timescaledb`](https://github.com/flaksit/ha-timescaledb/issues) and attach the full script output.

# TimescaleDB App

PostgreSQL 18 with TimescaleDB 2.25 for Home Assistant. Provides a high-performance time-series database optimized for the Raspberry Pi 5.

## Installation

1. In Home Assistant, navigate to **Settings > Apps > App Store**
2. Click the three-dot menu (top right) and select **Repositories**
3. Add: `https://github.com/flaksit/ha-timescaledb`
4. Find "TimescaleDB" in the store and click **Install**
5. Start the app — first startup initializes the database (this takes 30-60 seconds)
6. Check the app logs to confirm: "Database 'homeassistant' with TimescaleDB ready"

## Configuration

### Database Tuning

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `database` | string | `homeassistant` | Name of the PostgreSQL database to create. Change only if you need a custom database name. |
| `shared_buffers` | string | `256MB` | PostgreSQL shared memory. Increase to `512MB` if your Pi has 8GB RAM. |
| `work_mem` | string | `32MB` | Memory per sort/hash operation. Default is sufficient for Home Assistant workloads. |
| `effective_cache_size` | string | `768MB` | Planner hint for available OS cache. Set to ~75% of free RAM. |
| `max_connections` | int | `50` | Maximum simultaneous database connections. Home Assistant typically uses 5-10. |
| `log_level` | string | `info` | PostgreSQL log verbosity. Options: trace, debug, info, notice, warning, error, fatal. |

#### RPi 5 Recommended Defaults

The defaults are tuned for a Raspberry Pi 5 with 4GB RAM. If you have 8GB:

| Option | 4GB (default) | 8GB |
|--------|---------------|-----|
| `shared_buffers` | `256MB` | `512MB` |
| `effective_cache_size` | `768MB` | `1536MB` |

Other options can remain at defaults for most installations.

### JIT compilation

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable_jit` | bool | `true` | Enable PostgreSQL's LLVM JIT compilation (Postgres default). |

PostgreSQL's LLVM JIT is **enabled by default** (matching upstream PostgreSQL). Home Assistant and Grafana workloads are dashboard-speed (seconds, not minutes) and dominated by decompression and aggregation over time-series chunks, not per-row CPU. In that regime the JIT's 1–3 s LLVM compile cost is often pure overhead.

Measured on one real HA dataset (1.5M rows, 154k output buckets): 3.3 s with `jit = off` vs 5.9 s with `jit = on`. If your dashboards feel sluggish, set `enable_jit: false` in the app's **Configuration** tab and restart the app.

To override per session without changing the global default:

```sql
SET jit = on;
SET jit_above_cost = 50000;
-- your long-running analytical query
```

### Roles and Access Control

The app manages PostgreSQL roles with per-role passwords and network access.

#### homeassistant (always enabled)

The primary role used by HA's recorder. Owns the database with full DDL and DML privileges (required for HA schema migrations).

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `ha_db_password` | string | *(auto-generated)* | Password for the `homeassistant` role. Leave empty to auto-generate on first start. |

This role can only connect from within the HAOS app network (172.30.32.0/23). To configure HA's recorder:

1. Open the app's **Log** tab — the ready-to-use `db_url` (with password) is printed on each start
2. Copy the `db_url` into `secrets.yaml`:
   ```yaml
   # secrets.yaml
   recorder_db_url: postgresql://homeassistant:ACTUAL_PASSWORD@b872f4a0-timescaledb:5432/homeassistant
   ```
3. Reference it in `configuration.yaml`:
   ```yaml
   recorder:
     db_url: !secret recorder_db_url
   ```

The hostname `b872f4a0-timescaledb` is stable across app updates, rebuilds, and restarts. It is derived from the repository URL and only changes if you remove and re-add the repository from a different URL.

#### homeassistant_ro (optional)

Read-only access to the database. Useful for Grafana dashboards or analytics tools.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable_readonly` | bool | `false` | Create the `homeassistant_ro` role. |
| `readonly_password` | string | *(auto-generated)* | Password for `homeassistant_ro`. Leave empty to auto-generate. |
| `readonly_network` | string | `internal` | `internal` = HAOS network only. `external` = any IP that can reach port 5432. |

#### homeassistant_rw (optional)

Read-write access (SELECT, INSERT, UPDATE, DELETE) without DDL privileges. For custom integrations that need to write data.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable_readwrite` | bool | `false` | Create the `homeassistant_rw` role. |
| `readwrite_password` | string | *(auto-generated)* | Password for `homeassistant_rw`. Leave empty to auto-generate. |
| `readwrite_network` | string | `internal` | `internal` = HAOS network only. `external` = any IP. |

#### postgres / admin (optional)

Full superuser access via the built-in `postgres` role.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable_admin` | bool | `false` | Set a password on the `postgres` superuser and allow remote access. |
| `admin_password` | string | *(auto-generated)* | Password for `postgres`. Leave empty to auto-generate. |
| `admin_network` | string | `internal` | `internal` = HAOS network only. `external` = any IP. |

> **Note:** The `postgres` superuser can always connect via local unix socket (inside the container) without a password. The `enable_admin` toggle controls whether it gets a password and remote access — useful for connecting with pgAdmin or psql from another machine.

### Passwords

#### Retrieving passwords

The easiest way to retrieve passwords is from the app's **Log** tab — connection strings with passwords are printed on each start.

Password behavior:

- **Empty field on first start:** A random 32-character password is generated and stored.
- **Set a password:** Takes effect on the next **app** restart (no HA restart needed). The configured value is saved to the secrets file.
- **Change a password:** Same as above — the new password is applied on app restart. If HA's `db_url` uses this role, you must also update `secrets.yaml` and restart HA.
- **Clear a previously set password:** The existing password from the secrets file is kept. Clearing the field does not generate a new password or remove the old one.

## Data Storage

PostgreSQL data is stored in the app's persistent `/data/postgres` directory. This directory is:

- **Preserved** across app restarts and updates
- **Excluded** from Home Assistant snapshots (too large for the snapshot format)

> **Important:** This app's data is not included in HA backups. Use the **Backup** section below to configure pgBackRest off-host.

## Backup (pgBackRest to Hetzner Storage Box)

The app integrates [pgBackRest](https://pgbackrest.org/) to ship encrypted, deduplicated, point-in-time-recoverable backups to two independent off-host SFTP destinations.

### Design

Two separate Hetzner Storage Box **sub-accounts** are used, one per repository:

- **repo1** — rolling operational backups: monthly fulls + weekly diffs + WAL, retained for 3 years (tunable)
- **repo2** — annual archival: same backup machinery, but unlimited retention, intended for manual/yearly preservation

Each repo is a separate sub-account so that a credential compromise of one repo cannot reach the other, and each has its own encryption passphrase generated on first start.

### Why Hetzner sub-accounts at path `/` (do not change this)

This is **load-bearing** configuration. Do not point pgBackRest at the main Hetzner account with subpaths like `/backups/ha-tsdb-continuous`.

pgBackRest 2.58.0 (current and `main` branch as of 2026-05) has a recursion bug in `storageSftpPathCreate` (`src/storage/sftp/storage.c:1039-1047`):

```c
else if (sftpErrno == LIBSSH2_FX_NO_SUCH_FILE && !noParentCreate)
{
    String *const pathParent = strPath(path);
    storageInterfacePathCreateP(this, pathParent, ...);
    storageInterfacePathCreateP(this, path, ...);
}
```

`strPath("/")` returns `"/"` unchanged. If the SFTP server returns `LIBSSH2_FX_NO_SUCH_FILE` while pgBackRest walks parent directories upward, the recursion never terminates at root and pgBackRest segfaults from stack overflow (~880 recursive frames). This was diagnosed via gdb backtrace.

**Sub-account chroots at path `/` avoid the trigger** because pgBackRest creates `/archive` and `/backup` directly inside the sub-account's writable chroot — the very first `mkdir` succeeds (no walk-up needed). Main accounts on Hetzner Storage Box exhibit the trigger because Hetzner returns `NO_SUCH_FILE` for the chained walk-up to `/`.

### Setup

#### 1. Create two sub-accounts in Hetzner Robot

In Hetzner Console > your Storage Box > Sub-accounts, create two with:

- Home directory pointing at a dedicated empty subpath of the main account (e.g. `/home/backups/ha-tsdb-continuous` and `/home/backups/ha-tsdb-yearly`)
- Comment / label: `pgbackrest repo1` and `pgbackrest repo2` (or similar)
- Permissions: enable SSH access (port 22 SFTP only — Hetzner does not expose port 23 for sub-accounts)
- Note the assigned usernames (e.g. `u404673-sub4`, `u404673-sub5`) and the per-sub hostname (e.g. `u404673-sub4.your-storagebox.de`)

#### 2. Generate two distinct SSH keypairs

On your workstation:

```bash
ssh-keygen -t ed25519 -N '' -C 'pgbackrest-repo1@ha-timescaledb' -f ./repo1
ssh-keygen -t ed25519 -N '' -C 'pgbackrest-repo2@ha-timescaledb' -f ./repo2
```

Two separate keys is mandatory — sharing a key across repos defeats the credential isolation between the two sub-accounts.

#### 3. Install the public keys into each sub-account

Hetzner sub-accounts on port 22 require RFC4716-format `authorized_keys`. Convert and upload via the main account's port-23 shell (which has write access to all sub-account chroots):

```bash
# Convert to RFC4716
ssh-keygen -e -f ./repo1.pub > ./repo1.rfc.pub
ssh-keygen -e -f ./repo2.pub > ./repo2.rfc.pub

# Connect to MAIN account (port 23) and create the .ssh dirs inside each sub chroot
ssh -p 23 u404673@u404673.your-storagebox.de "mkdir backups/ha-tsdb-continuous/.ssh; mkdir backups/ha-tsdb-yearly/.ssh"

# Upload as authorized_keys (one per sub)
scp -O -P 23 ./repo1.rfc.pub u404673@u404673.your-storagebox.de:backups/ha-tsdb-continuous/.ssh/authorized_keys
scp -O -P 23 ./repo2.rfc.pub u404673@u404673.your-storagebox.de:backups/ha-tsdb-yearly/.ssh/authorized_keys

# Tighten permissions (Hetzner enforces these for SSH key auth)
ssh -p 23 u404673@u404673.your-storagebox.de "chmod 700 backups/ha-tsdb-continuous/.ssh backups/ha-tsdb-yearly/.ssh; chmod 600 backups/ha-tsdb-continuous/.ssh/authorized_keys backups/ha-tsdb-yearly/.ssh/authorized_keys"
```

Verify each sub-account auth works (each should connect and land at `/`):

```bash
sftp -i ./repo1 -P 22 u404673-sub4@u404673-sub4.your-storagebox.de <<< 'pwd'
sftp -i ./repo2 -P 22 u404673-sub5@u404673-sub5.your-storagebox.de <<< 'pwd'
```

#### 4. Stage the secrets on the HA host

The app reads SSH private keys, known_hosts, and (optionally pre-set) cipher passphrases from `/data/secrets/` inside the container. On the HAOS host these live at:

```
/mnt/data/supervisor/addons/data/b872f4a0_timescaledb/secrets/
```

Where `b872f4a0` is the slug Home Assistant generates from the repository URL (visible in **Settings > Apps > TimescaleDB**). Adjust if your slug differs.

Files required:

| File | Content |
|------|---------|
| `pgbackrest_id_ed25519_repo1` | repo1 private key (the `repo1` file from step 2) |
| `pgbackrest_id_ed25519_repo2` | repo2 private key (the `repo2` file from step 2) |
| `pgbackrest_known_hosts_repo1` | host fingerprints for sub4 — see below |
| `pgbackrest_known_hosts_repo2` | host fingerprints for sub5 — see below |

Generate the known_hosts files by scanning each sub on port 22:

```bash
ssh-keyscan -p 22 -t rsa,ecdsa,ed25519 u404673-sub4.your-storagebox.de > ./known_hosts_repo1
ssh-keyscan -p 22 -t rsa,ecdsa,ed25519 u404673-sub5.your-storagebox.de > ./known_hosts_repo2
```

Push everything to the HA host. Use `scp -O` (the legacy SCP wire protocol) — HAOS BusyBox ssh does not support the new `sftp` transfer protocol that recent OpenSSH clients default to:

```bash
SECRETS=/mnt/data/supervisor/addons/data/b872f4a0_timescaledb/secrets
scp -O ./repo1            ha:$SECRETS/pgbackrest_id_ed25519_repo1
scp -O ./repo2            ha:$SECRETS/pgbackrest_id_ed25519_repo2
scp -O ./known_hosts_repo1 ha:$SECRETS/pgbackrest_known_hosts_repo1
scp -O ./known_hosts_repo2 ha:$SECRETS/pgbackrest_known_hosts_repo2
```

Set ownership and mode (`uid 70` is the postgres user inside the app's Alpine base; the app runs pgBackRest as that user):

```bash
ssh ha "chown 70:70 $SECRETS/pgbackrest_id_ed25519_repo1 \
                    $SECRETS/pgbackrest_id_ed25519_repo2 \
                    $SECRETS/pgbackrest_known_hosts_repo1 \
                    $SECRETS/pgbackrest_known_hosts_repo2"
ssh ha "chmod 600   $SECRETS/pgbackrest_id_ed25519_repo1 \
                    $SECRETS/pgbackrest_id_ed25519_repo2 \
                    $SECRETS/pgbackrest_known_hosts_repo1 \
                    $SECRETS/pgbackrest_known_hosts_repo2"
```

These permissions are not optional. pgBackRest refuses to use private keys with permissive modes, and the app explicitly checks ownership/mode at start.

#### 5. Configure the app

Set the following in the app's **Configuration** tab:

| Option | Value |
|--------|-------|
| `backup_enabled` | `true` |
| `archive_timeout_seconds` | `3600` (default — WAL is force-flushed every hour even with no DB activity) |
| `repo1_sftp_host` | `u404673-sub4.your-storagebox.de` |
| `repo1_sftp_port` | `22` |
| `repo1_sftp_user` | `u404673-sub4` |
| `repo1_sftp_path` | `/` |
| `repo2_sftp_host` | `u404673-sub5.your-storagebox.de` |
| `repo2_sftp_port` | `22` |
| `repo2_sftp_user` | `u404673-sub5` |
| `repo2_sftp_path` | `/` |

> Always use port `22` and path `/`. Pointing pgBackRest at the main account with a subpath triggers the recursion segfault described above.

Restart the app. On first start with `backup_enabled: true`:

1. The app generates two cipher passphrases (`/data/secrets/pgbackrest_cipher_pass_repo[12]`) and writes them once. They are never overwritten — the same passphrases must be available to restore later, so copy them somewhere safe out-of-band.
2. `pgbackrest stanza-create` runs against both repos. Successful output looks like:

   ```
   P00 INFO: stanza-create for stanza 'timescaledb' on repo1
   P00 INFO: stanza-create for stanza 'timescaledb' on repo2
   P00 INFO: stanza-create command end: completed successfully
   pgBackRest: stanza-create OK (attempt 1)
   pgBackRest: backup provisioning complete — WAL archiving active
   ```

3. PostgreSQL `archive_command` starts pushing WAL to both repos. Each WAL segment is logged as `pushed WAL file 'XXXXXX' to the archive`.

If `stanza-create` fails on every attempt (3 retries with backoff), the init script disables `archive_mode` for that boot to prevent unbounded WAL accumulation on disk. Fix the underlying error and restart the app to re-enable archiving.

### Verification

```bash
# From your workstation: list contents of each sub via SFTP
sftp -i ./repo1 -P 22 u404673-sub4@u404673-sub4.your-storagebox.de <<< 'ls -l'
sftp -i ./repo2 -P 22 u404673-sub5@u404673-sub5.your-storagebox.de <<< 'ls -l'
```

After a successful first start each should list `archive/` and `backup/` directories owned by the corresponding sub-user.

To inspect pgBackRest's view of stanza state from inside the container:

```bash
ssh ha "docker exec addon_b872f4a0_timescaledb gosu postgres pgbackrest --stanza=timescaledb info"
```

### Troubleshooting

**Symptom: `stanza-create` segfaults (exit code 139), backtrace shows ~800 recursive frames.**
Configuration points pgBackRest at the main account with a non-empty subpath, or at any path other than the sub-account chroot root. Switch to dedicated sub-accounts at `repo*_sftp_path: /`.

**Symptom: `stanza-create` exits with `unable to load private key` or `permission denied`.**
The `/data/secrets/pgbackrest_id_ed25519_repo*` files are owned by root or have mode `0644`. Re-run the chown/chmod commands in step 4.

**Symptom: `host key verification failed`.**
The `pgbackrest_known_hosts_repo*` file does not contain a key for the host pgBackRest is connecting to, or the host key on Hetzner has rotated. Re-run `ssh-keyscan -p 22 ...` and re-upload.

**Symptom: cipher passphrase lost after `/data/secrets/` was wiped.**
Existing backups are unrecoverable. The cipher passphrases are generated once on first stanza-create and never written elsewhere. Always copy `/data/secrets/pgbackrest_cipher_pass_repo[12]` to an out-of-band location after first start.

## Network

By default, PostgreSQL is only accessible from within HAOS (other apps and HA core). The port is **not** exposed to your local network.

### Internal access (default)

HA and other apps connect using the hostname `b872f4a0-timescaledb` on port `5432`. No additional configuration needed.

### External access (e.g. psql from laptop, Grafana on another machine)

1. In the app's **Network** tab, set the host port to `5432` (or any available port)
2. In the app's **Configuration** tab, set the role's network to `external` (e.g. `admin_network: external`)
3. Restart the app
4. Connect from your machine:
   ```
   psql "postgresql://postgres:PASSWORD@<RPI_IP>:5432/postgres"
   ```
   Replace `<RPI_IP>` with your Raspberry Pi's IP address and `PASSWORD` with the password from the app logs.

## Migrating from SQLite

If you have an existing Home Assistant installation using SQLite, you can migrate all historical data to this PostgreSQL database. The migration runs while HA continues to use SQLite — there is no downtime until the final cutover.

### Prerequisites

- This TimescaleDB app installed and running (see Installation above)
- SSH access to the HAOS host (`ssh ha`)
- The migration tooling from the [paradise-ha](https://github.com/flaksit/paradise-ha) repository

### Overview

The migration happens in two phases:

1. **Bulk pre-copy** (this section): copies all historical data while HA keeps running on SQLite. Takes ~40 minutes for a 63M-row states table on RPi 5.
2. **Cutover** (Phase 3): brief HA stop, copy final delta rows, switch recorder to PostgreSQL, restart HA. Target: under 5 minutes downtime.

### Step 1: Prepare the schema

The migration container includes a `reset-schema.sh` script that drops and recreates the PostgreSQL schema:

```bash
# Transfer migration files to Pi
cd paradise-ha
tar cf - scripts/migrate/Dockerfile scripts/migrate/.dockerignore \
  scripts/migrate/migrate.py scripts/migrate/pyproject.toml \
  scripts/migrate/uv.lock scripts/migrate/reset-schema.sh \
  scripts/migrate/schema/ha_schema.sql \
  | ssh ha "mkdir -p /tmp/ha-migrate && tar xf - --strip-components=2 -C /tmp/ha-migrate"

# Apply schema
ssh ha "bash /tmp/ha-migrate/reset-schema.sh"
```

### Step 2: Build the migration container

```bash
ssh ha "cd /tmp/ha-migrate && docker build -t ha-migrate:latest ."
```

This builds a Python 3.14 Alpine container with the migration script and psycopg3.

### Step 3: Run smoke test

```bash
PG_PASS=$(ssh ha "docker exec addon_b872f4a0_timescaledb cat /data/secrets/homeassistant_password")

ssh ha "docker run --rm --network hassio \
  -v /mnt/data/supervisor/homeassistant/home-assistant_v2.db:/data/home-assistant_v2.db:ro \
  -v /mnt/data/supervisor/homeassistant/home-assistant_v2.db-shm:/data/home-assistant_v2.db-shm:ro \
  -v /mnt/data/supervisor/homeassistant/home-assistant_v2.db-wal:/data/home-assistant_v2.db-wal:ro \
  -e SQLITE_PATH=/data/home-assistant_v2.db \
  -e PG_DSN='postgresql://homeassistant:${PG_PASS}@172.30.33.5:5432/homeassistant' \
  ha-migrate:latest --smoke-test 3000 --skip-mutable"
```

The smoke test copies a small subset of data and runs exhaustive row-by-row verification. It should exit with `RESULT: SUCCESS`.

### Step 4: Reset and run full migration

```bash
# Reset schema (clears smoke test data)
ssh ha "bash /tmp/ha-migrate/reset-schema.sh"

# Full migration
ssh ha "docker run --rm --network hassio \
  -v /mnt/data/supervisor/homeassistant/home-assistant_v2.db:/data/home-assistant_v2.db:ro \
  -v /mnt/data/supervisor/homeassistant/home-assistant_v2.db-shm:/data/home-assistant_v2.db-shm:ro \
  -v /mnt/data/supervisor/homeassistant/home-assistant_v2.db-wal:/data/home-assistant_v2.db-wal:ro \
  -e SQLITE_PATH=/data/home-assistant_v2.db \
  -e PG_DSN='postgresql://homeassistant:${PG_PASS}@172.30.33.5:5432/homeassistant' \
  ha-migrate:latest --skip-mutable --batch-size 10000"
```

The `--skip-mutable` flag ensures rows that HA is actively updating (current state per entity, open recorder run) are handled correctly: they are copied, verified, then deleted from PG and stored in `_migrate_excluded` for the cutover phase to re-copy with final values.

### Verification

The migration script performs automatic verification after each pass:

- **Row counts**: exact match between SQLite and PG for every copied PK range
- **PK hash**: streaming MD5 of ordered primary keys catches swapped/duplicate/missing rows
- **Exhaustive comparison** (smoke test only): column-by-column 1-on-1 comparison

The script exits with code 0 on success, 1 on any mismatch.

### After bulk pre-copy

Do **not** switch HA to PostgreSQL yet. The bulk pre-copy leaves ~380 mutable tip rows in `_migrate_excluded` — these will be re-copied during the Phase 3 cutover when HA is briefly stopped.

## Uninstalling

1. If Home Assistant is using this database (`db_url` points here), switch the recorder back to SQLite first by removing the `db_url` from your `configuration.yaml` and restarting HA
2. Stop the app
3. Click **Uninstall** on the app page

This removes the app and all PostgreSQL data in `/data/postgres`. The data cannot be recovered after uninstalling unless you have a separate backup.

To also remove the repository, go to **Settings > Apps > App Store** > three-dot menu > **Repositories** and delete the `https://github.com/flaksit/ha-timescaledb` entry.

## Troubleshooting

### App fails to start

Check the app logs for error messages. Common causes:

- **Port 5432 in use:** Another app is using port 5432. Stop it or change the port mapping.
- **Corrupt data directory:** If the app was force-killed, PostgreSQL may need recovery. Check logs for "database system was not shut down cleanly" — PostgreSQL handles this automatically on next start.

### Checking database status

The app log shows "Database 'homeassistant' with TimescaleDB ready" on successful initialization. PostgreSQL logs are available in the app log viewer.

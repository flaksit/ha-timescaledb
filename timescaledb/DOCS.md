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

PostgreSQL's LLVM JIT is **disabled** in this app (`jit = off` in `postgresql.conf`). Home Assistant and Grafana workloads are dashboard-speed (seconds, not minutes) and dominated by decompression and aggregation over time-series chunks, not per-row CPU. In that regime the JIT's 1–3 s LLVM compile cost is pure overhead.

Measured on a real HA dataset (1.5M rows, 154k output buckets): 3.3 s with `jit = off` vs 5.9 s with `jit = on`.

For ad-hoc analytical queries that actually benefit from JIT, opt in per session:

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

> **Important:** This app's data is not included in HA backups. A dedicated backup solution will be configured in a later phase.

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

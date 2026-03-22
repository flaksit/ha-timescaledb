# TimescaleDB Add-on

PostgreSQL 18 with TimescaleDB 2.25 for Home Assistant. Provides a high-performance time-series database optimized for the Raspberry Pi 5.

## Installation

1. In Home Assistant, navigate to **Settings > Add-ons > Add-on Store**
2. Click the three-dot menu (top right) and select **Repositories**
3. Add: `https://github.com/flaksit/hass-timescaledb-addon`
4. Find "TimescaleDB" in the store and click **Install**
5. Start the add-on — first startup initializes the database (this takes 30-60 seconds)
6. Check the add-on logs to confirm: "Database 'homeassistant' with TimescaleDB ready"

## Configuration

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `databases` | string | `homeassistant` | Name of the PostgreSQL database to create. Change only if you need a custom database name. |
| `shared_buffers` | string | `256MB` | PostgreSQL shared memory. Increase to `512MB` if your Pi has 8GB RAM. |
| `work_mem` | string | `32MB` | Memory per sort/hash operation. Default is sufficient for Home Assistant workloads. |
| `effective_cache_size` | string | `768MB` | Planner hint for available OS cache. Set to ~75% of free RAM. |
| `max_connections` | int | `50` | Maximum simultaneous database connections. Home Assistant typically uses 5-10. |
| `log_level` | string | `info` | PostgreSQL log verbosity. Options: trace, debug, info, notice, warning, error, fatal. |

### RPi 5 Recommended Defaults

The defaults are tuned for a Raspberry Pi 5 with 4GB RAM. If you have 8GB:

| Option | 4GB (default) | 8GB |
|--------|---------------|-----|
| `shared_buffers` | `256MB` | `512MB` |
| `effective_cache_size` | `768MB` | `1536MB` |

Other options can remain at defaults for most installations.

## Data Storage

PostgreSQL data is stored in the add-on's persistent `/data/postgres` directory. This directory is:

- **Preserved** across add-on restarts and updates
- **Excluded** from Home Assistant snapshots (too large for the snapshot format)

> **Important:** This add-on's data is not included in HA backups. A dedicated backup solution will be configured in a later phase.

## Network

The add-on exposes PostgreSQL on port **5432**. By default, connections are accepted from the Home Assistant network using `scram-sha-256` authentication.

## Uninstalling

1. If Home Assistant is using this database (`db_url` points here), switch the recorder back to SQLite first by removing the `db_url` from your `configuration.yaml` and restarting HA
2. Stop the add-on
3. Click **Uninstall** on the add-on page

This removes the add-on and all PostgreSQL data in `/data/postgres`. The data cannot be recovered after uninstalling unless you have a separate backup.

To also remove the repository, go to **Settings > Add-ons > Add-on Store** > three-dot menu > **Repositories** and delete the `https://github.com/flaksit/hass-timescaledb-addon` entry.

## Troubleshooting

### Add-on fails to start

Check the add-on logs for error messages. Common causes:

- **Port 5432 in use:** Another add-on is using port 5432. Stop it or change the port mapping.
- **Corrupt data directory:** If the add-on was force-killed, PostgreSQL may need recovery. Check logs for "database system was not shut down cleanly" — PostgreSQL handles this automatically on next start.

### Checking database status

The add-on log shows "Database 'homeassistant' with TimescaleDB ready" on successful initialization. PostgreSQL logs are available in the add-on log viewer.

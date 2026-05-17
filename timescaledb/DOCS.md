# TimescaleDB App

PostgreSQL 18 with TimescaleDB 2.26 for Home Assistant, packaged as a Home Assistant app and tuned for the Raspberry Pi 5.

## What this app is (and is not)

This is a general-purpose PostgreSQL + TimescaleDB instance running alongside Home Assistant. It is **not** a drop-in for HA's recorder and does not modify HA's default storage. Two deployments are common:

- **Parallel analytics / time-series store.** Home Assistant keeps using its built-in SQLite recorder. PostgreSQL is used by Grafana, custom integrations, or one-off analyses that need TimescaleDB features (continuous aggregates, compression, retention policies, etc.) on a copy of HA history or on independent data.
- **HA recorder destination.** Home Assistant's `recorder.db_url` is pointed at this PostgreSQL instance, replacing SQLite as the live recorder backend. The `homeassistant` role (see "Roles and Access Control") is intended for this mode.

The configuration sections below apply to both deployments. Sections specific to one mode call it out explicitly.

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

Owns the `homeassistant` database with full DDL and DML privileges. Suitable as either the destination for an HA recorder pointed at this app, or as the role that owns historical HA data copied in for analytics.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `ha_db_password` | string | *(auto-generated)* | Password for the `homeassistant` role. Leave empty to auto-generate on first start. |

This role can only connect from within the HAOS app network (172.30.32.0/23).

To use this app as HA's recorder backend (replacing SQLite for live writes):

1. Open the app's **Log** tab — the ready-to-use `db_url` (with password) is printed on each start.
2. Copy it into `secrets.yaml`:
   ```yaml
   recorder_db_url: postgresql://homeassistant:ACTUAL_PASSWORD@b872f4a0-timescaledb:5432/homeassistant
   ```
3. Reference it in `configuration.yaml`:
   ```yaml
   recorder:
     db_url: !secret recorder_db_url
   ```

The hostname `b872f4a0-timescaledb` is stable across app updates, rebuilds, and restarts. It is derived from the repository URL and only changes if you remove and re-add the repository from a different URL.

If you keep HA on SQLite (parallel-analytics deployment), skip the `recorder.db_url` step. The role and database still exist and remain reachable for tools like Grafana or custom integrations.

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

## TimescaleDB extension version

The image ships a specific TimescaleDB version (currently 2.26) as `timescaledb-X.Y.Z.so`. On each app start, `init-db.sh` runs `ALTER EXTENSION timescaledb UPDATE` against the `homeassistant` database to align the per-database extension catalog (`pg_extension.extversion`) with the binary on disk. This is idempotent — no-op when already current — and is logged on each start as either `TimescaleDB extension at X.Y.Z (already current)` or `TimescaleDB extension upgraded: A.B.C → X.Y.Z`.

PostgreSQL keeps every TimescaleDB minor version's `.so` side-by-side and loads whichever matches the catalog's recorded version. Without the auto-update, an image bump replaces the binaries on disk but sessions in pre-existing databases keep loading the older `.so`. The auto-update step removes that footgun: after a successful start, `SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';` reflects the version shipped by the current image.

## Data Storage

PostgreSQL data is stored in the app's persistent `/data/postgres` directory. This directory is:

- **Preserved** across app restarts and updates
- **Excluded** from Home Assistant snapshots (too large for the snapshot format)

Home Assistant snapshots run in **hot** mode (the app keeps running during backup). Only secrets and rendered config are captured — enough to bootstrap pgBackRest on a fresh install. The DB itself is not in the HA snapshot.

> **Important:** This app's data is not included in HA backups. **Enable pgBackRest in the Backup section below** to protect DB contents — HA snapshots alone do not back up the database.

## Backup

> **Opt-in only.** `backup_enabled` defaults to `false`. Upstream ha-timescaledb users who do not use pgBackRest are completely unaffected — the app behaves identically to v1.0.x when this option is not set.

The app integrates [pgBackRest](https://pgbackrest.org/) to ship encrypted, deduplicated, point-in-time-recoverable backups to two independent off-host SFTP destinations.

### Prerequisites

- **Two SFTP destinations** with separate credentials. The recommended setup is two Hetzner Storage Box sub-accounts — see [BKUP-13 below](#backup-setup-bkup-13). Any SFTP server that allows writing to the chroot root (`/`) works.
- **MQTT broker + integration** (optional but recommended). Backup status sensors (`sensor.timescaledb_backup_*`) are published via MQTT discovery through the Supervisor's `mqtt/publish` service. Without MQTT the backups still run, but the four status sensors will not appear in Home Assistant. To enable:
    1. Install the **Mosquitto broker** app from the official add-on store.
    2. Configure the **MQTT integration** in Home Assistant (Settings → Devices & Services → Add Integration → MQTT). Mosquitto's discovery flow handles this automatically on most installs.

### Design

Two separate Hetzner Storage Box **sub-accounts** are used, one per repository:

- **repo1** — rolling operational backups: monthly fulls + weekly diffs + WAL, retained for 3 years (tunable)
- **repo2** — annual archival: same backup machinery, but unlimited retention, intended for manual/yearly preservation

Each repo is a separate sub-account so that a credential compromise of one repo cannot reach the other, and each has its own encryption passphrase generated on first start.

### Why Hetzner sub-accounts at path `/` (do not change this)

This is **load-bearing** configuration. Do not point pgBackRest at the main Hetzner account with subpaths like `/backups/ha-tsdb-continuous`.

pgBackRest 2.58.0 has a recursion bug in `storageSftpPathCreate` (`src/storage/sftp/storage.c:1039-1047`):

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

### Backup Setup (BKUP-13)

#### Step 1. Create two sub-accounts in Hetzner Cloud Console

Storage Boxes are managed through the [Hetzner Cloud Console](https://console.hetzner.com). Open the project that owns the Storage Box, select the box, then open the **Sub-accounts** tab and add two new sub-accounts. For each:

- **Home directory:** a dedicated, empty subpath of the main account, one per repo (e.g. `/home/backups/ha-tsdb-continuous` and `/home/backups/ha-tsdb-yearly`). Sub-accounts are chrooted to this directory and see it as their `/`.
- **Comment / label:** `pgbackrest repo1` and `pgbackrest repo2` (free text — only shown in the Console).
- **Read-only:** off (pgBackRest must write).
- **External Reachability:** on — required for the Storage Box to be reachable from outside Hetzner's internal network (e.g. from a Raspberry Pi at home).
- **Samba/CIFS, WebDAV:** off — pgBackRest does not use them.
- **SSH support:** off. With SSH off the sub-account exposes only SFTP on port 22; the port-23 extended shell that offers `install-ssh-key` / `ssh-copy-id` / rsync / borg stays disabled, which is fine — the main account keeps SSH enabled so it can write each sub-account's `authorized_keys` file in step 3.

The Console assigns each sub a username (e.g. `u404673-sub4`) and the per-sub hostname follows the pattern `<username>.your-storagebox.de` (e.g. `u404673-sub4.your-storagebox.de`). Note both — the app needs them in step 5.

References: [Sub-account access overview](https://docs.hetzner.com/storage/storage-box/access/access-overview/), [SFTP/SCP access docs](https://docs.hetzner.com/storage/storage-box/access/access-sftp-scp/).

#### Step 2. Generate two distinct SSH keypairs

On your workstation:

```bash
ssh-keygen -t ed25519 -N '' -C 'pgbackrest-repo1@ha-timescaledb' -f ./repo1
ssh-keygen -t ed25519 -N '' -C 'pgbackrest-repo2@ha-timescaledb' -f ./repo2
```

Two separate keys is mandatory — sharing a key across repos defeats the credential isolation between the two sub-accounts.

#### Step 3. Install the public keys into each sub-account

With SSH disabled on the sub-accounts (step 1), only port 22 SFTP remains. Hetzner's port-22 SFTP service expects `authorized_keys` in **RFC4716** format (the multi-line PEM-style block) — the one-line `ssh-ed25519 AAAA...` OpenSSH format that the port-23 shell accepts will not authenticate here. The `install-ssh-key` / `ssh-copy-id -p 23 -s` flow from [Hetzner's SSH key docs](https://docs.hetzner.com/storage/storage-box/backup-space-ssh-keys/) is therefore not applicable to the sub-accounts.

Convert the public keys to RFC4716 and write them into each sub's chroot through the **main account's** port-23 shell (the main account has full read/write across every sub's home directory):

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

#### Step 4. Stage the secrets on the HA host

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

Push everything to the HA host. The `-O` flag selects the original SCP wire protocol; HAOS BusyBox ssh does not implement the SFTP transfer protocol that OpenSSH clients default to:

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

#### Step 5. Configure the app

Set the following in the app's **Configuration** tab. Replace the `<MAIN>-sub<N>` placeholders with the usernames the Cloud Console assigned in step 1:

| Option | Value |
| --- | --- |
| `backup_enabled` | `true` |
| `archive_timeout_seconds` | `3600` (default — WAL is force-flushed every hour even with no DB activity) |
| `repo1_sftp_host` | `<MAIN>-sub<N>.your-storagebox.de` (the sub used for repo1) |
| `repo1_sftp_port` | `22` |
| `repo1_sftp_user` | `<MAIN>-sub<N>` |
| `repo1_sftp_path` | `/` |
| `repo2_sftp_host` | `<MAIN>-sub<M>.your-storagebox.de` (the sub used for repo2, distinct from repo1's) |
| `repo2_sftp_port` | `22` |
| `repo2_sftp_user` | `<MAIN>-sub<M>` |
| `repo2_sftp_path` | `/` |

> Always use port `22` and path `/`. Pointing pgBackRest at the main account, or at any sub-account with a non-`/` `repo*_sftp_path`, triggers the recursion segfault described above.

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

#### Step 6. Verify stanza creation and WAL archiving

After a successful first start, list the stanza contents from your workstation:

```bash
# List contents of each sub via SFTP
sftp -i ./repo1 -P 22 u404673-sub4@u404673-sub4.your-storagebox.de <<< 'ls -l'
sftp -i ./repo2 -P 22 u404673-sub5@u404673-sub5.your-storagebox.de <<< 'ls -l'
```

Each should list `archive/` and `backup/` directories owned by the corresponding sub-user.

Inspect pgBackRest's view of the stanza from inside the container:

```bash
ssh ha "docker exec addon_b872f4a0_timescaledb gosu postgres \
  pgbackrest --stanza=timescaledb info"
```

Verify WAL is reaching repo1. Run the check command via docker exec (substitute the actual container name, which you can find with `docker ps | grep timescale`):

```bash
ssh ha "docker exec <container> gosu postgres \
  pgbackrest --stanza=timescaledb check"
```

Expected behavior: repo1 WAL archive check passes with "WAL segment ... successfully archived to repo1". The command will report a timeout error for repo2 and exit non-zero (exit code 82) — this is expected. By design (D-22), the WAL archive stream is scoped to repo1 only; repo2 receives no continuous WAL. The check command cannot be scoped to a single repo, so the repo2 timeout is unavoidable and is not a malfunction.

#### Step 7. Store all four secrets in your password manager

This is the most important step. If these secrets are lost, all encrypted backups become permanently unrecoverable.

The four secrets to copy out-of-band, before anything else:

| Secret file (inside container) | What it is |
|--------------------------------|------------|
| `/data/secrets/pgbackrest_cipher_pass_repo1` | repo1 AES-256 cipher passphrase (auto-generated; immutable after stanza-create) |
| `/data/secrets/pgbackrest_cipher_pass_repo2` | repo2 AES-256 cipher passphrase (auto-generated; immutable after stanza-create) |
| `/data/secrets/pgbackrest_id_ed25519_repo1` | repo1 SSH private key (the file you copied in Step 4) |
| `/data/secrets/pgbackrest_id_ed25519_repo2` | repo2 SSH private key (the file you copied in Step 4) |

> Run each command below in a private terminal session. Before running: disable shell history logging for the session (`set +o history` in bash, or use a terminal that does not log history). Do not screenshot the output. Paste each secret directly into your password manager.

```bash
SECRETS=/mnt/data/supervisor/addons/data/b872f4a0_timescaledb/secrets
ssh ha "cat $SECRETS/pgbackrest_cipher_pass_repo1"
ssh ha "cat $SECRETS/pgbackrest_cipher_pass_repo2"
ssh ha "cat $SECRETS/pgbackrest_id_ed25519_repo1"
ssh ha "cat $SECRETS/pgbackrest_id_ed25519_repo2"
```

The cipher passphrases are immutable. After stanza-create, the app never regenerates them. Permanent loss of a passphrase means permanent loss of access to that repo's backups.

#### Phase 9: automated cron and observability sensors

If you are running Phase 9 or later, the `pgbackrest-cron` s6 longrun service starts
automatically with the app — no manual cron entry or scheduler configuration is needed.
Backups run daily at 02:00 UTC according to the schedule in
[What Phase 9 adds](#what-phase-9-adds).

After each successful backup, four Home Assistant sensors are updated:

| Entity | What it shows |
|--------|---------------|
| `sensor.timescaledb_backup_last_backup_repo1` | Timestamp of last successful repo1 backup |
| `sensor.timescaledb_backup_last_backup_repo2` | Timestamp of last successful repo2 backup |
| `sensor.timescaledb_backup_repo1_size` | repo1 backup catalog total size (bytes) |
| `sensor.timescaledb_backup_repo2_size` | repo2 backup catalog total size (bytes) |

These sensors are registered via MQTT discovery. After a Home Assistant restart the sensors
show as `unavailable` until the next 02:00 UTC backup window completes — the entities remain
visible in your dashboards and automations. The last known state is restored automatically when
HA reconnects to the MQTT broker.

### Capacity Planning

Storage estimates based on live system measurements (verified 2026-04-16):

| Metric | Observed value |
|--------|---------------|
| Compressed chunk growth | ~52 MiB/week |
| Backup size at 3-year steady state | ~5 GiB (pgBackRest block-level dedup + compression) |
| repo1 steady-state storage | ~190 GiB (3-year rolling fulls + diffs + WAL) |
| repo2 growth rate | one annual full per year (~5 GiB/year at current data rate) |

A Hetzner Storage Box BX11 (1 TB) comfortably fits both repos for the first decade under these numbers.

These figures assume default retention settings (monthly fulls for 3 years on repo1). Retention can be tuned via pgBackRest configuration.

### Verification

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

### Backup command reference (BKUP-14)

All commands run as the `postgres` user inside the app container. Resolve the container name at runtime:

```bash
CONTAINER=$(ssh ha "docker ps --format '{{.Names}}' | grep -i timescale")
```

pgBackRest requires the cipher passphrases as environment variables. The pattern below injects them scoped to the subprocess only — the values never appear in the process list visible to other users:

```bash
ssh ha "docker exec -e PGBACKREST_REPO1_CIPHER_PASS=\$(cat /data/secrets/pgbackrest_cipher_pass_repo1) \
  -e PGBACKREST_REPO2_CIPHER_PASS=\$(cat /data/secrets/pgbackrest_cipher_pass_repo2) \
  $CONTAINER gosu postgres pgbackrest --stanza=timescaledb <command>"
```

This is a documented scoped exception to the standard secret-injection guideline: pgBackRest provides no file-based or stdin alternative for `cipher-pass`; environment variables are the only supported mechanism for runtime passphrase injection.

| Command | Repo | Purpose | Notes |
|---------|------|---------|-------|
| `pgbackrest --stanza=timescaledb info --output=json` | both | List backups and WAL ranges for all repos | Use `-o json` for machine parsing |
| `pgbackrest --stanza=timescaledb check` | both | Force WAL switch and verify WAL segment reaches repo1 | Exits 82 by design: repo2 receives no streaming WAL (D-22); repo1 check line must show "successfully archived" |
| `pgbackrest --stanza=timescaledb --repo=1 backup --type=full` | repo1 | Full backup to repo1 | Triggered automatically by Phase 9 cron on monthly schedule |
| `pgbackrest --stanza=timescaledb --repo=1 backup --type=diff` | repo1 | Differential backup to repo1 | Since last full; smaller than full |
| `pgbackrest --stanza=timescaledb --repo=1 backup --type=incr` | repo1 | Incremental backup to repo1 | Since last backup of any type; smallest |
| `pgbackrest --stanza=timescaledb --repo=2 backup --type=full --no-archive-check` | repo2 | Annual archival full backup to repo2 | `--no-archive-check` required: repo2 has no streaming WAL by design; without the flag pgBackRest times out waiting for a WAL segment to appear in repo2 (exit 82) |
| `pgbackrest --stanza=timescaledb --repo=2 verify` | repo2 | Validate repo2 backup manifests and file checksums | `verify --no-pitr` is not valid in pgBackRest 2.58.0 (exit 31 "invalid option"). Run without it; behavior is equivalent since repo2 has no WAL archive stream to verify for PITR. |
| `pgbackrest --stanza=timescaledb --repo=1 restore --pg1-path=/data/restore-test/pgdata --delta` | repo1 | Restore latest backup to a scratch directory for drill | Does not affect live PGDATA; `--delta` is downgraded to full-copy automatically if the target directory is empty |
| `/usr/local/bin/pg_checksums --check -D /data/restore-test/pgdata` | — | Validate block checksums in a restored PGDATA | Must be preceded by `pg_resetwal -f /data/restore-test/pgdata` (see Phase 8 drill below) |

#### Restore to a new instance

To restore a backup to a Docker container on a laptop or cloud server — for example, after a
hardware failure or for an offline drill — use the `verify-restore` script:

```bash
./scripts/verify-restore/verify-restore.sh --repo 1
```

The script:

1. Pulls secrets from the HA host (or from your `pass` store if the Pi is offline)
2. Starts a throwaway `timescale/timescaledb:latest-pg18` Docker container
3. Installs pgBackRest and restores the most recent backup from the chosen repo
4. Queries both the restored database and the live HA instance to confirm row counts match
5. Cleans up the container and temp files on exit

See [`scripts/verify-restore/README.md`](../scripts/verify-restore/README.md) for flags,
credential modes, and prerequisites.

For offline use when the Pi is unavailable, use `--pgbackrest-conf` to provide a local
pgbackrest.conf and `--pass-path` to pull secrets from your password manager:

```bash
./scripts/verify-restore/verify-restore.sh \
  --repo 1 \
  --pgbackrest-conf ~/pgbackrest.conf \
  --pass-path home-assistant/backups
```

To restore to a fresh Pi (disaster recovery), follow the
[DR runbook](#disaster-recovery-runbook-bkup-12) instead — that procedure restores directly
to `/data/postgres` after staging secrets.

### Phase 8 drill commands

The following command sequences were executed on 2026-05-05 as the Phase 8 P1 gate (SC2, SC3, SC4). Run them quarterly to confirm both repos remain readable and restorable.

#### repo1 drill

SC3 (restore) + SC4 (checksum verification). Runtime: ~3 min restore + <1 min checksums.

```bash
CONTAINER=$(ssh ha "docker ps --format '{{.Names}}' | grep -i timescale")

# Create a fresh scratch directory
ssh ha "docker exec $CONTAINER install -d -m 700 -o postgres /data/restore-test/pgdata"

# Restore latest repo1 backup to scratch (delta is downgraded to full-copy if directory is empty)
ssh ha "docker exec \
  -e PGBACKREST_REPO1_CIPHER_PASS=\$(cat /mnt/data/supervisor/addons/data/b872f4a0_timescaledb/secrets/pgbackrest_cipher_pass_repo1) \
  -e PGBACKREST_REPO2_CIPHER_PASS=\$(cat /mnt/data/supervisor/addons/data/b872f4a0_timescaledb/secrets/pgbackrest_cipher_pass_repo2) \
  $CONTAINER gosu postgres \
  pgbackrest --stanza=timescaledb --repo=1 restore \
    --pg1-path=/data/restore-test/pgdata --delta"
```

Expected last lines of output:

```text
INFO: restore size = 2.4GB, file total = 1886
INFO: restore command end: completed successfully
```

pgBackRest restores pg_control last. The restored cluster has state "in production" (taken from a live cluster). `pg_checksums --check` requires state "shut down". Use `pg_resetwal -f` to transition the control file before running checksums — it only modifies the control file state and WAL pointer, not any data files:

```bash
# Transition pg_control to shut-down state (required before pg_checksums)
ssh ha "docker exec $CONTAINER gosu postgres pg_resetwal -f /data/restore-test/pgdata"

# Validate block checksums
ssh ha "docker exec $CONTAINER gosu postgres \
  /usr/local/bin/pg_checksums --check -D /data/restore-test/pgdata"
```

Expected pg_resetwal output: `Write-ahead log reset`

Expected pg_checksums output:

```text
Checksum operation completed
Files scanned:   1865
Blocks scanned:  316233
Bad checksums:  0
Data checksum version: 1
```

Phase 8 observed result: 0 bad checksums across 1865 files / 316,233 blocks.

Cleanup after drill:

```bash
ssh ha "docker exec $CONTAINER rm -rf /data/restore-test"
```

Verify cleanup: `ssh ha "docker exec $CONTAINER test -d /data/restore-test"` should return non-zero.

#### repo2 drill

SC2 (info + verify). Runtime: ~3 min. No data is downloaded — verify checks remote manifests and file checksums at source.

```bash
CONTAINER=$(ssh ha "docker ps --format '{{.Names}}' | grep -i timescale")

# Confirm at least one full backup exists in repo2 with status ok
ssh ha "docker exec \
  -e PGBACKREST_REPO1_CIPHER_PASS=\$(cat /mnt/data/supervisor/addons/data/b872f4a0_timescaledb/secrets/pgbackrest_cipher_pass_repo1) \
  -e PGBACKREST_REPO2_CIPHER_PASS=\$(cat /mnt/data/supervisor/addons/data/b872f4a0_timescaledb/secrets/pgbackrest_cipher_pass_repo2) \
  $CONTAINER gosu postgres \
  pgbackrest --stanza=timescaledb info --output=json"
```

Look for `"repo-key":2,"status":{"code":0,"message":"ok"}` and `"cipher":"aes-256-cbc"` in the output. Phase 8 confirmed: repo2 backup label `20260505-192628F`, 2.4 GB, status ok, cipher aes-256-cbc.

```bash
# Verify backup manifests and file checksums at source
ssh ha "docker exec \
  -e PGBACKREST_REPO1_CIPHER_PASS=\$(cat /mnt/data/supervisor/addons/data/b872f4a0_timescaledb/secrets/pgbackrest_cipher_pass_repo1) \
  -e PGBACKREST_REPO2_CIPHER_PASS=\$(cat /mnt/data/supervisor/addons/data/b872f4a0_timescaledb/secrets/pgbackrest_cipher_pass_repo2) \
  $CONTAINER gosu postgres \
  pgbackrest --stanza=timescaledb --repo=2 verify"
```

Expected last line: `verify command end: completed successfully`. Phase 8 observed: exit 0 in ~2.7 min.

Note: `--no-pitr` is not a valid option for `pgbackrest verify` in pgBackRest 2.58.0 (exit 31). Run without it.

The quarterly drill is manual in v1.1. Phase 10 (deferred) adds automated scheduling.

### What Phase 9 adds

Phase 9 automates the backup schedule established in Phase 8 and adds observability through
four Home Assistant sensors.

#### Automated backup schedule

The `pgbackrest-cron` service runs daily at 02:00 UTC without any user action:

| Day | Operation |
|-----|-----------|
| 1st Sunday of month | Full backup to repo1, then a diff to start the weekly chain |
| Other Sundays | Differential backup to repo1 |
| Monday–Saturday | Incremental backup to repo1 |
| January 1 | Annual full backup to repo2 (independent of the daily schedule) |

If a backup fails, it is retried up to 6 times (1 initial attempt + 5 retries with
60s, 120s, 300s, 600s, 900s backoff). After retry exhaustion a persistent notification
appears in Home Assistant.

#### Observability sensors

Four sensors are updated in Home Assistant after each backup completes:

| Entity | State | Attributes |
|--------|-------|------------|
| `sensor.timescaledb_backup_last_backup_repo1` | ISO timestamp of last successful repo1 backup | `backup_type`, `duration_seconds` |
| `sensor.timescaledb_backup_last_backup_repo2` | ISO timestamp of last successful repo2 backup | `backup_type`, `duration_seconds` |
| `sensor.timescaledb_backup_repo1_size` | repo1 total backup catalog size (bytes) | `unit_of_measurement: "B"` |
| `sensor.timescaledb_backup_repo2_size` | repo2 total backup catalog size (bytes) | `unit_of_measurement: "B"` |

`sensor.timescaledb_backup_last_backup_repo2` and `_repo2_size` are only updated on January 1 when the
annual backup runs. Both size sensors use raw bytes; Home Assistant and Grafana auto-scale the
display.

These sensors persist across Home Assistant restarts. They are registered via MQTT discovery
with retained messages — after a restart the sensors show as `unavailable` until the broker
reconnects (typically seconds), then restore to their last known state. No action is required.

### Disaster recovery runbook (BKUP-12)

This runbook covers the full path from a failed or replaced Raspberry Pi to a verified running
database. Follow these steps in order. The runbook assumes all four secrets are in your password
manager (the Phase 8 setup checkpoint confirmed this).

> **Warning:** If the Pi NVMe fails and the cipher passphrases were not copied to a password
> manager, the affected repo's encrypted backup is permanently unrecoverable.

#### Step 1. Provision a new HAOS instance

Install Home Assistant OS on the replacement hardware and complete initial setup. No HA
configuration is needed beyond basic system setup — backups are database-level, not HA-level.

#### Step 2. Install the TimescaleDB app

In **Settings > Apps > App Store**, click the three-dot menu, add the repository
`https://github.com/flaksit/ha-timescaledb`, find "TimescaleDB" and click **Install**.
Do NOT start it yet — start it after secrets are staged in Step 4.

#### Step 3. Locate the app's secrets directory

The host path for app data is:

```text
/mnt/data/supervisor/addons/data/<slug>_timescaledb/secrets/
```

Where `<slug>` is visible in **Settings > Apps > TimescaleDB** (typically `b872f4a0`).

```bash
SECRETS=/mnt/data/supervisor/addons/data/<slug>_timescaledb/secrets
ssh ha "mkdir -p $SECRETS"
```

#### Step 4. Stage secrets from your password manager

Retrieve all four secrets from your password manager and copy them to the HAOS host.

Use `pass` to pipe secrets directly to the HAOS host without them appearing in terminal
output or shell history. Replace `<pass-path>` with your actual password store path:

```bash
# Pipe cipher passphrases from password manager directly to remote file
pass show <pass-path>/pgbackrest_cipher_pass_repo1 | \
  ssh ha "install -m 600 /dev/stdin $SECRETS/pgbackrest_cipher_pass_repo1"
pass show <pass-path>/pgbackrest_cipher_pass_repo2 | \
  ssh ha "install -m 600 /dev/stdin $SECRETS/pgbackrest_cipher_pass_repo2"

# Pipe SSH private keys (multi-line PEM content)
pass show <pass-path>/pgbackrest_id_ed25519_repo1 | \
  ssh ha "install -m 600 /dev/stdin $SECRETS/pgbackrest_id_ed25519_repo1"
pass show <pass-path>/pgbackrest_id_ed25519_repo2 | \
  ssh ha "install -m 600 /dev/stdin $SECRETS/pgbackrest_id_ed25519_repo2"
```

If you use a different password manager, paste each secret using `cat` with history disabled:

```bash
set +o history                              # disable shell history for this session
ssh ha "cat > $SECRETS/pgbackrest_cipher_pass_repo1"   # paste, then Ctrl-D
ssh ha "cat > $SECRETS/pgbackrest_cipher_pass_repo2"
ssh ha "cat > $SECRETS/pgbackrest_id_ed25519_repo1"
ssh ha "cat > $SECRETS/pgbackrest_id_ed25519_repo2"
ssh ha "chmod 600 $SECRETS/pgbackrest_cipher_pass_repo1 \
  $SECRETS/pgbackrest_cipher_pass_repo2 \
  $SECRETS/pgbackrest_id_ed25519_repo1 \
  $SECRETS/pgbackrest_id_ed25519_repo2"
set -o history
```

Re-generate known_hosts files from the SFTP hosts (host fingerprints do not change unless
the Hetzner Storage Box is migrated):

```bash
ssh-keyscan -p 22 -t rsa,ecdsa,ed25519 <repo1-sftp-host> | \
  ssh ha "cat > $SECRETS/pgbackrest_known_hosts_repo1"
ssh-keyscan -p 22 -t rsa,ecdsa,ed25519 <repo2-sftp-host> | \
  ssh ha "cat > $SECRETS/pgbackrest_known_hosts_repo2"
```

Set ownership (uid 70 = postgres in the app container):

```bash
ssh ha "chown 70:70 $SECRETS/pgbackrest_cipher_pass_repo1 \
  $SECRETS/pgbackrest_cipher_pass_repo2 \
  $SECRETS/pgbackrest_id_ed25519_repo1 \
  $SECRETS/pgbackrest_id_ed25519_repo2 \
  $SECRETS/pgbackrest_known_hosts_repo1 \
  $SECRETS/pgbackrest_known_hosts_repo2"
```

#### Step 5. Configure and start the app

In **Settings > Apps > TimescaleDB**, set the same SFTP options as the original installation
(repo1/repo2 host, port, user, path; `backup_enabled: true`). Start the app.

The init script will:

1. Detect the existing cipher passphrases (files already present — not regenerated)
2. Run `pgbackrest stanza-create` against both repos
3. Enable WAL archiving

Confirm in the app log: `pgBackRest: backup provisioning complete — WAL archiving active`

#### Step 6. Stop PostgreSQL and restore the backup

The restore overwrites the data directory. Stop PostgreSQL cleanly:

```bash
CONTAINER=$(ssh ha "docker ps --format '{{.Names}}' | grep -i timescale")
ssh ha "docker exec $CONTAINER gosu postgres pg_ctl stop -D /data/postgres -m fast"
```

Run the restore. This replaces `/data/postgres` with the contents of the most recent backup
in repo1. Replace `--repo=1` with `--repo=2` to restore from the annual archival backup:

```bash
ssh ha "docker exec \
  -e PGBACKREST_REPO1_CIPHER_PASS=\$(cat $SECRETS/pgbackrest_cipher_pass_repo1) \
  -e PGBACKREST_REPO2_CIPHER_PASS=\$(cat $SECRETS/pgbackrest_cipher_pass_repo2) \
  $CONTAINER gosu postgres \
  pgbackrest --stanza=timescaledb --repo=1 \
    restore --pg1-path=/data/postgres --delta"
```

Expected final output line: `restore command end: completed successfully`

#### Step 7. Start PostgreSQL and verify row counts

Restart the app (or start PostgreSQL directly via the app's restart button). PostgreSQL will
enter crash recovery on the restored cluster — this is normal and completes automatically.

After the app log shows `Database 'homeassistant' with TimescaleDB ready`, verify data:

```bash
ssh ha "docker exec $CONTAINER psql -h /tmp -U postgres -d homeassistant \
  -c 'SELECT count(*), max(time), min(time) FROM states'"
```

The row count should match the last known count within roughly 1 hour of unarchived WAL
(bounded by `archive_timeout_seconds`, default 3600s). The `max(time)` value confirms the
restore point.

#### Step 8. Reconnect Home Assistant integrations

Re-install or reconfigure HA integrations that write to TimescaleDB:

- The ha-timescaledb-recorder integration (HACS): re-install from HACS if needed; it
  auto-reconnects on the next restart.

#### SCD2 integrity spot-check (optional)

Verify that SCD2 dimension tables are intact and the chain is unbroken:

```bash
ssh ha "docker exec $CONTAINER psql -h /tmp -U postgres -d homeassistant -c \
  'SELECT count(*) FROM dim_entities WHERE valid_to IS NULL'"
```

This returns the count of currently-active entity rows (`valid_to = NULL` = current version).
A non-zero result with counts matching the original metadata table confirms SCD2 integrity.

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

## Copying historical SQLite data to PostgreSQL

A separate tool in the [paradise-ha](https://github.com/flaksit/paradise-ha) repository copies HA's existing SQLite history (`home-assistant_v2.db`) into the `homeassistant` database in this app. The tool runs against a read-only mount of the SQLite file while HA keeps writing to it.

This is useful in either deployment:

- **Parallel analytics:** seed the PostgreSQL copy with HA's existing history so Grafana / TimescaleDB queries see more than just data accumulated since this app was installed. HA continues recording into SQLite as before.
- **Recorder migration:** populate PostgreSQL before flipping `recorder.db_url`, so the new recorder backend already has the past. Mutable tip rows (the entity's current state and the open recorder run) are skipped during the bulk pass and must be reconciled against the live SQLite before flipping `db_url`; consult the migration tool's own README for the recommended cutover sequence.

### Prerequisites

- This TimescaleDB app installed and running (see Installation above)
- SSH access to the HAOS host (alias `ha` is assumed below)
- The migration tooling from [paradise-ha](https://github.com/flaksit/paradise-ha) cloned on your workstation

### Step 1: Prepare the schema

The migration tool ships a `reset-schema.sh` that drops and recreates the schema in the `homeassistant` database. Transfer the tool to the Pi and run it:

```bash
cd paradise-ha
tar cf - scripts/migrate/Dockerfile scripts/migrate/.dockerignore \
  scripts/migrate/migrate.py scripts/migrate/pyproject.toml \
  scripts/migrate/uv.lock scripts/migrate/reset-schema.sh \
  scripts/migrate/schema/ha_schema.sql \
  | ssh ha "mkdir -p /tmp/ha-migrate && tar xf - --strip-components=2 -C /tmp/ha-migrate"

ssh ha "bash /tmp/ha-migrate/reset-schema.sh"
```

In a parallel-analytics deployment, run `reset-schema.sh` only the first time you copy history. Re-running it drops everything that has accumulated in PostgreSQL since (including any continuous aggregates and Grafana writes against the same database).

### Step 2: Build the migration container

```bash
ssh ha "cd /tmp/ha-migrate && docker build -t ha-migrate:latest ."
```

Produces a Python + psycopg3 image used in the next steps.

### Step 3: Smoke-test against a small slice

```bash
PG_PASS=$(ssh ha "docker exec addon_b872f4a0_timescaledb cat /data/secrets/homeassistant_password")

ssh ha "docker run --rm --network hassio \
  -v /mnt/data/supervisor/homeassistant/home-assistant_v2.db:/data/home-assistant_v2.db:ro \
  -v /mnt/data/supervisor/homeassistant/home-assistant_v2.db-shm:/data/home-assistant_v2.db-shm:ro \
  -v /mnt/data/supervisor/homeassistant/home-assistant_v2.db-wal:/data/home-assistant_v2.db-wal:ro \
  -e SQLITE_PATH=/data/home-assistant_v2.db \
  -e PG_DSN='postgresql://homeassistant:${PG_PASS}@b872f4a0-timescaledb:5432/homeassistant' \
  ha-migrate:latest --smoke-test 3000 --skip-mutable"
```

A successful run ends with `RESULT: SUCCESS` and copies a small subset with column-by-column verification.

### Step 4: Reset and run the full copy

```bash
# Drop the smoke-test rows and re-create the schema
ssh ha "bash /tmp/ha-migrate/reset-schema.sh"

# Full copy
ssh ha "docker run --rm --network hassio \
  -v /mnt/data/supervisor/homeassistant/home-assistant_v2.db:/data/home-assistant_v2.db:ro \
  -v /mnt/data/supervisor/homeassistant/home-assistant_v2.db-shm:/data/home-assistant_v2.db-shm:ro \
  -v /mnt/data/supervisor/homeassistant/home-assistant_v2.db-wal:/data/home-assistant_v2.db-wal:ro \
  -e SQLITE_PATH=/data/home-assistant_v2.db \
  -e PG_DSN='postgresql://homeassistant:${PG_PASS}@b872f4a0-timescaledb:5432/homeassistant' \
  ha-migrate:latest --skip-mutable --batch-size 10000"
```

`--skip-mutable` excludes rows HA is actively updating (current state per entity, the open recorder run). They are copied, verified, deleted from PostgreSQL, and recorded in `_migrate_excluded`. If you intend to swap the recorder, reconcile that table against live SQLite during the cutover (see the migration tool's README); otherwise the excluded rows simply remain unimported.

Run time depends on database size and Pi class; expect roughly an hour for a multi-tens-of-millions-of-rows states table on a Pi 5.

### Verification

The tool runs verification on every batch and on every reset:

- **Row counts:** exact match between SQLite and PostgreSQL for every copied primary-key range
- **PK hash:** streaming MD5 of ordered primary keys, which catches swapped, duplicate, or missing rows
- **Exhaustive column comparison:** smoke test only

Exit code 0 means all batches matched, 1 means at least one row diverged.

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

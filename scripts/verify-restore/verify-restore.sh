#!/usr/bin/env bash
# verify-restore.sh — Restore a pgBackRest backup to a throwaway Docker container and verify
# the backup is valid and row counts match the live TimescaleDB instance.
#
# Usage: ./verify-restore.sh [options]
# See scripts/verify-restore/README.md for full documentation.
set -euo pipefail

# ────────────────────────────────────────────────────────────────────────────
# Default configuration (all overridable via flags or env)
# ────────────────────────────────────────────────────────────────────────────
HA_SSH="${HA_SSH:-ha}"
CONTAINER=""                      # resolved from live docker ps if not set via --container
REPO="1"                          # which repo to restore from (1 or 2)
SECRETS_DIR_FLAG=""               # --secrets-dir: local directory with pre-copied secrets (priority 3)
PASS_PREFIX=""                    # --pass-path: pass store path prefix (priority 2)
PGBACKREST_CONF_PATH=""           # --pgbackrest-conf: local pgbackrest.conf to use (offline fallback)
DOCKER_IMAGE="timescale/timescaledb:latest-pg18"
RESTORE_DIR="$(mktemp -d)"
CONTAINER_NAME="pgbackrest-verify-$$"   # unique name per run; cleaned up on EXIT

# ────────────────────────────────────────────────────────────────────────────
# Usage
# ────────────────────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Usage: verify-restore.sh [OPTIONS]

Restore a pgBackRest backup to a throwaway Docker container and verify it.
See scripts/verify-restore/README.md for details.

Options:
  --ha-ssh <alias>         SSH alias for the HAOS host (default: ha)
  --container <name>       TimescaleDB container name on the HAOS host (default: auto-detected)
  --repo <1|2>             pgBackRest repo to restore from (default: 1)
  --secrets-dir <path>     Local directory containing pre-copied secret files (priority 3)
  --pass-path <prefix>     pass store path prefix for offline secret retrieval (priority 2)
  --pgbackrest-conf <path> Local pgbackrest.conf to use instead of fetching from the live container.
                           Required when the live Pi/container is unavailable (offline DR scenario).
  -h, --help               Show this message and exit
EOF
}

# ────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ────────────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ha-ssh)             HA_SSH="$2"; shift 2 ;;
    --container)          CONTAINER="$2"; shift 2 ;;
    --repo)               REPO="$2"; shift 2 ;;
    --secrets-dir)        SECRETS_DIR_FLAG="$2"; shift 2 ;;
    --pass-path)          PASS_PREFIX="$2"; shift 2 ;;
    --pgbackrest-conf)    PGBACKREST_CONF_PATH="$2"; shift 2 ;;
    -h|--help)            usage; exit 0 ;;
    *)                    echo "Unknown flag: $1"; usage; exit 1 ;;
  esac
done

# Validate repo value
if [[ "$REPO" != "1" && "$REPO" != "2" ]]; then
  echo "ERROR: --repo must be 1 or 2 (got: ${REPO})"
  exit 1
fi

# ────────────────────────────────────────────────────────────────────────────
# Cleanup trap — always remove the verify container and temp dirs on exit
# ────────────────────────────────────────────────────────────────────────────
TMPDIR_SECRETS=$(mktemp -d)
trap 'rm -rf "$TMPDIR_SECRETS" "$RESTORE_DIR"; docker rm -f "$CONTAINER_NAME" 2>/dev/null || true' EXIT

# ────────────────────────────────────────────────────────────────────────────
# Resolve live container name (skip if offline mode is active)
# ────────────────────────────────────────────────────────────────────────────
if [[ -z "$CONTAINER" ]]; then
  CONTAINER=$(ssh "$HA_SSH" "docker ps --format '{{.Names}}' | grep -i timescale" 2>/dev/null) \
    || true
  if [[ -z "$CONTAINER" ]]; then
    if [[ -n "$PGBACKREST_CONF_PATH" ]]; then
      echo "INFO: live container not found; proceeding with --pgbackrest-conf (offline mode)"
    else
      echo "ERROR: could not resolve TimescaleDB container name."
      echo "       Use --container to specify it explicitly, or --pgbackrest-conf for offline mode."
      exit 1
    fi
  fi
fi

# ────────────────────────────────────────────────────────────────────────────
# Secret acquisition — fetch_secret <filename> <dest_file>
#
# Three-priority strategy (D-07):
#   1. ssh cat /data/secrets/<file>  — primary: no SCP on HAOS; pipe works
#   2. pass show <prefix>/<file>     — offline fallback; only if --pass-path given
#   3. --secrets-dir <path>          — last resort; only if --secrets-dir given
#
# Exits 1 if all three fail.
# ────────────────────────────────────────────────────────────────────────────
fetch_secret() {
  local filename="$1"
  local dest_file="$2"

  # Priority 1: SSH cat from HAOS /data/secrets/
  if ssh "$HA_SSH" "cat /data/secrets/${filename}" > "$dest_file" 2>/dev/null \
      && [[ -s "$dest_file" ]]; then
    return 0
  fi

  # Priority 2: pass store (offline fallback; only when --pass-path was given)
  if [[ -n "$PASS_PREFIX" ]]; then
    if pass show "${PASS_PREFIX}/${filename}" > "$dest_file" 2>/dev/null \
        && [[ -s "$dest_file" ]]; then
      return 0
    fi
  fi

  # Priority 3: --secrets-dir local directory (last resort)
  if [[ -n "$SECRETS_DIR_FLAG" && -f "${SECRETS_DIR_FLAG}/${filename}" ]]; then
    cp "${SECRETS_DIR_FLAG}/${filename}" "$dest_file"
    return 0
  fi

  echo "ERROR: could not acquire secret '${filename}'"
  echo "       Tried: ssh ${HA_SSH} cat /data/secrets/${filename}"
  [[ -n "$PASS_PREFIX" ]]      && echo "       Tried: pass show ${PASS_PREFIX}/${filename}"
  [[ -n "$SECRETS_DIR_FLAG" ]] && echo "       Tried: ${SECRETS_DIR_FLAG}/${filename}"
  echo "       Use --pass-path or --secrets-dir to provide secrets when the live Pi is offline."
  exit 1
}

# ────────────────────────────────────────────────────────────────────────────
# Fetch secrets for the chosen repo
# ────────────────────────────────────────────────────────────────────────────
echo "==> Fetching secrets for repo${REPO} ..."
fetch_secret "pgbackrest_cipher_pass_repo${REPO}" "${TMPDIR_SECRETS}/cipher_pass"
fetch_secret "pgbackrest_id_ed25519_repo${REPO}"  "${TMPDIR_SECRETS}/id_ed25519"
fetch_secret "pgbackrest_known_hosts_repo${REPO}" "${TMPDIR_SECRETS}/known_hosts"
chmod 600 "${TMPDIR_SECRETS}/id_ed25519"

# ────────────────────────────────────────────────────────────────────────────
# Fetch or use pgbackrest.conf
# ────────────────────────────────────────────────────────────────────────────
if [[ -n "$PGBACKREST_CONF_PATH" ]]; then
  # Offline mode: operator-provided config avoids the live container dependency.
  # WHY: if the Pi/NVMe/container is unavailable, `docker exec ... cat` cannot fetch
  # the live config. --pgbackrest-conf lets the operator supply a saved or manually
  # reconstructed pgbackrest.conf for the offline DR scenario.
  cp "$PGBACKREST_CONF_PATH" "${TMPDIR_SECRETS}/pgbackrest.conf"
  echo "INFO: using provided pgbackrest.conf (offline mode)"
else
  echo "==> Fetching pgbackrest.conf from live container ..."
  ssh "$HA_SSH" "docker exec ${CONTAINER} cat /etc/pgbackrest/pgbackrest.conf" \
    > "${TMPDIR_SECRETS}/pgbackrest.conf"
fi

# ────────────────────────────────────────────────────────────────────────────
# Pull Docker image (done before starting container so errors surface early)
# ────────────────────────────────────────────────────────────────────────────
echo "==> Pulling Docker image ${DOCKER_IMAGE} ..."
docker pull "${DOCKER_IMAGE}"

# ────────────────────────────────────────────────────────────────────────────
# Start the verify container with sleep entrypoint (NOT the normal PG start)
#
# WHY --entrypoint /bin/sleep: timescale/timescaledb starts PostgreSQL automatically
# when launched normally. Restoring into a PGDATA while PostgreSQL is running would
# corrupt the cluster. Using 'sleep infinity' keeps the container alive but idle so
# we can restore into the empty PGDATA first, then start PG explicitly.
# ────────────────────────────────────────────────────────────────────────────
echo "==> Starting verify container '${CONTAINER_NAME}' ..."
docker run -d \
  --name "${CONTAINER_NAME}" \
  --entrypoint /bin/sleep \
  -v "${RESTORE_DIR}:/restore/pgdata" \
  -v "${TMPDIR_SECRETS}:/secrets:ro" \
  "${DOCKER_IMAGE}" \
  infinity

# ────────────────────────────────────────────────────────────────────────────
# Install pgBackRest inside the verify container
#
# WHY apt-get: pgBackRest is not bundled in the timescale/timescaledb Docker image.
# The image is Debian-based; apt resolves all runtime dependencies automatically.
# No ldd guard needed (unlike Alpine musl builds).
# ────────────────────────────────────────────────────────────────────────────
echo "==> Installing pgBackRest in verify container ..."
docker exec "${CONTAINER_NAME}" bash -c "apt-get update -qq && apt-get install -y -qq pgbackrest"

# ────────────────────────────────────────────────────────────────────────────
# Copy pgbackrest.conf into the verify container and patch it
# ────────────────────────────────────────────────────────────────────────────
echo "==> Configuring pgbackrest.conf in verify container ..."
docker exec "${CONTAINER_NAME}" mkdir -p /etc/pgbackrest
docker cp "${TMPDIR_SECRETS}/pgbackrest.conf" "${CONTAINER_NAME}:/etc/pgbackrest/pgbackrest.conf"

# Point pg1-path to the restore volume mount inside this container
docker exec "${CONTAINER_NAME}" bash -c \
  "sed -i 's|pg1-path=.*|pg1-path=/restore/pgdata|' /etc/pgbackrest/pgbackrest.conf"

# Override SSH key and known_hosts paths to the read-only /secrets mount
docker exec "${CONTAINER_NAME}" bash -c \
  "sed -i \"s|repo${REPO}-sftp-private-key-file=.*|repo${REPO}-sftp-private-key-file=/secrets/id_ed25519|\" /etc/pgbackrest/pgbackrest.conf; \
   sed -i \"s|repo${REPO}-sftp-known-hosts-file=.*|repo${REPO}-sftp-known-hosts-file=/secrets/known_hosts|\" /etc/pgbackrest/pgbackrest.conf"

# The /secrets volume is mounted :ro; chmod must be applied inside the container separately
# by touching the file via docker exec into a writable location is not needed since the key
# is already in the volume with correct host permissions (chmod 600 applied above).

# WHY log-path and spool-path redirects: /var/log/pgbackrest and /var/lib/pgbackrest may
# not exist or lack write permissions in the Debian timescale image (different from the live
# Alpine-based Pi image). Redirect both to /tmp which is always writable in any container.
docker exec "${CONTAINER_NAME}" bash -c \
  "mkdir -p /tmp/pgbackrest-logs /tmp/pgbackrest-spool; \
   sed -i 's|log-path=.*|log-path=/tmp/pgbackrest-logs|' /etc/pgbackrest/pgbackrest.conf; \
   if grep -q '^spool-path=' /etc/pgbackrest/pgbackrest.conf; then \
     sed -i 's|spool-path=.*|spool-path=/tmp/pgbackrest-spool|' /etc/pgbackrest/pgbackrest.conf; \
   else \
     echo 'spool-path=/tmp/pgbackrest-spool' >> /etc/pgbackrest/pgbackrest.conf; \
   fi; \
   if ! grep -q '^log-path=' /etc/pgbackrest/pgbackrest.conf; then \
     echo 'log-path=/tmp/pgbackrest-logs' >> /etc/pgbackrest/pgbackrest.conf; \
   fi"

# ────────────────────────────────────────────────────────────────────────────
# Fetch backup info BEFORE restore to get the backup stop timestamp
#
# Primary freshness check (review finding): max(time) in the states table is NOT
# the same as backup freshness. If no HA state changed recently, a valid and current
# backup would fail a max(time) freshness check. The pgBackRest backup stop timestamp
# (.backup[].timestamp.stop in the info JSON) is the authoritative signal.
# ────────────────────────────────────────────────────────────────────────────
echo "==> Fetching backup info for repo${REPO} ..."
_info_json=$(docker exec \
  -e "PGBACKREST_REPO${REPO}_CIPHER_PASS=$(cat "${TMPDIR_SECRETS}/cipher_pass")" \
  "${CONTAINER_NAME}" \
  pgbackrest --stanza=timescaledb "--repo=${REPO}" info --output=json 2>/dev/null \
  || echo '[]')

# Extract stop timestamp of the most recent backup for this repo.
# .backup[] entries carry timestamps; we select by database.repo-key matching REPO.
_backup_stop=$(printf '%s' "${_info_json}" | jq -r \
  ".[0].backup | map(select(.database.\"repo-key\" == ${REPO})) | last | .timestamp.stop // 0")

# ────────────────────────────────────────────────────────────────────────────
# Run pgbackrest restore into the stopped PGDATA
# ────────────────────────────────────────────────────────────────────────────
echo "==> Restoring repo${REPO} backup to /restore/pgdata ..."
docker exec \
  -e "PGBACKREST_REPO${REPO}_CIPHER_PASS=$(cat "${TMPDIR_SECRETS}/cipher_pass")" \
  "${CONTAINER_NAME}" \
  pgbackrest --stanza=timescaledb "--repo=${REPO}" \
    restore --pg1-path=/restore/pgdata --delta

# ────────────────────────────────────────────────────────────────────────────
# Start PostgreSQL explicitly after restore completes
#
# WHY explicit start: the container was started with 'sleep infinity' as entrypoint
# so PostgreSQL did not auto-start. PG must not be running during restore (it writes
# to PGDATA). Now that restore is complete, start it explicitly.
# ────────────────────────────────────────────────────────────────────────────
echo "==> Starting PostgreSQL in verify container ..."
docker exec "${CONTAINER_NAME}" bash -c \
  "chown -R postgres:postgres /restore/pgdata && \
   gosu postgres pg_ctl start -D /restore/pgdata -o '-k /tmp --port=5433' -w -t 60"

# ────────────────────────────────────────────────────────────────────────────
# Verify step 1 — Primary freshness check: pgBackRest backup stop timestamp
# ────────────────────────────────────────────────────────────────────────────
_freshness_ok=true
_rowcount_ok=true

_now=$(date +%s)
if [[ "$REPO" == "1" ]]; then
  _max_age=90000    # 25 hours for repo1 (daily backup schedule, BKUP-06)
else
  _max_age=31536000 # 1 year for repo2 (annual backup schedule, BKUP-06)
fi

_age=$(( _now - _backup_stop ))
echo "Backup stop timestamp: ${_backup_stop} (${_age}s ago, limit: ${_max_age}s)"
if [[ "$_backup_stop" -gt "$(( _now - _max_age ))" ]]; then
  echo "PASS: backup freshness check (stop_time within allowed window for repo${REPO})"
else
  echo "FAIL: backup stop_time is ${_age}s ago, exceeds ${_max_age}s limit for repo${REPO}"
  _freshness_ok=false
fi

# ────────────────────────────────────────────────────────────────────────────
# Verify step 2 — Secondary data sanity: max(time) from restored DB
#
# WHY secondary: max(time) can appear stale if no HA entity changed state recently,
# even with a fresh and valid backup. Logged for visibility; not a failure gate alone.
# ────────────────────────────────────────────────────────────────────────────
_restored_max=$(docker exec "${CONTAINER_NAME}" bash -c \
  "gosu postgres psql -h /tmp -p 5433 -U postgres -d homeassistant -tAc \
  'SELECT max(time) FROM states'" 2>/dev/null \
  || echo "NULL")
echo "Restored DB max(time): ${_restored_max}"

# ────────────────────────────────────────────────────────────────────────────
# Verify step 3 — Exact row count match (requires live Pi via ssh)
# Skipped in offline mode (when live container is unavailable).
# ────────────────────────────────────────────────────────────────────────────
if [[ -n "${CONTAINER}" ]]; then
  echo "==> Comparing row counts between restored and live DB ..."
  _restored_counts=$(docker exec "${CONTAINER_NAME}" bash -c \
    "gosu postgres psql -h /tmp -p 5433 -U postgres -d homeassistant -tAc \
    'SELECT count(*) || chr(9) || max(time) || chr(9) || min(time) FROM states'")
  _cnt_r=$(printf '%s' "$_restored_counts" | cut -f1)
  _max_r=$(printf '%s' "$_restored_counts" | cut -f2)
  _min_r=$(printf '%s' "$_restored_counts" | cut -f3)

  # Query live DB with time <= restored max to get a comparable slice
  _live_counts=$(ssh "$HA_SSH" "docker exec ${CONTAINER} psql -h /tmp -U postgres \
    -d homeassistant -tAc \
    \"SELECT count(*) || chr(9) || max(time) || chr(9) || min(time) FROM states WHERE time <= '${_max_r}'\"")
  _cnt_l=$(printf '%s' "$_live_counts" | cut -f1)
  _max_l=$(printf '%s' "$_live_counts" | cut -f2)
  _min_l=$(printf '%s' "$_live_counts" | cut -f3)

  if [[ "$_cnt_r" == "$_cnt_l" && "$_max_r" == "$_max_l" && "$_min_r" == "$_min_l" ]]; then
    echo "PASS: row count exact match (restored=${_cnt_r} rows, live=${_cnt_l} rows)"
  else
    echo "FAIL: row count mismatch"
    echo "  Restored: count=${_cnt_r}, max=${_max_r}, min=${_min_r}"
    echo "  Live:     count=${_cnt_l}, max=${_max_l}, min=${_min_l}"
    _rowcount_ok=false
  fi
else
  echo "INFO: live container unavailable (offline mode) — skipping exact row count match"
fi

# ────────────────────────────────────────────────────────────────────────────
# Shutdown the restore PG and report summary
# ────────────────────────────────────────────────────────────────────────────
docker exec "${CONTAINER_NAME}" bash -c \
  "gosu postgres pg_ctl stop -D /restore/pgdata -m fast" 2>/dev/null || true

echo ""
echo "==> Verify complete"
if [[ "${_freshness_ok}" == "false" || "${_rowcount_ok}" == "false" ]]; then
  echo "RESULT: FAILED"
  exit 1
else
  echo "RESULT: PASSED"
fi

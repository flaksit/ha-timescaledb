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
CONTAINER_NAME="pgbackrest-verify-$$"   # unique name per run; cleaned up on EXIT
KEEP=0                            # --keep: skip container teardown + leave PG running for inspection
# Default ties to the addon's archive_timeout_seconds default (3600 — see
# timescaledb/config.yaml). The 300s slack covers verify-container startup,
# pgbackrest install, restore, PG start, and the final archive-get round trips
# observed in practice. Override with --max-recovery-lag when the live cluster
# runs a non-default archive_timeout.
MAX_RECOVERY_LAG=3900             # --max-recovery-lag: seconds, repo1 PITR lag ceiling
RECOVERY_WAIT_TIMEOUT=300         # --recovery-wait-timeout: seconds, max to wait for pg_is_in_recovery()=false

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
  --keep                   After a successful verify, leave the verify container + PostgreSQL
                           running so the restored database can be inspected interactively.
                           Prints connection and cleanup commands. Default: tear everything down.
  --max-recovery-lag <s>   For --repo=1 only: max allowed seconds between live max(last_updated)
                           and restored max(last_updated). Proves WAL replay reached near-current.
                           Default: 3900 (PG archive_timeout default 3600 + 300 script overhead).
  --recovery-wait-timeout <s>
                           For --repo=1 only: max seconds to wait for pg_is_in_recovery() to
                           flip to false after PG accepts connections. Default: 300.
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
    --keep)               KEEP=1; shift ;;
    --max-recovery-lag)   MAX_RECOVERY_LAG="$2"; shift 2 ;;
    --recovery-wait-timeout) RECOVERY_WAIT_TIMEOUT="$2"; shift 2 ;;
    -h|--help)            usage; exit 0 ;;
    *)                    echo "Unknown flag: $1"; usage; exit 1 ;;
  esac
done

# Validate repo value
if [[ "$REPO" != "1" && "$REPO" != "2" ]]; then
  echo "ERROR: --repo must be 1 or 2 (got: ${REPO})"
  exit 1
fi

# Validate recovery-lag threshold
if ! [[ "$MAX_RECOVERY_LAG" =~ ^[0-9]+$ ]] || [[ "$MAX_RECOVERY_LAG" -lt 1 ]]; then
  echo "ERROR: --max-recovery-lag must be a positive integer (got: ${MAX_RECOVERY_LAG})"
  exit 1
fi

# Validate recovery-wait timeout
if ! [[ "$RECOVERY_WAIT_TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$RECOVERY_WAIT_TIMEOUT" -lt 1 ]]; then
  echo "ERROR: --recovery-wait-timeout must be a positive integer (got: ${RECOVERY_WAIT_TIMEOUT})"
  exit 1
fi

# ────────────────────────────────────────────────────────────────────────────
# Cleanup trap — remove the verify container and temp dirs on exit
#
# WHY two cleanup tiers: with --keep, a successful verify must leave the
# container alive for inspection. The trap registered here is the "full" teardown
# used on early failures (e.g. before the container even exists) and for default
# (non-keep) runs. When --keep is in effect AND the verify succeeds, the trap is
# disarmed at the end of the script (see the final block) so the container and
# its PG remain reachable. Temp dirs are always removed (secrets must not leak),
# but the container is only force-removed when KEEP=0 or the run failed.
# ────────────────────────────────────────────────────────────────────────────
TMPDIR_SECRETS=$(mktemp -d)
_cleanup_on_exit() {
  # Always remove secret temp dirs (must not leak SSH keys, cipher passes).
  rm -rf "$TMPDIR_SECRETS"
  # On --keep, leave the verify container in place even when the script aborted
  # early (e.g. pg_ctl timeout, set -e abort), so the operator can inspect
  # /tmp/pg.log, /tmp/pgbackrest-logs/, /restore/pgdata, and the partial state.
  # Without --keep, full teardown.
  if [[ "${KEEP:-0}" -ne 1 ]]; then
    docker rm -fv "$CONTAINER_NAME" 2>/dev/null || true
  fi
}
trap '_cleanup_on_exit' EXIT

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
#   1. ssh ha "docker exec <ctr> cat /data/secrets/<file>"
#      — primary: secrets live inside the addon container at /data/secrets/;
#        the path does not exist on the HAOS host filesystem. Requires the
#        live container to be reachable (skipped in offline DR mode where
#        CONTAINER is empty).
#   2. pass show <prefix>/<file>     — offline fallback; only if --pass-path given
#   3. --secrets-dir <path>          — last resort; only if --secrets-dir given
#
# Exits 1 if all three fail.
# ────────────────────────────────────────────────────────────────────────────
_fetch_secret_quiet() {
  # Try the three priority sources. Returns 0 if the secret is found and non-empty,
  # non-zero (and removes the dest file) otherwise. Never prints, never exits.
  local filename="$1"
  local dest_file="$2"

  # Priority 1: docker exec cat into the live addon container.
  if [[ -n "$CONTAINER" ]] \
      && ssh "$HA_SSH" "docker exec ${CONTAINER} cat /data/secrets/${filename}" \
            > "$dest_file" 2>/dev/null \
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

  rm -f "$dest_file"
  return 1
}

fetch_secret() {
  # Strict variant: secret must be present. Exits 1 with a diagnostic on miss.
  local filename="$1"
  local dest_file="$2"
  if _fetch_secret_quiet "$filename" "$dest_file"; then
    return 0
  fi
  echo "ERROR: could not acquire secret '${filename}'"
  echo "       Tried: ssh ${HA_SSH} docker exec ${CONTAINER:-<container>} cat /data/secrets/${filename}"
  [[ -n "$PASS_PREFIX" ]]      && echo "       Tried: pass show ${PASS_PREFIX}/${filename}"
  [[ -n "$SECRETS_DIR_FLAG" ]] && echo "       Tried: ${SECRETS_DIR_FLAG}/${filename}"
  echo "       Use --pass-path or --secrets-dir to provide secrets when the live Pi is offline."
  exit 1
}

fetch_secret_optional() {
  # Optional variant: returns 0 if found, 1 if not. No diagnostic, no exit.
  _fetch_secret_quiet "$1" "$2"
}

# ────────────────────────────────────────────────────────────────────────────
# Fetch secrets for the chosen repo (strict) + the other repo's cipher pass
# (optional — see below).
#
# WHY both cipher passes: pgbackrest validates the cipher-pass for every repo
# declared with cipher-type=... in the conf on every invocation, even when only
# one --repo=N is targeted. With both repos encrypted (the default for this
# addon), a --repo=1 restore otherwise fails with:
#   P00 ERROR: [037]: restore command requires option: repo2-cipher-pass
# Fetching the non-target cipher pass is optional so single-repo deployments
# (where only one secret file exists) still work.
# ────────────────────────────────────────────────────────────────────────────
echo "==> Fetching secrets for repo${REPO} ..."
fetch_secret "pgbackrest_cipher_pass_repo${REPO}" "${TMPDIR_SECRETS}/cipher_pass_repo${REPO}"
fetch_secret "pgbackrest_id_ed25519_repo${REPO}"  "${TMPDIR_SECRETS}/id_ed25519"
fetch_secret "pgbackrest_known_hosts_repo${REPO}" "${TMPDIR_SECRETS}/known_hosts"
chmod 600 "${TMPDIR_SECRETS}/id_ed25519"

# Optional cipher pass for the other repo — needed only when the conf declares it.
for _other_repo in 1 2; do
  [[ "${_other_repo}" == "${REPO}" ]] && continue
  if fetch_secret_optional "pgbackrest_cipher_pass_repo${_other_repo}" \
        "${TMPDIR_SECRETS}/cipher_pass_repo${_other_repo}"; then
    echo "==> Also fetched cipher pass for repo${_other_repo} (required for combined-conf validation)"
  fi
done

# Build the -e flags for every cipher pass present so pgbackrest invocations see
# them. Bash array preserves quoting correctly across `docker exec`.
PGBACKREST_ENV=()
for _r in 1 2; do
  if [[ -s "${TMPDIR_SECRETS}/cipher_pass_repo${_r}" ]]; then
    PGBACKREST_ENV+=( -e "PGBACKREST_REPO${_r}_CIPHER_PASS=$(cat "${TMPDIR_SECRETS}/cipher_pass_repo${_r}")" )
  fi
done

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
#
# WHY anonymous Docker volume for /restore/pgdata (no -v <host>:<container>):
# Host bind-mounts of $TMPDIR paths fail silently on rootless Docker, Docker
# Desktop, and snap-packaged Docker setups — the daemon cannot see paths under
# the calling user's private /tmp namespace, so the in-container directory is
# empty even though the host directory contains the expected files. An
# anonymous volume is managed entirely by the Docker daemon and is reliable
# across all setups; `docker rm -fv` (set in the EXIT trap above) tears it
# down with the container.
#
# WHY no -v for /secrets: same reason. Secrets are injected with `docker cp`
# after the container is up (see next block).
docker run -d \
  --name "${CONTAINER_NAME}" \
  --entrypoint /bin/sleep \
  -v "/restore/pgdata" \
  "${DOCKER_IMAGE}" \
  infinity

# Inject secrets into the container with `docker cp` rather than a bind mount.
# /secrets is created inside the container's writable layer (anonymous volume
# not needed — the path is gone when the container is removed). The id_ed25519
# key file is chmod 0600 to satisfy SSH client strictness.
echo "==> Installing secrets in verify container ..."
docker exec "${CONTAINER_NAME}" mkdir -p /secrets
docker cp "${TMPDIR_SECRETS}/id_ed25519"  "${CONTAINER_NAME}:/secrets/id_ed25519"
docker cp "${TMPDIR_SECRETS}/known_hosts" "${CONTAINER_NAME}:/secrets/known_hosts"
docker exec "${CONTAINER_NAME}" chmod 0600 /secrets/id_ed25519
docker exec "${CONTAINER_NAME}" chmod 0644 /secrets/known_hosts
# WHY chown to postgres (uid 70 on Alpine): pgbackrest archive-get is spawned by
# the PostgreSQL backend during WAL replay (postgresql.auto.conf's restore_command),
# so it runs as the postgres user — not as root like the initial restore command.
# Without this, docker cp lands files as the host invoker's uid (often 1000:1000)
# and the postgres process gets EACCES on the key file. The failure mode is silent:
# libssh2 reports "public key authentication failed [-16]" and PG falls through to
# "consistent recovery state reached" using only the WAL embedded in the backup,
# producing a green PASS that masks a broken WAL-replay path. Aligns with the
# pgbackrest.conf comment "pgbackrest opens them directly as postgres UID".
docker exec "${CONTAINER_NAME}" chown 70:70 /secrets/id_ed25519 /secrets/known_hosts

# ────────────────────────────────────────────────────────────────────────────
# Install pgBackRest inside the verify container
#
# WHY apk + edge community pin: timescale/timescaledb:latest-pg18 is an Alpine
# image, so apk is the only package manager available. The Alpine stable repos
# ship pgbackrest 2.57.0-r0, but the addon container is built against
# pgbackrest 2.58.0-r0 from alpine:edge community (see timescaledb/Dockerfile).
# Restoring a 2.58-produced backup with a 2.57 client is not guaranteed to be
# safe, so this script pins the exact same version + repo as the addon. If the
# edge community repo no longer carries 2.58.0-r0, this install fails fast with
# a clear error rather than silently degrading to 2.57.0-r0.
# ────────────────────────────────────────────────────────────────────────────
PGBACKREST_PIN="2.58.0-r0"
PGBACKREST_REPO_URL="https://dl-cdn.alpinelinux.org/alpine/edge/community"
echo "==> Installing pgBackRest ${PGBACKREST_PIN} in verify container ..."
docker exec "${CONTAINER_NAME}" sh -c \
  "apk add --no-cache --repository ${PGBACKREST_REPO_URL} 'pgbackrest=${PGBACKREST_PIN}'"

# ────────────────────────────────────────────────────────────────────────────
# Copy pgbackrest.conf into the verify container and patch it
# ────────────────────────────────────────────────────────────────────────────
echo "==> Configuring pgbackrest.conf in verify container ..."
docker exec "${CONTAINER_NAME}" mkdir -p /etc/pgbackrest
docker cp "${TMPDIR_SECRETS}/pgbackrest.conf" "${CONTAINER_NAME}:/etc/pgbackrest/pgbackrest.conf"

# Point pg1-path to the restore volume mount inside this container
docker exec "${CONTAINER_NAME}" bash -c \
  "sed -i 's|pg1-path=.*|pg1-path=/restore/pgdata|' /etc/pgbackrest/pgbackrest.conf"

# Override SSH key + known_hosts paths for EVERY repo, not just the target.
#
# WHY rewrite every repo: pgbackrest parses the entire conf on each invocation
# and validates SSH paths for all configured sftp repos, even when only
# --repo=N is targeted. Leaving repo<other>-sftp-private-key-file pointing at
# the addon container's /data/secrets/... path (which does not exist in the
# verify container) causes "known hosts failure" or "key file not found"
# during --repo=N restore.
#
# WHY same key for every repo: the verify container only carries the target
# repo's key and known_hosts (one set fetched into /secrets). pgbackrest only
# opens an SSH session for the targeted repo during restore, so reusing the
# target's key file string for the other repo's path is harmless — pgbackrest
# never actually authenticates with it on a single-repo restore.
#
# WHY this option name is 'sftp-known-host' (singular, no '-file'): that is
# the canonical pgBackRest 2.5x option key. An earlier 'sftp-known-hosts-file'
# substitution silently failed to match anything in the conf, leaving the
# default path in place and producing LIBSSH2_KNOWNHOST_CHECK_NOTFOUND.
docker exec "${CONTAINER_NAME}" sh -c \
  "sed -i -E \
     -e 's|^(repo[0-9]+)-sftp-private-key-file=.*|\\1-sftp-private-key-file=/secrets/id_ed25519|' \
     -e 's|^(repo[0-9]+)-sftp-known-host=.*|\\1-sftp-known-host=/secrets/known_hosts|' \
     /etc/pgbackrest/pgbackrest.conf"

# Embed each repo's cipher-pass directly into pgbackrest.conf so child
# processes spawned by PostgreSQL during recovery — specifically the
# restore_command -> 'pgbackrest archive-get' that pulls WAL segments — can
# decrypt the repo without inheriting env vars from the verify driver.
#
# WHY env vars alone are not enough: the script invokes pgbackrest via
# 'docker exec -e PGBACKREST_REPOn_CIPHER_PASS=...', so the env reaches
# pgbackrest's restore command. But after restore, pg_ctl starts PostgreSQL
# in a new process tree; PG then forks pgbackrest from postgresql.auto.conf's
# restore_command without those env vars set. Repo2 verifies surfaced this:
# repo2 has no WAL archive of its own, so recovery must pull WAL from
# repo1's archive, and the embedded archive-get failed with:
#   P00 ERROR: [037]: archive-get command requires option: repo1-cipher-pass
#
# WHY stdin (printf | tee -a) instead of a 'sh -c "echo ... >> ..."' wrapper:
# the cipher pass would otherwise appear on the docker exec process argv and
# be visible to anyone running 'ps' on the host. Piping through stdin keeps
# the secret out of process tables. The verify cluster is throwaway, but
# good hygiene costs nothing here.
for _r in 1 2; do
  if [[ -s "${TMPDIR_SECRETS}/cipher_pass_repo${_r}" ]]; then
    printf 'repo%d-cipher-pass=%s\n' "${_r}" "$(cat "${TMPDIR_SECRETS}/cipher_pass_repo${_r}")" \
      | docker exec -i "${CONTAINER_NAME}" tee -a /etc/pgbackrest/pgbackrest.conf > /dev/null
  fi
done

# The /secrets volume is mounted :ro; chmod was applied on the host side
# (chmod 600 on id_ed25519) before the container mount took effect.

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

# Enable file logging for archive-get in the verify container.
#
# WHY: PG-spawned archive-get only writes its INFO/ERROR lines to PG's stderr
# (which gets interleaved into the script's console). If a single archive-get
# fails (e.g. transient libssh2 / Hetzner SFTP error), PG treats exit code 1
# as "no more WAL" and promotes immediately — without making the underlying
# error easy to find in the console flood. log-level-file=detail captures
# every archive-get attempt to /tmp/pgbackrest-logs/<stanza>-archive-get.log
# inside the verify container, so post-mortem inspection (--keep) can pinpoint
# which segment failed and why.
docker exec "${CONTAINER_NAME}" bash -c \
  "sed -i 's|^log-level-file=.*|log-level-file=detail|' /etc/pgbackrest/pgbackrest.conf; \
   if ! grep -q '^log-level-file=' /etc/pgbackrest/pgbackrest.conf; then \
     echo 'log-level-file=detail' >> /etc/pgbackrest/pgbackrest.conf; \
   fi; \
   chown postgres:postgres /tmp/pgbackrest-logs"

# ────────────────────────────────────────────────────────────────────────────
# Fetch backup info BEFORE restore to get the backup stop timestamp
#
# Primary freshness check (review finding): max(last_updated) in the states table
# is NOT the same as backup freshness. If no HA state changed recently, a valid and
# current backup would fail a max(last_updated) check. The pgBackRest backup stop timestamp
# (.backup[].timestamp.stop in the info JSON) is the authoritative signal.
# ────────────────────────────────────────────────────────────────────────────
echo "==> Fetching backup info for repo${REPO} ..."
_info_json=$(docker exec \
  "${PGBACKREST_ENV[@]}" \
  "${CONTAINER_NAME}" \
  pgbackrest --stanza=timescaledb "--repo=${REPO}" info --output=json 2>/dev/null \
  || echo '[]')

# Extract stop timestamp of the most recent backup for this repo.
# .backup[] entries carry timestamps; we select by database.repo-key matching REPO.
# WHY || echo "0" fallback: when _info_json is '[]' (empty stanza — no backups have run
# yet, or the repo was never initialized), jq evaluates 'null | map(...)' and exits with
# "Cannot iterate over null" (exit code 5). Under set -euo pipefail this aborts the
# script before the freshness check runs. The fallback produces "0" so the explicit
# _backup_stop==0 guard below can report a clear FAIL instead of a crash.
_backup_stop=$(printf '%s' "${_info_json}" | jq -r \
  ".[0].backup | map(select(.database.\"repo-key\" == ${REPO})) | last | .timestamp.stop // 0" \
  2>/dev/null || echo "0")

# ────────────────────────────────────────────────────────────────────────────
# Run pgbackrest restore into the stopped PGDATA
# ────────────────────────────────────────────────────────────────────────────
echo "==> Restoring repo${REPO} backup to /restore/pgdata ..."
#
# WHY --type differs per repo:
#
# repo1 — default recovery (no --type flag). repo1 holds rolling fulls + diffs
#   + WAL archive, so the restored cluster can and SHOULD replay WAL forward
#   to the latest archived segment. This exercises the archive-pull path end
#   to end (archive_command -> pgbackrest archive-get -> WAL fetch -> redo)
#   and is what an actual disaster recovery would do. The verify container's
#   pgbackrest is invoked under PGBACKREST_REPO[12]_CIPHER_PASS env vars so
#   archive-get succeeds.
#
# repo2 — --type=immediate. repo2 is annual fulls only; there is no WAL
#   archive for PG to fetch beyond the base backup, so a default-mode restore
#   would loop in archive-get and FATAL with 'could not locate required
#   checkpoint record'. Stopping recovery at backup-end is the correct
#   semantic for a yearly-archive repo. Row count + max(last_updated) still
#   verify the physical backup is intact.
_RESTORE_TYPE_FLAGS=()
if [[ "${REPO}" == "2" ]]; then
  _RESTORE_TYPE_FLAGS=( --type=immediate )
fi
docker exec \
  "${PGBACKREST_ENV[@]}" \
  "${CONTAINER_NAME}" \
  pgbackrest --stanza=timescaledb "--repo=${REPO}" \
    restore --pg1-path=/restore/pgdata "${_RESTORE_TYPE_FLAGS[@]}"

# ────────────────────────────────────────────────────────────────────────────
# Install a retry wrapper around pgbackrest archive-get and rewrite the
# restored cluster's restore_command to use it (repo1 only).
#
# PROBLEM: PostgreSQL's restore_command contract is binary — exit 0 means
# "segment delivered (or unambiguously absent, with no file written)", any
# non-zero exit means "I have no idea what's going on, treat as end of
# archive and promote". pgbackrest has no internal retry on transient SSH /
# libssh2 / Hetzner storage-box hiccups: one connection blip → exit 1 → PG
# promotes prematurely at the last successfully replayed segment, leaving
# the restored cluster minutes-to-hours behind even when later WAL is
# perfectly available in the archive.
#
# OBSERVED: in a verify-restore run with E7-F5 all present in repo1's
# archive, recovery stopped at LSN 29/F0FFF428 (mid-segment F0). F1-F5 were
# fetchable manually 30s later. The diagnostic signal — which segment
# failed and why — was lost because PG's restore_command stderr is no
# longer attached to docker exec after pg_ctl returns, and pgbackrest
# archive-get does not write its own log file in that invocation.
#
# FIX: shim restore_command with a tiny shell wrapper that retries 5 times
# (linear backoff 3/6/9/12/15s = 45s worst case) on non-zero exit before
# truly giving up. pgbackrest returns exit 0 for the "segment legitimately
# not in archive" case (writing nothing to %p), so the wrapper does not
# interfere with end-of-archive detection — only with transient failures.
# ────────────────────────────────────────────────────────────────────────────
if [[ "${REPO}" == "1" ]]; then
  echo "==> Installing archive-get retry wrapper and rewriting restore_command ..."
  docker exec -i "${CONTAINER_NAME}" tee /usr/local/bin/pgbackrest-archive-get-retry >/dev/null <<'WRAPPER'
#!/bin/sh
# Retry pgbackrest archive-get on transient errors (libssh2, Hetzner SFTP).
#
# pgbackrest archive-get exit codes:
#   0     = WAL segment fetched into %p
#   1     = WAL segment legitimately not in the archive (end of archive,
#           timeline-history probe). PG interprets exit 1 as "no more WAL"
#           and promotes — exactly what we want for this case.
#   other = real error (SSH/libssh2, repo unreachable, decryption, etc).
#           PG also treats this as "promote", but here a transient blip
#           causes premature promotion. Retry these.
#
# Without this wrapper, a single transient SSH error during recovery
# promotes the restored cluster minutes-to-hours behind live, making the
# recovery-lag check fail. Observed at least once on Hetzner storage-box
# SFTP: F1 fetch transient-failed, recovery promoted at F0, restored
# max(last_updated) ended up 2h+ behind live.
seg="$1"; dst="$2"
log=/tmp/pgbackrest-logs/archive-get-retry.log
mkdir -p "$(dirname "$log")" 2>/dev/null
for attempt in 1 2 3 4 5; do
  pgbackrest --pg1-path=/restore/pgdata --repo=1 --stanza=timescaledb \
    archive-get "$seg" "$dst"
  rc=$?
  case "$rc" in
    0)
      [ "$attempt" -gt 1 ] && echo "$(date -Iseconds) seg=$seg attempt=$attempt OK after retry" >> "$log"
      exit 0
      ;;
    1)
      # Legitimately missing — let PG handle (it will promote if appropriate).
      # Log only on first attempt to keep the log compact.
      [ "$attempt" -eq 1 ] && echo "$(date -Iseconds) seg=$seg rc=1 (not in archive) — passing through" >> "$log"
      exit 1
      ;;
    *)
      echo "$(date -Iseconds) seg=$seg attempt=$attempt rc=$rc — retrying" >> "$log"
      sleep "$(( attempt * 3 ))"
      ;;
  esac
done
echo "$(date -Iseconds) seg=$seg gave up after 5 attempts" >> "$log"
exit 1
WRAPPER
  docker exec "${CONTAINER_NAME}" chmod 0755 /usr/local/bin/pgbackrest-archive-get-retry
  docker exec "${CONTAINER_NAME}" sed -i \
    "s|^restore_command = .*|restore_command = '/usr/local/bin/pgbackrest-archive-get-retry %f \"%p\"'|" \
    /restore/pgdata/postgresql.auto.conf
fi

# ────────────────────────────────────────────────────────────────────────────
# Start PostgreSQL explicitly after restore completes
#
# WHY explicit start: the container was started with 'sleep infinity' as entrypoint
# so PostgreSQL did not auto-start. PG must not be running during restore (it writes
# to PGDATA). Now that restore is complete, start it explicitly.
#
# WHY -l /tmp/pg.log: pg_ctl detaches from this shell after the daemon reaches
# "ready to accept connections"; without -l, postgres's stderr — including all
# restore_command output during ongoing archive recovery — is lost. Routing it
# to a file makes the per-segment archive-get trace inspectable after the run
# (especially under --keep).
# ────────────────────────────────────────────────────────────────────────────
echo "==> Starting PostgreSQL in verify container ..."
docker exec "${CONTAINER_NAME}" bash -c \
  "chown -R postgres:postgres /restore/pgdata && \
   gosu postgres pg_ctl start -D /restore/pgdata -o '-k /tmp --port=5433' -w -t 180 -l /tmp/pg.log"

# ────────────────────────────────────────────────────────────────────────────
# Wait for archive recovery to complete (repo1 only)
#
# WHY: `pg_ctl start -w` returns when PG is "ready to accept connections", which
# happens at the "consistent recovery state reached" point — i.e. as soon as
# the base backup is consistent. Archive recovery (replaying WAL segments via
# restore_command -> pgbackrest archive-get) continues in the background after
# that. Querying max(last_updated) before recovery finishes produces a value
# frozen at backup-stop time even though replay is actively catching up,
# yielding a false-FAIL on the recovery-lag check.
#
# `pg_is_in_recovery()` returns true while WAL is still being replayed and
# flips to false once PG exhausts the archive and promotes to read-write.
# That promotion happens when archive-get returns an error for the next WAL
# segment (signal: no more segments available).
#
# Timeout: archive_timeout default 3600s means the live cluster only forces a
# WAL switch hourly. The most recent segment may genuinely not be archived yet.
# 300s of WAL fetching + promote is generous; on slow networks or large diffs,
# bump via --recovery-wait-timeout.
# ────────────────────────────────────────────────────────────────────────────
if [[ "${REPO}" == "1" ]]; then
  echo "==> Waiting for archive recovery to complete (pg_is_in_recovery() -> false) ..."
  _rec_deadline=$(( SECONDS + RECOVERY_WAIT_TIMEOUT ))
  _rec_done=false
  while (( SECONDS < _rec_deadline )); do
    _in_rec=$(docker exec "${CONTAINER_NAME}" bash -c \
      "gosu postgres psql -h /tmp -p 5433 -U postgres -d homeassistant -tAc \
      'SELECT pg_is_in_recovery()'" 2>/dev/null || echo "")
    if [[ "${_in_rec}" == "f" ]]; then
      _rec_done=true
      break
    fi
    sleep 2
  done
  if [[ "${_rec_done}" != "true" ]]; then
    echo "WARN: archive recovery did not finish within ${RECOVERY_WAIT_TIMEOUT}s — proceeding anyway"
    echo "      (lag check will likely FAIL; see --recovery-wait-timeout)"
  else
    echo "Archive recovery complete; cluster promoted to read-write."
  fi
fi

# ────────────────────────────────────────────────────────────────────────────
# Verify step 1 — Backup file age: pgBackRest backup stop timestamp must be
# within the daily-backup window (proves the scheduled backup ran recently),
# NOT a recovery-quality signal — that is the recovery-lag check below.
# ────────────────────────────────────────────────────────────────────────────
_freshness_ok=true
_rowcount_ok=true
_lag_ok=true

_now=$(date +%s)
if [[ "$REPO" == "1" ]]; then
  _max_age=90000    # 25 hours for repo1 (daily backup schedule, BKUP-06)
else
  _max_age=31536000 # 1 year for repo2 (annual backup schedule, BKUP-06)
fi

_age=$(( _now - _backup_stop ))
echo "Backup stop timestamp: ${_backup_stop} (${_age}s ago, limit: ${_max_age}s)"
# _backup_stop==0 means jq found no backup entries (empty or uninitialized stanza).
# Handle this explicitly before the arithmetic comparison: comparing 0 against the
# freshness window would always produce a misleading "N seconds ago" message rather
# than surfacing the real problem (no backups exist for this repo).
if [[ "$_backup_stop" == "0" ]]; then
  echo "FAIL: no backup found for repo${REPO} (stanza empty or not initialized)"
  _freshness_ok=false
elif [[ "$_backup_stop" -gt "$(( _now - _max_age ))" ]]; then
  echo "PASS: backup file age (stop_time within allowed window for repo${REPO})"
else
  echo "FAIL: backup stop_time is ${_age}s ago, exceeds ${_max_age}s limit for repo${REPO}"
  _freshness_ok=false
fi

# ────────────────────────────────────────────────────────────────────────────
# Verify step 2 — Secondary data sanity: max(last_updated) from restored DB
#
# WHY 'last_updated' and not 'time': Home Assistant's recorder schema names the
# event-time column 'last_updated' on the states hypertable; 'time' is also a
# PostgreSQL reserved word, so a bare unquoted 'time' would fail to parse even
# if the column existed. The TimescaleDB hypertable is partitioned by
# last_updated (see ha_states_last_updated_idx).
#
# WHY secondary: max(last_updated) can appear stale if no HA entity changed
# state recently, even with a fresh and valid backup. Logged for visibility;
# not a failure gate alone.
# ────────────────────────────────────────────────────────────────────────────
_restored_max=$(docker exec "${CONTAINER_NAME}" bash -c \
  "gosu postgres psql -h /tmp -p 5433 -U postgres -d homeassistant -tAc \
  'SELECT max(last_updated) FROM states'" 2>/dev/null \
  || echo "NULL")
echo "Restored DB max(last_updated): ${_restored_max}"

# ────────────────────────────────────────────────────────────────────────────
# Verify step 3 — Recovery lag (repo1 only): proves WAL replay actually ran
#
# WHY this exists separately from the row-count check: the row-count comparison
# below filters the live DB with last_updated <= restored_max, which makes the
# match trivially true even when restored_max sits at the backup-stop timestamp
# (i.e. when archive-get failed and no WAL got replayed). A real DR exercise
# must end with the restored cluster catching up close to "now", not just being
# internally consistent at backup time. This step is the only gate that
# distinguishes "WAL replay path works" from "WAL replay path silently broken".
#
# WHY repo1 only: repo2 is restored with --type=immediate (annual fulls, no WAL
# archive of its own), so restored_max will sit at or near the most recent yearly
# backup — possibly months behind live. That is correct for a yearly-archive
# repo and not a failure of WAL replay.
# ────────────────────────────────────────────────────────────────────────────
if [[ "$REPO" == "1" && -n "${CONTAINER}" ]]; then
  echo "==> Checking recovery lag (restored vs live max(last_updated)) ..."
  _live_max_unfiltered=$(ssh "$HA_SSH" "docker exec ${CONTAINER} psql -h /tmp -U postgres \
    -d homeassistant -tAc 'SELECT max(last_updated) FROM states'" 2>/dev/null || echo "")
  if [[ -z "$_live_max_unfiltered" || "$_restored_max" == "NULL" || -z "$_restored_max" ]]; then
    echo "FAIL: cannot compute recovery lag"
    echo "  live max(last_updated):     '${_live_max_unfiltered}'"
    echo "  restored max(last_updated): '${_restored_max}'"
    _lag_ok=false
  else
    _live_epoch=$(date -d "$_live_max_unfiltered" +%s 2>/dev/null || echo "")
    _restored_epoch=$(date -d "$_restored_max" +%s 2>/dev/null || echo "")
    if [[ -z "$_live_epoch" || -z "$_restored_epoch" ]]; then
      echo "FAIL: could not parse timestamps for lag calculation"
      echo "  live='${_live_max_unfiltered}' restored='${_restored_max}'"
      _lag_ok=false
    else
      _lag=$(( _live_epoch - _restored_epoch ))
      echo "Recovery lag: ${_lag}s (live=${_live_max_unfiltered}, restored=${_restored_max}, threshold=${MAX_RECOVERY_LAG}s)"
      if [[ "$_lag" -le "$MAX_RECOVERY_LAG" ]]; then
        echo "PASS: recovery lag within threshold — WAL replay reached near-current state"
      else
        echo "FAIL: recovery lag ${_lag}s exceeds ${MAX_RECOVERY_LAG}s"
        echo "  HINT: archive-get likely failed during PG startup, so recovery stopped at"
        echo "        the backup stop point instead of catching up via WAL replay."
        echo "        Check the restore output above for libssh2 / 'unable to find a valid"
        echo "        repository' errors. Common cause: /secrets/* not readable by the"
        echo "        postgres uid inside the verify container."
        _lag_ok=false
      fi
    fi
  fi
elif [[ "$REPO" == "2" ]]; then
  echo "INFO: skipping recovery-lag check for repo2 (yearly archival, --type=immediate, no WAL replay expected)"
fi

# ────────────────────────────────────────────────────────────────────────────
# Verify step 4 — Exact row count match (requires live Pi via ssh)
# Skipped in offline mode (when live container is unavailable).
#
# WHY explicit empty-result fail: $(docker exec ... psql ...) captures stdout
# only. When psql errors, stderr is shown to the operator but the variable
# silently receives "". An earlier version of this block then compared "" == ""
# and reported a false PASS. The non-empty guards below abort with FAIL if
# either side's query returned no rows.
# ────────────────────────────────────────────────────────────────────────────
if [[ -n "${CONTAINER}" ]]; then
  echo "==> Comparing row counts between restored and live DB ..."
  _restored_counts=$(docker exec "${CONTAINER_NAME}" bash -c \
    "gosu postgres psql -h /tmp -p 5433 -U postgres -d homeassistant -tAc \
    'SELECT count(*) || chr(9) || max(last_updated) || chr(9) || min(last_updated) FROM states'")
  _cnt_r=$(printf '%s' "$_restored_counts" | cut -f1)
  _max_r=$(printf '%s' "$_restored_counts" | cut -f2)
  _min_r=$(printf '%s' "$_restored_counts" | cut -f3)

  if [[ -z "$_cnt_r" || -z "$_max_r" || -z "$_min_r" ]]; then
    echo "FAIL: restored DB row count query returned empty result"
    echo "  Raw response: '${_restored_counts}'"
    _rowcount_ok=false
  else
    # Query live DB with last_updated <= restored max to get a comparable slice.
    _live_counts=$(ssh "$HA_SSH" "docker exec ${CONTAINER} psql -h /tmp -U postgres \
      -d homeassistant -tAc \
      \"SELECT count(*) || chr(9) || max(last_updated) || chr(9) || min(last_updated) FROM states WHERE last_updated <= '${_max_r}'\"")
    _cnt_l=$(printf '%s' "$_live_counts" | cut -f1)
    _max_l=$(printf '%s' "$_live_counts" | cut -f2)
    _min_l=$(printf '%s' "$_live_counts" | cut -f3)

    if [[ -z "$_cnt_l" || -z "$_max_l" || -z "$_min_l" ]]; then
      echo "FAIL: live DB row count query returned empty result"
      echo "  Raw response: '${_live_counts}'"
      _rowcount_ok=false
    elif [[ "$_cnt_r" == "$_cnt_l" && "$_max_r" == "$_max_l" && "$_min_r" == "$_min_l" ]]; then
      echo "PASS: row count exact match (restored=${_cnt_r} rows, live=${_cnt_l} rows)"
    else
      echo "FAIL: row count mismatch"
      echo "  Restored: count=${_cnt_r}, max=${_max_r}, min=${_min_r}"
      echo "  Live:     count=${_cnt_l}, max=${_max_l}, min=${_min_l}"
      _rowcount_ok=false
    fi
  fi
else
  echo "INFO: live container unavailable (offline mode) — skipping exact row count match"
fi

# ────────────────────────────────────────────────────────────────────────────
# Shutdown the restore PG and report summary
#
# With --keep, leave PostgreSQL running so the operator can connect to the
# restored database via `docker exec ... psql`. The trap is disarmed below.
# ────────────────────────────────────────────────────────────────────────────
if [[ "${KEEP}" -eq 0 ]]; then
  docker exec "${CONTAINER_NAME}" bash -c \
    "gosu postgres pg_ctl stop -D /restore/pgdata -m fast" 2>/dev/null || true
fi

echo ""
echo "==> Verify complete"
_result_failed=false
if [[ "${_freshness_ok}" == "false" || "${_rowcount_ok}" == "false" || "${_lag_ok}" == "false" ]]; then
  echo "RESULT: FAILED"
  _result_failed=true
else
  echo "RESULT: PASSED"
fi

# ────────────────────────────────────────────────────────────────────────────
# --keep post-run (success OR failure): disarm trap, leave container + PG
# running so the operator can inspect /tmp/pgbackrest-logs, /restore/pgdata,
# and the running DB.
#
# WHY also on failure: archive-get failures during WAL replay are the most
# common cause of a FAILED verdict. The diagnostic data (per-segment archive-get
# log lines, restored pg_wal/ contents, postgresql.auto.conf recovery options)
# only exists inside the verify container — tearing it down on FAIL leaves the
# operator nothing to debug from. Without --keep the default trap still tears
# the container down on FAIL, so this only affects explicit-keep runs.
# ────────────────────────────────────────────────────────────────────────────
if [[ "${KEEP}" -eq 1 ]]; then
  rm -rf "$TMPDIR_SECRETS"
  trap - EXIT

  # Open the restored PG to TCP from outside the container so GUI clients
  # (DBeaver, DataGrip, psql on the host) can connect. The verify cluster is a
  # throwaway, so trust-auth from any source is acceptable — it never touches
  # the live HA database. Failures here are warnings, not fatal: the operator
  # can still use `docker exec ... psql` via the local socket.
  _tcp_ok=true
  if ! docker exec "${CONTAINER_NAME}" gosu postgres psql -h /tmp -p 5433 -d postgres -c \
       "ALTER SYSTEM SET listen_addresses='*';" >/dev/null 2>&1; then
    _tcp_ok=false
  fi
  if ! docker exec "${CONTAINER_NAME}" sh -c \
       "grep -q '^host all all 0.0.0.0/0 trust' /restore/pgdata/pg_hba.conf \
        || echo 'host all all 0.0.0.0/0 trust' >> /restore/pgdata/pg_hba.conf"; then
    _tcp_ok=false
  fi
  # Reload to pick up pg_hba.conf change (listen_addresses needs full restart
  # via pg_ctl, not just reload).
  docker exec "${CONTAINER_NAME}" gosu postgres psql -h /tmp -p 5433 -d postgres -c \
    "SELECT pg_reload_conf();" >/dev/null 2>&1 || true
  docker exec "${CONTAINER_NAME}" bash -c \
    "gosu postgres pg_ctl restart -D /restore/pgdata -o '-k /tmp --port=5433' -w -t 60" \
    >/dev/null 2>&1 || _tcp_ok=false

  # Resolve container IP on the default bridge so the host can reach 5433
  # directly. Falls back to '<container-ip>' placeholder if inspection fails.
  CTR_IP=$(docker inspect "${CONTAINER_NAME}" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null \
    || echo "<container-ip>")

  cat <<EOF

──────────────────────────────────────────────────────────────────────
--keep enabled: verify container left running for inspection.

Container : ${CONTAINER_NAME}
Database  : homeassistant
User      : postgres (no password — throwaway cluster, trust auth)

Inspect with docker-exec psql (no networking required):
  docker exec -it ${CONTAINER_NAME} gosu postgres psql -h /tmp -p 5433 -d homeassistant

Run a one-shot query:
  docker exec ${CONTAINER_NAME} gosu postgres psql -h /tmp -p 5433 -d homeassistant -c 'SELECT count(*) FROM states;'

Connect a GUI client (DBeaver, DataGrip, psql) from the same host as
docker (Linux: works out of the box; Docker Desktop on macOS/Windows:
see note below):
  Host     : ${CTR_IP}
  Port     : 5433
  Database : homeassistant
  User     : postgres
  Password : (leave empty)

Or run psql from the host:
  psql -h ${CTR_IP} -p 5433 -U postgres -d homeassistant

Docker Desktop note: the container IP above is on a Docker-internal
bridge that the host kernel cannot route to directly. Either run a
short-lived publisher sidecar:
  docker run -d --rm --name pg-pub --network container:${CONTAINER_NAME} \\
    -p 15433:5433 alpine/socat \\
    tcp-listen:5433,fork,reuseaddr tcp:127.0.0.1:5433
then point your client at localhost:15433; or skip the GUI and use
docker exec.

Stop and remove when done (the -v flag also reclaims the anonymous
/restore/pgdata volume):
  docker container rm -fv ${CONTAINER_NAME}
──────────────────────────────────────────────────────────────────────
EOF
  if [[ "${_tcp_ok}" == "false" ]]; then
    echo "WARNING: TCP listener could not be enabled — only docker-exec psql will work."
  fi
fi

# Final exit code reflects the verdict regardless of --keep, so callers (CI,
# wrappers) still see FAIL=1 / PASS=0 when --keep leaves the container behind.
if [[ "${_result_failed}" == "true" ]]; then
  exit 1
fi

#!/command/with-contenv bashio
set -euo pipefail

PGDATA="/data/postgres"
SECRETS_DIR="/data/secrets"
DB_NAME=$(bashio::config 'database')

mkdir -p "${SECRETS_DIR}"

# Generate a random password, or use the configured one if set.
# Stores the effective password in SECRETS_DIR for retrieval.
# Usage: ensure_password <role_name> <config_key>
ensure_password() {
    local role="$1"
    local config_key="$2"
    local secret_file="${SECRETS_DIR}/${role}_password"
    local configured_pw

    configured_pw=$(bashio::config "${config_key}")

    if [ -n "${configured_pw}" ]; then
        echo "${configured_pw}" > "${secret_file}"
    elif [ ! -f "${secret_file}" ]; then
        head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 32 > "${secret_file}"
        bashio::log.info "Generated password for '${role}' — stored in ${secret_file}"
    fi

    chmod 600 "${secret_file}"
    cat "${secret_file}"
}

# Auto-generate a per-repo pgBackRest cipher passphrase if not already present.
# Idempotent: once written the file is NEVER overwritten (cipher immutability after stanza-create).
# The passphrase is NOT echoed to stdout — callers read the file directly at pgbackrest invocation time.
# Usage: ensure_cipher_passphrase <repo_id>   (repo_id ∈ repo1 | repo2)
ensure_cipher_passphrase() {
    local repo_id="$1"
    local pass_file="${SECRETS_DIR}/pgbackrest_cipher_pass_${repo_id}"

    if [ ! -s "${pass_file}" ]; then
        head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 32 > "${pass_file}"
        # Log warning (not info) so it stands out — loss of this passphrase = permanent backup loss
        bashio::log.warning "Generated pgBackRest cipher passphrase for ${repo_id} — copy ${pass_file} to a password manager immediately (loss = permanent backup loss)"
    fi
    chmod 600 "${pass_file}"
    chown postgres:postgres "${pass_file}"
}

# Send a persistent notification to Home Assistant via the supervisor API.
# Requires SUPERVISOR_TOKEN env var (auto-provided by HAOS to apps).
# Non-fatal: on any failure (missing token, network error) logs a warning and returns 0.
# Usage: notify_supervisor <title> <message>
notify_supervisor() {
    local title="$1"
    local message="$2"

    if [ -z "${SUPERVISOR_TOKEN:-}" ]; then
        bashio::log.warning "pgBackRest: ${title} (SUPERVISOR_TOKEN unavailable — notification not sent)"
        return 0
    fi

    local payload
    payload=$(jq -nc --arg title "${title}" --arg message "${message}" '{title: $title, message: $message}')

    # SUPERVISOR_TOKEN goes in the Authorization header only — NEVER in URL or log output
    if ! curl -fsS --max-time 10 \
        -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -d "${payload}" \
        http://supervisor/core/api/services/persistent_notification/create 2>/dev/null; then
        bashio::log.warning "pgBackRest: failed to send notification '${title}' via supervisor API"
    fi
    return 0
}

# Classify a pgbackrest exit code + stderr as "transient" or "non-transient".
# Non-transient errors must not be retried — they require manual intervention (wrong key, cipher mismatch).
# Transient errors (network timeouts, temporary DNS failures) are safe to retry.
# Defaults to "non-transient" when the error cannot be classified — safety-first.
# Usage: classify_pgbackrest_error <exit_code> [stderr_file]
# Output: echoes "transient" or "non-transient"
classify_pgbackrest_error() {
    local exit_code="$1"
    local stderr_file="${2:-}"
    local stderr_content=""

    # Exit codes that are always non-transient regardless of stderr:
    #   31 = crypto/cipher error (wrong passphrase, incompatible encryption)
    #   102 = stanza mismatch (existing stanza has different configuration)
    case "${exit_code}" in
        31|102) echo "non-transient"; return ;;
    esac

    if [ -f "${stderr_file}" ]; then
        stderr_content=$(tail -c 4096 "${stderr_file}" 2>/dev/null || true)
    fi

    # Non-transient patterns: auth/permission failures, known_hosts mismatches, key problems
    if echo "${stderr_content}" | grep -qiE 'authentication|denied|permission|unknown key|not found in known_hosts|host key verification|invalid private key|cipher'; then
        echo "non-transient"
    # Transient patterns: network connectivity / temporary infrastructure problems
    elif echo "${stderr_content}" | grep -qiE 'timeout|timed out|Connection reset|Connection refused|Temporary failure|could not resolve|network is unreachable|EOF from client'; then
        echo "transient"
    else
        # Unrecognized exit code with no pattern match — default to non-transient for safety
        echo "non-transient"
    fi
}

# Ensure data directory exists and is owned by postgres
mkdir -p "${PGDATA}"
chown -R postgres:postgres "${PGDATA}"

# Initialize cluster if not exists (guard with PG_VERSION check to prevent data loss on restart)
if [ ! -f "${PGDATA}/PG_VERSION" ]; then
    bashio::log.info "Initializing PostgreSQL cluster at ${PGDATA}..."
    gosu postgres initdb \
        --pgdata="${PGDATA}" \
        --username=postgres \
        --encoding=UTF-8 \
        --locale=en_US.UTF-8 \
        --auth-local=trust \
        --auth-host=scram-sha-256
    bashio::log.info "PostgreSQL cluster initialized."
fi

# Render postgresql.conf from app options
bashio::log.info "Rendering postgresql.conf from app options..."
tempio \
    -conf /data/options.json \
    -template /etc/postgresql/postgresql.conf.tmpl \
    -out "${PGDATA}/postgresql.conf"

# Render pg_hba.conf from app options (role-based access control)
bashio::log.info "Rendering pg_hba.conf from app options..."
tempio \
    -conf /data/options.json \
    -template /etc/postgresql/pg_hba.conf.tmpl \
    -out "${PGDATA}/pg_hba.conf"

mkdir -p "${PGDATA}/log"
chown -R postgres:postgres "${PGDATA}"

# Start PostgreSQL temporarily for initialization
bashio::log.info "Starting PostgreSQL temporarily for initialization..."
gosu postgres pg_ctl -D "${PGDATA}" -w -o "-p 5432 -k /tmp" start
pg_isready --host=/tmp --username=postgres --timeout=30

# Create database if not exists
if ! psql -U postgres -h /tmp -tc "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'" | grep -q 1; then
    bashio::log.info "Creating database '${DB_NAME}'..."
    psql -U postgres -h /tmp -c "CREATE DATABASE \"${DB_NAME}\" ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8' TEMPLATE template0;"
fi

# Create TimescaleDB extension if not loaded
psql -U postgres -h /tmp -d "${DB_NAME}" -c "CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;"

# Align the extension catalog with whatever timescaledb-X.Y.Z.so the current
# image ships. CREATE EXTENSION IF NOT EXISTS leaves pg_extension.extversion
# pinned to whatever was installed when the database was first created — so
# after an image bump from e.g. 2.25.x to 2.26.x, the running database keeps
# loading the older .so until ALTER EXTENSION ... UPDATE is run. This call is
# idempotent (no-op when the catalog already matches default_version) and runs
# before any pgbackrest invocation so backups always reflect the live binary.
TS_VERSION_BEFORE=$(psql -U postgres -h /tmp -d "${DB_NAME}" -At -c \
    "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'")
psql -U postgres -h /tmp -d "${DB_NAME}" -c "ALTER EXTENSION timescaledb UPDATE;" >/dev/null
TS_VERSION_AFTER=$(psql -U postgres -h /tmp -d "${DB_NAME}" -At -c \
    "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'")
if [ "${TS_VERSION_BEFORE}" != "${TS_VERSION_AFTER}" ]; then
    bashio::log.info "TimescaleDB extension upgraded: ${TS_VERSION_BEFORE} → ${TS_VERSION_AFTER}"
else
    bashio::log.info "TimescaleDB extension at ${TS_VERSION_AFTER} (already current)."
fi

# === Role management ===

# homeassistant role — always created, owns the database
HA_PW=$(ensure_password "homeassistant" "ha_db_password")
psql -U postgres -h /tmp -d "${DB_NAME}" <<-EOSQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'homeassistant') THEN
            CREATE ROLE homeassistant LOGIN PASSWORD '${HA_PW}';
            RAISE NOTICE 'Created role homeassistant';
        ELSE
            ALTER ROLE homeassistant PASSWORD '${HA_PW}';
        END IF;
    END
    \$\$;
    ALTER DATABASE "${DB_NAME}" OWNER TO homeassistant;
    GRANT ALL PRIVILEGES ON DATABASE "${DB_NAME}" TO homeassistant;
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO homeassistant;
    GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO homeassistant;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO homeassistant;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO homeassistant;
EOSQL
bashio::log.info "Role 'homeassistant' ready."

# homeassistant_ro role — optional, SELECT only
if bashio::config.true 'enable_readonly'; then
    RO_PW=$(ensure_password "homeassistant_ro" "readonly_password")
    psql -U postgres -h /tmp -d "${DB_NAME}" <<-EOSQL
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'homeassistant_ro') THEN
                CREATE ROLE homeassistant_ro LOGIN PASSWORD '${RO_PW}';
                RAISE NOTICE 'Created role homeassistant_ro';
            ELSE
                ALTER ROLE homeassistant_ro PASSWORD '${RO_PW}';
            END IF;
        END
        \$\$;
        GRANT CONNECT ON DATABASE "${DB_NAME}" TO homeassistant_ro;
        GRANT USAGE ON SCHEMA public TO homeassistant_ro;
        GRANT SELECT ON ALL TABLES IN SCHEMA public TO homeassistant_ro;
        ALTER DEFAULT PRIVILEGES FOR ROLE homeassistant IN SCHEMA public GRANT SELECT ON TABLES TO homeassistant_ro;
EOSQL
    bashio::log.info "Role 'homeassistant_ro' ready."
fi

# homeassistant_rw role — optional, DML only (no DDL)
if bashio::config.true 'enable_readwrite'; then
    RW_PW=$(ensure_password "homeassistant_rw" "readwrite_password")
    psql -U postgres -h /tmp -d "${DB_NAME}" <<-EOSQL
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'homeassistant_rw') THEN
                CREATE ROLE homeassistant_rw LOGIN PASSWORD '${RW_PW}';
                RAISE NOTICE 'Created role homeassistant_rw';
            ELSE
                ALTER ROLE homeassistant_rw PASSWORD '${RW_PW}';
            END IF;
        END
        \$\$;
        GRANT CONNECT ON DATABASE "${DB_NAME}" TO homeassistant_rw;
        GRANT USAGE ON SCHEMA public TO homeassistant_rw;
        GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO homeassistant_rw;
        GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO homeassistant_rw;
        ALTER DEFAULT PRIVILEGES FOR ROLE homeassistant IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO homeassistant_rw;
        ALTER DEFAULT PRIVILEGES FOR ROLE homeassistant IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO homeassistant_rw;
EOSQL
    bashio::log.info "Role 'homeassistant_rw' ready."
fi

# postgres superuser — optional, just set a password
if bashio::config.true 'enable_admin'; then
    ADMIN_PW=$(ensure_password "postgres" "admin_password")
    psql -U postgres -h /tmp -c "ALTER ROLE postgres PASSWORD '${ADMIN_PW}';"
    bashio::log.info "Admin role 'postgres' password set."
fi

# Log connection info
APP_HOSTNAME=$(hostname)
HA_PW_LOG=$(cat "${SECRETS_DIR}/homeassistant_password")
bashio::log.info "---"
bashio::log.info "Connection info (copy to secrets.yaml):"
bashio::log.info "  db_url: postgresql://homeassistant:${HA_PW_LOG}@${APP_HOSTNAME}:5432/${DB_NAME}"
if bashio::config.true 'enable_readonly'; then
    RO_PW_LOG=$(cat "${SECRETS_DIR}/homeassistant_ro_password")
    bashio::log.info "  homeassistant_ro: postgresql://homeassistant_ro:${RO_PW_LOG}@${APP_HOSTNAME}:5432/${DB_NAME}"
fi
if bashio::config.true 'enable_readwrite'; then
    RW_PW_LOG=$(cat "${SECRETS_DIR}/homeassistant_rw_password")
    bashio::log.info "  homeassistant_rw: postgresql://homeassistant_rw:${RW_PW_LOG}@${APP_HOSTNAME}:5432/${DB_NAME}"
fi
if bashio::config.true 'enable_admin'; then
    ADMIN_PW_LOG=$(cat "${SECRETS_DIR}/postgres_password")
    bashio::log.info "  postgres: postgresql://postgres:${ADMIN_PW_LOG}@${APP_HOSTNAME}:5432/postgres"
fi
bashio::log.info "---"

# === pgBackRest backup provisioning ===
# Gated on backup_enabled. When false: zero pgbackrest calls, no cipher generation,
# no conf render, archive_mode=off in postgresql.conf. Exactly v1.0.x behaviour.
if bashio::config.true 'backup_enabled'; then

    # Create log/config directories; pgbackrest refuses to start without its log path
    mkdir -p /var/log/pgbackrest /etc/pgbackrest
    chown postgres:postgres /var/log/pgbackrest

    bashio::log.info "Rendering pgbackrest.conf from app options..."
    if ! tempio \
        -conf /data/options.json \
        -template /etc/pgbackrest/pgbackrest.conf.tmpl \
        -out /etc/pgbackrest/pgbackrest.conf; then
        notify_supervisor "pgBackRest config render failed" \
            "tempio failed to render pgbackrest.conf. Check that all required options are set in the app configuration."
        bashio::log.error "pgBackRest config render failed — backup disabled for this boot"
        # fall through: _backup_any_success stays false → archive_mode=off sed below handles degrade
    fi
    chown postgres:postgres /etc/pgbackrest/pgbackrest.conf 2>/dev/null || true
    chmod 640 /etc/pgbackrest/pgbackrest.conf 2>/dev/null || true

    # local is only valid inside functions; use plain vars at script top level.
    # Prefix with _ to signal these are internal to the pgbackrest block.
    _backup_any_success=false

    # Phase 1: per-repo secrets check and cipher generation.
    # stanza-create does NOT accept --repo (it operates on ALL configured repos at once),
    # so this loop only validates secrets and accumulates ready repos — stanza-create runs
    # once below after all repos are checked.
    _repos_ready=0
    for REPO_ID in repo1 repo2; do
        SFTP_HOST=$(bashio::config "${REPO_ID}_sftp_host")

        if [ -z "${SFTP_HOST}" ]; then
            bashio::log.info "pgBackRest ${REPO_ID}: sftp_host not configured — skipping"
            continue
        fi

        # Auto-generate cipher passphrase (idempotent: never overwrites an existing file)
        ensure_cipher_passphrase "${REPO_ID}"
        KEY_FILE="${SECRETS_DIR}/pgbackrest_id_ed25519_${REPO_ID}"
        KNOWN_FILE="${SECRETS_DIR}/pgbackrest_known_hosts_${REPO_ID}"

        # Verify user-provided secrets exist and are non-empty before attempting stanza-create
        _missing=""
        [ ! -s "${KEY_FILE}" ] && _missing="${_missing} ${KEY_FILE}"
        [ ! -s "${KNOWN_FILE}" ] && _missing="${_missing} ${KNOWN_FILE}"
        if [ -n "${_missing}" ]; then
            notify_supervisor "pgBackRest ${REPO_ID} secrets missing" \
                "The following files are required but missing or empty:${_missing}. See DOCS.md for provisioning steps."
            bashio::log.error "pgBackRest ${REPO_ID}: missing secrets —${_missing}"
            continue
        fi

        # Enforce 600 on user-provided files (user may have copied them with looser perms)
        chmod 600 "${KEY_FILE}" "${KNOWN_FILE}"
        chown postgres:postgres "${KEY_FILE}" "${KNOWN_FILE}"
        _repos_ready=$(( _repos_ready + 1 ))
    done

    # Phase 2: stanza-create once for all configured repos.
    # pgBackRest 2.57+ does not accept --repo on stanza-create; it always operates on all
    # repos defined in pgbackrest.conf. Both cipher passphrases are injected via env vars
    # (files may be absent for unconfigured repos — 2>/dev/null returns empty string, which
    # pgBackRest ignores for repos not present in the config).
    if [ "${_repos_ready}" -gt 0 ]; then
        if ! pg_isready --host=/tmp --username=postgres --timeout=30 >/dev/null 2>&1; then
            notify_supervisor "pgBackRest pre-check failed" \
                "PostgreSQL was not ready before stanza-create attempt. Restart the app to retry."
            bashio::log.error "pgBackRest: PG not ready — skipping stanza-create"
        else
            _stanza_ok=false
            _attempt=0
            _stderr_file=$(mktemp)
            for _delay in 0 30 120; do
                _attempt=$(( _attempt + 1 ))
                [ "${_delay}" -gt 0 ] && sleep "${_delay}"

                bashio::log.info "pgBackRest: stanza-create attempt ${_attempt}/3..."
                _exit_code=0
                # Inject all cipher passphrases; pgbackrest uses only those matching
                # repos present in the rendered pgbackrest.conf.
                env \
                    "PGBACKREST_REPO1_CIPHER_PASS=$(cat "${SECRETS_DIR}/pgbackrest_cipher_pass_repo1" 2>/dev/null)" \
                    "PGBACKREST_REPO2_CIPHER_PASS=$(cat "${SECRETS_DIR}/pgbackrest_cipher_pass_repo2" 2>/dev/null)" \
                    gosu postgres /usr/bin/pgbackrest \
                    --stanza=timescaledb \
                    stanza-create 2>"${_stderr_file}" || _exit_code=$?

                if [ "${_exit_code}" -eq 0 ]; then
                    bashio::log.info "pgBackRest: stanza-create OK (attempt ${_attempt})"
                    _stanza_ok=true
                    break
                fi

                _classification=$(classify_pgbackrest_error "${_exit_code}" "${_stderr_file}")
                _stderr_tail=$(tail -c 1024 "${_stderr_file}" 2>/dev/null || true)

                if [ "${_classification}" = "non-transient" ]; then
                    notify_supervisor \
                        "pgBackRest stanza-create failed (non-transient)" \
                        "Exit ${_exit_code}. Last error: ${_stderr_tail}. Fix secrets/SSH key/host and restart."
                    bashio::log.error "pgBackRest: non-transient error (exit ${_exit_code}) — not retrying"
                    break
                fi

                if [ "${_attempt}" -eq 3 ]; then
                    notify_supervisor \
                        "pgBackRest stanza-create failed (retries exhausted)" \
                        "Exit ${_exit_code} after 3 attempts. Last error: ${_stderr_tail}. Fix connectivity and restart."
                    bashio::log.error "pgBackRest: stanza-create failed after 3 attempts (exit ${_exit_code})"
                else
                    bashio::log.warning "pgBackRest: transient error (exit ${_exit_code}), retrying..."
                fi
            done
            rm -f "${_stderr_file}"

            if [ "${_stanza_ok}" = "true" ]; then
                _backup_any_success=true
            fi
        fi
    fi

    # Fail-safe archive_mode degrade: if every configured repo failed stanza-create, disable WAL
    # archiving for this boot by patching the rendered postgresql.conf. This prevents unbounded WAL
    # accumulation on disk when pgbackrest cannot accept archive-push commands.
    # archive_mode requires a full PG restart to re-enable — the user must fix and restart the app.
    if [ "${_backup_any_success}" = "false" ]; then
        bashio::log.warning "pgBackRest: all repos failed — disabling archive_mode for this boot (archive_mode=off)"
        sed -i 's/^archive_mode = on$/archive_mode = off/' "${PGDATA}/postgresql.conf"
        bashio::log.warning "pgBackRest: Fix the above errors and restart the container to re-enable WAL archiving."
    fi

    if [ "${_backup_any_success}" = "true" ]; then
        bashio::log.info "pgBackRest: backup provisioning complete — WAL archiving active"
    else
        bashio::log.info "pgBackRest: backup provisioning failed — running without WAL archiving (check HA notifications)"
    fi

fi

bashio::log.info "Backup: $(bashio::config.true 'backup_enabled' && echo 'enabled' || echo 'disabled')"

# Stop temporary PostgreSQL (the longrun service will start it properly)
gosu postgres pg_ctl -D "${PGDATA}" -w stop
bashio::log.info "Database '${DB_NAME}' with TimescaleDB ready."

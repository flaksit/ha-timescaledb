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
bashio::log.info "TimescaleDB extension verified in '${DB_NAME}'."

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
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO homeassistant_ro;
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
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO homeassistant_rw;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO homeassistant_rw;
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

# Stop temporary PostgreSQL (the longrun service will start it properly)
gosu postgres pg_ctl -D "${PGDATA}" -w stop
bashio::log.info "Database '${DB_NAME}' with TimescaleDB ready."

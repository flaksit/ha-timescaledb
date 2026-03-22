#!/usr/bin/with-contenv bashio
set -euo pipefail

PGDATA="/data/postgres"
SECRETS_DIR="/data/secrets"
DB_NAME=$(bashio::config 'databases')

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

# Initialize cluster if not exists (guard with PG_VERSION check to prevent data loss on restart)
if [ ! -f "${PGDATA}/PG_VERSION" ]; then
    bashio::log.info "Initializing PostgreSQL cluster at ${PGDATA}..."
    initdb \
        --pgdata="${PGDATA}" \
        --username=postgres \
        --encoding=UTF-8 \
        --locale=en_US.UTF-8 \
        --auth-local=trust \
        --auth-host=scram-sha-256
    bashio::log.info "PostgreSQL cluster initialized."
fi

# Render postgresql.conf from add-on options
bashio::log.info "Rendering postgresql.conf from add-on options..."
tempio \
    -conf /data/options.json \
    -template /etc/postgresql/postgresql.conf.tmpl \
    -out "${PGDATA}/postgresql.conf"

# Render pg_hba.conf from add-on options (role-based access control)
bashio::log.info "Rendering pg_hba.conf from add-on options..."
tempio \
    -conf /data/options.json \
    -template /etc/postgresql/pg_hba.conf.tmpl \
    -out "${PGDATA}/pg_hba.conf"

mkdir -p "${PGDATA}/log"

# Start PostgreSQL temporarily for initialization
bashio::log.info "Starting PostgreSQL temporarily for initialization..."
pg_ctl -D "${PGDATA}" -w -o "-p 5432 -k /tmp" start
pg_isready --host=/tmp --timeout=30

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

# ha_readonly role — optional, SELECT only
if bashio::config.true 'enable_readonly'; then
    RO_PW=$(ensure_password "ha_readonly" "readonly_password")
    psql -U postgres -h /tmp -d "${DB_NAME}" <<-EOSQL
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ha_readonly') THEN
                CREATE ROLE ha_readonly LOGIN PASSWORD '${RO_PW}';
                RAISE NOTICE 'Created role ha_readonly';
            ELSE
                ALTER ROLE ha_readonly PASSWORD '${RO_PW}';
            END IF;
        END
        \$\$;
        GRANT CONNECT ON DATABASE "${DB_NAME}" TO ha_readonly;
        GRANT USAGE ON SCHEMA public TO ha_readonly;
        GRANT SELECT ON ALL TABLES IN SCHEMA public TO ha_readonly;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO ha_readonly;
EOSQL
    bashio::log.info "Role 'ha_readonly' ready."
fi

# ha_readwrite role — optional, DML only (no DDL)
if bashio::config.true 'enable_readwrite'; then
    RW_PW=$(ensure_password "ha_readwrite" "readwrite_password")
    psql -U postgres -h /tmp -d "${DB_NAME}" <<-EOSQL
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ha_readwrite') THEN
                CREATE ROLE ha_readwrite LOGIN PASSWORD '${RW_PW}';
                RAISE NOTICE 'Created role ha_readwrite';
            ELSE
                ALTER ROLE ha_readwrite PASSWORD '${RW_PW}';
            END IF;
        END
        \$\$;
        GRANT CONNECT ON DATABASE "${DB_NAME}" TO ha_readwrite;
        GRANT USAGE ON SCHEMA public TO ha_readwrite;
        GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ha_readwrite;
        GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ha_readwrite;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ha_readwrite;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO ha_readwrite;
EOSQL
    bashio::log.info "Role 'ha_readwrite' ready."
fi

# postgres superuser — optional, just set a password
if bashio::config.true 'enable_admin'; then
    ADMIN_PW=$(ensure_password "postgres" "admin_password")
    psql -U postgres -h /tmp -c "ALTER ROLE postgres PASSWORD '${ADMIN_PW}';"
    bashio::log.info "Admin role 'postgres' password set."
fi

# Log connection info
ADDON_HOSTNAME=$(hostname)
bashio::log.info "---"
bashio::log.info "Connection info:"
bashio::log.info "  db_url: postgresql://homeassistant:PASSWORD@${ADDON_HOSTNAME}:5432/${DB_NAME}"
bashio::log.info "  Passwords stored in: ${SECRETS_DIR}/"
bashio::log.info "---"

# Stop temporary PostgreSQL (the longrun service will start it properly)
pg_ctl -D "${PGDATA}" -w stop
bashio::log.info "Database '${DB_NAME}' with TimescaleDB ready."

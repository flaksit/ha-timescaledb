#!/usr/bin/with-contenv bashio
set -euo pipefail

PGDATA="/data/postgres"
DB_NAME=$(bashio::config 'databases')

# Phase 1: Initialize cluster if not exists (guard with PG_VERSION check to prevent data loss on restart)
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

# Phase 2: Render postgresql.conf from add-on options
bashio::log.info "Rendering postgresql.conf from add-on options..."
tempio \
    -conf /data/options.json \
    -template /etc/postgresql/postgresql.conf.tmpl \
    -out "${PGDATA}/postgresql.conf"

# Copy pg_hba.conf (static, not templated)
cp /etc/postgresql/pg_hba.conf "${PGDATA}/pg_hba.conf"

# Create log directory
mkdir -p "${PGDATA}/log"

# Phase 3: Start PostgreSQL temporarily to create DB and extension
bashio::log.info "Starting PostgreSQL temporarily for initialization..."
pg_ctl -D "${PGDATA}" -w -o "-p 5432 -k /tmp" start

# Wait for ready
pg_isready --host=/tmp --timeout=30

# Create database if not exists
if ! psql -U postgres -h /tmp -tc "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'" | grep -q 1; then
    bashio::log.info "Creating database '${DB_NAME}'..."
    psql -U postgres -h /tmp -c "CREATE DATABASE \"${DB_NAME}\" ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8' TEMPLATE template0;"
fi

# Create TimescaleDB extension if not loaded
psql -U postgres -h /tmp -d "${DB_NAME}" -c "CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;"
bashio::log.info "TimescaleDB extension verified in '${DB_NAME}'."

# Stop temporary PostgreSQL (the longrun service will start it properly)
pg_ctl -D "${PGDATA}" -w stop
bashio::log.info "Database '${DB_NAME}' with TimescaleDB ready."

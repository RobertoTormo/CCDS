#!/bin/sh
set -eu

# Load production passwords from Swarm secrets when paths are provided
# Otherwise, keep the environment values used in development
if [ -n "${POSTGRES_PASSWORD_FILE:-}" ]; then
  POSTGRES_PASSWORD="$(cat "$POSTGRES_PASSWORD_FILE")"
fi

if [ -n "${GRAFANA_DB_PASSWORD_FILE:-}" ]; then
  GRAFANA_DB_PASSWORD="$(cat "$GRAFANA_DB_PASSWORD_FILE")"
fi

# Prevent accidentally changing the administrator's password
if [ "$GRAFANA_DB_USER" = "$POSTGRES_USER" ]; then
  echo "Grafana's reader must differ from the database administrator" >&2
  exit 1
fi

# Connect as the existing database administrator
export PGHOST=postgres PGCONNECT_TIMEOUT=3
export PGUSER="$POSTGRES_USER" PGDATABASE="$POSTGRES_DB"
export PGPASSWORD="$POSTGRES_PASSWORD"

# Make the reader password available to psql's \getenv command.
export GRAFANA_DB_PASSWORD

# Wait for the database and the table created by Core
# Stop retrying after 30 attempts
for attempt in $(seq 1 30); do
  if psql -X -c 'SELECT 1 FROM public.items LIMIT 0' >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# Create the reader if missing
psql -X -v ON_ERROR_STOP=1 <<'SQL'
\getenv reader GRAFANA_DB_USER
\getenv password GRAFANA_DB_PASSWORD

SELECT format('CREATE ROLE %I LOGIN', :'reader')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'reader')
\gexec

ALTER ROLE :"reader" PASSWORD :'password';
GRANT CONNECT ON DATABASE :"DBNAME" TO :"reader";
GRANT USAGE ON SCHEMA public TO :"reader";
GRANT SELECT ON public.items TO :"reader";
SQL

echo "Grafana reader account ready."
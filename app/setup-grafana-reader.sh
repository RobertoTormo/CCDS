#!/bin/sh
set -eu

# Connection settings for the existing database administrator
export PGHOST=postgres PGCONNECT_TIMEOUT=3
export PGUSER="$POSTGRES_USER" PGDATABASE="$POSTGRES_DB"
export PGPASSWORD="$POSTGRES_PASSWORD"

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
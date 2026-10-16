
#!/bin/sh
set -eu

BACKUP_DIR="${BACKUP_DIR:-/backups}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_FILE="${BACKUP_DIR}/coredb_${TIMESTAMP}.dump"
TEMP_FILE="${BACKUP_FILE}.partial"

mkdir -p "$BACKUP_DIR"

cleanup() {
    rm -f "$TEMP_FILE"
}
trap cleanup EXIT INT TERM

echo "Waiting for PostgreSQL..."

until pg_isready \
    --host=postgres \
    --port=5432 \
    --username="$POSTGRES_USER" \
    --dbname="$POSTGRES_DB"; do
    sleep 5
done

echo "Creating PostgreSQL backup..."

if pg_dump \
    --host=postgres \
    --port=5432 \
    --username="$POSTGRES_USER" \
    --dbname="$POSTGRES_DB" \
    --format=custom \
    --file="$TEMP_FILE"; then
    test -s "$TEMP_FILE"
    mv "$TEMP_FILE" "$BACKUP_FILE"
    echo "Backup completed: $BACKUP_FILE"
else
    echo "ERROR: PostgreSQL backup failed" >&2
    exit 1
fi

find "$BACKUP_DIR" -type f -name 'coredb_*.dump' -mtime +7 -delete

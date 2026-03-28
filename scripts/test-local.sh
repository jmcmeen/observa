#!/bin/sh
# One-command local test: seed data, refresh views, and run API smoke tests.
# Usage: ./scripts/test-local.sh
#
# Prerequisites: docker compose up -d (services must be running)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

log() { echo "[$(date -u '+%H:%M:%S')] $*"; }

# Check that services are running
if ! docker compose ps --status running postgres 2>/dev/null | grep -q postgres; then
    echo "ERROR: PostgreSQL is not running. Start services first:"
    echo "  docker compose up -d"
    exit 1
fi

log "Seeding test data (100K observations)..."
docker compose exec -T postgres psql -U observa -d inaturalist -v ALLOW_SEED=1 -f - < "${PROJECT_DIR}/scripts/seed-test-data.sql"

log "Refreshing materialized views..."
docker compose exec -T importer psql -f /scripts/create-materialized-views.sql

# Wait for nginx/postgrest to be ready
log "Waiting for API..."
for i in $(seq 1 15); do
    if curl -sf "http://localhost:3001/v_health" > /dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 15 ]; then
        echo "ERROR: API not responding at http://localhost:3001 after 15 seconds"
        exit 1
    fi
    sleep 1
done

log "Running API smoke tests..."
echo ""
sh "${SCRIPT_DIR}/test-api.sh"

echo ""
log "Done. Grafana is at http://localhost:3000"

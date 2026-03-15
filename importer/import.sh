#!/bin/sh
set -e

S3_BUCKET="s3://inaturalist-open-data"
AWS_ARGS="--no-sign-request --region us-east-1 --cli-read-timeout 300"
DATA_DIR="/data"
CACHE_DIR="/cache"
SCRIPTS_DIR="/scripts"
IMPORT_ID=""

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"; }

# Wait for postgres to accept connections
log "Waiting for PostgreSQL..."
for i in $(seq 1 30); do
    if pg_isready -h "${PGHOST:-postgres}" -U "${PGUSER:-observa}" -q 2>/dev/null; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        log "ERROR: PostgreSQL not ready after 30 attempts"
        exit 1
    fi
    sleep 1
done
log "PostgreSQL is ready"

# Cleanup handler: mark import as failed if it hasn't completed
cleanup() {
    EXIT_CODE=$?
    if [ $EXIT_CODE -ne 0 ] && [ -n "$IMPORT_ID" ]; then
        log "ERROR: Import failed with exit code $EXIT_CODE"
        psql -qtAX -c "
            UPDATE import_log
            SET finished_at = now(),
                status = 'failed',
                error_message = 'Import failed with exit code $EXIT_CODE',
                duration_seconds = EXTRACT(EPOCH FROM now() - started_at)::integer
            WHERE id = $IMPORT_ID AND status = 'running';
        " 2>/dev/null || true
    fi
    # Drop staging tables if they exist (failed mid-load)
    psql -qtAX -c "DROP TABLE IF EXISTS observations_staging, photos_staging, taxa_staging, observers_staging CASCADE;" 2>/dev/null || true
    # Release advisory lock
    psql -qtAX -c "SELECT pg_advisory_unlock(1);" 2>/dev/null || true
    # Clean up working files (cache is preserved)
    rm -f "${DATA_DIR}"/*.csv
}
trap cleanup EXIT

# Acquire advisory lock to prevent concurrent imports
LOCK_ACQUIRED=$(psql -qtAX -c "SELECT pg_try_advisory_lock(1);")
if [ "$LOCK_ACQUIRED" != "t" ]; then
    log "ERROR: Another import is already in progress. Exiting."
    exit 1
fi

log "=== iNaturalist import started ==="
START_TIME=$(date +%s)

# Record import start
IMPORT_ID=$(psql -qtAX -c "INSERT INTO import_log (started_at) VALUES (now()) RETURNING id;")

# Download CSV files from S3 (with ETag-based caching)
mkdir -p "${CACHE_DIR}"
log "Checking for updated data files on S3..."
for file in observations.csv.gz observers.csv.gz photos.csv.gz taxa.csv.gz; do
    ETAG_FILE="${CACHE_DIR}/${file}.etag"
    CACHED_FILE="${CACHE_DIR}/${file}"

    # Get the current ETag from S3
    REMOTE_ETAG=$(aws s3api head-object ${AWS_ARGS} \
        --bucket inaturalist-open-data --key "${file}" \
        --query ETag --output text 2>/dev/null || echo "")

    # Compare with cached ETag
    if [ -f "$CACHED_FILE" ] && [ -f "$ETAG_FILE" ]; then
        LOCAL_ETAG=$(cat "$ETAG_FILE")
        if [ "$REMOTE_ETAG" = "$LOCAL_ETAG" ]; then
            log "  ${file}: unchanged (cached)"
            continue
        fi
    fi

    log "  ${file}: downloading..."
    aws s3 cp ${AWS_ARGS} "${S3_BUCKET}/${file}" "${CACHED_FILE}"
    echo "$REMOTE_ETAG" > "$ETAG_FILE"
done

# Validate compressed files before decompression (secondary integrity check)
log "Validating compressed file integrity..."
for file in "${CACHE_DIR}"/*.csv.gz; do
    if ! gunzip -t "$file" 2>/dev/null; then
        BASENAME=$(basename "$file")
        log "ERROR: Corrupt file detected: $BASENAME — removing from cache"
        rm -f "$file" "${file}.etag"
        exit 1
    fi
done

log "Decompressing files to working directory..."
for file in "${CACHE_DIR}"/*.csv.gz; do
    gunzip -c "$file" > "${DATA_DIR}/$(basename "${file%.gz}")"
done

# Validate CSV headers
log "Validating CSV headers..."
EXPECTED_OBS_HEADER="observation_uuid"
EXPECTED_PHOTOS_HEADER="photo_uuid"
EXPECTED_TAXA_HEADER="taxon_id"
EXPECTED_OBSERVERS_HEADER="observer_id"

for pair in "observations.csv:${EXPECTED_OBS_HEADER}" "photos.csv:${EXPECTED_PHOTOS_HEADER}" "taxa.csv:${EXPECTED_TAXA_HEADER}" "observers.csv:${EXPECTED_OBSERVERS_HEADER}"; do
    file="${pair%%:*}"
    expected="${pair##*:}"
    header=$(head -1 "${DATA_DIR}/${file}")
    case "$header" in
        ${expected}*) ;;
        *)
            log "ERROR: Unexpected header in ${file}: ${header}"
            exit 1
            ;;
    esac
done

# Check row counts against previous import (abort if < 50% of previous)
PREV_OBS_COUNT=$(psql -qtAX -c "SELECT COALESCE(observations_count, 0) FROM import_log WHERE status = 'completed' ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "0")
if [ "$PREV_OBS_COUNT" -gt 0 ] 2>/dev/null; then
    NEW_OBS_LINES=$(wc -l < "${DATA_DIR}/observations.csv")
    NEW_OBS_LINES=$((NEW_OBS_LINES - 1))  # subtract header
    THRESHOLD=$((PREV_OBS_COUNT / 2))
    if [ "$NEW_OBS_LINES" -lt "$THRESHOLD" ]; then
        log "ERROR: observations.csv has ${NEW_OBS_LINES} rows, less than 50% of previous import (${PREV_OBS_COUNT}). Aborting."
        exit 1
    fi
fi

# Create staging tables and load data (zero-downtime swap strategy)
log "Creating staging tables..."
psql -v ON_ERROR_STOP=1 <<SQL
DROP TABLE IF EXISTS taxa_staging CASCADE;
DROP TABLE IF EXISTS observers_staging CASCADE;
DROP TABLE IF EXISTS observations_staging CASCADE;
DROP TABLE IF EXISTS photos_staging CASCADE;

CREATE TABLE taxa_staging (LIKE taxa INCLUDING ALL);
CREATE TABLE observers_staging (LIKE observers INCLUDING ALL);
CREATE TABLE observations_staging (LIKE observations INCLUDING ALL);
CREATE TABLE photos_staging (LIKE photos INCLUDING ALL);
SQL

log "Loading data into staging tables..."
psql -v ON_ERROR_STOP=1 <<SQL
\COPY taxa_staging FROM '${DATA_DIR}/taxa.csv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true, NULL '', QUOTE E'\x01')
\COPY observers_staging FROM '${DATA_DIR}/observers.csv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true, NULL '', QUOTE E'\x01')
\COPY observations_staging (observation_uuid, observer_id, latitude, longitude, positional_accuracy, taxon_id, quality_grade, observed_on, anomaly_score) FROM '${DATA_DIR}/observations.csv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true, NULL '', QUOTE E'\x01')

-- Load photos via temp table to handle duplicate photo_id values in upstream data
CREATE TEMP TABLE photos_raw (LIKE photos_staging INCLUDING DEFAULTS);
ALTER TABLE photos_raw DROP CONSTRAINT IF EXISTS photos_raw_pkey;
\COPY photos_raw FROM '${DATA_DIR}/photos.csv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true, NULL '', QUOTE E'\x01')
INSERT INTO photos_staging
SELECT DISTINCT ON (photo_id) * FROM photos_raw ORDER BY photo_id, observation_uuid;
DROP TABLE photos_raw;
SQL

# Populate PostGIS geometry column on staging table
log "Populating geometry column..."
psql -v ON_ERROR_STOP=1 -c "
    UPDATE observations_staging
    SET geom = ST_SetSRID(ST_MakePoint(longitude::double precision, latitude::double precision), 4326)
    WHERE latitude IS NOT NULL AND longitude IS NOT NULL;
"

# Build indexes on staging tables
log "Creating indexes on staging tables..."
psql -v ON_ERROR_STOP=1 <<SQL
CREATE INDEX idx_stg_observations_taxon_id ON observations_staging (taxon_id);
CREATE INDEX idx_stg_observations_observer_id ON observations_staging (observer_id);
CREATE INDEX idx_stg_observations_quality_grade ON observations_staging (quality_grade);
CREATE INDEX idx_stg_observations_observed_on ON observations_staging (observed_on);
CREATE INDEX idx_stg_observations_geom ON observations_staging USING GIST (geom);
CREATE INDEX idx_stg_observations_taxon_quality ON observations_staging (taxon_id, quality_grade);
CREATE INDEX idx_stg_observations_date_taxon ON observations_staging (observed_on, taxon_id);
CREATE INDEX idx_stg_photos_observation_uuid ON photos_staging (observation_uuid);
CREATE INDEX idx_stg_photos_observer_id ON photos_staging (observer_id);
CREATE INDEX idx_stg_taxa_name_trgm ON taxa_staging USING gin (name gin_trgm_ops);
CREATE INDEX idx_stg_observers_login ON observers_staging (login);
VACUUM ANALYZE observations_staging;
VACUUM ANALYZE photos_staging;
VACUUM ANALYZE taxa_staging;
VACUUM ANALYZE observers_staging;
SQL

# Atomic swap: rename staging tables to live, old live to _old
log "Swapping tables (atomic rename)..."
psql -v ON_ERROR_STOP=1 <<SQL
BEGIN;
ALTER TABLE observations RENAME TO observations_old;
ALTER TABLE photos RENAME TO photos_old;
ALTER TABLE taxa RENAME TO taxa_old;
ALTER TABLE observers RENAME TO observers_old;

ALTER TABLE observations_staging RENAME TO observations;
ALTER TABLE photos_staging RENAME TO photos;
ALTER TABLE taxa_staging RENAME TO taxa;
ALTER TABLE observers_staging RENAME TO observers;
COMMIT;
SQL

# Drop old tables
log "Dropping old tables..."
psql -v ON_ERROR_STOP=1 -c "DROP TABLE IF EXISTS observations_old, photos_old, taxa_old, observers_old CASCADE;"

# Refresh materialized views
log "Refreshing materialized views..."
psql -v ON_ERROR_STOP=1 -f "${SCRIPTS_DIR}/create-materialized-views.sql"

# Get row counts and update import log
OBS_COUNT=$(psql -qtAX -c "SELECT count(*) FROM observations;")
PHOTO_COUNT=$(psql -qtAX -c "SELECT count(*) FROM photos;")
TAXA_COUNT=$(psql -qtAX -c "SELECT count(*) FROM taxa;")
OBSERVER_COUNT=$(psql -qtAX -c "SELECT count(*) FROM observers;")

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))

psql -v ON_ERROR_STOP=1 -c "
    UPDATE import_log
    SET finished_at = now(),
        status = 'completed',
        observations_count = ${OBS_COUNT},
        photos_count = ${PHOTO_COUNT},
        taxa_count = ${TAXA_COUNT},
        observers_count = ${OBSERVER_COUNT},
        duration_seconds = ${DURATION}
    WHERE id = ${IMPORT_ID};
"

# Clean up downloaded files
rm -f "${DATA_DIR}"/*.csv

log "=== Import completed in ${DURATION}s ==="
log "  Observations: ${OBS_COUNT}"
log "  Photos:       ${PHOTO_COUNT}"
log "  Taxa:         ${TAXA_COUNT}"
log "  Observers:    ${OBSERVER_COUNT}"

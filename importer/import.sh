#!/bin/sh
set -e

S3_BUCKET="s3://inaturalist-open-data"
AWS_ARGS="--no-sign-request --region us-east-1 --cli-read-timeout 300"
DATA_DIR="/data"
CACHE_DIR="/cache"
SCRIPTS_DIR="/scripts"
IMPORT_ID=""
SWAP_COMPLETE=0
LOCK_DIR="/tmp/import.lock"
FILES_CHANGED=0

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"; }

# --- Cleanup ---

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
    # Drop staging tables only if the swap hasn't completed yet
    if [ "$SWAP_COMPLETE" -eq 0 ]; then
        psql -qtAX -c "DROP TABLE IF EXISTS observations_staging, photos_staging, taxa_staging, observers_staging CASCADE;" 2>/dev/null || true
    fi
    # Release lock
    rmdir "$LOCK_DIR" 2>/dev/null || true
    # Clean up working files (cache is preserved)
    rm -f "${DATA_DIR}"/*.csv
}

# --- Phase functions ---

wait_for_postgres() {
    log "Waiting for PostgreSQL..."
    for i in $(seq 1 30); do
        if pg_isready -h "${PGHOST:-postgres}" -U "${PGUSER:-observa}" -q 2>/dev/null; then
            log "PostgreSQL is ready"
            return
        fi
        if [ "$i" -eq 30 ]; then
            log "ERROR: PostgreSQL not ready after 30 attempts"
            exit 1
        fi
        sleep 1
    done
}

download_one() {
    file="$1"
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
            return
        fi
    fi

    log "  ${file}: downloading..."
    aws s3 cp --no-progress ${AWS_ARGS} "${S3_BUCKET}/${file}" "${CACHED_FILE}"
    log "  ${file}: done"
    echo "$REMOTE_ETAG" > "$ETAG_FILE"
    touch "${CACHE_DIR}/.files_changed"
}

download_files() {
    mkdir -p "${CACHE_DIR}"
    rm -f "${CACHE_DIR}/.files_changed"
    log "Checking for updated data files on S3..."

    for file in observations.csv.gz observers.csv.gz photos.csv.gz taxa.csv.gz; do
        download_one "$file" &
    done
    wait

    if [ -f "${CACHE_DIR}/.files_changed" ]; then
        FILES_CHANGED=1
        rm -f "${CACHE_DIR}/.files_changed"
    fi
}

validate_files() {
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

    log "Validating CSV headers..."
    for pair in "observations.csv:observation_uuid" "photos.csv:photo_uuid" "taxa.csv:taxon_id" "observers.csv:observer_id"; do
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
        # awk END{NR} counts records correctly even without a trailing newline
        NEW_OBS_LINES=$(awk 'END{print NR}' "${DATA_DIR}/observations.csv")
        NEW_OBS_LINES=$((NEW_OBS_LINES - 1))  # subtract header
        THRESHOLD=$((PREV_OBS_COUNT / 2))
        if [ "$NEW_OBS_LINES" -lt "$THRESHOLD" ]; then
            log "ERROR: observations.csv has ${NEW_OBS_LINES} rows, less than 50% of previous import (${PREV_OBS_COUNT}). Aborting."
            exit 1
        fi
    fi
}

load_staging() {
    log "Creating staging tables..."
    psql -v ON_ERROR_STOP=1 <<SQL
DROP TABLE IF EXISTS taxa_staging CASCADE;
DROP TABLE IF EXISTS observers_staging CASCADE;
DROP TABLE IF EXISTS observations_staging CASCADE;
DROP TABLE IF EXISTS photos_staging CASCADE;

CREATE UNLOGGED TABLE taxa_staging (LIKE taxa INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING GENERATED);
CREATE UNLOGGED TABLE observers_staging (LIKE observers INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING GENERATED);
CREATE UNLOGGED TABLE observations_staging (LIKE observations INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING GENERATED);
CREATE UNLOGGED TABLE photos_staging (LIKE photos INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING GENERATED);
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

    log "Creating indexes on staging tables..."
    psql -v ON_ERROR_STOP=1 <<SQL
CREATE INDEX IF NOT EXISTS idx_stg_observations_taxon_id ON observations_staging (taxon_id);
CREATE INDEX IF NOT EXISTS idx_stg_observations_observer_id ON observations_staging (observer_id);
CREATE INDEX IF NOT EXISTS idx_stg_observations_quality_grade ON observations_staging (quality_grade);
CREATE INDEX IF NOT EXISTS idx_stg_observations_observed_on ON observations_staging (observed_on);
CREATE INDEX IF NOT EXISTS idx_stg_observations_geom ON observations_staging USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_stg_observations_taxon_quality ON observations_staging (taxon_id, quality_grade);
CREATE INDEX IF NOT EXISTS idx_stg_observations_date_taxon ON observations_staging (observed_on, taxon_id);
CREATE INDEX IF NOT EXISTS idx_stg_photos_observation_uuid ON photos_staging (observation_uuid);
CREATE INDEX IF NOT EXISTS idx_stg_photos_observer_id ON photos_staging (observer_id);
CREATE INDEX IF NOT EXISTS idx_stg_taxa_name_trgm ON taxa_staging USING gin (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_stg_observers_login ON observers_staging (login);
VACUUM ANALYZE observations_staging;
VACUUM ANALYZE photos_staging;
VACUUM ANALYZE taxa_staging;
VACUUM ANALYZE observers_staging;
SQL
}

swap_tables() {
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
    SWAP_COMPLETE=1

    log "Dropping old tables..."
    psql -v ON_ERROR_STOP=1 <<SQL
DROP TABLE IF EXISTS observations_old, photos_old, taxa_old, observers_old CASCADE;
SQL
}

refresh_views() {
    log "Rebuilding materialized views..."
    psql -v ON_ERROR_STOP=1 -f "${SCRIPTS_DIR}/create-materialized-views.sql"
}

grant_api_access() {
    log "Granting api_readonly access to new tables..."
    psql -v ON_ERROR_STOP=1 -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO api_readonly;"
}

# --- Main ---

trap cleanup EXIT

wait_for_postgres

# Acquire lock to prevent concurrent imports (mkdir is atomic)
LOCK_DIR="/tmp/import.lock"
if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
elif [ -f "$LOCK_DIR/pid" ]; then
    LOCK_PID=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        log "ERROR: Another import (PID $LOCK_PID) is already running. Exiting."
        exit 1
    fi
    log "WARNING: Removing stale lock from PID $LOCK_PID"
    rm -rf "$LOCK_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        log "ERROR: Failed to re-acquire lock after stale cleanup. Another import may have started."
        exit 1
    fi
    echo $$ > "$LOCK_DIR/pid"
else
    log "ERROR: Lock exists but no PID file found. Remove $LOCK_DIR manually."
    exit 1
fi

log "=== iNaturalist import started ==="
START_TIME=$(date +%s)

download_files

# Skip import if no files changed and last import was successful
if [ "$FILES_CHANGED" -eq 0 ]; then
    LAST_STATUS=$(psql -qtAX -c "SELECT status FROM import_log ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")
    if [ "$LAST_STATUS" = "completed" ]; then
        log "No new data and last import succeeded. Skipping."
        exit 0
    fi
    log "No new data but last import was not successful. Re-importing."
fi

IMPORT_ID=$(psql -qtAX -c "INSERT INTO import_log (started_at) VALUES (now()) RETURNING id;")

validate_files
load_staging
swap_tables
refresh_views
grant_api_access

# Record completion
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

rm -f "${DATA_DIR}"/*.csv

log "=== Import completed in ${DURATION}s ==="
log "  Observations: ${OBS_COUNT}"
log "  Photos:       ${PHOTO_COUNT}"
log "  Taxa:         ${TAXA_COUNT}"
log "  Observers:    ${OBSERVER_COUNT}"

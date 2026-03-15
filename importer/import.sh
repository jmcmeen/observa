#!/bin/sh
set -e

S3_BUCKET="s3://inaturalist-open-data"
AWS_ARGS="--no-sign-request --region us-east-1"
DATA_DIR="/data"
SCRIPTS_DIR="/scripts"

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"; }

log "=== iNaturalist import started ==="
START_TIME=$(date +%s)

# Record import start
IMPORT_ID=$(psql -qtAX -c "INSERT INTO import_log (started_at) VALUES (now()) RETURNING id;")

# Download CSV files from S3
log "Downloading data files from S3..."
for file in observations.csv.gz observers.csv.gz photos.csv.gz taxa.csv.gz; do
    log "  Downloading ${file}..."
    aws s3 cp ${AWS_ARGS} "${S3_BUCKET}/${file}" "${DATA_DIR}/${file}"
done

log "Decompressing files..."
for file in "${DATA_DIR}"/*.csv.gz; do
    gunzip -f "$file"
done

# Full refresh: truncate and reload within a transaction
log "Loading data into database..."
psql -v ON_ERROR_STOP=1 <<SQL
BEGIN;

-- Drop indexes for faster bulk load
DROP INDEX IF EXISTS idx_observations_taxon_id;
DROP INDEX IF EXISTS idx_observations_observer_id;
DROP INDEX IF EXISTS idx_observations_quality_grade;
DROP INDEX IF EXISTS idx_observations_observed_on;
DROP INDEX IF EXISTS idx_observations_geom;
DROP INDEX IF EXISTS idx_photos_observation_uuid;
DROP INDEX IF EXISTS idx_photos_observer_id;

TRUNCATE observations, photos, taxa, observers;

\COPY taxa FROM '${DATA_DIR}/taxa.csv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true, NULL '')
\COPY observers FROM '${DATA_DIR}/observers.csv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true, NULL '')
\COPY observations (observation_uuid, observer_id, latitude, longitude, positional_accuracy, taxon_id, quality_grade, observed_on, anomaly_score) FROM '${DATA_DIR}/observations.csv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true, NULL '')
\COPY photos FROM '${DATA_DIR}/photos.csv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true, NULL '')

COMMIT;
SQL

# Populate PostGIS geometry column
log "Populating geometry column..."
psql -v ON_ERROR_STOP=1 -c "
    UPDATE observations
    SET geom = ST_SetSRID(ST_MakePoint(longitude::double precision, latitude::double precision), 4326)
    WHERE latitude IS NOT NULL AND longitude IS NOT NULL;
"

# Recreate indexes
log "Creating indexes..."
psql -v ON_ERROR_STOP=1 -f "${SCRIPTS_DIR}/create-indexes.sql"

# Get row counts and update import log
OBS_COUNT=$(psql -qtAX -c "SELECT count(*) FROM observations;")
PHOTO_COUNT=$(psql -qtAX -c "SELECT count(*) FROM photos;")
TAXA_COUNT=$(psql -qtAX -c "SELECT count(*) FROM taxa;")
OBSERVER_COUNT=$(psql -qtAX -c "SELECT count(*) FROM observers;")

psql -v ON_ERROR_STOP=1 -c "
    UPDATE import_log
    SET finished_at = now(),
        status = 'completed',
        observations_count = ${OBS_COUNT},
        photos_count = ${PHOTO_COUNT},
        taxa_count = ${TAXA_COUNT},
        observers_count = ${OBSERVER_COUNT}
    WHERE id = ${IMPORT_ID};
"

# Clean up downloaded files
rm -f "${DATA_DIR}"/*.csv

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))

log "=== Import completed in ${DURATION}s ==="
log "  Observations: ${OBS_COUNT}"
log "  Photos:       ${PHOTO_COUNT}"
log "  Taxa:         ${TAXA_COUNT}"
log "  Observers:    ${OBSERVER_COUNT}"

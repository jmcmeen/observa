#!/bin/sh
set -e

# Export data from the database in CSV or GeoJSON format
# Usage: export.sh [csv|geojson] [table] [output_dir]
#
# Examples:
#   export.sh csv observations /data
#   export.sh csv taxa /data
#   export.sh geojson observations /data

FORMAT="${1:-csv}"
TABLE="${2:-observations}"
OUTPUT_DIR="${3:-/data}"

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"; }

case "$TABLE" in
    observations|photos|taxa|observers) ;;
    *)
        echo "ERROR: Unknown table '$TABLE'. Valid tables: observations, photos, taxa, observers"
        exit 1
        ;;
esac

case "$FORMAT" in
    csv)
        OUTPUT_FILE="${OUTPUT_DIR}/${TABLE}_export.csv"
        log "Exporting ${TABLE} to CSV..."
        psql -c "\COPY ${TABLE} TO '${OUTPUT_FILE}' WITH (FORMAT csv, HEADER true)"
        log "Exported to ${OUTPUT_FILE}"
        ;;
    geojson)
        if [ "$TABLE" != "observations" ]; then
            echo "ERROR: GeoJSON export only supported for observations table"
            exit 1
        fi
        OUTPUT_FILE="${OUTPUT_DIR}/observations_export.geojson"
        log "Exporting observations to GeoJSON..."
        psql -qtAX -c "
            SELECT json_build_object(
                'type', 'FeatureCollection',
                'features', COALESCE(json_agg(
                    json_build_object(
                        'type', 'Feature',
                        'geometry', ST_AsGeoJSON(geom)::json,
                        'properties', json_build_object(
                            'observation_uuid', observation_uuid,
                            'taxon_id', taxon_id,
                            'quality_grade', quality_grade,
                            'observed_on', observed_on
                        )
                    )
                ), '[]'::json)
            )
            FROM observations
            WHERE geom IS NOT NULL
            LIMIT 10000;
        " > "$OUTPUT_FILE"
        log "Exported to ${OUTPUT_FILE} (limited to 10,000 features)"
        ;;
    *)
        echo "ERROR: Unknown format '$FORMAT'. Valid formats: csv, geojson"
        exit 1
        ;;
esac

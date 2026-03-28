#!/bin/sh
set -e

# Export data from the database in CSV, GeoJSON, KML, or Darwin Core Archive format
# Usage: export.sh [csv|geojson|kml|dwca] [table] [output_dir]
#
# Examples:
#   export.sh csv observations /data
#   export.sh csv taxa /data
#   export.sh geojson observations /data
#   export.sh kml observations /data
#   export.sh dwca observations /data

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
            FROM (
                SELECT geom, observation_uuid, taxon_id, quality_grade, observed_on
                FROM observations
                WHERE geom IS NOT NULL
                ORDER BY observed_on DESC
                LIMIT 10000
            ) sub;
        " > "$OUTPUT_FILE"
        log "Exported to ${OUTPUT_FILE} (limited to 10,000 features)"
        ;;
    kml)
        if [ "$TABLE" != "observations" ]; then
            echo "ERROR: KML export only supported for observations table"
            exit 1
        fi
        OUTPUT_FILE="${OUTPUT_DIR}/observations_export.kml"
        log "Exporting observations to KML (Google Earth)..."
        psql -qtAX -c "
            SELECT '<?xml version=\"1.0\" encoding=\"UTF-8\"?>'
            || '<kml xmlns=\"http://www.opengis.net/kml/2.2\">'
            || '<Document><name>Observa Export</name>'
            || COALESCE(string_agg(
                '<Placemark>'
                || '<name>' || replace(replace(replace(COALESCE(sub.taxon_name, 'Unknown'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || '</name>'
                || '<description>'
                || 'UUID: ' || sub.observation_uuid
                || ', Quality: ' || replace(replace(replace(COALESCE(sub.quality_grade, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
                || ', Date: ' || COALESCE(sub.observed_on::text, '')
                || '</description>'
                || '<Point><coordinates>'
                || sub.longitude || ',' || sub.latitude
                || '</coordinates></Point>'
                || '</Placemark>',
                ''
            ), '')
            || '</Document></kml>'
            FROM (
                SELECT o.observation_uuid, o.quality_grade, o.observed_on,
                       o.longitude, o.latitude, t.name AS taxon_name
                FROM observations o
                LEFT JOIN taxa t ON o.taxon_id = t.taxon_id
                WHERE o.latitude IS NOT NULL AND o.longitude IS NOT NULL
                ORDER BY o.observed_on DESC
                LIMIT 10000
            ) sub;
        " > "$OUTPUT_FILE"
        log "Exported to ${OUTPUT_FILE} (limited to 10,000 placemarks)"
        ;;
    dwca)
        if [ "$TABLE" != "observations" ]; then
            echo "ERROR: Darwin Core Archive export only supported for observations table"
            exit 1
        fi
        DWCA_DIR="${OUTPUT_DIR}/dwca_export"
        mkdir -p "$DWCA_DIR"
        log "Exporting observations as Darwin Core Archive..."

        # Occurrence core file
        psql -c "\COPY (
            SELECT
                observation_uuid AS \"occurrenceID\",
                'HumanObservation' AS \"basisOfRecord\",
                o.observed_on AS \"eventDate\",
                o.latitude AS \"decimalLatitude\",
                o.longitude AS \"decimalLongitude\",
                o.positional_accuracy AS \"coordinateUncertaintyInMeters\",
                t.name AS \"scientificName\",
                t.rank AS \"taxonRank\",
                'present' AS \"occurrenceStatus\",
                ob.login AS \"recordedBy\",
                o.quality_grade AS \"occurrenceRemarks\"
            FROM observations o
            LEFT JOIN taxa t ON o.taxon_id = t.taxon_id
            LEFT JOIN observers ob ON o.observer_id = ob.observer_id
            LIMIT 100000
        ) TO '${DWCA_DIR}/occurrence.csv' WITH (FORMAT csv, HEADER true)"

        # Meta descriptor
        cat > "${DWCA_DIR}/meta.xml" << 'METAXML'
<?xml version="1.0" encoding="UTF-8"?>
<archive xmlns="http://rs.tdwg.org/dwc/text/">
  <core encoding="UTF-8" fieldsTerminatedBy="," linesTerminatedBy="\n" fieldsEnclosedBy="&quot;" ignoreHeaderLines="1" rowType="http://rs.tdwg.org/dwc/terms/Occurrence">
    <files><location>occurrence.csv</location></files>
    <id index="0"/>
    <field index="0" term="http://rs.tdwg.org/dwc/terms/occurrenceID"/>
    <field index="1" term="http://rs.tdwg.org/dwc/terms/basisOfRecord"/>
    <field index="2" term="http://rs.tdwg.org/dwc/terms/eventDate"/>
    <field index="3" term="http://rs.tdwg.org/dwc/terms/decimalLatitude"/>
    <field index="4" term="http://rs.tdwg.org/dwc/terms/decimalLongitude"/>
    <field index="5" term="http://rs.tdwg.org/dwc/terms/coordinateUncertaintyInMeters"/>
    <field index="6" term="http://rs.tdwg.org/dwc/terms/scientificName"/>
    <field index="7" term="http://rs.tdwg.org/dwc/terms/taxonRank"/>
    <field index="8" term="http://rs.tdwg.org/dwc/terms/occurrenceStatus"/>
    <field index="9" term="http://rs.tdwg.org/dwc/terms/recordedBy"/>
    <field index="10" term="http://rs.tdwg.org/dwc/terms/occurrenceRemarks"/>
  </core>
</archive>
METAXML

        log "Exported to ${DWCA_DIR}/ (occurrence.csv + meta.xml, limited to 100,000 records)"
        log "To create a .zip archive: cd ${DWCA_DIR} && zip ../dwca_export.zip *"
        ;;
    *)
        echo "ERROR: Unknown format '$FORMAT'. Valid formats: csv, geojson, kml, dwca"
        exit 1
        ;;
esac

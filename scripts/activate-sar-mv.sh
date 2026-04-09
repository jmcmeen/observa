#!/bin/sh
# One-shot script to activate the multi-scale SAR panel changes from this session.
#
# The dashboard, init schema, and per-import script have already been edited.
# This script applies the runtime changes that need to happen against the live
# database/services to make the new panel work without waiting for the next import.
#
# Safe to run multiple times — uses DROP IF EXISTS / CREATE patterns.
#
# Usage:
#   ./scripts/activate-sar-mv.sh

set -e

log() { echo "[$(date -u '+%H:%M:%S')] $*"; }

log "Step 1/3: Building mv_herpetofauna_sar_grid in the running database..."
log "  (this scans ~6M herp observation rows and builds taxon_id arrays per 0.1 deg cell)"
log "  (expect ~30-90 seconds depending on cache state)"

docker exec -i observa-postgres-1 psql -U observa -d inaturalist -v ON_ERROR_STOP=1 <<'SQL'
DROP MATERIALIZED VIEW IF EXISTS mv_herpetofauna_sar_grid;

CREATE MATERIALIZED VIEW mv_herpetofauna_sar_grid AS
SELECT
    ST_SnapToGrid(o.geom, 0.1) AS grid_geom,
    o.quality_grade,
    array_agg(DISTINCT o.taxon_id ORDER BY o.taxon_id) AS taxon_ids,
    COALESCE(array_agg(DISTINCT o.taxon_id) FILTER (WHERE ('/' || COALESCE(t.ancestry, '') || '/') LIKE '%/20978/%' OR t.taxon_id = 20978), '{}'::int[]) AS amphibia_taxa,
    COALESCE(array_agg(DISTINCT o.taxon_id) FILTER (WHERE ('/' || COALESCE(t.ancestry, '') || '/') LIKE '%/26036/%' OR t.taxon_id = 26036), '{}'::int[]) AS reptilia_taxa,
    COALESCE(array_agg(DISTINCT o.taxon_id) FILTER (WHERE ('/' || COALESCE(t.ancestry, '') || '/') LIKE '%/20979/%' OR t.taxon_id = 20979), '{}'::int[]) AS anura_taxa,
    COALESCE(array_agg(DISTINCT o.taxon_id) FILTER (WHERE ('/' || COALESCE(t.ancestry, '') || '/') LIKE '%/26718/%' OR t.taxon_id = 26718), '{}'::int[]) AS caudata_taxa,
    COALESCE(array_agg(DISTINCT o.taxon_id) FILTER (WHERE ('/' || COALESCE(t.ancestry, '') || '/') LIKE '%/39532/%' OR t.taxon_id = 39532), '{}'::int[]) AS testudines_taxa,
    COALESCE(array_agg(DISTINCT o.taxon_id) FILTER (WHERE ('/' || COALESCE(t.ancestry, '') || '/') LIKE '%/85553/%' OR t.taxon_id = 85553), '{}'::int[]) AS serpentes_taxa,
    count(*) AS observation_count
FROM observations o
JOIN taxa t ON o.taxon_id = t.taxon_id
WHERE o.geom IS NOT NULL
  AND t.rank = 'species'
  AND ((('/' || COALESCE(t.ancestry, '') || '/') LIKE '%/20978/%' OR t.taxon_id = 20978)
    OR (('/' || COALESCE(t.ancestry, '') || '/') LIKE '%/26036/%' OR t.taxon_id = 26036))
GROUP BY 1, 2;

CREATE UNIQUE INDEX ON mv_herpetofauna_sar_grid (grid_geom, quality_grade);
CREATE INDEX ON mv_herpetofauna_sar_grid USING GIST (grid_geom);
GRANT SELECT ON mv_herpetofauna_sar_grid TO api_readonly;

SELECT
    count(*) AS rows,
    count(DISTINCT quality_grade) AS qualities,
    pg_size_pretty(pg_total_relation_size('mv_herpetofauna_sar_grid')) AS size
FROM mv_herpetofauna_sar_grid;
SQL

log ""
log "Step 2/3: Restarting Grafana to load the new dashboard panel..."
docker restart observa-grafana-1 > /dev/null
log "  Grafana restarted"

log ""
log "Step 3/3: Smoke-testing the multi-scale SAR query..."
docker exec observa-postgres-1 psql -U observa -d inaturalist -c "
WITH scales AS (SELECT unnest(ARRAY[0.1, 0.2, 0.4, 0.8, 1.6]::float[]) AS scale_deg),
aggregated AS (
    SELECT s.scale_deg,
           ST_SnapToGrid(g.grid_geom, s.scale_deg) AS coarse_geom,
           array_agg(DISTINCT tid) AS taxon_ids,
           sum(g.observation_count) AS total_observations
    FROM mv_herpetofauna_sar_grid g
    CROSS JOIN scales s
    CROSS JOIN LATERAL unnest(g.taxon_ids) AS u(tid)
    WHERE g.quality_grade = 'research'
    GROUP BY 1, 2
    HAVING sum(g.observation_count) >= 3
)
SELECT scale_deg,
       count(*) AS n_cells,
       round(min(ST_Area(ST_MakeEnvelope(GREATEST(ST_X(coarse_geom) - scale_deg/2, -180), GREATEST(ST_Y(coarse_geom) - scale_deg/2, -90), LEAST(ST_X(coarse_geom) + scale_deg/2, 180), LEAST(ST_Y(coarse_geom) + scale_deg/2, 90), 4326)::geography) / 1e6)::numeric, 1) AS min_area_km2,
       round(max(ST_Area(ST_MakeEnvelope(GREATEST(ST_X(coarse_geom) - scale_deg/2, -180), GREATEST(ST_Y(coarse_geom) - scale_deg/2, -90), LEAST(ST_X(coarse_geom) + scale_deg/2, 180), LEAST(ST_Y(coarse_geom) + scale_deg/2, 90), 4326)::geography) / 1e6)::numeric, 1) AS max_area_km2,
       round(avg(cardinality(taxon_ids))::numeric, 1) AS mean_species_per_cell,
       max(cardinality(taxon_ids)) AS max_species
FROM aggregated
GROUP BY scale_deg
ORDER BY scale_deg;
"

log ""
log "Done. Open Grafana at http://localhost:3000 and navigate to the Herpetofauna dashboard."
log "The new panel 'Multi-Scale Species-Area Aggregation (SAR-ready)' is at the bottom."

-- Materialized views for pre-aggregated dashboard queries
-- These dramatically improve Grafana panel load times on large datasets
--
-- Uses a build-and-swap pattern: new MVs are built under temporary names
-- while dashboards continue reading existing MVs, then swapped atomically.

-- Drop any leftover temp views from a previous failed run
DROP MATERIALIZED VIEW IF EXISTS mv_observations_monthly_new;
DROP MATERIALIZED VIEW IF EXISTS mv_quality_grade_counts_new;
DROP MATERIALIZED VIEW IF EXISTS mv_top_taxa_new;
DROP MATERIALIZED VIEW IF EXISTS mv_top_observers_new;
DROP MATERIALIZED VIEW IF EXISTS mv_photo_licenses_new;
DROP MATERIALIZED VIEW IF EXISTS mv_observations_by_rank_new;
DROP MATERIALIZED VIEW IF EXISTS mv_observations_grid_new;
DROP MATERIALIZED VIEW IF EXISTS mv_herpetofauna_grid_new;
DROP MATERIALIZED VIEW IF EXISTS mv_herpetofauna_sar_grid_new;
DROP MATERIALIZED VIEW IF EXISTS mv_herpetofauna_sar_data_new;

-- Phase 1: Build new MVs under temporary names (no lock on existing MVs)

CREATE MATERIALIZED VIEW mv_observations_monthly_new AS
SELECT date_trunc('month', observed_on) AS month,
       count(*) AS observation_count
FROM observations
WHERE observed_on IS NOT NULL
GROUP BY 1;
CREATE UNIQUE INDEX ON mv_observations_monthly_new (month);

CREATE MATERIALIZED VIEW mv_quality_grade_counts_new AS
SELECT quality_grade, count(*) AS total
FROM observations
WHERE quality_grade IS NOT NULL
GROUP BY quality_grade;
CREATE UNIQUE INDEX ON mv_quality_grade_counts_new (quality_grade);

CREATE MATERIALIZED VIEW mv_top_taxa_new AS
SELECT t.taxon_id, t.name, t.rank, count(*) AS observation_count
FROM observations o
JOIN taxa t ON o.taxon_id = t.taxon_id
GROUP BY t.taxon_id, t.name, t.rank;
CREATE UNIQUE INDEX ON mv_top_taxa_new (taxon_id);
CREATE INDEX ON mv_top_taxa_new (observation_count DESC);

CREATE MATERIALIZED VIEW mv_top_observers_new AS
SELECT ob.observer_id, ob.login, ob.name, count(*) AS observation_count
FROM observations o
JOIN observers ob ON o.observer_id = ob.observer_id
GROUP BY ob.observer_id, ob.login, ob.name;
CREATE UNIQUE INDEX ON mv_top_observers_new (observer_id);
CREATE INDEX ON mv_top_observers_new (observation_count DESC);

CREATE MATERIALIZED VIEW mv_photo_licenses_new AS
SELECT license, count(*) AS total
FROM photos
WHERE license IS NOT NULL
GROUP BY license;
CREATE UNIQUE INDEX ON mv_photo_licenses_new (license);

CREATE MATERIALIZED VIEW mv_observations_by_rank_new AS
SELECT t.rank, count(*) AS observation_count
FROM observations o
JOIN taxa t ON o.taxon_id = t.taxon_id
WHERE t.rank IS NOT NULL
GROUP BY t.rank;
CREATE UNIQUE INDEX ON mv_observations_by_rank_new (rank);

CREATE MATERIALIZED VIEW mv_observations_grid_new AS
SELECT ST_SnapToGrid(geom, 1) AS grid_geom,
       count(*) AS observation_count
FROM observations
WHERE geom IS NOT NULL
GROUP BY 1;
CREATE UNIQUE INDEX ON mv_observations_grid_new (grid_geom);
CREATE INDEX ON mv_observations_grid_new USING GIST (grid_geom);

-- Herpetofauna density grid (Amphibia + Reptilia) at 0.5 degree resolution.
-- Grouped by quality_grade so the Herpetofauna dashboard's quality variable still filters.
CREATE MATERIALIZED VIEW mv_herpetofauna_grid_new AS
SELECT ST_SnapToGrid(o.geom, 0.5) AS grid_geom,
       o.quality_grade,
       count(*) AS observation_count
FROM observations o
JOIN taxa t ON o.taxon_id = t.taxon_id
WHERE o.geom IS NOT NULL
  AND ((('/' || COALESCE(t.ancestry, '') || '/') LIKE '%/20978/%' OR t.taxon_id = 20978)
    OR (('/' || COALESCE(t.ancestry, '') || '/') LIKE '%/26036/%' OR t.taxon_id = 26036))
GROUP BY 1, 2;
CREATE UNIQUE INDEX ON mv_herpetofauna_grid_new (grid_geom, quality_grade);
CREATE INDEX ON mv_herpetofauna_grid_new USING GIST (grid_geom);

-- Herpetofauna SAR grid at 0.1 degree resolution with per-cell taxon_id arrays.
-- Backs the Multi-Scale Species-Area Aggregation panels — the dashboard queries union
-- taxon_ids across cells to compute species richness at coarser scales without
-- re-scanning the 233M-row observations table. Filtered to t.rank='species' since
-- SAR is fit on species counts only.
--
-- Per-group taxa columns (amphibia/reptilia/anura/caudata/testudines/serpentes_taxa)
-- are computed via array_agg(...) FILTER so each group's panel can unnest its own
-- column directly without a species-filter subquery. iNat taxon IDs:
--   Amphibia=20978, Reptilia=26036, Anura=20979, Caudata=26718,
--   Testudines=39532, Serpentes=85553
CREATE MATERIALIZED VIEW mv_herpetofauna_sar_grid_new AS
SELECT ST_SnapToGrid(o.geom, 0.1) AS grid_geom,
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
CREATE UNIQUE INDEX ON mv_herpetofauna_sar_grid_new (grid_geom, quality_grade);
CREATE INDEX ON mv_herpetofauna_sar_grid_new USING GIST (grid_geom);

-- Herpetofauna SAR data — fully pre-aggregated multi-scale grid backing the
-- Multi-Scale Species-Area Aggregation panel. Built from mv_herpetofauna_sar_grid_new.
-- One row per (scale, cell, quality_grade) with geodesic cell area and species
-- counts broken out per taxonomic group (total, amphibia, reptilia, anura,
-- caudata, testudines, serpentes).
CREATE MATERIALIZED VIEW mv_herpetofauna_sar_data_new AS
WITH scales AS (SELECT unnest(ARRAY[0.1, 0.2, 0.4, 0.8, 1.6]::float[]) AS scale_deg),
unnested AS (
  SELECT
    s.scale_deg,
    ST_SnapToGrid(g.grid_geom, s.scale_deg) AS coarse_geom,
    g.quality_grade,
    tid,
    tid = ANY(g.amphibia_taxa) AS in_amphibia,
    tid = ANY(g.reptilia_taxa) AS in_reptilia,
    tid = ANY(g.anura_taxa) AS in_anura,
    tid = ANY(g.caudata_taxa) AS in_caudata,
    tid = ANY(g.testudines_taxa) AS in_testudines,
    tid = ANY(g.serpentes_taxa) AS in_serpentes
  FROM mv_herpetofauna_sar_grid_new g
  CROSS JOIN scales s
  CROSS JOIN LATERAL unnest(g.taxon_ids) AS u(tid)
)
SELECT
  scale_deg,
  coarse_geom AS grid_geom,
  quality_grade,
  ST_Area(ST_MakeEnvelope(GREATEST(ST_X(coarse_geom) - scale_deg/2, -180), GREATEST(ST_Y(coarse_geom) - scale_deg/2, -90), LEAST(ST_X(coarse_geom) + scale_deg/2, 180), LEAST(ST_Y(coarse_geom) + scale_deg/2, 90), 4326)::geography) / 1e6 AS cell_area_km2,
  count(DISTINCT tid) AS total_species,
  count(DISTINCT tid) FILTER (WHERE in_amphibia) AS amphibia_species,
  count(DISTINCT tid) FILTER (WHERE in_reptilia) AS reptilia_species,
  count(DISTINCT tid) FILTER (WHERE in_anura) AS anura_species,
  count(DISTINCT tid) FILTER (WHERE in_caudata) AS caudata_species,
  count(DISTINCT tid) FILTER (WHERE in_testudines) AS testudines_species,
  count(DISTINCT tid) FILTER (WHERE in_serpentes) AS serpentes_species
FROM unnested
GROUP BY 1, 2, 3;
CREATE UNIQUE INDEX ON mv_herpetofauna_sar_data_new (scale_deg, grid_geom, quality_grade);
CREATE INDEX ON mv_herpetofauna_sar_data_new (quality_grade, scale_deg);

-- Phase 2: Atomic swap (dashboards see old data until this instant, then new data)
BEGIN;
DROP MATERIALIZED VIEW IF EXISTS mv_observations_monthly;
DROP MATERIALIZED VIEW IF EXISTS mv_quality_grade_counts;
DROP MATERIALIZED VIEW IF EXISTS mv_top_taxa;
DROP MATERIALIZED VIEW IF EXISTS mv_top_observers;
DROP MATERIALIZED VIEW IF EXISTS mv_photo_licenses;
DROP MATERIALIZED VIEW IF EXISTS mv_observations_by_rank;
-- Note: drop mv_herpetofauna_sar_data BEFORE mv_herpetofauna_sar_grid because the
-- former depends on the latter (built via WITH against the _new variant during phase 1).
-- The dependency only exists during build, but rename order still matters: grid first.
DROP MATERIALIZED VIEW IF EXISTS mv_observations_grid;
DROP MATERIALIZED VIEW IF EXISTS mv_herpetofauna_grid;
DROP MATERIALIZED VIEW IF EXISTS mv_herpetofauna_sar_data;
DROP MATERIALIZED VIEW IF EXISTS mv_herpetofauna_sar_grid;

ALTER MATERIALIZED VIEW mv_observations_monthly_new RENAME TO mv_observations_monthly;
ALTER MATERIALIZED VIEW mv_quality_grade_counts_new RENAME TO mv_quality_grade_counts;
ALTER MATERIALIZED VIEW mv_top_taxa_new RENAME TO mv_top_taxa;
ALTER MATERIALIZED VIEW mv_top_observers_new RENAME TO mv_top_observers;
ALTER MATERIALIZED VIEW mv_photo_licenses_new RENAME TO mv_photo_licenses;
ALTER MATERIALIZED VIEW mv_observations_by_rank_new RENAME TO mv_observations_by_rank;
ALTER MATERIALIZED VIEW mv_observations_grid_new RENAME TO mv_observations_grid;
ALTER MATERIALIZED VIEW mv_herpetofauna_grid_new RENAME TO mv_herpetofauna_grid;
ALTER MATERIALIZED VIEW mv_herpetofauna_sar_grid_new RENAME TO mv_herpetofauna_sar_grid;
ALTER MATERIALIZED VIEW mv_herpetofauna_sar_data_new RENAME TO mv_herpetofauna_sar_data;
COMMIT;

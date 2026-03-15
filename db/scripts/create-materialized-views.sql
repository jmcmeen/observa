-- Materialized views for pre-aggregated dashboard queries
-- These dramatically improve Grafana panel load times on large datasets
--
-- This script is idempotent and should be run once (e.g. after initial import).
-- Subsequent imports use refresh-materialized-views.sql instead.
-- Every view has a UNIQUE INDEX to support REFRESH MATERIALIZED VIEW CONCURRENTLY.

-- Monthly observation counts
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_observations_monthly AS
SELECT date_trunc('month', observed_on) AS month,
       count(*) AS observation_count
FROM observations
WHERE observed_on IS NOT NULL
GROUP BY 1;
CREATE UNIQUE INDEX IF NOT EXISTS uidx_mv_observations_monthly
    ON mv_observations_monthly (month);

-- Quality grade distribution
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_quality_grade_counts AS
SELECT quality_grade, count(*) AS total
FROM observations
WHERE quality_grade IS NOT NULL
GROUP BY quality_grade;
CREATE UNIQUE INDEX IF NOT EXISTS uidx_mv_quality_grade_counts
    ON mv_quality_grade_counts (quality_grade);

-- Top taxa by observation count
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_top_taxa AS
SELECT t.taxon_id, t.name, t.rank, count(*) AS observation_count
FROM observations o
JOIN taxa t ON o.taxon_id = t.taxon_id
GROUP BY t.taxon_id, t.name, t.rank;
CREATE UNIQUE INDEX IF NOT EXISTS uidx_mv_top_taxa
    ON mv_top_taxa (taxon_id);
CREATE INDEX IF NOT EXISTS idx_mv_top_taxa_obs_count
    ON mv_top_taxa (observation_count DESC);

-- Top observers by observation count
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_top_observers AS
SELECT ob.observer_id, ob.login, ob.name, count(*) AS observation_count
FROM observations o
JOIN observers ob ON o.observer_id = ob.observer_id
GROUP BY ob.observer_id, ob.login, ob.name;
CREATE UNIQUE INDEX IF NOT EXISTS uidx_mv_top_observers
    ON mv_top_observers (observer_id);
CREATE INDEX IF NOT EXISTS idx_mv_top_observers_obs_count
    ON mv_top_observers (observation_count DESC);

-- Photo license distribution
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_photo_licenses AS
SELECT license, count(*) AS total
FROM photos
WHERE license IS NOT NULL
GROUP BY license;
CREATE UNIQUE INDEX IF NOT EXISTS uidx_mv_photo_licenses
    ON mv_photo_licenses (license);

-- Observations by taxonomic rank
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_observations_by_rank AS
SELECT t.rank, count(*) AS observation_count
FROM observations o
JOIN taxa t ON o.taxon_id = t.taxon_id
WHERE t.rank IS NOT NULL
GROUP BY t.rank;
CREATE UNIQUE INDEX IF NOT EXISTS uidx_mv_observations_by_rank
    ON mv_observations_by_rank (rank);

-- Geographic grid aggregation (1-degree) for map panels
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_observations_grid AS
SELECT ST_SnapToGrid(geom, 1) AS grid_geom,
       count(*) AS observation_count
FROM observations
WHERE geom IS NOT NULL
GROUP BY 1;
CREATE UNIQUE INDEX IF NOT EXISTS uidx_mv_observations_grid
    ON mv_observations_grid (grid_geom);
CREATE INDEX IF NOT EXISTS idx_mv_observations_grid_geom
    ON mv_observations_grid USING GIST (grid_geom);

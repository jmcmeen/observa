-- Materialized views for pre-aggregated dashboard queries
-- These dramatically improve Grafana panel load times on large datasets

-- Monthly observation counts
DROP MATERIALIZED VIEW IF EXISTS mv_observations_monthly;
CREATE MATERIALIZED VIEW mv_observations_monthly AS
SELECT date_trunc('month', observed_on) AS month,
       count(*) AS observation_count
FROM observations
WHERE observed_on IS NOT NULL
GROUP BY 1;
CREATE UNIQUE INDEX ON mv_observations_monthly (month);

-- Quality grade distribution
DROP MATERIALIZED VIEW IF EXISTS mv_quality_grade_counts;
CREATE MATERIALIZED VIEW mv_quality_grade_counts AS
SELECT quality_grade, count(*) AS total
FROM observations
WHERE quality_grade IS NOT NULL
GROUP BY quality_grade;

-- Top taxa by observation count
DROP MATERIALIZED VIEW IF EXISTS mv_top_taxa;
CREATE MATERIALIZED VIEW mv_top_taxa AS
SELECT t.taxon_id, t.name, t.rank, count(*) AS observation_count
FROM observations o
JOIN taxa t ON o.taxon_id = t.taxon_id
GROUP BY t.taxon_id, t.name, t.rank;
CREATE INDEX ON mv_top_taxa (observation_count DESC);

-- Top observers by observation count
DROP MATERIALIZED VIEW IF EXISTS mv_top_observers;
CREATE MATERIALIZED VIEW mv_top_observers AS
SELECT ob.observer_id, ob.login, ob.name, count(*) AS observation_count
FROM observations o
JOIN observers ob ON o.observer_id = ob.observer_id
GROUP BY ob.observer_id, ob.login, ob.name;
CREATE INDEX ON mv_top_observers (observation_count DESC);

-- Photo license distribution
DROP MATERIALIZED VIEW IF EXISTS mv_photo_licenses;
CREATE MATERIALIZED VIEW mv_photo_licenses AS
SELECT license, count(*) AS total
FROM photos
WHERE license IS NOT NULL
GROUP BY license;

-- Observations by taxonomic rank
DROP MATERIALIZED VIEW IF EXISTS mv_observations_by_rank;
CREATE MATERIALIZED VIEW mv_observations_by_rank AS
SELECT t.rank, count(*) AS observation_count
FROM observations o
JOIN taxa t ON o.taxon_id = t.taxon_id
WHERE t.rank IS NOT NULL
GROUP BY t.rank;

-- Geographic grid aggregation (1-degree) for map panels
DROP MATERIALIZED VIEW IF EXISTS mv_observations_grid;
CREATE MATERIALIZED VIEW mv_observations_grid AS
SELECT ST_SnapToGrid(geom, 1) AS grid_geom,
       count(*) AS observation_count
FROM observations
WHERE geom IS NOT NULL
GROUP BY 1;
CREATE INDEX ON mv_observations_grid USING GIST (grid_geom);

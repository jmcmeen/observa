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

-- Phase 2: Atomic swap (dashboards see old data until this instant, then new data)
BEGIN;
DROP MATERIALIZED VIEW IF EXISTS mv_observations_monthly;
DROP MATERIALIZED VIEW IF EXISTS mv_quality_grade_counts;
DROP MATERIALIZED VIEW IF EXISTS mv_top_taxa;
DROP MATERIALIZED VIEW IF EXISTS mv_top_observers;
DROP MATERIALIZED VIEW IF EXISTS mv_photo_licenses;
DROP MATERIALIZED VIEW IF EXISTS mv_observations_by_rank;
DROP MATERIALIZED VIEW IF EXISTS mv_observations_grid;

ALTER MATERIALIZED VIEW mv_observations_monthly_new RENAME TO mv_observations_monthly;
ALTER MATERIALIZED VIEW mv_quality_grade_counts_new RENAME TO mv_quality_grade_counts;
ALTER MATERIALIZED VIEW mv_top_taxa_new RENAME TO mv_top_taxa;
ALTER MATERIALIZED VIEW mv_top_observers_new RENAME TO mv_top_observers;
ALTER MATERIALIZED VIEW mv_photo_licenses_new RENAME TO mv_photo_licenses;
ALTER MATERIALIZED VIEW mv_observations_by_rank_new RENAME TO mv_observations_by_rank;
ALTER MATERIALIZED VIEW mv_observations_grid_new RENAME TO mv_observations_grid;
COMMIT;

-- Create empty materialized views so Grafana panels load before the first import.
-- The importer will DROP and recreate these with real data after each successful import.

CREATE MATERIALIZED VIEW mv_observations_monthly AS
SELECT null::timestamptz AS month, 0::bigint AS observation_count WHERE false;
CREATE UNIQUE INDEX ON mv_observations_monthly (month);

CREATE MATERIALIZED VIEW mv_quality_grade_counts AS
SELECT null::varchar AS quality_grade, 0::bigint AS total WHERE false;
CREATE UNIQUE INDEX ON mv_quality_grade_counts (quality_grade);

CREATE MATERIALIZED VIEW mv_top_taxa AS
SELECT null::integer AS taxon_id, null::varchar AS name, null::varchar AS rank, 0::bigint AS observation_count WHERE false;
CREATE UNIQUE INDEX ON mv_top_taxa (taxon_id);

CREATE MATERIALIZED VIEW mv_top_observers AS
SELECT null::integer AS observer_id, null::varchar AS login, null::varchar AS name, 0::bigint AS observation_count WHERE false;
CREATE UNIQUE INDEX ON mv_top_observers (observer_id);

CREATE MATERIALIZED VIEW mv_photo_licenses AS
SELECT null::varchar AS license, 0::bigint AS total WHERE false;
CREATE UNIQUE INDEX ON mv_photo_licenses (license);

CREATE MATERIALIZED VIEW mv_observations_by_rank AS
SELECT null::varchar AS rank, 0::bigint AS observation_count WHERE false;
CREATE UNIQUE INDEX ON mv_observations_by_rank (rank);

CREATE MATERIALIZED VIEW mv_observations_grid AS
SELECT null::geometry AS grid_geom, 0::bigint AS observation_count WHERE false;
CREATE UNIQUE INDEX ON mv_observations_grid (grid_geom);

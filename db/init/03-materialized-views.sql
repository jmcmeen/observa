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

-- Herpetofauna density grid (Amphibia + Reptilia) — backs the Herpetofauna dashboard
-- Observation Density Map. Uses 0.5 degree cells (~55 km at mid-latitudes), grouped
-- by quality_grade so the dashboard's quality template variable still works.
CREATE MATERIALIZED VIEW mv_herpetofauna_grid AS
SELECT null::geometry AS grid_geom, null::varchar AS quality_grade, 0::bigint AS observation_count WHERE false;
CREATE UNIQUE INDEX ON mv_herpetofauna_grid (grid_geom, quality_grade);

-- Herpetofauna SAR grid (Amphibia + Reptilia) — backs the Multi-Scale Species-Area
-- Aggregation panels. Stores per-cell taxon_id arrays at 0.1 degree resolution so the
-- dashboard can compute species richness at coarser scales (0.2/0.4/0.8/1.6) by union
-- of arrays without re-scanning observations. Filters to t.rank='species' since SAR
-- is fit on species counts only.
--
-- The per-group taxa columns (amphibia_taxa, reptilia_taxa, anura_taxa, caudata_taxa,
-- testudines_taxa, serpentes_taxa) allow per-group SAR panels to skip the species
-- filtering subquery entirely — they unnest the appropriate group column directly,
-- which is faster than filtering the all-herp taxon_ids array per query.
CREATE MATERIALIZED VIEW mv_herpetofauna_sar_grid AS
SELECT null::geometry AS grid_geom,
       null::varchar AS quality_grade,
       '{}'::int[] AS taxon_ids,
       '{}'::int[] AS amphibia_taxa,
       '{}'::int[] AS reptilia_taxa,
       '{}'::int[] AS anura_taxa,
       '{}'::int[] AS caudata_taxa,
       '{}'::int[] AS testudines_taxa,
       '{}'::int[] AS serpentes_taxa,
       0::bigint AS observation_count WHERE false;
CREATE UNIQUE INDEX ON mv_herpetofauna_sar_grid (grid_geom, quality_grade);

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

-- Herpetofauna SAR grid (Amphibia + Reptilia) — base MV at 0.1 degree resolution.
-- Stores per-cell taxon_id arrays plus per-group sub-arrays so coarser scales and
-- per-group species counts can be derived without re-scanning the 233M-row
-- observations table. Filters to t.rank='species' since SAR is fit on species counts.
-- This is a building block for mv_herpetofauna_sar_data (below), not queried by
-- dashboards directly.
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

-- Herpetofauna SAR data — fully pre-aggregated multi-scale grid backing the
-- Multi-Scale Species-Area Aggregation panel. One row per (scale, cell, quality_grade)
-- with cell area in km² (geodesic, computed via ST_Area on the WGS84 geography type)
-- and species counts broken out per taxonomic group. Built by aggregating
-- mv_herpetofauna_sar_grid across 5 scales: 0.1° / 0.2° / 0.4° / 0.8° / 1.6°.
-- Backs the SAR panel directly with sub-second queries (~130ms vs ~13s for the
-- equivalent inline aggregation).
CREATE MATERIALIZED VIEW mv_herpetofauna_sar_data AS
SELECT null::float AS scale_deg,
       null::geometry AS grid_geom,
       null::varchar AS quality_grade,
       null::float AS cell_area_km2,
       0::bigint AS total_species,
       0::bigint AS amphibia_species,
       0::bigint AS reptilia_species,
       0::bigint AS anura_species,
       0::bigint AS caudata_species,
       0::bigint AS testudines_species,
       0::bigint AS serpentes_species WHERE false;
CREATE UNIQUE INDEX ON mv_herpetofauna_sar_data (scale_deg, grid_geom, quality_grade);

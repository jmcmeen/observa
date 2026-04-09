# Data Model Reference

This document describes the tables, columns, relationships, and materialized views in the Observa database. Understanding this model is essential for writing useful queries and CSV exports.

> **Need a terse machine-readable reference?** See [schema-definition.md](schema-definition.md) — it has the same tables in compact tabular form, plus RPC function signatures, a useful iNaturalist taxon ID lookup, a gotchas section, and Grafana macro reference. It's designed to be loaded as context by LLM coding assistants when writing SQL.

## Entity relationship

```
observers 1──M observations M──1 taxa
                   │
                   1
                   │
                   M
                 photos
```

- An **observer** has many **observations**
- A **taxon** has many **observations**
- An **observation** has many **photos**

There are no enforced foreign keys in the schema (the data comes from upstream CSVs), but the relationships hold in practice. Join on `observer_id`, `taxon_id`, and `observation_uuid`.

## Tables

### observations

The core table. Each row is a single iNaturalist observation — one person saw one organism at one place and time.

| Column | Type | Description |
|---|---|---|
| `observation_uuid` | uuid (PK) | Unique identifier from iNaturalist |
| `observer_id` | integer | FK to `observers.observer_id` |
| `latitude` | numeric(15,10) | WGS 84 latitude |
| `longitude` | numeric(15,10) | WGS 84 longitude |
| `positional_accuracy` | integer | GPS accuracy in meters. NULL means unknown. Lower is better — filter to `< 100` for precise locations |
| `taxon_id` | integer | FK to `taxa.taxon_id`. NULL if the observation hasn't been identified |
| `quality_grade` | varchar | One of three values (see below) |
| `observed_on` | date | When the organism was observed |
| `anomaly_score` | double precision | iNaturalist's model-based anomaly score. Higher values suggest unusual sightings for the location |
| `geom` | geometry(Point, 4326) | PostGIS point, auto-generated from lat/lon. Used for spatial queries and map panels |

**Approximate row count:** ~200 million

#### quality_grade values

| Value | Meaning | Use case |
|---|---|---|
| `research` | Community-verified identification with date, location, and photo. The most reliable observations | Scientific analysis, species distribution maps |
| `needs_id` | Has media and location but identification not yet confirmed by the community | Broader surveys where coverage matters more than certainty |
| `casual` | Missing date, location, or media, or flagged by the community | Usually excluded from analysis |

For most analytical work, filter to `quality_grade = 'research'`.

### taxa

Taxonomic information for every organism identified on iNaturalist.

| Column | Type | Description |
|---|---|---|
| `taxon_id` | integer (PK) | iNaturalist taxon ID |
| `ancestry` | varchar | Slash-separated path of ancestor `taxon_id` values (e.g., `48460/1/2/355675/3`) |
| `rank_level` | double precision | Numeric level in the hierarchy (higher = broader). See below |
| `rank` | varchar | Taxonomic rank name (e.g., `species`, `genus`, `family`) |
| `name` | varchar | Scientific name. Supports trigram search via GIN index |
| `active` | boolean | Whether this taxon is currently accepted in iNaturalist's taxonomy |

**Approximate row count:** ~1.6 million

#### rank_level values

| rank_level | rank | Example |
|---|---|---|
| 70 | kingdom | Animalia |
| 60 | phylum | Chordata |
| 50 | class | Aves |
| 40 | order | Passeriformes |
| 30 | family | Turdidae |
| 20 | genus | Turdus |
| 10 | species | Turdus migratorius |
| 5 | subspecies | Turdus migratorius migratorius |

#### Using ancestry for taxonomic filtering

The `ancestry` column encodes the full path from kingdom to parent as a slash-separated list (e.g. `48460/1/3` for a direct child of Aves). To find all observations of birds (Aves, taxon_id 3) **including direct children whose ancestry ends in `/3`**, use the wrapped-delimiter pattern:

```sql
SELECT o.*
FROM observations o
JOIN taxa t ON o.taxon_id = t.taxon_id
WHERE ('/' || COALESCE(t.ancestry, '') || '/') LIKE '%/3/%'
   OR t.taxon_id = 3;
```

This matches any taxon that has Aves (3) anywhere in its ancestry chain — species, genera, families, and orders within birds.

> **Why the wrapping?** The naive pattern `t.ancestry LIKE '%/3/%'` misses direct children of Aves whose ancestry string ends with `/3` (no trailing slash). Wrapping both ends with `/` before matching ensures every position is checked. Always use the wrapped form when the target taxon may have direct child taxa.

### photos

Metadata for observation photos. Does not contain the actual image data.

| Column | Type | Description |
|---|---|---|
| `photo_uuid` | uuid | Unique photo identifier |
| `photo_id` | integer (PK) | iNaturalist photo ID (used as primary key) |
| `observation_uuid` | uuid | FK to `observations.observation_uuid` |
| `observer_id` | integer | FK to `observers.observer_id` |
| `extension` | varchar(5) | File extension (e.g., `jpeg`, `png`) |
| `license` | varchar | Creative Commons license code (e.g., `CC-BY`, `CC0`, `CC-BY-NC`) |
| `width` | smallint | Image width in pixels |
| `height` | smallint | Image height in pixels |
| `position` | smallint | Display order within the observation (0 = primary photo) |

**Approximate row count:** ~350 million

Photo URLs can be constructed from `photo_id` and `extension`:
```
https://inaturalist-open-data.s3.amazonaws.com/photos/{photo_id}/medium.{extension}
```

### observers

People who submitted observations.

| Column | Type | Description |
|---|---|---|
| `observer_id` | integer (PK) | iNaturalist user ID |
| `login` | varchar | Username/handle |
| `name` | varchar | Display name (may be NULL) |

**Approximate row count:** ~3 million

### import_log

Internal table tracking each ETL run. Useful for debugging and monitoring.

| Column | Type | Description |
|---|---|---|
| `id` | serial (PK) | Auto-incrementing run ID |
| `started_at` | timestamptz | When the import began |
| `finished_at` | timestamptz | When the import ended (NULL if still running) |
| `status` | varchar(20) | `running`, `completed`, or `failed` |
| `observations_count` | bigint | Row count after import |
| `photos_count` | bigint | Row count after import |
| `taxa_count` | bigint | Row count after import |
| `observers_count` | bigint | Row count after import |
| `error_message` | text | Error details on failure |
| `duration_seconds` | integer | Total import time |

## Materialized views

Pre-aggregated views refreshed after each import. These are fast to query and export since the heavy joins and grouping are already done.

### mv_top_taxa

Taxa ranked by observation count. Includes a descending index on `observation_count` for fast top-N queries.

```sql
SELECT taxon_id, name, rank, observation_count
FROM mv_top_taxa
WHERE rank = 'species'
ORDER BY observation_count DESC
LIMIT 100;
```

### mv_top_observers

Observers ranked by observation count.

```sql
SELECT observer_id, login, name, observation_count
FROM mv_top_observers
ORDER BY observation_count DESC
LIMIT 100;
```

### mv_observations_monthly

Monthly observation counts. Useful for trend analysis and seasonality.

```sql
SELECT month, observation_count
FROM mv_observations_monthly
ORDER BY month;
```

### mv_quality_grade_counts

Observation counts by quality grade (`research`, `needs_id`, `casual`).

### mv_photo_licenses

Photo counts by license type. Useful for understanding what's available under open licenses.

### mv_observations_by_rank

Observation counts grouped by taxonomic rank (`species`, `genus`, `family`, etc.).

### mv_observations_grid

Geographic observation density aggregated to a 1-degree grid using PostGIS `ST_SnapToGrid`. Has a GIST spatial index for map queries.

## Indexes

The following indexes support common query patterns:

| Index | Table | Columns | Type |
|---|---|---|---|
| Primary keys | all tables | see above | B-tree |
| idx_observations_taxon_id | observations | taxon_id | B-tree |
| idx_observations_observer_id | observations | observer_id | B-tree |
| idx_observations_quality_grade | observations | quality_grade | B-tree |
| idx_observations_observed_on | observations | observed_on | B-tree |
| idx_observations_geom | observations | geom | GIST (spatial) |
| idx_observations_taxon_quality | observations | taxon_id, quality_grade | B-tree (composite) |
| idx_observations_date_taxon | observations | observed_on, taxon_id | B-tree (composite) |
| idx_photos_observation_uuid | photos | observation_uuid | B-tree |
| idx_photos_observer_id | photos | observer_id | B-tree |
| idx_taxa_name_trgm | taxa | name | GIN (trigram) |
| idx_observers_login | observers | login | B-tree |

### Composite indexes and query planning

The composite indexes exist to support common filter combinations without requiring index intersection:

- **taxon_quality** — queries like "all research-grade observations of taxon X" use this directly
- **date_taxon** — queries like "observations of taxon X in 2025" use this directly

### Trigram search on taxa names

The GIN trigram index on `taxa.name` supports fuzzy and substring matching:

```sql
-- Substring search (uses the trigram index)
SELECT * FROM taxa WHERE name ILIKE '%robin%';

-- Similarity search
SELECT *, similarity(name, 'Turdus migratoris') AS sim
FROM taxa
WHERE name % 'Turdus migratoris'
ORDER BY sim DESC
LIMIT 10;
```

## Common query patterns

### Observations with species names

```sql
SELECT o.observation_uuid, o.observed_on, o.latitude, o.longitude,
       t.name AS species, t.rank
FROM observations o
JOIN taxa t ON o.taxon_id = t.taxon_id
WHERE o.quality_grade = 'research'
  AND t.rank = 'species';
```

### Observations in a geographic area

```sql
-- Bounding box
SELECT * FROM observations
WHERE latitude BETWEEN 10.0 AND 11.0
  AND longitude BETWEEN -84.5 AND -83.5;

-- Radius search using PostGIS (within 10km of a point)
SELECT * FROM observations
WHERE ST_DWithin(
    geom,
    ST_SetSRID(ST_MakePoint(-83.98, 10.43), 4326),
    0.09  -- approximately 10km in degrees
);
```

### Species list for an area

```sql
SELECT DISTINCT t.name, t.rank, count(*) AS obs_count
FROM observations o
JOIN taxa t ON o.taxon_id = t.taxon_id
WHERE o.quality_grade = 'research'
  AND o.latitude BETWEEN 10.0 AND 11.0
  AND o.longitude BETWEEN -84.5 AND -83.5
  AND t.rank = 'species'
GROUP BY t.name, t.rank
ORDER BY obs_count DESC;
```

### Seasonal activity for a taxon

```sql
SELECT EXTRACT(MONTH FROM observed_on) AS month, count(*) AS observations
FROM observations
WHERE taxon_id = 3726
  AND quality_grade = 'research'
  AND observed_on IS NOT NULL
GROUP BY 1
ORDER BY 1;
```

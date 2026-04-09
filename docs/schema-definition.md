# Observa Schema Definition

A query-reference cheat sheet for the Observa PostgreSQL/PostGIS database. This document is intentionally terse and structured so that humans (and LLM coding assistants) can use it as authoritative context when writing SQL against the database.

> **Looking for the human-friendly tour?** See [data-model.md](data-model.md) — it has the ER diagram, prose explanations of each table, worked query examples, and the rank_level walkthrough. This file is the source of truth for **what exists**; that file is the source of truth for **how to think about it**.

## Database

- **Engine:** PostgreSQL 16 + PostGIS 3.4
- **Extensions:** `postgis`, `pg_trgm`, `pg_stat_statements`
- **Default schema:** `public`
- **Datasource UID in Grafana:** `inaturalist` (type `postgres`)

## Tables

### `observations`
Core table — one row per iNaturalist observation.

| Column | Type | Notes |
|---|---|---|
| `observation_uuid` | `uuid` PK | iNaturalist UUID |
| `observer_id` | `integer` | Logical FK → `observers.observer_id` (not enforced) |
| `latitude` | `numeric(15,10)` | WGS 84; nullable |
| `longitude` | `numeric(15,10)` | WGS 84; nullable |
| `positional_accuracy` | `integer` | meters; nullable |
| `taxon_id` | `integer` | Logical FK → `taxa.taxon_id`; nullable |
| `quality_grade` | `varchar(255)` | `'research'` \| `'needs_id'` \| `'casual'` |
| `observed_on` | `date` | nullable |
| `anomaly_score` | `double precision` | iNat model score |
| `geom` | `geometry(Point, 4326)` | **Generated stored** from `longitude`/`latitude`; NULL if either coordinate is NULL |

Approx. row count: ~233M.

### `taxa`
Taxonomic information for every taxon referenced by observations.

| Column | Type | Notes |
|---|---|---|
| `taxon_id` | `integer` PK | iNaturalist taxon ID |
| `ancestry` | `varchar(255)` | Slash-separated ancestor chain, e.g. `48460/1/26036`. Last element is the direct parent. May be NULL or empty for root taxa |
| `rank_level` | `double precision` | Numeric rank; higher = broader. Kingdom=70, phylum=60, class=50, order=40, family=30, genus=20, species=10, subspecies=5 |
| `rank` | `varchar(255)` | Rank name (`kingdom`, `phylum`, `class`, `order`, `family`, `genus`, `species`, ...) |
| `name` | `varchar(255)` | Scientific name. Indexed with GIN trigrams |
| `active` | `boolean` | Currently accepted in iNat taxonomy |
| `parent_id` | `integer` | **Generated stored** — last element of `ancestry` cast to int |

Approx. row count: ~1.6M.

> **No `iconic_taxon_name` column exists.** Code that joins on `t.iconic_taxon_name = 'Amphibia'` is broken. Use ancestry filtering instead — see [Canonical idioms](#canonical-idioms).

### `photos`
Photo metadata (no image bytes).

| Column | Type | Notes |
|---|---|---|
| `photo_uuid` | `uuid` | iNat photo UUID |
| `photo_id` | `integer` PK | iNat photo ID — **this is the primary key**, not `photo_uuid` |
| `observation_uuid` | `uuid` | Logical FK → `observations.observation_uuid` |
| `observer_id` | `integer` | Logical FK → `observers.observer_id` |
| `extension` | `varchar(5)` | e.g. `jpeg`, `png` |
| `license` | `varchar(255)` | CC license code |
| `width` | `smallint` | px |
| `height` | `smallint` | px |
| `position` | `smallint` | Display order; 0 = primary |

Approx. row count: ~350M.

### `observers`

| Column | Type | Notes |
|---|---|---|
| `observer_id` | `integer` PK | iNat user ID |
| `login` | `varchar(255)` | Username |
| `name` | `varchar(255)` | Display name; nullable |

Approx. row count: ~3M.

### `import_log`
Internal — one row per ETL run.

| Column | Type | Notes |
|---|---|---|
| `id` | `serial` PK | |
| `started_at` | `timestamptz` | |
| `finished_at` | `timestamptz` | NULL while running |
| `status` | `varchar(20)` | `'running'` \| `'completed'` \| `'failed'` |
| `observations_count` | `bigint` | |
| `photos_count` | `bigint` | |
| `taxa_count` | `bigint` | |
| `observers_count` | `bigint` | |
| `error_message` | `text` | |
| `duration_seconds` | `integer` | |

### `import_stats`
Internal — post-import data profiling stats. Columns: `id`, `import_id` (FK → `import_log.id`), `null_taxon_pct`, `null_location_pct`, `null_observed_on_pct`, `min_observed_on`, `max_observed_on`, `quality_research`, `quality_needs_id`, `quality_casual`, `bbox_min_lat`, `bbox_max_lat`, `bbox_min_lon`, `bbox_max_lon`, `created_at`.

## Materialized views

All MVs are rebuilt and atomically swapped at the end of each successful import.

| View | Columns | Purpose |
|---|---|---|
| `mv_observations_monthly` | `month timestamptz`, `observation_count bigint` | Monthly trend |
| `mv_quality_grade_counts` | `quality_grade varchar`, `total bigint` | Quality grade breakdown |
| `mv_top_taxa` | `taxon_id integer`, `name varchar`, `rank varchar`, `observation_count bigint` | Most-observed taxa. Indexed `observation_count DESC` |
| `mv_top_observers` | `observer_id integer`, `login varchar`, `name varchar`, `observation_count bigint` | Most active observers |
| `mv_photo_licenses` | `license varchar`, `total bigint` | License distribution |
| `mv_observations_by_rank` | `rank varchar`, `observation_count bigint` | Counts by taxonomic rank |
| `mv_observations_grid` | `grid_geom geometry`, `observation_count bigint` | 1° spatial grid via `ST_SnapToGrid(geom, 1)`. GIST indexed |

> **Use MVs whenever possible** — they're orders of magnitude faster than raw aggregation against the 233M-row `observations` table.

## Views

### `v_health`
Single-row view summarizing the most recent terminal import (status `completed` or `failed`). Columns: `last_import_status`, `last_import_at`, `hours_since_import`, `observations_count`, `photos_count`, `taxa_count`, `observers_count`, `last_import_duration_seconds`, `last_error`. Exposed via PostgREST.

## RPC functions (PostgREST-exposed)

| Function | Signature | Returns |
|---|---|---|
| `observations_near` | `(lat double precision, lon double precision, radius_km double precision DEFAULT 10, lim integer DEFAULT 100)` | `(observation_uuid, taxon_id, quality_grade, observed_on, distance_m)` |
| `taxa_search` | `(query text, lim integer DEFAULT 20)` | `(taxon_id, name, rank, rank_level, active, similarity)` — pg_trgm fuzzy match |
| `taxon_lineage` | `(target_taxon_id integer)` | `(taxon_id, name, rank, rank_level, depth)` — recursive ancestry walk |
| `taxon_children` | `(parent_id integer, lim integer DEFAULT 100)` | `(taxon_id, name, rank, rank_level, observation_count)` — direct children with counts |

## Indexes

| Index | Table | Definition |
|---|---|---|
| `observations_pkey` | `observations` | `(observation_uuid)` B-tree |
| `idx_observations_taxon_id` | `observations` | `(taxon_id)` B-tree |
| `idx_observations_observer_id` | `observations` | `(observer_id)` B-tree |
| `idx_observations_quality_grade` | `observations` | `(quality_grade)` B-tree |
| `idx_observations_observed_on` | `observations` | `(observed_on)` B-tree |
| `idx_observations_geom` | `observations` | `(geom)` GIST |
| `idx_observations_taxon_quality` | `observations` | `(taxon_id, quality_grade)` B-tree composite |
| `idx_observations_date_taxon` | `observations` | `(observed_on, taxon_id)` B-tree composite |
| `idx_photos_observation_uuid` | `photos` | `(observation_uuid)` B-tree |
| `idx_photos_observer_id` | `photos` | `(observer_id)` B-tree |
| `idx_taxa_name_trgm` | `taxa` | `(name)` GIN trigram |
| `idx_observers_login` | `observers` | `(login)` B-tree |
| `idx_import_log_status_id` | `import_log` | `(status, id DESC)` |
| `idx_import_log_started_at` | `import_log` | `(started_at DESC)` |

## Canonical idioms

### Filtering by taxonomic group via ancestry

The `ancestry` column stores ancestor `taxon_id` values separated by `/`. To match a target taxon **and all its descendants**, use the wrapped-delimiter pattern — it correctly handles direct children whose ancestry ends with the target ID:

```sql
WHERE (('/' || COALESCE(t.ancestry, '') || '/') LIKE '%/' || :target_id || '/%'
       OR t.taxon_id = :target_id)
```

The naive `t.ancestry LIKE '%/X/%'` pattern (used in some older Observa dashboards) **misses direct children** whose ancestry ends in `/X` with no trailing slash. Prefer the wrapped form.

### Useful iNaturalist taxon IDs

These are the canonical iNat taxon IDs for major groups, useful for ancestry filtering. They are stable across imports.

| Taxon | ID | Rank |
|---|---|---|
| Life | 48460 | (root) |
| Animalia | 1 | kingdom |
| Plantae | 47126 | kingdom |
| Fungi | 47170 | kingdom |
| Chordata | 2 | phylum |
| Aves (birds) | 3 | class |
| Mammalia | 40151 | class |
| Reptilia | 26036 | class |
| Amphibia | 20978 | class |
| Actinopterygii (ray-finned fish) | 47178 | class |
| Insecta | 47158 | class |
| Arachnida | 47119 | class |
| Mollusca | 47115 | phylum |
| Anura (frogs) | 20979 | order |
| Squamata (lizards & snakes) | 85553 | order |
| Testudines (turtles) | 39532 | order |

### Filter to research-grade only

```sql
WHERE quality_grade = 'research'
```

For most ecological analysis this is the right default. `needs_id` is useful for broad surveys; `casual` is usually excluded.

### Finding the family-rank ancestor of an observation's taxon

Direct `parent_id` is **not** the family for species — it's the genus. To find the family ancestor, traverse `ancestry`:

```sql
WITH obs_ancestors AS (
  SELECT o.observation_uuid,
         string_to_array(t.ancestry, '/')::int[] AS ancestors
  FROM observations o
  JOIN taxa t ON o.taxon_id = t.taxon_id
  WHERE t.ancestry IS NOT NULL AND t.ancestry <> ''
)
SELECT fam.name AS family, count(*) AS obs_count
FROM obs_ancestors oa
JOIN taxa fam ON fam.taxon_id = ANY(oa.ancestors)
WHERE fam.rank = 'family'
GROUP BY fam.name
ORDER BY obs_count DESC;
```

The same pattern works for any rank — substitute `'family'` for `'order'`, `'genus'`, etc.

### Spatial queries

```sql
-- Bounding box (uses lat/lon range, fast with B-tree on observed_on, etc.)
WHERE latitude BETWEEN :min_lat AND :max_lat
  AND longitude BETWEEN :min_lon AND :max_lon

-- Radius search using PostGIS (uses GIST index on geom)
WHERE ST_DWithin(
    geom::geography,
    ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography,
    :radius_meters
)
```

Note: `geom` is NULL when latitude or longitude is NULL — add `geom IS NOT NULL` for spatial joins.

### Photo URL construction

Photos are not stored locally. Construct URLs from `photo_id` and `extension`:

```
https://inaturalist-open-data.s3.amazonaws.com/photos/{photo_id}/medium.{extension}
```

Sizes: `square`, `small`, `medium`, `large`, `original`.

### Grafana macros

When writing dashboard queries, use these Grafana macros for time filtering:

- `$__timeFilter(o.observed_on)` — expands to `o.observed_on BETWEEN '...' AND '...'`
- `${var:sqlstring}` — quotes a multi-select var as comma-separated SQL strings, e.g. `IN (${quality:sqlstring})`

## Gotchas

1. **No enforced foreign keys.** Joins always succeed but rows may not match — use `LEFT JOIN` and `IS NOT NULL` checks if you care about completeness.
2. **`observed_on` is nullable.** Filter `observed_on IS NOT NULL` for any time-bounded query.
3. **`taxon_id` is nullable.** ~5–10% of observations have no identification.
4. **`geom` is generated stored.** It's NULL whenever either coordinate is NULL — never insert into it.
5. **`photos.photo_id` is the PK**, not `photo_uuid`. Joins to `photos` should use `observation_uuid` to link back to observations.
6. **Materialized views are rebuilt by drop-and-swap**, not `REFRESH MATERIALIZED VIEW`. Don't reference them inside long-running transactions across import boundaries.
7. **`taxa.parent_id` is generated** from `ancestry`. Don't update it directly.
8. **Ancestry can be NULL or empty** for root taxa — always use `COALESCE(t.ancestry, '')` in LIKE patterns.
9. **The `iconic_taxon_name` column does not exist.** Filter taxonomic classes via ancestry on `taxon_id = 20978` (Amphibia), `26036` (Reptilia), `3` (Aves), `40151` (Mammalia), etc.

# CSV Export Guide

Observa stores the full iNaturalist Open Dataset in PostgreSQL, making it straightforward to export filtered subsets as CSV files for use in R, Python, Excel, QGIS, or any other tool that reads CSV.

There are three ways to export data, depending on what you need:

| Method | Best for | Requires |
|---|---|---|
| [PostgREST API](#postgrest-api) | Filtered exports, scripting, automation | `curl` (services running) |
| [psql \COPY](#psql-copy) | Custom queries, joins, full SQL control | `psql` (or `docker compose exec`) |
| [export.sh](#exportsh) | Quick full-table dumps | `docker compose exec` |

## Available tables and views

### Tables

| Table | Key columns | Rows (approx.) |
|---|---|---|
| `observations` | `observation_uuid`, `observer_id`, `latitude`, `longitude`, `taxon_id`, `quality_grade`, `observed_on` | ~200M |
| `taxa` | `taxon_id`, `name`, `rank`, `ancestry`, `active` | ~1.6M |
| `observers` | `observer_id`, `login`, `name` | ~3M |
| `photos` | `photo_id`, `observation_uuid`, `observer_id`, `license`, `extension`, `width`, `height` | ~350M |

### Materialized views (pre-aggregated)

| View | Description |
|---|---|
| `mv_top_taxa` | Taxa ranked by observation count |
| `mv_top_observers` | Observers ranked by observation count |
| `mv_observations_monthly` | Monthly observation counts |
| `mv_quality_grade_counts` | Observation counts by quality grade |
| `mv_photo_licenses` | Photo counts by license type |
| `mv_observations_by_rank` | Observation counts by taxonomic rank |
| `mv_observations_grid` | 1-degree geographic grid aggregation |

These views are refreshed after each import and can be exported just like tables.

## PostgREST API

The REST API at `http://localhost:3001` returns CSV when you set the `Accept: text/csv` header. This is the easiest method for filtered exports and scripting.

### Basic usage

```bash
# Export all taxa as CSV
curl -H "Accept: text/csv" "http://localhost:3001/taxa" > taxa.csv

# Export first 1000 observations
curl -H "Accept: text/csv" "http://localhost:3001/observations?limit=1000" > sample.csv
```

### Filtering

PostgREST uses query parameters for filtering. Common operators:

| Operator | Meaning | Example |
|---|---|---|
| `eq` | Equals | `quality_grade=eq.research` |
| `neq` | Not equals | `quality_grade=neq.casual` |
| `gt`, `gte` | Greater than (or equal) | `observed_on=gte.2025-01-01` |
| `lt`, `lte` | Less than (or equal) | `observed_on=lte.2025-12-31` |
| `like` | Pattern match (% wildcard) | `name=like.*robin*` |
| `ilike` | Case-insensitive pattern | `name=ilike.*Robin*` |
| `in` | In list | `quality_grade=in.(research,needs_id)` |
| `is` | Is null/not null | `latitude=is.null` |

### Selecting specific columns

Use the `select` parameter to return only the columns you need:

```bash
curl -H "Accept: text/csv" \
  "http://localhost:3001/observations?select=observation_uuid,taxon_id,observed_on,latitude,longitude&limit=5000" > slim.csv
```

### Example exports

**Research-grade observations for a specific taxon:**

```bash
curl -H "Accept: text/csv" \
  "http://localhost:3001/observations?taxon_id=eq.3726&quality_grade=eq.research&select=observation_uuid,observed_on,latitude,longitude" \
  > taxon_3726_research.csv
```

**Observations within a bounding box:**

```bash
curl -H "Accept: text/csv" \
  "http://localhost:3001/observations?latitude=gte.10.0&latitude=lte.11.0&longitude=gte.-84.5&longitude=lte.-83.5" \
  > costa_rica_bbox.csv
```

**Observations within a date range:**

```bash
curl -H "Accept: text/csv" \
  "http://localhost:3001/observations?observed_on=gte.2025-01-01&observed_on=lte.2025-12-31" \
  > year_2025.csv
```

**Top 100 most-observed species:**

```bash
curl -H "Accept: text/csv" \
  "http://localhost:3001/mv_top_taxa?rank=eq.species&order=observation_count.desc&limit=100" \
  > top_species.csv
```

**Monthly observation counts:**

```bash
curl -H "Accept: text/csv" \
  "http://localhost:3001/mv_observations_monthly?order=month.asc" \
  > monthly_counts.csv
```

**Photo license breakdown:**

```bash
curl -H "Accept: text/csv" \
  "http://localhost:3001/mv_photo_licenses?order=total.desc" \
  > licenses.csv
```

### Pagination for large exports

PostgREST returns all matching rows by default, but very large result sets may be slow. You can paginate with `limit` and `offset`:

```bash
# First 50,000 rows
curl -H "Accept: text/csv" \
  "http://localhost:3001/observations?quality_grade=eq.research&limit=50000&offset=0" > batch_1.csv

# Next 50,000
curl -H "Accept: text/csv" \
  "http://localhost:3001/observations?quality_grade=eq.research&limit=50000&offset=50000" > batch_2.csv
```

For very large filtered exports (millions of rows), consider using `psql \COPY` instead.

## psql COPY

For full SQL control — joins, aggregations, window functions, or exporting millions of rows — use `psql` with the `\COPY` command.

### From inside the Docker network

```bash
docker compose exec postgres psql -U observa -d inaturalist -c \
  "\COPY (SELECT * FROM observations WHERE quality_grade = 'research' AND observed_on >= '2025-01-01') TO '/tmp/export.csv' WITH (FORMAT csv, HEADER true)"

# Copy the file out of the container
docker cp $(docker compose ps -q postgres):/tmp/export.csv .
```

### From a local psql client

If you have `psql` installed on the host:

```bash
psql -h localhost -U observa -d inaturalist -c \
  "\COPY (SELECT * FROM observations WHERE quality_grade = 'research' LIMIT 100000) TO 'research.csv' WITH (FORMAT csv, HEADER true)"
```

### Examples with joins

**Observations with species names:**

```bash
docker compose exec postgres psql -U observa -d inaturalist -c \
  "\COPY (
    SELECT o.observation_uuid, o.observed_on, o.latitude, o.longitude,
           o.quality_grade, t.name AS species_name, t.rank
    FROM observations o
    JOIN taxa t ON o.taxon_id = t.taxon_id
    WHERE t.rank = 'species' AND o.quality_grade = 'research'
    LIMIT 100000
  ) TO '/tmp/obs_with_names.csv' WITH (FORMAT csv, HEADER true)"

docker cp $(docker compose ps -q postgres):/tmp/obs_with_names.csv .
```

**Observations with observer login and photo count:**

```bash
docker compose exec postgres psql -U observa -d inaturalist -c \
  "\COPY (
    SELECT o.observation_uuid, o.observed_on, o.latitude, o.longitude,
           ob.login, count(p.photo_id) AS photo_count
    FROM observations o
    JOIN observers ob ON o.observer_id = ob.observer_id
    LEFT JOIN photos p ON o.observation_uuid = p.observation_uuid
    WHERE o.observed_on >= '2025-01-01'
    GROUP BY o.observation_uuid, o.observed_on, o.latitude, o.longitude, ob.login
    LIMIT 50000
  ) TO '/tmp/obs_with_photos.csv' WITH (FORMAT csv, HEADER true)"

docker cp $(docker compose ps -q postgres):/tmp/obs_with_photos.csv .
```

## export.sh

The built-in `export.sh` script dumps an entire table to CSV or GeoJSON. It does not support filtering.

```bash
# Export full taxa table
docker compose exec importer sh /scripts/export.sh csv taxa /data
docker cp $(docker compose ps -q importer):/data/taxa_export.csv .

# Export full observers table
docker compose exec importer sh /scripts/export.sh csv observers /data
docker cp $(docker compose ps -q importer):/data/observers_export.csv .

# Export observations as GeoJSON (limited to 10,000 features)
docker compose exec importer sh /scripts/export.sh geojson observations /data
docker cp $(docker compose ps -q importer):/data/observations_export.geojson .
```

Valid tables: `observations`, `photos`, `taxa`, `observers`.

## Tips

- **Start with materialized views** if you need aggregated data — they're small and fast to export.
- **Use `select` in PostgREST** to limit columns. Fewer columns = smaller files and faster exports.
- **Use `psql \COPY` for joins** — PostgREST queries single tables/views. If you need data from multiple tables in one CSV, use SQL.
- **Watch memory on full-table exports** — the observations table has ~200M rows. Export in batches or add filters to avoid running out of memory or disk.
- **Tab-separated output** is supported by `psql \COPY` if your downstream tool prefers TSV: replace `FORMAT csv` with `FORMAT csv, DELIMITER E'\t'`.

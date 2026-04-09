# Changelog

All notable changes to this project will be documented in this file.

## v0.2.1 — 2026-04-09

### Features

- **Herpetofauna dashboard** — New Grafana dashboard for amphibian and reptile observations: total/per-class observation counts, unique species, monthly trends by class, cumulative species discovered, seasonality, observation density map, top 15 families (computed via ancestry traversal), species richness table, and a SAR-ready site × species matrix export for downstream species-area curve fitting in the `sars` R/Python packages.
- **`mv_herpetofauna_grid` materialized view** — Pre-aggregated 0.5 degree (~55 km) density grid for Amphibia + Reptilia observations, grouped by `quality_grade` so dashboard quality variables still filter. Backs the Herpetofauna Observation Density Map. Built and atomically swapped on each import alongside the other materialized views. Reduced map panel load from ~22 s (inline ancestry-filtered aggregation against the 233 M-row observations table) to ~28 ms (sequential scan of ~62 K pre-aggregated rows). Added to both `db/init/03-materialized-views.sql` (empty stub) and `db/scripts/create-materialized-views.sql` (per-import build + swap).
- **Herpetofauna density map and SAR table now use compatible grid boundaries** — The Site x Species Matrix panel previously used `round(latitude, 1)` for cell snapping, while the Density Map used `ST_SnapToGrid(geom, 0.5)`. Although both produced ~10 km cells, the snapping functions produced subtly different boundaries that prevented the two grids from nesting cleanly. Switched the SAR query to `ST_SnapToGrid(geom, 0.1)` so it uses the same nearest-snap convention as the density map, with the result that 0.1° SAR cells now nest exactly within 0.5° density cells (5×5 = 25 SAR cells per density cell). Added detailed panel descriptions to both panels documenting the resolution, the km equivalent at lat 36° (the dashboard's default Appalachian view), and the nesting relationship.
- **Multi-Scale Species-Area Aggregation panel + `mv_herpetofauna_sar_grid` materialized view** — Added a new panel and supporting MV for true species-area curve fitting with the `sars` R package. The previous "Site x Species Matrix" panel was misnamed — uniform 0.1° cells don't have enough area dynamic range for a meaningful SAR fit, so it was renamed to "Site x Species Matrix (0.1° grid)" with an honest description listing what it actually IS good for (beta diversity, hotspot mapping, accumulation curves). The new "Multi-Scale Species-Area Aggregation (SAR-ready)" panel aggregates herp observations across 5 scales (0.1° / 0.2° / 0.4° / 0.8° / 1.6°) giving a ~730× area dynamic range and producing data ready to feed directly into `sars::sar_power()` or `sars::sar_average()`. Cell areas are computed as **geodesic surface area on the WGS84 ellipsoid** via `ST_Area(geometry::geography)`, so they correctly account for Earth curvature and meridian convergence at higher latitudes. Backed by `mv_herpetofauna_sar_grid`, a new MV that stores per-cell `taxon_id` arrays at 0.1° base resolution; the panel query unions arrays via `unnest` + `array_agg` to compute species richness at coarser scales without re-scanning the 233 M-row observations table. Reduced query time from ~60 s (inline scan + aggregation) to ~1.7 s (MV-backed). MV is ~316 K rows / 66 MB. Added to both `db/init/03-materialized-views.sql` and `db/scripts/create-materialized-views.sql` so it gets rebuilt on every import.

### Bug Fixes

- **Ancestry filter pattern corrected** — The naive `t.ancestry LIKE '%/X/%'` pattern documented in `data-model.md` and used by some dashboards missed direct child taxa whose ancestry string ended in `/X` with no trailing slash (e.g., orders directly under a class). All new code uses the wrapped-delimiter form `('/' || COALESCE(t.ancestry, '') || '/') LIKE '%/X/%'`. Existing dashboards using the buggy pattern continue to work for species-rank queries but should be migrated.
- **`import-stale` alert no longer false-fires on cache-skip** — The alert query previously looked for the most recent `'completed'` row in `import_log`, which made it fire whenever upstream iNaturalist S3 was unchanged for >36 hours (i.e., almost always, since iNat publishes monthly). The importer now writes a `status='skipped'` row to `import_log` on each cache-skip, and the alert query was updated to `WHERE status IN ('completed', 'skipped')` so a healthy nightly skip counts as a check-in. The skip-decision logic in `import.sh` was also updated to ignore prior `'skipped'` rows when deciding whether to re-import, so consecutive skips don't trigger spurious re-imports.
- **`import-count-drop` alert no longer false-fires on first run** — The alert used an `INNER JOIN` between current and previous completed imports, which returned zero rows (NoData → alerting) whenever there was only one completed import in the database. Rewrote the query as a `LEFT JOIN LATERAL` wrapped in `COALESCE(..., 0)` so it always returns exactly one row containing `pct_drop`, defaulting to 0 when there's no baseline to compare against.
- **`v_health` view reflects skipped runs** — The PostgREST health endpoint previously filtered to `status IN ('completed', 'failed')`, which caused `hours_since_import` to climb indefinitely between monthly iNaturalist publishes — making external uptime monitors flag a healthy system as broken. Rewrote the view as two CTEs: `last_import_status`, `last_import_at`, `hours_since_import`, `last_import_duration_seconds`, and `last_error` now reflect the most recent terminal run of any kind (`completed`, `skipped`, or `failed`), while `observations_count`, `photos_count`, `taxa_count`, and `observers_count` continue to come from the most recent successful `completed` import. Column names and order are unchanged, so existing consumers of `/v_health` are not affected.

### Documentation

- **Schema definition reference** — Added [docs/schema-definition.md](docs/schema-definition.md), a terse machine-readable schema cheat sheet designed to be loaded as context by LLM coding assistants when writing SQL against Observa. Covers exact column types, materialized view columns, RPC function signatures, indexes, the canonical ancestry-filter idiom, useful iNaturalist taxon IDs (Amphibia, Reptilia, Aves, Mammalia, etc.), Grafana macro reference, and a Gotchas section explicitly flagging the non-existent `iconic_taxon_name` column and other footguns.
- **Cross-linked data-model and schema-definition docs** — Both reference docs now point at each other in their headers, with `data-model.md` framed as the prose/tutorial source of truth and `schema-definition.md` framed as the structured/reference source of truth.
- **Fixed ancestry filter example in data-model.md** — Updated the worked example to use the correct wrapped-delimiter pattern, with a callout explaining why the naive form is buggy.
- **Contribution guide** — Added [CONTRIBUTING.md](CONTRIBUTING.md) at the repo root with sections covering bug reports, local development setup, the synthetic test data harness, running CI checks locally, project layout, and step-by-step recipes for common contribution tasks (adding a dashboard, modifying an alert, changing the schema, modifying the importer). Slimmed the existing Contributing section in the README to point at the new file.

### Project metadata

- **Citation File Format manifest** — Added [CITATION.cff](CITATION.cff) (CFF 1.2.0) so GitHub's "Cite this repository" button and Zenodo can produce structured citations on release. Includes a `references` block pointing at the underlying iNaturalist Open Dataset so downstream users know to cite both Observa and the source data.

## v0.2.0 — 2026-03-28

### Security

- **Default credential check expanded** — The importer now refuses to start if `GF_SECURITY_ADMIN_PASSWORD` is still set to `changeme`, in addition to the existing `PGPASSWORD` check. Added a security callout to the Quick Start section of the README.
- **API rate limiting and request logging** — Nginx reverse proxy in front of PostgREST with rate limiting (10 req/s per IP, burst 20), access logging, and CORS headers. PostgREST is no longer directly exposed; all API traffic routes through nginx on port 3001.

### Reliability

- **Index on import_log.started_at** — Added a descending index on `started_at` to support the hung-import alert query efficiently as import history grows.
- **Data quality alerts** — Three new Grafana alerts: high NULL taxon_id percentage (>15%), stale observations (latest >90 days old), and geographic bounding box collapse (all observations in <1 degree).

### Performance

- **Non-blocking materialized view refresh** — Replaced the DROP/CREATE pattern for materialized views with a build-and-swap approach. New views are built under temporary names while dashboards continue reading existing views, then swapped in atomically. Dashboards no longer return errors or stale data during view rebuilds.
- **Python S3 downloader with progress bars** — Replaced the shell-based `aws s3 cp` download logic with a Python script using `boto3` and `tqdm`. Downloads show per-file progress bars with transfer speed and ETA. Removed `aws-cli` dependency from the importer image.

### Features

- **Spatial query API endpoint** — Added `observations_near(lat, lon, radius_km, lim)` PostgreSQL function for finding observations within a radius of a geographic point. Auto-exposed via PostgREST at `/rpc/observations_near`. Returns results ordered by distance with `distance_m` in meters.
- **Fuzzy taxa search endpoint** — Added `taxa_search(query, lim)` function using `pg_trgm` similarity and `ILIKE` for typo-tolerant species name search. Exposed at `/rpc/taxa_search`.
- **Taxonomy tree navigation** — Added `taxon_lineage(taxon_id)` to walk ancestry from any taxon up to its root, and `taxon_children(parent_id)` to list direct children with observation counts. Both exposed via PostgREST RPC.
- **Automated scheduled backups** — Backup service now runs on a cron schedule (default: weekly Sunday 2 AM) instead of on-demand only. Configurable via `BACKUP_CRON` env var.
- **Configurable import thresholds** — The row count drop threshold (previously hardcoded at 50%) is now configurable via `ROW_DROP_THRESHOLD` env var.
- **Post-import data profiling** — Each import now computes and stores data quality metrics (NULL percentages, date range, quality grade distribution, geographic bounding box) in a new `import_stats` table.
- **KML and Darwin Core Archive export** — `export.sh` now supports `kml` format for Google Earth and `dwca` format for GBIF-compatible Darwin Core Archives with proper `meta.xml` descriptor.
- **Database Health dashboard** — New Grafana dashboard showing cache hit ratio, index hit ratio, database size, active queries, table sizes, index usage, table bloat, slowest queries (via `pg_stat_statements`), connection count, and temp file usage.
- **Observer Activity filtering** — Observer Activity dashboard now accepts an iNaturalist observer ID to filter all panels to a single user.

### Dashboard hardening

- Removed unused `quality_grade` and `taxonomic_rank` variable dropdowns from Overview dashboard (were defined but not wired to queries).
- Removed Photo Gallery dashboard (photo metadata is better explored via the API).
- Lowered default anomaly threshold from 0.9 to 0.5 for better out-of-the-box visibility.
- Fixed Overview heatmap and HotSpots density panels to render correctly with marker layers.
- All geomap panels use auto-fit view to zoom to data extent instead of centering on the Atlantic.

### Documentation

- **Architecture Decisions section** — Added an Architecture section to the README explaining the swap-table import pattern, materialized view rebuild strategy, file-lock concurrency control, and read-only API role separation.
- Updated Grafana Alerts section to include the hung-import alert.
- Updated dashboard list in Quick Start (4 → 8 dashboards).
- Added spatial query, taxa search, and taxonomy tree API documentation to README.
- Updated backup, services table, and API security sections for nginx and scheduled backups.
- Replaced manual seed snippet with `test-local.sh` one-command test harness (100K synthetic observations, API smoke tests).

### Deferred

- **Incremental materialized view refresh** — deferred until refresh times become a bottleneck at 500M+ rows.
- **Endangered species monitoring** — deferred; requires sourcing external IUCN Red List data.

## v0.1.4 — 2026-03-19

### Bug Fixes

- **Staging index creation fails on retry** — `CREATE INDEX` on staging tables failed with "relation already exists" if indexes carried over from a previous run or cached image. Changed all staging index statements to `CREATE INDEX IF NOT EXISTS` for idempotent execution.

### Features

- **Regional Explorer dashboard** — New parameterized dashboard that works for any region and taxonomic group. Set bounding box coordinates, taxon ID, and quality grade via dropdown variables. Replaces the hardcoded La Selva and Steele Creek dashboards.
- **Overview dashboard variables wired** — The `quality_grade` and `taxonomic_rank` variables were defined but unused. Now `quality_grade` filters Total Observations and `taxonomic_rank` filters the Top 20 Taxa panel.
- **Dashboard time picker wired** — The Grafana time range picker was visible but ignored by all queries. Timeseries panels in Overview, Regional Explorer, and Import Health now respect the selected time range via `$__timeFilter()` macros.
- **Parallel S3 downloads** — The importer now downloads all 4 data files concurrently instead of sequentially, reducing download time by up to 4x on the initial import.
- **Anomaly Detection dashboard** — New dashboard visualizing the `anomaly_score` column: score distribution, monthly trends, geographic map of high-anomaly observations, top anomalous species, and configurable threshold variable.
- **Observer Activity dashboard** — New dashboard focused on observer engagement: new observers over time, cumulative growth, activity distribution, top observers with species diversity, and monthly active observer counts.
- **BioBlitz Event dashboard** — New parameterized dashboard for time-bounded citizen science events: configurable start/end dates and bounding box, species accumulation curve, participant leaderboard, daily activity breakdown, and observation map.
- **Photo Gallery dashboard** — New dashboard for browsing photo metadata: license and format distribution, clickable photo URLs to S3, top photographers, most-photographed species, and license filter variable.
- **Multi-grid resolution for HotSpots** — The HotSpots dashboard now has a grid resolution variable (0.1 to 5.0 degrees) so users can zoom into dense areas or zoom out for continental views. Queries compute on the fly instead of using the fixed 1-degree materialized view.

### Documentation

- Added data model reference, troubleshooting guide, and custom dashboards guide to `docs/`.
- Updated CSV export guide and README with new dashboard descriptions.

## v0.1.3 — 2026-03-19

### Bug Fixes

- **Race condition in stale lock recovery** — After removing a stale lock, `mkdir` was not checked for failure, allowing two imports to run concurrently if another process grabbed the lock in between. Now aborts if re-acquisition fails.

## v0.1.2 — 2026-03-19

### Bug Fixes

- **Skip-unchanged logic never triggered** — The `import_log` row for the current run was inserted before the skip check, so the query always saw a `running` status instead of the previous completed one. Moved the INSERT to after the skip decision.
- **Orphan import_log rows on skip** — Skipping an import left a row with NULL status/timestamps, which also broke the `v_health` view. Now no row is created when the import is skipped.
- **Stale file lock blocks all future imports** — If the import process was killed uncleanly, the `/tmp/import.lock` directory was never removed. Added PID-based stale lock detection and automatic recovery.
- **Staging index collision after first successful import** — `LIKE taxa INCLUDING ALL` copied indexes from the previous staging-turned-live tables, causing `CREATE INDEX idx_stg_*` to fail with "relation already exists". Replaced with `INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING GENERATED` to skip index copying.

### Reliability

- **`v_health` view filtered to finished imports** — Added `WHERE status IN ('completed', 'failed')` so the health endpoint only reports on completed or failed imports, not in-progress ones.

## v0.1.1 — 2026-03-19

### Bug Fixes

- **Importer not running** — Replaced `supercronic` (glibc binary incompatible with Alpine/musl) with Alpine's built-in `crond`.
- **Broken concurrent-import lock** — PostgreSQL advisory lock was session-scoped and released immediately; replaced with `mkdir`-based file lock.
- **Grafana panels failing** — Added empty materialized views at database init so panels load before first import; granted `pg_read_all_stats` for the Database Size panel.
- **Removed auto-import on startup** — Initial import no longer runs automatically; must be triggered manually or by cron schedule.

### Features

- **Skip unchanged imports** — Importer checks S3 ETags and skips the full import cycle when data hasn't changed and last import succeeded.
- **Health endpoint** — Added `v_health` SQL view exposed via PostgREST at `/v_health` for external uptime monitors.
- **La Selva Biological Station dashboard** — Observations, species, seasonal patterns, and map for the La Selva area in Costa Rica.
- **Steele Creek Park — Frogs dashboard** — Frog observations, species list, seasonal activity, and map for Steele Creek Park in Bristol, TN.
- **iNaturalist HotSpots dashboard** — Global observation density heatmap, top hotspots table, and distribution breakdown.

### Documentation

- Added development guide covering: manual imports, test data seeding, alert SQL testing, and log viewing.
- Added filtered data export examples using PostgREST with `Accept: text/csv`.

## v0.1.0 — 2026-03-15

Initial release of Observa, a Dockerized platform for hosting and exploring iNaturalist Open Data.

### Highlights

- **Automated ETL pipeline** — Cron-scheduled importer downloads CSVs from S3, validates integrity, loads into staging tables, and performs zero-downtime atomic table swaps.
- **PostGIS database** — PostgreSQL 16 with PostGIS, materialized views for fast analytics, and tuned configuration for analytical workloads.
- **Grafana dashboards** — Pre-provisioned Overview and Import Health dashboards with alerting for stale imports, failures, and observation count drops.
- **REST API** — Read-only PostgREST API for querying observations, taxa, and materialized views.
- **Database backup** — On-demand `pg_dump` backups with configurable retention.
- **Data export** — CSV and GeoJSON export scripts.

### Security

- Default credentials (`changeme`) are detected at startup with a loud warning; missing `.env` causes an explicit error instead of silent fallback defaults.
- Postgres and PostgREST ports bound to `127.0.0.1` only.
- Dedicated read-only `api_user` role for PostgREST instead of the admin superuser.
- S3 downloads verified against published checksums before decompression.
- Documented unauthenticated API access and JWT authentication setup.

### Performance

- Materialized views use `REFRESH MATERIALIZED VIEW CONCURRENTLY` with unique indexes instead of drop-and-recreate.
- Geometry column populated via generated column to avoid full-table UPDATE after COPY.
- Covering index on `import_log(status, id)` for fast alert evaluation.
- Documented `work_mem` x parallelism memory ceiling in `postgresql.conf`.

### Reliability

- Hung import alert fires when an import is stuck in `running` state for over 4 hours.
- Cleanup trap guarded by a `SWAP_COMPLETE` flag to avoid dropping tables after a successful swap.
- Backup file rotation sorts by filename timestamp instead of unreliable filesystem mtime.
- Row-count validation uses `awk 'END{print NR}'` to handle TSV files without trailing newlines.
- Backup service uses its own minimal Docker image with only `pg_dump` and Postgres client tools.

### Maintainability

- Dashboard JSON uses explicit datasource UIDs matching `postgres.yml`.
- `import.sh` refactored into named functions (`download_files`, `validate_files`, `load_staging`, `swap_tables`, `refresh_views`).
- Alerting contact points provisioned via `contact-points.yml` with environment variable support.

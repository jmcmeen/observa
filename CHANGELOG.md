# Changelog

All notable changes to this project will be documented in this file.

## v0.2.0 — 2026-03-19

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

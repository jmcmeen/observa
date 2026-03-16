# Changelog

All notable changes to this project will be documented in this file.

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

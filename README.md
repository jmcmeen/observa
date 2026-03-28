# Observa

![Observa](docs/observa.webp)

A Dockerized platform for hosting and exploring [iNaturalist Open Data](https://github.com/inaturalist/inaturalist-open-data) from the AWS Open Registry. Includes a PostGIS-enabled PostgreSQL database, automated daily imports, Grafana dashboards, and a REST API.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) and Docker Compose v2+
- ~50 GB of free disk space (for downloaded CSVs and database storage)
- 16 GB+ RAM recommended (PostgreSQL is tuned for analytical workloads)

## Quick Start

1. **Clone and configure**

   ```bash
   git clone https://github.com/jmcmeen/observa.git && cd observa
   cp .env.example .env
   ```

   Edit `.env` to set your passwords:

   ```ini
   POSTGRES_PASSWORD=your_secure_password
   API_USER_PASSWORD=your_api_password
   GF_SECURITY_ADMIN_PASSWORD=your_grafana_password
   ```

   > **Security:** The importer will refuse to start if any password is still set to `changeme`. Choose strong, unique passwords for each service before proceeding.

2. **Start the services**

   ```bash
   docker compose up -d
   ```

   This starts PostgreSQL (with PostGIS), Grafana, the importer, and PostgREST.

3. **Run the initial import**

   The first import must be triggered manually. This downloads ~10 GB of compressed data from S3 and loads it into the database. It will take a while depending on your connection and hardware.

   ```bash
   docker compose run --rm --entrypoint /import.sh importer
   ```

4. **Open the dashboard**

   Navigate to [http://localhost:3000](http://localhost:3000) and log in with the credentials from your `.env` file. Eight dashboards are pre-provisioned:

   - **iNaturalist Overview** — total observations, taxa, maps, quality grade distribution, monthly trends, and top species
   - **Regional Explorer** — parameterized dashboard for any region and taxon (set bounding box, taxon ID, and quality grade via dropdowns)
   - **Import Health** — import duration trends, row counts, and status history
   - **iNaturalist HotSpots** — global observation density heatmap with multi-resolution grid variable
   - **Anomaly Detection** — anomaly score distribution, trends, geographic map, and top anomalous species
   - **Observer Activity** — observer engagement, cumulative growth, activity distribution, and monthly active counts (filterable by observer ID)
   - **BioBlitz Event** — time-bounded citizen science events with species accumulation and participant leaderboards
   - **Database Health** — cache hit ratio, index hit ratio, database size, table sizes, index usage, bloat, slow queries, and active connections

## Configuration

All settings are in `.env` (see `.env.example` for defaults):

| Variable | Description | Default |
|---|---|---|
| `POSTGRES_USER` | Database user | `observa` |
| `POSTGRES_PASSWORD` | Database password | **(required)** |
| `POSTGRES_DB` | Database name | `inaturalist` |
| `API_USER_PASSWORD` | PostgREST API database user password | **(required)** |
| `GF_SECURITY_ADMIN_USER` | Grafana admin username | `admin` |
| `GF_SECURITY_ADMIN_PASSWORD` | Grafana admin password | **(required)** |
| `IMPORT_CRON` | Import schedule (cron expression) | `0 3 * * *` (daily 3 AM) |
| `ROW_DROP_THRESHOLD` | Max allowed row count drop % before aborting import | `50` |
| `BACKUP_CRON` | Backup schedule (cron expression) | `0 2 * * 0` (weekly Sunday 2 AM) |
| `BACKUP_RETENTION` | Number of database backups to keep | `4` |

### PostgreSQL tuning

`db/postgresql.conf` is tuned for a host with **~16 GB RAM**. The most impactful settings are `shared_buffers` (4 GB) and `work_mem` (256 MB). On hosts with less RAM, create a `docker-compose.override.yml` to lower these values:

```yaml
services:
  postgres:
    command: >
      postgres
        -c config_file=/etc/postgresql/postgresql.conf
        -c shared_buffers=1GB
        -c work_mem=64MB
```

See comments in `db/postgresql.conf` for details on worst-case memory usage under parallel queries.

## Services

| Service | Port | Description |
|---|---|---|
| `postgres` | 5432 | PostGIS 16 database with iNaturalist data |
| `grafana` | 3000 | Dashboard UI with alerting |
| `importer` | — | Cron-based ETL container (no exposed ports) |
| `nginx` | 3001 | Reverse proxy with rate limiting and access logging |
| `postgrest` | — | Read-only REST API over the database (internal, behind nginx) |
| `backup` | — | Scheduled database backup (weekly by default) |

## Daily Imports

The importer runs on the schedule defined by `IMPORT_CRON`. Each run uses a zero-downtime swap-table strategy:

1. Downloads the latest CSVs from `s3://inaturalist-open-data`
2. Validates file integrity and CSV headers
3. Loads data into staging tables with indexes
4. Atomically swaps staging tables with live tables
5. Refreshes materialized views for fast dashboard queries
6. Logs results to the `import_log` table

Safety features:

- File lock with PID-based stale lock recovery prevents concurrent imports
- ETag caching skips the full import cycle when S3 data hasn't changed
- Row count validation aborts if data drops >50% from previous import
- Failed imports are automatically logged with error details
- Staging tables are cleaned up on failure (live data preserved)

To trigger a manual import:

```bash
docker compose run --rm --entrypoint /import.sh importer
```

To check import logs:

```bash
docker compose exec postgres psql -U observa -d inaturalist \
  -c "SELECT * FROM import_log ORDER BY id DESC LIMIT 5;"
```

## Health Endpoint

A `v_health` view is exposed via PostgREST for external uptime monitors:

```bash
curl "http://localhost:3001/v_health"
```

Returns the status of the last finished import (completed or failed), hours since last import, row counts, and any error message. In-progress imports are excluded. This can be polled by monitoring tools without requiring Grafana access.

## REST API

PostgREST provides a read-only REST API at [http://localhost:3001](http://localhost:3001). Examples:

```bash
# Get 10 observations
curl "http://localhost:3001/observations?limit=10"

# Search taxa by name
curl "http://localhost:3001/taxa?name=ilike.*robin*"

# Filter observations by quality grade
curl "http://localhost:3001/observations?quality_grade=eq.research&limit=50"

# Get observation counts from materialized views
curl "http://localhost:3001/mv_quality_grade_counts"
```

### Spatial queries

Find observations within a radius of a geographic point using the `observations_near` RPC function:

```bash
# Observations within 50 km of Great Smoky Mountains (lat 35.5, lon -83.2)
curl "http://localhost:3001/rpc/observations_near?lat=35.5&lon=-83.2&radius_km=50"

# Nearest 20 observations to a point (default radius: 10 km)
curl "http://localhost:3001/rpc/observations_near?lat=40.7&lon=-74.0&lim=20"
```

Returns `observation_uuid`, `taxon_id`, `quality_grade`, `observed_on`, and `distance_m` (distance in meters from the query point), ordered by distance.

### Taxa search

Search taxa by name with fuzzy matching (typo-tolerant):

```bash
# Search for "robin" (substring + similarity match)
curl "http://localhost:3001/rpc/taxa_search?query=robin"

# Fuzzy search for a misspelled name
curl "http://localhost:3001/rpc/taxa_search?query=turdus%20migratorus&lim=5"
```

Returns `taxon_id`, `name`, `rank`, `rank_level`, `active`, and `similarity` score, ordered by best match.

### Taxonomy tree

Navigate the taxonomic hierarchy using recursive ancestry queries:

```bash
# Get the full lineage of a taxon (e.g., American Robin, taxon_id=12727)
curl "http://localhost:3001/rpc/taxon_lineage?target_taxon_id=12727"

# List direct children of a taxon with observation counts
curl "http://localhost:3001/rpc/taxon_children?parent_id=3&lim=20"
```

`taxon_lineage` walks from any taxon up to its kingdom, returning each ancestor's name, rank, and depth. `taxon_children` lists direct children sorted by observation count.

See the [PostgREST documentation](https://postgrest.org/en/stable/references/api.html) for full query syntax.

### CSV export

Add `Accept: text/csv` to any API request to get CSV output instead of JSON:

```bash
curl -H "Accept: text/csv" \
  "http://localhost:3001/observations?quality_grade=eq.research&limit=1000" > research.csv
```

See **[docs/csv-export-guide.md](docs/csv-export-guide.md)** for filtering, column selection, pagination, joins, and more examples.

### API security notice

The API is rate-limited (10 requests/second per IP, burst of 20) via an nginx reverse proxy. The `/v_health` endpoint is exempt from rate limiting for uptime monitors. PostgREST is not directly exposed — all traffic routes through nginx.

The API is **unauthenticated by default** — anyone with network access to port 3001 can query the full dataset. This is acceptable on trusted networks or when bound to localhost (the default), but you should add authentication before exposing it to the internet.

To enable JWT authentication:

1. Generate a secret (at least 32 characters):

   ```bash
   openssl rand -base64 32
   ```

2. Add it to your `.env`:

   ```ini
   PGRST_JWT_SECRET=your_generated_secret
   ```

3. Add the variable to the `postgrest` service in `docker-compose.yml`:

   ```yaml
   environment:
     PGRST_JWT_SECRET: ${PGRST_JWT_SECRET}
   ```

4. Requests must now include a valid JWT in the `Authorization: Bearer <token>` header. See the [PostgREST authentication docs](https://postgrest.org/en/stable/references/auth.html) for details on generating tokens and configuring roles.

## Database Backup

Backups run automatically on the schedule defined by `BACKUP_CRON` (default: weekly Sunday 2 AM). To trigger an immediate backup:

```bash
docker compose exec backup /backup.sh
```

Backups are stored in the `backup_data` volume in PostgreSQL custom format. To restore, copy the dump from the volume and pipe it into `pg_restore`:

```bash
# List available backups
docker compose exec backup ls /backups

# Restore a specific backup
docker compose exec backup \
  pg_restore -h postgres -U observa -d inaturalist --clean /backups/observa_20260315_030000.dump
```

## Data Export

Observa supports exporting filtered CSV files for use in R, Python, Excel, QGIS, and other tools. The quickest method is the REST API:

```bash
# Research-grade observations for a specific taxon
curl -H "Accept: text/csv" \
  "http://localhost:3001/observations?taxon_id=eq.3726&quality_grade=eq.research" > research.csv

# Top 100 most-observed species
curl -H "Accept: text/csv" \
  "http://localhost:3001/mv_top_taxa?rank=eq.species&order=observation_count.desc&limit=100" > top_species.csv
```

For joins, complex queries, and full-table dumps, use `psql \COPY` or the built-in `export.sh` script.

See **[docs/csv-export-guide.md](docs/csv-export-guide.md)** for the complete guide — filtering, column selection, pagination, joins, and examples for common workflows.

## Connecting Directly to the Database

```bash
docker compose exec postgres psql -U observa -d inaturalist
```

Or from your host (with a PostgreSQL client installed):

```bash
psql -h localhost -U observa -d inaturalist
```

## Grafana Alerts

The following alerts are pre-configured:

- **Import is stale** — warns if no successful import in 36+ hours
- **Last import failed** — critical alert on import failure
- **Observation count drop** — warns if count drops >10% between imports
- **Import hung** — critical alert if an import has been running for 4+ hours

Configure notification channels in Grafana under Alerting > Contact Points.

## Development

### Running the importer against an existing database

If the database is already populated, you can re-run the importer without downloading from S3. The importer uses ETag caching, so if cached files exist and haven't changed upstream, the download phase is skipped automatically:

```bash
docker compose exec importer /bin/sh /import.sh
```

To force a fresh download (e.g., after clearing the cache volume):

```bash
docker compose down importer
docker volume rm observa_import_cache
docker compose up -d importer
docker compose exec importer /bin/sh /import.sh
```

### Local testing without S3

A one-command test harness seeds 100K synthetic observations, refreshes materialized views, and runs an API smoke test against all endpoints:

```bash
docker compose up -d
./scripts/test-local.sh
```

This generates a realistic dataset with taxonomy hierarchy (10 orders, 9 families, 80 species), 200 observers, geographically clustered observations across 5 US regions, 60K photos, and seasonal date spread — enough to exercise all dashboards, spatial queries, taxa search, and data quality alerts.

The individual scripts can also be run separately:

```bash
# Seed data only (idempotent — safe to re-run)
docker compose exec -T postgres psql -U observa -d inaturalist -f - < scripts/seed-test-data.sql
docker compose exec importer psql -f /scripts/create-materialized-views.sql

# API smoke tests only
./scripts/test-api.sh
```

### Testing alert SQL

Grafana alert rules query PostgreSQL directly. To test alert queries from the command line:

```bash
# Import stale alert — checks hours since last successful import
docker compose exec postgres psql -U observa -d inaturalist -c "
  SELECT EXTRACT(EPOCH FROM now() - max(finished_at)) / 3600 AS hours_since_import
  FROM import_log WHERE status = 'completed';
"

# Observation count drop alert
docker compose exec postgres psql -U observa -d inaturalist -c "
  SELECT a.observations_count AS current, b.observations_count AS previous,
         round(100.0 * (b.observations_count - a.observations_count) / b.observations_count, 1) AS drop_pct
  FROM import_log a, import_log b
  WHERE a.id = (SELECT max(id) FROM import_log WHERE status = 'completed')
    AND b.id = (SELECT max(id) FROM import_log WHERE status = 'completed' AND id < a.id);
"
```

### Rebuilding a single service

```bash
docker compose up -d --build importer   # rebuild and restart importer only
docker compose up -d --build postgres   # rebuild postgres (data persists in volume)
```

### Viewing logs

```bash
docker compose logs -f importer         # follow importer logs
docker compose logs --tail 50 postgres  # last 50 lines from postgres
docker compose logs                     # all services
```

## Documentation

| Guide | Description |
|---|---|
| [CSV Export Guide](docs/csv-export-guide.md) | Exporting filtered data as CSV for R, Python, Excel, QGIS |
| [Data Model Reference](docs/data-model.md) | Tables, columns, relationships, indexes, and materialized views |
| [Custom Dashboards](docs/custom-dashboards.md) | Building your own Grafana dashboards with query examples |
| [Troubleshooting](docs/troubleshooting.md) | Common problems, error messages, and fixes |

## Architecture

Key design decisions and the reasoning behind them:

**Atomic swap-table imports.** Each import loads data into staging tables, then renames them into place in a single transaction. This avoids the read-blocking and WAL amplification of `TRUNCATE`/`INSERT` or row-by-row `UPSERT` on a 200M+ row table. Dashboards and API queries experience zero downtime during imports.

**Materialized views rebuilt per import.** The iNaturalist open dataset is published as a full snapshot, not a delta. Since every row is replaced on each import, incremental view maintenance would add complexity without benefit. Views are built under temporary names and swapped in atomically so dashboards continue serving stale-but-valid data during the rebuild.

**File-lock concurrency control.** The importer uses an atomic `mkdir`-based lock with PID-based stale detection. If a previous import was killed (OOM, node restart), the next run detects the dead PID and recovers the lock automatically. This prevents concurrent imports from corrupting the table swap without requiring external coordination.

**Read-only API role separation.** PostgREST connects through an `api_readonly` role that has only `SELECT` and `EXECUTE` grants. Even if PostgREST is exposed beyond localhost, the database enforces that no data can be modified through the API layer.

## Contributing

Contributions are welcome. To get started:

1. Fork the repository and create a feature branch from `main`.
2. Set up the local development environment (see [Quick Start](#quick-start)).
3. Run the test harness before submitting:

   ```bash
   ./scripts/test-local.sh
   ```

4. Open a pull request against `main` with a clear description of the change.

Bug reports and feature requests can be filed via [GitHub Issues](https://github.com/jmcmeen/observa/issues).

## Citation

If you use Observa in academic work or publications, please cite it as:

```bibtex
@software{observa,
  author       = {McMeen, John},
  title        = {Observa: A Dockerized Platform for iNaturalist Open Data},
  url          = {https://github.com/jmcmeen/observa},
  license      = {Apache-2.0}
}
```

## Data Source

This project uses the [iNaturalist Open Dataset](https://github.com/inaturalist/inaturalist-open-data), which is hosted on the [AWS Open Data Registry](https://registry.opendata.aws/inaturalist-open-data/). The dataset includes observations, photos, taxa, and observer metadata published under Creative Commons licenses. See the upstream repository for licensing and attribution details.

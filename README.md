# Observa

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

   ```
   POSTGRES_PASSWORD=your_secure_password
   GF_SECURITY_ADMIN_PASSWORD=your_grafana_password
   ```

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

   Navigate to [http://localhost:3000](http://localhost:3000) and log in with the credentials from your `.env` file (default: `admin` / `changeme`). Two dashboards are pre-provisioned:

   - **iNaturalist Overview** — observations, taxa, maps, and analytics
   - **Import Health** — import duration trends, row counts, and status history

## Configuration

All settings are in `.env` (see `.env.example` for defaults):

| Variable | Description | Default |
|---|---|---|
| `POSTGRES_USER` | Database user | `observa` |
| `POSTGRES_PASSWORD` | Database password | `changeme` |
| `POSTGRES_DB` | Database name | `inaturalist` |
| `GF_SECURITY_ADMIN_USER` | Grafana admin username | `admin` |
| `GF_SECURITY_ADMIN_PASSWORD` | Grafana admin password | `changeme` |
| `IMPORT_CRON` | Import schedule (cron expression) | `0 3 * * *` (daily 3 AM) |
| `BACKUP_RETENTION` | Number of database backups to keep | `4` |

## Services

| Service | Port | Description |
|---|---|---|
| `postgres` | 5432 | PostGIS 16 database with iNaturalist data |
| `grafana` | 3000 | Dashboard UI with alerting |
| `importer` | — | Cron-based ETL container (no exposed ports) |
| `postgrest` | 3001 | Read-only REST API over the database |
| `backup` | — | On-demand database backup (via `--profile backup`) |

## Daily Imports

The importer runs on the schedule defined by `IMPORT_CRON`. Each run uses a zero-downtime swap-table strategy:

1. Downloads the latest CSVs from `s3://inaturalist-open-data`
2. Validates file integrity and CSV headers
3. Loads data into staging tables with indexes
4. Atomically swaps staging tables with live tables
5. Refreshes materialized views for fast dashboard queries
6. Logs results to the `import_log` table

Safety features:

- Advisory lock prevents concurrent imports
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

See the [PostgREST documentation](https://postgrest.org/en/stable/references/api.html) for full query syntax.

## Database Backup

Run a backup on demand:

```bash
docker compose run --rm --profile backup backup
```

Backups are stored in the `backup_data` volume in PostgreSQL custom format. To restore, copy the dump from the volume and pipe it into `pg_restore`:

```bash
# List available backups
docker compose run --rm --profile backup --entrypoint ls backup /backups

# Restore a specific backup
docker compose run --rm --profile backup --entrypoint sh backup -c \
  "pg_restore -h postgres -U observa -d inaturalist --clean /backups/observa_20260315_030000.dump"
```

## Data Export

Export data as CSV or GeoJSON. Files are written inside the importer container and can be copied out with `docker cp`:

```bash
# Export taxa as CSV
docker compose exec importer sh /scripts/export.sh csv taxa /data
docker cp $(docker compose ps -q importer):/data/taxa_export.csv .

# Export observations as GeoJSON (limited to 10,000 features)
docker compose exec importer sh /scripts/export.sh geojson observations /data
docker cp $(docker compose ps -q importer):/data/observations_export.geojson .
```

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

Configure notification channels in Grafana under Alerting > Contact Points.

## Data Source

This project uses the [iNaturalist Open Dataset](https://github.com/inaturalist/inaturalist-open-data), which is hosted on the [AWS Open Data Registry](https://registry.opendata.aws/inaturalist-open-data/). The dataset includes observations, photos, taxa, and observer metadata published under Creative Commons licenses. See the upstream repository for licensing and attribution details.

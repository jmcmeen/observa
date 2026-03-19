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
| `POSTGRES_PASSWORD` | Database password | **(required)** |
| `POSTGRES_DB` | Database name | `inaturalist` |
| `API_USER_PASSWORD` | PostgREST API database user password | **(required)** |
| `GF_SECURITY_ADMIN_USER` | Grafana admin username | `admin` |
| `GF_SECURITY_ADMIN_PASSWORD` | Grafana admin password | **(required)** |
| `IMPORT_CRON` | Import schedule (cron expression) | `0 3 * * *` (daily 3 AM) |
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

- File lock prevents concurrent imports
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

Returns the last import status, hours since last import, row counts, and any error message. This can be polled by monitoring tools without requiring Grafana access.

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

### Filtered data export

PostgREST supports CSV output via the `Accept` header, which is often more useful than the full-table dumps from `export.sh`:

```bash
# Export research-grade observations as CSV
curl -H "Accept: text/csv" \
  "http://localhost:3001/observations?quality_grade=eq.research&limit=1000" > research.csv

# Export observations for a specific taxon
curl -H "Accept: text/csv" \
  "http://localhost:3001/observations?taxon_id=eq.3726&limit=5000" > taxon_obs.csv

# Export observations within a date range
curl -H "Accept: text/csv" \
  "http://localhost:3001/observations?observed_on=gte.2025-01-01&observed_on=lte.2025-12-31" > year_2025.csv

# Export observations within a bounding box (lat/lon)
curl -H "Accept: text/csv" \
  "http://localhost:3001/observations?latitude=gte.10.0&latitude=lte.11.0&longitude=gte.-84.5&longitude=lte.-83.5" > bbox.csv

# Combine filters — research-grade birds in 2025
curl -H "Accept: text/csv" \
  "http://localhost:3001/observations?quality_grade=eq.research&observed_on=gte.2025-01-01&observed_on=lte.2025-12-31&select=observation_uuid,taxon_id,observed_on,latitude,longitude" > filtered.csv

# Export photo license breakdown
curl -H "Accept: text/csv" \
  "http://localhost:3001/mv_photo_licenses?order=total.desc" > licenses.csv
```

### API security notice

The PostgREST API is **unauthenticated by default** — anyone with network access to port 3001 can query the full dataset. This is acceptable on trusted networks or when bound to localhost (the default), but you should add authentication before exposing it to the internet.

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

### Seeding a small test dataset

For local testing without downloading the full ~10 GB dataset, you can insert sample data directly:

```bash
docker compose exec postgres psql -U observa -d inaturalist <<'SQL'
INSERT INTO taxa (taxon_id, name, rank, rank_level, active)
VALUES (1, 'Aves', 'class', 50, true),
       (2, 'Turdus migratorius', 'species', 10, true);

INSERT INTO observers (observer_id, login, name)
VALUES (1, 'testuser', 'Test User');

INSERT INTO observations (observation_uuid, observer_id, latitude, longitude, taxon_id, quality_grade, observed_on)
VALUES ('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 1, 36.5, -82.5, 2, 'research', '2025-06-15');

INSERT INTO photos (photo_uuid, photo_id, observation_uuid, observer_id, license)
VALUES ('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 1, 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 1, 'CC-BY');
SQL
```

Then refresh the materialized views so dashboards reflect the test data:

```bash
docker compose exec postgres psql -U observa -d inaturalist -f /docker-entrypoint-initdb.d/../scripts/create-materialized-views.sql
```

Note: the views script is mounted at `/scripts` inside the importer container, but accessible from the postgres container only if you mount it separately. Alternatively, run it from the importer:

```bash
docker compose exec importer psql -f /scripts/create-materialized-views.sql
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

## Data Source

This project uses the [iNaturalist Open Dataset](https://github.com/inaturalist/inaturalist-open-data), which is hosted on the [AWS Open Data Registry](https://registry.opendata.aws/inaturalist-open-data/). The dataset includes observations, photos, taxa, and observer metadata published under Creative Commons licenses. See the upstream repository for licensing and attribution details.

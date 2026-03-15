# Observa

A Dockerized platform for hosting and exploring [iNaturalist Open Data](https://github.com/inaturalist/inaturalist-open-data) from the AWS Open Registry. Includes a PostGIS-enabled PostgreSQL database, automated daily imports, and a Grafana dashboard.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) and Docker Compose v2+
- ~50 GB of free disk space (for downloaded CSVs and database storage)

## Quick Start

1. **Clone and configure**

   ```bash
   git clone jmcmeen/observa && cd observa
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

   This starts PostgreSQL (with PostGIS), Grafana, and the importer container.

3. **Run the initial import**

   The first import must be triggered manually. This downloads ~10 GB of compressed data from S3 and loads it into the database. It will take a while depending on your connection and hardware.

   ```bash
   docker compose run --rm --entrypoint /import.sh importer
   ```

4. **Open the dashboard**

   Navigate to [http://localhost:3000](http://localhost:3000) and log in with the credentials from your `.env` file (default: `admin` / `changeme`). The "iNaturalist Overview" dashboard is pre-provisioned.

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

## Services

| Service | Port | Description |
|---|---|---|
| `postgres` | 5432 | PostGIS 16 database with iNaturalist data |
| `grafana` | 3000 | Dashboard UI |
| `importer` | — | Cron-based ETL container (no exposed ports) |

## Daily Imports

The importer runs on the schedule defined by `IMPORT_CRON`. Each run performs a full refresh:

1. Downloads the latest CSVs from `s3://inaturalist-open-data`
2. Truncates and reloads all tables
3. Rebuilds PostGIS geometry and indexes
4. Logs results to the `import_log` table

To trigger a manual import:

```bash
docker compose run --rm --entrypoint /import.sh importer
```

To check import logs:

```bash
docker compose exec postgres psql -U observa -d inaturalist \
  -c "SELECT * FROM import_log ORDER BY id DESC LIMIT 5;"
```

## Connecting Directly to the Database

```bash
docker compose exec postgres psql -U observa -d inaturalist
```

Or from your host (with a PostgreSQL client installed):

```bash
psql -h localhost -U observa -d inaturalist
```

## Data Source

This project uses the [iNaturalist Open Dataset](https://github.com/inaturalist/inaturalist-open-data), which is hosted on the [AWS Open Data Registry](https://registry.opendata.aws/inaturalist-open-data/). The dataset includes observations, photos, taxa, and observer metadata published under Creative Commons licenses. See the upstream repository for licensing and attribution details.

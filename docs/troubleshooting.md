# Troubleshooting Guide

Common problems, what causes them, and how to fix them.

## Import issues

### Import is stuck or hung

**Symptom:** The "Import stuck running" alert fires, or `import_log` shows a row with `status = 'running'` for hours.

**Check the current state:**

```bash
# Is the importer container running?
docker compose ps importer

# Check import logs for errors
docker compose logs --tail 100 importer

# Check database for stuck imports
docker compose exec postgres psql -U observa -d inaturalist -c \
  "SELECT id, started_at, status, duration_seconds FROM import_log WHERE status = 'running';"
```

**Common causes:**

- **S3 download stalled** — The `--cli-read-timeout 300` flag should prevent this, but network issues can still cause hangs. Check if the container is consuming bandwidth.
- **Staging table loading** — Loading ~200M observations takes time. The `load_staging` phase is normally the longest step.
- **Container was killed** — If the container was stopped mid-import (`docker compose down`, OOM kill, host reboot), the `import_log` row stays as `running` and the lock file persists.

**Fix:**

```bash
# If the import process is genuinely dead, mark it as failed
docker compose exec postgres psql -U observa -d inaturalist -c \
  "UPDATE import_log SET status = 'failed', finished_at = now(), error_message = 'Manually marked as failed (process died)' WHERE status = 'running';"

# The lock file is automatically cleaned up on next run (stale PID detection),
# but you can also remove it manually
docker compose exec importer rm -rf /tmp/import.lock
```

### Import fails with "relation already exists"

**Symptom:** Log shows `ERROR: relation "idx_stg_observations_taxon_id" already exists`.

**Cause:** This was a bug in versions before v0.1.2 where `CREATE TABLE ... (LIKE taxa INCLUDING ALL)` copied indexes from the live tables (which were previously staging tables). Fixed by using `INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING GENERATED` instead.

**Fix:** Update to v0.1.2+. If you can't update immediately, drop the staging tables manually:

```bash
docker compose exec postgres psql -U observa -d inaturalist -c \
  "DROP TABLE IF EXISTS observations_staging, photos_staging, taxa_staging, observers_staging CASCADE;"
```

### Import fails with "Corrupt file detected"

**Symptom:** Log shows `ERROR: Corrupt file detected: observations.csv.gz — removing from cache`.

**Cause:** A downloaded file failed `gunzip -t` integrity check. Usually caused by an interrupted download or disk issue.

**Fix:** The importer automatically deletes the corrupt file and its ETag cache. Just re-run the import — it will re-download the file:

```bash
docker compose run --rm --entrypoint /import.sh importer
```

### Import fails with observation count drop

**Symptom:** Log shows `ERROR: observations.csv has X rows, less than 50% of previous import`.

**Cause:** A safety check aborted the import because the new data has dramatically fewer rows than the previous successful import. This usually means the upstream data file is truncated or corrupted.

**What to do:**

1. Check if iNaturalist is having issues with their S3 data (this is rare but happens).
2. If you're confident the data is correct (e.g., you're importing a subset intentionally), clear the cache and import fresh:

```bash
docker compose down
docker volume rm observa_import_cache
docker compose up -d
docker compose run --rm --entrypoint /import.sh importer
```

### Import skipping never activates

**Symptom:** Every cron run does a full import even when data hasn't changed.

**Check ETag cache state:**

```bash
# Check if cache files exist
docker compose exec importer ls -la /cache/

# Check stored ETags
docker compose exec importer cat /cache/*.etag
```

**Common causes:**

- **Cache volume was deleted** — If `import_cache` volume is removed, ETags are lost and every file looks "new".
- **Previous import failed** — The skip logic only activates when the last import was `completed`. If the last run failed, the importer will always retry.

### "Another import is already running"

**Symptom:** Log shows `ERROR: Another import (PID X) is already running. Exiting.`

**Cause:** A legitimate concurrent import is running, or the PID from the lock file happens to match an unrelated process.

**Check:**

```bash
# See if an import is actually running
docker compose exec importer ps aux | grep import

# If nothing is running, the lock is stale — it will auto-recover on next run.
# To fix immediately:
docker compose exec importer rm -rf /tmp/import.lock
```

### "Lock exists but no PID file found"

**Symptom:** `ERROR: Lock exists but no PID file found. Remove /tmp/import.lock manually.`

**Cause:** The lock directory exists but has no `pid` file inside. This can happen if the lock was created by an older version of the script (before PID tracking was added).

**Fix:**

```bash
docker compose exec importer rm -rf /tmp/import.lock
```

## Database issues

### PostgreSQL won't start

**Check logs:**

```bash
docker compose logs postgres
```

**Common causes:**

- **Disk full** — PostgreSQL needs space for WAL files and temp operations. Free up disk space.
- **Corrupted data volume** — Rare, but can happen after an unclean shutdown. Restore from backup (see below).
- **Config error** — If you modified `postgresql.conf`, check for syntax errors. The container will fail to start with an explicit error message.

### Queries are slow

**Check which queries are running:**

```bash
docker compose exec postgres psql -U observa -d inaturalist -c \
  "SELECT pid, now() - pg_stat_activity.query_start AS duration, query
   FROM pg_stat_activity
   WHERE state = 'active' AND query NOT LIKE '%pg_stat_activity%'
   ORDER BY duration DESC;"
```

**Common causes and fixes:**

- **Missing indexes** — Run the index creation script if indexes were lost during a failed import:
  ```bash
  docker compose exec postgres psql -U observa -d inaturalist -f /docker-entrypoint-initdb.d/../scripts/create-indexes.sql
  ```
- **Stale materialized views** — If views weren't refreshed after an import:
  ```bash
  docker compose exec importer psql -f /scripts/refresh-materialized-views.sql
  ```
- **Low memory** — If `work_mem` is too low for your queries, PostgreSQL spills to disk. Check `postgresql.conf` and consider increasing `work_mem` (but watch total memory usage: `work_mem` x `max_parallel_workers_per_gather` x active queries).

### Materialized views are empty

**Symptom:** Dashboard panels show no data, but the base tables have rows.

**Cause:** Views haven't been refreshed since the tables were populated (common after the first import or a restore from backup).

**Fix:**

```bash
docker compose exec importer psql -f /scripts/create-materialized-views.sql
```

## Grafana issues

### Dashboards show "No data"

**Check in order:**

1. **Is the database populated?**
   ```bash
   docker compose exec postgres psql -U observa -d inaturalist -c \
     "SELECT count(*) FROM observations;"
   ```

2. **Are materialized views populated?**
   ```bash
   docker compose exec postgres psql -U observa -d inaturalist -c \
     "SELECT count(*) FROM mv_top_taxa;"
   ```

3. **Is the datasource working?** Go to Grafana > Connections > Data Sources > iNaturalist > Test. If it fails, check that `POSTGRES_PASSWORD` in `.env` matches what the database was initialized with.

### Alerts aren't firing

**Possible causes:**

- **No notification channels configured** — By default, alerts are only visible in the Grafana UI. Configure contact points (email, Slack, etc.) under Alerting > Contact Points.
- **Alert evaluation paused** — Check Alerting > Alert Rules to see if rules are active.
- **Thresholds not met** — The default thresholds are:
  - Import stale: >36 hours since last successful import
  - Import failed: latest import has `status = 'failed'`
  - Observation count drop: >10% decrease between consecutive imports
  - Import hung: any import in `running` state for >4 hours

### Setting up Slack notifications

1. Create an [Incoming Webhook](https://api.slack.com/messaging/webhooks) in your Slack workspace.
2. Add the webhook URL to `.env`:
   ```
   SLACK_WEBHOOK_URL=https://hooks.slack.com/services/T.../B.../...
   ```
3. In Grafana, go to Alerting > Contact Points > Add contact point, select Slack, and paste your webhook URL.
4. Assign the contact point to your notification policy under Alerting > Notification policies.

## Backup and recovery

### Restoring from a backup

```bash
# List available backups
docker compose run --rm --profile backup --entrypoint ls backup /backups

# Restore (--clean drops existing objects first)
docker compose run --rm --profile backup --entrypoint sh backup -c \
  "pg_restore -h postgres -U observa -d inaturalist --clean /backups/observa_20260315_030000.dump"

# Refresh materialized views after restore
docker compose exec importer psql -f /scripts/create-materialized-views.sql
```

### Verifying backup integrity

Test a backup without actually restoring it:

```bash
docker compose run --rm --profile backup --entrypoint sh backup -c \
  "pg_restore --list /backups/observa_20260315_030000.dump > /dev/null && echo 'Backup is valid'"
```

### Backup is too large

Backups use PostgreSQL custom format (`-Fc`), which is already compressed. Typical backup size is roughly 30-40% of the raw database size. If disk is tight:

- Reduce `BACKUP_RETENTION` in `.env` (default is 4)
- Delete old backups manually:
  ```bash
  docker compose run --rm --profile backup --entrypoint sh backup -c \
    "ls -lh /backups/ && rm /backups/observa_20260301_030000.dump"
  ```

## Container issues

### "FATAL: PGPASSWORD is still set to 'changeme'"

**Cause:** The importer refuses to start with the default password.

**Fix:** Set a real password in `.env`:

```
POSTGRES_PASSWORD=your_secure_password
```

Then restart: `docker compose up -d`

### Cache persists after `docker volume prune`

`docker volume prune` only removes **unused** volumes. If containers exist (even stopped), their volumes are considered "in use".

**Fix:**

```bash
docker compose down
docker volume rm observa_import_cache
```

Or to remove all project volumes:

```bash
docker compose down -v
```

### Out of disk space

**Check usage:**

```bash
docker system df
docker compose exec postgres psql -U observa -d inaturalist -c \
  "SELECT pg_size_pretty(pg_database_size('inaturalist'));"
```

**Free space:**

- Remove old backups (see above)
- Clear the import cache: `docker volume rm observa_import_cache`
- Prune unused Docker images: `docker image prune`
- The database itself requires ~40-50 GB — this is not reducible without dropping tables

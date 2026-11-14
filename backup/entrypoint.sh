#!/bin/sh
set -e

# BACKUP_ENABLED=false keeps the container idle: no schedule, but
# `docker compose exec backup /backup.sh` still takes a backup on demand.
if [ "${BACKUP_ENABLED:-true}" = "false" ]; then
    echo "Scheduled backups are disabled (BACKUP_ENABLED=false)."
    echo "Run '/backup.sh' manually inside the container to take one."
    exec tail -f /dev/null
fi

# Generate crontab from environment variable
echo "${BACKUP_CRON:-0 2 * * 0} /bin/sh /backup.sh >> /proc/1/fd/1 2>&1" > /var/spool/cron/crontabs/root

echo "Starting backup service with schedule: ${BACKUP_CRON:-0 2 * * 0}"
echo "Run '/backup.sh' manually inside the container to trigger an immediate backup."

exec crond -f -l 2

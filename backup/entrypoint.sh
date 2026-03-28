#!/bin/sh
set -e

# Generate crontab from environment variable
echo "${BACKUP_CRON:-0 2 * * 0} /bin/sh /backup.sh >> /proc/1/fd/1 2>&1" > /var/spool/cron/crontabs/root

echo "Starting backup service with schedule: ${BACKUP_CRON:-0 2 * * 0}"
echo "Run '/backup.sh' manually inside the container to trigger an immediate backup."

exec crond -f -l 2

#!/bin/sh
set -e

# Generate crontab from environment variable
echo "${IMPORT_CRON:-0 3 * * *} /import.sh >> /var/log/import.log 2>&1" > /tmp/crontab

echo "Starting importer with schedule: ${IMPORT_CRON:-0 3 * * *}"
echo "Run '/import.sh' manually inside the container to trigger an immediate import."

exec supercronic /tmp/crontab

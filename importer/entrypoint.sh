#!/bin/sh
set -e

# Refuse to start with default credentials
if [ "$PGPASSWORD" = "changeme" ]; then
  echo "FATAL: PGPASSWORD is still set to 'changeme'. Set a real password in .env before starting." >&2
  exit 1
fi

# Generate crontab from environment variable
echo "${IMPORT_CRON:-0 3 * * *} /import.sh" > /tmp/crontab

echo "Starting importer with schedule: ${IMPORT_CRON:-0 3 * * *}"
echo "Run '/import.sh' manually inside the container to trigger an immediate import."

exec supercronic /tmp/crontab

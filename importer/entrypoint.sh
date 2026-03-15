#!/bin/sh
set -e

# Refuse to start with default credentials
for var in PGPASSWORD; do
  eval val=\$$var
  if [ "$val" = "changeme" ]; then
    echo "FATAL: $var is still set to 'changeme'. Set a real password in .env before starting." >&2
    exit 1
  fi
done

# Generate crontab from environment variable
echo "${IMPORT_CRON:-0 3 * * *} /import.sh" > /tmp/crontab

echo "Starting importer with schedule: ${IMPORT_CRON:-0 3 * * *}"
echo "Run '/import.sh' manually inside the container to trigger an immediate import."

exec supercronic /tmp/crontab

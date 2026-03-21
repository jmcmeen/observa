#!/bin/sh
set -e

# Refuse to start with default credentials
if [ "$PGPASSWORD" = "changeme" ]; then
  echo "FATAL: PGPASSWORD is still set to 'changeme'. Set a real password in .env before starting." >&2
  exit 1
fi

if [ "$GF_SECURITY_ADMIN_PASSWORD" = "changeme" ]; then
  echo "FATAL: GF_SECURITY_ADMIN_PASSWORD is still set to 'changeme'. Set a real password in .env before starting." >&2
  exit 1
fi

# Generate crontab from environment variable
echo "${IMPORT_CRON:-0 3 * * *} /bin/sh /import.sh >> /proc/1/fd/1 2>&1" > /var/spool/cron/crontabs/root

echo "Starting importer with schedule: ${IMPORT_CRON:-0 3 * * *}"
echo "Run '/import.sh' manually inside the container to trigger an immediate import."

exec crond -f -l 2

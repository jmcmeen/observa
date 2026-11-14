#!/bin/sh
set -e

BACKUP_DIR="/backups"
RETENTION=${BACKUP_RETENTION:-4}
TIMESTAMP=$(date -u '+%Y%m%d_%H%M%S')
BACKUP_FILE="${BACKUP_DIR}/observa_${TIMESTAMP}.dump"
# Dump to a temporary name and rename on success, so a dump cut short (container
# stopped, disk full) never looks like a usable backup or counts toward retention.
PARTIAL_FILE="${BACKUP_FILE}.partial"

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"; }

log "=== Database backup started ==="

# One backup at a time on the shared volume. A second run (another replica, or a
# manual run during a scheduled one) skips instead of writing or deleting the
# first run's files. The lock goes away with the process, so it is never stale.
exec 9> "${BACKUP_DIR}/.backup.lock"
if ! flock -n 9; then
    log "Another backup is already running; not starting a second."
    exit 0
fi

# Leftovers from an earlier interrupted run
rm -f "${BACKUP_DIR}"/observa_*.dump.partial
trap 'rm -f "$PARTIAL_FILE"' EXIT

# Create backup using custom format (compressed)
pg_dump -Fc -f "$PARTIAL_FILE"
mv "$PARTIAL_FILE" "$BACKUP_FILE"

FILESIZE=$(du -h "$BACKUP_FILE" | cut -f1)
log "Backup created: ${BACKUP_FILE} (${FILESIZE})"

# Remove old backups, keeping the most recent N
BACKUP_COUNT=$(ls -1 "${BACKUP_DIR}"/observa_*.dump 2>/dev/null | wc -l)
if [ "$BACKUP_COUNT" -gt "$RETENTION" ]; then
    REMOVE_COUNT=$((BACKUP_COUNT - RETENTION))
    ls -1 "${BACKUP_DIR}"/observa_*.dump | sort | head -n "$REMOVE_COUNT" | while read -r old_backup; do
        log "Removing old backup: ${old_backup}"
        rm -f "$old_backup"
    done
fi

log "=== Backup completed (${BACKUP_COUNT} total, keeping last ${RETENTION}) ==="

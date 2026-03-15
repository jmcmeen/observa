#!/bin/sh
set -e

BACKUP_DIR="/backups"
RETENTION=${BACKUP_RETENTION:-4}
TIMESTAMP=$(date -u '+%Y%m%d_%H%M%S')
BACKUP_FILE="${BACKUP_DIR}/observa_${TIMESTAMP}.dump"

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"; }

log "=== Database backup started ==="

# Create backup using custom format (compressed)
pg_dump -Fc -f "$BACKUP_FILE"

FILESIZE=$(du -h "$BACKUP_FILE" | cut -f1)
log "Backup created: ${BACKUP_FILE} (${FILESIZE})"

# Remove old backups, keeping the most recent N
BACKUP_COUNT=$(ls -1 "${BACKUP_DIR}"/observa_*.dump 2>/dev/null | wc -l)
if [ "$BACKUP_COUNT" -gt "$RETENTION" ]; then
    REMOVE_COUNT=$((BACKUP_COUNT - RETENTION))
    ls -1t "${BACKUP_DIR}"/observa_*.dump | tail -n "$REMOVE_COUNT" | while read -r old_backup; do
        log "Removing old backup: ${old_backup}"
        rm -f "$old_backup"
    done
fi

log "=== Backup completed (${BACKUP_COUNT} total, keeping last ${RETENTION}) ==="

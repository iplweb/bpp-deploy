#!/usr/bin/env bash
#
# Codzienny cykl backupu: pg_dump -> tar media -> lokalna rotacja -> rclone
# sync -> Rollbar notify. Wywolywane przez Ofelie (label na kontenerze
# backup-runner) lub recznie: `make backup-cycle`.
#
# Wymagane zmienne srodowiskowe (z env_file w docker-compose.backup.yml):
#   DJANGO_BPP_DB_HOST, DJANGO_BPP_DB_PORT, DJANGO_BPP_DB_USER,
#   DJANGO_BPP_DB_PASSWORD, DJANGO_BPP_DB_NAME, DJANGO_BPP_HOSTNAME
#
# Opcjonalne:
#   ROLLBAR_ACCESS_TOKEN         - gdy pusty, notify jest no-opem
#   DJANGO_BPP_RCLONE_REMOTE     - target rclone, default "backup_enc:"
#   DJANGO_BPP_BACKUP_KEEP_LAST  - ile kopii lokalnie, default 7
#   PARALLEL_JOBS                - pg_dump -j, default 4
#
# Exit codes:
#   0 - pelny sukces
#   1 - pg_dump lub tar bazy failed
#   2 - tar media failed
#   3 - rclone sync failed (lokalne backupy zostaly utworzone)

set -o pipefail

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
START_TS=$(date +%s)
DB_DIR="/backup/db-backup-${TIMESTAMP}"
DB_TAR="/backup/db-backup-${TIMESTAMP}.tar.gz"
MEDIA_TAR="/backup/media-backup-${TIMESTAMP}.tar.gz"
REMOTE="${DJANGO_BPP_RCLONE_REMOTE:-backup_enc:}"
REMOTE_DIR="${REMOTE}$(date +%Y-%m)/$(date +%d)/"
KEEP_LAST="${DJANGO_BPP_BACKUP_KEEP_LAST:-7}"
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"
RCLONE_CONFIG="/config/rclone/rclone.conf"
LOG="/tmp/backup-cycle.log"

: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

fmt_size() {
    local bytes="$1"
    numfmt --to=iec --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B"
}

notify_rollbar() {
    local level="$1" message="$2"
    if [ -z "${ROLLBAR_ACCESS_TOKEN:-}" ]; then
        log "rollbar: skip (ROLLBAR_ACCESS_TOKEN not set)"
        return 0
    fi
    local body_json
    body_json="$(printf '%s' "$message" | jq -Rs .)"
    local payload
    payload=$(cat <<JSON
{"access_token":"$ROLLBAR_ACCESS_TOKEN","data":{"environment":"${DJANGO_BPP_HOSTNAME:-unknown}","level":"$level","body":{"message":{"body":$body_json}},"custom":{"component":"backup-cycle","timestamp":"$TIMESTAMP"}}}
JSON
)
    local http_code
    http_code=$(curl -sS -o /dev/null -w "%{http_code}" -m 10 \
        -H "Content-Type: application/json" \
        -X POST https://api.rollbar.com/api/1/item/ \
        -d "$payload" 2>/dev/null || echo "000")
    log "rollbar: POST level=$level http=$http_code"
}

fail() {
    local step="$1" code="$2"
    log "FAIL: $step (exit=$code)"
    local tail_log
    tail_log="$(tail -c 2000 "$LOG")"
    notify_rollbar error "Backup FAIL on ${DJANGO_BPP_HOSTNAME:-unknown}: step=$step exit=$code
Log tail:
$tail_log"
    exit "$code"
}

# --- 1. pg_dump bazy do /backup (bind-mount hosta) ---
log "pg_dump $DJANGO_BPP_DB_NAME from $DJANGO_BPP_DB_HOST:$DJANGO_BPP_DB_PORT..."
if ! pg_dump -Fd -j "$PARALLEL_JOBS" \
        -h "$DJANGO_BPP_DB_HOST" -p "$DJANGO_BPP_DB_PORT" \
        -U "$DJANGO_BPP_DB_USER" "$DJANGO_BPP_DB_NAME" \
        -f "$DB_DIR"; then
    fail "pg_dump" 1
fi
log "tar db dump..."
tar czf "$DB_TAR" -C /backup "db-backup-${TIMESTAMP}" || fail "db-tar" 1
rm -rf "$DB_DIR"
DB_SIZE=$(stat -c%s "$DB_TAR" 2>/dev/null || stat -f%z "$DB_TAR" 2>/dev/null || echo 0)
log "db-backup ok: $DB_TAR ($(fmt_size "$DB_SIZE"))"

# --- 2. tar media volume ---
log "tar media from /mediaroot..."
if ! tar czf "$MEDIA_TAR" -C /mediaroot .; then
    fail "media-tar" 2
fi
MEDIA_SIZE=$(stat -c%s "$MEDIA_TAR" 2>/dev/null || stat -f%z "$MEDIA_TAR" 2>/dev/null || echo 0)
log "media-backup ok: $MEDIA_TAR ($(fmt_size "$MEDIA_SIZE"))"

# --- 3. Lokalna rotacja - zachowaj N najnowszych kopii kazdego typu ---
prune_type() {
    local prefix="$1"
    # Nazwy plikow maja format ${prefix}-YYYYMMDD-HHMMSS.tar.gz, wiec
    # sort leksykograficzny = sort chronologiczny. find+sort zamiast ls -1t
    # bo shellcheck (SC2012) preferuje find, a busybox find w alpine nie
    # ma -printf.
    find /backup -maxdepth 1 -type f -name "${prefix}-*.tar.gz" 2>/dev/null \
        | sort -r \
        | tail -n +$((KEEP_LAST + 1)) \
        | while IFS= read -r f; do
            [ -n "$f" ] && log "prune: removing $f" && rm -f "$f"
        done
}
log "local rotation: keep last $KEEP_LAST per type"
prune_type db-backup
prune_type media-backup

# --- 4. rclone sync ---
log "rclone sync /backup/ -> $REMOTE_DIR"
if [ ! -f "$RCLONE_CONFIG" ]; then
    fail "rclone-config-missing" 3
fi
if ! rclone sync /backup/ "$REMOTE_DIR" --config "$RCLONE_CONFIG"; then
    fail "rclone-sync" 3
fi
log "rclone sync ok"

# --- 5. Sukces - notify ---
END_TS=$(date +%s)
DURATION=$(( END_TS - START_TS ))
MSG="Backup OK on ${DJANGO_BPP_HOSTNAME:-unknown}: db=$(fmt_size "$DB_SIZE") media=$(fmt_size "$MEDIA_SIZE") remote=$REMOTE_DIR duration=${DURATION}s keep_last=$KEEP_LAST"
log "$MSG"
notify_rollbar info "$MSG"

exit 0

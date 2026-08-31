#!/usr/bin/env bash
#
# Reczna, wymuszona wysylka lokalnych backupow na zdalny (`make rclone-sync`).
# Ten sam uklad katalogow co nocny cykl: JEDEN katalog na miesiac.
#
# Logika sciezki docelowej siedzi w scripts/lib-rclone.sh, a nie tutaj i nie w
# mk/rclone.mk - wczesniej ta sama sciezka byla wpisana w dwoch miejscach
# (Makefile i backup-cycle.sh) i nic nie pilnowalo, zeby sie nie rozjechaly.
#
# CRITICAL: `copy`, nie `sync` - patrz komentarz w scripts/lib-rclone.sh.
# Ten skrypt CELOWO nie robi retencji: kasowanie czegokolwiek na zdalnym
# nalezy wylacznie do nocnego cyklu, ktory robi to po udanej wysylce.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib-rclone.sh
. "$SCRIPT_DIR/lib-rclone.sh"

BACKUP_DIR="${BPP_BACKUP_DIR:-/backup}"
RCLONE_CONFIG="${BPP_RCLONE_CONFIG:-/config/rclone/rclone.conf}"
REMOTE="${DJANGO_BPP_RCLONE_REMOTE:-backup_enc:}"
DEST="$(rclone_month_dir "$REMOTE" "$(date +%Y-%m)")"

if [ ! -f "$RCLONE_CONFIG" ]; then
    echo "BLAD: brak konfiguracji rclone ($RCLONE_CONFIG). Uruchom: make rclone-config" >&2
    exit 3
fi

echo "rclone copy $BACKUP_DIR/ -> $DEST"
exec rclone copy "$BACKUP_DIR/" "$DEST" --config "$RCLONE_CONFIG" --progress

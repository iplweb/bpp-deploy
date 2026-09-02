#!/bin/sh
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

# shellcheck shell=sh
# shellcheck disable=SC3040  # `set -o pipefail`: swiadome odstepstwo od POSIX.
#   Busybox ash i bash je maja, dash nie - stad preflight nizej. Kontrakty
#   o SIGPIPE (patrz lib-rclone.sh) bez pipefail przestaja obowiazywac.
#   UWAGA: dyrektywa musi stac PRZED wszelkim kodem (rowniez przed preflightem),
#   inaczej jest lokalna dla jednej linii i nie gasi drugiego wystapienia
#   `set -o pipefail` ponizej - zweryfikowane realnym shellcheckiem.

# Docelowe obrazy (docker:cli, rclone/rclone) nie maja basha, wiec shebang musi byc
# /bin/sh. Ale na Debianie /bin/sh to dash, ktory NIE zna `pipefail` - a na nim stoja
# kontrakty o SIGPIPE w tym repo. Wiec: jesli powloka nie ma pipefail, przeskakujemy
# na basha; jesli basha tez nie ma, giniemy z czytelnym komunikatem zamiast dziwnie.
if ! (set -o pipefail) 2>/dev/null; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    fi
    echo "BLAD: ten skrypt wymaga powloki z pipefail (busybox ash albo bash)." >&2
    echo "      dash jej nie ma - uruchom przez bash albo wewnatrz kontenera." >&2
    exit 1
fi

set -eu
set -o pipefail

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

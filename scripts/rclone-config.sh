#!/usr/bin/env bash
#
# `make rclone-config` — kreator konfiguracji zdalnego backupu.
# Uruchamiany WEWNATRZ backup-runnera: rclone jest doinstalowywany w tym
# kontenerze, na hoscie go nie zakladamy.
#
# Poza odpaleniem kreatora robi jedna rzecz wiecej: wyrownuje wlasciciela
# powstalego rclone.conf do wlasciciela katalogu na hoscie. Uzasadnienie
# i kody wyjscia — patrz rclone_fix_config_owner w scripts/lib-rclone.sh.
#
# Katalog /config/rclone MUSI byc montowany read-write (docker-compose.backup.yml).
# Przy :ro kreator wypisuje "Failed to save config after 10 tries: ...
# read-only file system" przy KAZDEJ odpowiedzi, ale brnie do konca — mozna
# przeklikac cala konfiguracje i nie zauwazyc, ze nic nie powstalo.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib-rclone.sh
. "$SCRIPT_DIR/lib-rclone.sh"

RCLONE_CONFIG="${BPP_RCLONE_CONFIG:-/config/rclone/rclone.conf}"

RC=0
rclone --config "$RCLONE_CONFIG" config || RC=$?

FIX_RC=0
rclone_fix_config_owner "$RCLONE_CONFIG" || FIX_RC=$?

case "$FIX_RC" in
    0) ;;
    1)
        # Tylko gdy sam kreator wyszedl czysto. Przy niezerowym RC (np. rclone
        # jeszcze niedoinstalowany -> 127, Ctrl-C -> 130) wlasciwy komunikat
        # padl juz wyzej, a ten by go tylko przykryl falszywym tropem.
        if [ "$RC" -eq 0 ]; then
            echo "UWAGA: nie powstal $RCLONE_CONFIG — kreator zakonczyl sie bez zapisania" >&2
            echo "       konfiguracji. Jesli w trakcie pojawialo sie 'read-only file system'," >&2
            echo "       odtworz kontener: git pull && make up" >&2
        fi
        ;;
    *)
        echo "UWAGA: nie udalo sie wyrownac wlasciciela $RCLONE_CONFIG (kod $FIX_RC)." >&2
        echo "       Backupy beda dzialac normalnie, ale plik zostaje wlasnoscia roota:" >&2
        echo "       przy przenosinach serwera kopiuj \$BPP_CONFIGS_DIR przez sudo rsync." >&2
        ;;
esac

exit "$RC"

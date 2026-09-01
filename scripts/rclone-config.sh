#!/bin/sh
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
# na basha; jesli basha tez nie ma, gliniemy z czytelnym komunikatem zamiast dziwnie.
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

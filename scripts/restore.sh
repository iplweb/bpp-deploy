#!/usr/bin/env bash
#
# Disaster recovery / klonowanie srodowiska: wczytaj backup zrobiony przez
# `make backup` (lub `make backup-cycle`) z powrotem do uruchomionego stacka.
#
# Strategia:
#   1. Wybor pary tarballi (db + media) o tym samym timestampie.
#   2. (Domyslnie) bezpieczny backup biezacego stanu jako fallback.
#   3. Stop appserver/workers/beat/denorm-queue.
#   4. dropdb + createdb + pg_restore -Fd -j N na bazie.
#   5. tar xzf media-backup na volume media.
#   6. make up.
#
# Wybor backupu:
#   - bez argumentow: najnowsza para db-backup-*.tar.gz + media-backup-*.tar.gz
#     (parowanie po timestampie YYYYMMDD-HHMMSS w nazwie pliku).
#   - --timestamp=YYYYMMDD-HHMMSS: konkretna para.
#   - --pick: interaktywny wybor (fzf jesli dostepne, fallback do numerowanego
#     menu w czystym shellu).
#
# Wywolanie: `make restore` lub bezposrednio `bash scripts/restore.sh`.
#
# UWAGA: ta operacja niszczy aktualna baze i nadpisuje volume media. Domyslnie
# robi safety-backup biezacego stanu PRZED restorem (mozna pominac flaga
# --no-safety-backup). Tarball safety-backupa zostaje w katalogu backupow.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ENV="$REPO_DIR/.env"

# ---- Parsowanie argumentow ----------------------------------------------
TIMESTAMP_ARG=""
PICK=0
DB_ONLY=0
MEDIA_ONLY=0
SAFETY_BACKUP=1
NOINPUT=0

while [ $# -gt 0 ]; do
    case "$1" in
        --timestamp=*) TIMESTAMP_ARG="${1#*=}"; shift ;;
        --timestamp)   TIMESTAMP_ARG="${2:-}"; shift 2 || { echo "BLAD: --timestamp wymaga wartosci." >&2; exit 1; } ;;
        --pick)        PICK=1; shift ;;
        --db-only)     DB_ONLY=1; shift ;;
        --media-only)  MEDIA_ONLY=1; shift ;;
        --no-safety-backup) SAFETY_BACKUP=0; shift ;;
        --noinput|--non-interactive|--yes) NOINPUT=1; shift ;;
        -h|--help)
            cat <<'HELP_EOF'
Uzycie: restore.sh [OPCJE]

  --timestamp=YYYYMMDD-HHMMSS  Wybierz konkretna pare backupow (db + media).
                               Domyslnie: najnowsza para w katalogu backupow.

  --pick                       Interaktywny wybor backupu. Uzywa fzf jesli
                               dostepne, w przeciwnym razie pokazuje
                               numerowane menu.

  --db-only                    Restore tylko bazy danych (pomija media).
  --media-only                 Restore tylko mediow (pomija baze).

  --no-safety-backup           Pomija automatyczny backup biezacego stanu
                               przed restorem. NIE ZALECANE poza testami.

  --noinput, --yes             Tryb nieinteraktywny - wszystkie potwierdzenia
                               auto-yes. Uzywaj swiadomie.

  -h, --help                   Ten ekran.

Przyklady:
  bash scripts/restore.sh                               # najnowsza para, z safety
  bash scripts/restore.sh --pick                        # interaktywny wybor
  bash scripts/restore.sh --timestamp=20260428-140218   # konkretna para
  bash scripts/restore.sh --db-only --no-safety-backup  # tylko baza, bez safety
HELP_EOF
            exit 0
            ;;
        *) echo "BLAD: nieznana opcja: $1 (zobacz --help)" >&2; exit 1 ;;
    esac
done

if [ "$DB_ONLY" = 1 ] && [ "$MEDIA_ONLY" = 1 ]; then
    echo "BLAD: --db-only i --media-only sa wzajemnie wykluczajace." >&2
    exit 1
fi

# ---- Helpers ------------------------------------------------------------
get_env_var() {
    local raw
    raw="$(grep -E "^${1}=" "$2" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
    if [ "${raw#\"}" != "$raw" ] && [ "${raw%\"}" != "$raw" ]; then
        raw="${raw#\"}"; raw="${raw%\"}"
    fi
    if [ "${raw#\'}" != "$raw" ] && [ "${raw%\'}" != "$raw" ]; then
        raw="${raw#\'}"; raw="${raw%\'}"
    fi
    printf '%s' "$raw"
}

confirm() {
    local prompt="$1" answer
    if [ "$NOINPUT" = 1 ]; then
        echo "$prompt [auto-yes via --noinput]"
        return 0
    fi
    read -r -p "$prompt [yes/NO]: " answer
    [ "$answer" = "yes" ]
}

run() { echo "+ $*"; "$@"; }

fmt_size() {
    local f="$1" bytes
    bytes="$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)"
    numfmt --to=iec --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B"
}

# ---- Ladowanie zmiennych konfiguracyjnych ------------------------------
if [ ! -f "$REPO_ENV" ]; then
    echo "BLAD: brak $REPO_ENV. Najpierw uruchom 'make' zeby zainicjalizowac konfiguracje." >&2
    exit 1
fi

: "${BPP_CONFIGS_DIR:=$(get_env_var BPP_CONFIGS_DIR "$REPO_ENV")}"
: "${COMPOSE_PROJECT_NAME:=$(get_env_var COMPOSE_PROJECT_NAME "$REPO_ENV")}"

if [ -z "$BPP_CONFIGS_DIR" ]; then
    echo "BLAD: BPP_CONFIGS_DIR nie ustawione w $REPO_ENV." >&2
    exit 1
fi
if [ -z "$COMPOSE_PROJECT_NAME" ]; then
    echo "BLAD: COMPOSE_PROJECT_NAME nie ustawione w $REPO_ENV." >&2
    exit 1
fi

APP_ENV="$BPP_CONFIGS_DIR/.env"
if [ ! -f "$APP_ENV" ]; then
    echo "BLAD: brak $APP_ENV. Uruchom 'make init-configs'." >&2
    exit 1
fi

DJANGO_BPP_DB_PASSWORD="$(get_env_var DJANGO_BPP_DB_PASSWORD "$APP_ENV")"
DJANGO_BPP_DB_HOST="$(get_env_var DJANGO_BPP_DB_HOST "$APP_ENV")"
DJANGO_BPP_DB_PORT="$(get_env_var DJANGO_BPP_DB_PORT "$APP_ENV")"
DJANGO_BPP_DB_USER="$(get_env_var DJANGO_BPP_DB_USER "$APP_ENV")"
DJANGO_BPP_DB_NAME="$(get_env_var DJANGO_BPP_DB_NAME "$APP_ENV")"

# Katalog backupow - ten sam fallback co w mk/database.mk.
HOST_BACKUP_DIR="$(get_env_var DJANGO_BPP_HOST_BACKUP_DIR "$APP_ENV")"
if [ -z "$HOST_BACKUP_DIR" ]; then
    HOST_BACKUP_DIR="$(get_env_var DJANGO_BPP_BACKUP_DIR "$APP_ENV")"
fi
if [ -z "$HOST_BACKUP_DIR" ]; then
    HOST_BACKUP_DIR="$(cd "$BPP_CONFIGS_DIR/.." && pwd)/backups"
fi
if [ ! -d "$HOST_BACKUP_DIR" ]; then
    echo "BLAD: katalog backupow $HOST_BACKUP_DIR nie istnieje." >&2
    exit 1
fi

PARALLEL_JOBS="${PARALLEL_JOBS:-4}"

# ---- Wybor backupu -------------------------------------------------------
list_timestamps() {
    # Wypisuje unikalne timestampy ktore maja zarowno db-backup jak i media-backup
    # (chyba ze --db-only / --media-only - wtedy tylko jeden typ jest wymagany).
    # Sortuje malejaco (najnowszy pierwszy).
    local db_ts media_ts
    db_ts="$(find "$HOST_BACKUP_DIR" -maxdepth 1 -type f -name 'db-backup-*.tar.gz' \
                | sed 's|.*/db-backup-||; s|\.tar\.gz$||' | sort -r)"
    media_ts="$(find "$HOST_BACKUP_DIR" -maxdepth 1 -type f -name 'media-backup-*.tar.gz' \
                | sed 's|.*/media-backup-||; s|\.tar\.gz$||' | sort -r)"

    if [ "$DB_ONLY" = 1 ]; then
        printf '%s\n' "$db_ts"
    elif [ "$MEDIA_ONLY" = 1 ]; then
        printf '%s\n' "$media_ts"
    else
        # Iloczyn - tylko timestampy obecne w obu zbiorach.
        comm -12 <(printf '%s\n' "$db_ts" | sort) <(printf '%s\n' "$media_ts" | sort) | sort -r
    fi
}

describe_ts() {
    local ts="$1" db_path media_path
    db_path="$HOST_BACKUP_DIR/db-backup-${ts}.tar.gz"
    media_path="$HOST_BACKUP_DIR/media-backup-${ts}.tar.gz"
    local db_size="-" media_size="-"
    [ -f "$db_path" ] && db_size="$(fmt_size "$db_path")"
    [ -f "$media_path" ] && media_size="$(fmt_size "$media_path")"
    printf '%s   db=%-10s media=%-10s' "$ts" "$db_size" "$media_size"
}

pick_timestamp_interactive() {
    local timestamps
    timestamps="$(list_timestamps)"
    if [ -z "$timestamps" ]; then
        echo "BLAD: brak kompletnych par backupow w $HOST_BACKUP_DIR." >&2
        exit 1
    fi

    if command -v fzf >/dev/null 2>&1; then
        local lines selected
        lines="$(while IFS= read -r ts; do describe_ts "$ts"; printf '\n'; done <<<"$timestamps")"
        selected="$(printf '%s' "$lines" | fzf --height=40% --reverse --prompt='Wybierz backup> ' \
                       --header='ENTER=wybierz, ESC=anuluj' || true)"
        if [ -z "$selected" ]; then
            echo "Anulowane." >&2
            exit 1
        fi
        # Pierwsze pole to timestamp (przed pierwsza spacja).
        printf '%s' "${selected%% *}"
    else
        echo "(fzf nie znalezione - prosty wybor)"
        local i=1
        local -a ts_arr=()
        while IFS= read -r ts; do
            [ -z "$ts" ] && continue
            ts_arr+=("$ts")
            printf '  [%d] %s\n' "$i" "$(describe_ts "$ts")" >&2
            i=$((i + 1))
        done <<<"$timestamps"
        local choice
        read -r -p "Numer backupu (1-${#ts_arr[@]}): " choice
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#ts_arr[@]}" ]; then
            echo "BLAD: nieprawidlowy wybor." >&2
            exit 1
        fi
        printf '%s' "${ts_arr[$((choice - 1))]}"
    fi
}

if [ -n "$TIMESTAMP_ARG" ]; then
    TS="$TIMESTAMP_ARG"
elif [ "$PICK" = 1 ]; then
    TS="$(pick_timestamp_interactive)"
else
    TS="$(list_timestamps | head -1)"
    if [ -z "$TS" ]; then
        echo "BLAD: brak kompletnych par backupow w $HOST_BACKUP_DIR." >&2
        echo "      Uruchom backup recznie ('make backup') lub uzyj --db-only/--media-only." >&2
        exit 1
    fi
fi

DB_TAR="db-backup-${TS}.tar.gz"
MEDIA_TAR="media-backup-${TS}.tar.gz"
DB_TAR_PATH="$HOST_BACKUP_DIR/$DB_TAR"
MEDIA_TAR_PATH="$HOST_BACKUP_DIR/$MEDIA_TAR"
DUMP_DIRNAME="db-backup-${TS}"

# Walidacja istnienia plikow
if [ "$MEDIA_ONLY" != 1 ] && [ ! -f "$DB_TAR_PATH" ]; then
    echo "BLAD: nie znaleziono $DB_TAR_PATH." >&2
    exit 1
fi
if [ "$DB_ONLY" != 1 ] && [ ! -f "$MEDIA_TAR_PATH" ]; then
    echo "BLAD: nie znaleziono $MEDIA_TAR_PATH." >&2
    exit 1
fi

# ---- Podsumowanie + potwierdzenie ---------------------------------------
echo
echo "=========================================================="
echo "  BPP RESTORE"
echo "=========================================================="
echo "  Timestamp:        $TS"
echo "  Katalog backupow: $HOST_BACKUP_DIR"
if [ "$MEDIA_ONLY" != 1 ]; then
    echo "  DB tarball:       $DB_TAR ($(fmt_size "$DB_TAR_PATH"))"
fi
if [ "$DB_ONLY" != 1 ]; then
    echo "  Media tarball:    $MEDIA_TAR ($(fmt_size "$MEDIA_TAR_PATH"))"
fi
echo "  Project:          $COMPOSE_PROJECT_NAME"
echo "  DB target:        $DJANGO_BPP_DB_USER@$DJANGO_BPP_DB_HOST:$DJANGO_BPP_DB_PORT/$DJANGO_BPP_DB_NAME"
echo "  Safety backup:    $([ "$SAFETY_BACKUP" = 1 ] && echo TAK || echo NIE)"
echo "=========================================================="
echo
echo "UWAGA: ta operacja:"
[ "$MEDIA_ONLY" != 1 ] && echo "  - DROPNIE i odtworzy baze $DJANGO_BPP_DB_NAME"
[ "$DB_ONLY"    != 1 ] && echo "  - rozpakuje archiwum mediow na volume ${COMPOSE_PROJECT_NAME}_media"
echo "  - zatrzyma appserver, workery, beat, denorm-queue na czas operacji"
echo

if ! confirm "Kontynuowac?"; then
    echo "Anulowane."
    exit 0
fi

# ---- Safety backup biezacego stanu --------------------------------------
if [ "$SAFETY_BACKUP" = 1 ]; then
    echo
    echo "=== Safety backup biezacego stanu (przed restorem) ==="
    if [ "$MEDIA_ONLY" = 1 ]; then
        run make -C "$REPO_DIR" media-backup
    elif [ "$DB_ONLY" = 1 ]; then
        run make -C "$REPO_DIR" db-backup
    else
        run make -C "$REPO_DIR" backup
    fi
fi

# ---- Stop dependent services --------------------------------------------
echo
echo "=== Stop dependent services ==="
run docker compose -f "$REPO_DIR/docker-compose.yml" stop \
    appserver workerserver-general workerserver-denorm denorm-queue celerybeat flower || true

# ---- DB restore ---------------------------------------------------------
if [ "$MEDIA_ONLY" != 1 ]; then
    echo
    echo "=== DB restore z $DB_TAR ==="

    # Tarball jest w $HOST_BACKUP_DIR czyli /backup wewnatrz dbserver (bind-mount).
    # Rozpakuj wewnatrz kontenera, restore, posprzataj rozpakowany katalog.
    run docker compose -f "$REPO_DIR/docker-compose.yml" exec -T dbserver \
        tar xzf "/backup/$DB_TAR" -C /backup

    # Drop + create. Connection do template1 zeby moc zdropnac biezaca baze.
    echo "+ dropdb --force $DJANGO_BPP_DB_NAME"
    docker compose -f "$REPO_DIR/docker-compose.yml" exec -T \
        -e "PGPASSWORD=$DJANGO_BPP_DB_PASSWORD" dbserver \
        dropdb --force \
            -h "$DJANGO_BPP_DB_HOST" -p "$DJANGO_BPP_DB_PORT" \
            -U "$DJANGO_BPP_DB_USER" "$DJANGO_BPP_DB_NAME"

    echo "+ createdb $DJANGO_BPP_DB_NAME"
    docker compose -f "$REPO_DIR/docker-compose.yml" exec -T \
        -e "PGPASSWORD=$DJANGO_BPP_DB_PASSWORD" dbserver \
        createdb \
            -h "$DJANGO_BPP_DB_HOST" -p "$DJANGO_BPP_DB_PORT" \
            -U "$DJANGO_BPP_DB_USER" "$DJANGO_BPP_DB_NAME"

    echo "+ pg_restore -Fd -j $PARALLEL_JOBS"
    docker compose -f "$REPO_DIR/docker-compose.yml" exec -T \
        -e "PGPASSWORD=$DJANGO_BPP_DB_PASSWORD" dbserver \
        pg_restore \
            -Fd -j "$PARALLEL_JOBS" \
            -h "$DJANGO_BPP_DB_HOST" -p "$DJANGO_BPP_DB_PORT" \
            -U "$DJANGO_BPP_DB_USER" -d "$DJANGO_BPP_DB_NAME" \
            --no-owner --no-privileges \
            "/backup/$DUMP_DIRNAME"

    # Sprzatamy rozpakowany katalog (tarball ZOSTAJE jako disaster recovery).
    run docker compose -f "$REPO_DIR/docker-compose.yml" exec -T dbserver \
        rm -rf "/backup/$DUMP_DIRNAME"
    echo "DB restore: OK"
fi

# ---- Media restore ------------------------------------------------------
if [ "$DB_ONLY" != 1 ]; then
    echo
    echo "=== Media restore z $MEDIA_TAR ==="
    # Volume montujemy rw, katalog z tarballem ro, rozpakowujemy. Identyczna
    # logika jak `media-backup` w mk/database.mk, tylko w druga strone.
    # Zalozenie: volume jest pusty albo zgadzasz sie na merge (overlay).
    # Uzytkownik potwierdzil w brainstormie ze use-case to pusty volume.
    run docker run --rm \
        -v "${COMPOSE_PROJECT_NAME}_media:/dst" \
        -v "$HOST_BACKUP_DIR:/backup:ro" \
        alpine \
        tar xzf "/backup/$MEDIA_TAR" -C /dst
    echo "Media restore: OK"
fi

# ---- Restart stacka -----------------------------------------------------
echo
echo "=== Restart stacka (make up) ==="
run make -C "$REPO_DIR" up

echo
echo "=========================================================="
echo "  RESTORE ZAKONCZONY POMYSLNIE"
echo "=========================================================="
echo "  Timestamp restored: $TS"
[ "$MEDIA_ONLY" != 1 ] && echo "  DB:    $DB_TAR"
[ "$DB_ONLY"    != 1 ] && echo "  Media: $MEDIA_TAR"
echo
echo "Sprawdz stan stacka: make health  /  make logs-appserver"
echo "Tarballe pozostaja w $HOST_BACKUP_DIR (nie zostaly usuniete)."

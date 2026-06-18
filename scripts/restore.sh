#!/usr/bin/env bash
#
# Disaster recovery / klonowanie srodowiska: wczytaj backup z powrotem do
# uruchomionego stacka.
#
# Zrodla zrzutu DB:
#   - Para db+media po timestampie (`make backup`): db-backup-<TS>.tar.gz (-Fd)
#     + media-backup-<TS>.tar.gz. Tryb domyslny (przywraca DB ORAZ media).
#   - Pojedynczy plik DB dowolnego formatu: --db-file=PATH (tryb DB-only,
#     media nietkniete). Plik moze byc poza katalogiem backupow.
#   - --pick: interaktywny wybor — pokazuje ZAROWNO pary db+media, JAK I
#     pojedyncze zrzuty DB (*.sql / *.sql.gz / *.dump / *.custom) z katalogu
#     backupow.
#
# Detekcja formatu zrzutu DB (override: --db-format=auto|directory|custom|plain):
#   - directory (-Fd, tar.gz z toc.dat)  -> pg_restore -Fd -j N
#   - custom    (-Fc, magic PGDMP)       -> pg_restore -Fc
#   - plain     (.sql, tez .sql.gz)      -> psql
#   pg_restore zawsze z --no-owner --no-privileges; plain SQL powinien byc
#   dumpniety z --no-owner (patrz scripts/pg-collation-migrate-1-dump.sh) —
#   inaczej load do swiezego klastra padnie na "role ... does not exist".
#
# Wybor backupu (tryb par):
#   - bez argumentow: najnowsza para db-backup-*.tar.gz + media-backup-*.tar.gz.
#   - --timestamp=YYYYMMDD-HHMMSS: konkretna para.
#   - --pick: interaktywny wybor (fzf jesli dostepne, inaczej numerowane menu).
#
# Wywolanie: `make restore` lub bezposrednio `bash scripts/restore.sh`.
#
# UWAGA: ta operacja niszczy aktualna baze i (w trybie par) nadpisuje volume
# media. Domyslnie robi safety-backup biezacego stanu PRZED restorem (mozna
# pominac flaga --no-safety-backup). Tarball safety-backupa zostaje w katalogu
# backupow.

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
DB_FILE=""
DB_FORMAT="auto"

while [ $# -gt 0 ]; do
    case "$1" in
        --timestamp=*) TIMESTAMP_ARG="${1#*=}"; shift ;;
        --timestamp)   TIMESTAMP_ARG="${2:-}"; shift 2 || { echo "BLAD: --timestamp wymaga wartosci." >&2; exit 1; } ;;
        --db-file=*)   DB_FILE="${1#*=}"; shift ;;
        --db-file)     DB_FILE="${2:-}"; shift 2 || { echo "BLAD: --db-file wymaga sciezki." >&2; exit 1; } ;;
        --db-format=*) DB_FORMAT="${1#*=}"; shift ;;
        --db-format)   DB_FORMAT="${2:-}"; shift 2 || { echo "BLAD: --db-format wymaga wartosci." >&2; exit 1; } ;;
        --pick)        PICK=1; shift ;;
        --db-only)     DB_ONLY=1; shift ;;
        --media-only)  MEDIA_ONLY=1; shift ;;
        --no-safety-backup) SAFETY_BACKUP=0; shift ;;
        --noinput|--non-interactive|--yes) NOINPUT=1; shift ;;
        -h|--help)
            cat <<'HELP_EOF'
Uzycie: restore.sh [OPCJE]

  Zrodlo DB:
  --timestamp=YYYYMMDD-HHMMSS  Para backupow (db + media) po timestampie.
                               Domyslnie: najnowsza para w katalogu backupow.
  --db-file=PATH               Pojedynczy plik zrzutu DB (dowolny format,
                               tez spoza katalogu backupow). Tryb DB-only —
                               media NIE sa ruszane.
  --pick                       Interaktywny wybor: pary db+media ORAZ
                               pojedyncze zrzuty DB (*.sql/*.sql.gz/*.dump).

  Format zrzutu DB:
  --db-format=FMT              auto (domyslnie) | directory | custom | plain.
                               auto wykrywa: -Fd tar.gz (toc.dat) -> pg_restore,
                               -Fc (PGDMP) -> pg_restore, .sql/.sql.gz -> psql.

  Zakres:
  --db-only                    Restore tylko bazy (pomija media).
  --media-only                 Restore tylko mediow (pomija baze).

  --no-safety-backup           Pomija auto-backup biezacego stanu przed
                               restorem. NIE ZALECANE poza testami.
  --noinput, --yes             Tryb nieinteraktywny (auto-yes na potwierdzenia).
  -h, --help                   Ten ekran.

Przyklady:
  bash scripts/restore.sh                                  # najnowsza para
  bash scripts/restore.sh --pick                           # interaktywny wybor
  bash scripts/restore.sh --timestamp=20260428-140218      # konkretna para
  bash scripts/restore.sh --db-file=/backups/db.sql        # plain SQL -> psql
  bash scripts/restore.sh --db-file=/b/db.sql.gz --yes     # .sql.gz -> psql
  bash scripts/restore.sh --db-file=/b/db.dump             # -Fc -> pg_restore
HELP_EOF
            exit 0
            ;;
        *) echo "BLAD: nieznana opcja: $1 (zobacz --help)" >&2; exit 1 ;;
    esac
done

case "$DB_FORMAT" in
    auto|directory|custom|plain) : ;;
    *) echo "BLAD: --db-format musi byc auto|directory|custom|plain (jest: $DB_FORMAT)" >&2; exit 1 ;;
esac

if [ "$DB_ONLY" = 1 ] && [ "$MEDIA_ONLY" = 1 ]; then
    echo "BLAD: --db-only i --media-only sa wzajemnie wykluczajace." >&2
    exit 1
fi
if [ -n "$DB_FILE" ] && [ "$MEDIA_ONLY" = 1 ]; then
    echo "BLAD: --db-file (DB-only) z --media-only nie ma sensu." >&2
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

# Thin wrapper na docker compose z jawnym plikiem (z include podciaga reszte).
dc() { docker compose -f "$REPO_DIR/docker-compose.yml" "$@"; }

fmt_size() {
    local f="$1" bytes
    bytes="$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)"
    numfmt --to=iec --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B"
}

# Wykrywa format zrzutu DB. Echo: directory | custom | custom-gz | plain | plain-gz
#   directory = -Fd (tar.gz z toc.dat) ; custom = -Fc (magic PGDMP) ;
#   plain = czysty SQL. Wariant *-gz = to samo, ale skompresowane gzipem.
# Kolejnosc wazna: tar.gz tez przechodzi `gzip -t`, wiec tar sprawdzamy NAJPIERW.
detect_db_format() {
    local f="$1" magic
    if tar tzf "$f" 2>/dev/null | grep -q 'toc\.dat'; then
        echo directory; return
    fi
    if gzip -t "$f" 2>/dev/null; then
        magic="$(gunzip -c "$f" 2>/dev/null | head -c 5 || true)"
        if [ "$magic" = "PGDMP" ]; then echo custom-gz; else echo plain-gz; fi
        return
    fi
    magic="$(head -c 5 "$f" 2>/dev/null || true)"
    if [ "$magic" = "PGDMP" ]; then echo custom; else echo plain; fi
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

# ---- Operacje na bazie (uzywane przez restore_db) ------------------------
db_dropdb_createdb() {
    echo "+ dropdb --force $DJANGO_BPP_DB_NAME"
    dc exec -T -e "PGPASSWORD=$DJANGO_BPP_DB_PASSWORD" dbserver \
        dropdb --force \
            -h "$DJANGO_BPP_DB_HOST" -p "$DJANGO_BPP_DB_PORT" \
            -U "$DJANGO_BPP_DB_USER" "$DJANGO_BPP_DB_NAME"
    echo "+ createdb $DJANGO_BPP_DB_NAME"
    dc exec -T -e "PGPASSWORD=$DJANGO_BPP_DB_PASSWORD" dbserver \
        createdb \
            -h "$DJANGO_BPP_DB_HOST" -p "$DJANGO_BPP_DB_PORT" \
            -U "$DJANGO_BPP_DB_USER" "$DJANGO_BPP_DB_NAME"
}

# psql czytajacy SQL ze stdin (plain / plain-gz po dekompresji na hoscie).
db_psql_stdin() {
    dc exec -T -e "PGPASSWORD=$DJANGO_BPP_DB_PASSWORD" dbserver \
        psql -v ON_ERROR_STOP=1 \
            -h "$DJANGO_BPP_DB_HOST" -p "$DJANGO_BPP_DB_PORT" \
            -U "$DJANGO_BPP_DB_USER" -d "$DJANGO_BPP_DB_NAME"
}

# pg_restore czytajacy archiwum -Fc ze stdin.
db_pgrestore_stdin() {
    dc exec -T -e "PGPASSWORD=$DJANGO_BPP_DB_PASSWORD" dbserver \
        pg_restore --no-owner --no-privileges \
            -h "$DJANGO_BPP_DB_HOST" -p "$DJANGO_BPP_DB_PORT" \
            -U "$DJANGO_BPP_DB_USER" -d "$DJANGO_BPP_DB_NAME"
}

# Restore -Fd (katalog) z tarballa. Wymaga, by tarball byl widoczny w
# kontenerze pod /backup (bind-mount HOST_BACKUP_DIR). Plik spoza tego
# katalogu kopiujemy tymczasowo. Nazwe katalogu top-level czytamy z tarballa.
restore_db_directory() {
    local tar="$1" rel tmpcopy="" topdir
    case "$tar" in
        "$HOST_BACKUP_DIR"/*) rel="$(basename "$tar")" ;;
        *)
            tmpcopy="$HOST_BACKUP_DIR/.restore-dbfile-$$.tar.gz"
            run cp "$tar" "$tmpcopy"
            rel="$(basename "$tmpcopy")"
            ;;
    esac
    topdir="$(dc exec -T dbserver tar tzf "/backup/$rel" 2>/dev/null \
                | head -1 | cut -d/ -f1 | tr -d '\r')"
    if [ -z "$topdir" ]; then
        echo "BLAD: nie udalo sie odczytac katalogu z tarballa $rel." >&2
        [ -n "$tmpcopy" ] && rm -f "$tmpcopy"
        exit 1
    fi
    run dc exec -T dbserver tar xzf "/backup/$rel" -C /backup
    echo "+ pg_restore -Fd -j $PARALLEL_JOBS --no-owner --no-privileges"
    dc exec -T -e "PGPASSWORD=$DJANGO_BPP_DB_PASSWORD" dbserver \
        pg_restore \
            -Fd -j "$PARALLEL_JOBS" \
            -h "$DJANGO_BPP_DB_HOST" -p "$DJANGO_BPP_DB_PORT" \
            -U "$DJANGO_BPP_DB_USER" -d "$DJANGO_BPP_DB_NAME" \
            --no-owner --no-privileges \
            "/backup/$topdir"
    run dc exec -T dbserver rm -rf "/backup/$topdir"
    [ -n "$tmpcopy" ] && rm -f "$tmpcopy"
}

# Dropdb/createdb + restore wg formatu.
restore_db() {
    local src="$1" fmt="$2"
    echo
    echo "=== DB restore (format: $fmt) z $(basename "$src") ==="
    db_dropdb_createdb
    case "$fmt" in
        plain)     db_psql_stdin < "$src" ;;
        plain-gz)  gunzip -c "$src" | db_psql_stdin ;;
        custom)    db_pgrestore_stdin < "$src" ;;
        custom-gz) gunzip -c "$src" | db_pgrestore_stdin ;;
        directory) restore_db_directory "$src" ;;
        *) echo "BLAD: nieobslugiwany format DB: $fmt" >&2; exit 1 ;;
    esac
    echo "DB restore: OK"
}

# ---- Wybor backupu -------------------------------------------------------
list_timestamps() {
    # Unikalne timestampy majace zarowno db-backup jak i media-backup
    # (lub tylko jeden typ przy --db-only/--media-only). Sort malejaco.
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
        comm -12 <(printf '%s\n' "$db_ts" | sort) <(printf '%s\n' "$media_ts" | sort) | sort -r
    fi
}

# Pojedyncze zrzuty DB (bez pary media): plain SQL / gzip / custom.
list_db_files() {
    find "$HOST_BACKUP_DIR" -maxdepth 1 -type f \
        \( -name '*.sql' -o -name '*.sql.gz' -o -name '*.dump' -o -name '*.custom' \) \
        2>/dev/null | sort -r
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

# Buduje liste wyboru. Kazda linia: "<TAG>\t<etykieta>", gdzie TAG to
# "pair:<TS>" albo "file:<PATH>". Etykieta jest czytelna dla czlowieka.
build_pick_lines() {
    local ts f
    while IFS= read -r ts; do
        [ -z "$ts" ] && continue
        printf 'pair:%s\t[para ] %s\n' "$ts" "$(describe_ts "$ts")"
    done < <(list_timestamps)
    # Pojedyncze pliki DB tylko gdy nie jestesmy w trybie --media-only.
    if [ "$MEDIA_ONLY" != 1 ]; then
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            printf 'file:%s\t[plik ] %s (%s)\n' "$f" "$(basename "$f")" "$(fmt_size "$f")"
        done < <(list_db_files)
    fi
}

# Interaktywny wybor. Echo na STDOUT: "pair:<TS>" albo "file:<PATH>".
pick_source_interactive() {
    local lines
    lines="$(build_pick_lines)"
    if [ -z "$lines" ]; then
        echo "BLAD: brak backupow w $HOST_BACKUP_DIR (par db+media ani plikow DB)." >&2
        exit 1
    fi

    if command -v fzf >/dev/null 2>&1; then
        local selected
        selected="$(printf '%s\n' "$lines" \
            | fzf --height=40% --reverse --delimiter='\t' --with-nth=2.. \
                  --prompt='Wybierz backup> ' --header='ENTER=wybierz, ESC=anuluj' \
            || true)"
        [ -z "$selected" ] && { echo "Anulowane." >&2; exit 1; }
        printf '%s' "${selected%%$'\t'*}"
    else
        echo "(fzf nie znalezione - prosty wybor)" >&2
        local i=1
        local -a tags=()
        local tag label
        while IFS=$'\t' read -r tag label; do
            [ -z "$tag" ] && continue
            tags+=("$tag")
            printf '  [%d] %s\n' "$i" "$label" >&2
            i=$((i + 1))
        done <<<"$lines"
        local choice
        read -r -p "Numer (1-${#tags[@]}): " choice
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#tags[@]}" ]; then
            echo "BLAD: nieprawidlowy wybor." >&2
            exit 1
        fi
        printf '%s' "${tags[$((choice - 1))]}"
    fi
}

# ---- Rozwiazanie zrodla restore -----------------------------------------
# SINGLE_DB=1 => restore pojedynczego pliku DB (bez media). DB_SRC => sciezka.
# Tryb par => TS ustawione, DB_TAR_PATH/MEDIA_TAR_PATH wyliczane nizej.
SINGLE_DB=0
DB_SRC=""
TS=""

if [ -n "$DB_FILE" ]; then
    SINGLE_DB=1
    DB_SRC="$DB_FILE"
elif [ "$PICK" = 1 ]; then
    SEL="$(pick_source_interactive)"
    case "$SEL" in
        file:*) SINGLE_DB=1; DB_SRC="${SEL#file:}" ;;
        pair:*) TS="${SEL#pair:}" ;;
        *) echo "BLAD: nieoczekiwany wybor: $SEL" >&2; exit 1 ;;
    esac
elif [ -n "$TIMESTAMP_ARG" ]; then
    TS="$TIMESTAMP_ARG"
else
    TS="$(list_timestamps | head -1)"
    if [ -z "$TS" ]; then
        echo "BLAD: brak kompletnych par backupow w $HOST_BACKUP_DIR." >&2
        echo "      Uruchom 'make backup', podaj --db-file=PATH albo uzyj --pick." >&2
        exit 1
    fi
fi

# ---- Walidacja + wyliczenie sciezek -------------------------------------
if [ "$SINGLE_DB" = 1 ]; then
    if [ ! -f "$DB_SRC" ]; then
        echo "BLAD: nie znaleziono pliku zrzutu DB: $DB_SRC" >&2
        exit 1
    fi
    DB_SRC="$(cd "$(dirname "$DB_SRC")" && pwd)/$(basename "$DB_SRC")"
    # Detekcja / override formatu.
    if [ "$DB_FORMAT" = auto ]; then
        FMT="$(detect_db_format "$DB_SRC")"
    else
        FMT="$DB_FORMAT"
        if { [ "$FMT" = custom ] || [ "$FMT" = plain ]; } \
           && gzip -t "$DB_SRC" 2>/dev/null; then
            FMT="${FMT}-gz"
        fi
    fi
else
    DB_TAR="db-backup-${TS}.tar.gz"
    MEDIA_TAR="media-backup-${TS}.tar.gz"
    DB_TAR_PATH="$HOST_BACKUP_DIR/$DB_TAR"
    MEDIA_TAR_PATH="$HOST_BACKUP_DIR/$MEDIA_TAR"

    if [ "$MEDIA_ONLY" != 1 ] && [ ! -f "$DB_TAR_PATH" ]; then
        echo "BLAD: nie znaleziono $DB_TAR_PATH." >&2
        exit 1
    fi
    if [ "$DB_ONLY" != 1 ] && [ ! -f "$MEDIA_TAR_PATH" ]; then
        echo "BLAD: nie znaleziono $MEDIA_TAR_PATH." >&2
        exit 1
    fi
    DB_SRC="$DB_TAR_PATH"
    if [ "$MEDIA_ONLY" != 1 ]; then
        if [ "$DB_FORMAT" = auto ]; then
            FMT="$(detect_db_format "$DB_SRC")"
        else
            FMT="$DB_FORMAT"
        fi
    fi
fi

# ---- Podsumowanie + potwierdzenie ---------------------------------------
echo
echo "=========================================================="
echo "  BPP RESTORE"
echo "=========================================================="
if [ "$SINGLE_DB" = 1 ]; then
    echo "  Tryb:             pojedynczy plik DB (media nietkniete)"
    echo "  DB source:        $(basename "$DB_SRC") ($(fmt_size "$DB_SRC"))"
    echo "  Format DB:        $FMT"
else
    echo "  Tryb:             para backupow (timestamp)"
    echo "  Timestamp:        $TS"
    if [ "$MEDIA_ONLY" != 1 ]; then
        echo "  DB tarball:       $DB_TAR ($(fmt_size "$DB_TAR_PATH"))  format=$FMT"
    fi
    if [ "$DB_ONLY" != 1 ]; then
        echo "  Media tarball:    $MEDIA_TAR ($(fmt_size "$MEDIA_TAR_PATH"))"
    fi
fi
echo "  Katalog backupow: $HOST_BACKUP_DIR"
echo "  Project:          $COMPOSE_PROJECT_NAME"
echo "  DB target:        $DJANGO_BPP_DB_USER@$DJANGO_BPP_DB_HOST:$DJANGO_BPP_DB_PORT/$DJANGO_BPP_DB_NAME"
echo "  Safety backup:    $([ "$SAFETY_BACKUP" = 1 ] && echo TAK || echo NIE)"
echo "=========================================================="
echo
echo "UWAGA: ta operacja:"
if [ "$MEDIA_ONLY" != 1 ]; then
    echo "  - DROPNIE i odtworzy baze $DJANGO_BPP_DB_NAME"
fi
if [ "$SINGLE_DB" != 1 ] && [ "$DB_ONLY" != 1 ]; then
    echo "  - rozpakuje archiwum mediow na volume ${COMPOSE_PROJECT_NAME}_media"
fi
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
    if [ "$SINGLE_DB" = 1 ] || [ "$DB_ONLY" = 1 ]; then
        run make -C "$REPO_DIR" db-backup
    elif [ "$MEDIA_ONLY" = 1 ]; then
        run make -C "$REPO_DIR" media-backup
    else
        run make -C "$REPO_DIR" backup
    fi
fi

# ---- Stop dependent services --------------------------------------------
echo
echo "=== Stop dependent services ==="
run dc stop appserver workerserver denorm-queue celerybeat flower || true

# ---- DB restore ---------------------------------------------------------
if [ "$MEDIA_ONLY" != 1 ]; then
    restore_db "$DB_SRC" "$FMT"
fi

# ---- Media restore ------------------------------------------------------
if [ "$SINGLE_DB" != 1 ] && [ "$DB_ONLY" != 1 ]; then
    echo
    echo "=== Media restore z $MEDIA_TAR ==="
    # Volume rw, katalog z tarballem ro, rozpakowujemy (overlay na volume).
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
if [ "$SINGLE_DB" = 1 ]; then
    echo "  DB source: $(basename "$DB_SRC")  (format: $FMT)"
else
    echo "  Timestamp restored: $TS"
    [ "$MEDIA_ONLY" != 1 ] && echo "  DB:    $DB_TAR  (format: $FMT)"
    [ "$DB_ONLY"    != 1 ] && echo "  Media: $MEDIA_TAR"
fi
echo
echo "Sprawdz stan stacka: make health  /  make logs-appserver"
echo "Pliki zrodlowe pozostaja w $HOST_BACKUP_DIR (nie zostaly usuniete)."

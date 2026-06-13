#!/usr/bin/env bash
#
# Wspolna biblioteka dla trzech krokow migracji "pozbadz sie kolacji libc
# pl_PL" przy przejsciu z obrazu iplweb/bpp_dbserver na stockowy postgres:
#
#   pg-collation-migrate-1-dump.sh   - zrzut biezacego clustra (stary obraz)
#   pg-collation-migrate-2-fix.sh    - usun kolacje pl_PL ze zrzutu
#   pg-collation-migrate-3-load.sh   - zaladuj poprawiony zrzut do psql 18
#
# DLACZEGO to w ogole jest potrzebne:
#   Stary obraz iplweb/bpp_dbserver mial wygenerowane locale libc
#   pl_PL.UTF-8 (RUN localedef ...) i tworzyl kolacje
#   `CREATE COLLATION public."pl_PL" (provider=libc, locale='pl_PL.UTF-8')`
#   (migracja bpp 0001_collation). Oficjalny obraz `postgres` ma TYLKO
#   en_US.UTF-8 + C.UTF-8 — wiec:
#     * istniejacy cluster sie NIE URUCHOMI (postgresql.conf ma
#       lc_messages/lc_monetary/lc_numeric/lc_time = pl_PL.utf-8, a
#       pg_database datcollate/datctype = pl_PL.utf-8 — nieznane locale),
#     * zrzut z `CREATE COLLATION ... libc pl_PL.UTF-8` nie wczyta sie na
#       czystym obrazie.
#   Kolacja byla uzywana wylacznie na stalych literalach ASCII w 5 widokach
#   bpp_kronika_*_view (no-op dla sortowania), wiec mozna ja bezpiecznie
#   usunac. Migracja bpp 0443_drop_pl_PL_collation robi to samo w schemacie.
#
# Strategia: logical dump (stary obraz) -> konwersja na czysty SQL z
# wycieciem kolacji -> load do swiezego clustra psql 18 zainicjowanego z
# kolacja ICU pl-PL (--locale-provider=icu --icu-locale=pl-PL).

set -euo pipefail

# REPO_DIR ustawia skrypt wywolujacy (dirname "$0"/..). Tu tylko walidacja.
: "${REPO_DIR:?REPO_DIR musi byc ustawione przez skrypt wywolujacy}"
REPO_ENV="$REPO_DIR/.env"

# Obraz postgres uzywany do (a) konwersji dir-dump -> SQL w kroku 2 oraz
# (b) jako docelowy cluster w kroku 3. pg_restore z nowszego majora czyta
# starsze archiwa, wiec domyslnie bierzemy wersje docelowa. Override:
#   PG_TARGET_IMAGE=postgres:18.3 bash scripts/pg-collation-migrate-2-fix.sh ...
PG_TARGET_IMAGE="${PG_TARGET_IMAGE:-postgres:${DJANGO_BPP_POSTGRESQL_VERSION:-18}}"

# ---- Helpers ------------------------------------------------------------

# Czyta zmienna z pliku .env (ostatnie wystapienie wygrywa), zdejmuje
# otaczajace cudzyslowy. Identyczne zachowanie jak w scripts/restore.sh.
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

run() { echo "+ $*" >&2; "$@"; }

confirm() {
    local prompt="$1" answer
    if [ "${NOINPUT:-0}" = 1 ]; then
        echo "$prompt [auto-yes via --yes]" >&2
        return 0
    fi
    read -r -p "$prompt [yes/NO]: " answer
    [ "$answer" = "yes" ]
}

# Wczytuje BPP_CONFIGS_DIR + COMPOSE_PROJECT_NAME z REPO_ENV oraz
# DJANGO_BPP_DB_* + katalog backupow z APP_ENV. Ustawia globalne zmienne:
#   BPP_CONFIGS_DIR COMPOSE_PROJECT_NAME APP_ENV
#   DJANGO_BPP_DB_{PASSWORD,HOST,PORT,USER,NAME} HOST_BACKUP_DIR
load_env() {
    if [ ! -f "$REPO_ENV" ]; then
        echo "BLAD: brak $REPO_ENV. Uruchom najpierw 'make' / 'make init-configs'." >&2
        exit 1
    fi
    : "${BPP_CONFIGS_DIR:=$(get_env_var BPP_CONFIGS_DIR "$REPO_ENV")}"
    : "${COMPOSE_PROJECT_NAME:=$(get_env_var COMPOSE_PROJECT_NAME "$REPO_ENV")}"
    if [ -z "${BPP_CONFIGS_DIR:-}" ]; then
        echo "BLAD: BPP_CONFIGS_DIR nie ustawione w $REPO_ENV." >&2; exit 1
    fi
    if [ -z "${COMPOSE_PROJECT_NAME:-}" ]; then
        echo "BLAD: COMPOSE_PROJECT_NAME nie ustawione w $REPO_ENV." >&2; exit 1
    fi
    export COMPOSE_PROJECT_NAME

    APP_ENV="$BPP_CONFIGS_DIR/.env"
    if [ ! -f "$APP_ENV" ]; then
        echo "BLAD: brak $APP_ENV. Uruchom 'make init-configs'." >&2; exit 1
    fi

    DJANGO_BPP_DB_PASSWORD="$(get_env_var DJANGO_BPP_DB_PASSWORD "$APP_ENV")"
    DJANGO_BPP_DB_HOST="$(get_env_var DJANGO_BPP_DB_HOST "$APP_ENV")"
    DJANGO_BPP_DB_PORT="$(get_env_var DJANGO_BPP_DB_PORT "$APP_ENV")"
    DJANGO_BPP_DB_USER="$(get_env_var DJANGO_BPP_DB_USER "$APP_ENV")"
    DJANGO_BPP_DB_NAME="$(get_env_var DJANGO_BPP_DB_NAME "$APP_ENV")"

    HOST_BACKUP_DIR="$(get_env_var DJANGO_BPP_HOST_BACKUP_DIR "$APP_ENV")"
    if [ -z "$HOST_BACKUP_DIR" ]; then
        HOST_BACKUP_DIR="$(get_env_var DJANGO_BPP_BACKUP_DIR "$APP_ENV")"
    fi
    if [ -z "$HOST_BACKUP_DIR" ]; then
        HOST_BACKUP_DIR="$(cd "$BPP_CONFIGS_DIR/.." && pwd)/backups"
    fi
    if [ ! -d "$HOST_BACKUP_DIR" ]; then
        echo "BLAD: katalog backupow $HOST_BACKUP_DIR nie istnieje." >&2; exit 1
    fi

    # Te zmienne sa uzywane przez skrypty sourcujace te biblioteke (export
    # zaspokaja tez shellcheck SC2034 — "used externally").
    export DJANGO_BPP_DB_PASSWORD DJANGO_BPP_DB_HOST DJANGO_BPP_DB_PORT \
           DJANGO_BPP_DB_USER DJANGO_BPP_DB_NAME HOST_BACKUP_DIR
}

# Thin wrapper na `docker compose` z jawnym plikiem + projektem (jak restore.sh).
dc() {
    docker compose -f "$REPO_DIR/docker-compose.yml" "$@"
}

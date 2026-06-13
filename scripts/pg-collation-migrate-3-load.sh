#!/usr/bin/env bash
#
# KROK 3/3 migracji "pozbadz sie kolacji libc pl_PL". Patrz
# lib-pg-collation-migrate.sh.
#
# Laduje poprawiony zrzut (<...>-nocollation.sql.gz z kroku 2) do SWIEZEGO
# clustra na STOCKOWYM obrazie postgres (np. 18), zainicjowanego z kolacja
# ICU pl-PL (POSTGRES_INITDB_ARGS=--locale-provider=icu --icu-locale=pl-PL,
# ustawiane w docker-compose.database.yml).
#
# Zaklada, ze serwis 'dbserver' chodzi juz na NOWYM obrazie (stock postgres)
# na PUSTYM volume. Jesli nie — uzyj --recreate-volume, zeby skrypt:
#   1) zatrzymal appserver + workery + dbserver,
#   2) USUNAL volume ${COMPOSE_PROJECT_NAME}_postgresql_data (DESTRUKCYJNE!),
#   3) wstal dbserver na nowo (initdb wg obrazu z docker-compose.database.yml).
# Najpierw ustaw w $BPP_CONFIGS_DIR/.env  DJANGO_BPP_POSTGRESQL_VERSION=18.x
# i upewnij sie, ze docker-compose.database.yml uzywa stockowego postgres.
#
# Uzycie:
#     bash scripts/pg-collation-migrate-3-load.sh <plik-nocollation.sql.gz> \
#         [--recreate-volume] [--yes]

set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib-pg-collation-migrate.sh
. "$REPO_DIR/scripts/lib-pg-collation-migrate.sh"

SQL_GZ=""
RECREATE=0
NOINPUT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --recreate-volume) RECREATE=1; shift ;;
        --yes|--noinput|--non-interactive) NOINPUT=1; shift ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        -*) echo "BLAD: nieznany argument: $1" >&2; exit 1 ;;
        *) SQL_GZ="$1"; shift ;;
    esac
done
if [ -z "$SQL_GZ" ] || [ ! -f "$SQL_GZ" ]; then
    echo "BLAD: podaj istniejacy plik *-nocollation.sql.gz" >&2
    exit 1
fi
SQL_GZ="$(cd "$(dirname "$SQL_GZ")" && pwd)/$(basename "$SQL_GZ")"

load_env

if [ "$RECREATE" = 1 ]; then
    VOL="${COMPOSE_PROJECT_NAME}_postgresql_data"
    echo "!! --recreate-volume: USUNE volume '$VOL' i wszystkie dane biezacego clustra." >&2
    confirm "Na pewno skasowac volume '$VOL' i postawic SWIEZY cluster?" \
        || { echo "Przerwano — nic nie ruszone." >&2; exit 1; }
    run dc stop appserver workerserver celerybeat denorm-queue dbserver || true
    run dc rm -f dbserver || true
    run docker volume rm "$VOL"
    echo ">> Stawiam swiezy dbserver (initdb wg obrazu z compose)..." >&2
    run dc up -d --wait dbserver
fi

if ! dc ps --status=running --services 2>/dev/null | grep -qx dbserver; then
    echo "BLAD: serwis 'dbserver' nie dziala. Uruchom 'make up' lub uzyj --recreate-volume." >&2
    exit 1
fi

# Bezpiecznik: nie laduj do STAREGO obrazu (bylby to stary cluster, nie psql 18).
IMG="$(dc ps --format '{{.Image}}' dbserver 2>/dev/null | head -1 || true)"
echo ">> dbserver image: ${IMG:-?}" >&2
if printf '%s' "$IMG" | grep -qi 'bpp_dbserver'; then
    echo "BLAD: dbserver wciaz uzywa obrazu iplweb/bpp_dbserver. Przelacz na stock" >&2
    echo "      postgres (docker-compose.database.yml + DJANGO_BPP_POSTGRESQL_VERSION)" >&2
    echo "      i uzyj --recreate-volume, zanim zaladujesz zrzut." >&2
    exit 1
fi

PSQL=(dc exec -T -e "PGPASSWORD=${DJANGO_BPP_DB_PASSWORD}" dbserver psql \
      -h "${DJANGO_BPP_DB_HOST}" -p "${DJANGO_BPP_DB_PORT}" -U "${DJANGO_BPP_DB_USER}")

echo ">> dropdb --force + createdb ${DJANGO_BPP_DB_NAME} (dziedziczy kolacje ICU pl-PL z clustra)" >&2
confirm "Skasowac i odtworzyc baze '${DJANGO_BPP_DB_NAME}' na ${IMG}?" \
    || { echo "Przerwano." >&2; exit 1; }
dc exec -T -e "PGPASSWORD=${DJANGO_BPP_DB_PASSWORD}" dbserver \
    dropdb --force --if-exists -h "${DJANGO_BPP_DB_HOST}" -p "${DJANGO_BPP_DB_PORT}" \
        -U "${DJANGO_BPP_DB_USER}" "${DJANGO_BPP_DB_NAME}"
dc exec -T -e "PGPASSWORD=${DJANGO_BPP_DB_PASSWORD}" dbserver \
    createdb -h "${DJANGO_BPP_DB_HOST}" -p "${DJANGO_BPP_DB_PORT}" \
        -U "${DJANGO_BPP_DB_USER}" "${DJANGO_BPP_DB_NAME}"

echo ">> Sprawdzam kolacje docelowej bazy (oczekiwane: ICU / 'i')..." >&2
PROV="$("${PSQL[@]}" -tAc \
    "SELECT datlocprovider FROM pg_database WHERE datname='${DJANGO_BPP_DB_NAME}';" 2>/dev/null | tr -d '[:space:]')"
echo "   datlocprovider=${PROV:-?}" >&2
if [ "${PROV:-}" != "i" ]; then
    echo "!! OSTRZEZENIE: docelowa baza nie jest ICU. Czy cluster zainicjowano z" >&2
    echo "   POSTGRES_INITDB_ARGS=--locale-provider=icu --icu-locale=pl-PL ?" >&2
fi

echo ">> Laduje ${SQL_GZ} (psql, ON_ERROR_STOP=1)..." >&2
gunzip -c "$SQL_GZ" | "${PSQL[@]}" -v ON_ERROR_STOP=1 -d "${DJANGO_BPP_DB_NAME}"

echo ">> Weryfikacja po loadzie:" >&2
"${PSQL[@]}" -d "${DJANGO_BPP_DB_NAME}" -tAc \
    "SELECT 'kronika views: '||count(*) FROM information_schema.views WHERE table_name LIKE 'bpp_kronika%';" >&2
"${PSQL[@]}" -d "${DJANGO_BPP_DB_NAME}" -tAc \
    "SELECT 'collations pl_PL pozostale: '||count(*) FROM pg_collation WHERE collname='pl_PL';" >&2
echo ">> Gotowe. Baza '${DJANGO_BPP_DB_NAME}' zaladowana na ${IMG}." >&2
echo "   Teraz: zmigruj aplikacje ('make migrate') i wstan stack ('make up')." >&2

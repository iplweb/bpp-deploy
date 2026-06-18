#!/usr/bin/env bash
#
# KROK 3/3 migracji "pozbadz sie kolacji libc pl_PL". Patrz
# lib-pg-collation-migrate.sh.
#
# Laduje poprawiony zrzut (<...>-nocollation.sql z kroku 2, plain SQL bez
# gzipa) do SWIEZEGO clustra na STOCKOWYM obrazie postgres (np. 18),
# zainicjowanego z kolacja
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
#     bash scripts/pg-collation-migrate-3-load.sh <plik-nocollation.sql> \
#         [--recreate-volume] [--yes]

set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib-pg-collation-migrate.sh
. "$REPO_DIR/scripts/lib-pg-collation-migrate.sh"

SQL_FILE=""
RECREATE=0
NOINPUT=0
# NOINPUT czyta confirm() z sourcowanej lib; shellcheck bez -x tego uzycia nie
# widzi -> SC2034. Nie eksportujemy (to flaga sterujaca, nie env dla procesow).
# shellcheck disable=SC2034
while [ $# -gt 0 ]; do
    case "$1" in
        --recreate-volume) RECREATE=1; shift ;;
        --yes|--noinput|--non-interactive) NOINPUT=1; shift ;;
        -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
        -*) echo "BLAD: nieznany argument: $1" >&2; exit 1 ;;
        *) SQL_FILE="$1"; shift ;;
    esac
done
if [ -z "$SQL_FILE" ] || [ ! -f "$SQL_FILE" ]; then
    echo "BLAD: podaj istniejacy plik *-nocollation.sql (plain SQL z kroku 2)" >&2
    exit 1
fi
case "$SQL_FILE" in
    *.gz|*.tgz)
        echo "BLAD: krok 2 produkuje teraz NIESKOMPRESOWANY .sql — podaj plik" >&2
        echo "      *-nocollation.sql, nie .gz." >&2
        exit 1 ;;
esac
SQL_FILE="$(cd "$(dirname "$SQL_FILE")" && pwd)/$(basename "$SQL_FILE")"

load_env

if [ "$RECREATE" = 1 ]; then
    VOL="${COMPOSE_PROJECT_NAME}_postgresql_data"
    echo "!! --recreate-volume: USUNE volume '$VOL' i wszystkie dane biezacego clustra." >&2
    confirm "Na pewno skasowac volume '$VOL' i postawic SWIEZY cluster?" \
        || { echo "Przerwano — nic nie ruszone." >&2; exit 1; }
    run dc stop appserver workerserver celerybeat denorm-queue dbserver || true
    run dc rm -f dbserver || true
    # Wolumen kasujemy tylko jesli istnieje — jego BRAK to dokladnie stan
    # docelowy (swiezy cluster i tak powstanie). 'docker volume rm' na
    # nieistniejacym wolumenie zwraca blad i przy set -e wywalalby skrypt.
    # Prawdziwy blad usuwania (np. wolumen w uzyciu) nadal zatrzyma skrypt.
    if docker volume inspect "$VOL" >/dev/null 2>&1; then
        run docker volume rm "$VOL"
    else
        echo ">> Volume '$VOL' nie istnieje — pomijam usuwanie." >&2
    fi
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

# Fix hstore-w-WHEN na PG18: pg_dump utwardza naglowek przez
# `SELECT pg_catalog.set_config('search_path', '', false);` (ochrona po
# CVE-2018-1058 — PUSTY search_path na cala sesje restore). Przy odtwarzaniu
# triggerow STAREGO denorma klauzula WHEN porownuje kolumne `legacy_data`
# (typ hstore) operatorem `IS DISTINCT FROM`, ktory rozwija sie do `hstore =
# hstore`. Ten operator zyje w schemacie `public` (CREATE EXTENSION hstore
# WITH SCHEMA public), a klauzula WHEN jest parsowana JUZ przy CREATE TRIGGER
# (niezaleznie od check_function_bodies). Z pustym search_path operator jest
# niewidoczny -> "operator does not exist: public.hstore = public.hstore".
# PG16 to przepuszczal, PG18 nie. Przywracamy `public` do search_path na czas
# restore (zachowanie sprzed CVE; bezpieczne, bo pg_dump kwalifikuje obiekty
# schematem). Robimy to filtrem strumieniowym, BEZ modyfikacji zapisanego
# pliku -nocollation.sql.
SEARCH_PATH_FIX=\
"s/set_config('search_path', '', false)/set_config('search_path', 'public', false)/"
if ! head -n 100 "$SQL_FILE" | grep -q "set_config('search_path', '', false)"; then
    echo "!! UWAGA: nie znalazlem w naglowku zrzutu linii" >&2
    echo "   set_config('search_path', '', false) — fix search_path bedzie no-op." >&2
    echo "   Jesli load padnie na 'operator does not exist: public.hstore = public.hstore'," >&2
    echo "   format pg_dump sie zmienil — popraw wzorzec SEARCH_PATH_FIX w tym skrypcie." >&2
fi

echo ">> Laduje ${SQL_FILE} (psql, ON_ERROR_STOP=1, search_path->public)..." >&2
# Plain SQL z pliku -> sed (fix search_path) -> psql w kontenerze (dc exec -T
# forwarduje stdin). Gdy jest `pv` i stderr to terminal, pokazujemy pasek
# postepu (pv sam zna rozmiar pliku, bo czyta go PRZED sedem). pipefail
# (set -o) wylapie blad psql mimo pv/sed po lewej stronie potoku.
if [ -t 2 ] && command -v pv >/dev/null 2>&1; then
    pv "$SQL_FILE" | sed "$SEARCH_PATH_FIX" \
        | "${PSQL[@]}" -v ON_ERROR_STOP=1 -d "${DJANGO_BPP_DB_NAME}"
else
    sed "$SEARCH_PATH_FIX" "$SQL_FILE" \
        | "${PSQL[@]}" -v ON_ERROR_STOP=1 -d "${DJANGO_BPP_DB_NAME}"
fi

echo ">> Weryfikacja po loadzie:" >&2
"${PSQL[@]}" -d "${DJANGO_BPP_DB_NAME}" -tAc \
    "SELECT 'kronika views: '||count(*) FROM information_schema.views WHERE table_name LIKE 'bpp_kronika%';" >&2
# Dowolny case (pl_PL/pl_pl) w schemacie public; systemowa pg_catalog.pl_PL
# (auto-import initdb) jest pomijana przez nspname='public'.
"${PSQL[@]}" -d "${DJANGO_BPP_DB_NAME}" -tAc \
    "SELECT 'kolacje pl_PL w public pozostale: '||count(*) FROM pg_collation c JOIN pg_namespace n ON n.oid=c.collnamespace WHERE lower(c.collname)='pl_pl' AND n.nspname='public';" >&2
echo ">> Gotowe. Baza '${DJANGO_BPP_DB_NAME}' zaladowana na ${IMG}." >&2
echo "   Teraz: wstan stack ('make up') — appserver przy starcie sam" >&2
echo "   przepusci migracje. Ewentualnie potem 'make migrate' na zywym" >&2
echo "   stacku ('make migrate' robi 'docker compose exec appserver ...'," >&2
echo "   wiec wymaga juz dzialajacego appservera)." >&2

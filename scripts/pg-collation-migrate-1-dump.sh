#!/usr/bin/env bash
#
# KROK 1/3 migracji "pozbadz sie kolacji libc pl_PL" (przejscie z obrazu
# iplweb/bpp_dbserver na stockowy postgres). Patrz lib-pg-collation-migrate.sh.
#
# Robi logical dump BIEZACEGO clustra (ktory wciaz chodzi na STARYM obrazie
# iplweb/bpp_dbserver, bo tylko on ma locale libc pl_PL.UTF-8) do PLAIN SQL
# (pg_dump -Fp), spakowanego gzipem -> db-backup-<TS>.sql.gz.
#
# DLACZEGO plain SQL, a nie format katalogowy (-Fd) jak `make db-backup`:
# krok 2 musi EDYTOWAC TEKST (sed) definicji widokow, zeby wyciac klauzule
# COLLATE "pl_PL". Format binarny (-Fd/-Fc) trzeba by najpierw skonwertowac
# `pg_restore -f -` (dodatkowy obraz postgres na hoscie + tar/untar) — a
# skoro load i tak idzie psql-em (jednowatkowo), rownoleglosc pg_restore -j
# nic nie daje. Plain SQL = zaden binarny posrednik. Wynikowy .sql.gz jest
# tez normalnym, ladowalnym backupem.
#
# WAZNE: zanim zrzucisz, zatrzymaj zapisy. Domyslnie skrypt NIE zatrzymuje
# aplikacji; podaj --stop-app, zeby zatrzymal appserver + workery + beat +
# denorm-queue (jak `make restore`). Alternatywnie zrob recznie:
#     docker compose stop appserver workerserver celerybeat denorm-queue
#
# Uzycie:
#     bash scripts/pg-collation-migrate-1-dump.sh [--stop-app] [--yes]
#
# Wypisuje na STDOUT pelna sciezke do .sql.gz (do podania krokowi 2).

set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib-pg-collation-migrate.sh
. "$REPO_DIR/scripts/lib-pg-collation-migrate.sh"

STOP_APP=0
NOINPUT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --stop-app) STOP_APP=1; shift ;;
        --yes|--noinput|--non-interactive) NOINPUT=1; shift ;;
        -h|--help)
            sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "BLAD: nieznany argument: $1" >&2; exit 1 ;;
    esac
done

load_env
TS="$(date +%Y%m%d-%H%M%S)"
DUMP_SQL_GZ="db-backup-${TS}.sql.gz"
OUT_PATH="${HOST_BACKUP_DIR}/${DUMP_SQL_GZ}"
PARTIAL="${OUT_PATH}.partial"

# Niedokonczony zrzut (pg_dump padl w polowie potoku) nie moze udawac
# gotowego pliku — krok 2 by go pozniej sed-owal jako kompletny.
cleanup_partial() { rm -f "$PARTIAL"; }
trap cleanup_partial EXIT

if ! dc ps --status=running --services 2>/dev/null | grep -qx dbserver; then
    echo "BLAD: serwis 'dbserver' nie dziala. Uruchom 'make up' przed zrzutem." >&2
    exit 1
fi

if [ "$STOP_APP" = 1 ]; then
    echo ">> Zatrzymuje aplikacje (appserver + workery + beat + denorm-queue)..." >&2
    run dc stop appserver workerserver celerybeat denorm-queue
else
    echo ">> UWAGA: aplikacja NIE jest zatrzymywana (--stop-app pominiete)." >&2
    echo "   Zrzut spojny tylko jesli nie ma rownoleglych zapisow do bazy." >&2
    confirm "Kontynuowac zrzut bez zatrzymania aplikacji?" || { echo "Przerwano."; exit 1; }
fi

# pg_dump -Fp pisze czysty SQL na stdout (in-container), gzip pakuje na
# hoscie. Brak -j (plain SQL nie wspiera rownoleglosci) i tak nie jest
# strata: load w kroku 3 to jednowatkowy psql. -T wylacza pseudo-TTY, wiec
# strumien nie jest psuty translacja CR/LF. pipefail (z set -o) wylapie
# blad pg_dump mimo gzipa po prawej stronie potoku.
echo ">> pg_dump -Fp (zrodlo: stary cluster) | gzip -> ${OUT_PATH}" >&2
dc exec -T -e "PGPASSWORD=${DJANGO_BPP_DB_PASSWORD}" dbserver pg_dump \
    -Fp \
    -h "${DJANGO_BPP_DB_HOST}" -p "${DJANGO_BPP_DB_PORT}" \
    -U "${DJANGO_BPP_DB_USER}" "${DJANGO_BPP_DB_NAME}" \
    | gzip > "$PARTIAL"

echo ">> Sprawdzam integralnosc gzipa..." >&2
gzip -t "$PARTIAL"
mv "$PARTIAL" "$OUT_PATH"

echo ">> Gotowe. Zrzut plain SQL:" >&2
# Jedyne, co idzie na czysty STDOUT — sciezka do .sql.gz (dla kroku 2).
printf '%s\n' "$OUT_PATH"

#!/usr/bin/env bash
#
# KROK 1/3 migracji "pozbadz sie kolacji libc pl_PL" (przejscie z obrazu
# iplweb/bpp_dbserver na stockowy postgres). Patrz lib-pg-collation-migrate.sh.
#
# Robi logical dump BIEZACEGO clustra (ktory wciaz chodzi na STARYM obrazie
# iplweb/bpp_dbserver, bo tylko on ma locale libc pl_PL.UTF-8) do PLAIN SQL
# (pg_dump -Fp) -> db-backup-<TS>.sql. BEZ gzipa — krok 2 i tak musi czytac
# i edytowac caly tekst sed-em, a brak (de)kompresji jest troche szybszy.
#
# DLACZEGO plain SQL, a nie format katalogowy (-Fd) jak `make db-backup`:
# krok 2 musi EDYTOWAC TEKST (sed) definicji widokow, zeby wyciac klauzule
# COLLATE pl_PL. Format binarny (-Fd/-Fc) trzeba by najpierw skonwertowac
# `pg_restore -f -` (dodatkowy obraz postgres na hoscie + tar/untar) — a
# skoro load i tak idzie psql-em (jednowatkowo), rownoleglosc pg_restore -j
# nic nie daje. Plain SQL = zaden binarny posrednik. Wynikowy .sql jest
# tez normalnym, ladowalnym backupem.
#
# Jesli na hoscie jest `pv`, dump pokazuje pasek postepu (estymata rozmiaru
# z pg_database_size). Bez pv leci bez paska — `pv` jest opcjonalne.
#
# WAZNE: zanim zrzucisz, zatrzymaj zapisy. Domyslnie skrypt NIE zatrzymuje
# aplikacji; podaj --stop-app, zeby zatrzymal appserver + workery + beat +
# denorm-queue (jak `make restore`). Alternatywnie zrob recznie:
#     docker compose stop appserver workerserver celerybeat denorm-queue
#
# Uzycie:
#     bash scripts/pg-collation-migrate-1-dump.sh [--stop-app] [--yes]
#
# Wypisuje na STDOUT pelna sciezke do .sql (do podania krokowi 2).

set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib-pg-collation-migrate.sh
. "$REPO_DIR/scripts/lib-pg-collation-migrate.sh"

STOP_APP=0
NOINPUT=0
# NOINPUT czyta confirm() z sourcowanej lib; shellcheck bez -x tego uzycia nie
# widzi -> SC2034. Nie eksportujemy (to flaga sterujaca, nie env dla pg_dump/psql).
# shellcheck disable=SC2034
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
DUMP_SQL="db-backup-${TS}.sql"
OUT_PATH="${HOST_BACKUP_DIR}/${DUMP_SQL}"
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

# Pasek postepu: jesli na hoscie jest `pv` i stderr to terminal, wpinamy go
# miedzy pg_dump a plik. Jako estymate (-s) bierzemy fizyczny rozmiar bazy
# (pg_database_size) — to tylko przyblizenie (dump nie ma indeksow ani bloatu,
# wiec zwykle konczy przed 100%), ale daje procent + ETA. Gdy pv nie ma,
# identity-pipe przez `cat`. Nieudane zapytanie o rozmiar -> pv bez -s.
PROGRESS=(cat)
if [ -t 2 ] && command -v pv >/dev/null 2>&1; then
    DB_BYTES="$(dc exec -T -e "PGPASSWORD=${DJANGO_BPP_DB_PASSWORD}" dbserver psql \
        -h "${DJANGO_BPP_DB_HOST}" -p "${DJANGO_BPP_DB_PORT}" \
        -U "${DJANGO_BPP_DB_USER}" -d "${DJANGO_BPP_DB_NAME}" \
        -tAc "SELECT pg_database_size('${DJANGO_BPP_DB_NAME}')" 2>/dev/null \
        | tr -d '[:space:]')"
    case "$DB_BYTES" in ''|*[!0-9]*) DB_BYTES=0 ;; esac
    if [ "$DB_BYTES" -gt 0 ]; then
        PROGRESS=(pv -s "$DB_BYTES")
    else
        PROGRESS=(pv)
    fi
elif ! command -v pv >/dev/null 2>&1; then
    echo ">> (bez paska postepu — zainstaluj 'pv': apt install pv / brew install pv)" >&2
fi

# pg_dump -Fp pisze czysty SQL na stdout (in-container), zapisujemy go wprost
# do pliku na hoscie (bez gzipa). Brak -j (plain SQL nie wspiera rownoleglosci)
# i tak nie jest strata: load w kroku 3 to jednowatkowy psql. -T wylacza
# pseudo-TTY, wiec strumien nie jest psuty translacja CR/LF. pipefail (z set -o)
# wylapie blad pg_dump mimo pv po prawej stronie potoku.
echo ">> pg_dump -Fp (zrodlo: stary cluster) -> ${OUT_PATH}" >&2
dc exec -T -e "PGPASSWORD=${DJANGO_BPP_DB_PASSWORD}" dbserver pg_dump \
    -Fp \
    -h "${DJANGO_BPP_DB_HOST}" -p "${DJANGO_BPP_DB_PORT}" \
    -U "${DJANGO_BPP_DB_USER}" "${DJANGO_BPP_DB_NAME}" \
    | "${PROGRESS[@]}" > "$PARTIAL"

# Kompletnosc: pg_dump -Fp konczy zrzut markerem na koncu pliku. Jego brak =
# zrzut urwany (zamiast `gzip -t`, ktory mielismy przy wersji gzipowanej).
echo ">> Sprawdzam kompletnosc zrzutu (marker konca pg_dump)..." >&2
if ! tail -n 5 "$PARTIAL" | grep -q 'PostgreSQL database dump complete'; then
    echo "BLAD: zrzut wyglada na urwany (brak markera 'PostgreSQL database dump complete')." >&2
    exit 1
fi
mv "$PARTIAL" "$OUT_PATH"

echo ">> Gotowe. Zrzut plain SQL:" >&2
# Jedyne, co idzie na czysty STDOUT — sciezka do .sql (dla kroku 2).
printf '%s\n' "$OUT_PATH"

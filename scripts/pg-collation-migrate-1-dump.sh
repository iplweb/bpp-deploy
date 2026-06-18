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
# --no-owner --no-privileges: zrzut bez `ALTER ... OWNER TO <rola>` i bez
# GRANT/REVOKE. Docelowy SWIEZY cluster ma tylko superusera POSTGRES_USER
# (np. `postgres`) i NIE ma ról ze starego klastra (np. `bpp`) — per-bazowy
# pg_dump ról nie zrzuca (sa cluster-level). Bez tych flag load padal na
# "role bpp does not exist". Obiekty obejmuje na wlasnosc user ladujacy,
# Django laczy sie jako ten sam superuser. (Pojedynczy pg_dump i tak NIGDY
# nie tworzy userow — CREATE ROLE robi tylko pg_dumpall --globals.)
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

# Serwisy ktore moga PISAC do bazy (psuja spojnosc rownoleglego zrzutu).
# Nie tylko appserver: takze celery (workery/beat) i denorm-queue. To te same,
# ktore zatrzymuje --stop-app.
WRITER_SVCS="appserver workerserver celerybeat denorm-queue"
if [ "$STOP_APP" = 1 ]; then
    echo ">> Zatrzymuje aplikacje (appserver + workery + beat + denorm-queue)..." >&2
    run dc stop $WRITER_SVCS
else
    # Ostrzegaj/pytaj TYLKO o realnie dzialajace serwisy-pisarzy. Gdy zaden nie
    # chodzi (np. caly stack stoi, a recznie wstal tylko dbserver), zrzut jest
    # spojny i nie ma o co pytac -> bez promptu.
    RUNNING_SVCS="$(dc ps --status=running --services 2>/dev/null || true)"
    RUNNING_WRITERS=""
    for svc in $WRITER_SVCS; do
        if printf '%s\n' "$RUNNING_SVCS" | grep -qx "$svc"; then
            RUNNING_WRITERS="${RUNNING_WRITERS:+$RUNNING_WRITERS }$svc"
        fi
    done
    if [ -n "$RUNNING_WRITERS" ]; then
        echo ">> UWAGA: dzialaja serwisy mogace pisac do bazy: ${RUNNING_WRITERS}" >&2
        echo "   (--stop-app pominiete). Zrzut spojny tylko bez rownoleglych zapisow." >&2
        confirm "Kontynuowac zrzut mimo dzialajacych: ${RUNNING_WRITERS}?" \
            || { echo "Przerwano."; exit 1; }
    else
        echo ">> Zaden serwis-pisarz (appserver/workery/beat/denorm-queue) nie dziala" >&2
        echo "   -> zrzut spojny, kontynuuje bez zatrzymywania." >&2
    fi
fi

# Pasek postepu: jesli na hoscie jest `pv` i stderr to terminal, wpinamy go
# miedzy pg_dump a plik. Estymate (-s) liczymy z pg_database_size, ale UWAGA:
# to rozmiar FIZYCZNY na dysku. Plain-SQL dump nie zrzuca danych indeksow, za
# to ROZPAKOWUJE TOAST i koduje wszystko tekstem (COPY) — dla bpp (duze pola
# tekstowe, tsvector search_index, hstore legacy_data) zrzut bywa ~2x wiekszy
# niz pg_database_size, wiec goly -s zanizal pasek do ~50%. Zadna funkcja
# katalogu nie zna logicznego rozmiaru, wiec KALIBRUJEMY: trzymamy w pliku
# stosunek (rozmiar_zrzutu / pg_database_size) z POPRZEDNIEGO uruchomienia i
# mnozymy nim biezacy pg_database_size. Pierwszy run: ratio=1.0 (jak dotad);
# po zrzucie zapisujemy zmierzony ratio (patrz nizej). Gdy pv nie ma —
# identity-pipe przez `cat`; nieudane zapytanie o rozmiar -> pv bez -s.
RATIO_FILE="${HOST_BACKUP_DIR}/.pg-dump-size-ratio"
file_size() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null; }

PROGRESS=(cat)
DB_BYTES=0
if [ -t 2 ] && command -v pv >/dev/null 2>&1; then
    DB_BYTES="$(dc exec -T -e "PGPASSWORD=${DJANGO_BPP_DB_PASSWORD}" dbserver psql \
        -h "${DJANGO_BPP_DB_HOST}" -p "${DJANGO_BPP_DB_PORT}" \
        -U "${DJANGO_BPP_DB_USER}" -d "${DJANGO_BPP_DB_NAME}" \
        -tAc "SELECT pg_database_size('${DJANGO_BPP_DB_NAME}')" 2>/dev/null \
        | tr -d '[:space:]')"
    case "$DB_BYTES" in ''|*[!0-9]*) DB_BYTES=0 ;; esac
    if [ "$DB_BYTES" -gt 0 ]; then
        RATIO=1.0
        if [ -r "$RATIO_FILE" ]; then
            R="$(tr -d '[:space:]' < "$RATIO_FILE")"
            # akceptuj tylko dodatnia liczbe w rozsadnym zakresie 0.1..20
            # (chroni przed uszkodzonym plikiem dajacym absurdalny -s).
            if printf '%s' "$R" | grep -qE '^[0-9]+(\.[0-9]+)?$' \
               && LC_ALL=C awk "BEGIN{exit !($R>=0.1 && $R<=20)}"; then
                RATIO="$R"
            fi
        fi
        EST="$(LC_ALL=C awk "BEGIN{printf \"%d\", $DB_BYTES * $RATIO}")"
        echo ">> Estymata pv: ${EST} B (pg_database_size ${DB_BYTES} B x ratio ${RATIO})" >&2
        PROGRESS=(pv -s "$EST")
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
echo ">> pg_dump -Fp --no-owner --no-privileges (zrodlo: stary cluster) -> ${OUT_PATH}" >&2
dc exec -T -e "PGPASSWORD=${DJANGO_BPP_DB_PASSWORD}" dbserver pg_dump \
    -Fp --no-owner --no-privileges \
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

# Kalibracja na przyszlosc: zapisz stosunek realnego rozmiaru zrzutu do
# pg_database_size. Nastepny run uzyje go jako mnoznika estymaty pv (patrz
# wyzej). Tylko gdy znalismy DB_BYTES (pv aktywne, zapytanie sie powiodlo).
if [ "${DB_BYTES:-0}" -gt 0 ]; then
    ACTUAL="$(file_size "$OUT_PATH")"
    case "$ACTUAL" in ''|*[!0-9]*) ACTUAL=0 ;; esac
    if [ "$ACTUAL" -gt 0 ]; then
        # LC_ALL=C: separator dziesietny MUSI byc kropka (pl_PL dalby "0,400",
        # co nie przejdzie walidacji ^[0-9]+(\.[0-9]+)?$ przy nastepnym odczycie).
        NEW_RATIO="$(LC_ALL=C awk "BEGIN{printf \"%.3f\", $ACTUAL / $DB_BYTES}")"
        if printf '%s\n' "$NEW_RATIO" > "$RATIO_FILE" 2>/dev/null; then
            echo ">> Ratio kalibracji pv zapisane: ${NEW_RATIO} (-> ${RATIO_FILE})" >&2
        fi
    fi
fi

echo ">> Gotowe. Zrzut plain SQL:" >&2
# Jedyne, co idzie na czysty STDOUT — sciezka do .sql (dla kroku 2).
printf '%s\n' "$OUT_PATH"

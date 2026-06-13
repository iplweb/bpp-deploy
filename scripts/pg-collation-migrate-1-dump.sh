#!/usr/bin/env bash
#
# KROK 1/3 migracji "pozbadz sie kolacji libc pl_PL" (przejscie z obrazu
# iplweb/bpp_dbserver na stockowy postgres). Patrz lib-pg-collation-migrate.sh.
#
# Robi logical dump BIEZACEGO clustra (ktory wciaz chodzi na STARYM obrazie
# iplweb/bpp_dbserver, bo tylko on ma locale libc pl_PL.UTF-8). Format
# katalogowy (-Fd) + tar, dokladnie jak `make db-backup`, zeby krok 2 mial
# wejscie.
#
# WAZNE: zanim zrzucisz, zatrzymaj zapisy. Domyslnie skrypt NIE zatrzymuje
# aplikacji; podaj --stop-app, zeby zatrzymal appserver + workery + beat +
# denorm-queue (jak `make restore`). Alternatywnie zrob recznie:
#     docker compose stop appserver workerserver celerybeat denorm-queue
#
# Uzycie:
#     bash scripts/pg-collation-migrate-1-dump.sh [--stop-app] [--yes]
#
# Wypisuje na STDOUT pelna sciezke do tarballa (do podania krokowi 2).

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
            sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "BLAD: nieznany argument: $1" >&2; exit 1 ;;
    esac
done

load_env
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"
TS="$(date +%Y%m%d-%H%M%S)"
DUMP_DIRNAME="db-backup-${TS}"
DUMP_TAR="${DUMP_DIRNAME}.tar.gz"

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

echo ">> pg_dump -Fd -j ${PARALLEL_JOBS} (zrodlo: stary cluster) -> /backup/${DUMP_DIRNAME}" >&2
dc exec -T -e "PGPASSWORD=${DJANGO_BPP_DB_PASSWORD}" dbserver pg_dump \
    -Fd -j "${PARALLEL_JOBS}" \
    -h "${DJANGO_BPP_DB_HOST}" -p "${DJANGO_BPP_DB_PORT}" \
    -U "${DJANGO_BPP_DB_USER}" "${DJANGO_BPP_DB_NAME}" \
    -f "/backup/${DUMP_DIRNAME}"

echo ">> Pakuje ${DUMP_TAR}..." >&2
dc exec -T dbserver tar czf "/backup/${DUMP_TAR}" -C /backup "${DUMP_DIRNAME}"
dc exec -T dbserver rm -rf "/backup/${DUMP_DIRNAME}"

echo ">> Gotowe. Tarball:" >&2
# Jedyne, co idzie na czysty STDOUT — sciezka do tarballa (dla kroku 2).
printf '%s\n' "${HOST_BACKUP_DIR}/${DUMP_TAR}"

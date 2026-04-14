#!/usr/bin/env bash
#
# Wykrywa major version PostgreSQL na zewnętrznym serwerze.
#
# Używa 'docker run' z obrazem postgres:17-alpine, żeby nie wymagać
# zainstalowanego psql na hoście. psql v17 potrafi połączyć się ze
# starszymi wersjami serwera i odczytać server_version_num.
#
# Argumenty:
#   $1 - HOST
#   $2 - PORT
#   $3 - USER
#   $4 - PASSWORD
#   $5 - DBNAME
#
# Wyjście:
#   stdout: major version (np. "17", "16"), gdy sukces
#   stderr: diagnostyka, gdy błąd
#   exit:   0 gdy sukces, !=0 gdy nie udało się wykryć
#
# Wywoływane z: scripts/init-configs.sh

set -euo pipefail

HOST="${1:-}"
PORT="${2:-}"
USER="${3:-}"
PASSWORD="${4:-}"
DBNAME="${5:-}"

if [ -z "$HOST" ] || [ -z "$PORT" ] || [ -z "$USER" ] || [ -z "$DBNAME" ]; then
    echo "usage: $0 HOST PORT USER PASSWORD DBNAME" >&2
    exit 2
fi

# --network host pozwala dosięgnąć hosta zewnętrznej bazy na hostach Linux
# (na macOS/Windows Docker Desktop zachowuje się inaczej, ale zewnętrzne
# bazy w deploymentach produkcyjnych są zwykle osiągalne publicznie lub
# przez host network).
if ! server_version_num="$(
    docker run --rm \
        -e PGPASSWORD="$PASSWORD" \
        -e PGCONNECT_TIMEOUT=5 \
        --network host \
        postgres:17-alpine \
        psql \
            -h "$HOST" \
            -p "$PORT" \
            -U "$USER" \
            -d "$DBNAME" \
            -tAXc "SHOW server_version_num;" \
        2>/tmp/detect-pg-err.$$
)"; then
    echo "ERROR: nie udało się połączyć z $HOST:$PORT jako $USER" >&2
    if [ -s /tmp/detect-pg-err.$$ ]; then
        sed 's/^/  psql: /' /tmp/detect-pg-err.$$ >&2
    fi
    rm -f /tmp/detect-pg-err.$$
    exit 1
fi
rm -f /tmp/detect-pg-err.$$

# Usuń białe znaki
server_version_num="$(echo "$server_version_num" | tr -d '[:space:]')"

if [ -z "$server_version_num" ]; then
    echo "ERROR: pusta odpowiedź na SHOW server_version_num" >&2
    exit 1
fi

# server_version_num: np. 170001 -> 17, 160004 -> 16, 150008 -> 15
# Major = wartość / 10000 (dla PostgreSQL 10+)
major=$(( server_version_num / 10000 ))

if [ "$major" -lt 10 ]; then
    echo "ERROR: wykryto PostgreSQL < 10 (server_version_num=$server_version_num) - nieobsługiwane" >&2
    exit 1
fi

echo "$major"

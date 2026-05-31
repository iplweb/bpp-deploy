#!/usr/bin/env bash
# Nadaje role pg_monitor uzytkownikowi BPP w dbserver.
# pg_monitor (built-in od PG 10) daje read na pg_stat_*, pg_stat_database*
# itd. - bez DDL/DML, best-practice dla collectorow monitoringowych.
#
# Idempotentne: GRANT ... TO ... powtorzony nic nie psuje.
# Tryb external: nie dziala (DBA musi grantnac recznie), skrypt to wykryje
# i wyswietli SQL do skopiowania.

set -euo pipefail

: "${BPP_CONFIGS_DIR:?BPP_CONFIGS_DIR not set}"

ENV_FILE="$BPP_CONFIGS_DIR/.env"
[ -f "$ENV_FILE" ] || { echo "BLAD: brak $ENV_FILE"; exit 1; }

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

DB_USER="${DJANGO_BPP_DB_USER:?}"
DB_NAME="${DJANGO_BPP_DB_NAME:?}"

SQL="GRANT pg_monitor TO \"$DB_USER\";"

# Wykryj tryb external - dbserver w external mode nie jest serwisem compose.
if ! docker compose ps --services 2>/dev/null | grep -q '^dbserver$'; then
    echo "Wykryto tryb external (dbserver nie jest w compose)."
    echo ""
    echo "Wykonaj recznie na zewnetrznym serwerze Postgres:"
    echo "  $SQL"
    echo ""
    echo "Bez tego collector Netdaty zglosi 'permission denied for view pg_stat_*'."
    exit 0
fi

echo "Granting pg_monitor TO $DB_USER w dbserver..."
docker compose exec -T dbserver psql -U "$DB_USER" -d "$DB_NAME" -c "$SQL"
echo "OK."

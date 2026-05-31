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

# Read specific vars from .env without sourcing (handles shell-unfriendly
# values like 'EMAIL=Name <addr@domain>' which break bash source).
_get_env() {
    local raw
    raw="$(grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
    # Strip surrounding double or single quotes if present
    if [ "${raw#\"}" != "$raw" ] && [ "${raw%\"}" != "$raw" ]; then
        raw="${raw#\"}"; raw="${raw%\"}"
    fi
    if [ "${raw#\'}" != "$raw" ] && [ "${raw%\'}" != "$raw" ]; then
        raw="${raw#\'}"; raw="${raw%\'}"
    fi
    printf '%s' "$raw"
}

DB_USER="$(_get_env DJANGO_BPP_DB_USER)"
DB_NAME="$(_get_env DJANGO_BPP_DB_NAME)"

if [ -z "$DB_USER" ] || [ -z "$DB_NAME" ]; then
    echo "BLAD: DJANGO_BPP_DB_USER lub DJANGO_BPP_DB_NAME puste w $ENV_FILE" >&2
    exit 1
fi

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

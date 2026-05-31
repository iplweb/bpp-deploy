#!/usr/bin/env bash
# Konfiguruje PostgreSQL do monitoringu wolnych zapytan:
# - log_min_duration_statement = 1000 (kazde zapytanie >1s leci do logu)
# - pg_stat_statements extension (agregowane statystyki per query)
#
# Idempotentne. shared_preload_libraries wymaga restartu dbservera -
# skrypt to robi automatycznie. ALTER SYSTEM zapisuje do
# postgresql.auto.conf (przezywa restart kontenera).
#
# Tryb external: skrypt wykrywa i wyswietla SQL do recznego uruchomienia
# przez DBA na zewnetrznym serwerze.

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

SLOW_QUERY_MS=1000

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Tryb external wykrywamy po BPP_DATABASE_COMPOSE w repo .env (NIE po obecnosci
# serwisu 'dbserver' - w external mode istnieje serwis-sentinel o tej samej
# nazwie, wiec heurystyka "czy jest dbserver" dawala falszywy internal i
# probowala exec psql na sentinelu zamiast pokazac instrukcje).
DATABASE_COMPOSE="$(grep -E '^BPP_DATABASE_COMPOSE=' "$REPO_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
if [ "$DATABASE_COMPOSE" = "docker-compose.database.external.yml" ]; then
    cat <<EOF
Wykryto tryb external (dbserver nie jest w compose).

Wykonaj recznie na zewnetrznym serwerze Postgres jako superuser:

  ALTER SYSTEM SET log_min_duration_statement = $SLOW_QUERY_MS;
  SELECT pg_reload_conf();

  -- Sprawdz biezace shared_preload_libraries i dolacz pg_stat_statements:
  SHOW shared_preload_libraries;
  -- Jezeli puste: ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements';
  -- Jezeli nie zawiera pg_stat_statements:
  --   ALTER SYSTEM SET shared_preload_libraries = '<obecna_wartosc>,pg_stat_statements';
  -- Restart Postgresa wymagany po zmianie shared_preload_libraries.

  -- Po restarcie, w bazie $DB_NAME:
  CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

EOF
    exit 0
fi

# Internal mode
# PGPASSWORD przez -e (nie w argv -> niewidoczne w `ps`); ON_ERROR_STOP=1 zeby
# blad SQL zwracal != 0 (bez tego psql konczy exit 0 mimo bledu, set -e nie lapie).
DB_PASSWORD="$(_get_env DJANGO_BPP_DB_PASSWORD)"
psql_run() {
    docker compose exec -T -e PGPASSWORD="$DB_PASSWORD" dbserver \
        psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" -tA -c "$1"
}

echo "1/4 ALTER SYSTEM SET log_min_duration_statement = $SLOW_QUERY_MS"
psql_run "ALTER SYSTEM SET log_min_duration_statement = $SLOW_QUERY_MS;" >/dev/null
psql_run "SELECT pg_reload_conf();" >/dev/null

echo "2/4 Check shared_preload_libraries for pg_stat_statements"
current="$(psql_run "SHOW shared_preload_libraries;" | tr -d ' ' | tr -d '\r')"
echo "    current: '$current'"
NEEDS_RESTART=0
if echo "$current" | grep -q 'pg_stat_statements'; then
    echo "    pg_stat_statements juz w shared_preload_libraries - skip"
else
    if [ -z "$current" ] || [ "$current" = '""' ]; then
        new="pg_stat_statements"
    else
        new="${current},pg_stat_statements"
    fi
    echo "    dodaje pg_stat_statements - new: '$new'"
    # Walidacja przed wstawieniem do literalu SQL ALTER SYSTEM: wartosc pochodzi
    # z SHOW (zywy PG) - nazwy bibliotek to tylko [a-z0-9_,]. Cokolwiek innego =
    # odmowa, zamiast budowac potencjalnie niebezpieczny SQL.
    case "$new" in
        *[!a-z0-9_,]*) echo "BLAD: nieoczekiwane znaki w shared_preload_libraries: '$new'" >&2; exit 1 ;;
    esac
    psql_run "ALTER SYSTEM SET shared_preload_libraries = '$new';" >/dev/null
    NEEDS_RESTART=1
fi

if [ $NEEDS_RESTART -eq 1 ]; then
    echo "3/4 Restart dbservera (shared_preload_libraries wymaga restartu)"
    docker compose restart dbserver
    # Wait for healthy
    healthy=0
    for i in $(seq 1 60); do
        cid="$(docker compose ps -q dbserver 2>/dev/null)"
        if [ -n "$cid" ]; then
            status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "")"
            if [ "$status" = "healthy" ]; then
                echo "    dbserver healthy po ${i}s"
                healthy=1
                break
            fi
        fi
        sleep 1
    done
    if [ $healthy -eq 0 ]; then
        echo "BLAD: dbserver nie osiagnal stanu healthy w ciagu 60s." >&2
        echo "      Sprawdz: docker compose logs dbserver" >&2
        exit 1
    fi
else
    echo "3/4 Restart pominiety (nic do zaaplikowania)"
fi

echo "4/4 CREATE EXTENSION pg_stat_statements"
psql_run "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" >/dev/null

echo ""
echo "Tworze/aktualizuje read-only uzytkownika monitoringu (bpp_monitor)..."
bash "$REPO_DIR/scripts/create-monitoring-user.sh"

echo ""
echo "DONE."
echo "  log_min_duration_statement = $SLOW_QUERY_MS ms"
echo "  pg_stat_statements: zainstalowane"
echo ""
echo "Dashboardy w Grafanie:"
echo "  - 'PostgreSQL: Slow queries (log)' - z Loki, ostatnie X dni"
echo "  - 'PostgreSQL: Top 100 queries (pg_stat_statements)' - top wg mean_exec_time"

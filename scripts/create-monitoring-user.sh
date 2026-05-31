#!/usr/bin/env bash
# Tworzy read-only uzytkownika PostgreSQL `bpp_monitor` uzywanego przez
# Grafane (datasource) i Netdate (kolektor postgres). NIE jest to uzytkownik
# aplikacji (BPP) - osobna, ograniczona rola tylko do odczytu:
#   - pg_monitor        -> pg_stat_*, pg_stat_statements (built-in od PG10)
#   - pg_read_all_data  -> SELECT na wszystkich tabelach (built-in od PG14;
#                          best-effort, dashboardy i tak korzystaja gl. ze stat-view)
# Rola NIE ma DDL/DML - panel SQL w Grafanie nie moze nic zepsuc w bazie.
#
# Idempotentne: ponowne uruchomienie aktualizuje tylko haslo i granty.
# Haslo z DJANGO_BPP_PG_MONITOR_PASSWORD (generowane przez ensure-config-files.sh).
#
# Tryby:
#   internal  - dbserver to prawdziwy Postgres w compose; laczymy sie jako
#               superuser (DJANGO_BPP_DB_USER) przez `docker compose exec`.
#   external  - dbserver to sentinel; DBA musi utworzyc role recznie -
#               skrypt wypisuje gotowy SQL.
#
# Flagi:
#   --soft    - nie przerywa (exit 0) gdy baza jeszcze nie wstala / brak hasla;
#               uzywane przez `make up`, zeby nie blokowac startu stacka.
#               Bez --soft (standalone / make create-monitoring-user) bledy
#               sa twarde (exit != 0).

set -euo pipefail

SOFT=0
[ "${1:-}" = "--soft" ] && SOFT=1

# W trybie --soft realny problem ma byc WIDOCZNY (warning), ale nie wywalac
# `make up`. Bez --soft - twardy blad.
fail() {
    echo "BLAD: $*" >&2
    [ "$SOFT" -eq 1 ] && { echo "  (--soft: pomijam, sprobuj ponownie pozniej: make create-monitoring-user)" >&2; exit 0; }
    exit 1
}

: "${BPP_CONFIGS_DIR:?BPP_CONFIGS_DIR not set}"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$BPP_CONFIGS_DIR/.env"
[ -f "$ENV_FILE" ] || fail "brak $ENV_FILE (uruchom: make init-configs)"

# Czyta zmienna z .env bez source'owania (wartosci typu 'EMAIL=Name <a@b>'
# wywalaja bash source). Zdejmuje otaczajace cudzyslowy.
_get_env() {
    local raw
    raw="$(grep -E "^${1}=" "$2" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
    if [ "${raw#\"}" != "$raw" ] && [ "${raw%\"}" != "$raw" ]; then
        raw="${raw#\"}"; raw="${raw%\"}"
    fi
    if [ "${raw#\'}" != "$raw" ] && [ "${raw%\'}" != "$raw" ]; then
        raw="${raw#\'}"; raw="${raw%\'}"
    fi
    printf '%s' "$raw"
}

MON_USER="bpp_monitor"
MON_PASS="$(_get_env DJANGO_BPP_PG_MONITOR_PASSWORD "$ENV_FILE")"
SU_USER="$(_get_env DJANGO_BPP_DB_USER "$ENV_FILE")"
SU_PASS="$(_get_env DJANGO_BPP_DB_PASSWORD "$ENV_FILE")"
DB_NAME="$(_get_env DJANGO_BPP_DB_NAME "$ENV_FILE")"

[ -n "$MON_PASS" ] || fail "DJANGO_BPP_PG_MONITOR_PASSWORD puste w $ENV_FILE (uruchom: make ensure-config-files)"
if [ -z "$SU_USER" ] || [ -z "$DB_NAME" ]; then
    fail "DJANGO_BPP_DB_USER/DJANGO_BPP_DB_NAME puste w $ENV_FILE"
fi

# Zabezpieczenie przed SQL-injection: haslo trafia do literalu SQL (CREATE ROLE
# ... PASSWORD '...'). ensure-config-files generuje je przez `openssl rand -hex`
# (tylko [0-9a-f]). Jesli ktos recznie wstawil haslo ze znakami spoza
# alfanumerycznych - odmawiamy, zamiast budowac niebezpieczny SQL.
case "$MON_PASS" in
    *[!A-Za-z0-9]*)
        fail "DJANGO_BPP_PG_MONITOR_PASSWORD zawiera znaki spoza [A-Za-z0-9].
      To haslo trafia do literalu SQL - uzyj alfanumerycznego (np. openssl rand -hex 24).
      Najprosciej: usun linie DJANGO_BPP_PG_MONITOR_PASSWORD z .env i odpal 'make ensure-config-files'." ;;
esac

# SQL budowany raz, uzywany w obu trybach. Haslo zwalidowane wyzej (alfanumeryczne).
read -r -d '' SQL <<SQL_EOF || true
SET client_min_messages = warning;
DO \$bpp\$
BEGIN
   IF EXISTS (SELECT FROM pg_roles WHERE rolname = '${MON_USER}') THEN
      ALTER ROLE ${MON_USER} LOGIN PASSWORD '${MON_PASS}';
   ELSE
      CREATE ROLE ${MON_USER} LOGIN PASSWORD '${MON_PASS}';
   END IF;
END
\$bpp\$;
GRANT pg_monitor TO ${MON_USER};
GRANT CONNECT ON DATABASE "${DB_NAME}" TO ${MON_USER};
SQL_EOF

# pg_read_all_data istnieje dopiero od PG14 - osobny, best-effort statement,
# zeby brak roli na starszym PG nie wywalil calosci (pg_monitor wystarcza dla
# obecnych dashboardow).
SQL_READALL="DO \$b\$ BEGIN IF EXISTS (SELECT FROM pg_roles WHERE rolname='pg_read_all_data') THEN GRANT pg_read_all_data TO ${MON_USER}; END IF; END \$b\$;"

# Tryb external: dbserver to sentinel, nie prawdziwa baza.
DATABASE_COMPOSE="$(_get_env BPP_DATABASE_COMPOSE "$REPO_DIR/.env")"
if [ "$DATABASE_COMPOSE" = "docker-compose.database.external.yml" ]; then
    # W trybie --soft (wpiety w `make up`) nie zasmiecaj outputu pelnym SQL
    # przy kazdym starcie - tylko krotkie przypomnienie.
    if [ "$SOFT" -eq 1 ]; then
        echo "  (external DB: utworz role read-only recznie -> make create-monitoring-user)"
        exit 0
    fi
    cat <<EOF
Wykryto tryb external (BPP_DATABASE_COMPOSE=docker-compose.database.external.yml).
Utworz role read-only recznie na zewnetrznym serwerze Postgres jako superuser:

----------------------------------------------------------------------
${SQL}
${SQL_READALL}
----------------------------------------------------------------------

Haslo musi byc identyczne z DJANGO_BPP_PG_MONITOR_PASSWORD w $ENV_FILE.
Bez tej roli Grafana/Netdata zgloszą 'password authentication failed for user "${MON_USER}"'.
EOF
    exit 0
fi

# Tryb internal: czekaj az dbserver bedzie healthy (w --soft tylko krotko).
cid="$(docker compose ps -q dbserver 2>/dev/null || true)"
[ -n "$cid" ] || fail "dbserver nie jest uruchomiony (make up najpierw)"

tries=30
[ "$SOFT" -eq 1 ] && tries=3
healthy=0
for _ in $(seq 1 "$tries"); do
    status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "")"
    if [ "$status" = "healthy" ]; then healthy=1; break; fi
    sleep 1
done
[ "$healthy" -eq 1 ] || fail "dbserver nie osiagnal stanu healthy (sprawdz: make logs-dbserver)"

echo "Tworze/aktualizuje role read-only '${MON_USER}' w bazie '${DB_NAME}'..."
# -v ON_ERROR_STOP=1: psql ma zwrocic != 0 przy bledzie SQL (inaczej exit 0 mimo bledu).
# PGPASSWORD jako env exec - nie ląduje w argv (ps).
if ! docker compose exec -T -e PGPASSWORD="$SU_PASS" dbserver \
        psql -v ON_ERROR_STOP=1 -U "$SU_USER" -d "$DB_NAME" -c "$SQL"; then
    fail "nie udalo sie utworzyc roli ${MON_USER} (czy ${SU_USER} jest superuserem?)"
fi
# Best-effort pg_read_all_data (PG14+); nie przerywa gdy starszy PG.
docker compose exec -T -e PGPASSWORD="$SU_PASS" dbserver \
    psql -v ON_ERROR_STOP=1 -U "$SU_USER" -d "$DB_NAME" -c "$SQL_READALL" \
    || echo "  (pg_read_all_data niedostepne - PG<14? pg_monitor wystarcza dla dashboardow)"

echo "OK: rola ${MON_USER} gotowa (read-only: pg_monitor + pg_read_all_data)."

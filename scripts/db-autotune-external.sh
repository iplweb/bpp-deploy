#!/usr/bin/env bash
# ============================================================================
# db-autotune-external.sh — autotune dla ZEWNETRZNEGO serwera PostgreSQL
# ============================================================================
# `make db-autotune-external RAM=16G CPU=8`
#
# Baza w Dockerze stroi sie sama przy kazdym starcie (dbserver/autotune.sh,
# RAM i rdzenie z cgroup kontenera). Baza zewnetrzna nie ma jak — nie
# widzimy jej maszyny. Ten skrypt uruchamia TEN SAM dbserver/autotune.sh
# z parametrami podanymi przez operatora i wypisuje gotowce do wklejenia:
#
#   1. fragment postgresql.conf (albo plik w conf.d/),
#   2. to samo jako ALTER SYSTEM (gdy nie ma dostepu do plikow serwera),
#   3. porownanie z tym, co baza ma TERAZ (tylko tryb external, gdy dziala
#      sentinel dbserver) — co sie zmieni i co wymaga restartu.
#
# NICZEGO nie zmienia: ani w bazie, ani w .env. Jedno zrodlo wzorow
# (autotune.sh) — nie kopiowac ich tutaj, bo rozjada sie z baza w Dockerze.
#
# Po co: max_connections ustawione za wysoko jak na RAM bazy (kazdy backend
# moze wziac work_mem razy kilka) konczy sie padnieciem bazy pod skanem,
# zanim zadziala jakikolwiek limit polaczen. autotune liczy max_connections
# i work_mem RAZEM, z tego samego RAM-u.
#
# BPP_AUTOTUNE_LIVE=0 wylacza krok 3 (testy; brak dockera).
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AUTOTUNE="$REPO_DIR/dbserver/autotune.sh"

# Parametry wymagajace RESTARTU PostgreSQL (context = postmaster). Reszta
# z autotune'a wchodzi po pg_reload_conf(). Krok 3 bierze to z pg_settings
# bazy; ta lista jest dla wydruku bez polaczenia.
RESTART_KEYS=" max_connections shared_buffers wal_buffers max_worker_processes max_locks_per_transaction max_pred_locks_per_transaction "

usage() {
    cat >&2 <<'EOF'
Uzycie: make db-autotune-external RAM=<pamiec> CPU=<rdzenie>

  RAM  pamiec serwera bazy: 16G, 16GB, 16 (= GB), 512M, 16384MB
  CPU  liczba rdzeni serwera bazy (np. 8)

Bez parametrow (w terminalu) zapyta o oba.
EOF
}

# ram_to_mb WARTOSC -> liczba MB na stdout albo kod 1
ram_to_mb() {
    local v
    v="$(printf '%s' "$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
    v="${v%B}"
    case "$v" in
        '' ) return 1 ;;
        *[!0-9GMT]* ) return 1 ;;
    esac
    local num="${v%[GMT]}" unit="${v##*[0-9]}"
    case "$num" in ''|*[!0-9]*) return 1 ;; esac
    num=$((10#$num))
    case "$unit" in
        ''|G) echo $((num * 1024)) ;;
        M)    echo "$num" ;;
        T)    echo $((num * 1024 * 1024)) ;;
        *)    return 1 ;;
    esac
}

RAM_IN="${1:-}"
CPU_IN="${2:-}"

if [ -z "$RAM_IN" ] || [ -z "$CPU_IN" ]; then
    if [ -t 0 ]; then
        echo "Parametry ZEWNETRZNEGO serwera PostgreSQL (nie tego hosta)."
        [ -n "$RAM_IN" ] || read -r -p "RAM serwera bazy (np. 16G): " RAM_IN
        [ -n "$CPU_IN" ] || read -r -p "Liczba rdzeni serwera bazy (np. 8): " CPU_IN
    else
        usage
        exit 2
    fi
fi

if ! RAM_MB="$(ram_to_mb "$RAM_IN")" || [ "$RAM_MB" -lt 256 ]; then
    echo "BLAD: RAM='$RAM_IN' — podaj np. 16G albo 512M (minimum 256M)." >&2
    exit 2
fi
case "$CPU_IN" in
    ''|*[!0-9]*|0) echo "BLAD: CPU='$CPU_IN' — podaj liczbe rdzeni, np. 8." >&2; exit 2 ;;
esac
CPU=$((10#$CPU_IN))

DATABASE_COMPOSE="$(grep -E '^BPP_DATABASE_COMPOSE=' "$REPO_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
EXTERNAL=0
[ "$DATABASE_COMPOSE" = "docker-compose.database.external.yml" ] && EXTERNAL=1

# Wylacznie linie "klucz = wartosc" (komentarze autotune'a mowia o zmiennych
# srodowiskowych kontenera — przy wklejaniu na obcy serwer tylko myla).
CONF="$(POSTGRESQL_RAM_THIS_MUCH_GB="$RAM_MB" POSTGRESQL_NPROC="$CPU" \
        POSTGRESQL_UNSAFE_BUT_FAST='' sh "$AUTOTUNE" | grep -E '^[a-z_]+ = ')"

if [ "$RAM_MB" -ge 1024 ] && [ $((RAM_MB % 1024)) -eq 0 ]; then
    RAM_OPIS="$((RAM_MB / 1024)) GB"
else
    RAM_OPIS="$RAM_MB MB"
fi

echo
if [ "$EXTERNAL" -eq 0 ]; then
    echo "UWAGA: ta instalacja ma baze w Dockerze — ona stroi sie sama przy starcie"
    echo "(z DBSERVER_MEM_LIMIT). Ponizsze przyda sie tylko dla innego serwera."
    echo
fi

cat <<EOF
==============================================================================
 1. postgresql.conf — serwer bazy: RAM $RAM_OPIS, rdzeni $CPU
==============================================================================
Wklej na KONIEC postgresql.conf albo zapisz jako osobny plik, np.
/etc/postgresql/<wersja>/main/conf.d/bpp-autotune.conf (Debian/Ubuntu).
Zakladamy, ze serwer jest DEDYKOWANY bazie — jesli dzieli maszyne z czyms
innym, podaj RAM=<tyle, ile ma dostac PostgreSQL>.

# --- BPP autotune ($(date +%Y-%m-%d)): RAM $RAM_OPIS, $CPU rdzeni ---
# Wygenerowane przez make db-autotune-external (bpp-deploy, dbserver/autotune.sh)
$CONF
# --- koniec BPP autotune ---

==============================================================================
 2. To samo przez SQL (jako superuser, gdy nie ma dostepu do plikow)
==============================================================================
EOF

while IFS= read -r line; do
    k="${line%% = *}"; v="${line#* = }"
    printf "ALTER SYSTEM SET %s = '%s';\n" "$k" "$v"
done <<<"$CONF"
echo "SELECT pg_reload_conf();"

RESTART_LIST=""
while IFS= read -r line; do
    k="${line%% = *}"
    case "$RESTART_KEYS" in *" $k "*) RESTART_LIST="$RESTART_LIST $k" ;; esac
done <<<"$CONF"

cat <<EOF

Wymaga RESTARTU PostgreSQL (reload nie wystarczy):$RESTART_LIST
Reszta dziala od razu po pg_reload_conf(). Sprawdzenie po restarcie:
  SELECT name, setting, unit, pending_restart FROM pg_settings WHERE pending_restart;
(pusta lista = wszystko weszlo).

Po zmianie max_connections zrestartuj tez pgbouncer, zeby przeliczyl pule:
  docker compose restart pgbouncer
EOF

# pgbouncer odejmuje od max_connections rezerwe na klientow bezposrednich
# (min. 40, pgbouncer/entrypoint.sh) i nie schodzi z pula ponizej 10.
MAXC_NOWE="$(sed -n 's/^max_connections = //p' <<<"$CONF")"
if [ -n "$MAXC_NOWE" ] && [ "$MAXC_NOWE" -lt 100 ]; then
    PULA_OK=$(( MAXC_NOWE - 40 )); [ "$PULA_OK" -ge 10 ] || PULA_OK=10
    echo
    echo "UWAGA: max_connections = $MAXC_NOWE to malo dla BPP. Celery, denorm-queue,"
    echo "authserver i monitoring lacza sie z baza bezposrednio (pgbouncer zostawia im"
    echo "co najmniej 40), wiec dla stron WWW zostanie pula ok. $PULA_OK polaczen."
    echo "Rozwaz wiecej RAM-u dla bazy (autotune: 100 polaczen na 1 GB, maks. 250)."
fi

# --- 3. porownanie z biezacymi ustawieniami ------------------------------------
[ "${BPP_AUTOTUNE_LIVE:-1}" = "0" ] && exit 0
[ "$EXTERNAL" -eq 1 ] || exit 0

if [ -z "$(cd "$REPO_DIR" && docker compose ps -q --status running dbserver 2>/dev/null)" ]; then
    echo
    echo "(Porownanie z baza pominiete: sentinel dbserver nie dziala — make up.)"
    exit 0
fi

KEYS_SQL="$(while IFS= read -r line; do printf "'%s'," "${line%% = *}"; done <<<"$CONF")"
KEYS_SQL="${KEYS_SQL%,}"
# current_setting() zwraca wartosc w tej samej postaci co autotune (4GB,
# 4194kB), wiec da sie porownac napisy. Haslo czytane W kontenerze.
SQL="SELECT name, current_setting(name), context FROM pg_settings WHERE name IN ($KEYS_SQL)
     UNION ALL SELECT '#aktywne', count(*)::text, '' FROM pg_stat_activity WHERE backend_type = 'client backend'"
if ! LIVE="$(cd "$REPO_DIR" && docker compose exec -T dbserver sh -c '
        PGPASSWORD="$DJANGO_BPP_DB_PASSWORD" PGCONNECT_TIMEOUT=5 \
        psql -X -h "$DJANGO_BPP_DB_HOST" -p "${DJANGO_BPP_DB_PORT:-5432}" \
             -U "$DJANGO_BPP_DB_USER" -d "$DJANGO_BPP_DB_NAME" \
             -Atq -F"|" -v ON_ERROR_STOP=1 -c "$1"' sh "$SQL" 2>&1)"; then
    echo
    echo "(Porownanie z baza pominiete — zapytanie nie przeszlo: ${LIVE##*$'\n'})"
    exit 0
fi

echo
echo "=============================================================================="
echo " 3. Co sie zmieni w bazie ${DJANGO_BPP_DB_HOST:-zewnetrznej} (stan na teraz)"
echo "=============================================================================="
printf '%-34s %-12s %-12s %s\n' "parametr" "teraz" "autotune" ""
AKTYWNE=""
while IFS='|' read -r name cur ctx; do
    if [ "$name" = "#aktywne" ]; then AKTYWNE="$cur"; continue; fi
    want="$(sed -n "s/^$name = //p" <<<"$CONF")"
    if [ "$cur" = "$want" ]; then
        uwaga="bez zmian"
    elif [ "$ctx" = "postmaster" ]; then
        uwaga="ZMIANA (restart)"
    else
        uwaga="ZMIANA (reload)"
    fi
    printf '%-34s %-12s %-12s %s\n' "$name" "$cur" "$want" "$uwaga"
done <<<"$LIVE"

if [ -n "$AKTYWNE" ] && [ -n "$MAXC_NOWE" ] && [ "$AKTYWNE" -ge $((MAXC_NOWE * 8 / 10)) ]; then
    echo
    echo "UWAGA: teraz jest $AKTYWNE polaczen klientow, a nowe max_connections = $MAXC_NOWE."
    echo "Sprawdz, kto je trzyma: make db-connection-stats"
fi

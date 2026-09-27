#!/bin/sh
# ============================================================================
# Skrypt startowy pgbouncera BPP (zamiast entrypointu obrazu edoburu/pgbouncer)
# ============================================================================
#
# Wywolanie (docker-compose.pgbouncer.yml):
#   sh /bpp-entrypoint.sh           -> render konfiguracji + exec pgbouncer
#   sh /bpp-entrypoint.sh zdrowie   -> sonda healthchecka (exit 0 = zdrowy)
#
# DLACZEGO WLASNY, A NIE OBRAZOWY: entrypoint obrazu wpisuje haslo do
# userlist.txt bez escapowania (`"` w hasle psuje plik) i wkleja wartosci do
# FORMATU printf (`%` psuje konfiguracje). Z obrazu bierzemy tylko binarke.
#
# Tryb `session` NA SZTYWNO: Django uzywa kursorow WITH HOLD (QuerySet.iterator
# w autocommicie), ktorych tryb transaction nie wspiera; tak samo LISTEN, SET,
# PREPARE. Tabela: https://www.pgbouncer.org/features.html
#
# Spec: docs/superpowers/specs/2026-09-27-pgbouncer-design.md
# ============================================================================

set -eu

ME="bpp-pgbouncer"
KONF="/etc/pgbouncer/pgbouncer.ini"
USERS="/etc/pgbouncer/userlist.txt"
PORT_PULI=6432

log() { echo "$ME: $*"; }

wymagana() {
    eval "_w=\${$1:-}"
    # shellcheck disable=SC2154  # ustawiana przez eval wyzej
    if [ -z "$_w" ]; then
        log "BLAD: brak zmiennej $1 w .env — pgbouncer nie wie, dokad sie laczyc" >&2
        exit 1
    fi
}

# liczba_lub_domyslna NAZWA DOMYSLNA — ten sam kontrakt co
# defaults/webserver/25-render-bpp-limits.sh: puste = domyslna, smiec =
# ostrzezenie + domyslna (literowka w .env nie moze polozyc strony).
liczba_lub_domyslna() {
    eval "_v=\${$1:-}"
    # shellcheck disable=SC2154
    _v=$(printf '%s' "$_v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    if [ -z "$_v" ]; then echo "$2"; return; fi
    case "$_v" in
        *[!0-9]*)
            log "OSTRZEZENIE: $1='$_v' nie jest liczba nieujemna — uzywam $2" >&2
            echo "$2" ;;
        *) printf '%s\n' "$_v" | sed 's/^0*//; s/^$/0/' ;;
    esac
}

# Pole userlist.txt: w cudzyslowach, kazdy `"` podwojony
# (https://www.pgbouncer.org/config.html, "Authentication file format").
pole() { printf '"%s"' "$(printf '%s' "$1" | sed 's/"/""/g')"; }

if [ "${1:-}" = "zdrowie" ]; then
    # Osobny wpis bazy `<NAME>_health` z pool_size=1: sonda nie stoi w kolejce
    # za nasycona glowna pula (inaczej pgbouncer robil sie `unhealthy`
    # dokladnie pod ruchem, ktory limity nginx maja obsluzyc).
    PGPASSWORD="$DJANGO_BPP_DB_PASSWORD" PGCONNECT_TIMEOUT=3 \
        psql -h 127.0.0.1 -p "$PORT_PULI" -U "$DJANGO_BPP_DB_USER" \
             -d "${DJANGO_BPP_DB_NAME}_health" -Atqc 'SELECT 1' 2>/dev/null | grep -qx 1
    exit $?
fi

wymagana DJANGO_BPP_DB_HOST
wymagana DJANGO_BPP_DB_NAME
wymagana DJANGO_BPP_DB_USER
wymagana DJANGO_BPP_DB_PASSWORD
DB_PORT="${DJANGO_BPP_DB_PORT:-5432}"

PULA=$(liczba_lub_domyslna PGBOUNCER_POOL_SIZE 80)
KLIENCI=$(liczba_lub_domyslna PGBOUNCER_MAX_CLIENT_CONN 1000)
[ "$PULA" -ge 1 ] || { log "OSTRZEZENIE: PGBOUNCER_POOL_SIZE=0 — uzywam 80" >&2; PULA=80; }
[ "$KLIENCI" -ge 1 ] || { log "OSTRZEZENIE: PGBOUNCER_MAX_CLIENT_CONN=0 — uzywam 1000" >&2; KLIENCI=1000; }

# --- Przyciecie puli do max_connections -------------------------------------
# Do tego samego serwera lacza sie BEZPOSREDNIO: Celery (floor(0.75 x rdzenie)
# dzieci), denorm-queue, beat, authserver, netdata, backup, sesje admina,
# alias _health, 3 sloty superuser_reserved_connections. nproc widzi rdzenie
# hosta. Pula wieksza niz max_connections wpada w petle server_login_retry.
RDZENIE=$(nproc 2>/dev/null || echo 4)
REZERWA=$(( 20 + (3 * RDZENIE + 3) / 4 ))
[ "$REZERWA" -ge 40 ] || REZERWA=40
if MAXC=$(PGPASSWORD="$DJANGO_BPP_DB_PASSWORD" PGCONNECT_TIMEOUT=5 \
        psql -h "$DJANGO_BPP_DB_HOST" -p "$DB_PORT" -U "$DJANGO_BPP_DB_USER" \
             -d "$DJANGO_BPP_DB_NAME" -Atqc 'SHOW max_connections' 2>/dev/null) \
        && [ -n "$MAXC" ]; then
    LIMIT=$(( MAXC - REZERWA ))
    [ "$LIMIT" -ge 10 ] || LIMIT=10
    if [ "$PULA" -gt "$LIMIT" ]; then
        log "OSTRZEZENIE: PGBOUNCER_POOL_SIZE=$PULA przekracza max_connections=$MAXC minus rezerwa $REZERWA — przycinam do $LIMIT. Obniz BPP_NGINX_GLOBAL_CONN do <= $LIMIT albo podnies DBSERVER_MEM_LIMIT (autotune: 100 polaczen na 1 GB)." >&2
        PULA=$LIMIT
    fi
else
    log "OSTRZEZENIE: nie udalo sie odczytac max_connections z $DJANGO_BPP_DB_HOST:$DB_PORT — pula $PULA bez sprawdzenia" >&2
fi

# --- Render --------------------------------------------------------------------
# rm -f: obraz ma juz userlist.txt (0644), a przekierowanie do ISTNIEJACEGO
# pliku zachowuje jego tryb — umask dziala tylko przy tworzeniu.
rm -f "$USERS"
umask 077
{
    pole "$DJANGO_BPP_DB_USER"; printf ' '; pole "$DJANGO_BPP_DB_PASSWORD"; printf '\n'
} > "$USERS"

umask 022
cat > "$KONF" <<INI
; Wygenerowane przez $ME przy starcie kontenera — NIE EDYTOWAC.
; Zrodlo: pgbouncer/entrypoint.sh w repo bpp-deploy.
[databases]
$DJANGO_BPP_DB_NAME = host=$DJANGO_BPP_DB_HOST port=$DB_PORT
${DJANGO_BPP_DB_NAME}_health = host=$DJANGO_BPP_DB_HOST port=$DB_PORT dbname=$DJANGO_BPP_DB_NAME pool_size=1

[pgbouncer]
listen_addr = *
listen_port = $PORT_PULI
auth_type = scram-sha-256
auth_file = $USERS
pool_mode = session
default_pool_size = $PULA
max_db_connections = $PULA
max_client_conn = $KLIENCI
query_wait_timeout = 15
log_connections = 0
log_disconnections = 0
stats_users = $DJANGO_BPP_DB_USER
INI

log "pula $PULA polaczen do $DJANGO_BPP_DB_HOST:$DB_PORT/$DJANGO_BPP_DB_NAME, do $KLIENCI klientow, tryb session"
exec pgbouncer "$KONF"

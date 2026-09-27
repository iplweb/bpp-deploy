#!/usr/bin/env bash
# SC2016: fragmenty SQL/sh w apostrofach CELOWO — rozwijaja sie w kontenerze.
# SC2015: `warunek && ok ... || zle ...` jest bezpieczne, bo `ok` zawsze
#   zwraca 0.
# shellcheck disable=SC2016,SC2015
# Test pgbouncera BPP na zywo: prawdziwy PostgreSQL (SCRAM) + obraz
# edoburu/pgbouncer z NASZYM skryptem startowym (pgbouncer/entrypoint.sh).
#
# Sprawdza zachowanie, nie tekst konfiguracji: logowanie tym samym kontem
# (takze z haslem pelnym metaznakow), izolacje i reset sesji miedzy klientami
# (tryb session + DISCARD ALL), ponowne uzycie backendu (zrodlo przyspieszenia),
# sonde zdrowia przy nasyconej puli, walidacje zmiennych i przyciecie puli do
# max_connections. Spec: docs/superpowers/specs/2026-09-27-pgbouncer-design.md
#
# Nie wymaga .env ani dzialajacej instalacji BPP — tylko dockera.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRZEBIEG="${PGB_TEST_SUFFIX:-$$}"
NET="bpp-pgb-test-net-$PRZEBIEG"
PG="bpp-pgb-test-db-$PRZEBIEG"
PGB="bpp-pgb-test-bouncer-$PRZEBIEG"
CLI="bpp-pgb-test-cli-$PRZEBIEG"
PG_IMAGE="postgres:18.4"
PGB_IMAGE="edoburu/pgbouncer:${PGBOUNCER_VERSION:-v1.25.2-p0}"
DB="bpp"
USR="bpp"
# Haslo celowo pelne metaznakow: " (format userlist.txt), % (printf),
# $ (sh/Compose), \ (escape), spacja.
HASLO='p"a%s$ w\x'

BLEDY=0
ok()  { echo "  OK    $*"; }
zle() { echo "  BLAD  $*"; BLEDY=$((BLEDY + 1)); }

# shellcheck disable=SC2317,SC2329  # wolane przez `trap`
czysc() {
    [ "${PGB_TEST_KEEP:-0}" = 1 ] && { echo "PGB_TEST_KEEP=1 — zostaja $PG $PGB $CLI $NET"; return; }
    docker rm -f "$PG" "$PGB" "$CLI" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
}
trap czysc EXIT

docker info >/dev/null 2>&1 || { echo "BLAD: docker niedostepny."; exit 1; }

# start_db MAX_CONNECTIONS [ALIAS] — PostgreSQL pod aliasem sieciowym.
# Alias inny niz "dbserver" celowo: pgbouncer ma dzialac z dowolnym hostem
# (tryb bazy zewnetrznej).
start_db() {
    docker rm -f "$PG" >/dev/null 2>&1
    docker run -d --name "$PG" --network "$NET" --network-alias "${2:-baza-zewnetrzna}" \
        -e POSTGRES_DB="$DB" -e POSTGRES_USER="$USR" -e POSTGRES_PASSWORD="$HASLO" \
        "$PG_IMAGE" -c "max_connections=$1" >/dev/null || return 1
    for _ in $(seq 1 30); do
        docker exec "$PG" pg_isready -U "$USR" -d "$DB" -h 127.0.0.1 >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

# start_pgb [-e VAR=wartosc ...] — pgbouncer z naszym skryptem, czeka na port.
start_pgb() {
    docker rm -f "$PGB" >/dev/null 2>&1
    docker run -d --name "$PGB" --network "$NET" --network-alias pgbouncer \
        -e DJANGO_BPP_DB_HOST=baza-zewnetrzna -e DJANGO_BPP_DB_PORT=5432 \
        -e DJANGO_BPP_DB_NAME="$DB" -e DJANGO_BPP_DB_USER="$USR" \
        -e DJANGO_BPP_DB_PASSWORD="$HASLO" \
        "$@" \
        -v "$REPO_DIR/pgbouncer/entrypoint.sh:/bpp-entrypoint.sh:ro" \
        --entrypoint sh "$PGB_IMAGE" /bpp-entrypoint.sh >/dev/null || return 1
    for _ in $(seq 1 20); do
        docker exec "$PGB" nc -z 127.0.0.1 6432 >/dev/null 2>&1 && return 0
        [ "$(docker inspect -f '{{.State.Running}}' "$PGB" 2>/dev/null)" = true ] || return 1
        sleep 0.5
    done
    return 1
}

# q SQL — jedno polaczenie klienta przez pule, wynik bez naglowkow.
q() {
    docker exec -e PGPASSWORD="$HASLO" "$CLI" \
        psql -h pgbouncer -p 6432 -U "$USR" -d "$DB" -Atq -v ON_ERROR_STOP=1 -c "$1" 2>&1
}

# trzymaj SEKUNDY SQL... — klient w tle: wykonuje SQL, potem trzyma polaczenie
# BEZCZYNNIE (`\! sleep`, bez zapytania) przez SEKUNDY sekund. Bezczynnosc jest
# istotna: w trybie transaction pgbouncer oddaje wtedy backend do puli, wiec
# nastepny klient trafia na TEN SAM backend (LIFO) — i mutacja jest wykryta
# deterministycznie. `SELECT pg_sleep()` zajmowalby backend w obu trybach.
trzymaj() {
    local s="$1"; shift
    local args=()
    for sql in "$@"; do args+=(-c "$sql"); done
    docker exec -d -e PGPASSWORD="$HASLO" "$CLI" \
        psql -h pgbouncer -p 6432 -U "$USR" -d "$DB" -Atq "${args[@]}" -c "\\! sleep $s"
}

ini() { docker exec "$PGB" cat /etc/pgbouncer/pgbouncer.ini; }
log_pgb() { docker logs "$PGB" 2>&1; }

echo "== przygotowanie =="
docker network create "$NET" >/dev/null
docker run -d --name "$CLI" --network "$NET" --entrypoint sleep "$PG_IMAGE" infinity >/dev/null
start_db 300 || { echo "BLAD: PostgreSQL nie wstal."; exit 1; }

echo "== 1-3. logowanie, haslo z metaznakami, LISTEN =="
if start_pgb; then
    [ "$(q 'SELECT 1')" = "1" ] && ok "logowanie przez pule tym samym kontem (haslo z \" % \$ \\ spacja)" \
        || zle "logowanie przez pule: $(q 'SELECT 1')"
    [ "$(q 'LISTEN kanal; SELECT 1')" = "1" ] && ok "LISTEN przez pule" || zle "LISTEN: $(q 'LISTEN kanal; SELECT 1')"
    LOG="$(log_pgb)"
    # pgbouncer loguje przy starcie (poziom LOG, nie ostrzezenie):
    #   kernel file descriptor limit: N (hard: H); max_client_conn: C, max expected fd use: M
    # Realny problem to N < M — pod pelnym obciazeniem zabraklo by deskryptorow.
    FD="$(grep -o 'kernel file descriptor limit: [0-9]*\|max expected fd use: [0-9]*' <<<"$LOG" | grep -o '[0-9]*$' | tr '\n' ' ')"
    read -r FD_LIMIT FD_UZYCIE <<<"$FD"
    if [ -n "${FD_UZYCIE:-}" ] && [ "$FD_LIMIT" -ge "$FD_UZYCIE" ]; then
        ok "limit deskryptorow $FD_LIMIT >= przewidywane zuzycie $FD_UZYCIE (max_client_conn=1000)"
    else
        zle "limit deskryptorow za niski lub brak linii w logu: '${FD}'"
    fi
    G="$(ini)"
    grep -q "^pool_mode = session$" <<<"$G" && ok "pool_mode = session" || zle "brak pool_mode = session"
    grep -q "^default_pool_size = 80$" <<<"$G" && ok "pula domyslna 80" || zle "pula: $(grep pool_size <<<"$G")"
    grep -q "^max_client_conn = 1000$" <<<"$G" && ok "max_client_conn 1000" || zle "brak max_client_conn = 1000"
    [ "$(docker exec "$PGB" stat -c %a /etc/pgbouncer/userlist.txt)" = "600" ] && ok "userlist.txt 0600" \
        || zle "userlist.txt ma tryb $(docker exec "$PGB" stat -c %a /etc/pgbouncer/userlist.txt)"
else
    zle "pgbouncer nie wstal: $(log_pgb | tail -3)"
fi

echo "== 5. ponowne uzycie backendu (zrodlo przyspieszenia) =="
P1="$(q 'SELECT pg_backend_pid()')"; P2="$(q 'SELECT pg_backend_pid()')"
[ -n "$P1" ] && [ "$P1" = "$P2" ] && ok "dwa kolejne polaczenia klienta -> ten sam backend ($P1)" \
    || zle "rozne backendy: '$P1' vs '$P2'"

echo "== 6. psql --single-transaction -f (jak baseline_load) =="
W6="$(docker exec -i -e PGPASSWORD="$HASLO" "$CLI" psql -h pgbouncer -p 6432 -U "$USR" -d "$DB" \
    -Atq -v ON_ERROR_STOP=1 --single-transaction -f - 2>&1 <<'SQL'
SET client_min_messages = warning;
CREATE TABLE baseline_test (id int, nazwa text);
COPY baseline_test (id, nazwa) FROM stdin;
1	pierwszy
2	drugi
\.
SELECT count(*) FROM baseline_test;
SQL
)"
[ "$W6" = "2" ] && ok "SET/CREATE/COPY w jednej transakcji przez pule" || zle "baseline: $W6"

echo "== 4. izolacja klientow (lock trzymany przez A) =="
trzymaj 4 "SELECT pg_advisory_lock(42)"
sleep 1
[ "$(q 'SELECT pg_try_advisory_lock(42)')" = "f" ] && ok "B nie dostaje locka trzymanego przez A" \
    || zle "B dostal lock A — klienci dziela backend (tryb transaction?)"
sleep 4

echo "== 7. sonda zdrowia przy nasyconej glownej puli =="
if start_pgb -e PGBOUNCER_POOL_SIZE=2; then
    docker exec "$PGB" sh /bpp-entrypoint.sh zdrowie >/dev/null 2>&1 && ok "sonda zielona (pusta pula)" \
        || zle "sonda czerwona przy pustej puli"
    # w trybie session bezczynny klient i tak trzyma backend -> pula 2 pelna
    trzymaj 8 "SELECT 1"; trzymaj 8 "SELECT 1"
    sleep 1
    if timeout 5 docker exec "$PGB" sh /bpp-entrypoint.sh zdrowie >/dev/null 2>&1; then
        ok "sonda zielona przy pelnej glownej puli (osobny wpis _health)"
    else
        zle "sonda czerwona/zawieszona przy pelnej puli — idzie przez glowna pule"
    fi
    sleep 8
else
    zle "pgbouncer nie wstal (pula 2)"
fi

echo "== 4b. reset sesji miedzy klientami (pula 1 = deterministycznie) =="
if start_pgb -e PGBOUNCER_POOL_SIZE=1; then
    PA="$(q "SELECT pg_advisory_lock(42); SET bpp.test = 'zostalo'; SELECT pg_backend_pid()" | tail -1)"
    WB="$(q "SELECT pg_backend_pid() || '|' || pg_try_advisory_lock(42) || '|' || coalesce(current_setting('bpp.test', true), '')")"
    PB="${WB%%|*}"
    [ "$PA" = "$PB" ] && ok "B trafil na backend A ($PA) — wynik deterministyczny" \
        || zle "B na innym backendzie ('$PA' vs '$PB') — test nie rozstrzyga"
    # bool w konkatenacji tekstowej to 'true'/'false', nie 't'/'f'
    [ "$WB" = "$PA|true|" ] && ok "po rozlaczeniu A: lock zwolniony, SET niewidoczny (DISCARD ALL)" \
        || zle "stan sesji A przeciekl do B: '$WB'"
else
    zle "pgbouncer nie wstal (pula 1)"
fi

echo "== 7b. sonda czerwona przy zlym hasle =="
if start_pgb -e DJANGO_BPP_DB_PASSWORD=zle-haslo; then
    timeout 8 docker exec "$PGB" sh /bpp-entrypoint.sh zdrowie >/dev/null 2>&1 \
        && zle "sonda zielona mimo zlego hasla" || ok "sonda czerwona przy zlym hasle"
else
    zle "pgbouncer nie wstal przy zlym hasle (ma wstac, a sonda ma byc czerwona)"
fi

echo "== 8. smiec w zmiennych nie kladzie pgbouncera =="
if start_pgb -e PGBOUNCER_POOL_SIZE=abc -e PGBOUNCER_MAX_CLIENT_CONN="10 0"; then
    G="$(ini)"; LOG="$(log_pgb)"
    grep -q "^default_pool_size = 80$" <<<"$G" && grep -q "^max_client_conn = 1000$" <<<"$G" \
        && ok "bledne wartosci zastapione domyslnymi" || zle "nie wrocono do domyslnych: $(grep -E 'pool_size|client_conn' <<<"$G")"
    grep -q "OSTRZEZENIE: PGBOUNCER_POOL_SIZE='abc'" <<<"$LOG" && ok "ostrzezenie w logu" \
        || zle "brak ostrzezenia o PGBOUNCER_POOL_SIZE"
else
    zle "pgbouncer nie wstal na blednych wartosciach"
fi

echo "== 9. przyciecie puli do max_connections =="
start_db 50 || zle "PostgreSQL (max_connections=50) nie wstal"
if start_pgb; then
    G="$(ini)"; LOG="$(log_pgb)"
    grep -q "^default_pool_size = 10$" <<<"$G" && grep -q "^max_db_connections = 10$" <<<"$G" \
        && ok "pula 80 przycieta do 10 przy max_connections=50" || zle "brak przyciecia: $(grep pool_size <<<"$G")"
    grep -q "OSTRZEZENIE: .*max_connections" <<<"$LOG" && grep -q "BPP_NGINX_GLOBAL_CONN" <<<"$LOG" \
        && ok "ostrzezenie z instrukcja dla operatora" || zle "brak ostrzezenia o przycieciu"
else
    zle "pgbouncer nie wstal przy max_connections=50"
fi

echo "== 12. baza niedostepna przy starcie — start nie wisi i nie pada =="
docker stop "$PG" >/dev/null
T0=$(date +%s)
if start_pgb; then
    T=$(( $(date +%s) - T0 ))
    [ "$T" -le 12 ] && ok "pgbouncer wstal w ${T}s mimo niedostepnej bazy" || zle "start trwal ${T}s"
    grep -q "OSTRZEZENIE: .*max_connections" <<<"$(log_pgb)" && ok "ostrzezenie o nieudanej sondzie" \
        || zle "brak ostrzezenia o nieudanej sondzie max_connections"
    grep -q "^default_pool_size = 80$" <<<"$(ini)" && ok "bez sondy: pula bez przyciecia" || zle "pula zmieniona bez sondy"
else
    zle "pgbouncer nie wstal przy niedostepnej bazie"
fi

echo "== 11. brak wymaganej zmiennej = glosny blad =="
docker rm -f "$PGB" >/dev/null 2>&1
docker run --name "$PGB" --network "$NET" \
    -e DJANGO_BPP_DB_HOST=baza-zewnetrzna -e DJANGO_BPP_DB_NAME="$DB" -e DJANGO_BPP_DB_USER="$USR" \
    -v "$REPO_DIR/pgbouncer/entrypoint.sh:/bpp-entrypoint.sh:ro" \
    --entrypoint sh "$PGB_IMAGE" /bpp-entrypoint.sh >/dev/null 2>&1
RC=$?
[ "$RC" -ne 0 ] && grep -q "DJANGO_BPP_DB_PASSWORD" <<<"$(log_pgb)" \
    && ok "brak DJANGO_BPP_DB_PASSWORD: exit $RC z nazwa zmiennej" || zle "brak hasla nie zatrzymal startu (rc=$RC)"

echo
if [ "$BLEDY" -eq 0 ]; then echo "WYNIK: wszystko zgodne."; exit 0; fi
echo "WYNIK: $BLEDY niezgodnosci."
exit 1

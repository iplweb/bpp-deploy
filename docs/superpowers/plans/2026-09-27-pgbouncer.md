# pgbouncer przed PostgreSQL dla appservera — plan implementacji

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Usługa `pgbouncer` (tryb `session`), przez którą appserver łączy się z PostgreSQL — domyślnie włączona, ta sama konfiguracja dla `dbserver` i bazy zewnętrznej.

**Architecture:** Nowy `docker-compose.pgbouncer.yml` z obrazem `edoburu/pgbouncer`, ale z WŁASNYM skryptem startowym `pgbouncer/entrypoint.sh` (render `pgbouncer.ini` + `userlist.txt`, walidacja zmiennych, przycięcie puli do `max_connections`, podkomenda `zdrowie` dla healthchecka). appserver dostaje w `environment:` nadpisanie `DJANGO_BPP_DB_HOST/_PORT` z `BPP_APPSERVER_DB_HOST/_PORT` (domyślnie `pgbouncer:6432`) i `depends_on: pgbouncer: service_healthy`. Reszta serwisów bez zmian.

**Tech Stack:** Docker Compose v2 (`include:`), pgbouncer 1.25.2 (`edoburu/pgbouncer:v1.25.2-p0`, Alpine, busybox `sh`, uid 70), PostgreSQL 18, bash (testy), MkDocs.

**Spec:** `docs/superpowers/specs/2026-09-27-pgbouncer-design.md` (wersja 3, commit `95ec1ad`). Wykonawca czyta spec i plan.

## Global Constraints

- Tryb `pool_mode = session` NA SZTYWNO — bez zmiennej, bez przełącznika.
- Przez pulę idzie **wyłącznie appserver**. authserver, workerserver, celerybeat, denorm-queue, flower, netdata, backup — bez zmian.
- `DJANGO_BPP_DB_HOST`/`_PORT` w `.env` dalej znaczą „prawdziwa baza”; NIE przepinamy ich na pulę.
- Zmienne i domyślne: `BPP_APPSERVER_DB_HOST=pgbouncer`, `BPP_APPSERVER_DB_PORT=6432`, `PGBOUNCER_POOL_SIZE=80`, `PGBOUNCER_MAX_CLIENT_CONN=1000`, `PGBOUNCER_VERSION=v1.25.2-p0`, `PGBOUNCER_MEM_LIMIT=64m`, `PGBOUNCER_CPU_LIMIT=0.5`.
- Zero migracji `.env`; stary `.env` musi działać bez edycji (kontrakt backwards-compat w CLAUDE.md).
- appserver → pgbouncer: `condition: service_healthy` (jak do `dbserver`). Żadnego `scale`, żadnej „kłamiącej” sondy.
- Healthcheck przez osobny wpis bazy `<NAME>_health` z `pool_size=1`.
- `entrypoint: ["sh", "/bpp-entrypoint.sh"]` — nie polegamy na bicie `+x`.
- Skrypt startowy: POSIX `sh` (busybox), nie bash.
- `$$` w każdym inline shellu w compose (CLAUDE.md, „CRITICAL: `$$`”).
- Każda nowa usługa: `logging: *default-logging`, własne `x-logging` w pliku.
- `query_wait_timeout = 15`, `log_connections = 0`, `log_disconnections = 0`, `stats_users = <DJANGO_BPP_DB_USER>`, `listen_addr = *`, `listen_port = 6432`.
- Rezerwa przy przycinaniu: `max(40, 20 + ceil(0.75 × nproc))`; przycięcie do `max(10, max_connections − rezerwa)`.

## Review Focus

- **Hasło ze znakami specjalnymi** (`"`, `%`, `$`, spacja, `\`) — logowanie przez pulę ma działać tak samo jak bezpośrednio. Pokryte: Task 1, przypadek 2 (hasło testowe zawiera też `\`).
- **Brak wymaganej zmiennej bazy** (`DJANGO_BPP_DB_NAME`/`_USER`/`_PASSWORD`/`_HOST` pusty) — pgbouncer ma nie wstać z czytelnym komunikatem, a nie wstać z pustą konfiguracją. Pokryte: Task 1, przypadek 11.
- **Baza niedostępna w chwili startu pgbouncera** (sonda `max_connections` nie odpowiada) — start nie może wisieć dłużej niż kilka sekund i nie może się przerwać. Pokryte: Task 1, przypadek 12.
- **Stary `.env` bez żadnej nowej zmiennej** — `git pull && make up` ma przełączyć appserver na pulę bez edycji. Pokryte: Task 2, render compose z minimalnym `.env`.
- **Operator kieruje appserver bezpośrednio do bazy** (`BPP_APPSERVER_DB_HOST=dbserver`) — appserver łączy się bezpośrednio, pozostałe serwisy bez zmian. Pokryte: Task 2.

---

## File Structure

| Plik | Odpowiedzialność |
|---|---|
| `pgbouncer/entrypoint.sh` (nowy) | render konfiguracji, walidacja, przycięcie puli, `exec pgbouncer`; podkomenda `zdrowie` |
| `scripts/test-pgbouncer.sh` (nowy) | test na żywo: prawdziwy postgres + pgbouncer z naszym skryptem |
| `docker-compose.pgbouncer.yml` (nowy) | usługa `pgbouncer` |
| `docker-compose.yml` | `include:` nowego pliku |
| `docker-compose.application.yml` | appserver: nadpisanie hosta/portu bazy + `depends_on` |
| `scripts/configure-resources.sh` | `pgbouncer:64` + prefiks `PGBOUNCER` |
| `tests/test_makefile.sh` | asercje statyczne na wyrenderowanym compose + configure-resources |
| `mk/misc.mk`, `Makefile`, `.github/workflows/ci.yml` | `make test-pgbouncer`, `make test`, CI |
| `docs/konfiguracja/pgbouncer.md` (nowy), `docs/architektura/uslugi.md`, `docs/konfiguracja/limity-zasobow.md`, `docs/eksploatacja/komendy.md`, `docs/konfiguracja/architektura.md`, `mkdocs.yml`, `CLAUDE.md` | dokumentacja |

---

### Task 1: Skrypt startowy pgbouncera + test na żywo

**Files:**
- Create: `pgbouncer/entrypoint.sh`
- Create: `scripts/test-pgbouncer.sh`

**Interfaces:**
- Produces: `sh /bpp-entrypoint.sh` — renderuje `/etc/pgbouncer/pgbouncer.ini` i `/etc/pgbouncer/userlist.txt`, potem `exec pgbouncer /etc/pgbouncer/pgbouncer.ini`.
- Produces: `sh /bpp-entrypoint.sh zdrowie` — exit 0, gdy `SELECT 1` przez `127.0.0.1:6432`, baza `${DJANGO_BPP_DB_NAME}_health`, kontem aplikacji zwraca `1` w ≤ 3 s; inaczej exit ≠ 0. Task 2 używa tego w healthchecku.
- Consumes (env): `DJANGO_BPP_DB_HOST`, `DJANGO_BPP_DB_PORT` (domyślnie 5432), `DJANGO_BPP_DB_NAME`, `DJANGO_BPP_DB_USER`, `DJANGO_BPP_DB_PASSWORD`, `PGBOUNCER_POOL_SIZE`, `PGBOUNCER_MAX_CLIENT_CONN`.
- Log: wszystkie komunikaty z prefiksem `bpp-pgbouncer:`; ostrzeżenia zawierają słowo `OSTRZEZENIE`.

- [ ] **Step 1: Napisz test na żywo `scripts/test-pgbouncer.sh`**

```bash
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
    grep -q "file descriptor" <<<"$LOG" && zle "ostrzezenie o limicie deskryptorow: $(grep 'file descriptor' <<<"$LOG")" \
        || ok "brak ostrzezenia o limicie deskryptorow (max_client_conn=1000)"
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
```

- [ ] **Step 2: Uruchom — ma paść (brak skryptu startowego)**

Run: `chmod +x scripts/test-pgbouncer.sh && git add scripts/test-pgbouncer.sh && git update-index --chmod=+x scripts/test-pgbouncer.sh && ./scripts/test-pgbouncer.sh 2>&1 | tail -5`
Expected: `BLAD  pgbouncer nie wstal: ...` i `WYNIK: N niezgodnosci.`, exit 1.

- [ ] **Step 3: Napisz `pgbouncer/entrypoint.sh`**

```sh
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
```

- [ ] **Step 4: Uruchom test — ma przejść**

Run: `./scripts/test-pgbouncer.sh 2>&1 | grep -E "OK|BLAD|WYNIK"`
Expected: same `OK`, ostatnia linia `WYNIK: wszystko zgodne.`

Jeśli `4b` zgłasza „B na innym backendzie” — pula 1 nie dała determinizmu; sprawdź `docker exec $PGB cat /etc/pgbouncer/pgbouncer.ini` (czy `default_pool_size = 1`) zanim cokolwiek zmienisz.

- [ ] **Step 5: Mutacje — każda musi wywrócić test (potem przywróć plik)**

Dla każdej: zmień, uruchom `./scripts/test-pgbouncer.sh 2>&1 | grep -E "BLAD|WYNIK"`, zanotuj, `git checkout pgbouncer/entrypoint.sh`.

| Mutacja w `pgbouncer/entrypoint.sh` | Oczekiwany BLAD |
|---|---|
| w `pole()` usuń `\| sed 's/"/""/g'` | przypadek 1–3 (logowanie) |
| `pool_mode = session` → `pool_mode = transaction` | przypadek 4 („B dostal lock A”) |
| dopisz `server_reset_query =` pod `pool_mode` | przypadek 4b („stan sesji A przeciekl”) |
| w `zdrowie` zamień `${DJANGO_BPP_DB_NAME}_health` na `${DJANGO_BPP_DB_NAME}` | przypadek 7 („sonda czerwona/zawieszona przy pelnej puli”) |

- [ ] **Step 6: shellcheck + commit**

Run: `docker run --rm -e LANG=C.UTF-8 -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable pgbouncer/entrypoint.sh scripts/test-pgbouncer.sh`
Expected: brak wyjścia, exit 0.

```bash
git add pgbouncer/entrypoint.sh scripts/test-pgbouncer.sh
git update-index --chmod=+x scripts/test-pgbouncer.sh
git commit -m "feat(pgbouncer): skrypt startowy (session, sonda _health, przyciecie puli) + test na zywo"
```

---

### Task 2: Usługa w compose + appserver przez pulę + testy statyczne + CI

**Files:**
- Create: `docker-compose.pgbouncer.yml`
- Modify: `docker-compose.yml` (lista `include:`)
- Modify: `docker-compose.application.yml` (blok `appserver:` — `environment:` i `depends_on:`)
- Modify: `tests/test_makefile.sh` (nowy test + wpis na liście uruchamianych)
- Modify: `mk/misc.mk`, `Makefile`, `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `sh /bpp-entrypoint.sh` i `sh /bpp-entrypoint.sh zdrowie` z Task 1.
- Produces: usługa compose `pgbouncer` na porcie 6432 w sieci projektu; `make test-pgbouncer`.

- [ ] **Step 1: Napisz test statyczny w `tests/test_makefile.sh`**

Wstaw przed nagłówkiem `# TEST 11c: WAF — klikalny cross-filtr` (ten sam styl co `test_nginx_global_limits_wired`):

```bash
# ============================================================
# TEST 11e: pgbouncer — tylko appserver przez pule, reszta bezposrednio
# ============================================================
# Na WYRENDEROWANYM `docker compose config` (grep po zrodle nie widzi
# interpolacji). `-p` jawnie: nazwa projektu z repo-lokalnego .env (np.
# pozostalosc po init-configs z katalogiem tmp.XXXX) potrafi byc niepoprawna.

_render_compose() {
    # $1 = katalog konfiguracji z .env; wynik na stdout
    (cd "$REPO_DIR" && BPP_CONFIGS_DIR="$1" docker compose -p bpp-compose-test config 2>"$1/stderr.txt")
}

test_pgbouncer_compose() {
    yellow "=== Test 11e: pgbouncer — kto laczy sie przez pule ==="

    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        skip_or_fail "docker niedostepny — pomijam render compose config"
        return
    fi

    local cfg out app
    cfg=$(mktemp -d)
    # Minimalny STARY .env: zadnej nowej zmiennej — tak wyglada instalacja
    # po `git pull` (kontrakt backwards-compat).
    printf 'DJANGO_BPP_HOST_BACKUP_DIR=%s\nDJANGO_BPP_DB_HOST=dbserver\nDJANGO_BPP_DB_PORT=5432\n' \
        "$cfg" > "$cfg/.env"

    if ! out="$(_render_compose "$cfg")"; then
        fail "compose config nie wyrenderowal sie ($(tail -1 "$cfg/stderr.txt"))"
        rm_rf_root "$cfg"; return
    fi

    app="$(svc_block appserver <(printf '%s\n' "$out"))"
    assert_svc_contains "appserver domyslnie przez pgbouncer" "DJANGO_BPP_DB_HOST: pgbouncer" "$app"
    if printf '%s\n' "$app" | grep -Eq 'DJANGO_BPP_DB_PORT: "?6432"?$'; then
        pass "appserver domyslnie na porcie 6432"
    else
        fail "appserver: brak DJANGO_BPP_DB_PORT 6432"
    fi
    if printf '%s\n' "$app" | grep -A1 -E '^      pgbouncer:$' | grep -q 'condition: service_healthy'; then
        pass "appserver czeka na zdrowy pgbouncer (jak na dbserver)"
    else
        fail "appserver -> pgbouncer bez condition: service_healthy"
    fi

    local s blok
    for s in authserver workerserver celerybeat denorm-queue flower; do
        blok="$(svc_block "$s" <(printf '%s\n' "$out"))"
        if printf '%s\n' "$blok" | grep -q 'pgbouncer'; then
            fail "$s laczy sie przez pgbouncer (ma isc bezposrednio)"
        else
            pass "$s bezposrednio do bazy"
        fi
    done

    local pgb
    pgb="$(svc_block pgbouncer <(printf '%s\n' "$out"))"
    assert_svc_contains "pgbouncer: logging local" "driver: local" "$pgb"
    assert_svc_contains "pgbouncer: entrypoint przez sh" "- sh" "$pgb"
    assert_svc_contains "pgbouncer: skrypt startowy" "/bpp-entrypoint.sh" "$pgb"
    assert_svc_contains "pgbouncer: sonda przez podkomende" "zdrowie" "$pgb"
    assert_svc_contains "pgbouncer: czeka na dbserver" "dbserver:" "$pgb"
    assert_svc_contains "pgbouncer: limit pamieci 64m" "memory: \"67108864\"" "$pgb"
    assert_file_contains "pgbouncer: serwisowy env_file" 'env_file: ${BPP_CONFIGS_DIR}/.env' \
        "$REPO_DIR/docker-compose.pgbouncer.yml"

    # Operator kieruje appserver bezposrednio do bazy.
    printf 'BPP_APPSERVER_DB_HOST=dbserver\nBPP_APPSERVER_DB_PORT=5432\n' >> "$cfg/.env"
    out="$(_render_compose "$cfg")"
    app="$(svc_block appserver <(printf '%s\n' "$out"))"
    assert_svc_contains "BPP_APPSERVER_DB_HOST=dbserver -> appserver bezposrednio" \
        "DJANGO_BPP_DB_HOST: dbserver" "$app"

    rm_rf_root "$cfg"
}
```

Dopisz wywołanie na liście na końcu pliku, po `test_nginx_global_limits_wired`:

```bash
test_pgbouncer_compose
```

- [ ] **Step 2: Uruchom — ma paść**

Run: `bash tests/test_makefile.sh </dev/null 2>&1 | grep -E "11e|pgbouncer|RESULTS"`
Expected: `FAIL: appserver domyslnie przez pgbouncer ...` (brak usługi i nadpisania).

Uwaga dla wykonawcy: jeśli `memory: "67108864"` nie pasuje, sprawdź faktyczny format w `docker compose -p x config | grep -A3 memory` i popraw **asercję** na to, jak Compose renderuje `64m` — nie zmieniaj limitu.

- [ ] **Step 3: Utwórz `docker-compose.pgbouncer.yml`**

```yaml
# pgbouncer przed PostgreSQL — pula polaczen WYLACZNIE dla appservera.
#
# Po co: Django (CONN_MAX_AGE=0, ASGI) otwiera nowe polaczenie przy kazdym
# zadaniu; pomiar 2026-09-27: 18 ms connect + ~8 ms zimnego cache na ~100 ms
# mediany zadania. Pula w trybie session oddaje gotowy, rozgrzany backend.
# Spec: docs/superpowers/specs/2026-09-27-pgbouncer-design.md
#
# Laczy sie z DJANGO_BPP_DB_HOST/_PORT — dbserver ALBO baza zewnetrzna,
# ta sama konfiguracja. Reszta serwisow (Celery, denorm-queue z LISTEN,
# netdata, backup) laczy sie bezposrednio, jak dotad.

x-logging: &default-logging
  driver: "local"
  options:
    max-size: "${LOG_MAX_SIZE:-150m}"
    max-file: "${LOG_MAX_FILE:-5}"

services:
  pgbouncer:
    image: edoburu/pgbouncer:${PGBOUNCER_VERSION:-v1.25.2-p0}
    restart: always
    logging: *default-logging
    # Serwisowy env_file jest KONIECZNY: ten z `include:` sluzy tylko
    # interpolacji i nie trafia do kontenera (ta sama lekcja co dbserver).
    env_file: ${BPP_CONFIGS_DIR}/.env
    # Przez interpreter, nie przez bit +x (w tym repo +x juz ginal).
    # Wlasny skrypt zamiast entrypointu obrazu — patrz naglowek skryptu.
    entrypoint: ["sh", "/bpp-entrypoint.sh"]
    volumes:
      - ./pgbouncer/entrypoint.sh:/bpp-entrypoint.sh:ro
    depends_on:
      # W trybie bazy zewnetrznej dbserver to sentinel sondujacy prawdziwa
      # baze — wiec to dziala w obu trybach.
      dbserver:
        condition: service_healthy
    healthcheck:
      # Osobny wpis bazy `_health` (pool_size=1): sonda nie stoi w kolejce za
      # nasycona glowna pula.
      test: ["CMD", "sh", "/bpp-entrypoint.sh", "zdrowie"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 10s
    deploy:
      resources:
        limits:
          memory: ${PGBOUNCER_MEM_LIMIT:-64m}
          cpus: "${PGBOUNCER_CPU_LIMIT:-0.5}"
```

- [ ] **Step 4: Dopisz `include:` w `docker-compose.yml`** — po wpisie `docker-compose.database.yml`/`BPP_DATABASE_COMPOSE`, a przed `docker-compose.infrastructure.yml`:

```yaml
  - path: docker-compose.pgbouncer.yml
    env_file:
      - ${BPP_CONFIGS_DIR}/.env
```

- [ ] **Step 5: appserver w `docker-compose.application.yml`**

W bloku `appserver:` zamień:

```yaml
    environment:
      DJANGO_BPP_ENABLE_PROMETHEUS: ${DJANGO_BPP_ENABLE_PROMETHEUS:-false}
```

na:

```yaml
    environment:
      DJANGO_BPP_ENABLE_PROMETHEUS: ${DJANGO_BPP_ENABLE_PROMETHEUS:-false}
      # appserver laczy sie z baza przez pgbouncer (docker-compose.pgbouncer.yml).
      # `environment:` wygrywa z `env_file:`, wiec DJANGO_BPP_DB_HOST w .env
      # dalej znaczy "prawdziwa baza" dla reszty serwisow i dla pgbouncera.
      # BPP_APPSERVER_DB_HOST=dbserver (lub host bazy zewn.) + _PORT=5432 =
      # appserver bezposrednio do bazy.
      DJANGO_BPP_DB_HOST: ${BPP_APPSERVER_DB_HOST:-pgbouncer}
      DJANGO_BPP_DB_PORT: ${BPP_APPSERVER_DB_PORT:-6432}
```

i w `depends_on:` tego bloku, po `dbserver:` + `condition: service_healthy`, dopisz:

```yaml
      # Jak do dbserver: bez puli strona nie dziala, wiec zepsuty pgbouncer
      # ma zatrzymac start (i `make up --wait`), a nie przepuscic appserver.
      pgbouncer:
        condition: service_healthy
```

- [ ] **Step 6: Uruchom testy statyczne — mają przejść**

Run: `bash tests/test_makefile.sh </dev/null 2>&1 | grep -E "11e|FAIL:|RESULTS"`
Expected: wszystkie asercje 11e `PASS`; jedyny `FAIL` dopuszczalny lokalnie na macOS to znany `invalid project name "tmp..."` z testu 11a (pozostałość w repo-lokalnym `.env`; na CI go nie ma).

- [ ] **Step 7: make target, `make test`, CI**

`mk/misc.mk` — do pierwszej linii `.PHONY:` dopisz ` test-pgbouncer`, a pod targetem `test-nginx-limits:` dodaj:

```make

# pgbouncer na zywo: prawdziwy PostgreSQL (SCRAM) + obraz edoburu/pgbouncer
# z NASZYM skryptem startowym. Sprawdza logowanie (takze haslo z metaznakami),
# izolacje i reset sesji (tryb session + DISCARD ALL), ponowne uzycie backendu,
# sonde przy nasyconej puli, walidacje i przyciecie puli do max_connections.
# Zmienne: PGB_TEST_KEEP=1 (zostaw kontenery).
test-pgbouncer:
	@./scripts/test-pgbouncer.sh
```

`Makefile` — w recepturze `test:` po `@./scripts/test-nginx-limits.sh` dodaj linię `	@./scripts/test-pgbouncer.sh`; w `help` po linii `test-nginx-limits` dodaj:

```make
	@echo "    test-pgbouncer       - pgbouncer (pula dla appservera) na zywym PostgreSQL (~1 min)"
```

`.github/workflows/ci.yml` — w jobie `test-runtime`, po kroku `Globalny limit nginx`:

```yaml

      # pgbouncer: logowanie, tryb session (izolacja + reset sesji), ponowne
      # uzycie backendu, sonda przy pelnej puli, przyciecie do max_connections.
      - name: pgbouncer
        run: ./scripts/test-pgbouncer.sh
```

- [ ] **Step 8: Commit**

```bash
git add docker-compose.pgbouncer.yml docker-compose.yml docker-compose.application.yml \
        tests/test_makefile.sh mk/misc.mk Makefile .github/workflows/ci.yml
git commit -m "feat(pgbouncer): usluga w compose, appserver przez pule (service_healthy), testy statyczne + CI"
```

---

### Task 3: `make configure-resources` zna pgbouncera

**Files:**
- Modify: `scripts/configure-resources.sh` (`FIXED_MEM`, `var_prefix_for`)
- Modify: `tests/test_makefile.sh` (`test_configure_resources`)

**Interfaces:**
- Produces: `PGBOUNCER_MEM_LIMIT=64m` w `.env` po `make configure-resources`.

- [ ] **Step 1: Dopisz asercję w `test_configure_resources`**, po linii z `dozzle cap 64m`:

```bash
    assert_file_contains "pgbouncer cap 64m" "PGBOUNCER_MEM_LIMIT=64m" "$cfg/.env"
    assert_file_not_contains "brak UNKNOWN_*"  "UNKNOWN_MEM_LIMIT="      "$cfg/.env"
```

- [ ] **Step 2: Uruchom — ma paść**

Run: `bash tests/test_makefile.sh </dev/null 2>&1 | grep -E "pgbouncer cap|UNKNOWN|RESULTS"`
Expected: `FAIL: pgbouncer cap 64m`.

- [ ] **Step 3: Implementacja** — w `scripts/configure-resources.sh`, w `FIXED_MEM` po `"autoheal:32"` dopisz `"pgbouncer:64"`; w `var_prefix_for` po linii `autoheal)` dopisz:

```bash
        pgbouncer)              echo "PGBOUNCER" ;;
```

- [ ] **Step 4: Uruchom — ma przejść**

Run: `bash tests/test_makefile.sh </dev/null 2>&1 | grep -E "pgbouncer cap|UNKNOWN|RESULTS"`
Expected: `PASS: pgbouncer cap 64m`, `PASS: brak UNKNOWN_*`.

- [ ] **Step 5: Commit**

```bash
git add scripts/configure-resources.sh tests/test_makefile.sh
git commit -m "feat(pgbouncer): configure-resources przydziela PGBOUNCER_MEM_LIMIT"
```

---

### Task 4: Dokumentacja

Użyj skilla `docs-sync` przed edycją.

**Files:**
- Create: `docs/konfiguracja/pgbouncer.md`
- Modify: `mkdocs.yml` (nav, po `PostgreSQL — wersje i upgrade`)
- Modify: `docs/architektura/uslugi.md` (tabela usług, sekcja „Zależności startu”)
- Modify: `docs/konfiguracja/limity-zasobow.md`
- Modify: `docs/eksploatacja/komendy.md` (sekcja „Testy”)
- Modify: `docs/konfiguracja/architektura.md` (drzewo plików compose)
- Modify: `CLAUDE.md` (drzewo compose + tripwire'y)

- [ ] **Step 1: `docs/konfiguracja/pgbouncer.md`**

````markdown
# pgbouncer — pula połączeń dla appservera

Appserver łączy się z PostgreSQL przez **pgbouncer** w trybie `session`.
Włączone domyślnie, bez żadnej zmiany w `.env`.

## Po co

Django w appserverze otwiera nowe połączenie z bazą przy **każdym** żądaniu
i zamyka je na końcu. Pomiar na publikacje.up.lublin.pl (27.09.2026): samo
połączenie kosztowało **18 ms**, a pierwsze zapytanie na świeżym połączeniu
kolejne ~8 ms (zimny cache katalogu) — przy medianie całego żądania 100 ms.

pgbouncer trzyma gotowe połączenia z bazą i oddaje je kolejnym żądaniom. Znika
tworzenie procesu PostgreSQL i zimny cache; zostaje tańsze logowanie do samego
pgbouncera (SCRAM).

To **nie** jest ochrona przed zalewem ruchu — tę dają
[limity nginx i appservera](../architektura/rate-limiting.md#limit-globalny).

## Co idzie przez pulę

| Serwis | Połączenie z bazą |
|---|---|
| appserver | **przez pgbouncer** |
| authserver, workerserver, celerybeat, denorm-queue, flower | bezpośrednio |
| netdata (`bpp_monitor`) | bezpośrednio — ma widzieć prawdziwy serwer |
| backup / restore | `docker exec` w `dbserver` — bez zmian |

pgbouncer łączy się z `DJANGO_BPP_DB_HOST`/`DJANGO_BPP_DB_PORT` — czyli
z `dbserver` albo z [bazą zewnętrzną](postgresql.md). Ta sama konfiguracja
w obu trybach. Logowanie tym samym kontem co dotąd
(`DJANGO_BPP_DB_USER`/`_PASSWORD`).

## Zmienne (`$BPP_CONFIGS_DIR/.env`)

| Zmienna | Domyślnie | Znaczenie |
|---|---|---|
| `BPP_APPSERVER_DB_HOST` | `pgbouncer` | dokąd łączy się appserver |
| `BPP_APPSERVER_DB_PORT` | `6432` | port dla powyższego |
| `PGBOUNCER_POOL_SIZE` | `80` | maks. połączeń pgbouncera do bazy |
| `PGBOUNCER_MAX_CLIENT_CONN` | `1000` | maks. połączeń appservera do pgbouncera |
| `PGBOUNCER_VERSION` | `v1.25.2-p0` | tag obrazu `edoburu/pgbouncer` |
| `PGBOUNCER_MEM_LIMIT` / `_CPU_LIMIT` | `64m` / `0.5` | [limity zasobów](limity-zasobow.md) |

Pusta wartość = domyślna; błędna liczba = `OSTRZEZENIE` w logu i domyślna.

Appserver bezpośrednio do bazy (z pominięciem puli):

```
BPP_APPSERVER_DB_HOST=dbserver     # albo host bazy zewnętrznej
BPP_APPSERVER_DB_PORT=5432
```

potem `make up`. Usługa `pgbouncer` dalej działa i dalej musi być zdrowa.

## Pula a `max_connections`

Do tego samego serwera łączą się też bezpośrednio Celery, denorm-queue
i reszta. Przy starcie pgbouncer odczytuje `max_connections` i — jeśli pula
się nie mieści — **przycina ją** z ostrzeżeniem w logu:

```
bpp-pgbouncer: OSTRZEZENIE: PGBOUNCER_POOL_SIZE=80 przekracza max_connections=100 minus rezerwa 40 — przycinam do 60. Obniz BPP_NGINX_GLOBAL_CONN do <= 60 albo podnies DBSERVER_MEM_LIMIT (autotune: 100 polaczen na 1 GB).
```

## Diagnostyka

```bash
docker compose logs pgbouncer | grep bpp-pgbouncer     # konfiguracja przy starcie
docker compose logs pgbouncer | grep stats             # co 60 s; pole "wait" > 0 = kolejka
docker compose exec pgbouncer sh -c 'PGPASSWORD="$DJANGO_BPP_DB_PASSWORD" psql -h 127.0.0.1 -p 6432 -U "$DJANGO_BPP_DB_USER" pgbouncer -c "SHOW POOLS"'
```

W `SHOW POOLS` kolumna `cl_waiting` > 0 znaczy, że appserver czeka na wolne
połączenie z bazą (po 15 s dostaje błąd).

## Awarie

pgbouncer jest infrastrukturą jak `dbserver`: gdy jest `unhealthy`, appserver
nie startuje, a `make up` kończy się błędem. Celery, denorm i panele działają
dalej.
````

- [ ] **Step 2: nav w `mkdocs.yml`** — po linii `      - PostgreSQL — wersje i upgrade: konfiguracja/postgresql.md` dodaj:

```yaml
      - pgbouncer (pula połączeń): konfiguracja/pgbouncer.md
```

- [ ] **Step 3: `docs/architektura/uslugi.md`** — w tabeli usług po wierszu `| **dbserver** | ...` dodaj:

```markdown
| **pgbouncer** | Pula połączeń PostgreSQL (tryb `session`) — **wyłącznie** dla appservera; reszta łączy się bezpośrednio ([pgbouncer](../konfiguracja/pgbouncer.md)) |
```

W sekcji `## Zależności startu` dopisz punkt: `pgbouncer` czeka na zdrowy `dbserver`; `appserver` czeka na zdrowy `pgbouncer`. (Dopasuj do formatu tej sekcji — przeczytaj ją najpierw.)

- [ ] **Step 4: `docs/konfiguracja/limity-zasobow.md`** — po akapicie o `GUNICORN_LIMIT_CONCURRENCY` dodaj:

```markdown
### pgbouncer — `PGBOUNCER_*`

`PGBOUNCER_MEM_LIMIT` (64 MB) i `_CPU_LIMIT` (0,5) — `make configure-resources`
wpisuje stały cap. `PGBOUNCER_POOL_SIZE` (80) to sufit połączeń puli do bazy;
musi się zmieścić w `max_connections` razem z połączeniami bezpośrednimi.
Łańcuch zależności: `DBSERVER_MEM_LIMIT` → autotune `max_connections`
(100 na 1 GB, maks. 250) → pula przycinana przy starcie do
`max_connections − max(40, 20 + 0,75 × rdzenie)`
([pgbouncer](pgbouncer.md#pula-a-max_connections)).
```

- [ ] **Step 5: `docs/eksploatacja/komendy.md`** — w bloku „Testy” po linii `make test-nginx-limits ...` dodaj:

```
make test-pgbouncer          # Czy pula pgbouncera działa (session, reset sesji, przycięcie puli)
```

oraz dopisz `test-pgbouncer` do zdania „…nie wymagają `.env`…” i do listy `./scripts/…` w notce „Na maszynie bez repo-owego `.env`”.

- [ ] **Step 6: drzewo compose** w `docs/konfiguracja/architektura.md` i `CLAUDE.md` — pod linią `docker-compose.database.yml` / `database.external.yml` dodaj:

```
├── docker-compose.pgbouncer.yml      # pgbouncer (pula dla appservera)
```

- [ ] **Step 7: tripwire w `CLAUDE.md`** — nowa sekcja po `### Service dependencies`:

```markdown
### pgbouncer — only appserver, only `session`

`appserver` reaches PostgreSQL through `pgbouncer` (`docker-compose.pgbouncer.yml`); every other service connects directly. `DJANGO_BPP_DB_HOST`/`_PORT` keep meaning "the real DB" — the appserver override is `BPP_APPSERVER_DB_HOST`/`_PORT` in its `environment:`. **Anti-fixes — do NOT:** (1) switch to `pool_mode = transaction` — Django's `QuerySet.iterator()` uses `WITH HOLD` cursors, and `LISTEN`/`SET`/`PREPARE` break too (https://www.pgbouncer.org/features.html); (2) repoint `DJANGO_BPP_DB_HOST` at the pool or route `denorm-queue` (`LISTEN`, all-day connection) through it; (3) go back to the image's own entrypoint — it writes the password into `userlist.txt` unescaped and pastes values into a `printf` format, so `"` or `%` in the password breaks login; (4) point the healthcheck at the main pool — it would queue behind a saturated pool and flip `unhealthy` exactly under load, hence the `<NAME>_health` alias with `pool_size=1`; (5) add an off-switch (`scale`, lying probe, `service_started`) — pgbouncer is infrastructure like `dbserver`, `appserver` waits on it `service_healthy` and an unhealthy one must fail `make up`. Pool is clamped at start to `max_connections − max(40, 20 + 0.75×nproc)`. Tests: `make test-pgbouncer` (live, mutation-checked) + `test_pgbouncer_compose`. Operator doc: `docs/konfiguracja/pgbouncer.md`.
```

- [ ] **Step 8: `mkdocs build --strict`**

Run: `uvx --with-requirements docs/requirements.txt mkdocs build --strict -d "$TMPDIR/site" 2>&1 | tail -3`
Expected: `Documentation built in …`, bez `WARNING`/`ERROR`.

- [ ] **Step 9: Commit**

```bash
git add docs/konfiguracja/pgbouncer.md mkdocs.yml docs/architektura/uslugi.md \
        docs/konfiguracja/limity-zasobow.md docs/eksploatacja/komendy.md \
        docs/konfiguracja/architektura.md CLAUDE.md
git commit -m "docs(pgbouncer): strona operatora, uslugi, limity, komendy, tripwire'y w CLAUDE.md"
```

---

### Task 5: Weryfikacja całości

**Files:** brak zmian (chyba że coś padnie — wtedy poprawka w pliku, którego dotyczy, i osobny commit).

- [ ] **Step 1: Wszystkie testy lokalnie**

```bash
./scripts/test-pgbouncer.sh 2>&1 | tail -1
./scripts/test-nginx-limits.sh 2>&1 | tail -1
./scripts/test-waf.sh 2>&1 | tail -1
bash tests/test_makefile.sh </dev/null 2>&1 | grep -E "FAIL:|RESULTS"
docker run --rm -e LANG=C.UTF-8 -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable \
    pgbouncer/entrypoint.sh scripts/test-pgbouncer.sh tests/test_makefile.sh
```

Expected: trzy `WYNIK: wszystko zgodne.` / `Wszystkie … zgodnie z oczekiwaniem.`; `RESULTS` bez nowych `FAIL` (dopuszczalny tylko znany lokalny `invalid project name "tmp..."` z testu 11a); shellcheck czysty.

- [ ] **Step 2: Render compose z prawdziwym układem** — sprawdź, że `make up` na świeżym katalogu się nie wywróci na interpolacji:

Run: `d=$(mktemp -d); printf 'DJANGO_BPP_HOST_BACKUP_DIR=%s\n' "$d" > "$d/.env"; BPP_CONFIGS_DIR=$d docker compose -p bpp-check config --services | sort | grep -x pgbouncer; rm -rf "$d"`
Expected: `pgbouncer`.

- [ ] **Step 3: Push brancha i CI**

```bash
git push -u origin feat/pgbouncer
gh pr create --base main --title "feat: pgbouncer (session) przed PostgreSQL dla appservera" --body-file <(printf '%s\n' "Spec: docs/superpowers/specs/2026-09-27-pgbouncer-design.md" "Plan: docs/superpowers/plans/2026-09-27-pgbouncer.md" "" "🤖 Generated with [Claude Code](https://claude.com/claude-code)")
gh pr checks --watch
```

Expected: wszystkie joby `pass`. NIE merguj bez zgody użytkownika.

- [ ] **Step 4: Pomiar na produkcji — POZA tym planem**

Wdrożenie na publikacje.up.lublin.pl i pomiar przed/po (kryterium: `connect` + pierwsze zapytanie ≥ 3× szybciej niż 27,7 ms, mediana `request_time` nie rośnie) wykonuje się dopiero po merge'u i na wyraźne polecenie użytkownika. Przed wdrożeniem posprzątać zdublowane `DJANGO_BPP_DB_*` w `.env` tamtej instalacji.

#!/usr/bin/env bash
# ============================================================================
# db-budget.sh — budzet polaczen z PostgreSQL: RAM bazy -> pula -> nginx
# ============================================================================
#   make db-budget            -> wypisuje caly lancuch (read-only)
#   (make up / refresh / up-quick przez ensure-config-files)
#   bash scripts/db-budget.sh --zapisz
#                             -> wpisuje BPP_BUDGET_* do $BPP_CONFIGS_DIR/.env
#
# PO CO: limity byly niezalezne (pula pgbouncera 80, nginx 60 naraz). Gdy
# baza ma male max_connections, pgbouncer przycina pule (np. do 20), a nginx
# dalej wpuszcza 60 zadan naraz — 40 czeka w kolejce pgbouncera do 15 s
# (query_wait_timeout) i konczy sie timeoutem/500 zamiast szybkim 429.
# Budzet liczy wszystkie ogniwa z jednego zrodla:
#
#   max_connections = autotune(RAM bazy)            (dbserver/autotune.sh)
#   rezerwa         = max(40, 20 + 3/4 x rdzenie)   (jak pgbouncer/entrypoint.sh)
#   pula            = min(PGBOUNCER_POOL_SIZE|80, max(10, max_connections - rezerwa))
#   nginx naraz     = min(BPP_NGINX_GLOBAL_CONN|60, pula)
#
# RAM bazy: tryb lokalny — DBSERVER_MEM_LIMIT x POSTGRESQL_RAM_PERCENT (jak
# autotune w kontenerze; POSTGRESQL_RAM_THIS_MUCH_GB wygrywa), tryb external —
# BPP_DB_RAM (opcjonalna; bez niej budzetu nie liczymy i zostaja domyslne).
#
# Budzet tylko OBNIZA domyslne — nigdy nie podnosi puli ani limitu nginx.
# Jawne PGBOUNCER_POOL_SIZE / BPP_NGINX_GLOBAL_CONN w .env WYGRYWAJA (budzet
# tylko ostrzega, gdy je przekraczaja). pgbouncer przy starcie i tak przycina
# pule do PRAWDZIWEGO max_connections (siatka bezpieczenstwa dla bazy
# zewnetrznej z innym max_connections niz wynika z RAM).
#
# --zapisz jest fail-open: zaden blad nie zatrzymuje `make up` (exit 0).
#
# Hooki testowe: BPP_BUDGET_NPROC (rdzenie), BPP_REPO_ENV (repo-lokalny .env).
# ============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AUTOTUNE="$REPO_DIR/dbserver/autotune.sh"
ENV_FILE="${BPP_CONFIGS_DIR:-}/.env"
REPO_ENV="${BPP_REPO_ENV:-$REPO_DIR/.env}"

TRYB="pokaz"
[ "${1:-}" = "--zapisz" ] && TRYB="zapisz"

DOMYSLNA_PULA=80          # pgbouncer/entrypoint.sh
DOMYSLNY_NGINX_CONN=60    # defaults/webserver/25-render-bpp-limits.sh

koniec_bledem() {
    if [ "$TRYB" = "zapisz" ]; then
        echo "  budzet polaczen: pominiety ($1)" >&2
        exit 0
    fi
    echo "BLAD: $1" >&2
    exit 1
}

[ -n "${BPP_CONFIGS_DIR:-}" ] && [ -f "$ENV_FILE" ] \
    || koniec_bledem "brak $ENV_FILE (BPP_CONFIGS_DIR)"

# get VAR [PLIK] — ostatnia wartosc z .env, bez \r i bialych znakow z brzegow
get() {
    grep -E "^$1=" "${2:-$ENV_FILE}" 2>/dev/null | tail -1 | cut -d= -f2- \
        | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true
}

# liczba nieujemna albo pusto (jak liczba_lub_domyslna w kontenerach)
liczba() {
    case "$1" in ''|*[!0-9]*) return 0 ;; esac
    echo $((10#$1))
}

# Docker-owy zapis pamieci (2g, 1536m, 512M, 4GB; gola liczba = bajty) -> MB
mem_to_mb() {
    printf '%s' "$1" | LC_ALL=C awk '
        match(tolower($0), /^[0-9]+(\.[0-9]+)?(b|k|kb|m|mb|g|gb)?$/) {
            v = $0 + 0; u = tolower($0); sub(/^[0-9.]+/, "", u)
            if (u == "" || u == "b") v = v / 1048576
            else if (u ~ /^k/) v = v / 1024
            else if (u ~ /^g/) v = v * 1024
            printf "%d", v; ok = 1
        }
        END { exit ok ? 0 : 1 }'
}

# BPP_DB_RAM jak w make db-autotune-external: 16G, 16 (= GB), 512M
ram_to_mb() {
    local v
    v="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"; v="${v%B}"
    case "$v" in
        *[!0-9GMT]*|'') return 1 ;;
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

# max_connections z autotune'a dla RAM (MB) — te same wzory co baza w Dockerze
maxc_z_ram() {
    POSTGRESQL_RAM_THIS_MUCH_GB="$1" POSTGRESQL_NPROC=1 POSTGRESQL_UNSAFE_BUT_FAST='' \
        sh "$AUTOTUNE" 2>/dev/null | sed -n 's/^max_connections = //p'
}

# --- RAM bazy ------------------------------------------------------------------
EXTERNAL=0
[ "$(get BPP_DATABASE_COMPOSE "$REPO_ENV")" = "docker-compose.database.external.yml" ] && EXTERNAL=1

RAM_MB=""
RAM_ZRODLO=""
if [ "$EXTERNAL" -eq 1 ]; then
    _r="$(get BPP_DB_RAM)"
    if [ -n "$_r" ]; then
        if RAM_MB="$(ram_to_mb "$_r")"; then
            RAM_ZRODLO="BPP_DB_RAM=$_r"
        else
            RAM_MB=""
            echo "OSTRZEZENIE: BPP_DB_RAM='$_r' — podaj np. 16G albo 512M; budzet pominiety." >&2
        fi
    fi
else
    _force="$(liczba "$(get POSTGRESQL_RAM_THIS_MUCH_GB)")"
    if [ -n "$_force" ] && [ "$_force" -gt 0 ]; then
        RAM_MB="$_force"   # sic: autotune traktuje te wartosc jako MB
        RAM_ZRODLO="POSTGRESQL_RAM_THIS_MUCH_GB=$_force (MB)"
    else
        _lim="$(get DBSERVER_MEM_LIMIT)"; _lim="${_lim:-2g}"   # compose: ${DBSERVER_MEM_LIMIT:-2g}
        _pct="$(get POSTGRESQL_RAM_PERCENT)"; _pct="${_pct:-0.95}"
        if _lim_mb="$(mem_to_mb "$_lim")"; then
            RAM_MB="$(LC_ALL=C awk -v m="$_lim_mb" -v p="$_pct" 'BEGIN { printf "%d", m * p }')"
            RAM_ZRODLO="DBSERVER_MEM_LIMIT=$_lim x $_pct"
        fi
    fi
fi

MAXC=""
[ -n "$RAM_MB" ] && [ "$RAM_MB" -gt 0 ] && MAXC="$(maxc_z_ram "$RAM_MB")"

# --- rezerwa, pula, nginx --------------------------------------------------------
RDZENIE="$(liczba "${BPP_BUDGET_NPROC:-}")"
[ -n "$RDZENIE" ] || RDZENIE="$(nproc 2>/dev/null || echo 4)"
REZERWA=$(( 20 + (3 * RDZENIE + 3) / 4 ))
[ "$REZERWA" -ge 40 ] || REZERWA=40

JAWNA_PULA="$(liczba "$(get PGBOUNCER_POOL_SIZE)")"
JAWNY_CONN="$(liczba "$(get BPP_NGINX_GLOBAL_CONN)")"

BUDZET_PULA=""
BUDZET_CONN=""
if [ -n "$MAXC" ]; then
    _limit=$(( MAXC - REZERWA )); [ "$_limit" -ge 10 ] || _limit=10
    BUDZET_PULA=$DOMYSLNA_PULA
    [ "$_limit" -lt "$BUDZET_PULA" ] && BUDZET_PULA=$_limit
    BUDZET_CONN=$DOMYSLNY_NGINX_CONN
    [ "$BUDZET_PULA" -lt "$BUDZET_CONN" ] && BUDZET_CONN=$BUDZET_PULA
fi

# Co faktycznie zadziala (kolejnosc jak w kontenerach: jawna > budzet > domyslna)
EF_PULA="${JAWNA_PULA:-${BUDZET_PULA:-$DOMYSLNA_PULA}}"
[ "$EF_PULA" -ge 1 ] || EF_PULA=$DOMYSLNA_PULA
EF_CONN="${JAWNY_CONN:-${BUDZET_CONN:-$DOMYSLNY_NGINX_CONN}}"

OSTRZEZENIA=()
if [ -n "$BUDZET_PULA" ] && [ -n "$JAWNA_PULA" ] && [ "$JAWNA_PULA" -gt "$BUDZET_PULA" ]; then
    OSTRZEZENIA+=("PGBOUNCER_POOL_SIZE=$JAWNA_PULA przekracza budzet $BUDZET_PULA — pgbouncer przytnie pule przy starcie, jesli baza ma mniej max_connections.")
fi
if [ "$EF_CONN" -gt 0 ] && [ "$EF_CONN" -gt "$EF_PULA" ]; then
    OSTRZEZENIA+=("nginx wpuszcza $EF_CONN zadan naraz, a pula ma $EF_PULA polaczen — nadmiar czeka w pgbouncerze do 15 s zamiast dostac 429. Usun BPP_NGINX_GLOBAL_CONN z .env albo ustaw <= $EF_PULA.")
fi

# --- --zapisz ------------------------------------------------------------------------
if [ "$TRYB" = "zapisz" ]; then
    # Zapis przez `cat >` (nie mv): zostaje tryb i wlasciciel .env.
    _ustaw() {  # VAR WARTOSC — pusta WARTOSC = usun linie
        local tmp="$ENV_FILE.budzet.$$"
        if [ -z "$2" ]; then
            grep -q "^$1=" "$ENV_FILE" || return 0
            awk -v k="$1" 'BEGIN { FS="=" } $1 != k { print }' "$ENV_FILE" > "$tmp" \
                && cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"; ZMIENIONO=1; return 0
        fi
        [ "$(get "$1")" = "$2" ] && return 0
        if grep -q "^$1=" "$ENV_FILE"; then
            awk -v k="$1" -v v="$2" 'BEGIN { FS=OFS="=" } $1 == k { print k "=" v; next } { print }' \
                "$ENV_FILE" > "$tmp" && cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
        else
            if ! grep -q "^# === Budzet polaczen" "$ENV_FILE"; then
                {
                    echo ""
                    echo "# === Budzet polaczen (make up liczy sam — NIE EDYTUJ; make db-budget) ==="
                    echo "# Nadpisanie: PGBOUNCER_POOL_SIZE / BPP_NGINX_GLOBAL_CONN. Baza zewnetrzna: BPP_DB_RAM."
                } >> "$ENV_FILE"
            fi
            echo "$1=$2" >> "$ENV_FILE"
        fi
        ZMIENIONO=1
    }
    ZMIENIONO=0
    _ustaw BPP_BUDGET_POOL "$BUDZET_PULA" || true
    _ustaw BPP_BUDGET_NGINX_CONN "$BUDZET_CONN" || true
    if [ "$ZMIENIONO" -eq 1 ]; then
        if [ -n "$BUDZET_PULA" ]; then
            echo "  budzet polaczen: max_connections $MAXC -> pula $BUDZET_PULA, nginx $BUDZET_CONN naraz (make db-budget)"
        else
            echo "  budzet polaczen: wylaczony (brak RAM bazy) — domyslne pula $DOMYSLNA_PULA, nginx $DOMYSLNY_NGINX_CONN"
        fi
    fi
    for o in "${OSTRZEZENIA[@]+"${OSTRZEZENIA[@]}"}"; do echo "  OSTRZEZENIE: $o" >&2; done
    exit 0
fi

# --- pokaz ------------------------------------------------------------------------------
if [ "$EXTERNAL" -eq 1 ]; then TRYB_BAZY="zewnetrzna"; else TRYB_BAZY="w Dockerze"; fi
echo "Budzet polaczen z PostgreSQL (baza $TRYB_BAZY)"
echo
if [ -n "$MAXC" ]; then
    printf '  %-26s %s\n' "RAM bazy" "$RAM_MB MB  ($RAM_ZRODLO)"
    printf '  %-26s %s\n' "max_connections (autotune)" "$MAXC"
else
    printf '  %-26s %s\n' "RAM bazy" "nieznany"
    if [ "$EXTERNAL" -eq 1 ]; then
        echo
        echo "  Dopisz do $ENV_FILE RAM serwera bazy, np. BPP_DB_RAM=16G,"
        echo "  i zrob make up. Do tego czasu obowiazuja domyslne limity, a pgbouncer"
        echo "  przycina pule tylko do max_connections odczytanego z bazy."
    fi
fi
printf '  %-26s %s\n' "rezerwa (bezposrednie)" "$REZERWA  (Celery, denorm, beat, authserver, monitoring, superuser; $RDZENIE rdzeni)"
_opis() {  # jawna budzet
    if [ -n "$1" ]; then echo "jawnie w .env"; elif [ -n "$2" ]; then echo "z budzetu"; else echo "domyslna"; fi
}
printf '  %-26s %s\n' "pula pgbouncera" "$EF_PULA  ($(_opis "$JAWNA_PULA" "$BUDZET_PULA"))"
if [ "$EF_CONN" -eq 0 ]; then
    printf '  %-26s %s\n' "nginx: zadan naraz" "wylaczone (BPP_NGINX_GLOBAL_CONN=0)"
else
    printf '  %-26s %s\n' "nginx: zadan naraz" "$EF_CONN  ($(_opis "$JAWNY_CONN" "$BUDZET_CONN")) — ponad to 429"
fi
echo
echo "  Wartosci z budzetu wchodza przy make up (pgbouncer i webserver sa"
echo "  odtwarzane). Stan na zywo: make db-connection-stats, make pgbouncer-stats."
for o in "${OSTRZEZENIA[@]+"${OSTRZEZENIA[@]}"}"; do echo; echo "  OSTRZEZENIE: $o"; done
exit 0

#!/usr/bin/env bash
#
# Idempotentne, non-interactive upewnienie sie, ze wszystkie pliki konfiguracyjne
# wymagane przez docker-compose (bind-mounty z $BPP_CONFIGS_DIR) istnieja.
#
# Wywolywane:
#   - przez Makefile targets up / up-quick / refresh jako prerequisit,
#     zeby `git pull && make up` zadzialal nawet jesli nowy release dodal
#     kolejny bind-mount (regresja typu: brakujacy plik -> Docker auto-tworzy
#     pusty katalog w jego miejscu -> runc wywala sie przy tworzeniu mountpointu).
#   - przez scripts/init-configs.sh jako podfragment pierwszej inicjalizacji.
#
# Non-interactive z zalozenia: nie pyta usera o nic, tylko dokopiowuje brakujace
# pliki z defaults/ (copy_if_missing). Nie nadpisuje istniejacych, nie modyfikuje
# .env. Zmiany w .env (nowe zmienne, migracje) to rola init-configs.sh, ktora
# user musi swiadomie wywolac.

set -euo pipefail

: "${BPP_CONFIGS_DIR:?BPP_CONFIGS_DIR nie jest ustawione. Uruchom: make init-configs}"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULTS_DIR="$REPO_DIR/defaults"

if [ ! -d "$BPP_CONFIGS_DIR" ]; then
    echo "BLAD: katalog konfiguracyjny nie istnieje: $BPP_CONFIGS_DIR" >&2
    echo "      Uruchom: make init-configs" >&2
    exit 1
fi

mkdir -p "$BPP_CONFIGS_DIR/ssl"
# Let's Encrypt: certyfikaty wystawiane przez certbot (mountowane RW przez
# webserver dla sentinela .reload-needed). Tworzymy pusty katalog niezaleznie
# od DJANGO_BPP_SSL_MODE, zeby bind-mount na webserverze nie wykreowal
# pustego katalogu / nie wywalil sie przy starcie.
mkdir -p "$BPP_CONFIGS_DIR/letsencrypt"
mkdir -p "$BPP_CONFIGS_DIR/rclone"
mkdir -p "$BPP_CONFIGS_DIR/alloy"
mkdir -p "$BPP_CONFIGS_DIR/loki"
mkdir -p "$BPP_CONFIGS_DIR/grafana/provisioning/datasources"
mkdir -p "$BPP_CONFIGS_DIR/grafana/provisioning/dashboards"
mkdir -p "$BPP_CONFIGS_DIR/netdata/go.d"
mkdir -p "$BPP_CONFIGS_DIR/netdata/health.d"

# Kopiuje plik tylko jesli nie istnieje. Obsluguje edge-case, gdy Docker
# przy bind-moucie nieistniejacej sciezki hosta utworzyl w tym miejscu pusty
# katalog (bo domyslnie zaklada bind dla katalogu) - wtedy probuje go usunac
# zanim wrzuci plik. Jesli katalog nie jest pusty, odmawia i wymaga recznej
# interwencji zeby nie usunac przypadkiem cudzych danych.
copy_if_missing() {
    local src="$1" dest="$2"

    if [ -d "$dest" ] && ! [ -f "$dest" ]; then
        if ! rmdir "$dest" 2>/dev/null; then
            echo "BLAD: $dest istnieje jako niepusty katalog (spodziewany plik)." >&2
            echo "      Sprawdz recznie - moze to pozostalosc po poprzedniej konfiguracji." >&2
            return 1
        fi
        echo "  ~ usunieto pusty katalog (auto-utworzony przez Docker): $dest"
    fi

    if [ ! -f "$dest" ]; then
        cp "$src" "$dest"
        echo "  + dokopiowano z defaults/: $dest"
    fi
}

# Nadpisuje plik ZAWSZE, jesli rozni sie od wersji w defaults/. Dla wersjonowanych
# artefaktow, ktorych user NIE edytuje recznie - np. provisioned dashboardy Grafany
# (i tak read-only w UI). Bez tego zaktualizowany dashboard nigdy by nie trafil na
# zywy deployment przez make up/refresh/run (copy_if_missing pomijaloby istniejacy).
# cmp: kopiujemy tylko realne zmiany, zeby nie smiecic logiem przy kazdym uruchomieniu.
copy_always() {
    local src="$1" dest="$2"

    if [ -d "$dest" ] && ! [ -f "$dest" ]; then
        if ! rmdir "$dest" 2>/dev/null; then
            echo "BLAD: $dest istnieje jako niepusty katalog (spodziewany plik)." >&2
            return 1
        fi
    fi

    if ! cmp -s "$src" "$dest" 2>/dev/null; then
        cp "$src" "$dest"
        echo "  ~ zsynchronizowano z defaults/ (overwrite): $dest"
    fi
}

copy_if_missing "$DEFAULTS_DIR/alloy/config.alloy" "$BPP_CONFIGS_DIR/alloy/config.alloy"
copy_if_missing "$DEFAULTS_DIR/loki/local-config.yaml" "$BPP_CONFIGS_DIR/loki/local-config.yaml"

while IFS= read -r -d '' f; do
    rel="${f#"$DEFAULTS_DIR/grafana/provisioning/"}"
    dest="$BPP_CONFIGS_DIR/grafana/provisioning/$rel"
    case "$rel" in
        # Dashboardy: shipped, read-only w UI -> zawsze swieze z repo.
        dashboards/*) copy_always "$f" "$dest" ;;
        # Szablon datasource'ow tez force-sync: to shipped artefakt (definicje
        # Loki/PostgreSQL + cleanup martwego Prometheusa), renderowany potem
        # przez generate-grafana-datasources. Bez tego upgrade trzymalby stary
        # .tpl (copy_if_missing nie nadpisuje) i np. zmiana na read-only role
        # bpp_monitor nigdy by nie zadzialala na istniejacych wdrozeniach.
        datasources/datasources.yaml.tpl) copy_always "$f" "$dest" ;;
        # Reszta (configi tuningowane recznie) -> tylko gdy brak.
        *)            copy_if_missing "$f" "$dest" ;;
    esac
done < <(find "$DEFAULTS_DIR/grafana/provisioning" -type f -print0)

# Netdata configi (rekursywnie, copy_if_missing). .gitkeep wykluczone -
# jest tylko po to zeby pusty health.d/ trafil do gita.
while IFS= read -r -d '' f; do
    rel="${f#"$DEFAULTS_DIR/netdata/"}"
    dest="$BPP_CONFIGS_DIR/netdata/$rel"
    mkdir -p "$(dirname "$dest")"
    copy_if_missing "$f" "$dest"
done < <(find "$DEFAULTS_DIR/netdata" -type f -not -name '.gitkeep' -not -name '*.tpl' -print0)

# Render defaults/netdata/go.d/postgres.conf.tpl -> $BPP_CONFIGS_DIR/...
# go.d.plugin nie expanduje ${VAR} w DSN, wiec rendujemy host-side.
# Read values directly from .env via grep (source-as-bash pada na
# niestandardowych wartosciach typu EMAIL='Name <addr@domain>').
_ENV="$BPP_CONFIGS_DIR/.env"

# Self-heal sekretow wymaganych przez configi monitoringu. Append-only:
# NIGDY nie nadpisujemy istniejacych wartosci (zachowujemy to co ustawil
# init-configs/user), dopisujemy tylko brakujace. Dzieki temu `git pull &&
# make up` na starym .env (bez tych zmiennych) dziala bez recznych krokow -
# zgodnie z regula kompatybilnosci wstecznej (patrz CLAUDE.md).
if [ -f "$_ENV" ]; then
    _ensure_secret() {
        # $1 = nazwa zmiennej, $2 = wartosc generowana gdy brak LUB pusta.
        # Niepusta wartosc (VAR=cos) -> nic nie robimy. Pusta linia (VAR=)
        # traktujemy jak brak, bo inaczej create-monitoring-user / ntfy
        # dostaja pusty sekret; grep "^VAR=" lapal tez taki przypadek i nigdy
        # nie regenerowal. Wymagamy >=1 znaku po '=' (.+).
        if grep -qE "^${1}=.+" "$_ENV" 2>/dev/null; then
            return 0
        fi
        # Usun ewentualna pusta linie 'VAR=' zanim dopiszemy nowa - bez tego
        # zostawilibysmy duplikat klucza (VAR= oraz VAR=wartosc).
        if grep -qE "^${1}=$" "$_ENV" 2>/dev/null; then
            local _t="$_ENV.tmp.$$"
            grep -vE "^${1}=$" "$_ENV" > "$_t" && mv "$_t" "$_ENV"
        fi
        # Zapewnij trailing newline zanim dopiszemy - recznie edytowany .env
        # bez konca-linii inaczej sklei nowa zmienna z ostatnia linia.
        # $(tail -c1) gubi trailing \n: pusty => ostatni bajt to newline.
        if [ -s "$_ENV" ] && [ -n "$(tail -c1 "$_ENV")" ]; then
            printf '\n' >> "$_ENV"
        fi
        printf '%s=%s\n' "$1" "$2" >> "$_ENV"
        echo "  + wygenerowano brakujacy sekret w .env: $1"
    }
    # Haslo read-only roli monitoringu (Grafana datasource + Netdata postgres).
    # openssl rand -hex => tylko [0-9a-f]; create-monitoring-user.sh dodatkowo
    # waliduje alfanumerycznosc (haslo trafia do literalu SQL).
    _ensure_secret DJANGO_BPP_PG_MONITOR_PASSWORD "$(openssl rand -hex 24)"
    # Topic ntfy (sekret chroniacy kanal alertow) - gdy stary .env go nie ma.
    _ensure_secret NTFY_TOPIC "bpp-$(openssl rand -hex 16)"
fi

if [ -f "$_ENV" ] && [ -f "$DEFAULTS_DIR/netdata/go.d/postgres.conf.tpl" ]; then
    _get() {
        local raw
        raw="$(grep -E "^${1}=" "$_ENV" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
        if [ "${raw#\"}" != "$raw" ] && [ "${raw%\"}" != "$raw" ]; then
            raw="${raw#\"}"; raw="${raw%\"}"
        fi
        if [ "${raw#\'}" != "$raw" ] && [ "${raw%\'}" != "$raw" ]; then
            raw="${raw#\'}"; raw="${raw%\'}"
        fi
        printf '%s' "$raw"
    }
    # DSN dla kolektora postgres laczy sie jako read-only bpp_monitor (NIE
    # uzytkownik aplikacji) - user wpisany na sztywno w .tpl, tu tylko haslo.
    _PG_MON_PASSWORD="$(_get DJANGO_BPP_PG_MONITOR_PASSWORD)"
    _PG_HOST="$(_get DJANGO_BPP_DB_HOST)"
    _PG_PORT="$(_get DJANGO_BPP_DB_PORT)"
    _PG_DB="$(_get DJANGO_BPP_DB_NAME)"
    # Port domyslny 5432 gdy .env go nie ma - inaczej DSN renderuje sie jako
    # '...@host:/db' (pusty port) i kolektor postgres netdaty nie laczy sie.
    [ -n "$_PG_PORT" ] || _PG_PORT="5432"

    if [ -n "$_PG_MON_PASSWORD" ] && [ -n "$_PG_HOST" ] && [ -n "$_PG_DB" ]; then
        # sed-escape replacementu: backslash MUSI byc pierwszy (inaczej kolejne
        # podstawienia podwajaja juz wstawione backslashe), dopiero potem / i &.
        _esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/[\/&]/\\&/g'; }
        _dest="$BPP_CONFIGS_DIR/netdata/go.d/postgres.conf"
        # Render do pliku tymczasowego, chmod 600 PRZED podmiana, potem atomowy
        # mv: DSN zawiera haslo (nie moze byc world-readable), a crash w trakcie
        # nie zostawia obcietego/pustego configu.
        _tmp="${_dest}.tmp.$$"
        sed \
            -e "s/__PG_MON_PASSWORD__/$(_esc "$_PG_MON_PASSWORD")/g" \
            -e "s/__PG_HOST__/$(_esc "$_PG_HOST")/g" \
            -e "s/__PG_PORT__/$(_esc "$_PG_PORT")/g" \
            -e "s/__PG_DB__/$(_esc "$_PG_DB")/g" \
            "$DEFAULTS_DIR/netdata/go.d/postgres.conf.tpl" > "$_tmp"
        chmod 600 "$_tmp"
        mv "$_tmp" "$_dest"
        echo "  ~ wyrenderowano: $_dest"
    elif [ -f "$BPP_CONFIGS_DIR/netdata/go.d/postgres.conf" ]; then
        # Nie udalo sie wyrenderowac (brak hasla/hosta/bazy w .env), a STARY plik
        # juz istnieje - moze pochodzic sprzed migracji na bpp_monitor (DSN z
        # superuserem aplikacji). Ostrzegamy glosno, zeby nie zostawic po cichu
        # kolektora netdaty laczacego sie pelnoprawnym kontem aplikacji.
        echo "  ! UWAGA: pominieto render netdata/go.d/postgres.conf - brak" >&2
        echo "    DJANGO_BPP_PG_MONITOR_PASSWORD / DJANGO_BPP_DB_HOST / DJANGO_BPP_DB_NAME" >&2
        echo "    w .env. Istniejacy plik moze uzywac STAREGO DSN (superuser aplikacji)." >&2
        echo "    Uzupelnij .env i ponow: make ensure-config-files (lub make refresh)." >&2
    fi
fi

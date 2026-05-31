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

copy_if_missing "$DEFAULTS_DIR/alloy/config.alloy" "$BPP_CONFIGS_DIR/alloy/config.alloy"
copy_if_missing "$DEFAULTS_DIR/loki/local-config.yaml" "$BPP_CONFIGS_DIR/loki/local-config.yaml"

while IFS= read -r -d '' f; do
    rel="${f#"$DEFAULTS_DIR/grafana/provisioning/"}"
    dest="$BPP_CONFIGS_DIR/grafana/provisioning/$rel"
    copy_if_missing "$f" "$dest"
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
    _PG_USER="$(_get DJANGO_BPP_DB_USER)"
    _PG_PASSWORD="$(_get DJANGO_BPP_DB_PASSWORD)"
    _PG_HOST="$(_get DJANGO_BPP_DB_HOST)"
    _PG_PORT="$(_get DJANGO_BPP_DB_PORT)"
    _PG_DB="$(_get DJANGO_BPP_DB_NAME)"

    if [ -n "$_PG_USER" ] && [ -n "$_PG_HOST" ] && [ -n "$_PG_DB" ]; then
        # sed escaping: password moze zawierac /, &, .
        _esc() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }
        _dest="$BPP_CONFIGS_DIR/netdata/go.d/postgres.conf"
        sed \
            -e "s/__PG_USER__/$(_esc "$_PG_USER")/g" \
            -e "s/__PG_PASSWORD__/$(_esc "$_PG_PASSWORD")/g" \
            -e "s/__PG_HOST__/$(_esc "$_PG_HOST")/g" \
            -e "s/__PG_PORT__/$(_esc "$_PG_PORT")/g" \
            -e "s/__PG_DB__/$(_esc "$_PG_DB")/g" \
            "$DEFAULTS_DIR/netdata/go.d/postgres.conf.tpl" > "$_dest"
        echo "  ~ wyrenderowano: $_dest"
    fi
fi

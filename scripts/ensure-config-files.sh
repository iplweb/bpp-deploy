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
mkdir -p "$BPP_CONFIGS_DIR/rclone"
mkdir -p "$BPP_CONFIGS_DIR/alloy"
mkdir -p "$BPP_CONFIGS_DIR/loki"
mkdir -p "$BPP_CONFIGS_DIR/prometheus"
mkdir -p "$BPP_CONFIGS_DIR/rabbitmq"
mkdir -p "$BPP_CONFIGS_DIR/grafana/provisioning/datasources"
mkdir -p "$BPP_CONFIGS_DIR/grafana/provisioning/dashboards"

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
copy_if_missing "$DEFAULTS_DIR/prometheus/prometheus.yml" "$BPP_CONFIGS_DIR/prometheus/prometheus.yml"
copy_if_missing "$DEFAULTS_DIR/rabbitmq/enabled_plugins" "$BPP_CONFIGS_DIR/rabbitmq/enabled_plugins"

while IFS= read -r -d '' f; do
    rel="${f#"$DEFAULTS_DIR/grafana/provisioning/"}"
    dest="$BPP_CONFIGS_DIR/grafana/provisioning/$rel"
    copy_if_missing "$f" "$dest"
done < <(find "$DEFAULTS_DIR/grafana/provisioning" -type f -print0)

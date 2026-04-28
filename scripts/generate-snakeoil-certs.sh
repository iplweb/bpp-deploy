#!/usr/bin/env bash
# Generowanie samopodpisanych certyfikatow SSL dla deploymentu BPP.
#
# Uzycie:
#   scripts/generate-snakeoil-certs.sh <BPP_CONFIGS_DIR> [--force]
#
# Tryby:
#   1) Multi-host: DJANGO_BPP_HOSTNAMES="a.pl,b.pl,c.pl" w .env
#      Generuje per-host pary w <BPP_CONFIGS_DIR>/ssl/<host>/{cert,key}.pem.
#   2) Single-host (legacy): tylko DJANGO_BPP_HOSTNAME ustawione, brak HOSTNAMES.
#      Generuje pojedyncza pare <BPP_CONFIGS_DIR>/ssl/{cert,key}.pem (tak jak
#      historycznie). Entrypoint nginx-a uzyje jej jako fallback.
#
# Bez --force pomija hosty ktorych certyfikaty juz istnieja.

set -euo pipefail

if [ "${1:-}" = "" ]; then
    echo "Uzycie: $0 <BPP_CONFIGS_DIR> [--force]" >&2
    exit 2
fi

BPP_CONFIGS_DIR="$1"
FORCE=""
if [ "${2:-}" = "--force" ]; then
    FORCE=1
fi

ENV_FILE="$BPP_CONFIGS_DIR/.env"
SSL_DIR="$BPP_CONFIGS_DIR/ssl"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: $ENV_FILE nie istnieje. Uruchom 'make init-configs' najpierw." >&2
    exit 1
fi

mkdir -p "$SSL_DIR"

read_env() {
    grep "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true
}

HOSTNAMES_CSV="$(read_env DJANGO_BPP_HOSTNAMES)"
HOSTNAME_SINGLE="$(read_env DJANGO_BPP_HOSTNAME)"

# Parsuj CSV: przecinki i ewentualne spacje na separator, odfiltruj puste.
parse_hosts() {
    echo "$1" | tr ',' '\n' | tr -d ' \t' | awk 'NF > 0'
}

gen_cert() {
    # gen_cert <key_path> <cert_path> <hostname>
    local _key="$1"
    local _cert="$2"
    local _host="$3"
    mkdir -p "$(dirname "$_key")"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$_key" \
        -out "$_cert" \
        -subj "/CN=$_host" \
        -addext "subjectAltName=DNS:$_host" 2>/dev/null
    echo "  + $_cert (CN=$_host, 365 dni)"
}

# --- Tryb 1: multi-host (DJANGO_BPP_HOSTNAMES ustawione) ---
if [ -n "$HOSTNAMES_CSV" ]; then
    HOSTS="$(parse_hosts "$HOSTNAMES_CSV")"
    if [ -z "$HOSTS" ]; then
        echo "ERROR: DJANGO_BPP_HOSTNAMES ustawione, ale po sparsowaniu jest puste: '$HOSTNAMES_CSV'" >&2
        exit 1
    fi
    echo "Multi-host: znaleziono w DJANGO_BPP_HOSTNAMES:"
    # $HOSTS celowo unquoted - word splitting po newline rozbija na osobne argumenty.
    # shellcheck disable=SC2086
    printf '  - %s\n' $HOSTS
    echo ""

    while IFS= read -r host; do
        [ -z "$host" ] && continue
        host_dir="$SSL_DIR/$host"
        cert="$host_dir/cert.pem"
        key="$host_dir/key.pem"
        if [ -f "$cert" ] && [ -f "$key" ] && [ -z "$FORCE" ]; then
            echo "  = $host: certyfikat juz istnieje ($cert), pomijam (--force aby nadpisac)"
            continue
        fi
        gen_cert "$key" "$cert" "$host"
    done <<< "$HOSTS"
    exit 0
fi

# --- Tryb 2: legacy single-host (tylko DJANGO_BPP_HOSTNAME) ---
if [ -z "$HOSTNAME_SINGLE" ]; then
    echo "ERROR: ani DJANGO_BPP_HOSTNAMES, ani DJANGO_BPP_HOSTNAME nie sa ustawione w $ENV_FILE." >&2
    exit 1
fi

cert="$SSL_DIR/cert.pem"
key="$SSL_DIR/key.pem"
if [ -f "$cert" ] && [ -f "$key" ] && [ -z "$FORCE" ]; then
    echo "Certyfikaty SSL juz istnieja w $SSL_DIR/"
    echo "Uzyj 'make generate-snakeoil-certs-force' aby je nadpisac."
    exit 0
fi

echo "Single-host: generowanie certyfikatu dla $HOSTNAME_SINGLE"
gen_cert "$key" "$cert" "$HOSTNAME_SINGLE"

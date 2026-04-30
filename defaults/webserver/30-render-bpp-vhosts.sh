#!/bin/sh
# Generator per-host vhost-*.conf dla nginx-a w kontenerze webserver.
#
# Uruchamiany przez nginx entrypoint (/docker-entrypoint.sh) jako jeden z
# /docker-entrypoint.d/*.sh. Numer 30 - po wbudowanym 20-envsubst-on-templates.sh,
# zeby default.conf (globals) byl juz zrenderowany kiedy my dokladamy vhosty.
#
# Wejscie:
#   $DJANGO_BPP_HOSTNAMES  - CSV ("a.pl,b.pl,c.pl"). Preferowane.
#   $DJANGO_BPP_HOSTNAME   - single, fallback gdy HOSTNAMES puste.
#
# Wybor certyfikatu per host:
#
# DJANGO_BPP_SSL_MODE=letsencrypt:
#   1) /etc/letsencrypt/live/<host>/{fullchain,privkey}.pem (per-host LE cert)
#   2) /etc/letsencrypt/live/<canonical>/{fullchain,privkey}.pem (SAN — wszystkie
#      hosty wskazuja na cert wystawiony pod nazwa pierwszego hosta z listy)
#   3) /etc/ssl/private/<host>/{cert,key}.pem (manual per-host fallback - gdy LE
#      jeszcze nie wystawiony, zeby nginx wstal na snakeoil)
#   4) /etc/ssl/private/{cert,key}.pem (legacy single-pair fallback)
#
# DJANGO_BPP_SSL_MODE=manual (default):
#   1) /etc/ssl/private/<host>/{cert,key}.pem (per-host)
#   2) /etc/ssl/private/{cert,key}.pem (legacy fallback)
#
# Tryb manual zachowuje 100% zgodnosc dla dotychczasowych deploymentow,
# gdzie .env ma tylko DJANGO_BPP_HOSTNAME i ssl/{cert,key}.pem.

set -eu

ME="30-render-bpp-vhosts.sh"
TEMPLATE="/etc/nginx/bpp-templates/vhost.conf.template"
OUT_DIR="/etc/nginx/conf.d"
SSL_DIR="/etc/ssl/private"
LE_DIR="/etc/letsencrypt/live"
SSL_MODE="${DJANGO_BPP_SSL_MODE:-manual}"

log() {
    echo "$ME: $*"
}

err() {
    echo "$ME: ERROR: $*" >&2
}

if [ ! -f "$TEMPLATE" ]; then
    err "brak $TEMPLATE - sprawdz mounty docker-compose.infrastructure.yml"
    exit 1
fi

# Wyczysc poprzednie vhost-*.conf z konfiguracji - wazne przy `update-ssl-certs`
# albo restart-cie kiedy lista hostow w .env mogla sie zmienic. Inaczej zostalyby
# stare server bloki dla usunietych hostow.
rm -f "$OUT_DIR"/vhost-*.conf

# Lista hostow: preferuj HOSTNAMES, fallback do HOSTNAME. Przecinki -> nowe linie,
# wycinamy whitespace, pomijamy puste.
if [ -n "${DJANGO_BPP_HOSTNAMES:-}" ]; then
    HOSTS_RAW="$DJANGO_BPP_HOSTNAMES"
    log "uzywam DJANGO_BPP_HOSTNAMES: $HOSTS_RAW"
else
    HOSTS_RAW="${DJANGO_BPP_HOSTNAME:-}"
    log "uzywam DJANGO_BPP_HOSTNAME: $HOSTS_RAW (legacy single-host)"
fi

if [ -z "$HOSTS_RAW" ]; then
    err "ani DJANGO_BPP_HOSTNAMES, ani DJANGO_BPP_HOSTNAME nie sa ustawione"
    exit 1
fi

HOSTS=$(echo "$HOSTS_RAW" | tr ',' '\n' | tr -d ' \t\r' | awk 'NF > 0')

if [ -z "$HOSTS" ]; then
    err "lista hostow po sparsowaniu jest pusta: '$HOSTS_RAW'"
    exit 1
fi

# Canonical host (pierwszy z listy) — uzywany jako fallback dla SAN cert
# Let's Encrypt-a, gdzie wszystkie SAN-y dziela jeden plik fullchain.pem
# wystawiony pod nazwa pierwszego -d.
CANONICAL_HOST=$(echo "$HOSTS" | head -1)
log "ssl mode: $SSL_MODE (canonical host: $CANONICAL_HOST)"

ANY_RENDERED=0

# `for host in $(echo ...)` zamiast `while read`: dziala w `set -eu` bez
# subshella, ktory by zjadl ANY_RENDERED.
OLD_IFS="$IFS"
IFS='
'
for HOST in $HOSTS; do
    IFS="$OLD_IFS"
    [ -z "$HOST" ] && continue

    # Resolwer cert-path. Kolejnosc zalezy od DJANGO_BPP_SSL_MODE:
    # - letsencrypt: LE per-host -> LE canonical/SAN -> manual per-host -> manual legacy
    # - manual: manual per-host -> manual legacy
    VHOST_CERT_PATH=""
    VHOST_KEY_PATH=""
    CERT_KIND=""

    if [ "$SSL_MODE" = "letsencrypt" ]; then
        if [ -f "$LE_DIR/$HOST/fullchain.pem" ] && [ -f "$LE_DIR/$HOST/privkey.pem" ]; then
            VHOST_CERT_PATH="$LE_DIR/$HOST/fullchain.pem"
            VHOST_KEY_PATH="$LE_DIR/$HOST/privkey.pem"
            CERT_KIND="letsencrypt-per-host"
        elif [ -f "$LE_DIR/$CANONICAL_HOST/fullchain.pem" ] \
                && [ -f "$LE_DIR/$CANONICAL_HOST/privkey.pem" ]; then
            VHOST_CERT_PATH="$LE_DIR/$CANONICAL_HOST/fullchain.pem"
            VHOST_KEY_PATH="$LE_DIR/$CANONICAL_HOST/privkey.pem"
            CERT_KIND="letsencrypt-san"
        fi
    fi

    if [ -z "$VHOST_CERT_PATH" ]; then
        if [ -f "$SSL_DIR/$HOST/cert.pem" ] && [ -f "$SSL_DIR/$HOST/key.pem" ]; then
            VHOST_CERT_PATH="$SSL_DIR/$HOST/cert.pem"
            VHOST_KEY_PATH="$SSL_DIR/$HOST/key.pem"
            CERT_KIND="manual-per-host"
        elif [ -f "$SSL_DIR/cert.pem" ] && [ -f "$SSL_DIR/key.pem" ]; then
            VHOST_CERT_PATH="$SSL_DIR/cert.pem"
            VHOST_KEY_PATH="$SSL_DIR/key.pem"
            CERT_KIND="manual-legacy"
        fi
    fi

    if [ -z "$VHOST_CERT_PATH" ]; then
        err "brak certyfikatu dla $HOST (ssl_mode=$SSL_MODE). Sprawdzono:"
        if [ "$SSL_MODE" = "letsencrypt" ]; then
            err "    $LE_DIR/$HOST/fullchain.pem (per-host LE)"
            err "    $LE_DIR/$CANONICAL_HOST/fullchain.pem (SAN LE)"
        fi
        err "    $SSL_DIR/$HOST/cert.pem (per-host manual)"
        err "    $SSL_DIR/cert.pem (legacy manual fallback)"
        if [ "$SSL_MODE" = "letsencrypt" ]; then
            err "Wystaw cert: make ssl-letsencrypt-issue (staging) -> make ssl-letsencrypt-issue PROD=1"
        else
            err "Wygeneruj snakeoil: make generate-snakeoil-certs"
        fi
        exit 1
    fi

    VHOST_NAME="$HOST"
    export VHOST_NAME VHOST_CERT_PATH VHOST_KEY_PATH

    OUT="$OUT_DIR/vhost-$HOST.conf"
    # Single quotes na liscie zmiennych sa zamierzone - envsubst oczekuje literalu
    # '${NAME}', a nie rozwinietej wartosci.
    # shellcheck disable=SC2016
    envsubst '${VHOST_NAME} ${VHOST_CERT_PATH} ${VHOST_KEY_PATH}' < "$TEMPLATE" > "$OUT"
    log "vhost $HOST ($CERT_KIND): $OUT"
    ANY_RENDERED=$((ANY_RENDERED + 1))
    IFS='
'
done
IFS="$OLD_IFS"

if [ "$ANY_RENDERED" -eq 0 ]; then
    err "nie wygenerowano zadnego vhost-a"
    exit 1
fi

log "wygenerowano $ANY_RENDERED vhost(ow)"

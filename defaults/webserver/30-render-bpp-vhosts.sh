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
#   1) /etc/ssl/private/<host>/cert.pem + key.pem  (tryb multi-host)
#   2) /etc/ssl/private/cert.pem + key.pem         (legacy fallback - tylko
#                                                   gdy katalog per-host nie
#                                                   istnieje)
#
# Tryb legacy 2) zachowuje 100% zgodnosc dla dotychczasowych deploymentow,
# gdzie .env ma tylko DJANGO_BPP_HOSTNAME i ssl/{cert,key}.pem.

set -eu

ME="30-render-bpp-vhosts.sh"
TEMPLATE="/etc/nginx/bpp-templates/vhost.conf.template"
OUT_DIR="/etc/nginx/conf.d"
SSL_DIR="/etc/ssl/private"

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

ANY_RENDERED=0

# `for host in $(echo ...)` zamiast `while read`: dziala w `set -eu` bez
# subshella, ktory by zjadl ANY_RENDERED.
OLD_IFS="$IFS"
IFS='
'
for HOST in $HOSTS; do
    IFS="$OLD_IFS"
    [ -z "$HOST" ] && continue

    # Per-host cert ma priorytet, legacy single-pair jest fallbackiem.
    if [ -f "$SSL_DIR/$HOST/cert.pem" ] && [ -f "$SSL_DIR/$HOST/key.pem" ]; then
        VHOST_CERT_PATH="$SSL_DIR/$HOST/cert.pem"
        VHOST_KEY_PATH="$SSL_DIR/$HOST/key.pem"
        CERT_KIND="per-host"
    elif [ -f "$SSL_DIR/cert.pem" ] && [ -f "$SSL_DIR/key.pem" ]; then
        VHOST_CERT_PATH="$SSL_DIR/cert.pem"
        VHOST_KEY_PATH="$SSL_DIR/key.pem"
        CERT_KIND="legacy"
    else
        err "brak certyfikatu dla $HOST. Oczekiwane:"
        err "    $SSL_DIR/$HOST/cert.pem + $SSL_DIR/$HOST/key.pem (per-host)"
        err " lub $SSL_DIR/cert.pem + $SSL_DIR/key.pem (legacy fallback)"
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

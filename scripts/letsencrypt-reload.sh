#!/bin/sh
#
# Sprawdza sentinel /etc/letsencrypt/.reload-needed i reloaduje nginx jesli
# jest obecny. Wywolywane PRZEZ Ofelia (label ofelia.job-exec.letsencrypt_reload
# na webserverze, w docker-compose.infrastructure.yml). Sentinel tworzy certbot
# (deploy-hook po sukcesie renew/issue).
#
# Cichy no-op gdy brak sentinela - codzienny scheduler zostawia w logach minimum.

set -eu

SENTINEL="/etc/letsencrypt/.reload-needed"

if [ ! -f "$SENTINEL" ]; then
    exit 0
fi

echo "letsencrypt-reload: wykryto sentinel, reloaduje nginx..."

# Re-render vhosts. Wymagane przy pierwszym issue (gdy SSL_MODE byl juz
# ustawiony na letsencrypt, ale aktualne vhost-*.conf wskazywaly na manual
# fallback bo LE-cert jeszcze nie istnial). Idempotentny przy zwyklym renew.
if [ -x /docker-entrypoint.d/30-render-bpp-vhosts.sh ]; then
    /docker-entrypoint.d/30-render-bpp-vhosts.sh
fi

if ! nginx -t; then
    echo "letsencrypt-reload: BLAD: nginx -t nie przeszlo, pomijam reload" >&2
    echo "letsencrypt-reload: zostawiam sentinel - sprobuje ponownie przy nastepnym uruchomieniu" >&2
    exit 1
fi

nginx -s reload
echo "letsencrypt-reload: nginx zreloadowany"

rm -f "$SENTINEL"
echo "letsencrypt-reload: sentinel usuniety"

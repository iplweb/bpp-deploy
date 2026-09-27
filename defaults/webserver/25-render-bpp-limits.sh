#!/bin/sh
# ============================================================================
# GLOBALNY (AGREGATOWY) LIMIT RUCHU DO APPSERVERA
# ============================================================================
#
# Uruchamiany przez docker-entrypoint obrazu nginx (jak 30-render-bpp-vhosts.sh).
# Generuje dwa pliki:
#
#   /etc/nginx/conf.d/05-bpp-global-limits.conf   (kontekst http — strefy)
#   /etc/nginx/conf.d/bpp-global-limits.inc       (kontekst location — uzycie)
#
# Ten drugi ma rozszerzenie .inc CELOWO: nginx.conf includuje conf.d/*.conf
# w kontekscie http, a `limit_req`/`limit_conn` z burstem musza siedziec
# w locationach (/, /api/, /admin/ w _bpp-locations.conf).
#
# DLACZEGO SKRYPT, A NIE envsubst: _bpp-locations.conf nie jest renderowany
# wcale, a envsubst nie umie ani wartosci domyslnej, ani "0 = wylaczone",
# ani walidacji. Zla wartosc w .env nie moze polozyc calej strony, wiec
# smiec -> ostrzezenie + wartosc domyslna, a nie [emerg].
#
# Po co to jest: 2026-09-27 scraper z ~6800 adresow IP (1 zadanie na IP,
# osiem podrobionych UA Chrome) doszedl do ~2000 zadan/min. Limity per-IP nie
# mialy czego zlapac, appserver spietrzyl zadania ponad max_connections
# PostgreSQL i strona lezala ~3 minuty. Szczegoly:
# docs/architektura/rate-limiting.md#limit-globalny
#
# Zmienne (z $BPP_CONFIGS_DIR/.env przez env_file webservera):
#   BPP_NGINX_GLOBAL_RATE   zadan/s do appservera, lacznie ze wszystkich IP (20)
#   BPP_NGINX_GLOBAL_BURST  zapas na szpile ponad RATE, obslugiwany od reki (200)
#   BPP_NGINX_GLOBAL_CONN   zadan do appservera obslugiwanych naraz (60)
# Pusta/brak = domyslna, 0 = dany limit wylaczony.
# ============================================================================

set -eu

ME="25-render-bpp-limits.sh"
OUT_DIR="/etc/nginx/conf.d"
HTTP_CONF="$OUT_DIR/05-bpp-global-limits.conf"
LOC_INC="$OUT_DIR/bpp-global-limits.inc"

log() {
    echo "$ME: $*"
}

# liczba_lub_domyslna NAZWA DOMYSLNA -> wypisuje nieujemna liczbe calkowita
liczba_lub_domyslna() {
    _nazwa="$1"
    _domyslna="$2"
    eval "_wartosc=\${$_nazwa:-}"
    # shellcheck disable=SC2154  # ustawiana przez eval wyzej
    # tylko biale znaki z BRZEGOW (w tym \r z .env edytowanego na Windows);
    # "6 0" ma byc bledem, a nie po cichu 60
    _wartosc=$(printf '%s' "$_wartosc" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    if [ -z "$_wartosc" ]; then
        echo "$_domyslna"
        return
    fi
    case "$_wartosc" in
        *[!0-9]*)
            log "OSTRZEZENIE: $_nazwa='$_wartosc' nie jest liczba nieujemna — uzywam $_domyslna" >&2
            echo "$_domyslna"
            ;;
        *)
            # zera wiodace precz — "08" to dla arytmetyki sh liczba osemkowa
            # (blad), a "00" ma dalej znaczyc 0, czyli "wylaczone"
            printf '%s\n' "$_wartosc" | sed 's/^0*//; s/^$/0/'
            ;;
    esac
}

RATE=$(liczba_lub_domyslna BPP_NGINX_GLOBAL_RATE 20)
BURST=$(liczba_lub_domyslna BPP_NGINX_GLOBAL_BURST 200)
CONN=$(liczba_lub_domyslna BPP_NGINX_GLOBAL_CONN 60)

{
    echo "# Wygenerowane przez $ME — NIE EDYTOWAC, zmieniaj BPP_NGINX_GLOBAL_* w .env."
    # 429, nie domyslne 503: 503 wpadloby w `error_page 502 503 504
    # /maintenance.html` (dlawiony user widzialby "konserwacje") i odpalalo
    # alarm netdaty na 5xx. Ten sam powod co limit_req_status w
    # default.conf.template. `warn`, bo przy floodzie kazde odrzucenie na
    # poziomie `error` zalalo by dashboard error-monitoring.
    echo "limit_conn_status 429;"
    echo "limit_conn_log_level warn;"
    if [ "$RATE" -gt 0 ]; then
        # Klucz STALY ("bpp") = jeden wspolny kubelek dla wszystkich IP
        # i wszystkich vhostow (multi-host dzieli jednego appservera).
        echo "limit_req_zone bpp zone=bpp_global:1m rate=${RATE}r/s;"
    fi
    if [ "$CONN" -gt 0 ]; then
        # WebSockety (/asgi/notifications/) wisza godzinami — liczone zjadalyby
        # limit samym faktem, ze redaktorzy maja otwarte karty. Pusty klucz =
        # zadanie nie jest liczone (tak dziala limit_conn).
        # shellcheck disable=SC2016  # $http_upgrade to zmienna NGINKSA, nie sh
        echo 'map $http_upgrade $bpp_global_conn_key {'
        echo '    default "bpp";'
        echo '    ~.      "";'
        echo '}'
        # shellcheck disable=SC2016  # jw.
        echo 'limit_conn_zone $bpp_global_conn_key zone=bpp_global_conn:1m;'
    fi
} > "$HTTP_CONF"

{
    echo "# Wygenerowane przez $ME — NIE EDYTOWAC, zmieniaj BPP_NGINX_GLOBAL_* w .env."
    if [ "$RATE" -gt 0 ]; then
        echo "limit_req zone=bpp_global burst=${BURST} nodelay;"
    else
        echo "# BPP_NGINX_GLOBAL_RATE=0 — globalny limit zadan/s wylaczony"
    fi
    if [ "$CONN" -gt 0 ]; then
        echo "limit_conn bpp_global_conn ${CONN};"
    else
        echo "# BPP_NGINX_GLOBAL_CONN=0 — globalny limit rownoleglosci wylaczony"
    fi
} > "$LOC_INC"

if [ "$RATE" -gt 0 ]; then
    OPIS_RATE="${RATE} r/s (burst ${BURST})"
else
    OPIS_RATE="wylaczony"
fi
if [ "$CONN" -gt 0 ]; then
    OPIS_CONN="${CONN} naraz"
else
    OPIS_CONN="wylaczony"
fi
log "globalny limit do appservera: tempo $OPIS_RATE, rownoleglosc $OPIS_CONN"

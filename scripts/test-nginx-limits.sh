#!/usr/bin/env bash
# SC2016: skrypty dla `klient` sa w apostrofach CELOWO — $K/$U maja sie
#   rozwinac w kontenerze curla, nie tutaj.
# SC2015: `warunek && ok ... || zle ...` jest bezpieczne, bo `ok` zawsze
#   zwraca 0 — `zle` nie odpali sie po udanym `ok`.
# shellcheck disable=SC2016,SC2015
# Test GLOBALNEGO limitu ruchu do appservera (25-render-bpp-limits.sh).
#
# Stawia obraz produkcyjny (owasp/modsecurity-crs:nginx, nginx jako uid 101)
# z PRAWDZIWA konfiguracja z defaults/webserver/ przed atrapa appservera
# i sprawdza zachowanie, nie tekst konfiguracji:
#
#   - wartosci domyslne, smiec w .env i "0 = wylaczone" renderuja sie poprawnie
#     i nginx wstaje (smiec NIE moze polozyc strony),
#   - limit tempa jest GLOBALNY: drugi klient z INNEGO IP dostaje 429 po tym,
#     jak pierwszy wyczerpal pule — dokladnie to, czego per-IP nie umial przy
#     scraperze z ~6800 adresow (2026-09-27),
#   - limit rownoleglosci odrzuca nadmiar 429 (nie 503 -> strona "konserwacja"),
#     a WebSockety (Upgrade) sie do niego nie licza,
#   - /static/ zostaje poza limitem.
#
# Nie wymaga .env ani dzialajacej instalacji BPP — tylko dockera.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
W="$REPO_DIR/defaults/webserver"
PRZEBIEG="${LIMITS_TEST_SUFFIX:-$$}"
NET="bpp-limits-test-net-$PRZEBIEG"
BACK="bpp-limits-test-appserver-$PRZEBIEG"
FRONT="bpp-limits-test-webserver-$PRZEBIEG"
VOL="bpp-limits-test-log-$PRZEBIEG"
HOST_NAME="limits-test.example.org"
IMAGE="owasp/modsecurity-crs:nginx"
CURL_IMAGE="curlimages/curl:8.11.1"
TMP="$(mktemp -d)"

BLEDY=0
ok()   { echo "  OK    $*"; }
zle()  { echo "  BLAD  $*"; BLEDY=$((BLEDY + 1)); }

# shellcheck disable=SC2317,SC2329  # wolane przez `trap`
czysc() {
    [ "${LIMITS_TEST_KEEP:-0}" = 1 ] && { echo "LIMITS_TEST_KEEP=1 — zostaja $FRONT $BACK $NET $VOL"; return; }
    docker rm -f "$FRONT" "$BACK" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    docker volume rm "$VOL" >/dev/null 2>&1
    rm -rf "$TMP"
}
trap czysc EXIT

if ! docker info >/dev/null 2>&1; then
    echo "BLAD: docker niedostepny."
    exit 1
fi

echo "== przygotowanie =="
mkdir -p "$TMP"/{ssl,letsencrypt,certbot,static,media}
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$TMP/ssl/key.pem" -out "$TMP/ssl/cert.pem" \
    -subj "/CN=$HOST_NAME" >/dev/null 2>&1
echo "statyczny" > "$TMP/static/plik.txt"
# uid 101 musi przejsc przez katalogi i przeczytac klucz (patrz test-waf.sh)
chmod -R a+rX "$TMP"

# Atrapa appservera: /wolno trzyma zadanie 3 s (do testu rownoleglosci),
# reszta odpowiada od reki. Wielowatkowa — inaczej sama serializowalaby
# zadania i test rownoleglosci mierzylby atrape, nie nginksa.
cat > "$TMP/backend.py" <<'PY'
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/wolno"):
            time.sleep(3)
        body = b"pass\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
ThreadingHTTPServer(("0.0.0.0", 8000), H).serve_forever()
PY
chmod a+r "$TMP/backend.py"

docker network create "$NET" >/dev/null
docker run -d --name "$BACK" --network "$NET" --network-alias appserver \
    -v "$TMP/backend.py:/backend.py:ro" python:3-alpine python /backend.py >/dev/null \
    || { echo "BLAD: atrapa appservera nie wstala."; exit 1; }

# Wolumen NAZWANY jak na produkcji + chown jak webserver-init (patrz test-waf.sh).
docker volume create "$VOL" >/dev/null
docker run --rm --user 0:0 -v "$VOL:/var/log/nginx-shared" --entrypoint sh "$IMAGE" \
    -c 'chown -R nginx:nginx /var/log/nginx-shared' >/dev/null 2>&1

# start_webserver [-e VAR=wartosc ...] — stawia webserver z podanym srodowiskiem
# i czeka na /healthz. Zwraca 1, gdy nginx nie wstal.
start_webserver() {
    docker rm -f "$FRONT" >/dev/null 2>&1
    docker run -d --name "$FRONT" --network "$NET" --network-alias "$HOST_NAME" \
        -e DJANGO_BPP_HOSTNAMES="$HOST_NAME" \
        -e DJANGO_BPP_SSL_MODE=manual \
        -e MODSEC_RULE_ENGINE=On \
        -e BLOCKING_PARANOIA=1 \
        "$@" \
        -v "$TMP/ssl:/etc/ssl/private:ro" \
        -v "$TMP/letsencrypt:/etc/letsencrypt" \
        -v "$TMP/certbot:/var/www/certbot:ro" \
        -v "$TMP/static:/var/www/html/staticroot:ro" \
        -v "$TMP/media:/mediaroot" \
        -v "$VOL:/var/log/nginx-shared" \
        -v "$W/default.conf.template:/etc/nginx/templates/conf.d/default.conf.template:ro" \
        -v "$W/modsecurity-override.conf.template:/etc/nginx/templates/modsecurity.d/modsecurity-override.conf.template:ro" \
        -v "$W/00-log-format.conf:/etc/nginx/conf.d/00-log-format.conf:ro" \
        -v "$W/security-headers.conf:/etc/nginx/conf.d/security-headers.conf:ro" \
        -v "$W/_bpp-locations.conf:/etc/nginx/bpp-templates/_bpp-locations.conf:ro" \
        -v "$W/vhost.conf.template:/etc/nginx/bpp-templates/vhost.conf.template:ro" \
        -v "$W/30-render-bpp-vhosts.sh:/docker-entrypoint.d/30-render-bpp-vhosts.sh:ro" \
        -v "$W/25-render-bpp-limits.sh:/docker-entrypoint.d/25-render-bpp-limits.sh:ro" \
        "$IMAGE" >/dev/null || return 1
    for _ in $(seq 1 30); do
        if docker exec "$FRONT" curl -fs -o /dev/null http://127.0.0.1/healthz 2>/dev/null; then
            return 0
        fi
        if [ "$(docker inspect -f '{{.State.Running}}' "$FRONT" 2>/dev/null)" != "true" ]; then
            break
        fi
        sleep 1
    done
    docker logs "$FRONT" 2>&1 | grep -E "emerg|ERROR|OSTRZEZENIE" | head -5
    return 1
}

wygenerowany() {
    docker exec "$FRONT" cat /etc/nginx/conf.d/bpp-global-limits.inc /etc/nginx/conf.d/05-bpp-global-limits.conf
}

# klient NAZWA SKRYPT — uruchamia `sh -c SKRYPT` w osobnym kontenerze curla
# (= osobny adres IP w sieci testowej). W skrypcie dostepne $U (bazowy URL)
# i $K (wspolne flagi curla).
klient() {
    docker run --rm --network "$NET" --entrypoint sh \
        -e U="https://$HOST_NAME" \
        -e K="-sk -o /dev/null -w %{http_code}\n --max-time 15" \
        "$CURL_IMAGE" -c "$2"
}

policz() { tr ' ' '\n' | grep -c "^$1$"; }

echo "== 1. wartosci domyslne =="
if start_webserver; then
    ok "nginx wstal bez zmiennych BPP_NGINX_GLOBAL_*"
    G="$(wygenerowany)"
    grep -q "rate=20r/s" <<<"$G" && ok "tempo 20 r/s" || zle "brak rate=20r/s:\n$G"
    grep -q "limit_req zone=bpp_global burst=200 nodelay;" <<<"$G" && ok "burst 200" || zle "brak burst=200"
    grep -q "limit_conn bpp_global_conn 60;" <<<"$G" && ok "rownoleglosc 60" || zle "brak limit_conn 60"
    grep -q "limit_conn_status 429;" <<<"$G" && ok "limit_conn_status 429" || zle "brak limit_conn_status 429"
else
    zle "nginx nie wstal na wartosciach domyslnych"
fi

echo "== 2. smiec w .env nie kladzie strony =="
if start_webserver -e BPP_NGINX_GLOBAL_RATE=abc -e BPP_NGINX_GLOBAL_BURST=-5 -e BPP_NGINX_GLOBAL_CONN="6 0"; then
    ok "nginx wstal mimo blednych wartosci"
    G="$(wygenerowany)"
    grep -q "rate=20r/s" <<<"$G" && grep -q "burst=200" <<<"$G" && grep -q "limit_conn bpp_global_conn 60;" <<<"$G" \
        && ok "bledne wartosci zastapione domyslnymi" || zle "nie wrocono do domyslnych:\n$G"
    # Caly log najpierw do zmiennej: `docker logs | grep -q` pod pipefail
    # zglasza PORAZKE przy trafieniu (grep konczy wczesniej, producent dostaje
    # SIGPIPE) — ta sama pulapka co sonda w deploy-with-warning.
    LOG="$(docker logs "$FRONT" 2>&1)"
    grep -q "OSTRZEZENIE: BPP_NGINX_GLOBAL_RATE='abc'" <<<"$LOG" \
        && ok "ostrzezenie w logu kontenera" \
        || zle "brak ostrzezenia o BPP_NGINX_GLOBAL_RATE"
else
    zle "nginx NIE wstal na blednych wartosciach — literowka w .env polozylaby strone"
fi

echo "== 3. zero wylacza =="
if start_webserver -e BPP_NGINX_GLOBAL_RATE=0 -e BPP_NGINX_GLOBAL_CONN=00; then
    G="$(docker exec "$FRONT" cat /etc/nginx/conf.d/bpp-global-limits.inc)"
    if grep -qE "^[[:space:]]*limit_(req|conn) " <<<"$G"; then
        zle "przy 0 w include zostaly dyrektywy:\n$G"
    else
        ok "0 i 00 = brak dyrektyw globalnych"
    fi
    WYNIK="$(klient a 'for i in $(seq 1 30); do curl $K "$U/x"; done' | tr '\n' ' ')"
    [ "$(policz 200 <<<"$WYNIK")" -eq 30 ] && ok "30 szybkich zadan przeszlo" || zle "przy wylaczonych limitach: $WYNIK"
else
    zle "nginx nie wstal przy wartosciach 0"
fi

echo "== 4. limit tempa jest GLOBALNY (miedzy IP) =="
if start_webserver -e BPP_NGINX_GLOBAL_RATE=1 -e BPP_NGINX_GLOBAL_BURST=3 -e BPP_NGINX_GLOBAL_CONN=0; then
    A="$(klient a 'for i in $(seq 1 6); do curl $K "$U/x"; done' | tr '\n' ' ')"
    B="$(klient b 'curl $K "$U/x"' | tr '\n' ' ')"
    S="$(klient b 'curl $K "$U/static/plik.txt"' | tr '\n' ' ')"
    [ "$(policz 200 <<<"$A")" -le 4 ] && [ "$(policz 429 <<<"$A")" -ge 2 ] \
        && ok "klient A: nadmiar ponad burst dostal 429 ($A)" || zle "klient A: $A"
    [ "$(policz 429 <<<"$B")" -eq 1 ] \
        && ok "klient B z INNEGO IP dostal 429 — pula jest wspolna" \
        || zle "klient B dostal $B — limit dziala per-IP, a nie globalnie"
    [ "$(policz 200 <<<"$S")" -eq 1 ] \
        && ok "/static/ poza limitem" || zle "/static/ przy wyczerpanej puli: $S"
else
    zle "nginx nie wstal (test tempa)"
fi

echo "== 5. limit rownoleglosci, WebSockety poza nim =="
if start_webserver -e BPP_NGINX_GLOBAL_RATE=0 -e BPP_NGINX_GLOBAL_CONN=2; then
    R="$(klient a 'for i in 1 2 3 4 5; do curl $K "$U/wolno" & done; wait' | tr '\n' ' ')"
    [ "$(policz 200 <<<"$R")" -eq 2 ] && [ "$(policz 429 <<<"$R")" -eq 3 ] \
        && ok "5 naraz przy limicie 2: 2x200, 3x429 ($R)" || zle "5 naraz przy limicie 2: $R"
    WS="$(klient a 'for i in 1 2 3 4 5; do curl $K --http1.1 -H "Upgrade: websocket" -H "Connection: Upgrade" "$U/wolno" & done; wait' | tr '\n' ' ')"
    [ "$(policz 429 <<<"$WS")" -eq 0 ] \
        && ok "5 naraz z Upgrade: websocket — zaden nie odrzucony ($WS)" \
        || zle "WebSockety licza sie do limitu: $WS"
else
    zle "nginx nie wstal (test rownoleglosci)"
fi

echo
if [ "$BLEDY" -eq 0 ]; then
    echo "WYNIK: wszystko zgodne."
    exit 0
fi
echo "WYNIK: $BLEDY niezgodnosci."
exit 1

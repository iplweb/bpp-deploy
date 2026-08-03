#!/usr/bin/env bash
# Stack testowy WAF-a: sprawdza, czy ModSecurity + OWASP CRS faktycznie blokuje
# ataki i faktycznie przepuszcza legalny ruch BPP.
#
# Uruchamia dwa kontenery na wlasnej sieci:
#   - `appserver` — atrapa backendu, na kazde zadanie odpowiada 200 "pass",
#   - `webserver` — obraz CRS z PRAWDZIWA konfiguracja z defaults/webserver/.
#
# Potem strzela bateria zapytan, gdzie kazde ma z gory znany oczekiwany wynik:
#   BLOK  — polaczenie ma zostac zerwane bez odpowiedzi (nasze 444),
#   PASS  — zadanie ma dojsc do backendu i dostac 200 "pass".
#
# Payloady ataku to PRAWDZIWE proby z lipca 2026 (sqlmap przeciwko
# publikacje.up.lublin.pl), nie wymyslone przyklady.
#
# Nie dotyka niczego poza wlasna siecia i wlasnymi kontenerami. Nie wymaga
# .env ani dzialajacej instalacji BPP.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
W="$REPO_DIR/defaults/webserver"
NET="bpp-waf-test-net"
BACK="bpp-waf-test-appserver"
FRONT="bpp-waf-test-webserver"
PORT="${WAF_TEST_PORT:-18443}"
HOST_NAME="waf-test.example.org"
TMP="$(mktemp -d)"

# tryb silnika — domyslnie taki jak na produkcji; da sie przestawic na
# DetectionOnly, zeby zobaczyc co BY zostalo zablokowane
ENGINE="${MODSEC_RULE_ENGINE:-On}"

# shellcheck disable=SC2317  # wolane przez `trap`, shellcheck tego nie widzi
czysc() {
    docker rm -f "$FRONT" "$BACK" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    rm -rf "$TMP"
}
trap czysc EXIT

echo "== przygotowanie =="
mkdir -p "$TMP"/{ssl,letsencrypt,certbot,static,media,nginxlog,html}
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$TMP/ssl/key.pem" -out "$TMP/ssl/cert.pem" \
    -subj "/CN=$HOST_NAME" >/dev/null 2>&1

cat > "$TMP/backend.conf" <<'BACKEND'
server {
    listen 8000 default_server;
    location / {
        default_type text/plain;
        return 200 "pass\n";
    }
    # Strony do testowania regul WYCHODZACYCH (RESPONSE-95x), ktore skanuja
    # CIALO ODPOWIEDZI. Reszta atrapy zwraca "pass", czyli tresc, na ktorej
    # zadna z nich sie nie zapali.
    location /odpowiedz/ {
        alias /html/;
        default_type "text/html; charset=UTF-8";
    }
}
BACKEND

# Komunikat bledu PHP w ciele odpowiedzi — kanoniczny wyciek, ktory reguly
# wychodzace maja lapac. Sluzy za kontrole, ze inspekcja odpowiedzi w ogole
# dziala; bez niej wykluczenie 10004 nie mialoby czego wylaczac.
cat > "$TMP/html/wyciek-php.html" <<'WYCIEK'
<!DOCTYPE html><html><body>
Warning: mysql_connect(): Access denied for user 'root'@'localhost' in /var/www/index.php on line 12
</body></html>
WYCIEK

docker network create "$NET" >/dev/null 2>&1

# Atrapa backendu MUSI nazywac sie `appserver` — _bpp-locations.conf ma ten
# hostname zaszyty w proxy_pass.
docker run -d --name "$BACK" --network "$NET" --network-alias appserver \
    -v "$TMP/backend.conf:/etc/nginx/conf.d/default.conf:ro" \
    -v "$TMP/html:/html:ro" \
    nginx:1.30.2 >/dev/null

docker run -d --name "$FRONT" --network "$NET" -p "$PORT:443" \
    -e DJANGO_BPP_HOSTNAMES="$HOST_NAME" \
    -e DJANGO_BPP_SSL_MODE=manual \
    -e MODSEC_RULE_ENGINE="$ENGINE" \
    -e BLOCKING_PARANOIA=1 \
    -e MODSEC_AUDIT_ENGINE=RelevantOnly \
    -e MODSEC_AUDIT_LOG_FORMAT=JSON \
    -e MODSEC_AUDIT_LOG_PARTS=ABHZ \
    -e MODSEC_REQ_BODY_LIMIT=132120576 \
    -e MODSEC_REQ_BODY_NOFILES_LIMIT=4194304 \
    -v "$TMP/ssl:/etc/ssl/private:ro" \
    -v "$TMP/letsencrypt:/etc/letsencrypt" \
    -v "$TMP/certbot:/var/www/certbot:ro" \
    -v "$TMP/static:/var/www/html/staticroot" \
    -v "$TMP/media:/mediaroot" \
    -v "$TMP/nginxlog:/var/log/nginx-shared" \
    -v "$W/default.conf.template:/etc/nginx/templates/conf.d/default.conf.template:ro" \
    -v "$W/modsecurity-override.conf.template:/etc/nginx/templates/modsecurity.d/modsecurity-override.conf.template:ro" \
    -v "$W/00-log-format.conf:/etc/nginx/conf.d/00-log-format.conf:ro" \
    -v "$W/security-headers.conf:/etc/nginx/conf.d/security-headers.conf:ro" \
    -v "$W/_bpp-locations.conf:/etc/nginx/bpp-templates/_bpp-locations.conf:ro" \
    -v "$W/vhost.conf.template:/etc/nginx/bpp-templates/vhost.conf.template:ro" \
    -v "$W/30-render-bpp-vhosts.sh:/docker-entrypoint.d/30-render-bpp-vhosts.sh:ro" \
    owasp/modsecurity-crs:nginx >/dev/null

printf "   czekam na start"
for _ in $(seq 1 30); do
    if curl -sk --http1.1 --max-time 2 --resolve "$HOST_NAME:$PORT:127.0.0.1" \
        "https://$HOST_NAME:$PORT/healthz" >/dev/null 2>&1; then break; fi
    printf "."; sleep 1
done
echo

if docker logs "$FRONT" 2>&1 | grep -qiE "\[emerg\]"; then
    echo "BLAD: nginx nie wstal:"
    docker logs "$FRONT" 2>&1 | grep -iE "\[emerg\]" | head -5
    exit 1
fi
echo "   silnik regul: $ENGINE"
echo

# --------------------------------------------------------------------------
# Przypadki testowe: OCZEKIWANE|opis|sciezka
# --------------------------------------------------------------------------
PRZYPADKI=(
  # --- realne payloady sqlmap z 13/23/27.07.2026 ---
  "BLOK|SQLi: UNION ALL SELECT|?_export=html%27%20UNION%20ALL%20SELECT%20NULL,NULL--%20a"
  "BLOK|SQLi: UPDATEXML (error-based)|?_export=html%29%29%29%29%20OR%20UPDATEXML%281670,CONCAT%280x7e,%28SELECT%20%28ELT%281670=1670,1%29%29%29,0x7e%29,1%29--%20-"
  "BLOK|SQLi: SELECT FROM(SELECT COUNT|?_export=html%29%20OR%20%28SELECT%206323%20FROM%28SELECT%20COUNT%28*%29,CONCAT%280x7e,1%29%29a%29"
  # --- inne klasy ataku ---
  "BLOK|XSS w parametrze|?q=%3Cscript%3Ealert%281%29%3C/script%3E"
  "BLOK|path traversal /etc/passwd|?plik=../../../../etc/passwd"
  "BLOK|proba pobrania .env|.env"
  "BLOK|proba pobrania .git/config|.git/config"
  # phpMyAdmin i inne sondy o *.php NIE sa blokowane na brzegu — lapie je
  # dopiero MaliciousRequestBlockingMiddleware w Django (lista BLOCKED_EXTENSIONS
  # w bpp/src/bpp/middleware.py) i odpowiada 444. Tu backend jest atrapa, wiec
  # widzimy "pass" — i to jest POPRAWNY wynik dla tej warstwy.
  "PASS|sonda o phpMyAdmin (blokuje ja Django, nie nginx)|phpmyadmin/index.php"
  # --- legalny ruch BPP: MUSI przejsc ---
  "PASS|eksport raportu HTML|nowe_raporty/autor/123/2000/2020/?_export=html&_tzju=False"
  "PASS|eksport z sortowaniem|nowe_raporty/autor/1/1990/2020/?_export=xlsx&_tzju=True&sort=-Pkt.%20MNiSW"
  "PASS|wyszukiwanie: angielskie 'select ... from'|bpp/szukaj/?q=Select%20topics%20from%20organic%20chemistry"
  "PASS|wyszukiwanie: 'union' w tytule|bpp/szukaj/?q=Union%20of%20sets%20in%20topology"
  "PASS|rekord z przecinkiem w ID|bpp/rekord/75,7/"
  "PASS|slug autora z myslnikami|bpp/autor/Jan-Kowalski-2/"
  # --- sciezki wyjete z blokowania (reguly 10002/10003) ---
  "PASS|DjangoQL (API) ze skladnia SQL-podobna|api/v1/zapytanie/rekord?q=rok%20=%202020%20and%20tytul%20~%20%22select%22"
  # Realny przypadek ze stagingu 2026-08-03: to zapytanie w interfejsie
  # uzytkownika zapalalo 930120 + 932235 + 932160 (score 15) i bylo blokowane,
  # bo wykluczenie obejmowalo tylko wariant API.
  "PASS|DjangoQL (UI) z tekstem wygladajacym na LFI|bpp/zapytanie/?model=rekord&query=test%20%3D%205/etc/passwd"
  "PASS|dbtemplates z surowym HTML|admin/dbtemplates/template/1/?body=%3Cscript%3Ex%3C/script%3E"
  # --- infrastruktura ---
  "PASS|healthcheck|healthz"
)

printf "%-6s %-46s %s\n" "WYNIK" "PRZYPADEK" "SZCZEGOLY"
printf "%s\n" "----------------------------------------------------------------------------------"

BLEDY=0
for wpis in "${PRZYPADKI[@]}"; do
    IFS='|' read -r oczek opis sciezka <<< "$wpis"

    kod=$(curl -sk --http1.1 -o /dev/null -w '%{http_code}' --max-time 8 \
        --resolve "$HOST_NAME:$PORT:127.0.0.1" \
        "https://$HOST_NAME:$PORT/$sciezka" 2>/dev/null)
    rc=$?

    # curl 52 (empty reply) / 56 (reset) = nginx zamknal polaczenie bez
    # odpowiedzi, czyli nasze 444
    if [ "$rc" -eq 52 ] || [ "$rc" -eq 56 ] || [ "$rc" -eq 92 ]; then
        faktyczny="BLOK"; szczegol="polaczenie zerwane (curl $rc)"
    elif [ "$rc" -ne 0 ]; then
        faktyczny="BLAD"; szczegol="curl $rc"
    elif [ "$kod" = "200" ]; then
        faktyczny="PASS"; szczegol="HTTP 200 pass"
    else
        faktyczny="PASS"; szczegol="HTTP $kod"
    fi

    if [ "$faktyczny" = "$oczek" ]; then
        printf "  \033[32mOK\033[0m   %-46s %s\n" "$opis" "$szczegol"
    else
        printf "  \033[31mFAIL\033[0m %-46s oczekiwano %s, jest %s (%s)\n" \
            "$opis" "$oczek" "$faktyczny" "$szczegol"
        BLEDY=$((BLEDY + 1))
    fi
done

# --------------------------------------------------------------------------
# Reguly WYCHODZACE (RESPONSE-95x): inspekcja CIALA ODPOWIEDZI
# --------------------------------------------------------------------------
# Kontrola, ze ta rodzina w ogole dziala. Wazna, bo regula 10004 zdejmuje ja
# dla /grafana/, /dozzle/, /flower/ i /netdata/ — a wykluczenie, ktore nic nie
# wylacza, jest gorsze niz zadne: daje falszywy spokoj.
#
# DLACZEGO OSOBNO, A NIE JAKO PRZYPADEK "BLOK" W TABELCE: reguly wychodzace
# koncza sie w `phase:4`, czyli gdy nginx CZESTO WYSLAL JUZ NAGLOWKI. Nie da
# sie wtedy zwrocic 403 (ani naszego 444) — nginx zapisuje `header already
# sent`, urywa strumien i klient dostaje raz zerwane polaczenie, a raz cale
# 200. Zmierzone: 1 na 5 przebiegow konczylo sie inaczej niz pozostale.
# Wynik HTTP jest tu wiec WYSCIGIEM i asercja na nim migota.
#
# WYKRYCIE natomiast jest deterministyczne, wiec sprawdzamy audit log: czy dla
# tego URI zapalila sie ktoras regula 95xxxx. To samo zjawisko widac na
# produkcji jako `500 0` w access logu zamiast czystej blokady.
echo
printf "%-6s %-46s %s\n" "WYNIK" "INSPEKCJA CIALA ODPOWIEDZI" "SZCZEGOLY"
printf "%s\n" "----------------------------------------------------------------------------------"
curl -sk --http1.1 -o /dev/null --max-time 8 --resolve "$HOST_NAME:$PORT:127.0.0.1" \
    "https://$HOST_NAME:$PORT/odpowiedz/wyciek-php.html" >/dev/null 2>&1
TRAFIENIA=$(docker logs "$FRONT" 2>&1 \
    | grep -c '"uri":"/odpowiedz/wyciek-php.html".*"ruleId":"95' || true)
if [ "$TRAFIENIA" -gt 0 ]; then
    printf "  \033[32mOK\033[0m   %-46s %s\n" \
        "wyciek komunikatu PHP w ciele odpowiedzi" "regula 95xxx zapalona"
else
    printf "  \033[31mFAIL\033[0m %-46s %s\n" \
        "wyciek komunikatu PHP w ciele odpowiedzi" "ZADNA regula 95xxx sie nie zapalila"
    BLEDY=$((BLEDY + 1))
fi

echo
if [ "$BLEDY" -eq 0 ]; then
    echo "Wszystkie ${#PRZYPADKI[@]} przypadkow + inspekcja odpowiedzi zgodnie z oczekiwaniem."
else
    echo "NIEZGODNOSCI: $BLEDY z $(( ${#PRZYPADKI[@]} + 1 ))."
    echo
    echo "Trafienia regul CRS z tego przebiegu:"
    docker logs "$FRONT" 2>&1 | grep -o '"ruleId":"[0-9]*"' | sort | uniq -c | sort -rn | head -10
fi
exit "$BLEDY"

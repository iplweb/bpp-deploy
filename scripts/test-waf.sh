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
# Nazwy i siec sa UNIKALNE dla przebiegu. Wczesniej byly stale i dwa rownolegle
# przebiegi (dwa terminale, dwa worktree, CI obok reki) kolidowaly nazwa
# kontenera — `docker run` przegrywal, blad szedl do /dev/null, a skrypt jechal
# dalej odpytujac CUDZY kontener. Objaw byl nie do odgadniecia: testy HTTP/1.1
# przechodzily (bo cudzy kontener tez publikuje port), a przypadek h3 zglaszal
# "klient nie zestawil QUIC" — bo w cudzym kontenerze nie ma naszego aliasu.
PRZEBIEG="${WAF_TEST_SUFFIX:-$$}"
NET="bpp-waf-test-net-$PRZEBIEG"
# Wolumen NAZWANY, nie bind mount z $TMP — patrz komentarz przy `docker run` nizej.
VOL="bpp-waf-test-log-$PRZEBIEG"
BACK="bpp-waf-test-appserver-$PRZEBIEG"
FRONT="bpp-waf-test-webserver-$PRZEBIEG"
# 0 = dowolny wolny port od jadra; realny numer odczytujemy z `docker port`.
# Stala 18443 potrafila kolidowac z czyms juz dzialajacym na hoscie.
PORT_ZADANY="${WAF_TEST_PORT:-0}"
HOST_NAME="waf-test.example.org"
TMP="$(mktemp -d)"

# tryb silnika — domyslnie taki jak na produkcji; da sie przestawic na
# DetectionOnly, zeby zobaczyc co BY zostalo zablokowane
ENGINE="${MODSEC_RULE_ENGINE:-On}"

# Klient HTTP/3. Systemowy curl — takze ten z obrazow alpine i curlimages/curl
# — jest budowany BEZ QUIC (`curl -V` nie pokazuje HTTP3), wiec do tego jednego
# przypadku bierzemy osobny obraz. Publikuje wylacznie manifest amd64, stad
# jawne `--platform`: na x86 to no-op, na arm64 wlacza emulacje (zawodna —
# patrz komentarz przy `sprawdz_http3`).
H3_IMAGE="${WAF_TEST_H3_IMAGE:-ymuski/curl-http3}"
H3_PLATFORM="--platform=linux/amd64"

# shellcheck disable=SC2317  # wolane przez `trap`, shellcheck tego nie widzi
czysc() {
    # WAF_TEST_KEEP=1 zostawia stack na nogach — bez tego nie da sie po
    # nieudanym przebiegu zajrzec do logow nginksa ani odpytac go recznie.
    if [ "${WAF_TEST_KEEP:-0}" = "1" ]; then
        echo "WAF_TEST_KEEP=1 — kontenery zostaja ($FRONT, $BACK, siec $NET)."
        echo "Posprzatasz przez: docker rm -f $FRONT $BACK && docker network rm $NET && docker volume rm $VOL"
        return
    fi
    docker rm -f "$FRONT" "$BACK" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    docker volume rm "$VOL" >/dev/null 2>&1
    rm -rf "$TMP"
}
trap czysc EXIT

echo "== przygotowanie =="
mkdir -p "$TMP"/{ssl,letsencrypt,certbot,static,media,html}
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
if ! docker run -d --name "$BACK" --network "$NET" --network-alias appserver \
    -v "$TMP/backend.conf:/etc/nginx/conf.d/default.conf:ro" \
    -v "$TMP/html:/html:ro" \
    nginx:1.30.2 >/dev/null; then
    echo "BLAD: nie udalo sie wystartowac atrapy backendu ($BACK)."
    exit 1
fi

# Katalog roboczy musi byc CZYTELNY DLA KONTENERA. `mktemp -d` daje 0700,
# a openssl zapisuje klucz jako 0600 — obie rzeczy nalezace do uzytkownika,
# ktory odpalil test. Nginx w obrazie CRS chodzi jako uid 101, wiec przez bind
# mount nie przejdzie ani przez katalog, ani do klucza:
#
#   [emerg] cannot load certificate key "/etc/ssl/private/key.pem":
#           ... Permission denied
#
# Na macOS/OrbStack tego nie widac (bind mounty pokazuja sie jako wlasnosc
# uzytkownika kontenera), na Linuksie owszem — wyszlo dopiero po wpieciu tego
# skryptu do CI. Na produkcji problemu nie ma, bo $BPP_CONFIGS_DIR powstaje
# przez `mkdir -p` z normalna umaska, czyli jest przechodni.
#
# `a+rX` = odczyt dla wszystkich, wykonywalnosc TYLKO na katalogach. Klucz jest
# jednorazowym snakeoilem, generowanym na ten przebieg i kasowanym razem z $TMP.
chmod -R a+rX "$TMP"

# Wolumen access logu — NAZWANY, dokladnie jak na produkcji, i to jest istotne.
#
# Wczesniej byl tu bind mount z `mktemp -d`. To DWA ROZNE mechanizmy uprawnien:
# bind mount dziedziczy wlasciciela katalogu z hosta (i uid 101 w kontenerze
# zwykle moze w nim pisac), a swiezy wolumen nazwany Docker tworzy jako
# `root:root 0755`. Obraz CRS startuje nginksa jako NIEUPRZYWILEJOWANEGO
# uzytkownika (uid 101), wiec na wolumenie nazwanym dostaje:
#
#   [emerg] open() "/var/log/nginx-shared/bpp_access.log" failed (13: Permission denied)
#
# i nie wstaje wcale. Test na bind moucie byl STRUKTURALNIE niezdolny to zlapac —
# sprawdzal konfiguracje nginksa na innym typie storage'u niz produkcyjny.
#
# `chown` ponizej ODWZOROWUJE serwis `webserver-init` z
# docker-compose.infrastructure.yml. Ze sam serwis jest w compose zadeklarowany
# i wpiety w `depends_on` webservera pilnuje osobna asercja w tests/test_makefile.sh
# — tutaj sprawdzamy, ze ten mechanizm faktycznie wystarcza nginksowi do startu.
docker volume create "$VOL" >/dev/null
if ! docker run --rm --user 0:0 -v "$VOL:/var/log/nginx-shared" \
        --entrypoint sh owasp/modsecurity-crs:nginx \
        -c 'chown -R nginx:nginx /var/log/nginx-shared' >/dev/null 2>&1; then
    echo "BLAD: nie udalo sie przygotowac wolumenu access logu ($VOL)."
    exit 1
fi

# Alias sieciowy = nazwa vhosta. Potrzebny dla przypadku HTTP/3: klient QUIC
# chodzi z WNETRZA sieci dockerowej (na hoscie nie ma curla z h3), wiec musi
# rozwiazac `waf-test.example.org` na kontener — inaczej trafilby w
# `default_server` zamiast w testowany vhost. Reszta testow, strzelana z hosta
# przez `--resolve`, tego nie uzywa.
# MODSEC_AUDIT_LOG_PARTS=AHZ ponizej to DOKLADNIE to, co ma produkcja
# (docker-compose.infrastructure.yml). Bylo tu ABHZ, czyli Z czescia B (naglowki
# zadania) — a produkcja nie ma jej CELOWO, zeby `Cookie` z sessionid nie trafial
# do Loki. Test strzelal wiec inna konfiguracja logowania niz ta, ktorej broni,
# a fixture zebrany z takiego przebiegu (tests/fixtures/alloy-loglines.txt)
# zawieralby `request.headers`, ktorego na produkcji w audit logu nie ma.
if ! docker run -d --name "$FRONT" --network "$NET" --network-alias "$HOST_NAME" \
    -p "$PORT_ZADANY:443" \
    -e DJANGO_BPP_HOSTNAMES="$HOST_NAME" \
    -e DJANGO_BPP_SSL_MODE=manual \
    -e MODSEC_RULE_ENGINE="$ENGINE" \
    -e BLOCKING_PARANOIA=1 \
    -e ALLOWED_HTTP_VERSIONS="HTTP/1.0 HTTP/1.1 HTTP/2 HTTP/2.0 HTTP/3 HTTP/3.0" \
    -e MODSEC_AUDIT_ENGINE=RelevantOnly \
    -e MODSEC_AUDIT_LOG_FORMAT=JSON \
    -e MODSEC_AUDIT_LOG_PARTS=AHZ \
    -e MODSEC_REQ_BODY_LIMIT=132120576 \
    -e MODSEC_REQ_BODY_NOFILES_LIMIT=4194304 \
    -v "$TMP/ssl:/etc/ssl/private:ro" \
    -v "$TMP/letsencrypt:/etc/letsencrypt" \
    -v "$TMP/certbot:/var/www/certbot:ro" \
    -v "$TMP/static:/var/www/html/staticroot" \
    -v "$TMP/media:/mediaroot" \
    -v "$VOL:/var/log/nginx-shared" \
    -v "$W/default.conf.template:/etc/nginx/templates/conf.d/default.conf.template:ro" \
    -v "$W/modsecurity-override.conf.template:/etc/nginx/templates/modsecurity.d/modsecurity-override.conf.template:ro" \
    -v "$W/00-log-format.conf:/etc/nginx/conf.d/00-log-format.conf:ro" \
    -v "$W/security-headers.conf:/etc/nginx/conf.d/security-headers.conf:ro" \
    -v "$W/_bpp-locations.conf:/etc/nginx/bpp-templates/_bpp-locations.conf:ro" \
    -v "$W/vhost.conf.template:/etc/nginx/bpp-templates/vhost.conf.template:ro" \
    -v "$W/30-render-bpp-vhosts.sh:/docker-entrypoint.d/30-render-bpp-vhosts.sh:ro" \
    owasp/modsecurity-crs:nginx >/dev/null; then
    echo "BLAD: nie udalo sie wystartowac webservera ($FRONT)."
    exit 1
fi

# Realny numer portu na hoscie — przy PORT_ZADANY=0 przydziela go jadro.
PORT="$(docker port "$FRONT" 443/tcp | head -1 | sed 's/.*://')"
if [ -z "$PORT" ]; then
    echo "BLAD: nie udalo sie ustalic portu opublikowanego przez $FRONT."
    docker logs "$FRONT" 2>&1 | tail -5
    exit 1
fi

printf "   czekam na start"
GOTOWY=0
for _ in $(seq 1 30); do
    if curl -sk --http1.1 --max-time 2 --resolve "$HOST_NAME:$PORT:127.0.0.1" \
        "https://$HOST_NAME:$PORT/healthz" >/dev/null 2>&1; then GOTOWY=1; break; fi
    printf "."; sleep 1
done
echo

if docker logs "$FRONT" 2>&1 | grep -qiE "\[emerg\]"; then
    echo "BLAD: nginx nie wstal:"
    docker logs "$FRONT" 2>&1 | grep -iE "\[emerg\]" | head -5
    exit 1
fi
# Bez tego skrypt jechal dalej na niedzialajacym stacku i zglaszal 18 z 18
# niezgodnosci zamiast jednej czytelnej przyczyny.
if [ "$GOTOWY" -ne 1 ]; then
    echo "BLAD: webserver nie odpowiedzial na /healthz w 30 s. Ostatnie logi:"
    docker logs "$FRONT" 2>&1 | tail -10
    exit 1
fi
echo "   silnik regul: $ENGINE, port na hoscie: $PORT"
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
  # --- rozszerzenia wykonywalne: 444 juz na brzegu ---
  # Do 08.2026 te sondy przechodzily przez nginksa i lapal je dopiero
  # MaliciousRequestBlockingMiddleware w Django (BLOCKED_EXTENSIONS w
  # bpp/src/bpp/middleware.py). Ochrona byla, ale kosztowala runde do
  # appservera; teraz konczy sie na brzegu. Warianty wersjonowane pochodza
  # z realnych logow produkcji (72 h, 05.08.2026) — to one obnazyly, ze
  # wyliczenie `php|php3|php5|php7` przepuszcza 3 z 5 trafien.
  "BLOK|sonda o phpMyAdmin (*.php)|phpmyadmin/index.php"
  "BLOK|wersjonowane rozszerzenie .php73|zup.php73"
  "BLOK|wersjonowane rozszerzenie .php56|qaez.php56"
  "BLOK|.PhP7 — wariant wielkosci liter|randkeyword.PhP7"
  "BLOK|sonda o .aspx|default.aspx"
  # --- prefiksy obcych aplikacji ---
  "BLOK|prefiks WordPressa /wp-admin/|wp-admin/"
  "BLOK|prefiks /wp-json/|wp-json/"
  "BLOK|Tomcat /manager/html|manager/html"
  "BLOK|Spring /actuator/|actuator/health"
  # --- niepodstawione literaly szablonow ---
  # Wariant z `+` to REGRESJA, ktora ten test ma pilnowac: stary wzorzec
  # `\{\{\s*clickURL\s*\}\}` go NIE lapal, bo nginx nie dekoduje `+` w sciezce
  # na spacje. Produkcja dostawala 11 takich zadan na 72 h i wszystkie szly
  # do Django.
  "BLOK|literal {{ clickURL }} ze spacja|bpp/rekord/x/%7B%7B%20clickURL%20%7D%7D"
  "BLOK|literal {{+clickURL+}} z plusem (regresja)|bpp/rekord/x/%7B%7B+clickURL+%7D%7D"
  "BLOK|literal \${todayFeature.link} (template JS)|bpp/uczelnia/UP/%24%7BtodayFeature.link%7D"
  # --- legalny ruch BPP: MUSI przejsc ---
  # Kontrole granic nowych regul. `/admin/` nie moze sie zlapac na
  # `administrator` (stad `(/|$)` we wzorcu), a `.js` w /static/ nie moze
  # wpasc pod blokade rozszerzen — regex bije prefiks, wiec pomylka w tej
  # liscie zabralaby serwisowi cala statyke.
  "PASS|/admin/ NIE lapie sie na 'administrator'|admin/"
  "PASS|statyk .js nie jest blokowany|static/js/app.js"
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

# Suma przypadkow: tablica PRZYPADKI + inspekcja ciala odpowiedzi. Przypadek
# HTTP/3 dolicza sie nizej, bo jako jedyny bywa POMIJANY (brak klienta QUIC) —
# a wtedy nie ma go czym liczyc.
LACZNIE=$(( ${#PRZYPADKI[@]} + 1 ))

# --------------------------------------------------------------------------
# Regula 10006: /grafana/ poza inspekcja WAF-a
# --------------------------------------------------------------------------
# DLACZEGO OSOBNO, A NIE JAKO WPIS "PASS" W TABELCE: tamta bateria strzela
# wylacznie GET-em bez ciala, a tu caly problem siedzi w CIELE POST-a. Co
# wazniejsze, jej rozstrzygniecie liczy KAZDY kod HTTP jako PASS — czyli 403
# od ModSecurity przeszloby tam jako sukces. Regresja bylaby niewidoczna.
#
# CO SIE STALO NA PRODUKCJI (publikacje-test.up.lublin.pl, 2026-08-05): kazdy
# POST na /grafana/api/ds/query wracal z 403, wiec KAZDY panel KAZDEGO
# dashboardu pokazywal "No data". Zapalala go zmienna `$level` przy
# "Log Level = All", ktora rozwija sie do `detected_level=~"critical|debug|..."`
# — a ciag `|debug` to dla reguly 932110 wstrzykniecie polecenia Windows
# (metaznak powloki + polecenie DOS-a `debug`). Severity CRITICAL = 5 pkt przy
# progu 5, wiec jedno trafienie blokowalo.
#
# SA DWA SPRAWDZENIA I OBA SA POTRZEBNE. Samo "grafana przechodzi" nie dowodzi
# niczego, dopoki nie wiadomo, ze payload W OGOLE jest blokowany gdzie indziej
# — inaczej test przeszedlby tak samo po skasowaniu reguly 10006, a nawet po
# wylaczeniu calego CRS. To ta sama pulapka, ktora opisano wyzej przy regulach
# wychodzacych: wykluczenie, ktore nic nie wylacza, jest gorsze niz zadne.
CIALO_LOGQL='{"queries":[{"refId":"A","datasource":{"type":"loki","uid":"loki"},"expr":"sum(count_over_time({job=\"docker\", detected_level=~\"critical|debug|error|info|unknown|warn\"} | modsec_src=~\".*\" [1m])) by (detected_level)"}],"from":"now-6h","to":"now"}'

# Zwraca: BLOK (403 albo zerwane polaczenie) / PASS (cokolwiek innego) / BLAD.
strzel_ds_query() {
    local sciezka="$1" kod rc
    kod=$(curl -sk --http1.1 -o /dev/null -w '%{http_code}' --max-time 8 \
        --resolve "$HOST_NAME:$PORT:127.0.0.1" \
        -X POST -H 'Content-Type: application/json' --data "$CIALO_LOGQL" \
        "https://$HOST_NAME:$PORT/$sciezka" 2>/dev/null)
    rc=$?
    if [ "$rc" -eq 52 ] || [ "$rc" -eq 56 ] || [ "$rc" -eq 92 ]; then
        echo "BLOK|polaczenie zerwane (curl $rc)"
    elif [ "$rc" -ne 0 ]; then
        echo "BLAD|curl $rc"
    elif [ "$kod" = "403" ]; then
        echo "BLOK|HTTP 403 od ModSecurity"
    else
        echo "PASS|HTTP $kod"
    fi
}

echo
printf "%-6s %-46s %s\n" "WYNIK" "ZAPYTANIE LogQL Z GRAFANY (POST)" "SZCZEGOLY"
printf "%s\n" "----------------------------------------------------------------------------------"
for para in "BLOK|kontrola: ten sam payload poza /grafana/|" \
            "PASS|/grafana/api/ds/query nie jest blokowane|grafana/api/ds/query"; do
    IFS='|' read -r oczek opis sciezka <<< "$para"
    LACZNIE=$((LACZNIE + 1))
    IFS='|' read -r faktyczny szczegol <<< "$(strzel_ds_query "$sciezka")"
    if [ "$faktyczny" = "$oczek" ]; then
        printf "  \033[32mOK\033[0m   %-46s %s\n" "$opis" "$szczegol"
    else
        printf "  \033[31mFAIL\033[0m %-46s oczekiwano %s, jest %s (%s)\n" \
            "$opis" "$oczek" "$faktyczny" "$szczegol"
        BLEDY=$((BLEDY + 1))
    fi
done

# --------------------------------------------------------------------------
# Przypadek osobny: legalne zadanie po HTTP/3
# --------------------------------------------------------------------------
# Nie siedzi w tablicy PRZYPADKI, bo tamte strzelaja `curl --http1.1` Z HOSTA,
# a ten potrzebuje klienta QUIC z WNETRZA sieci dockerowej i wlasnego sposobu
# rozstrzygania wyniku.
#
# PO CO TO JEST: w HTTP/2 i /3 naglowek `Host:` zastapil pseudo-naglowek
# `:authority`, ktorego konektor ModSecurity-nginx nie widzi. Regula CRS 920280
# ("Request Missing a Host Header", severity CRITICAL = 5 pkt) zapalala sie
# przez to na KAZDYM zadaniu h3 i sama osiagala prog anomalii — caly serwis byl
# niedostepny dla kazdej przegladarki, ktora zlapala `Alt-Svc: h3`. Bateria na
# HTTP/1.1 tego nie widziala, bo tam `Host:` istnieje. Naprawia to regula 10005
# w modsecurity-override.conf.template; ten przypadek pilnuje, zeby nie
# wrocilo.
sprawdz_http3() {
    local kod rc proba h3_w_logu

    if ! docker run --rm "$H3_PLATFORM" "$H3_IMAGE" curl -V 2>/dev/null | grep -q HTTP3; then
        printf "  \033[33mPOMIN\033[0m %-46s brak dzialajacego klienta h3 (%s)\n" \
            "legalne GET / po HTTP/3" "$H3_IMAGE"
        return 2
    fi

    # Pod emulacja amd64 klient gubi handshake QUIC mniej wiecej raz na piec
    # prob i zadanie WCALE nie dochodzi do nginksa. Dlatego wyniku NIE czytamy
    # z kodu wyjscia curla, tylko z access logu:
    #   444 przy HTTP/3.0     -> realna blokada WAF-a, to jest FAIL,
    #   zero linii HTTP/3.0   -> zgubiony handshake, powtarzamy probe.
    # Bez tego rozroznienia retry maskowalby regresje.
    for proba in 1 2 3 4; do
        kod=$(docker run --rm --network "$NET" "$H3_PLATFORM" "$H3_IMAGE" \
            curl -sk --http3-only -o /dev/null -w '%{http_code}' --max-time 15 \
            "https://$HOST_NAME/" 2>/dev/null)
        rc=$?
        if [ "$rc" -eq 0 ] && [ "$kod" = "200" ]; then
            printf "  \033[32mOK\033[0m   %-46s HTTP %s (proba %s)\n" \
                "legalne GET / po HTTP/3" "$kod" "$proba"
            return 0
        fi
    done

    h3_w_logu=$(docker logs "$FRONT" 2>&1 | grep -c 'HTTP/3.0"')
    if [ "$h3_w_logu" -eq 0 ]; then
        printf "  \033[33mPOMIN\033[0m %-46s klient nie zestawil QUIC (nginx nie zapisal ani jednego zadania h3)\n" \
            "legalne GET / po HTTP/3"
        return 2
    fi

    printf "  \033[31mFAIL\033[0m %-46s WAF zablokowal legalne zadanie po h3\n" \
        "legalne GET / po HTTP/3"
    docker logs "$FRONT" 2>&1 | grep -o '"GET / HTTP/3.0" [0-9]*' | sort | uniq -c | sed 's/^/         /'
    return 1
}

sprawdz_http3
case $? in
    0) LACZNIE=$((LACZNIE + 1)) ;;
    1) LACZNIE=$((LACZNIE + 1)); BLEDY=$((BLEDY + 1)) ;;
    *) : ;;   # pominiety — nie liczymy go w sumie
esac

# Access log na wolumenie WSPOLDZIELONYM z netdata (kolektor web_log).
# Sam start nginksa juz dowodzi, ze zapis dziala (inaczej byloby [emerg]), ale
# ta asercja nazywa te wlasnosc wprost — bez niej regres uprawnien objawilby sie
# jako "wszystkie przypadki failuja z curl 7", czyli przyczyna nie do odgadniecia.
echo
printf "%-6s %-46s %s\n" "WYNIK" "ACCESS LOG DLA NETDATY" "SZCZEGOLY"
printf -- '----------------------------------------------------------------------------------\n'
LACZNIE=$((LACZNIE + 1))
linie_logu=$(docker exec "$FRONT" sh -c 'wc -l < /var/log/nginx-shared/bpp_access.log' 2>/dev/null | tr -d ' \r')
if [ -n "$linie_logu" ] && [ "$linie_logu" -gt 0 ] 2>/dev/null; then
    printf "  \033[32mOK\033[0m   %-46s %s linii na wolumenie nazwanym\n" \
        "nginx (uid 101) zapisuje bpp_access.log" "$linie_logu"
else
    printf "  \033[31mFAIL\033[0m %-46s %s\n" \
        "nginx (uid 101) zapisuje bpp_access.log" \
        "brak zapisu — sprawdz uprawnienia wolumenu (serwis webserver-init)"
    BLEDY=$((BLEDY + 1))
fi

# Naglowek `Server` nie moze niesc numeru wersji (server_tokens off).
#
# Ta asercja istnieje, bo wlasnosc jest KRUCHA W NIEOCZYWISTY SPOSOB: obraz CRS
# ma `SERVER_TOKENS=off`, ale dyrektywa czytajaca te zmienna siedzi w JEGO
# szablonie conf.d/default.conf.template — ktory my nadpisujemy wlasnym. Wersja
# wyciekala wiec mimo poprawnego ustawienia w obrazie, a jedynym objawem byl
# naglowek, ktorego nikt nie ogladal. Bez tego testu identyczna regresja wroci
# przy kazdym wiekszym przepisaniu default.conf.template.
echo
printf "%-6s %-46s %s\n" "WYNIK" "FINGERPRINT SERWERA" "SZCZEGOLY"
printf -- '----------------------------------------------------------------------------------\n'
LACZNIE=$((LACZNIE + 1))
naglowek_server=$(curl -skI --http1.1 --max-time 8 --resolve "$HOST_NAME:$PORT:127.0.0.1" \
    "https://$HOST_NAME:$PORT/healthz" 2>/dev/null | grep -i '^server:' | tr -d '\r')
if [ -z "$naglowek_server" ]; then
    printf "  \033[31mFAIL\033[0m %-46s %s\n" \
        "brak naglowka Server w odpowiedzi" "nie udalo sie odczytac naglowkow"
    BLEDY=$((BLEDY + 1))
elif printf '%s' "$naglowek_server" | grep -q '[0-9]'; then
    printf "  \033[31mFAIL\033[0m %-46s %s\n" \
        "wersja nginksa wycieka w naglowku Server" "$naglowek_server"
    BLEDY=$((BLEDY + 1))
else
    printf "  \033[32mOK\033[0m   %-46s %s\n" \
        "Server bez numeru wersji (server_tokens off)" "$naglowek_server"
fi

echo
if [ "$BLEDY" -eq 0 ]; then
    echo "Wszystkie $LACZNIE przypadkow zgodnie z oczekiwaniem."
else
    echo "NIEZGODNOSCI: $BLEDY z $LACZNIE."
    echo
    echo "Trafienia regul CRS z tego przebiegu:"
    docker logs "$FRONT" 2>&1 | grep -o '"ruleId":"[0-9]*"' | sort | uniq -c | sort -rn | head -10
fi
exit "$BLEDY"

#!/usr/bin/env bash
# Test pipeline'u logow Alloy: sprawdza, czy `defaults/alloy/config.alloy`
# nadaje wlasciwy `detected_level` i czy poprawnie rozklada trafienia WAF-a
# na pola `modsec_*`.
#
# Testuje PRAWDZIWY plik konfiguracyjny — nie kopie, nie fragment. Podmieniane
# sa wylacznie dwa konce pipeline'u:
#   - wejscie: `loki.source.file` z fixture zamiast `loki.source.docker`,
#   - wyjscie: `loki.echo` zamiast `loki.write` (wypisuje wpis razem z labelami
#     i structured metadata na stdout, wiec nie trzeba stawiac Loki).
# Wszystko pomiedzy — detektory poziomu, bramka normalizujaca, oba bloki
# ModSecurity — jest dokladnie to, co pojedzie na produkcje.
#
# Linie WAF-a w fixture to PRAWDZIWE wpisy z przebiegu `make test-waf`, zebrane
# przy produkcyjnym MODSEC_AUDIT_LOG_PARTS=AHZ (bez czesci B, czyli bez
# naglowkow zadania). Nie sa wymyslone.
#
# Nie wymaga .env ani dzialajacej instalacji BPP. Sprzata po sobie.
# Kod wyjscia = liczba niezgodnosci.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$REPO_DIR/defaults/alloy/config.alloy"
FIXTURE="$REPO_DIR/tests/fixtures/alloy-loglines.txt"
OBRAZ="${ALLOY_TEST_IMAGE:-grafana/alloy:v1.15.0}"
PRZEBIEG="${ALLOY_TEST_SUFFIX:-$$}"
KONTENER="bpp-alloy-test-$PRZEBIEG"
TMP="$(mktemp -d)"
BLEDY=0

# Ile czekac na przemielenie fixture. Alloy tailuje plik, wiec potrzebuje
# chwili od startu; 20 s daje zapas takze na wolnym hoscie / pod emulacja.
CZEKAJ="${ALLOY_TEST_WAIT:-20}"

# shellcheck disable=SC2317  # wolane przez `trap`, shellcheck tego nie widzi
czysc() {
    # ALLOY_TEST_KEEP=1 zostawia kontener i wygenerowany config — bez tego nie
    # da sie po nieudanym przebiegu zajrzec do logu Alloy ani odtworzyc, co
    # dokladnie dostal na wejscie.
    if [ "${ALLOY_TEST_KEEP:-0}" = "1" ]; then
        echo "ALLOY_TEST_KEEP=1 — kontener $KONTENER i katalog $TMP zostaja."
        echo "Posprzatasz przez: docker rm -f $KONTENER && rm -rf $TMP"
        return
    fi
    docker rm -f "$KONTENER" >/dev/null 2>&1
    [ -n "${TMP:-}" ] && rm -rf "$TMP"
}
trap czysc EXIT

command -v docker >/dev/null 2>&1 || { echo "BLAD: brak dockera."; exit 1; }
[ -f "$CONFIG" ]  || { echo "BLAD: brak $CONFIG"; exit 1; }
[ -f "$FIXTURE" ] || { echo "BLAD: brak $FIXTURE"; exit 1; }

# ── Przygotowanie configu testowego ─────────────────────────────────────────
# Wycinamy blok zrodla dockerowego i blok zapisu do Loki, przekierowujemy
# pipeline na loki.echo i doklejamy zrodlo plikowe.
#
# `job="docker"` na targecie jest OBOWIAZKOWE: selektory `stage.match`
# w config.alloy sa postaci {job="docker"} |~ "...", wiec bez tego labela
# zaden blok ModSecurity by sie nie zapalil i test przechodzilby na niby.
#
# `logging { level }` MUSI zejsc na "info": loki.echo wypisuje wpisy wlasnie na
# tym poziomie, a produkcyjny config.alloy ma "warn" — bez tej podmiany testowana
# konfiguracja wyciszalaby wlasny wynik i kazdy przebieg konczylby sie "pipeline
# sie nie zbudowal", mimo ze dziala.
#
# `discovery.docker` tez wylatuje: bez /var/run/docker.sock w kontenerze
# zasmieca log bledami odswiezania targetow, a po usunieciu loki.source.docker
# nikt go juz nie uzywa.
sed -e '/^loki\.source\.docker "containers" {/,/^}/d' \
    -e '/^loki\.write "local" {/,/^}/d' \
    -e '/^discovery\.docker "local" {/,/^}/d' \
    -e '/^discovery\.relabel "docker_labels" {/,/^}/d' \
    -e '/^logging {/,/^}/ s/level  = "warn"/level  = "info"/' \
    -e 's|forward_to = \[loki\.write\.local\.receiver\]|forward_to = [loki.echo.out.receiver]|' \
    "$CONFIG" > "$TMP/config.alloy"

cat >> "$TMP/config.alloy" <<'EOF'

loki.source.file "test" {
  targets = [{
    __path__  = "/data/fixture.txt",
    job       = "docker",
    service   = "webserver",
    container = "test-webserver",
  }]
  forward_to = [loki.process.log_levels.receiver]
}

loki.echo "out" {}
EOF

cp "$FIXTURE" "$TMP/fixture.txt"

if ! grep -q 'loki.echo' "$TMP/config.alloy" || grep -q 'loki.write.local.receiver' "$TMP/config.alloy"; then
    echo "BLAD: podmiana zrodla/ujscia w configu sie nie powiodla."
    echo "      Zmienila sie struktura config.alloy? Sprawdz nazwy blokow."
    exit 1
fi

# ── Uruchomienie ────────────────────────────────────────────────────────────
echo "== przygotowanie =="
echo "   obraz: $OBRAZ"

docker rm -f "$KONTENER" >/dev/null 2>&1
if ! docker run -d --name "$KONTENER" -v "$TMP:/data:ro" "$OBRAZ" \
        run --disable-reporting --storage.path=/tmp/alloy /data/config.alloy >/dev/null 2>"$TMP/run.err"; then
    echo "BLAD: nie udalo sie wystartowac Alloy:"
    cat "$TMP/run.err"
    exit 1
fi

sleep "$CZEKAJ"
docker logs "$KONTENER" > "$TMP/out.txt" 2>&1

# Blad skladni / budowy komponentu = brak jakiegokolwiek wpisu. Bez tej
# kontroli wszystkie asercje po prostu by nie trafily i wyglądaloby to na
# 13 zwyklych niezgodnosci zamiast na jedna przyczyne.
if ! grep -q 'component_id=loki.echo.out' "$TMP/out.txt"; then
    echo
    echo "BLAD: Alloy nie wypuscil ani jednego wpisu — pipeline sie nie zbudowal."
    echo "----- log Alloy -----"
    grep -iE 'level=error|Error:|error building|invalid' "$TMP/out.txt" | head -20
    echo "---------------------"
    exit 1
fi

# ── Asercje ─────────────────────────────────────────────────────────────────
# sprawdz <opis> <marker-linii> <klucz=wartosc>...
#   marker  — unikalny fragment linii wejsciowej, po nim znajdujemy wpis
#   klucz   — `detected_level` (label) albo `modsec_*` (structured metadata)
#
# ALLOY_FILTR (opcjonalny, ustawiany przez sprawdz_audit) zawezaja wybor, gdy
# marker pasuje do wiecej niz jednej linii.
sprawdz() {
    local opis="$1" marker="$2"; shift 2
    local wpis niezgodne=""

    wpis="$(grep -F -- "$marker" "$TMP/out.txt" | grep -F -- "${ALLOY_FILTR:-}" | head -1)"
    if [ -z "$wpis" ]; then
        printf '  \033[31mFAIL\033[0m %-46s %s\n' "$opis" "brak wpisu dla markera"
        BLEDY=$((BLEDY + 1))
        return
    fi

    local para klucz wartosc
    for para in "$@"; do
        klucz="${para%%=*}"
        wartosc="${para#*=}"
        # label:  detected_level=\"warn\"   |  SM: \"modsec_attack\":\"sqli\"
        if grep -qF -- "$klucz=\\\"$wartosc\\\"" <<<"$wpis" \
        || grep -qF -- "\\\"$klucz\\\":\\\"$wartosc\\\"" <<<"$wpis"; then
            continue
        fi
        niezgodne="$niezgodne $klucz(ocz. $wartosc)"
    done

    if [ -z "$niezgodne" ]; then
        printf '  \033[32mOK\033[0m   %-46s %s\n' "$opis" "$*"
    else
        printf '  \033[31mFAIL\033[0m %-46s%s\n' "$opis" "$niezgodne"
        BLEDY=$((BLEDY + 1))
    fi
}

# Jak `sprawdz`, ale wybiera WYLACZNIE wpis audit logu.
#
# Konieczne, bo jedno zadanie zostawia DWA wpisy — audit JSON i blizniacza linia
# error.log, ktora CYTUJE oryginalne zadanie (`request: "GET /?..."`). Marker po
# fragmencie URI trafia wiec w obie, a `head -1` wybieral raz jedna, raz druga:
# asercja `detected_level=warn` przechodzila zawsze (obie maja warn), ale pola
# modsec_* juz nie, bo linia error.log ich nie ma. Test byl niedeterministyczny.
# `is_interrupted` wystepuje wylacznie w audit logu.
sprawdz_audit() {
    ALLOY_FILTR='is_interrupted' sprawdz "$@"
}

echo
printf 'WYNIK  PRZYPADEK                                      SZCZEGOLY\n'
printf -- '----------------------------------------------------------------------------------\n'

# --- WAF: audit log JSON -> pelny rozklad na pola ---
sprawdz_audit "WAF: SQLi zablokowane" 'UNION%20ALL%20SELECT' \
    detected_level=warn modsec_action=blocked modsec_rule_id=942100 \
    modsec_attack=sqli modsec_direction=inbound modsec_code=403

sprawdz_audit "WAF: path traversal -> kategoria lfi" '/etc/passwd' \
    detected_level=warn modsec_action=blocked modsec_rule_id=930100 modsec_attack=lfi

sprawdz_audit "WAF: DetectionOnly (regula 10002/10003)" 'zapytanie' \
    detected_level=warn modsec_action=detected modsec_code=200

sprawdz_audit "WAF: inspekcja odpowiedzi (outbound)" 'wyciek-php' \
    detected_level=warn modsec_action=blocked modsec_direction=outbound \
    modsec_rule_id=951230

# --- WAF: blizniacza linia error.log ---
# REGRESJA: nginx loguje ja jako [error]; ma dostac warn, zeby skan nie
# malowal dashboardu bledow aplikacji na czerwono.
sprawdz "WAF: linia error.log dostaje warn, nie error" 'ModSecurity: Access denied' \
    detected_level=warn

# Linia startowa modulu NIE jest trafieniem — nie moze wpasc w blok WAF-a.
sprawdz "WAF: linia startowa modulu to info" 'rules loaded inline' \
    detected_level=info

# --- Zwykle formaty logow ---
# Marker BEZ cudzyslowow: loki.echo eskejpuje je w `entry="..."`, wiec
# grep -F po fragmencie JSON-a ze znakami " nigdy by nie trafil.
sprawdz "JSON z polem level"            'connection reset by peer' detected_level=debug
sprawdz "logger Pythona (ERROR:...)"    'Internal Server Error'   detected_level=error
sprawdz "format klucz-wartosc"          'slow query detected'     detected_level=warn
sprawdz "nginx [error] (prawdziwy)"     'upstream timed out'      detected_level=error

# REGRESJA: przeciek `securitywarning` na label. Zamkniety slownik ma to
# zamienic na `warn`.
sprawdz "SecurityWarning -> warn (nie securitywarning)" 'SecurityWarning' \
    detected_level=warn

# REGRESJA: `\berror\b` trafialo w srodek sciezki URL access logu.
sprawdz "access log z 'error' w URI to NIE blad" 'error-summary.html' \
    detected_level=unknown

sprawdz "linia bez poziomu -> unknown"  'Sending due task'        detected_level=unknown

echo
if [ "$BLEDY" -eq 0 ]; then
    echo "Wszystkie przypadki zgodnie z oczekiwaniem."
else
    echo "Niezgodnosci: $BLEDY"
    echo "Pelny log Alloy: docker logs $KONTENER  (ALLOY_TEST_KEEP=1 zostawia kontener)"
fi
exit "$BLEDY"

#!/usr/bin/env bash
# Asercje to stringi wykonywane przez `eval` w `sprawdz` — pojedyncze cudzyslowy
# sa celowe (rozwiniecie w momencie sprawdzenia), a zmienne czytane tylko w tych
# stringach shellcheck uznaje za nieuzywane.
# shellcheck disable=SC2016,SC2034
# Testy scripts/ssl-fix-chain.sh na lokalnej atrapie PKI (bez sieci).
#
# Root -> posredni -> cert serwera z AIA "CA Issuers" = file://… (curl/wget
# obsluguja file://, wiec testujemy PRAWDZIWA sciezke pobierania). Root podany
# przez BPP_SSL_CA_FILE zamiast systemowego magazynu.
#
# Najwazniejsza asercja to „podrobiony posredni NIE trafia do pliku" — to ona
# uzasadnia pobieranie AIA po http:// (bez niej skrypt dokleilby cokolwiek).
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
SKRYPT="$REPO/scripts/ssl-fix-chain.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  \033[32mOK\033[0m   %s\n' "$1"; }
zle() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
sprawdz() { if eval "$2"; then ok "$1"; else zle "$1"; fi; }
liczba_certow() { grep -c -- '-----BEGIN CERTIFICATE-----' "$1"; }

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo "POMIN: brak curl i wget"; exit 0
fi

# --- atrapa PKI -------------------------------------------------------------
P="$T/pki"; mkdir -p "$P"
ca() {  # nazwa, podpisujacy (pusty = self-signed), dodatkowe rozszerzenia
    local n=$1 by=$2 ext=$3
    openssl req -new -newkey rsa:2048 -nodes -keyout "$P/$n.key" -subj "/CN=$n" \
        -out "$P/$n.csr" 2>/dev/null
    printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n%s\n' \
        "$ext" > "$P/$n.ext"
    if [ -z "$by" ]; then
        openssl x509 -req -in "$P/$n.csr" -signkey "$P/$n.key" -days 30 \
            -extfile "$P/$n.ext" -out "$P/$n.pem" 2>/dev/null
    else
        openssl x509 -req -in "$P/$n.csr" -CA "$P/$by.pem" -CAkey "$P/$by.key" \
            -CAcreateserial -days 30 -extfile "$P/$n.ext" -out "$P/$n.pem" 2>/dev/null
    fi
    openssl x509 -in "$P/$n.pem" -outform DER -out "$P/$n.der"
}
leaf() {  # nazwa, podpisujacy, AIA (pusty = bez AIA)
    local n=$1 by=$2 aia=$3
    openssl req -new -newkey rsa:2048 -nodes -keyout "$P/$n.key" -subj "/CN=$n" \
        -out "$P/$n.csr" 2>/dev/null
    { echo "basicConstraints=CA:FALSE"; [ -n "$aia" ] && echo "authorityInfoAccess=caIssuers;URI:$aia"; } \
        > "$P/$n.ext"
    openssl x509 -req -in "$P/$n.csr" -CA "$P/$by.pem" -CAkey "$P/$by.key" \
        -CAcreateserial -days 30 -extfile "$P/$n.ext" -out "$P/$n.pem" 2>/dev/null
}

ca root "" ""
ca posredni root "authorityInfoAccess=caIssuers;URI:file://$P/root.der"
leaf serwer posredni "file://$P/posredni.der"
# dwa poziomy: root -> p1 -> p2 -> serwer2 (AIA serwer2 -> p2, AIA p2 -> p1)
ca p1 root "authorityInfoAccess=caIssuers;URI:file://$P/root.der"
ca p2 p1 "authorityInfoAccess=caIssuers;URI:file://$P/p1.der"
leaf serwer2 p2 "file://$P/p2.der"
leaf bezaia posredni ""
# podrobka: ta sama nazwa CN=posredni, ale inny klucz i NIEZAUFANY root
ca obcyroot "" ""
mv "$P/posredni.pem" "$P/posredni.prawdziwy.pem"; mv "$P/posredni.key" "$P/posredni.prawdziwy.key"
mv "$P/posredni.der" "$P/posredni.prawdziwy.der"
ca posredni obcyroot ""
mv "$P/posredni.der" "$P/podrobka.der"
mv "$P/posredni.prawdziwy.pem" "$P/posredni.pem"; mv "$P/posredni.prawdziwy.key" "$P/posredni.key"
mv "$P/posredni.prawdziwy.der" "$P/posredni.der"
leaf ofiara posredni "file://$P/podrobka.der"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$P/snake.key" -subj "/CN=snake" \
    -days 30 -out "$P/snake.pem" 2>/dev/null

export BPP_SSL_CA_FILE="$P/root.pem"

nowy_config() {  # -> katalog konfiguracyjny z ssl/<host>/cert.pem
    local d="$T/cfg-$1"; rm -rf "$d"; mkdir -p "$d/ssl"; echo "$d"
}
umiesc() { mkdir -p "$1/ssl/$2"; cat "${@:3}" > "$1/ssl/$2/cert.pem"; }

echo "ssl-fix-chain.sh:"

# 1. sam cert serwera -> doklejony posredni, bez roota, kopia, weryfikacja
C=$(nowy_config 1); umiesc "$C" bpp.example.org "$P/serwer.pem"
chmod 0640 "$C/ssl/bpp.example.org/cert.pem"
bash "$SKRYPT" "$C/ssl" >/dev/null 2>&1; rc=$?
F="$C/ssl/bpp.example.org/cert.pem"
sprawdz "brak posredniego -> naprawa, exit 0" '[ $rc -eq 0 ]'
sprawdz "plik ma teraz 2 certy (bez roota)" '[ "$(liczba_certow "$F")" = 2 ]'
sprawdz "lancuch weryfikuje sie do roota" \
    'openssl verify -CAfile "$P/root.pem" -untrusted "$F" "$P/serwer.pem" >/dev/null 2>&1'
sprawdz "leaf zostaje pierwszy (nginx wymaga)" \
    '[ "$(openssl x509 -in "$F" -noout -subject)" = "$(openssl x509 -in "$P/serwer.pem" -noout -subject)" ]'
sprawdz "zostaje kopia oryginalu" 'ls "$C"/ssl/bpp.example.org/cert.pem.bez-lancucha-* >/dev/null 2>&1'
sprawdz "tryb pliku zachowany (0640)" '[ "$(stat -c %a "$F" 2>/dev/null || stat -f %Lp "$F")" = 640 ]'

# 2. drugi przebieg = nic do roboty (idempotencja)
przed=$(cat "$F"); bash "$SKRYPT" "$C/ssl" >/dev/null 2>&1
sprawdz "drugi przebieg niczego nie zmienia" '[ "$(cat "$F")" = "$przed" ]'
sprawdz "drugi przebieg nie robi kolejnej kopii" \
    '[ "$(ls "$C"/ssl/bpp.example.org/ | grep -c bez-lancucha)" = 1 ]'

# 3. dwa poziomy posrednich
C=$(nowy_config 3); umiesc "$C" h2 "$P/serwer2.pem"
bash "$SKRYPT" "$C/ssl" >/dev/null 2>&1
sprawdz "dwa poziomy: dociaga p2 i p1 (3 certy)" '[ "$(liczba_certow "$C/ssl/h2/cert.pem")" = 3 ]'

# 4. snakeoil (self-signed) -> nietkniety, bez kopii
C=$(nowy_config 4); cp "$P/snake.pem" "$C/ssl/cert.pem"
bash "$SKRYPT" "$C/ssl" >/dev/null 2>&1; rc=$?
sprawdz "snakeoil pominiety (exit 0, bez zmian)" \
    '[ $rc -eq 0 ] && cmp -s "$P/snake.pem" "$C/ssl/cert.pem" && ! ls "$C"/ssl/*.bez-lancucha-* >/dev/null 2>&1'

# 5. brak AIA -> bez zmian; tryb domyslny exit 1, --auto exit 0
C=$(nowy_config 5); umiesc "$C" x "$P/bezaia.pem"
bash "$SKRYPT" "$C/ssl" >/dev/null 2>&1; rc=$?
sprawdz "brak AIA: exit 1 w trybie domyslnym" '[ $rc -eq 1 ]'
sprawdz "brak AIA: plik bez zmian" 'cmp -s "$P/bezaia.pem" "$C/ssl/x/cert.pem"'
bash "$SKRYPT" --auto "$C/ssl" >/dev/null 2>&1; rc=$?
sprawdz "brak AIA: --auto zawsze exit 0 (nie blokuje make up)" '[ $rc -eq 0 ]'

# 6. PODROBKA: AIA wskazuje na posredni z niezaufanego roota -> NIE doklejamy
C=$(nowy_config 6); umiesc "$C" v "$P/ofiara.pem"
bash "$SKRYPT" "$C/ssl" >/dev/null 2>&1; rc=$?
sprawdz "podrobiony posredni NIE trafia do pliku" 'cmp -s "$P/ofiara.pem" "$C/ssl/v/cert.pem"'
sprawdz "podrobka: exit 1" '[ $rc -eq 1 ]'

# 7. --sprawdz niczego nie zapisuje
C=$(nowy_config 7); umiesc "$C" s "$P/serwer.pem"
out=$(bash "$SKRYPT" --sprawdz "$C/ssl" 2>&1)
sprawdz "--sprawdz: plik bez zmian" 'cmp -s "$P/serwer.pem" "$C/ssl/s/cert.pem"'
sprawdz "--sprawdz: raportuje niekompletny lancuch" 'echo "$out" | grep -q NIEKOMPLETNY'

# 8. kompletny od poczatku -> bez zmian, bez kopii
C=$(nowy_config 8); umiesc "$C" k "$P/serwer.pem" "$P/posredni.pem"
cp "$C/ssl/k/cert.pem" "$T/k.przed"
bash "$SKRYPT" "$C/ssl" >/dev/null 2>&1
sprawdz "kompletny lancuch: bez zmian i bez kopii" \
    'cmp -s "$T/k.przed" "$C/ssl/k/cert.pem" && ! ls "$C"/ssl/k/*.bez-lancucha-* >/dev/null 2>&1'

# 9. plik bez koncowego \n -> END i BEGIN nie sklejaja sie
C=$(nowy_config 9); mkdir -p "$C/ssl/n"; printf '%s' "$(cat "$P/serwer.pem")" > "$C/ssl/n/cert.pem"
bash "$SKRYPT" "$C/ssl" >/dev/null 2>&1
sprawdz "brak koncowego newline: dwa poprawne certy" \
    '[ "$(liczba_certow "$C/ssl/n/cert.pem")" = 2 ] && ! grep -q "END CERTIFICATE-----.*BEGIN" "$C/ssl/n/cert.pem"'

# 10. brak katalogu ssl/ -> --auto cicho exit 0
bash "$SKRYPT" --auto "$T/nie-ma" >/dev/null 2>&1; rc=$?
sprawdz "brak katalogu: --auto exit 0" '[ $rc -eq 0 ]'

echo "ssl-fix-chain: $PASS OK, $FAIL FAIL"
[ "$FAIL" -eq 0 ]

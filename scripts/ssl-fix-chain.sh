#!/usr/bin/env bash
# ssl-fix-chain.sh — uzupelnia brakujace certyfikaty posrednie w recznie
# wgranych certach (ssl/cert.pem, ssl/<host>/cert.pem).
#
# GDZIE CHODZI: w kontenerze `webserver-init` (root), przy kazdym `make up`,
# PRZED ustawieniem uprawnien — bo na instalacji katalog ssl/ ma 0750
# root:nginx i operator na hoscie nie moze go nawet wylistowac. Recznie:
# `make ssl-napraw-lancuch` (ten sam kontener + przeladowanie nginksa).
#
# PO CO: certy komercyjne (np. Certum) bywaja wgrywane jako SAM certyfikat
# serwera, bez posredniego. Przegladarki desktopowe zwykle to maskuja (cache
# posrednich, AIA fetching), ale curl/Python/Android/harvestery dostaja
# `unable to get local issuer certificate`. bpp-updater oznacza takie hosty
# jako „niekompletny cert SSL".
#
# JAK: dla kazdego pliku, ktorego lancuch NIE weryfikuje sie systemowym
# magazynem CA, bierzemy URL „CA Issuers" z rozszerzenia AIA ostatniego certu,
# pobieramy posredni, doklejamy i powtarzamy (max 4 poziomy). Plik nadpisujemy
# WYLACZNIE gdy pelny lancuch przejdzie `openssl verify` — dlatego pobieranie
# po http:// (tak publikuja AIA wszystkie CA) jest bezpieczne: podrobiony
# posredni nie przejdzie weryfikacji. Root CA NIE jest doklejany (jest
# w magazynie klienta; doklejenie tylko powieksza handshake).
#
# Self-signed (snakeoil) i certy juz kompletne sa pomijane. Oryginal zostaje
# obok jako cert.pem.bez-lancucha-<TS>.
#
# Uzycie:
#   ssl-fix-chain.sh [--auto|--sprawdz] [SSL_DIR]
#     SSL_DIR      katalog z cert.pem / <host>/cert.pem (w kontenerze:
#                  /etc/ssl/private; domyslnie $BPP_CONFIGS_DIR/ssl)
#     (domyslnie)  napraw; exit 1, gdy ktoregos pliku nie dalo sie naprawic
#     --auto       jak wyzej, ale ZAWSZE exit 0 (make up — nie blokuje deployu)
#     --sprawdz    tylko raport, nic nie zapisuje
#
# Zmienne (glownie dla testow):
#   BPP_SSL_CA_FILE   magazyn CA zamiast systemowego (openssl verify -CAfile)
#   BPP_SSL_FETCH_TIMEOUT  limit pobrania jednego certu w s (domyslnie 15)
set -uo pipefail

TRYB=napraw
case "${1:-}" in
    --auto) TRYB=auto; shift ;;
    --sprawdz) TRYB=sprawdz; shift ;;
esac
SSL_DIR="${1:-${BPP_CONFIGS_DIR:+$BPP_CONFIGS_DIR/ssl}}"
TIMEOUT="${BPP_SSL_FETCH_TIMEOUT:-15}"

info() { echo "[ssl-lancuch] $*"; }
warn() { echo "[ssl-lancuch] OSTRZEZENIE: $*" >&2; }

# fail-open w trybie auto: brak narzedzi/katalogu nie moze wywrocic `make up`
koniec() {
    if [ "$TRYB" = auto ]; then exit 0; fi
    exit "$1"
}

if [ -z "$SSL_DIR" ] || [ ! -d "$SSL_DIR" ]; then
    [ "$TRYB" = auto ] || warn "brak katalogu z certyfikatami: '${SSL_DIR:-<nieustawiony BPP_CONFIGS_DIR>}'"
    koniec 0
fi
if ! command -v openssl >/dev/null 2>&1; then
    warn "brak openssl — pomijam sprawdzanie lancucha certyfikatow"
    koniec 0
fi

pobierz() {  # URL -> stdout
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time "$TIMEOUT" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T "$TIMEOUT" -O - "$1"
    else
        return 127
    fi
}

verify_args=()
if [ -n "${BPP_SSL_CA_FILE:-}" ]; then
    verify_args=(-CAfile "$BPP_SSL_CA_FILE")
fi

# leaf + posrednie -> 0, gdy lancuch weryfikuje sie do zaufanego roota
lancuch_ok() {  # $1 = leaf.pem, $2 = posrednie.pem (moze byc pusty)
    if [ -s "$2" ]; then
        openssl verify "${verify_args[@]}" -untrusted "$2" "$1" >/dev/null 2>&1
    else
        openssl verify "${verify_args[@]}" "$1" >/dev/null 2>&1
    fi
}

self_signed() {  # $1 = cert.pem
    [ "$(openssl x509 -in "$1" -noout -subject 2>/dev/null | sed 's/^subject=//')" = \
      "$(openssl x509 -in "$1" -noout -issuer 2>/dev/null | sed 's/^issuer=//')" ]
}

aia_url() {  # $1 = cert.pem -> URL "CA Issuers" albo nic
    openssl x509 -in "$1" -noout -text 2>/dev/null \
        | sed -n 's/^ *CA Issuers - URI:\(.*\)$/\1/p' | head -n 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

naprawione=0
nienaprawione=0
TS=$(date +%Y%m%d-%H%M%S)

shopt -s nullglob
for plik in "$SSL_DIR/cert.pem" "$SSL_DIR"/*/cert.pem; do
    [ -f "$plik" ] || continue
    nazwa=ssl/${plik#"$SSL_DIR"/}
    praca="$TMP/$(echo "$nazwa" | tr '/' '_')"
    mkdir -p "$praca"

    # rozbij plik na pojedyncze certy: c1.pem (leaf), c2.pem, ...
    awk -v d="$praca" '
        /-----BEGIN CERTIFICATE-----/ { n++; f = d "/c" n ".pem" }
        f { print > f }
        /-----END CERTIFICATE-----/ { close(f); f = "" }
    ' "$plik"
    if [ ! -s "$praca/c1.pem" ]; then
        warn "$nazwa: brak certyfikatu PEM w pliku — pomijam"
        continue
    fi
    if self_signed "$praca/c1.pem"; then
        continue  # snakeoil / testowy — nie ma czego uzupelniac
    fi

    posrednie="$praca/posrednie.pem"
    : > "$posrednie"
    for c in "$praca"/c[0-9]*.pem; do
        [ "$c" = "$praca/c1.pem" ] || cat "$c" >> "$posrednie"
    done

    if lancuch_ok "$praca/c1.pem" "$posrednie"; then
        continue  # kompletny — cisza
    fi

    # doklejamy kolejne posrednie po AIA, poczawszy od ostatniego certu w pliku
    ostatni="$praca/c$(grep -c -- '-----BEGIN CERTIFICATE-----' "$plik").pem"
    dodane="$praca/dodane.pem"
    : > "$dodane"
    ok=0
    powod="lancuch nadal sie nie weryfikuje"
    for _ in 1 2 3 4; do
        url=$(aia_url "$ostatni")
        if [ -z "$url" ]; then
            powod="ostatni certyfikat nie ma adresu AIA 'CA Issuers'"
            break
        fi
        if [ "$TRYB" = sprawdz ]; then
            powod="brak certyfikatu posredniego (do pobrania: $url)"
            break
        fi
        if ! pobierz "$url" > "$praca/pobrany.raw" 2>/dev/null || [ ! -s "$praca/pobrany.raw" ]; then
            powod="nie udalo sie pobrac $url"
            break
        fi
        nowy="$praca/pobrany.pem"
        # CA publikuja DER (.cer/.crt), czasem PEM albo PKCS#7 (.p7c)
        if ! openssl x509 -inform DER -in "$praca/pobrany.raw" -out "$nowy" 2>/dev/null \
            && ! openssl x509 -inform PEM -in "$praca/pobrany.raw" -out "$nowy" 2>/dev/null \
            && ! { openssl pkcs7 -inform DER -in "$praca/pobrany.raw" -print_certs 2>/dev/null \
                   | openssl x509 -out "$nowy" 2>/dev/null; }; then
            powod="pobrany plik z $url nie jest certyfikatem"
            break
        fi
        if self_signed "$nowy"; then
            break  # dotarlismy do roota — nie doklejamy go
        fi
        cat "$nowy" >> "$posrednie"
        cat "$nowy" >> "$dodane"
        if lancuch_ok "$praca/c1.pem" "$posrednie"; then
            ok=1
            break
        fi
        # kolejna iteracja szuka AIA w wlasnie pobranym; kopia, bo pobrany.pem
        # zostanie nadpisany
        cp "$nowy" "$praca/ostatni.pem"
        ostatni="$praca/ostatni.pem"
    done

    if [ "$ok" = 1 ]; then
        if ! [ -w "$plik" ]; then
            warn "$nazwa: lancuch do uzupelnienia, ale brak prawa zapisu (uruchom jako wlasciciel pliku albo przez sudo)"
            nienaprawione=$((nienaprawione + 1))
            continue
        fi
        cp -p "$plik" "$plik.bez-lancucha-$TS"
        # `cat >` zamiast mv: zachowuje wlasciciela/grupe/tryb pliku (webserver
        # czyta go jako grupa nginx — patrz webserver-init)
        {
            cat "$plik"
            # plik bez koncowego \n skleilby END i BEGIN w jedna linie
            [ -z "$(tail -c1 "$plik")" ] || echo
            cat "$dodane"
        } > "$praca/nowy-cert.pem"
        cat "$praca/nowy-cert.pem" > "$plik"
        info "$nazwa: doklejono $(grep -c 'BEGIN CERTIFICATE' "$dodane") cert. posredni(e) — lancuch kompletny (kopia: $(basename "$plik").bez-lancucha-$TS)"
        naprawione=$((naprawione + 1))
    else
        if [ "$TRYB" = sprawdz ]; then
            info "$nazwa: NIEKOMPLETNY lancuch — $powod"
        else
            warn "$nazwa: nie udalo sie uzupelnic lancucha — $powod. Plik bez zmian."
        fi
        nienaprawione=$((nienaprawione + 1))
    fi
done

if [ "$naprawione" -gt 0 ]; then
    info "naprawiono: $naprawione (nginx wczyta przy starcie; reczna sciezka przeladowuje sama)"
fi
if [ "$nienaprawione" -gt 0 ]; then
    koniec 1
fi
koniec 0

#!/usr/bin/env bash
#
# Wczytanie archiwum obrazow (scripts/images-archive.sh) do lokalnego Dockera
# i weryfikacja z manifestem. `make images-load FILE=...`.
#
# FILE moze wskazywac katalog zestawu (.../obrazy/20261125-014500/), jego
# manifest.txt albo samo archiwum obrazy.tar.gz|.tar.zst (manifest musi lezec
# obok). Dziala na swiezym hoscie, bez .env i bez dzialajacego stacka - stad
# target zdefiniowany w Makefile PRZED `ifdef FIRST_RUN`.
#
# Kolejnosc:
#   1. suma sha256 archiwum == archiwum_sha256 z manifestu (uszkodzony
#      download nie trafia do `docker load`),
#   2. docker load,
#   3. dla KAZDEGO obrazu z manifestu: obraz pod ref_w_archiwum musi miec to
#      samo ID co na zrodle ALBO (inny store Dockera: klasyczny overlay2 vs
#      containerd licza ID inaczej) ten sam odcisk warstw RootFS,
#   4. ref z compose (ref_compose) przepiety na ten obraz - `make up` (NIE
#      `make run`, ten robi pull) znajdzie wszystko lokalnie; tymczasowe tagi
#      bpp-archiwum-* zdjete; obrazy BPP o znanej wersji dostaja tez tag CalVer
#      (instalacje z przypietym DOCKER_VERSION).
#
# Exit: 0 - wszystkie obrazy wczytane i zgodne; 1 - blad / niezgodnosc.

set -euo pipefail

FILE="${FILE:-${1:-}}"
die() { echo "BLAD: $*" >&2; exit 1; }

[ -n "$FILE" ] || die "podaj zestaw: make images-load FILE=.../obrazy/<YYYYMMDD-HHMMSS>"
[ -e "$FILE" ] || die "nie ma: $FILE"
if [ -d "$FILE" ]; then DIR="$FILE"; else DIR="$(dirname "$FILE")"; fi
MANIFEST="$DIR/manifest.txt"
[ -f "$MANIFEST" ] || die "brak $MANIFEST - to nie jest zestaw z images-archive.sh"

mval() { grep -E "^$1=" "$MANIFEST" | tail -1 | cut -d= -f2-; }
ARCH="$DIR/$(mval archiwum)"
[ -f "$ARCH" ] || die "brak archiwum $ARCH (manifest: archiwum=$(mval archiwum))"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-64
    else shasum -a 256 | cut -c1-64; fi
}

echo "Zestaw:   $DIR"
echo "Utworzono: $(mval utworzono)   bpp-deploy: $(mval bpp_deploy_wersja)"

oczekiwana="$(mval archiwum_sha256)"
if [ -n "$oczekiwana" ]; then
    echo "Sprawdzam sume archiwum..."
    [ "$(sha256_of < "$ARCH")" = "$oczekiwana" ] \
        || die "suma sha256 $ARCH nie zgadza sie z manifestem - archiwum uszkodzone (pobierz ponownie)"
fi

echo "docker load -i $ARCH ..."
# docker load sam rozpoznaje gzip i zstd.
docker load -i "$ARCH"

BLEDY=0
while IFS='|' read -r typ ref save_ref id warstwy _dig wersja uslugi; do
    [ "$typ" = obraz ] || continue
    jest="$(docker image inspect --format '{{.Id}}' "$save_ref" 2>/dev/null || true)"
    if [ -z "$jest" ]; then
        echo "  BLAD: $save_ref nie ma w Dockerze po docker load ($uslugi)" >&2
        BLEDY=$((BLEDY + 1)); continue
    fi
    if [ "$jest" != "$id" ]; then
        odcisk="$(docker image inspect --format '{{range .RootFS.Layers}}{{.}} {{end}}' "$save_ref" | sha256_of)"
        if [ "$odcisk" != "$warstwy" ]; then
            echo "  BLAD: $save_ref ma inna zawartosc niz w manifescie (id $jest, oczekiwane $id)" >&2
            BLEDY=$((BLEDY + 1)); continue
        fi
    fi
    if [ "$save_ref" != "$ref" ]; then
        docker tag "$save_ref" "$ref"
        docker rmi "$save_ref" >/dev/null 2>&1 || true
    fi
    repo="${ref%%@*}"
    case "${repo##*/}" in *:*) repo="${repo%:*}" ;; esac
    case "$repo:$wersja" in
        iplweb/*:[0-9][0-9][0-9][0-9][0-9][0-9].*) docker tag "$ref" "$repo:$wersja" ;;
    esac
    echo "  OK: $ref (wersja ${wersja}, uslugi: $uslugi)"
done < "$MANIFEST"

if ! grep -q '^obraz|' "$MANIFEST"; then
    die "manifest nie zawiera zadnego obrazu"
fi
if [ "$BLEDY" -gt 0 ]; then
    die "$BLEDY obraz(y) niezgodne z manifestem"
fi
echo "Wszystkie obrazy z manifestu wczytane i zgodne."

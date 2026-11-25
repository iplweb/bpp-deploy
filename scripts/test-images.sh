#!/usr/bin/env bash
#
# Testy archiwum obrazow: scripts/images-archive.sh (`make images-save`, krok 2c
# nocnego cyklu) i scripts/images-load.sh (`make images-load`).
#
# Uruchamia PRAWDZIWE skrypty z atrapa `docker` (stan w plikach tekstowych)
# i `df` w PATH; git, gzip i sha256 sa prawdziwe - bundle jest naprawde
# klonowany, archiwum naprawde sprawdzane `gzip -t`. Bez sieci i bez Dockera.
#
# Uruchomienie: `make test-images` albo `bash scripts/test-images.sh`.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SAVE="$REPO_DIR/scripts/images-archive.sh"
LOAD="$REPO_DIR/scripts/images-load.sh"

T="$(mktemp -d -t bpp-images-test-XXXXXX)"
# shellcheck disable=SC2317  # wywolywane przez trap
cleanup() { rm -rf "$T"; }
trap cleanup EXIT

green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
PASS=0; FAIL=0
pass() { green "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { red   "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (oczekiwane '$1', jest '$2')"; fi; }
assert_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then pass "$3"; else fail "$3 (brak '$2' w: $1)"; fi
}
assert_not_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then fail "$3 ('$2' nie powinno wystapic)"; else pass "$3"; fi
}

# --------------------------------------------------------------------------
# Atrapy
# --------------------------------------------------------------------------
BIN="$T/bin"; M="$T/mock"
mkdir -p "$BIN" "$M"

# Stan:
#   $M/containers  cid|usluga|ref|id         (dzialajace kontenery projektu)
#   $M/images      ref|id|rozmiar|warstwy|repo_digests
cat > "$BIN/docker" <<'MOCK'
#!/usr/bin/env bash
echo "docker $*" >> "$M/calls"
img_find() {   # <ref-albo-id> -> linia z images
    case "$1" in
        sha256:*) awk -F'|' -v k="$1" '$2 == k { print; exit }' "$M/images" ;;
        *)        awk -F'|' -v k="$1" '$1 == k { print; exit }' "$M/images" ;;
    esac
}
case "$1" in
    ps) cut -d'|' -f1 "$M/containers" ;;
    inspect)
        shift; shift; shift   # --format <fmt>
        for c in "$@"; do
            awk -F'|' -v c="$c" '$1 == c { print $2 "|" $3 "|" $4 }' "$M/containers"
        done ;;
    image)
        case "$2" in
            inspect)
                fmt="$4"; key="$5"
                line="$(img_find "$key")"
                [ -n "$line" ] || { echo "Error: No such image: $key" >&2; exit 1; }
                case "$fmt" in
                    *Size*)        echo "$line" | cut -d'|' -f3 ;;
                    *RepoDigests*) echo "$line" | cut -d'|' -f5 ;;
                    *RootFS*)      echo "$line" | cut -d'|' -f4 ;;
                    *)             echo "$line" | cut -d'|' -f2 ;;
                esac ;;
            ls)
                repo="${!#}"
                awk -F'|' -v r="$repo:" 'index($1, r) == 1 { print $1 "|" $2 }' "$M/images" ;;
        esac ;;
    tag)
        line="$(img_find "$2")"
        [ -n "$line" ] || exit 1
        awk -F'|' -v d="$3" '$1 != d' "$M/images" > "$M/images.n"; mv "$M/images.n" "$M/images"
        echo "$3|$(echo "$line" | cut -d'|' -f2-)" >> "$M/images" ;;
    rmi)
        awk -F'|' -v d="$2" '$1 != d' "$M/images" > "$M/images.n"; mv "$M/images.n" "$M/images" ;;
    save)
        [ "${MOCK_SAVE_FAIL:-0}" = 1 ] && { echo "save padl" >&2; exit 1; }
        shift; printf 'ARCHIWUM %s\n' "$*"; head -c 4096 /dev/urandom ;;
    load)
        [ -f "$M/load-add" ] && cat "$M/load-add" >> "$M/images"
        echo "Loaded image(s)" ;;
    *) exit 1 ;;
esac
MOCK

cat > "$BIN/df" <<'MOCK'
#!/usr/bin/env bash
if [ -n "${MOCK_DF_FREE_KB:-}" ]; then
    echo "Filesystem 1024-blocks Used Available Capacity Mounted"
    echo "/dev/x 100000000 1 $MOCK_DF_FREE_KB 1% /"
    exit 0
fi
for d in /bin/df /usr/bin/df; do [ -x "$d" ] && exec "$d" "$@"; done
exit 127
MOCK
chmod +x "$BIN"/*

A_OLD="sha256:aaaa000000000000000000000000000000000000000000000000000000000001"
A_NEW="sha256:aaaa000000000000000000000000000000000000000000000000000000000002"
A_NEW2="sha256:aaaa000000000000000000000000000000000000000000000000000000000003"
W="sha256:bbbb000000000000000000000000000000000000000000000000000000000001"
D="sha256:cccc000000000000000000000000000000000000000000000000000000000001"
N="sha256:dddd000000000000000000000000000000000000000000000000000000000001"

reset_state() {
    : > "$M/calls"; rm -f "$M/load-add"
    cat > "$M/images" <<EOF
iplweb/bpp_appserver:latest|$A_OLD|1000000|sha256:l1 sha256:l2 |iplweb/bpp_appserver@sha256:da01
iplweb/bpp_workerserver:latest|$W|1000000|sha256:l1 sha256:l3 |iplweb/bpp_workerserver@sha256:dw01
postgres:18.4|$D|500000|sha256:p1 |postgres@sha256:dp01
netdata/netdata:v2.10.3|$N|500000|sha256:n1 |netdata/netdata@sha256:dn01
EOF
    cat > "$M/containers" <<EOF
c1|appserver|iplweb/bpp_appserver:latest|$A_OLD
c2|workerserver|iplweb/bpp_workerserver:latest|$W
c3|workerserver-status|iplweb/bpp_workerserver:latest|$W
c4|dbserver|postgres:18.4|$D
c5|netdata|netdata/netdata:v2.10.3|$N
EOF
}

# Prawdziwe repo gita jako zrodlo bundla.
GITREPO="$T/repo"
git init -q -b main "$GITREPO"
git -C "$GITREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$GITREPO" tag 2026.11.01
GIT_HEAD="$(git -C "$GITREPO" rev-parse HEAD)"

BK="$T/backup"
run_save() {   # argumenty dla save; wynik: SAVE_RC, SAVE_OUT, SAVE_ERR
    mkdir -p "$BK"
    set +e
    SAVE_OUT="$(env PATH="$BIN:$PATH" M="$M" \
        COMPOSE_PROJECT_NAME=testproj \
        BPP_BACKUP_DIR="$BK" BPP_REPO_DIR="${REPO_ENV-$GITREPO}" \
        DJANGO_BPP_BACKUP_IMAGES_KEEP_LAST="${KEEP_ENV:-2}" \
        MOCK_SAVE_FAIL="${MOCK_SAVE_FAIL:-0}" MOCK_DF_FREE_KB="${MOCK_DF_FREE_KB:-}" \
        BPP_IMAGES_COMPRESS=gzip \
        bash "$SAVE" save "$@" 2>"$T/save.err")"
    SAVE_RC=$?
    set -e
    SAVE_ERR="$(cat "$T/save.err")"
}
sets() { find "$BK/obrazy" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sed 's:.*/::' | sort; }
nsets() { sets | grep -c . || true; }
newest() { sets | sed -n '$p'; }

# --------------------------------------------------------------------------
echo "=== 1. Pierwszy zestaw: obrazy dzialajacych kontenerow, bez monitoringu ==="
reset_state
run_save
assert_eq 0 "$SAVE_RC" "save konczy sie sukcesem"
assert_contains "$SAVE_OUT" "NOWE $BK/obrazy/" "ostatnia linia: NOWE <katalog>"
S1="$(newest)"
MAN="$BK/obrazy/$S1/manifest.txt"
assert_eq 1 "$(nsets)" "jeden zestaw"
if gzip -t "$BK/obrazy/$S1/obrazy.tar.gz" 2>/dev/null; then pass "archiwum to poprawny gzip"; else fail "archiwum to poprawny gzip"; fi
MANT="$(cat "$MAN")"
assert_contains "$MANT" "obraz|iplweb/bpp_appserver:latest|iplweb/bpp_appserver:latest|$A_OLD|" "manifest: appserver z ID dzialajacego kontenera"
assert_contains "$MANT" "|workerserver,workerserver-status" "jeden obraz dla dwoch uslug"
assert_not_contains "$MANT" "netdata" "monitoring pominiety domyslnie"
assert_not_contains "$(grep '^docker save' "$M/calls")" "netdata" "docker save bez obrazu monitoringu"
assert_eq 1 "$(grep -c '^docker save' "$M/calls")" "JEDEN docker save wszystkich obrazow (wspolne warstwy)"
assert_contains "$MANT" "iplweb/bpp_appserver@sha256:da01" "manifest: repo digest"
assert_contains "$MANT" "archiwum_sha256=" "manifest: suma archiwum"
assert_contains "$MANT" "bpp_deploy_commit=$GIT_HEAD" "manifest: commit bpp-deploy"
assert_contains "$MANT" "bundle=bpp-deploy.bundle" "manifest: bundle"
if git clone -q "$BK/obrazy/$S1/bpp-deploy.bundle" "$T/klon" 2>/dev/null \
        && [ "$(git -C "$T/klon" rev-parse HEAD)" = "$GIT_HEAD" ] \
        && git -C "$T/klon" rev-parse -q --verify refs/tags/2026.11.01 >/dev/null; then
    pass "bundle klonuje sie do tego samego commitu, z tagami"
else
    fail "bundle klonuje sie do tego samego commitu, z tagami"
fi
if find "$BK/obrazy" -name '.*.tmp' | grep -q .; then fail "brak katalogu tymczasowego"; else pass "brak katalogu tymczasowego"; fi
if [ -d "$BK/obrazy/.lock" ]; then fail "blokada zwolniona"; else pass "blokada zwolniona"; fi

echo "=== 2. Te same obrazy: bez nowego archiwum ==="
: > "$M/calls"
sleep 1
run_save
assert_eq 0 "$SAVE_RC" "rc=0 bez zmian"
assert_contains "$SAVE_OUT" "BEZ-ZMIAN" "wynik BEZ-ZMIAN"
assert_eq 1 "$(nsets)" "nadal jeden zestaw"
assert_eq 0 "$(grep -c '^docker save' "$M/calls" || true)" "bez docker save"

echo "=== 3. Zmiana obrazu appservera: nowy zestaw; rotacja do KEEP_LAST=2 ==="
sed -i.bak "s/$A_OLD/$A_NEW/g" "$M/images" "$M/containers"
sleep 1; run_save
assert_contains "$SAVE_OUT" "NOWE" "nowy obraz -> NOWE"
assert_eq 2 "$(nsets)" "dwa zestawy"
sed -i.bak "s/$A_NEW/$A_NEW2/g" "$M/images" "$M/containers"
sleep 1; run_save
assert_eq 2 "$(nsets)" "trzeci zestaw -> rotacja zostawia 2"
if sets | grep -qx "$S1"; then fail "najstarszy zestaw usuniety"; else pass "najstarszy zestaw usuniety"; fi

echo "=== 4. --force i --monitoring ==="
sleep 1; run_save --force
assert_contains "$SAVE_OUT" "NOWE" "--force tworzy zestaw mimo braku zmian"
sleep 1; run_save --monitoring
assert_contains "$(cat "$BK/obrazy/$(newest)/manifest.txt")" "netdata/netdata:v2.10.3" "--monitoring dolacza netdata"
assert_contains "$(cat "$BK/obrazy/$(newest)/manifest.txt")" "monitoring=1" "manifest: monitoring=1"

echo "=== 5. KEEP_LAST smieciowe -> 2 ==="
sleep 1; KEEP_ENV=abc run_save --force
assert_eq 2 "$(nsets)" "KEEP_LAST=abc traktowane jak 2"

echo "=== 6. Lokalny tag wskazuje juz inny obraz niz dzialajacy (make pull bez recreate) ==="
reset_state; rm -rf "$BK"
# Kontener chodzi na A_OLD, ale :latest po pullu wskazuje A_NEW; A_OLD ma tag CalVer.
cat > "$M/images" <<EOF
iplweb/bpp_appserver:latest|$A_NEW|1000000|sha256:l9 |iplweb/bpp_appserver@sha256:da09
iplweb/bpp_appserver:202611.1407|$A_OLD|1000000|sha256:l1 sha256:l2 |iplweb/bpp_appserver@sha256:da01
iplweb/bpp_workerserver:latest|$W|1000000|sha256:l1 sha256:l3 |iplweb/bpp_workerserver@sha256:dw01
postgres:18.4|$D|500000|sha256:p1 |postgres@sha256:dp01
EOF
run_save
S6="$(newest)"
TMPTAG="iplweb/bpp_appserver:bpp-archiwum-aaaa00000000"
assert_contains "$(cat "$BK/obrazy/$S6/manifest.txt")" "obraz|iplweb/bpp_appserver:latest|$TMPTAG|$A_OLD|" "zapisany DZIALAJACY obraz pod tymczasowym tagiem"
assert_contains "$(grep '^docker save' "$M/calls")" "$TMPTAG" "docker save po tymczasowym tagu"
assert_contains "$(cat "$BK/obrazy/$S6/manifest.txt")" "|202611.1407|appserver" "wersja z lokalnego tagu CalVer tego samego obrazu"
assert_contains "$(cat "$M/calls")" "docker rmi $TMPTAG" "tymczasowy tag zdjety"
if grep -q "^$TMPTAG|" "$M/images"; then fail "tymczasowego tagu nie ma po zapisie"; else pass "tymczasowego tagu nie ma po zapisie"; fi

echo "=== 7. Brak appservera -> exit 5, nic nie zapisane ==="
reset_state; rm -rf "$BK"
grep -v '|appserver|' "$M/containers" > "$M/c.n"; mv "$M/c.n" "$M/containers"
run_save
assert_eq 5 "$SAVE_RC" "exit 5 bez appservera"
assert_contains "$SAVE_ERR" "nie dziala usluga appserver" "komunikat wskazuje brakujaca usluge"
assert_eq 0 "$(nsets)" "zero zestawow"

echo "=== 8. Za malo miejsca -> exit 6, nic nie zapisane ==="
reset_state; rm -rf "$BK"
MOCK_DF_FREE_KB=10 run_save
assert_eq 6 "$SAVE_RC" "exit 6 przy braku miejsca"
assert_eq 0 "$(nsets)" "zero zestawow"
assert_eq 0 "$(grep -c '^docker save' "$M/calls" || true)" "bez docker save"

echo "=== 9. docker save pada -> exit 1, bez polowicznego zestawu i tymczasowych tagow ==="
reset_state; rm -rf "$BK"
sed -i.bak "s#^iplweb/bpp_appserver:latest|$A_OLD|#iplweb/bpp_appserver:latest|$A_NEW|#" "$M/images"
echo "iplweb/bpp_appserver:202611.1407|$A_OLD|1000000|sha256:l1 |-" >> "$M/images"
MOCK_SAVE_FAIL=1 run_save
assert_eq 1 "$SAVE_RC" "exit 1 przy bledzie docker save"
assert_eq 0 "$(nsets)" "zero zestawow"
if find "$BK/obrazy" -name '.*.tmp' | grep -q .; then fail "katalog tymczasowy sprzatniety"; else pass "katalog tymczasowy sprzatniety"; fi
if grep -q 'bpp-archiwum' "$M/images"; then fail "tymczasowy tag zdjety po bledzie"; else pass "tymczasowy tag zdjety po bledzie"; fi

echo "=== 10. Brak repozytorium -> zestaw bez bundla ==="
reset_state; rm -rf "$BK"
REPO_ENV="$T/nie-ma" run_save
assert_eq 0 "$SAVE_RC" "rc=0 bez repo"
assert_contains "$(cat "$BK/obrazy/$(newest)/manifest.txt")" "bundle=brak" "manifest: bundle=brak"

# --------------------------------------------------------------------------
echo "=== 11. images-load: zgodne ID ==="
reset_state; rm -rf "$BK"; run_save
SET="$BK/obrazy/$(newest)"
run_load() {
    set +e
    LOAD_OUT="$(env PATH="$BIN:$PATH" M="$M" bash "$LOAD" "$1" 2>&1)"
    LOAD_RC=$?
    set -e
}
: > "$M/calls"
run_load "$SET"
assert_eq 0 "$LOAD_RC" "load: rc=0"
assert_contains "$(cat "$M/calls")" "docker load -i $SET/obrazy.tar.gz" "docker load wolany z archiwum"
run_load "$SET/obrazy.tar.gz"
assert_eq 0 "$LOAD_RC" "load: sciezka do archiwum tez dziala"

echo "=== 12. images-load: uszkodzone archiwum -> odmowa PRZED docker load ==="
cp -R "$SET" "$T/zly"; printf 'x' >> "$T/zly/obrazy.tar.gz"
: > "$M/calls"
run_load "$T/zly"
assert_eq 1 "$LOAD_RC" "load: rc=1 przy zlej sumie"
assert_eq 0 "$(grep -c 'docker load' "$M/calls" || true)" "docker load NIE wolany"

echo "=== 13. images-load: inny store (inne ID), te same warstwy -> OK ==="
sed -i.bak "s#|$A_OLD|#|sha256:inny-store-1|#" "$M/images"
run_load "$SET"
assert_eq 0 "$LOAD_RC" "load: inne ID, te same warstwy -> rc=0"

echo "=== 14. images-load: inne warstwy -> blad ==="
sed -i.bak "s#|sha256:inny-store-1|1000000|sha256:l1 sha256:l2 |#|sha256:inny-store-1|1000000|sha256:zle |#" "$M/images"
run_load "$SET"
assert_eq 1 "$LOAD_RC" "load: inna zawartosc -> rc=1"
assert_contains "$LOAD_OUT" "inna zawartosc" "load: komunikat o niezgodnosci"

echo "=== 15. images-load: tymczasowy tag -> ref z compose + tag CalVer ==="
reset_state; rm -rf "$BK"
cat > "$M/images" <<EOF
iplweb/bpp_appserver:latest|$A_NEW|1000000|sha256:l9 |-
iplweb/bpp_appserver:202611.1407|$A_OLD|1000000|sha256:l1 sha256:l2 |-
iplweb/bpp_workerserver:latest|$W|1000000|sha256:l1 sha256:l3 |-
postgres:18.4|$D|500000|sha256:p1 |-
EOF
run_save
SET="$BK/obrazy/$(newest)"
# Swiezy host: po docker load jest tylko to, co bylo w archiwum.
cat > "$M/images" <<EOF
iplweb/bpp_workerserver:latest|$W|1000000|sha256:l1 sha256:l3 |-
postgres:18.4|$D|500000|sha256:p1 |-
EOF
echo "iplweb/bpp_appserver:bpp-archiwum-aaaa00000000|$A_OLD|1000000|sha256:l1 sha256:l2 |-" > "$M/load-add"
: > "$M/calls"
run_load "$SET"
assert_eq 0 "$LOAD_RC" "load: rc=0"
assert_contains "$(cat "$M/calls")" "docker tag iplweb/bpp_appserver:bpp-archiwum-aaaa00000000 iplweb/bpp_appserver:latest" "ref z compose przepiety na wczytany obraz"
assert_contains "$(cat "$M/calls")" "docker tag iplweb/bpp_appserver:latest iplweb/bpp_appserver:202611.1407" "obraz BPP dostaje tez tag CalVer"
assert_eq "$A_OLD" "$(awk -F'|' '$1 == "iplweb/bpp_appserver:latest" { print $2 }' "$M/images")" ":latest wskazuje obraz z archiwum"

echo ""
echo "========================================"
if [ "$FAIL" -gt 0 ]; then
    red "  test-images: $PASS passed, $FAIL failed"
    exit 1
fi
green "  test-images: $PASS passed, 0 failed"

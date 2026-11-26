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
#   $M/images      ref|id|rozmiar|warstwy|repo_digests[|historia]
#                  historia = rozmiary z `docker history`, od NAJNOWSZEGO
#                  (0 = wpis bez warstwy, np. ENV); brak pola = pusta historia
#                  -> skrypt nie sparuje warstw i liczy caly `.Size`.
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
    history)
        line="$(img_find "${!#}")"
        [ -n "$line" ] || { echo "Error: No such image: ${!#}" >&2; exit 1; }
        echo "$line" | cut -d'|' -f6 | tr ' ' '\n' | grep . || true ;;
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
# Zawsze atrapa (domyslnie 100 GB, 90 GB wolne): prawdziwy df maszyny CI
# moglby zapalic rezerwe (>80% zajete na runnerze) i wywrocic testy.
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/x ${MOCK_DF_SIZE_KB:-104857600} 1 ${MOCK_DF_FREE_KB:-94371840} 1% /"
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
        MOCK_DF_SIZE_KB="${MOCK_DF_SIZE_KB:-}" \
        DJANGO_BPP_BACKUP_IMAGES_MIN_FREE_GB="${MIN_FREE_ENV-}" \
        DJANGO_BPP_BACKUP_IMAGES_MAX_USED_PCT="${MAX_PCT_ENV-}" \
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

echo "=== 8b. Rezerwa dysku: zapis pominiety (exit 8), sam rusza, gdy jest miejsce ==="
GB=1048576
# 100 GB dysku, 12 GB wolne: po zapisie >10 GB, ale zajete 88% > 80% -> pomin.
reset_state; rm -rf "$BK"
MOCK_DF_SIZE_KB=$((100 * GB)) MOCK_DF_FREE_KB=$((12 * GB)) run_save
assert_eq 8 "$SAVE_RC" "MUTACYJNY: zajete >80% po zapisie -> exit 8"
assert_eq "REZERWA wolne=12G zajete=88%" "$(printf '%s\n' "$SAVE_OUT" | tail -n 1)" "ostatnia linia: REZERWA z liczbami"
assert_eq 0 "$(nsets)" "rezerwa (%): zero zestawow"
assert_eq 0 "$(grep -c '^docker save' "$M/calls" || true)" "rezerwa (%): bez docker save"
# 20 GB dysku, 9 GB wolne (55%): ponizej 10 GB -> pomin.
reset_state; rm -rf "$BK"
MOCK_DF_SIZE_KB=$((20 * GB)) MOCK_DF_FREE_KB=$((9 * GB)) run_save
assert_eq 8 "$SAVE_RC" "MUTACYJNY: <10 GB wolnego po zapisie -> exit 8"
# Kontrola: 100 GB, 50 GB wolne -> zapis.
reset_state; rm -rf "$BK"
MOCK_DF_SIZE_KB=$((100 * GB)) MOCK_DF_FREE_KB=$((50 * GB)) run_save
assert_eq 0 "$SAVE_RC" "kontrola: dosc miejsca -> zapis"
assert_eq 1 "$(nsets)" "kontrola: jeden zestaw"
# Progi wylaczone (0) -> zapis mimo 88%.
reset_state; rm -rf "$BK"
MIN_FREE_ENV=0 MAX_PCT_ENV=0 MOCK_DF_SIZE_KB=$((100 * GB)) MOCK_DF_FREE_KB=$((12 * GB)) run_save
assert_eq 0 "$SAVE_RC" "progi =0: rezerwa wylaczona"
# Wlasne progi: 15 GB minimum przy 12 GB wolnego -> pomin, nawet z MAX_PCT=0.
reset_state; rm -rf "$BK"
MIN_FREE_ENV=15 MAX_PCT_ENV=0 MOCK_DF_SIZE_KB=$((100 * GB)) MOCK_DF_FREE_KB=$((12 * GB)) run_save
assert_eq 8 "$SAVE_RC" "MIN_FREE_GB=15 z env -> exit 8"

echo "=== 8c. Szacunek miejsca: wspolne warstwy liczone RAZ (jeden docker save) ==="
# Dwa obrazy BPP po 10 100 MiB dziela warstwe l1 (10 000 MiB). Suma .Size =
# ~19,7 GiB, unikalne warstwy = 10 201 MiB (+10% = ~10,96 GiB). Przy 29 GiB
# wolnego stary szacunek zostawialby ~9,3 GiB (< 10 -> pomin), nowy ~18 GiB
# (zapis). MAX_PCT=0 izoluje prog GB.
MB=1024
reset_state; rm -rf "$BK"
img8c() {   # <historia workerservera>
    cat <<EOF
iplweb/bpp_appserver:latest|$A_OLD|$((10100 * MB * MB))|sha256:l1 sha256:l2 |-|0 $((100 * MB * MB)) 0 $((10000 * MB * MB)) 0
iplweb/bpp_workerserver:latest|$W|$((10100 * MB * MB))|sha256:l1 sha256:l3 |-|$1
postgres:18.4|$D|$((MB * MB))|sha256:p1 |-|$((MB * MB))
EOF
}
img8c "$((100 * MB * MB)) $((10000 * MB * MB))" > "$M/images"
grep -v '|netdata|' "$M/containers" > "$M/c.n"; mv "$M/c.n" "$M/containers"
MAX_PCT_ENV=0 MOCK_DF_SIZE_KB=$((200 * GB)) MOCK_DF_FREE_KB=$((29 * GB)) run_save
assert_eq 0 "$SAVE_RC" "MUTACYJNY: wspolna warstwa liczona raz -> zapis (suma .Size by pominela)"
assert_contains "$SAVE_ERR" "szacunek archiwum: do 1122" "szacunek ~10,96 GiB (unikalne warstwy + 10%)"
# Zapas 10%: 20,5 GiB wolnego. Bez zapasu (10 201 MiB = ~9,96 GiB) zostaloby
# ~10,5 GiB -> zapis; z zapasem (~10,96 GiB) ~9,5 GiB -> pomin.
rm -rf "$BK"
MAX_PCT_ENV=0 MOCK_DF_SIZE_KB=$((20 * GB + GB / 2)) MOCK_DF_FREE_KB=$((20 * GB + GB / 2)) run_save
assert_eq 8 "$SAVE_RC" "MUTACYJNY: zapas 10% wchodzi do szacunku"
# Historia nie paruje sie z warstwami (np. warstwa o zerowym rozmiarze) ->
# caly .Size workerservera, bez deduplikacji: ostrozniej, jak dawniej.
rm -rf "$BK"
img8c "$((10000 * MB * MB))" > "$M/images"
MAX_PCT_ENV=0 MOCK_DF_SIZE_KB=$((200 * GB)) MOCK_DF_FREE_KB=$((29 * GB)) run_save
assert_eq 8 "$SAVE_RC" "niesparowana historia -> caly .Size (ostrozniej), pomin"
assert_contains "$SAVE_ERR" "nie paruja sie z historia" "komunikat o niesparowanych warstwach"
# Obraz dzialajacego kontenera zniknal -> blad jak dawniej.
rm -rf "$BK"
img8c "$((100 * MB * MB)) $((10000 * MB * MB))" | grep -v '^postgres' > "$M/images"
run_save
assert_eq 1 "$SAVE_RC" "brak obrazu dzialajacego kontenera -> exit 1"
assert_contains "$SAVE_ERR" "nie ma obrazu $D" "komunikat: nie ma obrazu"

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

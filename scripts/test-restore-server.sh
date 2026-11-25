#!/usr/bin/env bash
#
# Testy scripts/restore-server.sh (`make restore-server`, `make proba-odtworzenia`)
# z atrapami rclone/docker/make. Zdalny backup to drzewo katalogow z PRAWDZIWYMI
# archiwami tar.gz; scripts/restore-config.sh jest PRAWDZIWY (owiniety tylko
# zapisem wywolania), restore.sh i images-load.sh to atrapy.
#
# Kontrakty:
#   - wybor NAJNOWSZEGO KOMPLETU (db + media + config z tym samym TIMESTAMP),
#     niekompletna noc pominieta z ostrzezeniem; DATA= wybiera noc;
#   - brak kompletu / niekompletna wskazana noc = jasny blad, zero zmian;
#   - zle haslo crypt = jasny komunikat; haslo nigdy w argv;
#   - brak archiwum obrazow -> docker pull (make pull); jest -> images-load
#     zestawu nie nowszego niz kopia;
#   - KOLEJNOSC: restore-config PRZED pierwszym `make`, init-configs nigdy;
#   - proba: shadow stack, zero make/restore.sh/docker load/tag, produkcyjny
#     .env nietkniety, wynik w $BPP_CONFIGS_DIR/logs/.
#
# Bez sieci i bez Dockera: `make test-restore-server` albo
# `bash scripts/test-restore-server.sh`.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/restore-server.sh"

T="$(mktemp -d -t bpp-restore-server-test-XXXXXX)"
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
    if printf '%s' "$1" | grep -qF -- "$2"; then pass "$3"; else fail "$3 (brak '$2' w: $(printf '%s' "$1" | tail -c 1500))"; fi
}
assert_not_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then fail "$3 ('$2' nie powinno wystapic)"; else pass "$3"; fi
}

# --------------------------------------------------------------------------
# Atrapy
# --------------------------------------------------------------------------
BIN="$T/bin"; mkdir -p "$BIN"
CALLS="$T/calls"
R="$T/remote"

cat > "$BIN/rclone" <<'MOCK'
#!/usr/bin/env bash
echo "rclone $*" >> "$CALLS"
args=()
while [ $# -gt 0 ]; do
    case "$1" in --config) shift 2 ;; *) args+=("$1"); shift ;; esac
done
set -- "${args[@]}"
# name:sciezka -> katalog atrapy; bppodtw: (crypt ad hoc) sprawdza haslo.
resolve() {
    local p="$1" name="${1%%:*}" sub="${1#*:}"
    if [ "$name" = bppodtw ]; then
        if [ "${RCLONE_CONFIG_BPPODTW_PASSWORD:-}" != "OBS:${MOCK_CRYPT_PW:-}" ]; then
            echo "ERROR : failed to decrypt name: illegal base32 data" >&2
            return 1
        fi
        resolve "${RCLONE_CONFIG_BPPODTW_REMOTE%/}/$sub"
        return
    fi
    printf '%s/%s/%s' "$R" "$name" "$sub"
}
sub="$1"; shift
case "$sub" in
    obscure) IFS= read -r pw || true; printf 'OBS:%s\n' "$pw" ;;
    listremotes) printf '%s\n' ${MOCK_REMOTES:-} ;;
    lsf)
        d="$(resolve "$1")" || exit 0
        [ -d "$d" ] || exit 0
        case " $* " in
            *" --dirs-only "*) find "$d" -mindepth 1 -maxdepth 1 -type d | sed 's:.*/::; s:$:/:' ;;
            *) find "$d" -mindepth 1 -maxdepth 1 -type f | sed 's:.*/::' ;;
        esac ;;
    copyto) src="$(resolve "$1")" || exit 1; mkdir -p "$(dirname "$2")"; cp "$src" "$2" ;;
    copy)   src="$(resolve "$1")" || exit 1; mkdir -p "$2"; cp -R "$src"/. "$2"/ ;;
    config) exit 0 ;;
    *) exit 1 ;;
esac
MOCK

cat > "$BIN/docker" <<'MOCK'
#!/usr/bin/env bash
echo "docker $*" >> "$CALLS"
case "$1" in
    compose)
        case "$2" in
            version) exit 0 ;;
            ps) [ "${3:-}" = -q ] && [ -n "${4:-}" ] && { echo "${MOCK_PS_APP:-}"; exit 0; }
                echo "${MOCK_COMPOSE_PS:-}" ;;
            exec) case "$*" in *"-w"*) echo "${MOCK_HTTP:-200}" ;; esac ;;
        esac ;;
    exec) case "$*" in *"-w"*) echo "${MOCK_HTTP:-200}" ;; esac ;;
    inspect)
        case "$*" in
            *State.Running*) echo true ;;
            *"{{.Image}}"*) echo "sha256:prodapp" ;;
        esac ;;
    image) [ "$2" = inspect ] && exit 1 ;;
esac
exit 0
MOCK

cat > "$BIN/make" <<'MOCK'
#!/usr/bin/env bash
echo "make $*" >> "$CALLS"
echo "umask-make $(umask)" >> "$CALLS"
exit 0
MOCK

# restore-config: PRAWDZIWY skrypt, tylko zapis kolejnosci.
cat > "$T/restore-config-wrap.sh" <<EOF
#!/usr/bin/env bash
echo "restore-config BPP_CONFIGS_DIR=\$BPP_CONFIGS_DIR" >> "\$CALLS"
exec bash "$REPO_DIR/scripts/restore-config.sh" "\$@"
EOF
cat > "$T/restore-stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "restore.sh $*" >> "$CALLS"
EOF
cat > "$T/images-load-stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "images-load $*" >> "$CALLS"
exit "${MOCK_IMAGES_LOAD_RC:-0}"
EOF
chmod +x "$BIN"/* "$T"/*.sh

# --------------------------------------------------------------------------
# Zdalny backup (prawdziwe archiwa)
# --------------------------------------------------------------------------
mk_night() {   # <katalog-remote> <YYYY-MM> <TS> <typy...>
    local base="$1" m="$2" ts="$3" t w
    shift 3
    mkdir -p "$base/$m"
    w="$T/build-$ts"; mkdir -p "$w"
    for t in "$@"; do
        case "$t" in
            db) mkdir -p "$w/db/db-backup-$ts"; echo toc > "$w/db/db-backup-$ts/toc.dat"
                tar czf "$base/$m/db-backup-$ts.tar.gz" -C "$w/db" "db-backup-$ts" ;;
            media) mkdir -p "$w/media/x"; echo plik > "$w/media/x/a.pdf"
                tar czf "$base/$m/media-backup-$ts.tar.gz" -C "$w/media" . ;;
            config) mkdir -p "$w/cfg/rclone"
                printf 'DJANGO_BPP_DB_NAME=bpp\nDJANGO_BPP_DB_USER=bpp\nDJANGO_BPP_DB_PASSWORD=tajne\nDJANGO_BPP_SECRET_KEY=s\nDJANGO_BPP_FIELD_ENCRYPTION_KEY=klucz-%s\nDJANGO_BPP_HOSTNAME=bpp.example.org\nDJANGO_BPP_HOST_BACKUP_DIR=%s\n' "$ts" "$T/hostbackups" > "$w/cfg/.env"
                printf '[backup_enc]\ntype = local\n' > "$w/cfg/rclone/rclone.conf"
                tar czf "$base/$m/config-backup-$ts.tar.gz" -C "$w/cfg" . ;;
        esac
    done
}
mk_imageset() {   # <katalog-remote> <TS>
    mkdir -p "$1/obrazy/$2"
    printf 'archiwum=obrazy.tar.gz\nobraz|postgres:18.4|postgres:18.4|sha256:d|w|postgres@sha256:dp|18.4|dbserver\nobraz|iplweb/bpp_appserver:latest|iplweb/bpp_appserver:latest|sha256:a|w|iplweb/bpp_appserver@sha256:da|202611.1|appserver\n' > "$1/obrazy/$2/manifest.txt"
    echo x > "$1/obrazy/$2/obrazy.tar.gz"
}

BE="$R/backup_enc"
mk_night "$BE" 2026-10 20261020-014500 db media config
mk_night "$BE" 2026-11 20261124-014500 db media config
mk_night "$BE" 2026-11 20261125-014500 db media          # noc bez config-backup

N=0
run_real() {   # stdin = odpowiedzi; env: dodatkowe zmienne
    N=$((N + 1))
    : > "$CALLS"
    rm -rf "$T/inst" "$T/hostbackups" "$T/repo.env"
    printf '[backup_enc]\ntype = local\n' > "$T/rclone.conf"
    set +e
    OUT="$(env PATH="$BIN:$PATH" CALLS="$CALLS" R="$R" \
        BPP_RESTORE_RCLONE=host \
        BPP_RESTORE_CONFIG_SH="$T/restore-config-wrap.sh" \
        BPP_RESTORE_SH="$T/restore-stub.sh" \
        BPP_IMAGES_LOAD_SH="$T/images-load-stub.sh" \
        BPP_REPO_ENV_FILE="$T/repo.env" \
        BPP_CONFIGS_DIR="$T/inst/cfg" \
        STAGE_DIR="$T/stage-$N" \
        RCLONE_CONF="$T/rclone.conf" \
        MOCK_REMOTES="${MOCK_REMOTES-backup_enc:}" \
        "$@" bash "$SCRIPT" 2>&1)"
    RC=$?
    set -e
    CALLS_TXT="$(cat "$CALLS")"
}

# --------------------------------------------------------------------------
echo "=== 1. Najnowszy KOMPLET; niekompletna nowsza noc pominieta ==="
run_real REMOTE=backup_enc: <<< "tak"
assert_eq 0 "$RC" "odtworzenie: rc=0"
assert_contains "$OUT" "Komplet: 20261124-014500" "wybrana najnowsza kompletna noc"
assert_contains "$OUT" "20261125-014500 (brak: config)" "ostrzezenie o niekompletnej nowszej nocy"
assert_contains "$CALLS_TXT" "restore.sh --timestamp=20261124-014500 --yes --no-safety-backup" "restore.sh z timestampem kompletu"
assert_eq "klucz-20261124-014500" "$(grep '^DJANGO_BPP_FIELD_ENCRYPTION_KEY=' "$T/inst/cfg/.env" | cut -d= -f2)" "klucz szyfrowania z kopii tej samej nocy"
if [ -f "$T/hostbackups/db-backup-20261124-014500.tar.gz" ] && [ -f "$T/hostbackups/media-backup-20261124-014500.tar.gz" ]; then
    pass "kopie skopiowane do katalogu backupow z odtworzonego .env"
else
    fail "kopie skopiowane do katalogu backupow z odtworzonego .env"
fi
assert_contains "$(cat "$T/repo.env")" "BPP_CONFIGS_DIR=$T/inst/cfg" "repo .env zapisany przez restore-config"
assert_contains "$(cat "$T/inst/cfg/logs/odtworzenie-serwera.log")" "| odtworzenie | kopia 2026-11-24 01:45 |" "linia wyniku w logu katalogu konfiguracyjnego"
assert_contains "$(cat "$T/inst/cfg/logs/odtworzenie-serwera.log")" "| OK |" "wynik OK w logu"

echo "=== 2. KOLEJNOSC: restore-config przed pierwszym make, init-configs nigdy ==="
l_cfg="$(grep -n '^restore-config' "$CALLS" | head -1 | cut -d: -f1)"
l_make="$(grep -n '^make ' "$CALLS" | head -1 | cut -d: -f1)"
l_db="$(grep -n 'compose up -d --wait dbserver' "$CALLS" | head -1 | cut -d: -f1)"
if [ -n "$l_cfg" ] && [ -n "$l_make" ] && [ "$l_cfg" -lt "$l_make" ]; then pass "restore-config (linia $l_cfg) przed make (linia $l_make)"
else fail "restore-config przed make (cfg=$l_cfg make=$l_make)"; fi
if [ -n "$l_db" ] && [ "$l_cfg" -lt "$l_db" ]; then pass "konfiguracja przed startem dbservera"; else fail "konfiguracja przed startem dbservera"; fi
assert_not_contains "$CALLS_TXT" "init-configs" "init-configs nie jest wolany"
# umask 077 dziedziczony przez make/compose dawalby pliki konfiguracyjne 0600,
# nieczytelne dla kontenerow bez roota (grafana, loki).
assert_not_contains "$CALLS_TXT" "umask-make 0077" "make nie dziedziczy umask 077"
assert_not_contains "$CALLS_TXT" "make setup" "setup nie jest wolany"

echo "=== 3. Brak archiwum obrazow -> docker pull (make pull), bez images-load ==="
assert_contains "$CALLS_TXT" "make -C $REPO_DIR pull" "make pull wersji z .env"
assert_not_contains "$CALLS_TXT" "images-load" "images-load nie wolany"

echo "=== 4. Archiwum obrazow -> images-load zestawu nie nowszego niz kopia ==="
mk_imageset "$BE" 20261101-014500
mk_imageset "$BE" 20261124-020000
run_real REMOTE=backup_enc: <<< "tak"
assert_eq 0 "$RC" "rc=0 z archiwum"
assert_contains "$CALLS_TXT" "images-load $T/stage-$N/obrazy/20261101-014500" "zestaw <= TS kopii (nie nowszy 20261124-020000)"
assert_not_contains "$CALLS_TXT" "make -C $REPO_DIR pull" "bez docker pull, gdy archiwum sie wczytalo"
assert_contains "$CALLS_TXT" "--entrypoint sh postgres:18.4" "pg_restore --list w obrazie dbservera z manifestu"

echo "=== 5. images-load pada -> pull DOKLADNIE wersji z manifestu (repo@digest) ==="
run_real REMOTE=backup_enc: MOCK_IMAGES_LOAD_RC=1 <<< "tak"
assert_eq 0 "$RC" "rc=0 po fallbacku"
assert_contains "$CALLS_TXT" "docker pull iplweb/bpp_appserver@sha256:da" "pull po digescie z manifestu"
assert_contains "$CALLS_TXT" "docker tag iplweb/bpp_appserver@sha256:da iplweb/bpp_appserver:latest" "tag na ref z compose"
rm -rf "$BE/obrazy"

echo "=== 6. DATA= wybiera noc; niekompletna wskazana noc = blad ==="
run_real REMOTE=backup_enc: DATA=20261020 <<< "tak"
assert_contains "$OUT" "Komplet: 20261020-014500" "DATA=20261020 -> noc z pazdziernika"
run_real REMOTE=backup_enc: DATA=20261125 <<< "tak"
assert_eq 1 "$RC" "DATA na niekompletna noc -> rc=1"
assert_contains "$OUT" "brak: config" "komunikat wskazuje brakujacy plik"
assert_not_contains "$CALLS_TXT" "restore-config" "nic nie odtworzone"

echo "=== 7. Ani jednej kompletnej nocy -> jasny blad ==="
mv "$BE" "$T/be.bak"; mkdir -p "$BE"
mk_night "$BE" 2026-11 20261125-014500 db media
run_real REMOTE=backup_enc: <<< "tak"
assert_eq 1 "$RC" "brak kompletu -> rc=1"
assert_contains "$OUT" "nie ma ani jednej kompletnej nocy" "komunikat: brak kompletu"
assert_contains "$OUT" "Kopie sprzed backupu konfiguracji" "wyjasnienie: stare kopie bez config"
rm -rf "$BE"; mv "$T/be.bak" "$BE"

echo "=== 8. Odpowiedz inna niz 'tak' -> nic nie zmienione ==="
run_real REMOTE=backup_enc: <<< "nie"
assert_eq 1 "$RC" "bez 'tak' -> rc=1"
assert_not_contains "$CALLS_TXT" "restore-config" "konfiguracja nietknieta"
if [ -e "$T/inst/cfg/.env" ]; then fail "brak .env po odmowie"; else pass "brak .env po odmowie"; fi

echo "=== 9. Crypt ad hoc: dobre haslo dziala, zle = jasny komunikat, haslo nie w argv ==="
mkdir -p "$R/gdrive"; cp -R "$BE" "$R/gdrive/bpp"
run_real REMOTE=backup_enc: CRYPT_REMOTE=gdrive:bpp MOCK_CRYPT_PW='T@jne haslo!' MOCK_REMOTES="gdrive:" \
    <<< $'T@jne haslo!\n\ntak'
assert_eq 0 "$RC" "dobre haslo crypt -> rc=0"
assert_contains "$OUT" "Komplet: 20261124-014500" "crypt: komplet znaleziony"
assert_not_contains "$CALLS_TXT" "T@jne haslo!" "MUTACYJNY: haslo crypt nie pojawia sie w zadnym argv"
run_real REMOTE=backup_enc: CRYPT_REMOTE=gdrive:bpp MOCK_CRYPT_PW='T@jne haslo!' MOCK_REMOTES="gdrive:" \
    <<< $'zle\n\ntak'
assert_eq 1 "$RC" "zle haslo crypt -> rc=1"
assert_contains "$OUT" "ZLE HASLO" "komunikat wskazuje haslo"
assert_not_contains "$CALLS_TXT" "restore-config" "zle haslo: nic nie odtworzone"

echo "=== 10. Remote spoza rclone.conf -> pytanie o sciezke i haslo crypt ==="
run_real REMOTE=backup_enc: MOCK_CRYPT_PW='x1' MOCK_REMOTES="gdrive:" <<< $'gdrive:bpp\nx1\n\ntak'
assert_eq 0 "$RC" "interaktywny crypt -> rc=0"
assert_contains "$OUT" "nie istnieje w rclone.conf" "wyjasnienie, czemu pyta o crypt"

echo "=== 11. Dzialajacy stack -> odmowa ==="
N=$((N + 1)); : > "$CALLS"; rm -rf "$T/inst"
echo "BPP_CONFIGS_DIR=$T/inst/cfg" > "$T/repo.env"
set +e
OUT="$(env PATH="$BIN:$PATH" CALLS="$CALLS" R="$R" BPP_RESTORE_RCLONE=host MOCK_COMPOSE_PS=cid1 \
    BPP_REPO_ENV_FILE="$T/repo.env" BPP_CONFIGS_DIR="$T/inst/cfg" RCLONE_CONF="$T/rclone.conf" \
    bash "$SCRIPT" 2>&1 <<< "tak")"; RC=$?
set -e
assert_eq 1 "$RC" "dzialajacy stack -> rc=1"
assert_contains "$OUT" "make proba-odtworzenia" "podpowiedz: proba"

# --------------------------------------------------------------------------
echo "=== 12. Proba (--proba): shadow stack, produkcja nietknieta ==="
PROD="$T/prod"; mkdir -p "$PROD/rclone"
printf 'DJANGO_BPP_RCLONE_REMOTE=backup_enc:\nDJANGO_BPP_FIELD_ENCRYPTION_KEY=klucz-20261124-014500\nDJANGO_BPP_HOST_BACKUP_DIR=%s\n' "$T/prodbackups" > "$PROD/.env"
printf '[backup_enc]\ntype = local\n' > "$PROD/rclone/rclone.conf"
mkdir -p "$T/prodbackups"
echo "BPP_CONFIGS_DIR=$PROD" > "$T/repo-prod.env"
mk_imageset "$BE" 20261101-014500
# Zestaw obrazow z poprawna suma (proba ja sprawdza).
suma="$(sha256sum < "$BE/obrazy/20261101-014500/obrazy.tar.gz" | cut -c1-64)"
echo "archiwum_sha256=$suma" >> "$BE/obrazy/20261101-014500/manifest.txt"
before="$(sha256sum < "$PROD/.env")"
: > "$CALLS"
set +e
OUT="$(env PATH="$BIN:$PATH" CALLS="$CALLS" R="$R" BPP_RESTORE_RCLONE=host \
    BPP_RESTORE_CONFIG_SH="$T/restore-config-wrap.sh" BPP_RESTORE_SH="$T/restore-stub.sh" \
    BPP_IMAGES_LOAD_SH="$T/images-load-stub.sh" BPP_REPO_ENV_FILE="$T/repo-prod.env" \
    TEST_UPGRADE_LOCK_DIR="$T/lock" MOCK_PS_APP=cidapp KEEP_SHADOW=0 \
    bash "$SCRIPT" --proba 2>&1 </dev/null)"; RC=$?
set -e
CALLS_TXT="$(cat "$CALLS")"
assert_eq 0 "$RC" "proba: rc=0"
assert_contains "$OUT" "Komplet: 20261124-014500" "proba: najnowszy komplet"
assert_contains "$CALLS_TXT" "--name bpp-shadow-dbserver" "proba: shadow-baza"
assert_contains "$CALLS_TXT" "pg_restore -Fd" "proba: pg_restore do shadow-bazy"
assert_contains "$CALLS_TXT" "media-backup-20261124-014500.tar.gz -C /dst" "proba: media do wolumenu shadow"
assert_contains "$CALLS_TXT" "--name bpp-shadow-appserver" "proba: appserver shadow"
assert_contains "$CALLS_TXT" "sha256:prodapp" "proba: obraz appservera z produkcji (manifestowego brak lokalnie)"
assert_contains "$CALLS_TXT" "restore-config BPP_CONFIGS_DIR=" "proba: restore-config wolany"
if grep -qxF "restore-config BPP_CONFIGS_DIR=$PROD" "$CALLS"; then
    fail "MUTACYJNY proba: konfiguracja NIE do katalogu produkcyjnego"
else
    pass "MUTACYJNY proba: konfiguracja NIE do katalogu produkcyjnego"
fi
assert_eq "$before" "$(sha256sum < "$PROD/.env")" "MUTACYJNY proba: produkcyjny .env nietkniety"
for zakazane in "make " "restore.sh" "images-load" "docker load" "docker tag" "docker pull" "compose up" "compose stop"; do
    assert_not_contains "$CALLS_TXT" "$zakazane" "proba: zero '$zakazane'"
done
assert_contains "$CALLS_TXT" "docker rm -f bpp-shadow-appserver" "proba: shadow posprzatany"
if ls -d "$T"/prodbackups/.proba-odtworzenia-* >/dev/null 2>&1; then fail "proba: katalog roboczy usuniety"; else pass "proba: katalog roboczy usuniety"; fi
if [ -d "$T/lock" ]; then fail "proba: blokada zwolniona"; else pass "proba: blokada zwolniona"; fi
LOG="$(cat "$PROD/logs/odtworzenie-serwera.log" 2>/dev/null || true)"
assert_contains "$LOG" "| proba | kopia 2026-11-24 01:45 |" "proba: wynik w logu katalogu konfiguracyjnego"
assert_contains "$LOG" "klucz zgodny" "proba: klucz szyfrowania porownany z produkcja"
assert_contains "$LOG" "obrazy 20261101-014500" "proba: archiwum obrazow zweryfikowane"
assert_not_contains "$(grep '^rclone' "$CALLS" | grep -vE '^rclone (lsf|copyto|copy) backup_enc:' | grep -v '^rclone --config' || true)" "rclone" \
    "proba: rclone wylacznie czyta ze zdalnego (lsf/copy/copyto Z remote'a)"

echo "=== 13. Proba: appserver nie odpowiada -> wynik BLAD w logu, rc=1, sprzatniete ==="
: > "$CALLS"; rm -f "$PROD/logs/odtworzenie-serwera.log"
set +e
OUT="$(env PATH="$BIN:$PATH" CALLS="$CALLS" R="$R" BPP_RESTORE_RCLONE=host \
    BPP_RESTORE_CONFIG_SH="$T/restore-config-wrap.sh" BPP_REPO_ENV_FILE="$T/repo-prod.env" \
    TEST_UPGRADE_LOCK_DIR="$T/lock" MOCK_PS_APP=cidapp KEEP_SHADOW=0 MOCK_HTTP=500 \
    bash "$SCRIPT" --proba 2>&1 </dev/null)"; RC=$?
set -e
assert_eq 1 "$RC" "proba: HTTP 500 -> rc=1"
assert_contains "$(cat "$PROD/logs/odtworzenie-serwera.log")" "| BLAD |" "proba: BLAD w logu"
assert_eq 1 "$(grep -c '| BLAD |' "$PROD/logs/odtworzenie-serwera.log")" "proba: wynik zapisany raz"
assert_contains "$(cat "$CALLS")" "docker rm -f bpp-shadow-appserver" "proba po bledzie: sprzatniete (KEEP_SHADOW=0)"

echo ""
echo "========================================"
if [ "$FAIL" -gt 0 ]; then
    red "  test-restore-server: $PASS passed, $FAIL failed"
    exit 1
fi
green "  test-restore-server: $PASS passed, 0 failed"

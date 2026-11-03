#!/usr/bin/env bash
#
# Testy scripts/lib-docker-versions.sh, scripts/zaspawaj-wersje.sh oraz
# scripts/test-upgrade.sh (sciezka --clean).
#
# Bez sieci i bez Docker daemona: `curl` i `docker` sa mockowane
# stub-skryptami w PATH (konwencja: scripts/test-letsencrypt.sh).
#
# Uruchomienie: `make test-docker-versions` lub
#   `bash scripts/test-docker-versions.sh`

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_DIR/scripts/lib-docker-versions.sh"

TEST_ROOT="$(mktemp -d -t bpp-docker-versions-test-XXXXXX)"
MOCK_BIN="$TEST_ROOT/mock-bin"
CURL_LOG="$TEST_ROOT/curl-calls.log"
DOCKER_LOG="$TEST_ROOT/docker-calls.log"
FIXTURES="$TEST_ROOT/fixtures"
mkdir -p "$MOCK_BIN" "$FIXTURES"

# shellcheck disable=SC2317  # wywolywane przez trap
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
PASS=0; FAIL=0
pass() { green "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { red   "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local expected="$1" actual="$2" name="$3"
    if [ "$expected" = "$actual" ]; then pass "$name"; else
        fail "$name (oczekiwane '$expected', otrzymano '$actual')"; fi
}
assert_exit() {
    local expected="$1" actual="$2" name="$3"
    if [ "$expected" = "$actual" ]; then pass "$name"; else
        fail "$name (oczekiwany exit=$expected, otrzymany exit=$actual)"; fi
}
assert_nonzero() {
    local actual="$1" name="$2"
    if [ "$actual" != "0" ]; then pass "$name"; else
        fail "$name (oczekiwany exit != 0, otrzymany 0)"; fi
}
assert_file_contains() {
    local file="$1" needle="$2" name="$3"
    if grep -qF -- "$needle" "$file" 2>/dev/null; then pass "$name"; else
        fail "$name (brak '$needle' w $file)"; fi
}
assert_file_not_contains() {
    local file="$1" needle="$2" name="$3"
    if grep -qF -- "$needle" "$file" 2>/dev/null; then
        fail "$name ('$needle' obecne w $file)"; else pass "$name"; fi
}

# --- Mock curl ---
# Ostatni argument wywolania = URL.
#   .../tags?page_size=... -> cat $CURL_FIXTURE (lista tagow)
#   .../tags/<tag>         -> exit 0 gdy CURL_TAG_EXISTS=1 (domyslnie), inaczej 22
cat > "$MOCK_BIN/curl" <<EOF
#!/bin/sh
for last; do :; done
echo "\$last" >> "$CURL_LOG"
case "\$last" in
  *"/tags?page_size="*)
      if [ -n "\${CURL_FIXTURE:-}" ]; then cat "\$CURL_FIXTURE"; else exit 22; fi ;;
  *"/tags/"*)
      [ "\${CURL_TAG_EXISTS:-1}" = "1" ] || exit 22 ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$MOCK_BIN/curl"

# --- Mock docker ---
#   compose ps -q appserver  -> cid (pusty gdy MOCK_APPSERVER_RUNNING=0)
#   compose ps -q <inne>     -> cid-other
#   inspect --format {{.Image}} cid-* -> img-123
#   image inspect --format ... img-123 -> repo digest (MOCK_RUNNING_DIGEST)
cat > "$MOCK_BIN/docker" <<EOF
#!/bin/sh
echo "\$*" >> "$DOCKER_LOG"
case "\$*" in
  "compose ps -q appserver")
      if [ "\${MOCK_APPSERVER_RUNNING:-1}" = "1" ]; then echo "cid-app"; fi ;;
  "compose ps -q "*)
      echo "cid-other" ;;
  "inspect --format {{.Image}} cid-"*)
      echo "img-123" ;;
  "image inspect --format "*)
      echo "iplweb/bpp_appserver@\${MOCK_RUNNING_DIGEST:-sha256:aaa}" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$MOCK_BIN/docker"

export PATH="$MOCK_BIN:$PATH"

# --- Fixtures API Docker Huba ---
cat > "$FIXTURES/tags.json" <<'EOF'
{"results":[
 {"name":"latest","digest":"sha256:aaa","images":[{"digest":"sha256:arm64aaa"},{"digest":"sha256:amd64aaa"}]},
 {"name":"feature-multi-hosted-config","digest":"sha256:fff","images":[]},
 {"name":"sha-56127ac","digest":"sha256:aaa","images":[]},
 {"name":"202606.1386","digest":"sha256:aaa","images":[{"digest":"sha256:arm64aaa"},{"digest":"sha256:amd64aaa"}]},
 {"name":"202606.999","digest":"sha256:bbb","images":[{"digest":"sha256:armbbb"}]},
 {"name":"202605.1300","digest":"sha256:ccc","images":[]}
]}
EOF
cat > "$FIXTURES/no-calver.json" <<'EOF'
{"results":[{"name":"latest","digest":"sha256:aaa","images":[]}]}
EOF

# ===================== Testy lib-docker-versions.sh =====================
echo "== lib-docker-versions.sh =="
# shellcheck source=/dev/null
. "$LIB"

export CURL_FIXTURE="$FIXTURES/tags.json"

out="$(resolve_latest_calver iplweb/bpp_appserver)"
assert_eq "202606.1386" "$out" "resolve_latest_calver: najnowszy numerycznie (1386 > 999)"

out="$(resolve_digest_to_calver iplweb/bpp_appserver sha256:aaa)"
assert_eq "202606.1386" "$out" "resolve_digest_to_calver: digest manifest-list"

out="$(resolve_digest_to_calver iplweb/bpp_appserver sha256:armbbb)"
assert_eq "202606.999" "$out" "resolve_digest_to_calver: digest per-arch (images[])"

rc=0; resolve_digest_to_calver iplweb/bpp_appserver sha256:zzz >/dev/null 2>&1 || rc=$?
assert_nonzero "$rc" "resolve_digest_to_calver: nieznany digest -> exit != 0"

CURL_FIXTURE="$FIXTURES/no-calver.json"
rc=0; resolve_latest_calver iplweb/bpp_appserver >/dev/null 2>&1 || rc=$?
assert_nonzero "$rc" "resolve_latest_calver: brak tagow CalVer -> exit != 0"
CURL_FIXTURE="$FIXTURES/tags.json"

rc=0; verify_tag_exists iplweb/bpp_appserver 202606.1386 || rc=$?
assert_exit 0 "$rc" "verify_tag_exists: istniejacy tag -> exit 0"

rc=0; CURL_TAG_EXISTS=0 verify_tag_exists iplweb/bpp_appserver 999999.1 || rc=$?
assert_nonzero "$rc" "verify_tag_exists: brak tagu -> exit != 0"

out="$(running_repo_digest appserver)"
assert_eq "sha256:aaa" "$out" "running_repo_digest: digest z dzialajacego kontenera"

rc=0; MOCK_APPSERVER_RUNNING=0 running_repo_digest appserver >/dev/null 2>&1 || rc=$?
assert_nonzero "$rc" "running_repo_digest: kontener nie dziala -> exit != 0"

# ===================== Testy zaspawaj-wersje.sh =====================
echo ""
echo "== zaspawaj-wersje.sh =="
ZW="$REPO_DIR/scripts/zaspawaj-wersje.sh"

make_env() {  # make_env <nazwa> -> sciezka swiezego katalogu konfiguracyjnego
    local dir="$TEST_ROOT/configs-$1"
    mkdir -p "$dir"
    cat > "$dir/.env" <<'ENVEOF'
DJANGO_BPP_DB_NAME=bpp
DJANGO_BPP_DB_USER=bpp
DJANGO_BPP_DB_PASSWORD=sekret
ENVEOF
    printf '%s' "$dir"
}

# 1. Jawny TAG, poprawny i istniejacy -> wpis w .env, exit 0
cfg="$(make_env tag-ok)"
rc=0; BPP_CONFIGS_DIR="$cfg" TAG=202606.1386 bash "$ZW" >/dev/null 2>&1 || rc=$?
assert_exit 0 "$rc" "zaspawaj: TAG poprawny -> exit 0"
assert_file_contains "$cfg/.env" "DOCKER_VERSION=202606.1386" "zaspawaj: DOCKER_VERSION zapisany"

# 2. TAG o zlym formacie -> exit != 0, .env nietkniety
cfg="$(make_env tag-bad)"
rc=0; BPP_CONFIGS_DIR="$cfg" TAG=latest bash "$ZW" >/dev/null 2>&1 || rc=$?
assert_nonzero "$rc" "zaspawaj: TAG=latest odrzucony (nie-CalVer)"
assert_file_not_contains "$cfg/.env" "DOCKER_VERSION" "zaspawaj: .env nietkniety po blednym TAG"

# 3. TAG nieistniejacy na Hubie -> exit != 0, .env nietkniety
cfg="$(make_env tag-missing)"
rc=0; BPP_CONFIGS_DIR="$cfg" TAG=209912.1 CURL_TAG_EXISTS=0 bash "$ZW" >/dev/null 2>&1 || rc=$?
assert_nonzero "$rc" "zaspawaj: TAG nieistniejacy na Hubie odrzucony"
assert_file_not_contains "$cfg/.env" "DOCKER_VERSION" "zaspawaj: .env nietkniety po nieistniejacym TAG"

# 4. Bez TAG: wersja rozwiazana z digestu dzialajacego appservera
cfg="$(make_env running)"
rc=0; BPP_CONFIGS_DIR="$cfg" bash "$ZW" >/dev/null 2>&1 || rc=$?
assert_exit 0 "$rc" "zaspawaj: bez TAG -> exit 0 (digest dzialajacego appservera)"
assert_file_contains "$cfg/.env" "DOCKER_VERSION=202606.1386" "zaspawaj: wersja z digestu sha256:aaa"

# 5. Istniejacy DOCKER_VERSION jest nadpisywany (idempotentne przybicie)
cfg="$(make_env overwrite)"
echo "DOCKER_VERSION=202601.1" >> "$cfg/.env"
rc=0; BPP_CONFIGS_DIR="$cfg" TAG=202606.1386 bash "$ZW" >/dev/null 2>&1 || rc=$?
assert_exit 0 "$rc" "zaspawaj: nadpisanie istniejacej wartosci -> exit 0"
assert_file_contains "$cfg/.env" "DOCKER_VERSION=202606.1386" "zaspawaj: nowa wartosc zapisana"
assert_file_not_contains "$cfg/.env" "DOCKER_VERSION=202601.1" "zaspawaj: stara wartosc usunieta"

# 6. Appserver nie dziala (i brak TAG) -> exit != 0, .env nietkniety
cfg="$(make_env not-running)"
rc=0; BPP_CONFIGS_DIR="$cfg" MOCK_APPSERVER_RUNNING=0 bash "$ZW" >/dev/null 2>&1 || rc=$?
assert_nonzero "$rc" "zaspawaj: appserver nie dziala -> exit != 0"
assert_file_not_contains "$cfg/.env" "DOCKER_VERSION" "zaspawaj: .env nietkniety gdy appserver nie dziala"

# ===================== Testy test-upgrade.sh (--clean) =====================
echo ""
echo "== test-upgrade.sh --clean =="
TU="$REPO_DIR/scripts/test-upgrade.sh"

: > "$DOCKER_LOG"
rc=0; bash "$TU" --clean >/dev/null 2>&1 || rc=$?
assert_exit 0 "$rc" "test-upgrade --clean: exit 0"
assert_file_contains "$DOCKER_LOG" "rm -f bpp-shadow-appserver bpp-shadow-dbserver bpp-shadow-redis" "--clean: usuwa kontenery shadow"
assert_file_contains "$DOCKER_LOG" "volume rm -f bpp-shadow-pgdata bpp-shadow-staticfiles bpp-shadow-media" "--clean: usuwa wolumeny shadow"
assert_file_contains "$DOCKER_LOG" "network rm bpp-shadow" "--clean: usuwa siec shadow"

rc=0; bash -n "$TU" || rc=$?
assert_exit 0 "$rc" "test-upgrade.sh: poprawna skladnia (bash -n)"

# ============== Testy test-upgrade.sh (pelny przebieg, mock) ==============
# Prawdziwy skrypt, docker/make/curl podmienione. Sprawdzamy, CO poleci do
# dockera - grep po zrodle nie widzi, jaki obraz faktycznie trafi do shadow-bazy.
echo ""
echo "== test-upgrade.sh (pelny przebieg, mock) =="
TU_BIN="$TEST_ROOT/tu-bin"
TU_LOG="$TEST_ROOT/tu-docker.log"
TU_BACKUPS="$TEST_ROOT/tu-backups"
mkdir -p "$TU_BIN" "$TU_BACKUPS"

cat > "$TU_BIN/docker" <<EOF
#!/bin/sh
echo "\$*" >> "$TU_LOG"
case "\$*" in
  "compose ps -q dbserver")
      [ "\${MOCK_DB_RUNNING:-1}" = "1" ] && echo "cid-db" ;;
  "inspect --format {{.Config.Image}} cid-db")
      echo "\${MOCK_PROD_DB_IMAGE:-postgres:18.4}" ;;
  "inspect --format {{range .Mounts}}"*)
      echo "bpp_postgresql_data" ;;
  "run --rm -v bpp_postgresql_data:/v:ro --entrypoint du "*)
      printf '%s\t/v\n' "\${MOCK_DB_MB:-100}" ;;
  *"--entrypoint cat "*"/proc/meminfo")
      printf 'MemTotal:       16000000 kB\nMemAvailable:   %s kB\n' "\${MOCK_MEM_AVAIL_KB:-16000000}" ;;
  "compose exec -T dbserver sh -c "*)
      echo "\${MOCK_DB_MB:-100}" ;;
  *"--entrypoint python "*"migrate --noinput")
      exit "\${MOCK_MIGRATE_RC:-0}" ;;
  "exec bpp-shadow-appserver curl -fsS "*)
      [ "\${MOCK_HEALTH_OK:-1}" = "1" ] || exit 7 ;;
  "exec bpp-shadow-appserver curl -s "*)
      printf '%s' "\${MOCK_ROOT_CODE:-200}" ;;
  "inspect --format {{.State.Running}} bpp-shadow-appserver")
      echo "\${MOCK_APP_RUNNING:-true}" ;;
  "info "*) ;;
  *) exit 0 ;;
esac
EOF
cat > "$TU_BIN/make" <<EOF
#!/bin/sh
case "\$*" in
  *db-backup*) : > "$TU_BACKUPS/db-backup-20261103-1200.tar.gz" ;;
esac
exit 0
EOF
cat > "$TU_BIN/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TU_BIN/docker" "$TU_BIN/make" "$TU_BIN/sleep"

TU_LOCK="$TEST_ROOT/tu.lock"
TU_CFG="$TEST_ROOT/tu-cfg"
mkdir -p "$TU_CFG"
cat > "$TU_CFG/.env" <<EOF
DJANGO_BPP_DB_NAME=bpp
DJANGO_BPP_DB_USER=bpp
DJANGO_BPP_DB_PASSWORD=sekret
DJANGO_BPP_POSTGRESQL_VERSION=16.13
DJANGO_BPP_POSTGRESQL_VERSION_MAJOR=17
DJANGO_BPP_HOST_BACKUP_DIR=$TU_BACKUPS
DJANGO_BPP_HOSTNAMES=bpp.uczelnia-a.pl,bpp.uczelnia-b.pl
EOF

tu_run() {
    : > "$TU_LOG"
    rm -f "$TU_BACKUPS"/*.tar.gz
    rc=0
    # Domyslnie KEEP_SHADOW=1 (jak przy terminalu) - "$@" moze to nadpisac,
    # bo `env` stosuje przypisania po kolei.
    env PATH="$TU_BIN:$PATH" BPP_CONFIGS_DIR="$TU_CFG" TAG=202611.1460 \
        SHADOW_APP_TIMEOUT=10 KEEP_SHADOW=1 TEST_UPGRADE_LOCK_DIR="$TU_LOCK" \
        "$@" bash "$TU" </dev/null >"$TEST_ROOT/tu-out.log" 2>&1 || rc=$?
}

# 1. Sukces, tryb lokalny: shadow-baza z obrazu DZIALAJACEGO dbservera
#    (postgres:18.4), mimo ze .env mowi 16.13 - liczy sie to, na czym chodzi produkcja.
tu_run BPP_DATABASE_COMPOSE= MOCK_PROD_DB_IMAGE=postgres:18.4
assert_exit 0 "$rc" "test-upgrade: pelny przebieg -> exit 0"
assert_file_contains "$TU_LOG" "--entrypoint bash postgres:18.4 /usr/local/bin/docker-entrypoint-autotune.sh postgres" "shadow-baza: obraz produkcyjnego dbservera + autotune"
assert_file_contains "$TU_LOG" "dbserver/autotune.sh:/autotune.sh:ro" "shadow-baza: autotune bind-mountowany z repo"
assert_file_contains "$TU_LOG" "-e PGDATA=/var/lib/postgresql/data" "shadow-baza: PGDATA przypiety"
assert_file_contains "$TU_LOG" "--icu-locale=pl-PL" "shadow-baza: kolacja ICU pl-PL"
assert_file_contains "$TU_LOG" "-e POSTGRESQL_RAM_THIS_MUCH_GB= " "shadow-baza: produkcyjny RAM autotune wyzerowany"
assert_file_not_contains "$TU_LOG" "bpp_dbserver" "shadow-baza: brak wycofanego obrazu iplweb/bpp_dbserver"
assert_file_contains "$TU_LOG" "--entrypoint du postgres:18.4 -sm /v" "rozmiar bazy: du na wolumenie produkcyjnym"
assert_file_not_contains "$TU_LOG" "compose exec -T dbserver psql" "rozmiar bazy: bez psql w produkcyjnym dbserverze"
assert_file_contains "$TU_LOG" "pg_restore -Fd -j 4 --no-owner --no-privileges" "restore: bez wlascicieli i GRANT-ow obcych rol"
assert_file_contains "$TU_LOG" "--name bpp-shadow-appserver" "kandydat: startuje obok na kopii bazy"
assert_file_contains "$TU_LOG" "Host: bpp.uczelnia-a.pl" "kandydat: strona glowna pytana o pierwszy hostname"
assert_file_contains "$TU_LOG" "-e ROLLBAR_ACCESS_TOKEN= " "kandydat: Rollbar wyzerowany"
assert_file_contains "$TEST_ROOT/tu-out.log" "Sprzatam shadow stack..." "sukces: shadow posprzatany"

# 2. Kontrola miejsca liczona z rozmiaru wolumenu: za duza baza -> stop PRZED backupem.
tu_run BPP_DATABASE_COMPOSE= MOCK_DB_MB=999999999
assert_nonzero "$rc" "za malo miejsca -> exit != 0"
assert_file_not_contains "$TU_LOG" "--name bpp-shadow-dbserver" "za malo miejsca: shadow nie startuje"
if [ -e "$TU_BACKUPS/db-backup-20261103-1200.tar.gz" ]; then fail "za malo miejsca: backup nie powinien ruszyc"; else pass "za malo miejsca: backup nie ruszyl"; fi

# 2b. Kontrola pamieci: 1g + 256m + max(2g, 2g) = 3328 MB; dostepne 2000 MB -> stop PRZED backupem.
tu_run BPP_DATABASE_COMPOSE= MOCK_MEM_AVAIL_KB=2048000
assert_nonzero "$rc" "za malo RAM -> exit != 0"
assert_file_contains "$TEST_ROOT/tu-out.log" "wymagane ~3328 MB" "za malo RAM: liczy baza+redis+max(migracja,kandydat)"
if [ -e "$TU_BACKUPS/db-backup-20261103-1200.tar.gz" ]; then fail "za malo RAM: backup nie powinien ruszyc"; else pass "za malo RAM: backup nie ruszyl"; fi

# 2c. Mniejsze limity mieszcza sie w tej samej pamieci -> przechodzi.
tu_run BPP_DATABASE_COMPOSE= MOCK_MEM_AVAIL_KB=2048000 SHADOW_APP_MEM=512m SHADOW_MIGRATE_MEM=512m
assert_exit 0 "$rc" "mniejsze SHADOW_*_MEM -> miesci sie, exit 0"

# 2d. SKIP_MEM_CHECK=1 omija kontrole.
tu_run BPP_DATABASE_COMPOSE= MOCK_MEM_AVAIL_KB=2048000 SKIP_MEM_CHECK=1
assert_exit 0 "$rc" "SKIP_MEM_CHECK=1 -> exit 0"

# 3. Migracja pada -> exit != 0, kandydat NIE startuje, shadow zostaje.
tu_run BPP_DATABASE_COMPOSE= MOCK_MIGRATE_RC=1
assert_nonzero "$rc" "migracja pada -> exit != 0"
assert_file_not_contains "$TU_LOG" "--name bpp-shadow-appserver" "migracja pada: kandydat nie startuje"
assert_file_not_contains "$TEST_ROOT/tu-out.log" "Sprzatam shadow stack" "migracja pada (KEEP_SHADOW=1): shadow zostaje do inspekcji"
assert_file_contains "$TEST_ROOT/tu-out.log" "Shadow stack ZOSTAJE do inspekcji" "migracja pada (KEEP_SHADOW=1): podpowiedz inspekcji"

# 4. Kandydat nie odpowiada na /health/ -> exit != 0, shadow zostaje.
tu_run BPP_DATABASE_COMPOSE= MOCK_HEALTH_OK=0
assert_nonzero "$rc" "brak /health/ -> exit != 0"
assert_file_contains "$TEST_ROOT/tu-out.log" "nie odpowiedzial na /health/" "brak /health/: czytelny komunikat"
assert_file_not_contains "$TEST_ROOT/tu-out.log" "Sprzatam shadow stack" "brak /health/ (KEEP_SHADOW=1): shadow zostaje"

# 5. Kandydat padl przy starcie -> wykryte od razu, nie po timeoucie.
tu_run BPP_DATABASE_COMPOSE= MOCK_HEALTH_OK=0 MOCK_APP_RUNNING=false
assert_nonzero "$rc" "kandydat padl -> exit != 0"
assert_file_contains "$TEST_ROOT/tu-out.log" "zakonczyl dzialanie przy starcie" "kandydat padl: czytelny komunikat"

# 5b. Bez terminala (KEEP_SHADOW nieustawione, stdin=/dev/null): po bledzie
#     logi kandydata na wyjsciu, POTEM sprzatanie - nikt nie obejrzy stacka.
tu_run BPP_DATABASE_COMPOSE= MOCK_HEALTH_OK=0 KEEP_SHADOW=
assert_nonzero "$rc" "bez terminala, kandydat nie wstaje -> exit != 0"
assert_file_contains "$TEST_ROOT/tu-out.log" "Ostatnie linie logu kandydata" "bez terminala: logi kandydata wypisane"
assert_file_contains "$TEST_ROOT/tu-out.log" "Sprzatam shadow stack (bez terminala" "bez terminala: shadow sprzatany po bledzie"
assert_eq "2" "$(grep -c 'rm -f bpp-shadow-appserver' "$TU_LOG")" "bez terminala: cleanup na starcie + po bledzie"

# 5c. Blad PRZED shadow stackiem (brak miejsca) - nic do sprzatania, zero rm.
tu_run BPP_DATABASE_COMPOSE= MOCK_DB_MB=999999999 KEEP_SHADOW=0
assert_file_not_contains "$TU_LOG" "rm -f bpp-shadow-appserver" "blad przed shadow: nic nie sprzatane (nic nie stalo)"

# 5d. Blokada: inna proba zyje -> exit 2, zero operacji dockera.
mkdir -p "$TU_LOCK"; echo "$$" > "$TU_LOCK/pid"
tu_run BPP_DATABASE_COMPOSE=
assert_exit 2 "$rc" "blokada zajeta przez zywy proces -> exit 2"
if [ -s "$TU_LOG" ]; then fail "blokada zajeta: docker nie powinien byc wolany"; else pass "blokada zajeta: docker nie wolany"; fi
if [ -f "$TU_LOCK/pid" ] && [ "$(cat "$TU_LOCK/pid")" = "$$" ]; then pass "blokada zajeta: cudza blokada nietknieta"; else fail "blokada zajeta: cudza blokada naruszona"; fi
rm -rf "$TU_LOCK"

# 5e. Osierocona blokada (martwy pid) -> przejecie, przebieg OK, blokada zwolniona.
mkdir -p "$TU_LOCK"; echo "999999" > "$TU_LOCK/pid"
tu_run BPP_DATABASE_COMPOSE=
assert_exit 0 "$rc" "osierocona blokada -> przejeta, exit 0"
if [ -e "$TU_LOCK" ]; then fail "po przebiegu blokada powinna byc zwolniona"; else pass "po przebiegu blokada zwolniona"; fi

# 6. Strona glowna 500 -> exit != 0.
tu_run BPP_DATABASE_COMPOSE= MOCK_ROOT_CODE=500
assert_nonzero "$rc" "strona glowna 500 -> exit != 0"

# 7. Tryb external: shadow-baza = Debianowy postgres w majorze z .env,
#    rozmiar przez sentinela (psql -h do zewnetrznej bazy).
tu_run BPP_DATABASE_COMPOSE=docker-compose.database.external.yml
assert_exit 0 "$rc" "external: pelny przebieg -> exit 0"
assert_file_contains "$TU_LOG" "--entrypoint bash postgres:17 /usr/local/bin/docker-entrypoint-autotune.sh postgres" "external: shadow-baza postgres:<major> (nie -alpine)"
assert_file_contains "$TU_LOG" "compose exec -T dbserver sh -c psql -h" "external: rozmiar bazy przez sentinela"

# ======================= Podsumowanie =======================
echo ""
echo "Wynik: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

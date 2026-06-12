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

# ======================= Podsumowanie =======================
echo ""
echo "Wynik: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

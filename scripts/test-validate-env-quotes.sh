#!/usr/bin/env bash
#
# Test dla scripts/validate-env-quotes.sh.
#
# Buduje izolowana piaskownice w mktemp -d, pisze syntetyczne .env z roznymi
# kombinacjami cudzyslowow, uruchamia walidator i fix-er, asercjuje wyniki.
#
# Uruchomienie: `make test-validate-env-quotes` lub
#   `bash scripts/test-validate-env-quotes.sh`

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/validate-env-quotes.sh"

if [ ! -f "$SCRIPT" ]; then
    echo "BLAD: brak $SCRIPT" >&2
    exit 1
fi

TEST_ROOT="$(mktemp -d -t bpp-validate-test-XXXXXX)"
TEST_REPO="$TEST_ROOT/repo"
TEST_CONFIGS="$TEST_ROOT/configs"

mkdir -p "$TEST_REPO/scripts" "$TEST_CONFIGS"

# Kopia walidatora do test-repo (skrypt liczy REPO_DIR jako parent katalogu
# w ktorym sam sie znajduje, wiec REPO_DIR=$TEST_REPO przy tym layout-cie).
cp "$SCRIPT" "$TEST_REPO/scripts/validate-env-quotes.sh"
chmod +x "$TEST_REPO/scripts/validate-env-quotes.sh"

# shellcheck disable=SC2317  # wywolywane przez trap, shellcheck tego nie widzi
cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0

# Asercja: poprzednie polecenie zwrocilo oczekiwany kod wyjscia.
# Argumenty: $1 = oczekiwany exit code, $2 = realny exit code, $3 = nazwa testu.
assert_exit() {
    local expected="$1" actual="$2" name="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $name"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: $name (oczekiwane exit=$expected, otrzymano exit=$actual)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# Asercja: plik zawiera dokladnie podana zawartosc.
assert_file_eq() {
    local file="$1" expected="$2" name="$3"
    local actual
    actual="$(cat "$file")"
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: $name"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: $name"
        echo "    --- expected ---"
        printf '    %s\n' "${expected//$'\n'/$'\n'    }"
        echo "    --- actual ---"
        printf '    %s\n' "${actual//$'\n'/$'\n'    }"
        echo "    ----------------"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# Asercja: stdout/stderr poprzedniego polecenia zawiera podany substring.
assert_contains() {
    local haystack="$1" needle="$2" name="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        echo "  PASS: $name"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: $name (brak substringa '$needle')"
        echo "    --- output ---"
        printf '%s\n' "$haystack" | sed 's/^/    /'
        echo "    ----------------"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

reset_env() {
    rm -f "$TEST_REPO/.env" "$TEST_CONFIGS/.env"
    rm -f "$TEST_REPO"/.env.bak.* "$TEST_CONFIGS"/.env.bak.* 2>/dev/null || true
    # Repo .env musi istniec i wskazywac na BPP_CONFIGS_DIR (skrypt potrzebuje
    # tego do zlokalizowania drugiego pliku).
    printf 'BPP_CONFIGS_DIR=%s\n' "$TEST_CONFIGS" > "$TEST_REPO/.env"
}

run_validator() {
    bash "$TEST_REPO/scripts/validate-env-quotes.sh" "$@"
}

# === Test 1: pusty stack -> exit 0 ===
echo "=== Test 1: czyste pliki bez cudzyslowow ==="
reset_env
cat > "$TEST_CONFIGS/.env" <<'EOF'
DJANGO_BPP_DB_USER=bpp
DJANGO_BPP_DB_NAME=bpp
DJANGO_BPP_REDIS_PORT=6379
DOCKER_VERSION=latest
EOF
set +e
run_validator >/dev/null 2>&1
rc=$?
set -e
assert_exit 0 "$rc" "validator zwraca 0 gdy brak cudzyslowow"

# === Test 2: pojedyncze cudzyslowy -> exit 1 ===
echo "=== Test 2: wykrywa podwojne cudzyslowy ==="
reset_env
cat > "$TEST_CONFIGS/.env" <<'EOF'
DJANGO_BPP_DB_USER="bpp"
DJANGO_BPP_DB_PASSWORD=plain_pass
EOF
set +e
output="$(run_validator 2>&1)"
rc=$?
set -e
assert_exit 1 "$rc" "validator zwraca 1 gdy sa podwojne cudzyslowy"
assert_contains "$output" 'DJANGO_BPP_DB_USER="bpp"' "raport zawiera nazwe zmiennej i wartosc"
assert_contains "$output" "make fix-env-quotes" "raport sugeruje uzyc fix-env-quotes"

# === Test 3: pojedyncze apostrofy -> exit 1 ===
echo "=== Test 3: wykrywa pojedyncze apostrofy ==="
reset_env
cat > "$TEST_CONFIGS/.env" <<'EOF'
DJANGO_BPP_DB_USER='bpp'
EOF
set +e
output="$(run_validator 2>&1)"
rc=$?
set -e
assert_exit 1 "$rc" "validator zwraca 1 gdy sa apostrofy"
assert_contains "$output" "DJANGO_BPP_DB_USER='bpp'" "raport pokazuje wartosc w apostrofach"

# === Test 4: cudzyslowy w srodku wartosci NIE sa flagowane ===
echo "=== Test 4: nie flaguje cudzyslowow ktore nie otaczaja wartosci ==="
reset_env
cat > "$TEST_CONFIGS/.env" <<'EOF'
KEY1=foo"bar
KEY2=foo"bar"baz
KEY3="foo
KEY4=foo"
KEY5="
EOF
set +e
run_validator >/dev/null 2>&1
rc=$?
set -e
assert_exit 0 "$rc" "embedded i niezbalansowane cudzyslowy nie sa naruszeniem"

# === Test 5: --fix strip-uje cudzyslowy in-place i tworzy backup ===
echo "=== Test 5: --fix strip-uje + backup ==="
reset_env
cat > "$TEST_CONFIGS/.env" <<'EOF'
# Komentarz na gorze
DJANGO_BPP_DB_USER="bpp"
DJANGO_BPP_DB_NAME='bpp'
DJANGO_BPP_DB_PASSWORD=plain_pass
DJANGO_BPP_REDIS_PORT="6379"

# Pusty wiersz nizej zostaje
EOF
set +e
output="$(run_validator --fix 2>&1)"
rc=$?
set -e
assert_exit 0 "$rc" "fix zwraca 0"
assert_contains "$output" "3 naruszen naprawionych" "raportuje liczbe naprawionych naruszen"
assert_contains "$output" ".env.bak." "raportuje sciezke backupu"

EXPECTED_AFTER_FIX="# Komentarz na gorze
DJANGO_BPP_DB_USER=bpp
DJANGO_BPP_DB_NAME=bpp
DJANGO_BPP_DB_PASSWORD=plain_pass
DJANGO_BPP_REDIS_PORT=6379

# Pusty wiersz nizej zostaje"
assert_file_eq "$TEST_CONFIGS/.env" "$EXPECTED_AFTER_FIX" "po fix-ie cudzyslowy znikly, komentarze zostaly"

backup_count="$(find "$TEST_CONFIGS" -maxdepth 1 -name '.env.bak.*' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$backup_count" = "1" ]; then
    echo "  PASS: backup .env.bak.<ts> zostal utworzony"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "  FAIL: oczekiwany 1 plik backupu, znaleziono $backup_count"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# === Test 6: --fix idempotentny (drugi run nic nie robi) ===
echo "=== Test 6: --fix idempotentny ==="
set +e
output="$(run_validator --fix 2>&1)"
rc=$?
set -e
assert_exit 0 "$rc" "drugi run --fix zwraca 0"
assert_contains "$output" "brak naruszen do naprawy" "drugi run nie tworzy backupu"

# === Test 7: walidator po fix-ie zwraca 0 ===
echo "=== Test 7: walidacja po fix-ie ==="
set +e
run_validator >/dev/null 2>&1
rc=$?
set -e
assert_exit 0 "$rc" "validator po fix-ie zwraca 0"

# === Test 8: oba pliki .env (repo + configs) sa walidowane ===
echo "=== Test 8: walidacja obu plikow .env ==="
reset_env
cat > "$TEST_REPO/.env" <<EOF
BPP_CONFIGS_DIR=$TEST_CONFIGS
COMPOSE_PROJECT_NAME="my_project"
EOF
cat > "$TEST_CONFIGS/.env" <<'EOF'
DJANGO_BPP_DB_USER=bpp
EOF
set +e
output="$(run_validator 2>&1)"
rc=$?
set -e
assert_exit 1 "$rc" "validator wykrywa cudzyslow w repo .env"
assert_contains "$output" "COMPOSE_PROJECT_NAME=" "raport wskazuje na repo .env"

# === Test 9: --fix obejmuje oba pliki ===
echo "=== Test 9: --fix obu plikow ==="
reset_env
cat > "$TEST_REPO/.env" <<EOF
BPP_CONFIGS_DIR=$TEST_CONFIGS
COMPOSE_PROJECT_NAME="my_project"
EOF
cat > "$TEST_CONFIGS/.env" <<'EOF'
DJANGO_BPP_DB_USER="bpp"
EOF
set +e
run_validator --fix >/dev/null 2>&1
rc=$?
set -e
assert_exit 0 "$rc" "fix zwraca 0 dla obu plikow"

repo_user="$(grep '^COMPOSE_PROJECT_NAME=' "$TEST_REPO/.env" | cut -d= -f2-)"
configs_user="$(grep '^DJANGO_BPP_DB_USER=' "$TEST_CONFIGS/.env" | cut -d= -f2-)"
if [ "$repo_user" = "my_project" ] && [ "$configs_user" = "bpp" ]; then
    echo "  PASS: oba pliki stripnięte poprawnie"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "  FAIL: repo='$repo_user' (oczekiwane 'my_project'), configs='$configs_user' (oczekiwane 'bpp')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# === Test 10: trailing whitespace zachowany ===
echo "=== Test 10: trailing whitespace zachowany ==="
reset_env
printf 'KEY="bpp"   \n' > "$TEST_CONFIGS/.env"
set +e
run_validator --fix >/dev/null 2>&1
rc=$?
set -e
assert_exit 0 "$rc" "fix przeszedl"
expected_line='KEY=bpp   '
actual_line="$(cat "$TEST_CONFIGS/.env")"
if [ "$actual_line" = "$expected_line" ]; then
    echo "  PASS: trailing spaces zostaly zachowane po stripie"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "  FAIL: oczekiwane '$expected_line', otrzymano '$actual_line'"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# === Test 11: pusta wartosc w cudzyslowach -> stripped ===
echo "=== Test 11: pusta wartosc w cudzyslowach ==="
reset_env
cat > "$TEST_CONFIGS/.env" <<'EOF'
EMPTY_QUOTED=""
EOF
set +e
run_validator --fix >/dev/null 2>&1
rc=$?
set -e
assert_exit 0 "$rc" "fix dziala dla pustej wartosci w cudzyslowach"
assert_file_eq "$TEST_CONFIGS/.env" "EMPTY_QUOTED=" "pusta wartosc w cudzyslowach -> pusta wartosc"

# === Test 12: nieznany flag -> exit 2 ===
echo "=== Test 12: error na nieznanym flagu ==="
set +e
run_validator --foo >/dev/null 2>&1
rc=$?
set -e
assert_exit 2 "$rc" "nieznany flag zwraca 2"

# === Test 13: nieuciekniete `$X` w wartosci -> exit 1 ===
echo "=== Test 13: wykrywa nieuciekniete \$X ==="
reset_env
cat > "$TEST_CONFIGS/.env" <<'EOF'
DJANGO_BPP_DB_PASSWORD=abc$xyz
ESCAPED_OK=abc$$xyz
PLAIN=abc
WITH_BRACE=foo${var}bar
EOF
set +e
output="$(run_validator 2>&1)"
rc=$?
set -e
assert_exit 1 "$rc" "validator zwraca 1 gdy sa nieuciekniete \$X"
assert_contains "$output" "[DOLLAR] " "raport oznacza naruszenie typem DOLLAR"
assert_contains "$output" "DJANGO_BPP_DB_PASSWORD=abc\$xyz" "raport pokazuje linie z \$X"
assert_contains "$output" "WITH_BRACE=foo\${var}bar" "raport pokazuje linie z \${VAR}"
# Negative: poprawnie escape-owane $$ NIE powinno byc flagowane.
case "$output" in
    *"ESCAPED_OK="*)
        echo "  FAIL: ESCAPED_OK (z \$\$) zostal flagowany jako naruszenie"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        ;;
    *)
        echo "  PASS: ESCAPED_OK (z \$\$) nie jest flagowany"
        PASS_COUNT=$((PASS_COUNT + 1))
        ;;
esac

# === Test 14: --fix escape-uje `$X` -> `$$X` ===
echo "=== Test 14: --fix escape-uje \$X ==="
reset_env
cat > "$TEST_CONFIGS/.env" <<'EOF'
DJANGO_BPP_DB_PASSWORD=abc$xyz
ESCAPED_OK=abc$$xyz
PLAIN=abc
WITH_BRACE=foo${var}bar
LEADING=$start
EOF
set +e
output="$(run_validator --fix 2>&1)"
rc=$?
set -e
assert_exit 0 "$rc" "fix zwraca 0 dla \$X naruszen"
EXPECTED_AFTER_DOLLAR_FIX="DJANGO_BPP_DB_PASSWORD=abc\$\$xyz
ESCAPED_OK=abc\$\$xyz
PLAIN=abc
WITH_BRACE=foo\$\${var}bar
LEADING=\$\$start"
assert_file_eq "$TEST_CONFIGS/.env" "$EXPECTED_AFTER_DOLLAR_FIX" "po fix-ie wszystkie \$X sa escape-owane do \$\$X"

# === Test 15: --fix idempotentny dla `$X` ===
echo "=== Test 15: --fix idempotentny dla \$X ==="
set +e
output="$(run_validator --fix 2>&1)"
rc=$?
set -e
assert_exit 0 "$rc" "drugi run --fix zwraca 0"
assert_contains "$output" "brak naruszen do naprawy" "drugi run nie zmienia juz-escape-owanej wartosci"

# === Test 16: strip cudzyslowow + escape `$` w jednym przebiegu ===
echo "=== Test 16: strip + escape razem ==="
reset_env
cat > "$TEST_CONFIGS/.env" <<'EOF'
PASS_SQ='abc$xyz'
PASS_DQ="abc$xyz"
PORT="5672"
EOF
set +e
run_validator --fix >/dev/null 2>&1
rc=$?
set -e
assert_exit 0 "$rc" "fix zwraca 0 dla mieszanki"
EXPECTED_MIXED="PASS_SQ=abc\$\$xyz
PASS_DQ=abc\$\$xyz
PORT=5672"
assert_file_eq "$TEST_CONFIGS/.env" "$EXPECTED_MIXED" "cudzyslowy stripnięte + \$ escape-owane"

# === Test 17: `$` przed znakiem nie-identyfikatora zostawiony ===
echo "=== Test 17: \$ przed nie-identyfikatorem nie jest escape-owany ==="
reset_env
cat > "$TEST_CONFIGS/.env" <<'EOF'
KEY1=abc$
KEY2=abc$ xyz
KEY3=abc$1xyz
EOF
set +e
run_validator >/dev/null 2>&1
rc=$?
set -e
assert_exit 0 "$rc" "\$ przed end-of-string/space/digit nie jest naruszeniem (Compose tego nie interpoluje)"

# === Podsumowanie ===
echo ""
echo "================================================================"
echo "PODSUMOWANIE: $PASS_COUNT pass, $FAIL_COUNT fail"
echo "================================================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0

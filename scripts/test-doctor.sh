#!/usr/bin/env bash
#
# Testy scripts/doctor.sh w trybie nieinteraktywnym.
#
# Bez prawdziwego make, bez dockera, bez sieci. Mockujemy `make` w PATH przez
# stub, ktory loguje swoje argumenty (czyli wolany cel) do pliku i zwraca 0.
# Asercjujemy, ze dla danego argumentu doctor wola wlasciwy cel make.
#
# Uruchomienie: `make test-doctor` lub `bash scripts/test-doctor.sh`

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/doctor.sh"

if [ ! -f "$SCRIPT" ]; then
    echo "BLAD: brak $SCRIPT" >&2
    exit 1
fi

TEST_ROOT="$(mktemp -d -t bpp-doctor-test-XXXXXX)"
MOCK_BIN="$TEST_ROOT/mock-bin"
export MAKE_LOG="$TEST_ROOT/make-calls.log"

mkdir -p "$MOCK_BIN"

# --- Mock make ---
# Loguje argumenty (wolany cel) i zwraca 0. doctor.sh sprawdza tylko exit code.
cat > "$MOCK_BIN/make" <<EOF
#!/bin/sh
echo "\$*" >> "$MAKE_LOG"
exit 0
EOF
chmod +x "$MOCK_BIN/make"

# shellcheck disable=SC2317  # wywolywane przez trap
cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

PASS=0
FAIL=0

green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }

pass()  { green "  PASS: $1"; PASS=$((PASS + 1)); }
fail()  { red   "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Uruchamia doctor.sh z mockiem make w PATH. MAKE/MAKEFLAGS odpinamy bo gdy
# test odpalony przez `make test-doctor`, make eksportuje MAKE=<sciezka> do
# recipe - doctor uzylby prawdziwego make zamiast stuba.
run_doctor() {
    : > "$MAKE_LOG"
    set +e
    # Wynik (echa menu) nieistotny - asercjujemy log make; wyciszamy.
    env -u MAKE -u MAKEFLAGS PATH="$MOCK_BIN:$PATH" bash "$SCRIPT" "$@" >/dev/null 2>&1
    RUN_EXIT=$?
    set -e
}

assert_exit() {
    local expected="$1" actual="$2" name="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$name"
    else
        fail "$name (oczekiwane exit=$expected, otrzymano exit=$actual)"
    fi
}

assert_log_has() {
    local needle="$1" name="$2"
    if grep -qF -- "$needle" "$MAKE_LOG" 2>/dev/null; then
        pass "$name"
    else
        fail "$name (brak '$needle' w logu make)"
        printf '    --- make-calls.log ---\n%s\n    ----------------------\n' \
            "$(cat "$MAKE_LOG")" >&2
    fi
}

assert_log_lines() {
    local expected="$1" name="$2" actual
    # grep -c zawsze drukuje liczbe (takze 0); exit 1 przy zero trafien jest tu
    # nieistotny, wiec NIE doklejamy `|| echo 0` (dawalo "0\n0").
    actual="$(grep -c . "$MAKE_LOG" 2>/dev/null)" || true
    if [ "$actual" = "$expected" ]; then
        pass "$name"
    else
        fail "$name (oczekiwano $expected linii, otrzymano $actual)"
    fi
}

echo "== Testy scripts/doctor.sh (tryb nieinteraktywny) =="

# Pojedyncze pozycje -> wlasciwy cel make.
run_doctor mail
assert_exit 0 "$RUN_EXIT" "mail: exit 0"
assert_log_has "test-email" "mail -> make test-email"
assert_log_lines 1 "mail: dokladnie jeden cel"

run_doctor ntfy
assert_log_has "test-ntfy" "ntfy -> make test-ntfy"
assert_log_lines 1 "ntfy: dokladnie jeden cel"

run_doctor rollbar
assert_log_has "test-rollbar" "rollbar -> make test-rollbar"
assert_log_lines 1 "rollbar: dokladnie jeden cel"

run_doctor health
assert_log_has "health" "health -> make health"
assert_log_lines 1 "health: dokladnie jeden cel"

run_doctor backup
assert_log_has "backup-cycle" "backup -> make backup-cycle"
assert_log_lines 1 "backup: dokladnie jeden cel"

# "wszystko" = mail + ntfy + rollbar (BEZ health/backup).
run_doctor all
assert_exit 0 "$RUN_EXIT" "all: exit 0"
assert_log_has "test-email" "all zawiera test-email"
assert_log_has "test-ntfy" "all zawiera test-ntfy"
assert_log_has "test-rollbar" "all zawiera test-rollbar"
assert_log_lines 3 "all: dokladnie trzy cele"
if grep -qE 'health|backup-cycle' "$MAKE_LOG"; then
    fail "all: NIE powinno zawierac health/backup"
else
    pass "all: bez health/backup"
fi

# Nieznany argument -> exit 2, zero wywolan make.
run_doctor cosniezdefiniowanego
assert_exit 2 "$RUN_EXIT" "nieznany argument -> exit 2"
assert_log_lines 0 "nieznany argument: zadnego make"

echo ""
echo "== Wynik: $PASS PASS, $FAIL FAIL =="
[ "$FAIL" -eq 0 ]

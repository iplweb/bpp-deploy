#!/usr/bin/env bash
#
# Testy scripts/post-deploy-check.sh — bez prawdziwego dockera, bez sieci.
#
# Mockujemy `docker` (zwraca kontrolowany `compose ps`) i `make` (no-op) w PATH.
# Skrypt odpalamy z stdin=/dev/null (nie-TTY), wiec NIGDY nie pyta interaktywnie
# i nie zawiesza testu — sprawdzamy sciezki: OK -> exit 0, problem -> exit 1.
#
# Uruchomienie: `make test-post-deploy-check` lub `bash scripts/test-post-deploy-check.sh`

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/post-deploy-check.sh"

if [ ! -f "$SCRIPT" ]; then
	echo "BLAD: brak $SCRIPT" >&2
	exit 1
fi

TEST_ROOT="$(mktemp -d -t bpp-pdc-test-XXXXXX)"
MOCK_BIN="$TEST_ROOT/mock-bin"
export MOCK_PS_FILE="$TEST_ROOT/ps.txt"
mkdir -p "$MOCK_BIN"

# Mock docker: tylko `compose ps ...` -> wypisz zawartosc MOCK_PS_FILE. Reszta no-op.
cat > "$MOCK_BIN/docker" <<EOF
#!/bin/sh
if [ "\$1" = "compose" ] && [ "\$2" = "ps" ]; then
	cat "$MOCK_PS_FILE" 2>/dev/null
	exit "\${MOCK_PS_EXIT:-0}"
fi
exit 0
EOF
chmod +x "$MOCK_BIN/docker"

# Mock make: no-op (sciezka problemu wola `make health`).
cat > "$MOCK_BIN/make" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$MOCK_BIN/make"

# shellcheck disable=SC2317  # wywolywane przez trap
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

PASS=0
FAIL=0
green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
pass()  { green "  PASS: $1"; PASS=$((PASS + 1)); }
fail()  { red   "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Ustawia kontrolowany `docker compose ps` i odpala bramke nie-interaktywnie.
# stdin=/dev/null -> [ -t 0 ] falszywe -> sciezka nie-TTY (bez promptu).
run_check() {
	printf '%b' "$1" > "$MOCK_PS_FILE"
	set +e
	env -u MAKE -u MAKEFLAGS \
		MOCK_PS_EXIT="${MOCK_PS_EXIT:-0}" \
		${BPP_SKIP_HEALTH_GATE:+BPP_SKIP_HEALTH_GATE=$BPP_SKIP_HEALTH_GATE} \
		PATH="$MOCK_BIN:$PATH" \
		bash "$SCRIPT" </dev/null >/dev/null 2>&1
	RUN_EXIT=$?
	set -e
}

assert_exit() {
	if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (oczekiwane exit=$1, otrzymano exit=$2)"; fi
}

echo "== Testy scripts/post-deploy-check.sh =="

# Wszystkie zdrowe (w tym jedna usluga bez healthchecka: health puste) -> OK.
run_check 'dbserver\trunning\thealthy\nappserver\trunning\thealthy\nredis\trunning\t\n'
assert_exit 0 "$RUN_EXIT" "wszystkie running/healthy -> exit 0"

# Jedna usluga unhealthy -> problem.
run_check 'dbserver\trunning\thealthy\nappserver\trunning\tunhealthy\n'
assert_exit 1 "$RUN_EXIT" "usluga unhealthy -> exit 1"

# Jedna usluga restarting (crash-loop, np. bez healthchecka) -> problem.
run_check 'dbserver\trunning\thealthy\nworkerserver\trestarting\t\n'
assert_exit 1 "$RUN_EXIT" "usluga restarting -> exit 1"

# on-demand backup-runner jako `exited` NIE jest problemem (fail-open na exited).
run_check 'dbserver\trunning\thealthy\nbackup-runner\texited\t\n'
assert_exit 0 "$RUN_EXIT" "exited (backup-runner) NIE flagowane -> exit 0"

# Pusty `docker compose ps` (projekt bez uslug, ps OK) -> exit 0.
run_check ''
assert_exit 0 "$RUN_EXIT" "pusty ps (rc=0) -> exit 0"

# BLAD `docker compose ps` (rc!=0, np. daemon down) -> fail-open exit 0, ale BEZ
# falszywego "zdrowe" (nie twierdzimy zdrowia, ktorego nie sprawdzilismy).
MOCK_PS_EXIT=1
run_check 'dbserver\trunning\thealthy\n'
assert_exit 0 "$RUN_EXIT" "blad docker compose ps (fail-open) -> exit 0"
unset MOCK_PS_EXIT

# Opt-out BPP_SKIP_HEALTH_GATE pomija bramke NAWET przy unhealthy (automatyka:
# upgrade-postgres.sh / restore.sh wolajace `make up` pod set -e).
BPP_SKIP_HEALTH_GATE=1
run_check 'appserver\trunning\tunhealthy\n'
assert_exit 0 "$RUN_EXIT" "BPP_SKIP_HEALTH_GATE -> pomija bramke, exit 0"
unset BPP_SKIP_HEALTH_GATE

echo ""
echo "== Wynik: $PASS PASS, $FAIL FAIL =="
[ "$FAIL" -eq 0 ]

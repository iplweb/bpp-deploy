#!/usr/bin/env bash
#
# Testy scripts/autoupdate.sh — bez prawdziwego gita/dockera/make, bez sieci.
#
# Mockujemy w PATH:
#   git    -> fetch/rev-parse/merge-base/pull sterowane zmiennymi MOCK_GIT_*,
#             `git pull` zapisuje marker do $MARKER.
#   docker -> `compose config --images` staly; `compose pull` przelacza stan
#             (gdy MOCK_IMAGE_CHANGE=1); `image inspect` zwraca ID zalezne od
#             stanu (przed/po) -> tak symulujemy nowszy obraz.
#   make   -> zapisuje wywolany cel do $MARKER; `db-backup` moze zwrocic blad
#             (MOCK_BACKUP_FAIL=1).
#
# Sprawdzamy DECYZJE (czy wolano `make run`), a nie prawdziwe wdrozenie.
#
# Uruchomienie: `make test-autoupdate` lub `bash scripts/test-autoupdate.sh`

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/autoupdate.sh"

if [ ! -f "$SCRIPT" ]; then
	echo "BLAD: brak $SCRIPT" >&2
	exit 1
fi

TEST_ROOT="$(mktemp -d -t bpp-au-test-XXXXXX)"
MOCK_BIN="$TEST_ROOT/mock-bin"
mkdir -p "$MOCK_BIN"

# --- Mock git ---------------------------------------------------------------
# rev-parse HEAD        -> MOCK_GIT_LOCAL   (domyslnie "AAA")
# rev-parse origin/main -> MOCK_GIT_REMOTE  (domyslnie "AAA" == brak zmian)
# merge-base --is-ancestor -> exit 0 gdy MOCK_GIT_ANCESTOR=1 (domyslnie 1)
# fetch                 -> exit 0 (MOCK_GIT_FETCH_FAIL=1 -> blad)
# pull                  -> zapisz "make? git-pull" do MARKER, exit 0
cat > "$MOCK_BIN/git" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "rev-parse --git-dir") echo ".git"; exit 0 ;;
esac
case "$1" in
  fetch) [ "${MOCK_GIT_FETCH_FAIL:-0}" = "1" ] && exit 1; exit 0 ;;
  rev-parse)
    case "$2" in
      HEAD) echo "${MOCK_GIT_LOCAL:-AAA}"; exit 0 ;;
      origin/main) echo "${MOCK_GIT_REMOTE:-AAA}"; exit 0 ;;
    esac
    echo "X"; exit 0 ;;
  merge-base) [ "${MOCK_GIT_ANCESTOR:-1}" = "1" ] && exit 0; exit 1 ;;
  pull) echo "git-pull" >> "$MARKER"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$MOCK_BIN/git"

# --- Mock docker ------------------------------------------------------------
# compose config --images -> jeden obraz
# compose pull            -> gdy MOCK_IMAGE_CHANGE=1, ustaw stan "after"
# image inspect           -> ID zalezne od pliku stanu (przed/po pull)
cat > "$MOCK_BIN/docker" <<'EOF'
#!/bin/sh
if [ "$1" = "compose" ] && [ "$2" = "config" ]; then
	echo "iplweb/bpp_appserver:latest"; exit 0
fi
if [ "$1" = "compose" ] && [ "$2" = "pull" ]; then
	[ "${MOCK_IMAGE_CHANGE:-0}" = "1" ] && echo after > "$STATE_FILE"
	exit 0
fi
if [ "$1" = "image" ] && [ "$2" = "inspect" ]; then
	if [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE")" = "after" ]; then
		echo "sha256:new"; else echo "sha256:old"; fi
	exit 0
fi
exit 0
EOF
chmod +x "$MOCK_BIN/docker"

# --- Mock make --------------------------------------------------------------
# Zapisuje cel do MARKER. db-backup moze zwrocic blad (MOCK_BACKUP_FAIL=1).
cat > "$MOCK_BIN/make" <<'EOF'
#!/bin/sh
echo "make-$1" >> "$MARKER"
if [ "$1" = "db-backup" ] && [ "${MOCK_BACKUP_FAIL:-0}" = "1" ]; then
	exit 1
fi
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

# Odpala jeden cykl w izolacji. Kazdy przebieg: swiezy MARKER, swiezy stan
# obrazu, swiezy katalog locka. Zmienne MOCK_* przekazywane przez srodowisko.
run_cycle() {
	export MARKER="$TEST_ROOT/marker.$$.$RANDOM"
	export STATE_FILE="$TEST_ROOT/state.$$.$RANDOM"
	: > "$MARKER"
	rm -f "$STATE_FILE"
	set +e
	env -u MAKE -u MAKEFLAGS \
		PATH="$MOCK_BIN:$PATH" \
		MARKER="$MARKER" STATE_FILE="$STATE_FILE" \
		AUTOUPDATE_LOCK_DIR="$TEST_ROOT/lock.$$.$RANDOM" \
		MOCK_GIT_LOCAL="${MOCK_GIT_LOCAL:-AAA}" \
		MOCK_GIT_REMOTE="${MOCK_GIT_REMOTE:-AAA}" \
		MOCK_GIT_ANCESTOR="${MOCK_GIT_ANCESTOR:-1}" \
		MOCK_GIT_FETCH_FAIL="${MOCK_GIT_FETCH_FAIL:-0}" \
		MOCK_IMAGE_CHANGE="${MOCK_IMAGE_CHANGE:-0}" \
		MOCK_BACKUP_FAIL="${MOCK_BACKUP_FAIL:-0}" \
		AUTOUPDATE_DB_BACKUP="${AUTOUPDATE_DB_BACKUP:-0}" \
		AUTOUPDATE_WARNING_MINUTES="${AUTOUPDATE_WARNING_MINUTES:-0}" \
		bash "$SCRIPT" >/dev/null 2>&1
	RUN_EXIT=$?
	set -e
}

marker_has() { grep -q "$1" "$MARKER" 2>/dev/null; }

assert_deployed() {
	if marker_has "make-run"; then pass "$1"; else fail "$1 (oczekiwano make run)"; fi
}
assert_not_deployed() {
	if marker_has "make-run"; then fail "$1 (make run nie powinien byc wywolany)"; else pass "$1"; fi
}
assert_exit() {
	if [ "$1" = "$RUN_EXIT" ]; then pass "$2"; else fail "$2 (oczekiwane exit=$1, otrzymano $RUN_EXIT)"; fi
}

echo "== Testy scripts/autoupdate.sh =="

# 1. Brak zmian (obraz i commit aktualne) -> brak deployu.
MOCK_GIT_REMOTE=AAA MOCK_IMAGE_CHANGE=0 run_cycle
assert_not_deployed "brak zmian -> brak make run"
assert_exit 0 "brak zmian -> exit 0"

# 2. Nowy obraz -> deploy (bez git pull, bo commit ten sam).
MOCK_GIT_REMOTE=AAA MOCK_IMAGE_CHANGE=1 run_cycle
assert_deployed "nowy obraz -> make run"
if marker_has "git-pull"; then fail "nowy obraz nie powinien wolac git pull"; else pass "nowy obraz -> bez git pull"; fi

# 3. Nowy commit (fast-forward) -> git pull + deploy.
MOCK_GIT_REMOTE=BBB MOCK_GIT_ANCESTOR=1 MOCK_IMAGE_CHANGE=0 run_cycle
assert_deployed "nowy commit -> make run"
if marker_has "git-pull"; then pass "nowy commit -> git pull"; else fail "nowy commit -> brak git pull"; fi

# 4. Rozjazd (nie fast-forward) i brak nowego obrazu -> brak deployu.
MOCK_GIT_REMOTE=BBB MOCK_GIT_ANCESTOR=0 MOCK_IMAGE_CHANGE=0 run_cycle
assert_not_deployed "rozjazd bez nowego obrazu -> brak make run"

# 5. Backup wlaczony i pada -> brak deployu, exit != 0.
AUTOUPDATE_DB_BACKUP=1 MOCK_BACKUP_FAIL=1 MOCK_IMAGE_CHANGE=1 run_cycle
assert_not_deployed "backup pada -> brak make run"
if [ "$RUN_EXIT" -ne 0 ]; then pass "backup pada -> exit != 0"; else fail "backup pada -> exit powinien byc != 0"; fi

# 6. Backup wlaczony i OK -> backup + deploy.
AUTOUPDATE_DB_BACKUP=1 MOCK_BACKUP_FAIL=0 MOCK_IMAGE_CHANGE=1 run_cycle
if marker_has "make-db-backup"; then pass "backup on -> make db-backup"; else fail "backup on -> brak db-backup"; fi
assert_deployed "backup on + OK -> make run"

# 7. AUTOUPDATE_WARNING_MINUTES -> deploy przez sesje z ostrzezeniem.
# Rozroznik: sesja z ostrzezeniem zaczyna od `make pull`, a zwykla sciezka
# autoupdate wola `docker compose pull` bezposrednio i `make pull` nie pada.
# Obraz w tym tescie nie zna komend countdownu (mock dockera nie zwraca
# 'show_countdown'), wiec sprawdzamy tez, ze brak wsparcia NIE zatrzymuje petli.
AUTOUPDATE_WARNING_MINUTES=5 MOCK_IMAGE_CHANGE=1 run_cycle
assert_deployed "ostrzezenie wlaczone -> make run"
if marker_has "make-pull"; then pass "ostrzezenie wlaczone -> sesja z ostrzezeniem (make pull)"; else fail "ostrzezenie wlaczone -> brak make pull"; fi
assert_exit 0 "ostrzezenie + stary obraz -> exit 0 (petla nie staje)"

# 8. Lock zajety -> exit 0, brak deployu.
export MARKER="$TEST_ROOT/marker.lock"
: > "$MARKER"
LOCKED="$TEST_ROOT/held-lock.d"
mkdir -p "$LOCKED"
set +e
env -u MAKE -u MAKEFLAGS PATH="$MOCK_BIN:$PATH" MARKER="$MARKER" \
	STATE_FILE="$TEST_ROOT/state.lock" \
	AUTOUPDATE_LOCK_DIR="$LOCKED" MOCK_IMAGE_CHANGE=1 \
	bash "$SCRIPT" >/dev/null 2>&1
LOCK_EXIT=$?
set -e
if [ "$LOCK_EXIT" = "0" ]; then pass "lock zajety -> exit 0"; else fail "lock zajety -> exit 0 (otrzymano $LOCK_EXIT)"; fi
if grep -q "make-run" "$MARKER" 2>/dev/null; then fail "lock zajety -> nie powinien deployowac"; else pass "lock zajety -> brak make run"; fi

echo ""
echo "Wynik: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]

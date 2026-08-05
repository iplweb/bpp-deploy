#!/usr/bin/env bash
#
# Testy scripts/deploy-with-warning.sh i scripts/site-down-warning.sh
# — bez prawdziwego dockera/make, bez sieci, bez dzialajacej instalacji.
#
# Mockujemy w PATH:
#   docker -> `compose exec -T appserver python src/manage.py ...`; zapisuje
#             wywolana komende Django do $MARKER. `help --commands` udaje obraz
#             ze wsparciem countdownu (albo bez, gdy MOCK_NO_COUNTDOWN=1).
#   make   -> zapisuje cel + informacje czy dostal BPP_SKIP_HEALTH_GATE=1.
#             `run` moze spac (MOCK_RUN_SLEEP) i moze zwrocic blad (MOCK_RUN_FAIL).
# Dodatkowo podmieniamy bramke zdrowia przez POST_DEPLOY_CHECK.
#
# Sprawdzamy DECYZJE i KOLEJNOSC wywolan, nie prawdziwe wdrozenie.
#
# Uruchomienie: `make test-deploy-with-warning` albo bash scripts/test-deploy-with-warning.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$REPO_DIR/scripts/deploy-with-warning.sh"
WARN="$REPO_DIR/scripts/site-down-warning.sh"

for f in "$DEPLOY" "$WARN"; do
	if [ ! -f "$f" ]; then
		echo "BLAD: brak $f" >&2
		exit 1
	fi
done

TEST_ROOT="$(mktemp -d -t bpp-sdw-test-XXXXXX)"
MOCK_BIN="$TEST_ROOT/mock-bin"
mkdir -p "$MOCK_BIN"
trap 'rm -rf "$TEST_ROOT"' EXIT

# --- Mock docker ------------------------------------------------------------
# Interesuje nas wylacznie `docker compose exec -T appserver python src/manage.py ...`.
# Zapisujemy komende Django wraz z argumentami — testy asertuja na tych liniach.
cat > "$MOCK_BIN/docker" <<'EOF'
#!/bin/sh
# przeskocz: compose exec -T appserver python src/manage.py
for a in "$@"; do
	shift
	case "$a" in
		src/manage.py) break ;;
	esac
done
cmd="$1"
case "$cmd" in
	help)
		if [ "${MOCK_NO_COUNTDOWN:-0}" = "1" ]; then
			printf 'migrate\nshell\nstartapp\n'
		else
			printf 'migrate\nshell\nshow_countdown\nstart_countdown\nstop_countdown\nextend_countdown\nshorten_countdown\n'
		fi
		exit 0
		;;
esac
echo "django: $*" >> "$MARKER"
case "$cmd" in
	extend_countdown)
		case " $* " in
			*" --at-least "*) [ "${MOCK_HEARTBEAT_FAIL:-0}" = "1" ] && exit 1 ;;
		esac
		;;
	start_countdown) [ "${MOCK_START_FAIL:-0}" = "1" ] && exit 1 ;;
esac
exit 0
EOF
chmod +x "$MOCK_BIN/docker"

# --- Mock make --------------------------------------------------------------
cat > "$MOCK_BIN/make" <<'EOF'
#!/bin/sh
target="$1"
echo "make: $target gate=${BPP_SKIP_HEALTH_GATE:-unset}" >> "$MARKER"
if [ "$target" = "run" ]; then
	[ -n "${MOCK_RUN_SLEEP:-}" ] && sleep "$MOCK_RUN_SLEEP"
	[ "${MOCK_RUN_FAIL:-0}" = "1" ] && exit 2
fi
exit 0
EOF
chmod +x "$MOCK_BIN/make"

# --- Mock bramki zdrowia ----------------------------------------------------
cat > "$MOCK_BIN/post-deploy-check-mock.sh" <<'EOF'
#!/bin/sh
echo "health-gate" >> "$MARKER"
[ "${MOCK_HEALTH_FAIL:-0}" = "1" ] && exit 1
exit 0
EOF
chmod +x "$MOCK_BIN/post-deploy-check-mock.sh"

export PATH="$MOCK_BIN:$PATH"
export POST_DEPLOY_CHECK="$MOCK_BIN/post-deploy-check-mock.sh"

# --- Harness ----------------------------------------------------------------
PASS=0
FAIL=0

reset_marker() {
	MARKER="$TEST_ROOT/marker.$RANDOM"
	export MARKER
	: > "$MARKER"
}

ok() { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
ko() {
	FAIL=$((FAIL + 1))
	printf '  \033[31m✗\033[0m %s\n' "$1"
	[ -n "${2:-}" ] && printf '      %s\n' "$2"
	printf '      marker:\n'
	sed 's/^/        /' "$MARKER" 2>/dev/null || true
}

assert_exit_zero() {
	if [ "$1" -eq 0 ]; then ok "$2"; else ko "$2" "exit=$1"; fi
}

assert_exit_nonzero() {
	if [ "$1" -ne 0 ]; then ok "$2"; else ko "$2" "exit=$1"; fi
}

# assert_contains <opis> <wzorzec>
assert_contains() {
	if grep -qF -- "$2" "$MARKER"; then ok "$1"; else ko "$1" "brak linii: $2"; fi
}

assert_not_contains() {
	if grep -qF -- "$2" "$MARKER"; then ko "$1" "niechciana linia: $2"; else ok "$1"; fi
}

# assert_before <opis> <wzorzec-wczesniejszy> <wzorzec-pozniejszy>
assert_before() {
	a="$(grep -nF -- "$2" "$MARKER" | head -1 | cut -d: -f1)"
	b="$(grep -nF -- "$3" "$MARKER" | head -1 | cut -d: -f1)"
	if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then
		ok "$1"
	else
		ko "$1" "kolejnosc: '$2' (${a:-brak}) przed '$3' (${b:-brak})"
	fi
}

# Domyslne, szybkie ustawienia sesji: okno banera i heartbeat sciete do sekund.
run_deploy() {
	env \
		SITE_DOWN_TEST_WAIT_SECONDS=1 \
		SITE_DOWN_TICK_INTERVAL=1 \
		SITE_DOWN_HEARTBEAT_INTERVAL=1 \
		"$@" \
		bash "$DEPLOY" >"$TEST_ROOT/out.log" 2>&1
}

echo ""
echo "=== Testy deploy-with-warning.sh ==="
echo ""

# --- 1-3. Sciezka sukcesu: kolejnosc faz + bramka zdrowia -------------------
reset_marker
run_deploy
rc=$?
assert_exit_zero "$rc" "sukces: exit 0"
assert_contains "sukces: wolano make pull" "make: pull"
assert_contains "sukces: wolano start_countdown" "django: start_countdown"
assert_contains "sukces: wolano make run" "make: run"
assert_contains "sukces: wolano bramke zdrowia" "health-gate"
assert_contains "sukces: wolano stop_countdown" "django: stop_countdown"
assert_before "kolejnosc: pull PRZED start_countdown" "make: pull" "django: start_countdown"
assert_before "kolejnosc: start_countdown PRZED make run" "django: start_countdown" "make: run"
assert_before "kolejnosc: make run PRZED bramka zdrowia" "make: run" "health-gate"
assert_before "kolejnosc: bramka zdrowia PRZED stop_countdown" "health-gate" "django: stop_countdown"
assert_contains "make run dostal BPP_SKIP_HEALTH_GATE=1" "make: run gate=1"

# --- 4. Domyslne parametry --------------------------------------------------
reset_marker
run_deploy
assert_contains "domyslnie --banner +5m" "--banner +5m"
assert_contains "domyslnie --service +10m" "--service +10m"
assert_contains "start_countdown jest nieinteraktywny i nadpisuje" "--noinput --force"

reset_marker
run_deploy MINUTES=7 SERVICE=21
assert_contains "MINUTES=7 -> --banner +7m" "--banner +7m"
assert_contains "SERVICE=21 -> --service +21m" "--service +21m"

# --- 5. Blad make run -> blokada ZOSTAJE ------------------------------------
reset_marker
run_deploy MOCK_RUN_FAIL=1
rc=$?
assert_exit_nonzero "$rc" "blad make run: exit != 0"
assert_not_contains "blad make run: NIE zdejmujemy blokady" "django: stop_countdown"

# --- 6. Bramka zdrowia zglasza problem -> blokada ZOSTAJE -------------------
reset_marker
run_deploy MOCK_HEALTH_FAIL=1
rc=$?
assert_exit_nonzero "$rc" "niezdrowy stack: exit != 0"
assert_not_contains "niezdrowy stack: NIE zdejmujemy blokady" "django: stop_countdown"

# --- 7. Heartbeat bije w trakcie deployu ------------------------------------
reset_marker
run_deploy MOCK_RUN_SLEEP=3
beats="$(grep -cF -- "--at-least" "$MARKER")"
if [ "$beats" -ge 2 ]; then
	ok "heartbeat: >=2 uderzenia w trakcie make run (bylo $beats)"
else
	ko "heartbeat: >=2 uderzenia w trakcie make run" "bylo $beats"
fi
assert_contains "heartbeat uzywa --at-least, nie --service" "extend_countdown --at-least"

# --- 8. Blad heartbeatu nie zabija sesji, ale jest widoczny -----------------
reset_marker
run_deploy MOCK_RUN_SLEEP=2 MOCK_HEARTBEAT_FAIL=1
rc=$?
assert_exit_zero "$rc" "blad heartbeatu: sesja konczy sie sukcesem"
if grep -qi "heartbeat" "$TEST_ROOT/out.log"; then
	ok "blad heartbeatu: glosny komunikat na wyjsciu"
else
	ko "blad heartbeatu: glosny komunikat na wyjsciu" "brak slowa 'heartbeat' w logu"
fi

# --- 9. Przerwanie w fazie banera -> baner zdejmowany ----------------------
# SIGTERM, nie SIGINT: zadanie w tle uruchomione z NIEINTERAKTYWNEGO skryptu ma
# SIGINT ustawiony na ignorowanie, a sygnalu zignorowanego na wejsciu bash nie
# moze przechwycic — `kill -INT` bylby tu nieszkodliwym no-opem i test
# przechodzilby na zielono niczego nie sprawdzajac. Skrypt lapie INT i TERM tym
# samym trapem, wiec TERM jest wiernym zastepnikiem prawdziwego Ctrl-C.
reset_marker
env SITE_DOWN_TEST_WAIT_SECONDS=20 SITE_DOWN_TICK_INTERVAL=1 \
	bash "$DEPLOY" >"$TEST_ROOT/out.log" 2>&1 &
deploy_pid=$!
# poczekaj az baner bedzie wywieszony
for _ in 1 2 3 4 5 6 7 8 9 10; do
	grep -qF "django: start_countdown" "$MARKER" && break
	sleep 0.5
done
kill -TERM "$deploy_pid" 2>/dev/null
wait "$deploy_pid" 2>/dev/null
assert_contains "przerwanie w fazie banera: zdejmujemy ostrzezenie" "django: stop_countdown"
assert_not_contains "przerwanie w fazie banera: NIE zaczynamy deployu" "make: run"

# --- 10. Stary obraz bez komend --------------------------------------------
reset_marker
run_deploy MOCK_NO_COUNTDOWN=1
rc=$?
assert_exit_zero "$rc" "stary obraz: deploy mimo wszystko (exit 0)"
assert_contains "stary obraz: make run mimo braku wsparcia" "make: run"
assert_not_contains "stary obraz: bez start_countdown" "django: start_countdown"

echo ""
echo "=== Testy site-down-warning.sh ==="
echo ""

# --- 11. enable / disable ---------------------------------------------------
reset_marker
env MINUTES=5 SERVICE=10 MESSAGE="Aktualizacja" bash "$WARN" enable >"$TEST_ROOT/warn.log" 2>&1
assert_contains "enable -> start_countdown" "django: start_countdown"
assert_contains "enable przekazuje komunikat" "Aktualizacja"

reset_marker
bash "$WARN" disable >"$TEST_ROOT/warn.log" 2>&1
assert_contains "disable -> stop_countdown --noinput" "django: stop_countdown --noinput"
assert_not_contains "disable NIE zawezia do jednej witryny" "--site-id"

# --- 12. adjust: znak wybiera komende, wartosc zawsze dodatnia --------------
reset_marker
bash "$WARN" adjust +5 >"$TEST_ROOT/warn.log" 2>&1
assert_contains "adjust +5 -> extend_countdown --service +5m" "django: extend_countdown --service +5m"

reset_marker
bash "$WARN" adjust -5 >"$TEST_ROOT/warn.log" 2>&1
assert_contains "adjust -5 -> shorten_countdown --service +5m" "django: shorten_countdown --service +5m"
assert_not_contains "adjust -5 nie przekazuje minusa do komendy" "-5m"

# --- 13. SITE_IDS -> petla po witrynach ------------------------------------
reset_marker
env SITE_IDS="1 2" MINUTES=5 SERVICE=10 bash "$WARN" enable >"$TEST_ROOT/warn.log" 2>&1
assert_contains "SITE_IDS: --site-id 1" "--site-id 1"
assert_contains "SITE_IDS: --site-id 2" "--site-id 2"
starts="$(grep -cF -- "django: start_countdown" "$MARKER")"
if [ "$starts" -eq 2 ]; then
	ok "SITE_IDS: start_countdown wolany raz na witryne"
else
	ko "SITE_IDS: start_countdown wolany raz na witryne" "bylo $starts"
fi

# --- 14. Stary obraz: prymitywy odmawiaja ----------------------------------
reset_marker
env MOCK_NO_COUNTDOWN=1 MINUTES=5 SERVICE=10 bash "$WARN" enable >"$TEST_ROOT/warn.log" 2>&1
rc=$?
assert_exit_nonzero "$rc" "stary obraz: enable konczy sie bledem"

# --- 15. status jest tylko do odczytu --------------------------------------
reset_marker
bash "$WARN" status >"$TEST_ROOT/warn.log" 2>&1
assert_contains "status -> show_countdown" "django: show_countdown"
assert_not_contains "status nic nie zapisuje (brak start)" "django: start_countdown"
assert_not_contains "status nic nie zapisuje (brak stop)" "django: stop_countdown"

reset_marker
env JSON=1 bash "$WARN" status >"$TEST_ROOT/warn.log" 2>&1
assert_contains "status JSON=1 -> show_countdown --json" "django: show_countdown --json"

# --- Podsumowanie -----------------------------------------------------------
echo ""
echo "======================================"
printf "Zaliczone: %d, niezaliczone: %d\n" "$PASS" "$FAIL"
echo "======================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

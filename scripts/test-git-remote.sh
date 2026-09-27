#!/usr/bin/env bash
#
# Testy scripts/git-remote.sh (make git-bez-klucza / make git-na-klucz).
#
# Prawdziwy git na tymczasowych repozytoriach; sieci nie ma — `git ls-remote`
# przechwytuje nakladka w PATH (reszte komend oddaje prawdziwemu gitowi)
# i zapisuje, z jakim srodowiskiem ja wolano.
#
# Uruchomienie: `make test-git-remote` lub `bash scripts/test-git-remote.sh`

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/git-remote.sh"

REAL_GIT="$(command -v git)"
TEST_ROOT="$(mktemp -d -t bpp-git-remote-XXXXXX)"
MOCK_BIN="$TEST_ROOT/mock-bin"
mkdir -p "$MOCK_BIN"

# shellcheck disable=SC2317  # wywolywane przez trap
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

# --- Nakladka na git: przechwytuje tylko ls-remote -------------------------
cat > "$MOCK_BIN/git" <<EOF
#!/bin/sh
for a in "\$@"; do
	if [ "\$a" = "ls-remote" ]; then
		printf 'prompt=%s ssh=%s args=%s\n' "\${GIT_TERMINAL_PROMPT:-}" "\${GIT_SSH_COMMAND:-}" "\$*" >> "\$LS_REMOTE_LOG"
		exit "\${MOCK_LS_REMOTE_RC:-0}"
	fi
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$MOCK_BIN/git"

PASS=0
FAIL=0
green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
pass()  { green "  PASS: $1"; PASS=$((PASS + 1)); }
fail()  { red   "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# $1 = poczatkowy url origin ("" = brak remote'a), $2 = tryb, $3 = poczatkowy pushurl (opcjonalnie)
# Wynik: RUN_EXIT, URL, PUSHURL, OUT, LS_REMOTE_LOG
run_mode() {
	R="$TEST_ROOT/repo.$RANDOM$RANDOM"
	"$REAL_GIT" init -q "$R"
	[ -z "$1" ] || "$REAL_GIT" -C "$R" remote add origin "$1"
	[ -z "${3:-}" ] || "$REAL_GIT" -C "$R" config remote.origin.pushurl "$3"
	OUT="$R.out"
	export LS_REMOTE_LOG="$R.lsremote"
	: > "$LS_REMOTE_LOG"
	set +e
	env PATH="$MOCK_BIN:$PATH" BPP_REPO_DIR="$R" LS_REMOTE_LOG="$LS_REMOTE_LOG" \
		MOCK_LS_REMOTE_RC="${MOCK_LS_REMOTE_RC:-0}" \
		bash "$SCRIPT" "$2" >"$OUT" 2>&1
	RUN_EXIT=$?
	set -e
	URL="$("$REAL_GIT" -C "$R" config --get remote.origin.url || true)"          # brak remote'a -> pusto
	PUSHURL="$("$REAL_GIT" -C "$R" config --get remote.origin.pushurl || true)"  # brak pushurl -> pusto
}

assert_eq() {  # $1=opis $2=oczekiwane $3=otrzymane
	if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (oczekiwano '$2', otrzymano '$3')"; fi
}

echo "== Testy scripts/git-remote.sh =="

# 1. SSH (scp-like) -> HTTPS: pobieranie anonimowe, push nadal po SSH.
run_mode "git@github.com:iplweb/bpp-deploy.git" https
assert_eq "ssh -> https: exit 0" 0 "$RUN_EXIT"
assert_eq "ssh -> https: url pobierania" "https://github.com/iplweb/bpp-deploy.git" "$URL"
assert_eq "ssh -> https: push zostaje po ssh" "git@github.com:iplweb/bpp-deploy.git" "$PUSHURL"

# 2. HTTPS (z pushurl po SSH) -> SSH: jeden adres, pushurl usuniety.
run_mode "https://github.com/iplweb/bpp-deploy.git" ssh "git@github.com:iplweb/bpp-deploy.git"
assert_eq "https -> ssh: exit 0" 0 "$RUN_EXIT"
assert_eq "https -> ssh: url" "git@github.com:iplweb/bpp-deploy.git" "$URL"
assert_eq "https -> ssh: pushurl usuniety" "" "$PUSHURL"

# 3. HTTPS bez pushurl -> SSH (unset nieistniejacego klucza nie moze wywrocic skryptu).
run_mode "https://github.com/iplweb/bpp-deploy.git" ssh
assert_eq "https bez pushurl -> ssh: exit 0" 0 "$RUN_EXIT"
assert_eq "https bez pushurl -> ssh: url" "git@github.com:iplweb/bpp-deploy.git" "$URL"

# 4. Fork i inny host: wlasciciel, sciezka i host przepisane, nie zaszyte na sztywno.
run_mode "git@gitlab.example.org:grupa/podgrupa/bpp-deploy.git" https
assert_eq "inny host/fork -> https: url" "https://gitlab.example.org/grupa/podgrupa/bpp-deploy.git" "$URL"
assert_eq "inny host/fork -> https: pushurl" "git@gitlab.example.org:grupa/podgrupa/bpp-deploy.git" "$PUSHURL"

# 5. ssh:// z portem -> HTTPS: port jest portem SSH, do HTTPS nie przechodzi.
run_mode "ssh://git@github.com:22/iplweb/bpp-deploy.git" https
assert_eq "ssh:// z portem -> https: url bez portu" "https://github.com/iplweb/bpp-deploy.git" "$URL"

# 6. HTTPS z poswiadczeniami -> SSH: token NIE moze przejsc do nowego adresu.
run_mode "https://jan:ghp_TAJNE@github.com/iplweb/bpp-deploy" ssh
assert_eq "https z tokenem -> ssh: url bez poswiadczen" "git@github.com:iplweb/bpp-deploy" "$URL"
if grep -q "ghp_TAJNE" "$OUT"; then fail "https z tokenem: token wyciekl na wyjscie"; else pass "https z tokenem: token nie trafia na wyjscie"; fi

# 7. Idempotencja: juz HTTPS -> HTTPS nie rusza url.
run_mode "https://github.com/iplweb/bpp-deploy.git" https
assert_eq "https -> https: exit 0" 0 "$RUN_EXIT"
assert_eq "https -> https: url bez zmian" "https://github.com/iplweb/bpp-deploy.git" "$URL"
# Na zwyklym adresie ponowne ustawienie jest nierozroznialne od "nie ruszaj" —
# dopiero adres z poswiadczeniami pokazuje, ze skrypt nie przepisuje HTTPS od nowa
# (inaczej po cichu zgubilby token operatora).
run_mode "https://jan:ghp_FETCH@github.com/iplweb/bpp-deploy.git" https
assert_eq "https z tokenem -> https: url z tokenem nietkniety" "https://jan:ghp_FETCH@github.com/iplweb/bpp-deploy.git" "$URL"

# 8. Idempotencja w obie strony: ssh -> https -> ssh daje oryginal.
run_mode "git@github.com:iplweb/bpp-deploy.git" https
env PATH="$MOCK_BIN:$PATH" BPP_REPO_DIR="$R" LS_REMOTE_LOG="$LS_REMOTE_LOG" bash "$SCRIPT" ssh >/dev/null 2>&1
assert_eq "ssh -> https -> ssh: oryginalny url" "git@github.com:iplweb/bpp-deploy.git" "$("$REAL_GIT" -C "$R" config --get remote.origin.url)"
assert_eq "ssh -> https -> ssh: bez pushurl" "" "$("$REAL_GIT" -C "$R" config --get remote.origin.pushurl || true)"  # brak klucza -> pusto

# 9. Sprawdzenie polaczenia NIGDY nie moze pytac o haslo/login — pod screenem
# wisialoby w nieskonczonosc (pseudo-TTY).
run_mode "git@github.com:iplweb/bpp-deploy.git" https
if grep -q "prompt=0 " "$LS_REMOTE_LOG"; then pass "sprawdzenie z GIT_TERMINAL_PROMPT=0"; else fail "sprawdzenie bez GIT_TERMINAL_PROMPT=0 ($(cat "$LS_REMOTE_LOG"))"; fi
if grep -q "BatchMode=yes" "$LS_REMOTE_LOG"; then pass "sprawdzenie z ssh BatchMode=yes"; else fail "sprawdzenie bez ssh BatchMode=yes"; fi

# 10. Nieudane sprawdzenie -> exit != 0, ale zmiana zostaje (operator decyduje).
MOCK_LS_REMOTE_RC=128 run_mode "https://github.com/iplweb/bpp-deploy.git" ssh
if [ "$RUN_EXIT" -ne 0 ]; then pass "nieudane polaczenie -> exit != 0"; else fail "nieudane polaczenie -> exit 0"; fi
assert_eq "nieudane polaczenie -> zmiana zostaje" "git@github.com:iplweb/bpp-deploy.git" "$URL"

# 11. Nieznany format (lokalna sciezka) -> blad, konfiguracja nietknieta.
run_mode "/srv/git/bpp-deploy.git" https
if [ "$RUN_EXIT" -ne 0 ]; then pass "lokalna sciezka -> exit != 0"; else fail "lokalna sciezka -> exit 0"; fi
assert_eq "lokalna sciezka -> url nietkniety" "/srv/git/bpp-deploy.git" "$URL"
assert_eq "lokalna sciezka -> brak pushurl" "" "$PUSHURL"

# 12. Brak remote'a origin -> blad.
run_mode "" https
if [ "$RUN_EXIT" -ne 0 ]; then pass "brak origin -> exit != 0"; else fail "brak origin -> exit 0"; fi

# 13. Zly tryb -> exit 2, nic nie zmienione.
run_mode "git@github.com:iplweb/bpp-deploy.git" ftp
assert_eq "zly tryb -> exit 2" 2 "$RUN_EXIT"
assert_eq "zly tryb -> url nietkniety" "git@github.com:iplweb/bpp-deploy.git" "$URL"

# 14. Jawnie ustawiony pushurl operatora (np. HTTPS z tokenem) NIE jest
# nadpisywany przy przejsciu na HTTPS — zmieniamy tylko pobieranie.
run_mode "git@github.com:iplweb/bpp-deploy.git" https "https://jan:ghp_PUSH@github.com/iplweb/bpp-deploy.git"
assert_eq "wlasny pushurl -> https: pushurl nietkniety" "https://jan:ghp_PUSH@github.com/iplweb/bpp-deploy.git" "$PUSHURL"
if grep -q "ghp_PUSH" "$OUT"; then fail "wlasny pushurl: token wyciekl na wyjscie"; else pass "wlasny pushurl: token nie trafia na wyjscie"; fi

echo ""
echo "Wynik: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]

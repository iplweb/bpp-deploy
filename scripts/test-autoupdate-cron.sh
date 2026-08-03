#!/usr/bin/env bash
#
# Testy scripts/setup-autoupdate-cron.sh — bez prawdziwego crona, bez sieci.
#
# Mockujemy w PATH:
#   crontab -> caly stan trzymany w pliku $CRONTAB_FILE:
#              `crontab -l`      -> cat pliku (exit 0); gdy pliku nie ma:
#                                   "no crontab for <user>" na stderr + exit 1,
#              `crontab <plik>`  -> nadpisanie stanu trescia pliku,
#              MOCK_CRONTAB_L_FAIL=1 -> `-l` konczy sie INNYM bledem
#                                   (symulacja cron.deny / awarii przejsciowej).
#
# Sprawdzamy EFEKT (zawartosc crontaba po uruchomieniu) i kod wyjscia, a nie
# to, czy cron cokolwiek uruchomi.
#
# Uwaga: przypadek "brak crontab w PATH" symulujemy przez CRONTAB=<nazwa spoza
# PATH> — to ten sam punkt wstrzykniecia, ktorego uzywa skrypt (`command -v
# "$CRONTAB"`), a nie da sie sensownie wyciac /usr/bin/crontab z PATH bez
# odcinania sobie reszty coreutils.
#
# Uruchomienie: `make test-autoupdate-cron` lub `bash scripts/test-autoupdate-cron.sh`

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/setup-autoupdate-cron.sh"

if [ ! -f "$SCRIPT" ]; then
	echo "BLAD: brak $SCRIPT" >&2
	exit 1
fi

TEST_ROOT="$(mktemp -d -t bpp-aucron-test-XXXXXX)"
MOCK_BIN="$TEST_ROOT/mock-bin"
mkdir -p "$MOCK_BIN"

CRONTAB_FILE="$TEST_ROOT/crontab.state"
OUT="$TEST_ROOT/stdout"
ERR="$TEST_ROOT/stderr"

# --- Mock crontab -----------------------------------------------------------
cat > "$MOCK_BIN/crontab" <<'EOF'
#!/bin/sh
case "$1" in
  -l)
    if [ "${MOCK_CRONTAB_L_FAIL:-0}" = "1" ]; then
      echo "crontab: you (tester) are not allowed to use this program" >&2
      exit 1
    fi
    if [ -f "$CRONTAB_FILE" ]; then
      cat "$CRONTAB_FILE"
      exit 0
    fi
    echo "no crontab for tester" >&2
    exit 1
    ;;
  -r)
    rm -f "$CRONTAB_FILE"
    exit 0
    ;;
  *)
    if [ ! -f "$1" ]; then
      echo "crontab: cannot read $1" >&2
      exit 1
    fi
    cp "$1" "$CRONTAB_FILE"
    exit 0
    ;;
esac
EOF
chmod +x "$MOCK_BIN/crontab"

# shellcheck disable=SC2317  # wywolywane przez trap
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

PASS=0
FAIL=0
green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
pass()  { green "  PASS: $1"; PASS=$((PASS + 1)); }
fail()  { red   "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Stan wejsciowy pojedynczego przypadku: pusty crontab, domyslny harmonogram,
# log w katalogu tymczasowym (nigdy w prawdziwym $BPP_CONFIGS_DIR).
reset_state() {
	rm -f "$CRONTAB_FILE"
	T_LOG="$TEST_ROOT/logs/autoupdate-cron.log"
	T_CONFIGS_DIR=""
	T_SCHEDULE=""
	T_EXTRA_PATH=""
	CRONTAB_BIN="crontab"
	MOCK_CRONTAB_L_FAIL=0
}

# PATH procesu skryptu != PATH zamrozony we wpisie. Katalog mocka crontab MUSI
# byc w tym pierwszym (skrypt stamtad wola `$CRONTAB`), a NIE MOZE w drugim.
run_setup() {
	set +e
	env PATH="${T_EXTRA_PATH:+$T_EXTRA_PATH:}$MOCK_BIN:$PATH" \
		CRONTAB_FILE="$CRONTAB_FILE" \
		MOCK_CRONTAB_L_FAIL="$MOCK_CRONTAB_L_FAIL" \
		CRONTAB="$CRONTAB_BIN" \
		BPP_CONFIGS_DIR="$T_CONFIGS_DIR" \
		AUTOUPDATE_CRON_LOG="$T_LOG" \
		AUTOUPDATE_CRON_SCHEDULE="$T_SCHEDULE" \
		bash "$SCRIPT" "$@" >"$OUT" 2>"$ERR"
	RUN_EXIT=$?
	set -e
}

marker_count() {
	grep -cF 'BPP-AUTOUPDATE' "$CRONTAB_FILE" 2>/dev/null || true
}

assert_exit() {
	if [ "$1" = "$RUN_EXIT" ]; then pass "$2"; else fail "$2 (oczekiwane exit=$1, otrzymano $RUN_EXIT)"; fi
}
assert_exit_nonzero() {
	if [ "$RUN_EXIT" -ne 0 ]; then pass "$1"; else fail "$1 (oczekiwano exit != 0)"; fi
}
assert_marker_count() {
	got="$(marker_count)"
	if [ "$got" = "$1" ]; then pass "$2"; else fail "$2 (oczekiwano $1 wpisow, jest $got)"; fi
}
assert_cron_has() {
	if grep -qF -- "$1" "$CRONTAB_FILE" 2>/dev/null; then pass "$2"; else fail "$2 (brak '$1' w crontabie)"; fi
}
assert_cron_lacks() {
	if grep -qF -- "$1" "$CRONTAB_FILE" 2>/dev/null; then fail "$2 (znaleziono '$1' w crontabie)"; else pass "$2"; fi
}
assert_file_missing() {
	if [ -e "$1" ]; then fail "$2 (plik $1 istnieje)"; else pass "$2"; fi
}
assert_dir_exists() {
	if [ -d "$1" ]; then pass "$2"; else fail "$2 (brak katalogu $1)"; fi
}

echo "== Testy scripts/setup-autoupdate-cron.sh =="

# 1. Instalacja do pustego (nieistniejacego) crontaba -> dokladnie 1 wpis.
reset_state
run_setup
assert_exit 0 "1. instalacja do pustego crontaba -> exit 0"
assert_marker_count 1 "1. instalacja do pustego crontaba -> 1 wpis z markerem"

# 2. Dwukrotna instalacja -> wciaz dokladnie 1 wpis (idempotencja).
reset_state
run_setup
run_setup
assert_exit 0 "2. druga instalacja -> exit 0"
assert_marker_count 1 "2. dwukrotna instalacja -> nadal 1 wpis"

# 3. Reinstalacja ze zmienionym harmonogramem -> 1 wpis, stary zniknal.
reset_state
run_setup
T_SCHEDULE="*/30 * * * *"
run_setup
assert_marker_count 1 "3. zmiana harmonogramu -> nadal 1 wpis"
assert_cron_has "*/30 * * * *" "3. zmiana harmonogramu -> nowa wartosc we wpisie"
assert_cron_lacks "*/15 * * * *" "3. zmiana harmonogramu -> stara wartosc usunieta"

# 4. Cudze wpisy uzytkownika przetrwaja instalacje.
reset_state
cat > "$CRONTAB_FILE" <<'EOF'
0 3 * * * /usr/local/bin/moj-backup.sh
@daily /usr/bin/inne-zadanie
EOF
run_setup
assert_exit 0 "4. instalacja przy cudzych wpisach -> exit 0"
assert_marker_count 1 "4. instalacja przy cudzych wpisach -> 1 wpis BPP"
assert_cron_has "/usr/local/bin/moj-backup.sh" "4. cudzy wpis 1 przetrwal instalacje"
assert_cron_has "/usr/bin/inne-zadanie" "4. cudzy wpis 2 przetrwal instalacje"

# 5. Cudze wpisy przetrwaja --remove; usuwane sa tylko linie z markerem.
reset_state
cat > "$CRONTAB_FILE" <<'EOF'
0 3 * * * /usr/local/bin/moj-backup.sh
EOF
run_setup
run_setup --remove
assert_exit 0 "5. --remove -> exit 0"
assert_marker_count 0 "5. --remove -> wpisy BPP usuniete"
assert_cron_has "/usr/local/bin/moj-backup.sh" "5. --remove -> cudzy wpis nietkniety"

# 6. --remove na crontabie bez naszych wpisow -> kod 0, cudze nietkniete.
reset_state
cat > "$CRONTAB_FILE" <<'EOF'
0 3 * * * /usr/local/bin/moj-backup.sh
EOF
BEFORE="$TEST_ROOT/before.6"
cp "$CRONTAB_FILE" "$BEFORE"
run_setup --remove
assert_exit 0 "6. --remove bez wpisow BPP -> exit 0"
if cmp -s "$BEFORE" "$CRONTAB_FILE"; then
	pass "6. --remove bez wpisow BPP -> crontab nietkniety"
else
	fail "6. --remove bez wpisow BPP -> crontab zmieniony"
fi

# 7. --remove na NIEISTNIEJACYM crontabie -> kod 0, crontab nadal nie istnieje.
reset_state
run_setup --remove
assert_exit 0 "7. --remove bez crontaba -> exit 0"
assert_file_missing "$CRONTAB_FILE" "7. --remove bez crontaba -> nie tworzymy pustego crontaba"

# 8. AUTOUPDATE_CRON_SCHEDULE faktycznie laduje we wpisie.
reset_state
T_SCHEDULE="7 4 * * 1"
run_setup
assert_exit 0 "8. wlasny harmonogram -> exit 0"
assert_cron_has "7 4 * * 1 cd '" "8. wlasny harmonogram na poczatku wpisu"

# 9. Sciezka logu oraz PATH= obecne w zbudowanej linii.
reset_state
run_setup
assert_cron_has "PATH='" "9. wpis zawiera zamrozony PATH= jako prefiks komendy"
assert_cron_has ">> '$T_LOG' 2>&1" "9. wpis przekierowuje wyjscie do logu"
assert_cron_has "make screen-with-autoupdate" "9. wpis wola make screen-with-autoupdate"
if grep -qE '^PATH=' "$CRONTAB_FILE" 2>/dev/null; then
	fail "9. PATH nie moze byc osobna (globalna) linia crontaba"
else
	pass "9. PATH nie jest osobna linia crontaba"
fi

# 10. Katalog logu zostaje utworzony, gdy nie istnial (tu: domyslna sciezka
#     $BPP_CONFIGS_DIR/logs/, ktorej nie tworzy zaden inny skrypt).
reset_state
T_CONFIGS_DIR="$TEST_ROOT/configs-10"
T_LOG=""
rm -rf "$T_CONFIGS_DIR"
run_setup
assert_exit 0 "10. domyslna sciezka logu -> exit 0"
assert_dir_exists "$T_CONFIGS_DIR/logs" "10. katalog logu utworzony, gdy nie istnial"
assert_cron_has "$T_CONFIGS_DIR/logs/autoupdate-cron.log" "10. domyslna sciezka logu we wpisie"

# 11. Kopia zapasowa crontab.bak.* powstaje, gdy crontab byl niepusty.
reset_state
T_LOG="$TEST_ROOT/logs-11/autoupdate-cron.log"
cat > "$CRONTAB_FILE" <<'EOF'
0 3 * * * /usr/local/bin/moj-backup.sh
EOF
run_setup
if ls "$TEST_ROOT/logs-11"/crontab.bak.* >/dev/null 2>&1; then
	pass "11. kopia zapasowa crontaba powstala"
else
	fail "11. brak kopii zapasowej crontab.bak.* w katalogu logu"
fi

# 12. `%` w sciezce logu zostaje zaescape'owany do `\%`.
reset_state
T_LOG="$TEST_ROOT/logs-12%x/autoupdate-cron.log"
run_setup
assert_exit 0 "12. % w sciezce logu -> exit 0"
assert_cron_has '\%' "12. % w czesci komendy zaescape'owany do \\%"
assert_cron_lacks "logs-12%x" "12. brak niezaescape'owanego % w komendzie"

# 13. Harmonogram o zlej liczbie pol -> kod != 0, crontab nietkniety.
reset_state
cat > "$CRONTAB_FILE" <<'EOF'
0 3 * * * /usr/local/bin/moj-backup.sh
EOF
BEFORE="$TEST_ROOT/before.13"
cp "$CRONTAB_FILE" "$BEFORE"
T_SCHEDULE="*/15 * *"
run_setup
assert_exit_nonzero "13. zly harmonogram (3 pola) -> exit != 0"
if cmp -s "$BEFORE" "$CRONTAB_FILE"; then
	pass "13. zly harmonogram -> crontab nietkniety"
else
	fail "13. zly harmonogram -> crontab zmieniony"
fi

# 14. Harmonogram @reboot -> akceptowany, laduje we wpisie.
reset_state
T_SCHEDULE="@reboot"
run_setup
assert_exit 0 "14. @reboot -> exit 0"
assert_marker_count 1 "14. @reboot -> 1 wpis"
assert_cron_has "@reboot cd '" "14. @reboot laduje we wpisie"

# 15. Harmonogram z `%` -> kod != 0, crontab nietkniety.
reset_state
cat > "$CRONTAB_FILE" <<'EOF'
0 3 * * * /usr/local/bin/moj-backup.sh
EOF
BEFORE="$TEST_ROOT/before.15"
cp "$CRONTAB_FILE" "$BEFORE"
T_SCHEDULE="*/15 * * * %"
run_setup
assert_exit_nonzero "15. % w harmonogramie -> exit != 0"
if cmp -s "$BEFORE" "$CRONTAB_FILE"; then
	pass "15. % w harmonogramie -> crontab nietkniety"
else
	fail "15. % w harmonogramie -> crontab zmieniony"
fi

# 16. Brak `crontab` w PATH -> kod != 0 z czytelnym komunikatem.
reset_state
cat > "$CRONTAB_FILE" <<'EOF'
0 3 * * * /usr/local/bin/moj-backup.sh
EOF
BEFORE="$TEST_ROOT/before.16"
cp "$CRONTAB_FILE" "$BEFORE"
CRONTAB_BIN="crontab-ktorego-nie-ma"
run_setup
assert_exit_nonzero "16. brak crontab -> exit != 0"
if grep -qi 'crontab' "$ERR"; then
	pass "16. brak crontab -> komunikat wspomina crontab"
else
	fail "16. brak crontab -> brak czytelnego komunikatu na stderr"
fi
if grep -qi 'install' "$ERR"; then
	pass "16. brak crontab -> podpowiedz instalacji"
else
	fail "16. brak crontab -> brak podpowiedzi instalacji"
fi
if cmp -s "$BEFORE" "$CRONTAB_FILE"; then
	pass "16. brak crontab -> crontab nietkniety"
else
	fail "16. brak crontab -> crontab zmieniony"
fi

# 17. `crontab -l` konczy sie bledem INNYM niz "no crontab" -> abort,
#     crontab nietkniety (inaczej wyzerowalibysmy cudze wpisy).
reset_state
cat > "$CRONTAB_FILE" <<'EOF'
0 3 * * * /usr/local/bin/moj-backup.sh
EOF
BEFORE="$TEST_ROOT/before.17"
cp "$CRONTAB_FILE" "$BEFORE"
MOCK_CRONTAB_L_FAIL=1
run_setup
assert_exit 1 "17. nieznany blad 'crontab -l' -> exit 1"
if cmp -s "$BEFORE" "$CRONTAB_FILE"; then
	pass "17. nieznany blad 'crontab -l' -> crontab nietkniety"
else
	fail "17. nieznany blad 'crontab -l' -> crontab zmieniony"
fi

# --- Minimalny PATH we wpisie (limit MAX_COMMAND Vixie crona) ----------------
# Zamrozenie CALEGO $PATH powloki dawalo linie >3500 znakow (homebrew, orbstack,
# pluginy, .local/bin...) — a Vixie cron (Debian/Ubuntu `cron`, `cronie`) ma
# twardy MAX_COMMAND rzedu 1000 znakow: dluzsza linia bywa odrzucana albo
# wchodzi UCIETA.
#
# UWAGA: PATH procesu testu MUSI zawierac katalog mocka crontab (skrypt wola
# stamtad `$CRONTAB`) — sprawdzamy wylacznie to, co laduje WE WPISIE.
# Wyluskuje wartosc PATH='...' ze wpisu. Tolerancyjne na brak crontaba —
# inaczej `pipefail` wywrocilby caly przebieg zamiast zglosic FAIL.
cron_entry_path() {
	{ sed -n "s/.*PATH='\([^']*\)'.*/\1/p" "$CRONTAB_FILE" 2>/dev/null || true; } | head -1
}

# 18. Wpis zawiera katalog, w ktorym realnie lezy `make`.
reset_state
run_setup
MAKE_DIR="$(dirname "$(command -v make)")"
ENTRY_PATH="$(cron_entry_path)"
case ":$ENTRY_PATH:" in
	*":$MAKE_DIR:"*) pass "18. zamrozony PATH zawiera katalog make ($MAKE_DIR)" ;;
	*)               fail "18. zamrozony PATH nie zawiera katalogu make ($MAKE_DIR): $ENTRY_PATH" ;;
esac

# 19. Standardowe systemowe katalogi obecne.
case ":$ENTRY_PATH:" in
	*":/usr/bin:"*) pass "19. zamrozony PATH zawiera /usr/bin" ;;
	*)              fail "19. zamrozony PATH nie zawiera /usr/bin: $ENTRY_PATH" ;;
esac

# 20. SEDNO POPRAWKI: egzotyczny katalog z PATH procesu wywolujacego NIE trafia
#     do wpisu (nie ma w nim zadnej binarki potrzebnej wpisowi).
reset_state
EXOTIC="$TEST_ROOT/nie-powinno-byc-we-wpisie"
mkdir -p "$EXOTIC"
printf '#!/bin/sh\nexit 0\n' > "$EXOTIC/narzedzie-nieistotne"
chmod +x "$EXOTIC/narzedzie-nieistotne"
T_EXTRA_PATH="$EXOTIC"
run_setup
assert_cron_lacks "$EXOTIC" "20. egzotyczny katalog z \$PATH nie trafia do wpisu"
assert_cron_lacks "$MOCK_BIN" "20. katalog mocka crontab nie trafia do wpisu"

# 21. Brak duplikatow katalogow w zbudowanym PATH.
reset_state
run_setup
ENTRY_PATH="$(cron_entry_path)"
TOTAL="$(printf '%s\n' "$ENTRY_PATH" | tr ':' '\n' | wc -l | tr -d ' ')"
UNIQ="$(printf '%s\n' "$ENTRY_PATH" | tr ':' '\n' | sort -u | wc -l | tr -d ' ')"
if [ "$TOTAL" = "$UNIQ" ]; then
	pass "21. brak duplikatow w zamrozonym PATH ($TOTAL katalogow)"
else
	fail "21. duplikaty w zamrozonym PATH ($TOTAL pozycji, $UNIQ unikalnych): $ENTRY_PATH"
fi

# 22. Cala linia wpisu miesci sie ponizej limitu MAX_COMMAND.
LINE_LEN="$(awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$CRONTAB_FILE" 2>/dev/null || echo 0)"
if [ "$LINE_LEN" -eq 0 ]; then
	fail "22. brak wpisu w crontabie — nie ma czego mierzyc"
elif [ "$LINE_LEN" -lt 1000 ]; then
	pass "22. wpis krotszy niz 1000 znakow ($LINE_LEN)"
else
	fail "22. wpis za dlugi dla Vixie crona ($LINE_LEN znakow)"
fi

# 23. Wymuszone przekroczenie limitu (bardzo dluga sciezka logu) -> exit != 0,
#     crontab nietkniety, komunikat tlumaczacy limit.
reset_state
cat > "$CRONTAB_FILE" <<'EOF'
0 3 * * * /usr/local/bin/moj-backup.sh
EOF
BEFORE="$TEST_ROOT/before.23"
cp "$CRONTAB_FILE" "$BEFORE"
LONG_SEG="$(printf 'a%.0s' $(seq 1 200))"
T_LOG="$TEST_ROOT/$LONG_SEG/$LONG_SEG/$LONG_SEG/$LONG_SEG/autoupdate-cron.log"
run_setup
assert_exit_nonzero "23. za dlugi wpis -> exit != 0"
if grep -q 'MAX_COMMAND' "$ERR"; then
	pass "23. za dlugi wpis -> komunikat tlumaczy limit crona"
else
	fail "23. za dlugi wpis -> brak wyjasnienia limitu na stderr"
fi
if cmp -s "$BEFORE" "$CRONTAB_FILE"; then
	pass "23. za dlugi wpis -> crontab nietkniety"
else
	fail "23. za dlugi wpis -> crontab zmieniony"
fi

echo ""
echo "Wynik: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]

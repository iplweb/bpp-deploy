#!/usr/bin/env bash
#
# Testy scripts/lib-config-path.sh — normalizacji, absolutyzacji i walidacji
# sciezki katalogu konfiguracyjnego (BPP_CONFIGS_DIR).
#
# Bez sieci i bez Dockera. Windows jest symulowany stub-skryptami `cygpath`
# i `uname` w PATH (konwencja: scripts/test-docker-versions.sh), dzieki czemu
# ta sama regresja jest lapana takze na Linuksie i macOS.
#
# Uruchomienie: `make test-config-path` lub `bash scripts/test-config-path.sh`

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_DIR/scripts/lib-config-path.sh"

TEST_ROOT="$(mktemp -d -t bpp-config-path-test-XXXXXX)"
CYGPATH_BIN="$TEST_ROOT/mock-bin-cygpath"   # Git Bash: jest cygpath
MSYS_BIN="$TEST_ROOT/mock-bin-msys"         # MSYS bez cygpath: tylko uname
mkdir -p "$CYGPATH_BIN" "$MSYS_BIN"

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
assert_inside() {
    if config_path_inside_repo "$1" "$2"; then pass "$3"; else
        fail "$3 ('$1' powinno byc uznane za wnetrze '$2')"; fi
}
assert_outside() {
    if config_path_inside_repo "$1" "$2"; then
        fail "$3 ('$1' NIE lezy w '$2', a zostalo odrzucone)"; else pass "$3"; fi
}

# --- Stub cygpath (Git Bash / MSYS2 / Cygwin) ---
cat > "$CYGPATH_BIN/cygpath" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in -*) shift ;; esac
p="$(printf '%s' "${1:-}" | tr '\\' '/')"
case "$p" in
    [A-Za-z]:*)
        d="$(printf '%s' "$p" | cut -c1 | tr '[:upper:]' '[:lower:]')"
        p="/$d${p#?:}"
        ;;
esac
printf '%s\n' "$p"
EOF

# --- Stub uname: srodowisko MSYS bez cygpath (fallback reczny) ---
cat > "$MSYS_BIN/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "MINGW64_NT-10.0-22631"
EOF
chmod +x "$CYGPATH_BIN/cygpath" "$MSYS_BIN/uname"

REAL_PATH="$PATH"
posix_env()   { PATH="$REAL_PATH"; }
windows_env() { PATH="$CYGPATH_BIN:$REAL_PATH"; }   # jest cygpath
msys_env()    { PATH="$MSYS_BIN:$REAL_PATH"; }      # brak cygpath, uname=MINGW

# shellcheck source=scripts/lib-config-path.sh
. "$LIB"

echo ""
echo "== Windows: sciezki natywne (Git Bash, cygpath) =="
windows_env
# REGRESJA: kazda z tych postaci ladowala wczesniej w galezi "sciezka
# wzgledna" i byla doklejana do katalogu repozytorium -> falszywy komunikat
# "katalog musi byc POZA repozytorium". Przechodzilo tylko "..".
assert_eq "/c/dane/bpp"  "$(normalize_config_path 'C:\dane\bpp')"     "C:\\dane\\bpp -> /c/dane/bpp"
assert_eq "/c/dane/bpp"  "$(normalize_config_path 'C:/dane/bpp')"     "C:/dane/bpp -> /c/dane/bpp"
assert_eq "/d/bpp"       "$(normalize_config_path 'D:\bpp')"          "inna litera dysku"
assert_eq "/c/dane/bpp"  "$(normalize_config_path '"C:\dane\bpp"')"   'cudzyslowy ("Kopiuj jako sciezke")'
assert_eq "/c/dane/bpp"  "$(normalize_config_path '  C:\dane\bpp  ')" "spacje na brzegach"
assert_eq "/c/dane/bpp"  "$(normalize_config_path "$(printf 'C:\\dane\\bpp\r')")" "CR na koncu"
assert_eq "//srv/udzial" "$(normalize_config_path '\\srv\udzial')"    "sciezka UNC"
assert_eq "/c/dane/bpp"  "$(normalize_config_path '/c/dane/bpp')"     "postac POSIX bez zmian"

echo ""
echo "== Windows: MSYS bez cygpath (fallback reczny) =="
msys_env
assert_eq "/c/dane/bpp" "$(normalize_config_path 'C:\dane\bpp')" "fallback: C:\\dane\\bpp -> /c/dane/bpp"
assert_eq "/e/bpp"      "$(normalize_config_path 'E:/bpp')"      "fallback: wielka litera dysku -> mala"

echo ""
echo "== POSIX: bez konwersji liter dyskow =="
posix_env
# Na Linuksie "C:" to legalna nazwa katalogu (sciezka wzgledna) — konwersja
# na /c bylaby bledem.
assert_eq 'C:/dane/bpp' "$(normalize_config_path 'C:/dane/bpp')" "Linux: C:/... nie jest tlumaczone"
# shellcheck disable=SC2088  # tylda MA dotrzec do funkcji niezrozwinieta - to jej wejscie
assert_eq "$HOME/bpp"   "$(normalize_config_path '~/bpp')"       "tylda rozwijana"
assert_eq "$HOME"       "$(normalize_config_path '~')"           "sama tylda"
assert_eq "/dane/bpp"   "$(normalize_config_path '/dane/bpp')"   "sciezka absolutna bez zmian"

echo ""
echo "== absolutize_config_path =="
assert_eq "/dane/bpp"  "$(absolutize_config_path '/dane/bpp/' )"        "koncowy ukosnik uciety"
assert_eq "/dane/bpp"  "$(absolutize_config_path '/dane/bpp///')"       "wiele koncowych ukosnikow"
assert_eq "/"          "$(absolutize_config_path '/')"                  "korzen zostaje korzeniem"
assert_eq "/tmp/x/rel" "$(absolutize_config_path 'rel' '/tmp/x')"       "sciezka wzgledna wzgledem bazy"
assert_eq "$TEST_ROOT" "$(absolutize_config_path "$TEST_ROOT")"         "istniejacy katalog przez cd && pwd"

echo ""
echo "== config_path_inside_repo =="
posix_env
REPO="/home/u/bpp-deploy"
assert_inside  "$REPO"                    "$REPO" "sam katalog repo"
assert_inside  "$REPO/configs"            "$REPO" "podkatalog repo"
# REGRESJA: wzorzec bez ukosnika ("$REPO"*) odrzucal katalogi-rodzenstwo
# o wspolnym prefiksie nazwy.
assert_outside "/home/u/bpp-deploy-config" "$REPO" "rodzenstwo o wspolnym prefiksie"
assert_outside "/home/u/publikacje"        "$REPO" "katalog obok repo"
assert_outside "/home/u"                   "$REPO" "katalog nadrzedny (..)"
assert_inside  "$REPO/x"                  "$REPO/" "repo z koncowym ukosnikiem"

windows_env
# NTFS nie rozroznia wielkosci liter — inaczej config wyladowalby w repo.
assert_inside  "/c/Users/u/BPP-Deploy/cfg" "/c/users/u/bpp-deploy" "Windows: porownanie bez wielkosci liter"
assert_outside "/c/Users/u/bpp-deploy-cfg" "/c/Users/u/bpp-deploy" "Windows: rodzenstwo o wspolnym prefiksie"
posix_env
# Poza Windows wielkosc liter MA znaczenie (dwa rozne katalogi).
assert_outside "/home/u/BPP-Deploy/cfg" "$REPO" "Linux: wielkosc liter rozrozniana"

echo ""
echo "== skladnia =="
rc=0; bash -n "$LIB" || rc=$?
assert_eq "0" "$rc" "lib-config-path.sh: bash -n"
rc=0; bash -n "$REPO_DIR/scripts/init-configs.sh" || rc=$?
assert_eq "0" "$rc" "init-configs.sh: bash -n"

echo ""
echo "Wynik: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

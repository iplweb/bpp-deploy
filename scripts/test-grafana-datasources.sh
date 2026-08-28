#!/usr/bin/env bash
#
# Testy scripts/lib-render-template.sh oraz scripts/generate-grafana-datasources.sh.
#
# Kluczowa asercja: render datasource'ow Grafany dziala z PATH-em POZBAWIONYM
# `envsubst`. Ten skrypt wisi pod `update-configs`, czyli prerequisite `make up`
# (a wiec i `make run`), a Windows nie ma gettexta — do sierpnia 2026 kazdy
# deploy na Windows konczyl sie tam "envsubst: command not found" (exit 127).
#
# Bez sieci, Dockera i .env. Uruchomienie: `make test-grafana-datasources`
# lub `bash scripts/test-grafana-datasources.sh`

# Pojedyncze cudzyslowy w tym pliku sa CELOWE: to literaly szablonu i wartosci
# oczekiwane, ktore MAJA pozostac nierozwiniete - dokladnie to jest testowane.
# shellcheck disable=SC2016,SC2089,SC2090
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_DIR/scripts/lib-render-template.sh"
GEN="$REPO_DIR/scripts/generate-grafana-datasources.sh"
TPL_SRC="$REPO_DIR/defaults/grafana/provisioning/datasources/datasources.yaml.tpl"

TEST_ROOT="$(mktemp -d -t bpp-grafana-ds-test-XXXXXX)"
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

# PATH bez zadnego katalogu zawierajacego envsubst — symulacja Git Basha.
path_without_envsubst() {
    local out="" p
    local IFS=:
    for p in $PATH; do
        [ -n "$p" ] || continue
        [ -x "$p/envsubst" ] && continue
        [ -x "$p/envsubst.exe" ] && continue
        out="${out:+$out:}$p"
    done
    printf '%s\n' "$out"
}
NO_GETTEXT_PATH="$(path_without_envsubst)"

# shellcheck source=scripts/lib-render-template.sh
. "$LIB"

echo ""
echo "== render_template =="

TPL="$TEST_ROOT/t.tpl"
printf 'url: ${A}:${B}\nplain: $A\nobcy: ${NIE_PODSTAWIAJ} i $INNY\npusta: [${E}]\n' > "$TPL"
A=host B=5432 E=""
export A B E
assert_eq "url: host:5432"        "$(render_template "$TPL" A B E | sed -n 1p)" "forma \${VAR}"
assert_eq "plain: host"           "$(render_template "$TPL" A B E | sed -n 2p)" "forma \$VAR"
# To wlasnie robi whitelista: zmienna spoza listy ma zostac LITERALEM (szablon
# moze zawierac znak $ w polu customowego datasource'a).
assert_eq 'obcy: ${NIE_PODSTAWIAJ} i $INNY' \
                                  "$(render_template "$TPL" A B E | sed -n 3p)" "zmienne spoza listy nietkniete"
assert_eq "pusta: []"             "$(render_template "$TPL" A B E | sed -n 4p)" "pusta wartosc"

# Hasla zawieraja metaznaki seda (&, \, /) — dlatego podstawiamy bashem, nie sedem.
printf 'pass: ${P}\n' > "$TPL"
P='a&b\c/d"e$F%s ??'; export P
assert_eq 'pass: a&b\c/d"e$F%s ??' "$(render_template "$TPL" P)" "metaznaki w wartosci przechodza doslownie"

# Prefiks nazwy: $FOO nie moze zjesc poczatku $FOOBAR.
printf 'x: $FOOBAR y: $FOO\n' > "$TPL"
FOO=krotka FOOBAR=dluga; export FOO FOOBAR
assert_eq "x: dluga y: krotka" "$(render_template "$TPL" FOO FOOBAR)" "dluzsza nazwa podstawiana pierwsza"

# Szablon bez koncowego newline'a nie moze zgubic ostatniej linii.
printf 'ostatnia: ${A}' > "$TPL"
assert_eq "ostatnia: host" "$(render_template "$TPL" A)" "szablon bez koncowego newline"

# Rownowaznosc z envsubst — tylko gdy gettext jest dostepny (CI na Linuksie).
echo ""
echo "== zgodnosc z envsubst (jesli dostepny) =="
if command -v envsubst >/dev/null 2>&1; then
    DJANGO_BPP_DB_HOST=dbserver DJANGO_BPP_DB_PORT=5432 DJANGO_BPP_DB_NAME=bpp
    DJANGO_BPP_DB_USER=bpp DJANGO_BPP_DB_PASSWORD='p@$$/w&d'
    DJANGO_BPP_PG_MONITOR_PASSWORD='mo\ni"tor&x'
    export DJANGO_BPP_DB_HOST DJANGO_BPP_DB_PORT DJANGO_BPP_DB_NAME \
           DJANGO_BPP_DB_USER DJANGO_BPP_DB_PASSWORD DJANGO_BPP_PG_MONITOR_PASSWORD
    render_template "$TPL_SRC" \
        DJANGO_BPP_DB_HOST DJANGO_BPP_DB_PORT DJANGO_BPP_DB_NAME \
        DJANGO_BPP_DB_USER DJANGO_BPP_DB_PASSWORD DJANGO_BPP_PG_MONITOR_PASSWORD \
        > "$TEST_ROOT/mine.yaml"
    # shellcheck disable=SC2016  # envsubst chce literalnych nazw $VAR (whitelista)
    envsubst '$DJANGO_BPP_DB_HOST $DJANGO_BPP_DB_PORT $DJANGO_BPP_DB_NAME $DJANGO_BPP_DB_USER $DJANGO_BPP_DB_PASSWORD $DJANGO_BPP_PG_MONITOR_PASSWORD' \
        < "$TPL_SRC" > "$TEST_ROOT/envsubst.yaml"
    if diff -u "$TEST_ROOT/envsubst.yaml" "$TEST_ROOT/mine.yaml" >/dev/null; then
        pass "wynik bajt w bajt taki sam jak envsubst (prawdziwy szablon)"
    else
        fail "wynik rozni sie od envsubst: $(diff "$TEST_ROOT/envsubst.yaml" "$TEST_ROOT/mine.yaml" | head -5 | tr '\n' ' ')"
    fi
else
    pass "envsubst niedostepny - porownanie pominiete (to wlasnie stan Windows)"
fi

echo ""
echo "== generate-grafana-datasources.sh BEZ envsubst w PATH =="

CFG="$TEST_ROOT/cfg"
mkdir -p "$CFG/grafana/provisioning/datasources"
cp "$TPL_SRC" "$CFG/grafana/provisioning/datasources/datasources.yaml.tpl"
cat > "$CFG/.env" <<'EOF'
DJANGO_BPP_DB_HOST=dbserver
DJANGO_BPP_DB_NAME=bpp_produkcja
DJANGO_BPP_DB_USER=bpp
DJANGO_BPP_DB_PASSWORD=app-secret
DJANGO_BPP_PG_MONITOR_PASSWORD=monitor&secret/x
EOF

OUT="$CFG/grafana/provisioning/datasources/datasources.yaml"
rc=0
env PATH="$NO_GETTEXT_PATH" BPP_CONFIGS_DIR="$CFG" bash "$GEN" >"$TEST_ROOT/gen.log" 2>&1 || rc=$?
assert_eq "0" "$rc" "render konczy sie sukcesem bez envsubst w PATH"
assert_file_not_contains "$TEST_ROOT/gen.log" "envsubst" "log nie wspomina o envsubst"

if [ -f "$OUT" ]; then
    assert_file_contains "$OUT" "url: dbserver:5432" "host + domyslny port 5432"
    assert_file_contains "$OUT" "database: bpp_produkcja" "nazwa bazy"
    assert_file_contains "$OUT" "password: monitor&secret/x" "haslo z metaznakami seda"
    assert_file_not_contains "$OUT" '${DJANGO_BPP' "brak nierozwinietych placeholderow"
else
    fail "nie powstal $OUT"
fi

# Kontrola: gdy szablon uzywa hasla roli monitorujacej, a jest ono puste,
# skrypt MUSI odmowic - inaczej cicho wyrenderowalby zepsuty datasource.
sed -i.bak '/DJANGO_BPP_PG_MONITOR_PASSWORD/d' "$CFG/.env" && rm -f "$CFG/.env.bak"
rc=0
env PATH="$NO_GETTEXT_PATH" BPP_CONFIGS_DIR="$CFG" bash "$GEN" >"$TEST_ROOT/gen2.log" 2>&1 || rc=$?
if [ "$rc" != "0" ]; then pass "puste haslo bpp_monitor nadal odrzucane"; else
    fail "puste haslo bpp_monitor zostalo przyjete"; fi

echo ""
echo "== brak zaleznosci od gettexta w kodzie =="
if grep -rn '\benvsubst\b' "$GEN" "$LIB" | grep -vE '^\S+: *#' >/dev/null 2>&1; then
    fail "envsubst nadal wolany w $GEN lub $LIB"
else
    pass "envsubst nie jest wolany (wystapienia tylko w komentarzach)"
fi

rc=0; bash -n "$LIB" || rc=$?
assert_eq "0" "$rc" "lib-render-template.sh: bash -n"
rc=0; bash -n "$GEN" || rc=$?
assert_eq "0" "$rc" "generate-grafana-datasources.sh: bash -n"

echo ""
echo "Wynik: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

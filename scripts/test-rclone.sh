#!/usr/bin/env bash
#
# Testy scripts/lib-rclone.sh oraz kroku 4 (wysylka) i 5 (retencja zdalna)
# w scripts/backup-cycle.sh.
#
# Najwazniejsza asercja jest mutacyjna: `rclone copy` do katalogu MIESIECZNEGO
# musi zostac `copy`. Zamiana na `sync` (albo powrot podkatalogu dziennego
# /DD/) to cicha utrata archiwum — sync skasowalby z katalogu miesiaca
# wszystko poza biezacym oknem 7 lokalnych kopii, a backup-cycle zaraportowalby
# sukces. Zadna z tych asercji nie moze byc grepem po zrodle: testy uruchamiaja
# PRAWDZIWY backup-cycle.sh z atrapami w PATH i sprawdzaja, co naprawde
# zawolal.
#
# Bez sieci, Dockera i .env. Uruchomienie: `make test-rclone`
# lub `bash scripts/test-rclone.sh`

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_DIR/scripts/lib-rclone.sh"
CYCLE="$REPO_DIR/scripts/backup-cycle.sh"

TEST_ROOT="$(mktemp -d -t bpp-rclone-test-XXXXXX)"
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
assert_contains() {
    local hay="$1" needle="$2" name="$3"
    if printf '%s' "$hay" | grep -qF -- "$needle"; then pass "$name"; else
        fail "$name (brak '$needle' w: $hay)"; fi
}
assert_not_contains() {
    local hay="$1" needle="$2" name="$3"
    if printf '%s' "$hay" | grep -qF -- "$needle"; then
        fail "$name ('$needle' NIE powinno wystapic w: $hay)"; else pass "$name"; fi
}

# ==========================================================================
# 1. Funkcje czyste z lib-rclone.sh
# ==========================================================================
echo
echo "1. lib-rclone.sh — funkcje czyste"

if [ ! -f "$LIB" ]; then
    red "  BRAK $LIB"; exit 1
fi
# shellcheck source=/dev/null
. "$LIB"

assert_eq "backup_enc:"       "$(rclone_base 'backup_enc:')"       "rclone_base: goly remote zostaje bez zmian"
assert_eq "backup_enc:kat/"   "$(rclone_base 'backup_enc:kat')"    "rclone_base: remote z podkatalogiem dostaje /"
assert_eq "backup_enc:kat/"   "$(rclone_base 'backup_enc:kat/')"   "rclone_base: koncowy / nie dubluje sie"
assert_eq "/local/backup/"    "$(rclone_base '/local/backup')"     "rclone_base: sciezka lokalna"

assert_eq "backup_enc:2026-08/" "$(rclone_month_dir 'backup_enc:' '2026-08')" \
    "rclone_month_dir: katalog miesieczny, BEZ podkatalogu dziennego"
assert_not_contains "$(rclone_month_dir 'backup_enc:' '2026-08')" "/31" \
    "rclone_month_dir: nie doklada dnia"

# --- walidator KEEP_MONTHS ---
for good in 1 12 120; do
    if rclone_keep_months_valid "$good"; then pass "keep_months '$good' uznane za poprawne"
    else fail "keep_months '$good' powinno byc poprawne"; fi
done
# Wzorzec *[!0-9]* w walidatorze jest nosny wlasnie tutaj: bez niego
# `[ abc -gt 0 ]` tez zwroci blad, ale wypisze komunikat na stderr.
err_out="$(rclone_keep_months_valid abc 2>&1 >/dev/null || true)"
assert_eq "" "$err_out" "keep_months 'abc' odrzucone po cichu (czyste stderr)"

for bad in "" 0 -1 abc 12x 1.5 off; do
    if rclone_keep_months_valid "$bad"; then fail "keep_months '$bad' NIE powinno byc poprawne"
    else pass "keep_months '$bad' odrzucone (retencja off)"; fi
done

# --- matematyka retencji ---
MONTHS_IN='2025-06
2025-07
2025-08
2025-09
2026-08'
out="$(printf '%s\n' "$MONTHS_IN" | rclone_months_to_purge '2026-08' 12)"
assert_eq "2025-06
2025-07
2025-08" "$out" "months_to_purge: keep=12 zostawia 12 miesiecy liczac z biezacym"

out="$(printf '%s\n' "$MONTHS_IN" | rclone_months_to_purge '2026-08' 1)"
assert_contains "$out" "2025-09" "months_to_purge: keep=1 kasuje wszystko poza biezacym"
assert_not_contains "$out" "2026-08" "months_to_purge: keep=1 NIE kasuje biezacego miesiaca"

out="$(printf '%s\n' "$MONTHS_IN" | rclone_months_to_purge '2026-08' 999)"
assert_eq "" "$out" "months_to_purge: ogromny keep nie kasuje niczego"

# biezacy miesiac nie moze wyjsc NIGDY, nawet gdy jest najstarszy na liscie
out="$(printf '2026-08\n' | rclone_months_to_purge '2026-08' 1)"
assert_eq "" "$out" "months_to_purge: sam biezacy miesiac -> nic do kasowania"

# Guard "nigdy biezacy miesiac" jest przy keep>=1 redundantny wobec samej
# arytmetyki progu — nosny staje sie dopiero wtedy, gdy ktos ominie walidator
# i przepusci keep=0. Testujemy dokladnie ten przypadek, inaczej guard bylby
# martwym kodem, ktory mozna usunac bez zapalenia sie testu.
out="$(printf '2026-07\n2026-08\n' | rclone_months_to_purge '2026-08' 0)"
assert_eq "2026-07" "$out" "months_to_purge: keep=0 z pominietym walidatorem NADAL nie tyka biezacego"

# przelom roku
out="$(printf '2025-12\n2026-01\n' | rclone_months_to_purge '2026-01' 1)"
assert_eq "2025-12" "$out" "months_to_purge: poprawnie liczy przez przelom roku"

# ==========================================================================
# 2. Atrapy dla e2e backup-cycle.sh
# ==========================================================================
BIN="$TEST_ROOT/bin"
mkdir -p "$BIN"
RECORD="$TEST_ROOT/rclone-calls.log"

cat > "$BIN/rclone" <<'MOCK'
#!/usr/bin/env bash
{ printf '%s' "$*" | tr '\n' '~'; printf '\n'; } >> "$MOCK_RECORD"
sub="$1"
case "$sub" in
    lsf)
        if [ -n "${MOCK_LSF_DIRS:-}" ]; then printf '%s\n' "$MOCK_LSF_DIRS"; fi
        ;;
esac
case "${MOCK_FAIL_ON:-}" in
    "$sub") exit 7 ;;
esac
exit 0
MOCK

cat > "$BIN/pg_dump" <<'MOCK'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
    case "$1" in -f) out="$2"; shift 2 ;; *) shift ;; esac
done
mkdir -p "$out"; printf 'dump' > "$out/toc.dat"
exit 0
MOCK

cat > "$BIN/tar" <<'MOCK'
#!/usr/bin/env bash
out=""
prev=""
for a in "$@"; do
    case "$prev" in czf|-czf) out="$a"; break ;; esac
    prev="$a"
done
[ -n "$out" ] && printf 'archiwum-atrapa' > "$out"
exit 0
MOCK

# Nadpisujemy WYLACZNIE format "+%Y-%m" — reszta idzie do prawdziwego date,
# zeby timestampy i pomiar czasu w backup-cycle dzialaly normalnie.
cat > "$BIN/date" <<'MOCK'
#!/usr/bin/env bash
if [ "$*" = "+%Y-%m" ] && [ -n "${MOCK_YM:-}" ]; then printf '%s\n' "$MOCK_YM"; exit 0; fi
for d in /bin/date /usr/bin/date; do [ -x "$d" ] && exec "$d" "$@"; done
exit 127
MOCK

chmod +x "$BIN"/*

# Uruchamia prawdziwy backup-cycle.sh z atrapami. Zwraca exit code w $CYCLE_RC,
# log w $CYCLE_LOG, liste wywolan rclone w $RECORD.
# KEEP_MONTHS_ENV=__unset__  -> zmienna NIE trafia do srodowiska (fresh install)
# KEEP_MONTHS_ENV=""          -> zmienna ustawiona na PUSTO (operator wylaczyl)
# To sa dwa ROZNE przypadki i wczesniej test myslil je ze soba: "default"
# testowany byl pusta wartoscia, wiec sprzecznosc `${VAR:-12}` z dokumentacja
# ("puste = off") byla dla testow niewidoczna.
run_cycle() {
    : > "$RECORD"
    local KEEP_MONTHS_KV=""
    local unset_opt=()
    if [ "${KEEP_MONTHS_ENV:-__unset__}" = "__unset__" ] && [ "${KEEP_MONTHS_ENV+set}" != "set" ]; then
        unset_opt=(-u DJANGO_BPP_RCLONE_KEEP_MONTHS)
    elif [ "$KEEP_MONTHS_ENV" = "__unset__" ]; then
        unset_opt=(-u DJANGO_BPP_RCLONE_KEEP_MONTHS)
    else
        KEEP_MONTHS_KV="DJANGO_BPP_RCLONE_KEEP_MONTHS=$KEEP_MONTHS_ENV"
    fi
    local work="$TEST_ROOT/work"
    rm -rf "$work"; mkdir -p "$work/backup" "$work/mediaroot" "$work/config"
    printf '[backup_enc]\ntype = local\n' > "$work/config/rclone.conf"
    CYCLE_LOG="$work/cycle.log"
    set +e
    env ${unset_opt[@]+"${unset_opt[@]}"} PATH="$BIN:$PATH" \
        MOCK_RECORD="$RECORD" \
        MOCK_YM="${MOCK_YM:-2026-08}" \
        MOCK_LSF_DIRS="${MOCK_LSF_DIRS:-}" \
        MOCK_FAIL_ON="${MOCK_FAIL_ON:-}" \
        BPP_BACKUP_DIR="$work/backup" \
        BPP_MEDIA_DIR="$work/mediaroot" \
        BPP_RCLONE_CONFIG="$work/config/rclone.conf" \
        BPP_BACKUP_LOG="$work/backup-cycle.log" \
        DJANGO_BPP_DB_HOST=db DJANGO_BPP_DB_PORT=5432 \
        DJANGO_BPP_DB_USER=u DJANGO_BPP_DB_NAME=n \
        DJANGO_BPP_HOSTNAME=test.example \
        DJANGO_BPP_RCLONE_REMOTE="backup_enc:" \
        ROLLBAR_ACCESS_TOKEN="" \
        ${KEEP_MONTHS_KV:+"$KEEP_MONTHS_KV"} \
        bash "$CYCLE" > "$CYCLE_LOG" 2>&1
    CYCLE_RC=$?
    set -e
}

# ==========================================================================
# 2b. Kazda z dwoch warstw filtrowania osobno
# ==========================================================================
# Sa dwie niezalezne warstwy odsiewajace katalogi, ktore nie sa miesiacami:
# wzorzec w rclone_list_month_dirs i wzorzec w rclone_months_to_purge. Skoro
# obie chronia przed tym samym, zaden test e2e nie zapali sie po usunieciu
# JEDNEJ z nich - dlatego kazda dostaje wlasny test jednostkowy. Inaczej
# redundancja po cichu zgnije w martwy kod.
echo
echo "2b. warstwy filtrowania katalogow"

GARBAGE='-

99
2026-08-01
dane-wazne
2024-01'
out="$(printf '%s\n' "$GARBAGE" | rclone_months_to_purge '2026-08' 12 2>&1)"
assert_eq "2024-01" "$out" \
    "months_to_purge: przepuszcza WYLACZNIE YYYY-MM (goly '-' wywracal _ym_index)"

out="$(MOCK_RECORD=/dev/null MOCK_LSF_DIRS='2024-01/
99/
2026-08-01/
dane-wazne/' PATH="$BIN:$PATH" bash -c '. "$1"; rclone_list_month_dirs "backup_enc:"' _ "$LIB")"
assert_eq "2024-01" "$out" \
    "list_month_dirs: przepuszcza WYLACZNIE YYYY-MM"

# ==========================================================================
# 3. Krok 4 — wysylka do katalogu miesiecznego (asercje mutacyjne)
# ==========================================================================
echo
echo "3. backup-cycle krok 4 — wysylka"

MOCK_YM=2026-08 MOCK_LSF_DIRS="" KEEP_MONTHS_ENV=__unset__ run_cycle
UPLOAD="$(grep -E '^(copy|sync) ' "$RECORD" || true)"

assert_eq "0" "$CYCLE_RC" "backup-cycle konczy sie sukcesem"
assert_contains "$UPLOAD" "copy " \
    "MUTACYJNY: wysylka uzywa 'copy' (sync skasowalby archiwum miesiaca)"
assert_not_contains "$UPLOAD" "sync " \
    "MUTACYJNY: wysylka NIE uzywa 'sync'"
# Porownanie CALEGO argumentu docelowego, nie fragmentu: wczesniejsza wersja
# szukala "backup_enc:2026-08/0", wiec lapala dni 01-09 i przepuszczala mutacje
# 31 dnia miesiaca.
UPLOAD_DEST="$(awk '{ print $3 }' <<< "$UPLOAD")"
assert_eq "backup_enc:2026-08/" "$UPLOAD_DEST" \
    "MUTACYJNY: cel to DOKLADNIE backup_enc:2026-08/ (zaden podkatalog dzienny)"

MOCK_YM=2026-08 MOCK_LSF_DIRS="" KEEP_MONTHS_ENV=__unset__ MOCK_FAIL_ON=copy run_cycle
assert_eq "3" "$CYCLE_RC" "nieudany copy -> exit 3 (jak dotad przy sync)"

# ==========================================================================
# 4. Krok 5 — retencja zdalna
# ==========================================================================
echo
echo "4. backup-cycle krok 5 — retencja zdalna"

# "2026-08-01" i "99" to celowe pulapki: same cyfry i myslniki, wiec przechodza
# przez filtr w rclone_months_to_purge — zatrzymac je moze WYLACZNIE wzorzec
# ^YYYY-MM$ w rclone_list_month_dirs. Bez nich usuniecie tego wzorca przechodzi
# testy, a w produkcji `10#08-01` policzyloby sie jako 7 i katalog poszedlby
# do skasowania.
DIRS='2024-01/
2025-06/
2025-08/
2026-08/
2026-08-01/
99/
dane-wazne/'

# domyslnie WLACZONA (12 miesiecy) przy zmiennej NIEUSTAWIONEJ w .env
MOCK_YM=2026-08 MOCK_LSF_DIRS="$DIRS" KEEP_MONTHS_ENV=__unset__ run_cycle
PURGE="$(grep -E '^purge ' "$RECORD" || true)"
assert_eq "0" "$CYCLE_RC" "retencja domyslna: cykl konczy sie sukcesem"
# Porownanie calego argumentu, nie fragmentu: gdyby ktos usunal limit
# "1 na cykl", do rclone poleciałaby CALA lista jako jeden wielolinijkowy
# argument - liczenie linii by tego nie zauwazylo, porownanie tresci owszem
# (atrapa splaszcza nowe linie do "~").
PURGE_TARGET="$(awk '{ print $2 }' <<< "$PURGE")"
assert_eq "backup_enc:2024-01" "$PURGE_TARGET" \
    "MUTACYJNY: usuwany jest DOKLADNIE jeden, najstarszy katalog miesieczny"
assert_eq "1" "$(printf '%s' "$PURGE" | grep -c . || true)" \
    "bezpiecznik: maksymalnie JEDNO wywolanie purge na cykl"
assert_not_contains "$PURGE" "2026-08" "retencja NIGDY nie kasuje biezacego miesiaca"
assert_not_contains "$PURGE" "dane-wazne" "retencja NIGDY nie rusza katalogu spoza wzorca YYYY-MM"
assert_not_contains "$PURGE" "2026-08-01" "retencja NIGDY nie rusza katalogu 'YYYY-MM-DD' (same cyfry, a nie miesiac)"
assert_not_contains "$PURGE" "backup_enc:99" "retencja NIGDY nie rusza katalogu '99' (same cyfry, a nie miesiac)"

# purge musi isc PO udanym copy, nigdy przed
# NIE `| head -2`: pod `set -o pipefail` head zamyka potok, grep ginie od
# SIGPIPE, pipeline zwraca blad i `set -e` przerywa CALY zestaw bez zadnej
# asercji. Dokladnie ta pulapka, przed ktora ostrzega ten PR - czytamy wiec
# calosc, a dopiero potem bierzemy dwie pierwsze linie.
ORDER_ALL="$(grep -E '^(copy|purge) ' "$RECORD" | cut -d' ' -f1 || true)"
ORDER="$(printf '%s\n' "$ORDER_ALL" | sed -n '1,2p' | tr '\n' ' ')"
assert_eq "copy purge " "$ORDER" "kolejnosc: najpierw copy, potem purge"

# jawne wylaczenie
# Pusta wartosc jest UDOKUMENTOWANYM wylacznikiem ("DJANGO_BPP_RCLONE_KEEP_MONTHS="
# w .env). Musi byc na tej liscie - bez niej `${VAR:-12}` zamiast `${VAR-12}`
# przechodzi testy, a operator wylaczajacy retencje dostaje ja WLACZONA.
for offval in "" 0 abc -1; do
    MOCK_YM=2026-08 MOCK_LSF_DIRS="$DIRS" KEEP_MONTHS_ENV="$offval" run_cycle
    P="$(grep -cE '^purge ' "$RECORD" || true)"
    assert_eq "0" "$P" "KEEP_MONTHS='$offval' -> zero purge"
    assert_eq "0" "$CYCLE_RC" "KEEP_MONTHS='$offval' -> cykl nadal sukces"
    # Bez wzorca *[!0-9]* w walidatorze `[ abc -gt 0 ]` tez odrzuci wartosc,
    # ale wsypie blad basha do logu backupu, ktory przy awarii leci do
    # Rollbara. NIE dopasowujemy tresci komunikatu - bash go tlumaczy
    # (po polsku: "oczekiwano liczby calkowitej"), wiec asercja na angielski
    # tekst przechodzilaby zawsze i niczego nie pilnowala. Prefiks "bash:"
    # jest nietlumaczony.
    assert_not_contains "$(cat "$CYCLE_LOG")" "bash:" \
        "KEEP_MONTHS='$offval' -> brak komunikatu basha w logu"
done

# Wzorzec ^YYYY-MM$ w rclone_list_month_dirs jest nosny tylko wtedy, gdy
# smieciowy katalog jest JEDYNYM kandydatem - inaczej limit "1 na cykl"
# przepuszcza pod noz starszy, prawdziwy miesiac i smiec sie nie ujawnia.
# "99" -> _ym_index policzyloby 99*12+99-1 = 1286, czyli rok 99 n.e.
MOCK_YM=2026-08 MOCK_LSF_DIRS='2026-08/
99/' KEEP_MONTHS_ENV="12" run_cycle
assert_eq "0" "$(grep -cE '^purge ' "$RECORD" || true)" \
    "MUTACYJNY: katalog '99' jako jedyny kandydat NIE zostaje usuniety"

# "2026-08-01" (stary katalog dzienny wyniesiony na poziom remote) -
# _ym_index wzialoby ostatnie pole po myslniku jako miesiac i wyszedlby
# 2026-01, czyli cos "starego".
MOCK_YM=2026-08 MOCK_LSF_DIRS='2026-08/
2026-08-01/' KEEP_MONTHS_ENV="1" run_cycle
assert_eq "0" "$(grep -cE '^purge ' "$RECORD" || true)" \
    "MUTACYJNY: katalog '2026-08-01' jako jedyny kandydat NIE zostaje usuniety"

# nic nie jest wystarczajaco stare
MOCK_YM=2026-08 MOCK_LSF_DIRS='2026-07/
2026-08/' KEEP_MONTHS_ENV="12" run_cycle
assert_eq "0" "$(grep -cE '^purge ' "$RECORD" || true)" "swieze archiwum -> zero purge"

# nieudany purge to OSTRZEZENIE, nie porazka backupu
MOCK_YM=2026-08 MOCK_LSF_DIRS="$DIRS" KEEP_MONTHS_ENV="12" MOCK_FAIL_ON=purge run_cycle
assert_eq "0" "$CYCLE_RC" "nieudany purge NIE wywraca backupu (sprzatanie != backup)"
assert_contains "$(cat "$CYCLE_LOG")" "UWAGA" "nieudany purge zostawia ostrzezenie w logu"

# nieudane listowanie remote tez nie moze wywrocic backupu
MOCK_YM=2026-08 MOCK_LSF_DIRS="$DIRS" KEEP_MONTHS_ENV="12" MOCK_FAIL_ON=lsf run_cycle
assert_eq "0" "$CYCLE_RC" "nieudane lsf NIE wywraca backupu"
assert_eq "0" "$(grep -cE '^purge ' "$RECORD" || true)" "nieudane lsf -> zero purge (nie zgadujemy)"

echo
echo "=================================="
green "PASS: $PASS"
if [ "$FAIL" -gt 0 ]; then red "FAIL: $FAIL"; exit 1; fi
green "Wszystkie testy przeszly."

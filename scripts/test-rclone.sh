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
# MOCK_FAIL_ON_STEP=pg_dump - do wymuszenia fail("pg_dump", 1) w sekcji 8
# (notyfikacja przy padlym appserverze). Domyslnie zawsze sukces.
if [ "${MOCK_FAIL_ON_STEP:-}" = "pg_dump" ]; then exit 1; fi
out=""
while [ $# -gt 0 ]; do
    case "$1" in -f) out="$2"; shift 2 ;; *) shift ;; esac
done
mkdir -p "$out"; printf 'dump' > "$out/toc.dat"
exit 0
MOCK

cat > "$BIN/python" <<'MOCK'
#!/usr/bin/env bash
# notify_rollbar odpala ten program WEWNATRZ appservera (docker exec). Testy
# nie maja isc do prawdziwego Rollbara - potwierdzamy tylko, ze atrapa dockera
# faktycznie doszla do wywolania pythona, bez zadnego zadania sieciowego.
echo "python -c <rollbar-payload>" >> "$MOCK_RECORD"
echo "rollbar http=200"
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

# docker: backup-cycle.sh nie wola juz pg_dump/rclone lokalnie - adresuje
# kontenery po labelach (bpp_container -> `docker ps --filter label=...`) i
# wykonuje ciezkie kroki przez `docker exec`. Ta atrapa odgrywa role samego
# dockera: `ps` zwraca fikcyjne ID wyliczone z filtra usługi, `exec` zdejmuje
# "exec", flagi (-e VAR, -i/-t/-it) i ID kontenera, po czym `exec`-uje reszte
# LOKALNIE - dzieki temu istniejace atrapy pg_dump/rclone wyzej w PATH nadal
# dostaja wywolanie i dotychczasowe asercje ("copy, nie sync" itp.) dzialaja
# na tej samej sciezce bez zmian.
cat > "$BIN/docker" <<'MOCK'
#!/usr/bin/env bash
echo "docker $*" >> "$MOCK_RECORD"
case "$1" in
    ps) printf 'cid-%s\n' "$(echo "$*" | sed -n 's/.*service=\([a-z-]*\).*/\1/p')"; exit 0 ;;
    exec)
        shift
        target=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -e) shift 2 ;;
                -i|-t|-it) shift ;;
                cid-*) target="$1"; shift; break ;;
                *) shift ;;
            esac
        done
        # MOCK_FAIL_ON="exec-<usluga>" -> symulacja padlego kontenera podczas
        # `docker exec` (np. appserver widoczny w `docker ps`, ale exec pada).
        # Zwracamy 42 (NIE 1/2/3 - kody prawdziwych krokow), zeby asercja w
        # sekcji 8 faktycznie odroznila "notify_rollbar polkniete" (kod
        # zostaje 1, kod fail("pg_dump",1)) od "notify_rollbar sklobrowalo
        # trap" (kod zmienilby sie na 42) - kod 1 bylby niediagnostyczny,
        # bo pokrywa sie z intencjonalnym kodem pg_dump.
        case "${MOCK_FAIL_ON:-}" in
            "exec-${target#cid-}") exit 42 ;;
        esac
        if [ $# -gt 0 ]; then exec "$@"; fi
        exit 0
        ;;
    *) exit 1 ;;
esac
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
    # ROLLBAR_TOKEN_ENV=1 -> notify_rollbar dostaje token i NIE konczy sie na
    # wczesnym "skip", wiec faktycznie dochodzi do bpp_container/docker exec.
    # Domyslnie (nieustawione) token pusty - jak dotad, notify jest no-opem.
    local rollbar_token=""
    if [ "${ROLLBAR_TOKEN_ENV:-0}" = "1" ]; then
        rollbar_token="test-rollbar-token"
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
        MOCK_FAIL_ON_STEP="${MOCK_FAIL_ON_STEP:-}" \
        BPP_BACKUP_DIR="$work/backup" \
        BPP_MEDIA_DIR="$work/mediaroot" \
        BPP_RCLONE_CONFIG="$work/config/rclone.conf" \
        BPP_BACKUP_LOG="$work/backup-cycle.log" \
        DJANGO_BPP_DB_HOST=db DJANGO_BPP_DB_PORT=5432 \
        DJANGO_BPP_DB_USER=u DJANGO_BPP_DB_NAME=n \
        DJANGO_BPP_DB_PASSWORD=p \
        COMPOSE_PROJECT_NAME=testproj \
        DJANGO_BPP_HOSTNAME=test.example \
        DJANGO_BPP_RCLONE_REMOTE="backup_enc:" \
        ROLLBAR_ACCESS_TOKEN="$rollbar_token" \
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

# Orkiestrator (docker:cli) nie ma juz lokalnie pg_dump ani rclone - oba kroki
# MUSZA isc przez `docker exec` w kontenerach, ktore te narzedzia maja.
# UWAGA: `docker exec cid-dbserver`, NIE golo "docker exec" - sam shim
# rclone() tez generuje "docker exec", wiec luzniejsza asercja przechodzilaby
# nawet po regresji cofajacej krok 1 do lokalnego pg_dump (shim i tak zawolalby
# "docker exec" dla rclone copy). Podobnie "service=dbserver" samo w sobie NIE
# wystarczy - ten string wystepuje juz w linii `docker ps --filter
# label=...service=dbserver`, ktora leci ZAWSZE (nawet gdy krok 1 zostal
# lokalny), wiec dopiero POLACZENIE "docker exec" + "cid-dbserver" pina
# faktyczne wykonanie pg_dump przez `docker exec` w dbserverze.
RECORD_CONTENT="$(cat "$RECORD")"
assert_contains "$RECORD_CONTENT" "docker exec cid-dbserver" \
    "krok pg_dump idzie przez docker exec w dbserverze"
assert_not_contains "$RECORD_CONTENT" "docker run" \
    "cykl nie uzywa docker run (sciezki hosta!)"
assert_contains "$RECORD_CONTENT" "service=rclone" \
    "wysylka celuje w serwis rclone"

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

# ==========================================================================
# 5. rclone_fix_config_owner — wlasciciel i prawa rclone.conf
# ==========================================================================
echo
echo "5. rclone_fix_config_owner — wlasciciel i prawa rclone.conf"

# `rclone config` dziala w kontenerze jako root, wiec rclone.conf powstaje na
# hoscie jako root:root. docs/eksploatacja/przenosiny-serwera.md kaze przenosic
# $BPP_CONFIGS_DIR zwyklym `rsync -avzP` — ten takiego pliku NIE przeczyta
# i zostawi nowy serwer bez konfiguracji backupu zdalnego, a operator dowie sie
# o tym dopiero, gdy zabraknie kopii na zdalnym. Stad wyrownanie wlasciciela do
# wlasciciela KATALOGU (czyli tego, kto zrobil init-configs na hoscie).
#
# chown jest atrapa w PATH: prawdziwej zmiany wlasciciela nie da sie zrobic bez
# roota, a asercja ma sprawdzic, ze wolanie w ogole leci i z jakimi arguemntami.

OWNER_DIR="$TEST_ROOT/owner/rclone"
OWNER_BIN="$TEST_ROOT/owner-bin"
mkdir -p "$OWNER_DIR" "$OWNER_BIN"
CONF="$OWNER_DIR/rclone.conf"
export CHOWN_LOG="$TEST_ROOT/chown.log"

cat > "$OWNER_BIN/chown" <<'SH'
#!/bin/sh
echo "chown $*" >> "$CHOWN_LOG"
if [ "${MOCK_CHOWN_FAIL:-0}" = "1" ]; then exit 1; fi
exit 0
SH
chmod +x "$OWNER_BIN/chown"

# Prawa pliku przenosnie: GNU (Linux/CI) i BSD (macOS dewelopera).
perm_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
EXPECTED_OWNER="$(stat -c '%u:%g' "$OWNER_DIR" 2>/dev/null || stat -f '%u:%g' "$OWNER_DIR")"

OLD_PATH="$PATH"
PATH="$OWNER_BIN:$PATH"

# --- brak pliku: kreator przerwany albo zapis padl -------------------------
: > "$CHOWN_LOG"
rm -f "$CONF"
FIX_RC=0; rclone_fix_config_owner "$CONF" || FIX_RC=$?
assert_eq "1" "$FIX_RC" "brak pliku -> rc=1 (caller ma o czym poinformowac)"
assert_eq "0" "$(grep -c . "$CHOWN_LOG" || true)" "brak pliku -> zaden chown nie leci"

# --- plik jest: wlasciciel katalogu + zwezenie praw ------------------------
: > "$CHOWN_LOG"
printf '[backup_enc]\ntype = local\n' > "$CONF"
chmod 0644 "$CONF"
FIX_RC=0; rclone_fix_config_owner "$CONF" || FIX_RC=$?
assert_eq "0" "$FIX_RC" "plik jest -> rc=0"
assert_contains "$(cat "$CHOWN_LOG")" "chown $EXPECTED_OWNER $CONF" \
    "chown celuje we wlasciciela KATALOGU, nie w zgadywany uid"
assert_eq "600" "$(perm_of "$CONF")" "rclone.conf zwezony do 0600 (sa w nim poswiadczenia)"

# --- chown padl: funkcja nie moze udawac sukcesu ---------------------------
: > "$CHOWN_LOG"
FIX_RC=0; MOCK_CHOWN_FAIL=1 rclone_fix_config_owner "$CONF" || FIX_RC=$?
assert_eq "3" "$FIX_RC" "nieudany chown -> rc=3, nie cichy sukces"

PATH="$OLD_PATH"
unset MOCK_CHOWN_FAIL

# ==========================================================================
# 5b. scripts/rclone-config.sh — cale wolanie, nie sama funkcja
# ==========================================================================
echo
echo "5b. scripts/rclone-config.sh — e2e z atrapa kreatora"

# Sekcja 5 testuje funkcje; tutaj leci PRAWDZIWY skrypt, ktory `make
# rclone-config` odpala w kontenerze. Bez tego regresja w samym okablowaniu
# (wywalony `. lib-rclone.sh`, zla sciezka configu) przeszlaby niezauwazona:
# funkcja dalej byla zielona, a target nic by nie poprawial.

CFG_BIN="$TEST_ROOT/cfg-bin"
CFG_DIR="$TEST_ROOT/cfg/rclone"
mkdir -p "$CFG_BIN" "$CFG_DIR"
CFG_CONF="$CFG_DIR/rclone.conf"

# Atrapa kreatora: prawdziwy `rclone config` zapisuje plik pod --config.
cat > "$CFG_BIN/rclone" <<'SH'
#!/bin/sh
conf=""
while [ $# -gt 0 ]; do
    case "$1" in --config) conf="$2"; shift 2 ;; *) shift ;; esac
done
if [ "${MOCK_WIZARD_SAVES:-1}" = "1" ]; then
    printf '[backup_enc]\ntype = local\n' > "$conf"
fi
exit 0
SH
chmod +x "$CFG_BIN/rclone"

OLD_PATH="$PATH"
PATH="$CFG_BIN:$PATH"

# --- kreator zapisal konfiguracje -----------------------------------------
rm -f "$CFG_CONF"
CFG_RC=0
BPP_RCLONE_CONFIG="$CFG_CONF" bash "$REPO_DIR/scripts/rclone-config.sh" >/dev/null 2>&1 || CFG_RC=$?
assert_eq "0" "$CFG_RC" "rclone-config.sh konczy sie zerem, gdy kreator zapisal config"
assert_eq "600" "$(perm_of "$CFG_CONF")" "rclone-config.sh zweza prawa swiezego configu do 0600"

# --- kreator nic nie zapisal: ostrzezenie, nie cisza ------------------------
rm -f "$CFG_CONF"
CFG_OUT="$(MOCK_WIZARD_SAVES=0 BPP_RCLONE_CONFIG="$CFG_CONF" \
    bash "$REPO_DIR/scripts/rclone-config.sh" 2>&1 || true)"
assert_contains "$CFG_OUT" "UWAGA" "brak configu po kreatorze -> ostrzezenie na wyjsciu"
assert_contains "$CFG_OUT" "read-only file system" \
    "ostrzezenie nazywa najczestsza przyczyne (mount :ro)"

PATH="$OLD_PATH"

# ==========================================================================
# 6. Skrypty uruchamiaja sie pod busybox ash (docelowe obrazy nie maja basha)
# ==========================================================================
echo
echo "6. Uruchomienie pod busybox ash"

# Shebang sprawdzamy na hoscie (head+grep na widocznym pliku) - nie trzeba do
# tego dockera, w przeciwienstwie do e2e nizej. Dziala niezaleznie od tego,
# czy docker jest dostepny.
for s in backup-cycle.sh rclone-sync.sh rclone-config.sh; do
    head_rc=0
    head -1 "$REPO_DIR/scripts/$s" | grep -q '^#!/bin/sh$' || head_rc=$?
    assert_eq "0" "$head_rc" "$s ma shebang #!/bin/sh"
done

# Przy definitywnej porazce e2e nizej zostawal tylko kod wyjscia, bez
# stdout/stderr procesu - cicha awaria bez sladu. Wypisujemy przechwycone
# wyjscie WYLACZNIE wtedy, gdy wywolanie faktycznie zawiodlo.
show_ash_output_on_fail() {
    local rc="$1" out="$2" label="$3"
    if [ "$rc" != "0" ]; then
        echo "  --- wyjscie $label pod ash (rc=$rc) ---"
        printf '%s\n' "$out"
    fi
}

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "  SKIP: brak dzialajacego dockera (e2e pod busybox ash)"
else
    ASH_IMAGE="${BPP_ASH_TEST_IMAGE:-docker:cli}"
    ash_bin="$TEST_ROOT/ash-bin"
    mkdir -p "$ash_bin"
    # Atrapy: skrypty maja dojsc do konca bez prawdziwej bazy i bez sieci.
    # WAZNE: shebang #!/bin/sh, nie #!/usr/bin/env bash - w obrazie testowym
    # (docker:cli) nie ma basha, wiec atrapa z bashowym shebangiem w ogole by
    # sie nie uruchomila (rc=127).
    #
    # pg_dump NIE moze byc gola atrapa "exit 0": backup-cycle.sh po pg_dump
    # robi `tar czf "$DB_TAR" -C "$BACKUP_DIR" "db-backup-TS"`, a bez
    # katalogu dumpu tar pada i caly cykl konczy sie fail("db-tar", 1).
    # Atrapa odwzorowuje MOCK z sekcji 2 (pg_dump tworzy katalog z -f i
    # wrzuca do niego plik), tylko przepisana na #!/bin/sh.
    cat > "$ash_bin/pg_dump" <<'MOCK'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do
    case "$1" in -f) out="$2"; shift 2 ;; *) shift ;; esac
done
mkdir -p "$out"; printf 'dump' > "$out/toc.dat"
exit 0
MOCK
    # rclone dzieli sie miedzy backup-cycle.sh/rclone-sync.sh (`copy`) i
    # rclone-config.sh (`config`): zawsze zapisuje plik pod --config, jesli
    # taki argument dostanie. Dla `copy` to no-op (plik juz istnieje z
    # ponizszego printf), a dla rclone-config.sh to WARUNEK KONIECZNY, zeby
    # doszlo do rclone_fix_config_owner (chown/chmod dzialaja tylko na
    # istniejacym pliku).
    cat > "$ash_bin/rclone" <<'MOCK'
#!/bin/sh
conf=""
while [ $# -gt 0 ]; do
    case "$1" in --config) conf="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "$conf" ] && printf '[backup_enc]\ntype = local\n' > "$conf"
exit 0
MOCK
    for t in curl jq; do
        printf '#!/bin/sh\nexit 0\n' > "$ash_bin/$t"
    done
    # docker: backup-cycle.sh adresuje dbserver/rclone po labelach compose
    # (bpp_container -> `docker ps --filter label=...`) i wykonuje pg_dump
    # oraz rclone przez `docker exec` - w tym kontenerze testowym nie ma
    # dockera-w-dockerze, wiec atrapa udaje oba wywolania: `ps` zwraca
    # fikcyjne ID z filtra usługi, `exec` zdejmuje "exec"/flagi/ID kontenera
    # i uruchamia reszte LOKALNIE (trafiajac w atrapy pg_dump/rclone wyzej).
    # UWAGA: domyslna galaz (nierozpoznany subcommand) MUSI dac `exit 1`, nie
    # `exit 0`. Entrypoint obrazu docker:cli (docker-entrypoint.sh) robi
    # `if docker help "$1" >/dev/null 2>&1; then set -- docker "$@"; fi` -
    # przy atrapie zwracajacej wszedzie 0 ten test zawsze wychodzi prawdziwy,
    # entrypoint doklada "docker" przed CMD (`docker sh -c ...` zamiast
    # `sh -c ...`), a to trafia z powrotem w ta sama atrape z $1=sh, ktora
    # znow cicho konczy sie exit 0 - kontener wychodzi natychmiast, BEZ
    # jakiegokolwiek stdout, i asercje nizej dostaja pusty log przy rc=0.
    # Zweryfikowane bezposrednio na tym hoscie (docker inspect pokazywal
    # exited/exit=0/brak logow).
    cat > "$ash_bin/docker" <<'MOCK'
#!/bin/sh
case "$1" in
    ps) printf 'cid-%s\n' "$(echo "$*" | sed -n 's/.*service=\([a-z-]*\).*/\1/p')"; exit 0 ;;
    exec)
        shift
        while [ $# -gt 0 ]; do
            case "$1" in
                -e) shift 2 ;;
                -i|-t|-it) shift ;;
                cid-*) shift; break ;;
                *) shift ;;
            esac
        done
        if [ $# -gt 0 ]; then exec "$@"; fi
        exit 0
        ;;
    *) exit 1 ;;
esac
MOCK
    chmod +x "$ash_bin"/*
    # tar i date NIE dostaja atrap: prawdziwy busybox 1.37 w docker:cli ma
    # oba applety i obsluguje tu potrzebne opcje (tar czf -C, date +%Y-%m,
    # stat -c%s) - zweryfikowane bezposrednio w tym obrazie. Atrapa dublowalaby
    # tylko prawdziwe narzedzie bez zadnej korzysci dla testu.
    ash_work="$TEST_ROOT/ash-work"
    mkdir -p "$ash_work/backup" "$ash_work/media" "$ash_work/config"
    printf '[backup_enc]\ntype = local\n' > "$ash_work/config/rclone.conf"
    ash_log="$ash_work/backup-cycle.log"

    # NIE dodawac tu retry na `docker run`. Wczesniejsza wersja tej sekcji
    # miala retry "na wypadek" wyscigu bind-mountu - zweryfikowane empirycznie
    # (65 kontrolnych startow na tym samym hoscie, 0 porazek), ze taki wyscig
    # nie istnieje w obecnym ksztalcie testu. Obserwowany wtedy blad
    # ("can't create .../nonexistent directory") byl artefaktem iterowania
    # nad tym testem (katalog docelowy jeszcze nie istnial w danym miejscu
    # skryptu w trakcie edycji), nie awaria dockera - retry go maskowal
    # tylko dlatego, ze nieudana pierwsza proba zostawiala po sobie katalog
    # dla drugiej. Zamiast retry: przechwytujemy pelne wyjscie i pokazujemy
    # je przy definitywnej porazce (`show_ash_output_on_fail` wyzej), zeby
    # realny blad byl widoczny od razu, a nie diagnozowany na slepo.
    ash_out="$(docker run --rm \
        -v "$REPO_DIR/scripts:/scripts:ro" \
        -v "$ash_bin:/stub:ro" \
        -v "$ash_work:/work" \
        -e "PATH=/stub:/usr/local/bin:/usr/bin:/bin" \
        -e BPP_BACKUP_DIR=/work/backup \
        -e BPP_MEDIA_DIR=/work/media \
        -e BPP_RCLONE_CONFIG=/work/config/rclone.conf \
        -e BPP_BACKUP_LOG=/work/backup-cycle.log \
        -e DJANGO_BPP_DB_HOST=db -e DJANGO_BPP_DB_PORT=5432 \
        -e DJANGO_BPP_DB_USER=u -e DJANGO_BPP_DB_NAME=n \
        -e DJANGO_BPP_DB_PASSWORD=p \
        -e COMPOSE_PROJECT_NAME=testash \
        -e DJANGO_BPP_RCLONE_KEEP_MONTHS=0 \
        "$ASH_IMAGE" /scripts/backup-cycle.sh 2>&1)" && ash_rc=0 || ash_rc=$?
    assert_eq "0" "$ash_rc" "backup-cycle.sh dochodzi do konca pod busybox ash"
    show_ash_output_on_fail "$ash_rc" "$ash_out" "backup-cycle.sh"

    # Samo rc=0 NIE przypina poprawki BPP_INTENDED_EXIT=1 przed koncowym
    # `exit 0`: bledna wersja (bez tej linii) TEZ konczy sie rc=0, bo trap
    # EXIT->on_exit wywoluje `exit "$rc"` z rc=0 niezaleznie od tego, ktora
    # galaz go ustawila. Zmyslona regresja (linia usunieta recznie, zbadana
    # w tej samej sesji) dawala DOKLADNIE to: rc=0 i dodatkowa linie
    # "FAIL: unexpected-error (exit=0)" plus drugie "rollbar: skip" w logu -
    # wiec pina to tresc loga, nie kod wyjscia.
    ASH_LOG="$(cat "$ash_log" 2>/dev/null || true)"
    assert_not_contains "$ASH_LOG" "unexpected-error" \
        "MUTACYJNY: udany cykl NIE zglasza sie przez on_exit jako unexpected-error"
    assert_contains "$ASH_LOG" "Backup OK on" \
        "udany cykl zostawia w logu komunikat sukcesu"

    # --- rclone-sync.sh - realne uruchomienie pod ash, nie tylko shebang ---
    sync_out="$(docker run --rm \
        -v "$REPO_DIR/scripts:/scripts:ro" \
        -v "$ash_bin:/stub:ro" \
        -v "$ash_work:/work" \
        -e "PATH=/stub:/usr/local/bin:/usr/bin:/bin" \
        -e BPP_BACKUP_DIR=/work/backup \
        -e BPP_RCLONE_CONFIG=/work/config/rclone.conf \
        -e DJANGO_BPP_RCLONE_REMOTE="backup_enc:" \
        "$ASH_IMAGE" /scripts/rclone-sync.sh 2>&1)" && sync_rc=0 || sync_rc=$?
    assert_eq "0" "$sync_rc" "rclone-sync.sh dochodzi do konca pod busybox ash"
    show_ash_output_on_fail "$sync_rc" "$sync_out" "rclone-sync.sh"

    # --- rclone-config.sh - realne uruchomienie pod ash, z atrapa kreatora,
    # ktora faktycznie zapisuje plik (patrz atrapa "rclone" wyzej), zeby
    # doszlo do rclone_fix_config_owner (chown/chmod na prawdziwym pliku). ---
    mkdir -p "$ash_work/rcfg"
    rm -f "$ash_work/rcfg/rclone.conf"
    cfg_out="$(docker run --rm \
        -v "$REPO_DIR/scripts:/scripts:ro" \
        -v "$ash_bin:/stub:ro" \
        -v "$ash_work:/work" \
        -e "PATH=/stub:/usr/local/bin:/usr/bin:/bin" \
        -e BPP_RCLONE_CONFIG=/work/rcfg/rclone.conf \
        "$ASH_IMAGE" /scripts/rclone-config.sh 2>&1)" && cfg_rc=0 || cfg_rc=$?
    assert_eq "0" "$cfg_rc" "rclone-config.sh dochodzi do konca pod busybox ash"
    show_ash_output_on_fail "$cfg_rc" "$cfg_out" "rclone-config.sh"
fi

# ==========================================================================
# 7. bpp_container - adresowanie kontenerow po labelach compose
# ==========================================================================
echo
echo "7. bpp_container"

# Kontenery adresujemy po labelach, NIE po nazwie: compose generuje nazwy
# (`<projekt>-<usluga>-1`), a `container_name:` w tym repo nie jest ustawiany,
# wiec `docker exec dbserver` po prostu nie zadziala.
. "$REPO_DIR/scripts/lib-container.sh"

cont_bin="$TEST_ROOT/cont-bin"
mkdir -p "$cont_bin"
export DOCKER_LOG="$TEST_ROOT/docker-calls.log"
cat > "$cont_bin/docker" <<'SH'
#!/bin/sh
echo "docker $*" >> "$DOCKER_LOG"
case "$1" in
    ps) [ "${MOCK_NO_CONTAINER:-0}" = "1" ] || printf 'abc123\n' ;;
esac
exit 0
SH
chmod +x "$cont_bin/docker"

OLD_PATH="$PATH"; PATH="$cont_bin:$PATH"
export COMPOSE_PROJECT_NAME=testproj

: > "$DOCKER_LOG"
got="$(bpp_container dbserver)"
assert_eq "abc123" "$got" "bpp_container zwraca ID kontenera"
assert_contains "$(cat "$DOCKER_LOG")" \
    "label=com.docker.compose.project=testproj" "filtruje po projekcie"
assert_contains "$(cat "$DOCKER_LOG")" \
    "label=com.docker.compose.service=dbserver" "filtruje po usludze"
# `head` bylby konsumentem POTOKU (docker ps | head -1), nigdy argumentem
# samego `docker` - wiec zadna implementacja nie zostawilaby "head -1" w tym
# logu wywolan, a poprzednia wersja tej asercji nie mogla NIGDY pasc. Pilnujemy
# wiec kontraktu tam, gdzie faktycznie zyje: w zrodle lib-container.sh - kodzie,
# nie komentarzach (plik CELOWO tlumaczy "head -1" slowem w komentarzu, wiec
# surowy grep po calej tresci zapaliby sie na wlasnym uzasadnieniu).
LIBC_CODE="$(grep -v '^[[:space:]]*#' "$REPO_DIR/scripts/lib-container.sh")"
assert_not_contains "$LIBC_CODE" "head -" \
    "lib-container.sh nie uzywa head w potoku (SIGPIPE pod pipefail)"
assert_contains "$LIBC_CODE" "sed -n '1p'" \
    "lib-container.sh uzywa sed -n '1p' zamiast head"

: > "$DOCKER_LOG"
rc=0; MOCK_NO_CONTAINER=1 bpp_container dbserver >/dev/null || rc=$?
assert_eq "1" "$rc" "brak kontenera -> status 1, nie cichy sukces"

PATH="$OLD_PATH"; unset MOCK_NO_CONTAINER COMPOSE_PROJECT_NAME

# ==========================================================================
# 8. notify_rollbar przez appservera
# ==========================================================================
echo
echo "8. notify_rollbar przez appservera"

# Orkiestrator (docker:cli) nie ma curl ani jq - notyfikacja idzie przez
# `docker exec` w appserverze (python z jego wlasnego env_file czyta token).
: > "$RECORD"
MOCK_YM=2026-08 ROLLBAR_TOKEN_ENV=1 run_cycle
assert_eq "0" "$CYCLE_RC" "udany cykl z tokenem Rollbara nadal konczy sie sukcesem"
assert_contains "$(cat "$RECORD")" "service=appserver" \
    "notyfikacja celuje w appservera"

# Martwy appserver (docker ps go widzi, ale `docker exec` pada) nie moze
# sklobrowac kodu wyjscia ani urwac trapa EXIT w polowie. ROLLBAR_TOKEN_ENV=1
# jest tu KONIECZNE (inaczej niz w draftowej wersji tego kroku) - bez tokenu
# notify_rollbar wraca na wczesnym "skip" i sciezka docker-exec-appserver
# nigdy sie nie wykona, a asercja przeszlaby nawet po wyjeciu `|| true`.
# MOCK_FAIL_ON=exec-appserver zwraca z atrapy dockera kod 42 (NIE 1) - dzieki
# temu ta asercja realnie odroznia "notify_rollbar polkniete" (kod zostaje
# na 1, czyli na kodzie z fail("pg_dump",1)) od "notify_rollbar sklobrowalo
# trap" (kod zmienia sie na 42). Zweryfikowane mutacyjnie w raporcie zadania.
: > "$RECORD"
MOCK_YM=2026-08 ROLLBAR_TOKEN_ENV=1 MOCK_FAIL_ON=exec-appserver MOCK_FAIL_ON_STEP=pg_dump run_cycle
assert_eq "1" "$CYCLE_RC" "padly appserver NIE zmienia kodu wyjscia (1, nie sklobrowane)"
assert_contains "$(cat "$CYCLE_LOG")" "FAIL: pg_dump" \
    "log nadal pokazuje prawdziwa przyczyne (pg_dump), nie notyfikacje"

echo
echo "=================================="
green "PASS: $PASS"
if [ "$FAIL" -gt 0 ]; then red "FAIL: $FAIL"; exit 1; fi
green "Wszystkie testy przeszly."

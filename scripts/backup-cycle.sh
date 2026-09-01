#!/bin/sh
#
# Codzienny cykl backupu: pg_dump -> tar media -> lokalna rotacja -> rclone
# copy -> retencja zdalna -> Rollbar notify. Wywolywane przez Ofelie (label na kontenerze
# backup-runner) lub recznie: `make backup-cycle`.
#
# Wymagane zmienne srodowiskowe (z env_file w docker-compose.backup.yml):
#   DJANGO_BPP_DB_HOST, DJANGO_BPP_DB_PORT, DJANGO_BPP_DB_USER,
#   DJANGO_BPP_DB_PASSWORD, DJANGO_BPP_DB_NAME, DJANGO_BPP_HOSTNAME
#
# Opcjonalne:
#   ROLLBAR_ACCESS_TOKEN         - gdy pusty, notify jest no-opem
#   DJANGO_BPP_RCLONE_REMOTE      - target rclone, default "backup_enc:"
#   DJANGO_BPP_BACKUP_KEEP_LAST   - ile kopii lokalnie, default 7
#   DJANGO_BPP_RCLONE_KEEP_MONTHS - retencja ZDALNA: ile katalogow
#                                   miesiecznych zachowac, default 12.
#                                   Dowolna wartosc niebedaca dodatnia liczba
#                                   calkowita (0, puste, smieci) = wylaczone.
#   PARALLEL_JOBS                 - pg_dump -j, default 4
#
# Exit codes:
#   0 - pelny sukces
#   1 - pg_dump lub tar bazy failed; takze nieoczekiwany blad dowolnej
#       innej komendy (trap EXIT -> on_exit "unexpected-error")
#   2 - tar media failed
#   3 - rclone copy failed (lokalne backupy zostaly utworzone)
#
# Retencja zdalna (krok 5) NIGDY nie zmienia exit code'u: sprzatanie nie ma
# prawa zamienic udanego backupu w alert. Nieudany purge to ostrzezenie w logu
# i adnotacja w komunikacie do Rollbara.

# shellcheck shell=sh
# shellcheck disable=SC3040,SC3001,SC3043
#   SC3040 `set -o pipefail`: swiadome odstepstwo od POSIX. Busybox ash i bash
#     je maja, dash nie - stad preflight nizej. Kontrakty o SIGPIPE (patrz
#     lib-rclone.sh) bez pipefail przestaja obowiazywac.
#   SC3001 `exec > >(tee ...)` i SC3043 `local`: resztkowa zaleznosc od
#     bash-compat busyboksa (CONFIG_ASH_BASH_COMPAT), zweryfikowana empirycznie
#     w docker:cli i rclone/rclone. Zamienniki (mkfifo+tee, zmienne globalne)
#     sa gorsze - patrz specs/2026-09-01-backup-orchestrator-design.md §4.
#   UWAGA: ta dyrektywa musi stac PRZED wszelkim kodem (rowniez przed
#   preflightem), inaczej jest lokalna dla jednej linii i nie gasi drugiego
#   wystapienia `set -o pipefail` ponizej - zweryfikowane realnym shellcheckiem.

# Docelowe obrazy (docker:cli, rclone/rclone) nie maja basha, wiec shebang musi byc
# /bin/sh. Ale na Debianie /bin/sh to dash, ktory NIE zna `pipefail` - a na nim stoja
# kontrakty o SIGPIPE w tym repo. Wiec: jesli powloka nie ma pipefail, przeskakujemy
# na basha; jesli basha tez nie ma, giniemy z czytelnym komunikatem zamiast dziwnie.
if ! (set -o pipefail) 2>/dev/null; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    fi
    echo "BLAD: ten skrypt wymaga powloki z pipefail (busybox ash albo bash)." >&2
    echo "      dash jej nie ma - uruchom przez bash albo wewnatrz kontenera." >&2
    exit 1
fi

set -eu
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib-rclone.sh
. "$SCRIPT_DIR/lib-rclone.sh"
# shellcheck source=scripts/lib-container.sh
. "$SCRIPT_DIR/lib-container.sh"

# Shim: lib-rclone.sh wola `rclone` z PATH i jest sourcowana TAKZE przez
# rclone-sync.sh dzialajacy WEWNATRZ kontenera rclone (gdzie nie ma dockera).
# Dlatego biblioteka zostaje czysta, a przekierowanie na docker exec robimy
# tutaj, tylko dla backup-cycle.sh.
#
# NIE wolno tu wolac `fail`: rclone_list_month_dirs wola `rclone lsf ...`
# WEWNATRZ `$( )` (raw="$(rclone lsf ...)"), a `fail` w podpowloce konczy
# TYLKO podpowloke - `exit` nie wraca do rodzica, guard BPP_INTENDED_EXIT nie
# jest ustawiany w wywolujacym procesie i on_exit odpalilby sie DRUGI raz
# (podwojna notyfikacja). Zamiast tego logujemy i zwracamy 3 - obsluge
# zostawiamy guardom wywolujacym (`if ! rclone copy ...; then fail ...; fi`
# na top-levelu w tym skrypcie, `|| return 1` w rclone_list_month_dirs).
#
# KRYTYCZNE: `log` tutaj musi isc na stderr (`>&2`), nie na domyslne stdout.
# Kiedy ten shim jest wolany WEWNATRZ `$( )` (przypadek `rclone lsf` powyzej),
# stdout calej funkcji ladowalby sie do zmiennej wywolujacego (np. `raw`) i
# przepadal bez sladu w logu - w logu zostawalby tylko ogolnikowy komunikat
# wywolujacego ("nie moge wylistowac..."). Top-levelowe
# `exec > >(tee -a "$LOG") 2>&1` i tak kieruje stderr do tego samego pliku
# logu (i na terminal), wiec przekierowanie na `>&2` niczego nie gubi - tylko
# omija przechwycenie przez `$( )`.
rclone() {
    _rc_cid="$(bpp_container rclone)" || {
        log "BLAD: brak dzialajacego kontenera serwisu rclone" >&2
        return 3
    }
    docker exec "$_rc_cid" rclone "$@"
}

# Sciezki kontenerowe. Nadpisywalne WYLACZNIE po to, by scripts/test-rclone.sh
# mogl uruchomic ten skrypt na hoscie z atrapami w PATH - produkcja nie ustawia
# zadnej z nich. Asercja "copy, nie sync" musi odpalac prawdziwy skrypt, bo
# grep po zrodle nie widzi tego, co naprawde poleci do rclone.
BACKUP_DIR="${BPP_BACKUP_DIR:-/backup}"
MEDIA_DIR="${BPP_MEDIA_DIR:-/mediaroot}"
RCLONE_CONFIG="${BPP_RCLONE_CONFIG:-/config/rclone/rclone.conf}"
LOG="${BPP_BACKUP_LOG:-/tmp/backup-cycle.log}"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
START_TS=$(date +%s)
DB_DIR="${BACKUP_DIR}/db-backup-${TIMESTAMP}"
DB_TAR="${BACKUP_DIR}/db-backup-${TIMESTAMP}.tar.gz"
MEDIA_TAR="${BACKUP_DIR}/media-backup-${TIMESTAMP}.tar.gz"
REMOTE="${DJANGO_BPP_RCLONE_REMOTE:-backup_enc:}"
CURRENT_YM="$(date +%Y-%m)"
REMOTE_DIR="$(rclone_month_dir "$REMOTE" "$CURRENT_YM")"
KEEP_LAST="${DJANGO_BPP_BACKUP_KEEP_LAST:-7}"
# `-`, NIE `:-`. Dokumentacja obiecuje, ze pusta wartosc wylacza retencje;
# przy `:-` pusty string jest traktowany jak brak zmiennej i wpadalby na 12,
# czyli operator wpisujacy `DJANGO_BPP_RCLONE_KEEP_MONTHS=` w .env dostawalby
# WLACZONE kasowanie zdalnych kopii. Bez dwukropka pusta wartosc idzie do
# rclone_keep_months_valid i zostaje odrzucona jako "off".
KEEP_MONTHS="${DJANGO_BPP_RCLONE_KEEP_MONTHS-12}"
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"
RETENCJA_MSG="off"

: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

fmt_size() {
    # numfmt nie istnieje ani w docker:cli, ani w rclone/rclone - bez tego kazdy
    # komunikat do Rollbara mialby surowe bajty.
    awk -v b="$1" 'BEGIN {
        split("B KiB MiB GiB TiB", u, " ")
        i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        printf (i == 1 ? "%d%s\n" : "%.1f%s\n"), b, u[i]
    }'
}

notify_rollbar() {
    _level="$1"; _message="$2"
    if [ -z "${ROLLBAR_ACCESS_TOKEN:-}" ]; then
        log "rollbar: skip (ROLLBAR_ACCESS_TOKEN not set)"
        return 0
    fi
    # Orkiestrator nie ma curl ani jq. Python w appserverze escapuje JSON sam
    # i czyta token z wlasnego env_file, wiec sekret nie przechodzi przez -e.
    #
    # KRYTYCZNE: cala funkcja konczy sie sukcesem ZAWSZE. Jest wolana z on_exit,
    # a blad w trapie urywa go przed `exit "$rc"` i klobruje kod wyjscia na 1 -
    # i to dokladnie wtedy, gdy appserver lezy, czyli w scenariuszu, o ktorym
    # raportujemy.
    _app="$(bpp_container appserver)" || {
        log "rollbar: brak dzialajacego appservera - notyfikacja pominieta"
        return 0
    }
    docker exec \
        -e "BPP_RB_LEVEL=$_level" \
        -e "BPP_RB_MSG=$_message" \
        -e "BPP_RB_TS=$TIMESTAMP" \
        -e "BPP_RB_ENV=${DJANGO_BPP_HOSTNAME:-unknown}" \
        "$_app" python -c '
import json, os, urllib.request
payload = {
    "access_token": os.environ["ROLLBAR_ACCESS_TOKEN"],
    "data": {
        "environment": os.environ["BPP_RB_ENV"],
        "level": os.environ["BPP_RB_LEVEL"],
        "body": {"message": {"body": os.environ["BPP_RB_MSG"]}},
        "custom": {"component": "backup-cycle", "timestamp": os.environ["BPP_RB_TS"]},
    },
}
req = urllib.request.Request(
    "https://api.rollbar.com/api/1/item/",
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(req, timeout=10) as r:
    print("rollbar http=%s" % r.status)
' 2>&1 | while IFS= read -r _line; do log "rollbar: $_line"; done || true
    return 0
}

fail() {
    BPP_INTENDED_EXIT=1
    local step="$1" code="$2"
    log "FAIL: $step (exit=$code)"
    local tail_log
    tail_log="$(tail -c 2000 "$LOG" 2>/dev/null || true)"
    notify_rollbar error "Backup FAIL on ${DJANGO_BPP_HOSTNAME:-unknown}: step=$step exit=$code
Log tail:
$tail_log"
    exit "$code"
}

# set -e zamienialby ciche kontynuowanie w cicha smierc BEZ notyfikacji
# Rollbar - dlatego nieoczekiwane bledy (komendy poza jawnym `if !`/`|| fail`)
# kierujemy przez trap EXIT do on_exit(). Kroki krytyczne (pg_dump, tar, rclone)
# maja wlasne guardy z dokladna nazwa kroku i exit code'em - warunki if/||
# nie odpalaja trapu.
#
# Zamiennik `trap ERR` (bashizm). trap EXIT lapie takze abort z `set -e`, w tym
# w funkcjach - czyli pokrywa wiecej niz ERR bez `-E`.
#
# KRYTYCZNE: kazda komenda w tej sciezce ma `|| true`. Blad wewnatrz trapa urywa go
# w polowie, `exit "$rc"` nie zostaje osiagniety i kod wyjscia zostaje sklobrowany
# na 1 - a notyfikacja idzie przez `docker exec appserver`, ktory pada dokladnie
# wtedy, gdy appserver lezy, czyli w scenariuszu, o ktorym raportujemy.
BPP_INTENDED_EXIT=0

# shellcheck disable=SC2317  # wywolywane przez trap
on_exit() {
    rc=$?
    if [ "$BPP_INTENDED_EXIT" = 1 ]; then exit "$rc"; fi
    BPP_INTENDED_EXIT=1
    log "FAIL: unexpected-error (exit=$rc)" || true
    notify_rollbar error "Backup FAIL on ${DJANGO_BPP_HOSTNAME:-unknown}: step=unexpected-error exit=$rc" || true
    exit "$rc"
}
trap on_exit EXIT

# Smierc `tee` z przekierowania logu dawalaby SIGPIPE, rc=141, BEZ trapa EXIT
# i bez notyfikacji. Zignorowanie sygnalu zamienia to w zwykly blad zapisu,
# ktory `set -e` skieruje do on_exit.
trap '' PIPE

# --- 1. pg_dump bazy - WEWNATRZ dbservera (docker exec), nie lokalnie ---
#
# Ten orkiestrator (docker:cli) nie ma pg_dump. Haslo tez celowo NIE
# przechodzi przez `-e`/`docker exec -e`: lokalny dbserver ma wylacznie
# POSTGRES_PASSWORD (PGPASSWORD to sentinel wylacznie w trybie external),
# wiec czytamy je WEWNATRZ kontenera z DJANGO_BPP_DB_PASSWORD. `$DB_DIR`
# rozwiazuje sie w obu kontenerach do tego samego bind-mountu hosta
# (${DJANGO_BPP_HOST_BACKUP_DIR}:/backup w obu compose plikach).
log "pg_dump $DJANGO_BPP_DB_NAME from $DJANGO_BPP_DB_HOST:$DJANGO_BPP_DB_PORT..."
DB_CID="$(bpp_container dbserver)" || fail "dbserver-container-missing" 1
if ! docker exec "$DB_CID" sh -c '
        PGPASSWORD="$DJANGO_BPP_DB_PASSWORD" exec pg_dump -Fd -j "$1" \
            -h "$DJANGO_BPP_DB_HOST" -p "$DJANGO_BPP_DB_PORT" \
            -U "$DJANGO_BPP_DB_USER" "$DJANGO_BPP_DB_NAME" -f "$2"
    ' _ "$PARALLEL_JOBS" "$DB_DIR"; then
    fail "pg_dump" 1
fi
log "tar db dump..."
tar czf "$DB_TAR" -C "$BACKUP_DIR" "db-backup-${TIMESTAMP}" || fail "db-tar" 1
rm -rf "$DB_DIR"
DB_SIZE=$(stat -c%s "$DB_TAR" 2>/dev/null || stat -f%z "$DB_TAR" 2>/dev/null || echo 0)
log "db-backup ok: $DB_TAR ($(fmt_size "$DB_SIZE"))"

# --- 2. tar media volume ---
log "tar media from $MEDIA_DIR..."
if ! tar czf "$MEDIA_TAR" -C "$MEDIA_DIR" .; then
    fail "media-tar" 2
fi
MEDIA_SIZE=$(stat -c%s "$MEDIA_TAR" 2>/dev/null || stat -f%z "$MEDIA_TAR" 2>/dev/null || echo 0)
log "media-backup ok: $MEDIA_TAR ($(fmt_size "$MEDIA_SIZE"))"

# --- 3. Lokalna rotacja - zachowaj N najnowszych kopii kazdego typu ---
prune_type() {
    local prefix="$1"
    # Nazwy plikow maja format ${prefix}-YYYYMMDD-HHMMSS.tar.gz, wiec
    # sort leksykograficzny = sort chronologiczny. find+sort zamiast ls -1t
    # bo shellcheck (SC2012) preferuje find, a busybox find w alpine nie
    # ma -printf.
    find "$BACKUP_DIR" -maxdepth 1 -type f -name "${prefix}-*.tar.gz" 2>/dev/null \
        | sort -r \
        | tail -n +$((KEEP_LAST + 1)) \
        | while IFS= read -r f; do
            [ -n "$f" ] || continue
            log "prune: removing $f"
            # Nieudane prune to ostrzezenie, nie powod by przerwac backup
            # przed wysylka na zdalny.
            rm -f "$f" || log "WARN: nie udalo sie usunac $f"
        done
}
log "local rotation: keep last $KEEP_LAST per type"
prune_type db-backup
prune_type media-backup

# --- 4. rclone copy do katalogu MIESIECZNEGO ---
#
# CRITICAL: `copy`, nigdy `sync`. Pelne uzasadnienie w scripts/lib-rclone.sh;
# w skrocie: cel jest teraz STALY przez caly miesiac, wiec `sync` skasowalby
# z niego wszystko poza biezacym oknem 7 lokalnych kopii - zjadlby archiwum
# i zaraportowal sukces. Broni tego asercja mutacyjna w scripts/test-rclone.sh.
#
# Wysylamy caly $BACKUP_DIR, nie tylko dwa dzisiejsze pliki: `copy` i tak
# pominie to, co juz jest na zdalnym (nazwy niosa timestamp), a przy okazji
# dzien, w ktorym rclone padl, uzupelnia sie sam nastepnej nocy.
log "rclone copy $BACKUP_DIR/ -> $REMOTE_DIR"
if [ ! -f "$RCLONE_CONFIG" ]; then
    fail "rclone-config-missing" 3
fi
if ! rclone copy "$BACKUP_DIR/" "$REMOTE_DIR" --config "$RCLONE_CONFIG"; then
    fail "rclone-copy" 3
fi
log "rclone copy ok"

# --- 5. Retencja zdalna (domyslnie WLACZONA: 12 miesiecy) ---
#
# Uwaga na kontrakt backwards-compat: to JEST zmiana zachowania dostarczana
# przez `git pull` - swiadoma decyzja wlasciciela repo. Stad ponizsze
# bezpieczniki, kazdy celowy:
#   * ruszamy WYLACZNIE katalogi pasujace dokladnie do YYYY-MM (filtr w
#     rclone_list_month_dirs), wiec cokolwiek innego w remote jest nietykalne;
#   * biezacy miesiac nie zostanie usuniety NIGDY;
#   * maksymalnie JEDEN katalog miesieczny na cykl - patrz nizej;
#   * kazdy blad tego kroku to ostrzezenie, nie `fail`.
prune_remote_months() {
    if ! rclone_keep_months_valid "$KEEP_MONTHS"; then
        log "retencja zdalna: off (DJANGO_BPP_RCLONE_KEEP_MONTHS='$KEEP_MONTHS')"
        return 0
    fi
    log "retencja zdalna: keep_months=$KEEP_MONTHS, biezacy $CURRENT_YM"

    local base months to_purge oldest
    base="$(rclone_base "$REMOTE")"
    if ! months="$(rclone_list_month_dirs "$base" --config "$RCLONE_CONFIG")"; then
        log "UWAGA: nie moge wylistowac $base - pomijam retencje w tym cyklu"
        RETENCJA_MSG="blad listowania"
        return 0
    fi
    if [ -z "$months" ]; then
        log "retencja zdalna: brak katalogow YYYY-MM - nic do zrobienia"
        RETENCJA_MSG="brak katalogow"
        return 0
    fi

    to_purge="$(printf '%s\n' "$months" | rclone_months_to_purge "$CURRENT_YM" "$KEEP_MONTHS")"
    if [ -z "$to_purge" ]; then
        log "retencja zdalna: nic starszego niz $KEEP_MONTHS mies. - nic do usuniecia"
        RETENCJA_MSG="nic do usuniecia"
        return 0
    fi

    # Bezpiecznik: JEDEN katalog na cykl, najstarszy. W normalnej pracy i tak
    # co miesiac wypada dokladnie jeden, wiec roznicy nie widac - ale
    # instalacja z wieloletnia historia nie traci kilkudziesieciu miesiecy
    # jednej nocy, tylko po jednym na dobe, kazdy z osobnym wpisem w logu i w
    # komunikacie Rollbara. To daje doba na reakcje zamiast pojedynczego
    # nieodwracalnego zdarzenia.
    #
    # NIE uzywac tu `| head -1`: pod `set -o pipefail` producent dostaje
    # SIGPIPE, pipeline zwraca blad, trap EXIT wywraca caly backup. Ta sama
    # pulapka co z `grep -q` w probce wsparcia (patrz CLAUDE.md).
    # `sed -n 1p`, a nie `head -1`: head zamyka wejscie po pierwszej linii, producent
    # dostaje SIGPIPE i pod pipefail wywraca caly backup.
    oldest="$(printf '%s\n' "$to_purge" | sed -n '1p')"
    # Nieosiagalne przy obecnych filtrach, ale promien razenia to CALY zdalny:
    # `rclone purge backup_enc:` skasowaloby wszystkie backupy. Jedna linia za
    # odciecie tej mozliwosci na zawsze jest tania.
    if [ -z "$oldest" ]; then
        log "UWAGA: pusta nazwa katalogu do usuniecia - pomijam retencje"
        RETENCJA_MSG="pusta nazwa katalogu"
        return 0
    fi
    local pozostale
    pozostale="$(printf '%s\n' "$to_purge" | grep -c . || true)"

    log "retencja zdalna: usuwam $base$oldest (do usuniecia lacznie: $pozostale, po jednym na cykl)"
    if rclone purge "$base$oldest" --config "$RCLONE_CONFIG"; then
        log "retencja zdalna: usunieto $oldest"
        RETENCJA_MSG="usunieto $oldest (zostalo do usuniecia: $((pozostale - 1)))"
    else
        log "UWAGA: nie udalo sie usunac $base$oldest - zostaje, sprobuje w kolejnym cyklu"
        RETENCJA_MSG="BLAD usuwania $oldest"
    fi
    return 0
}
prune_remote_months

# --- 6. Sukces - notify ---
END_TS=$(date +%s)
DURATION=$(( END_TS - START_TS ))
MSG="Backup OK on ${DJANGO_BPP_HOSTNAME:-unknown}: db=$(fmt_size "$DB_SIZE") media=$(fmt_size "$MEDIA_SIZE") remote=$REMOTE_DIR duration=${DURATION}s keep_last=$KEEP_LAST retencja_zdalna=$RETENCJA_MSG"
log "$MSG"
notify_rollbar info "$MSG"

BPP_INTENDED_EXIT=1
exit 0

#!/usr/bin/env bash
#
# Wspolne funkcje rclone dla scripts/backup-cycle.sh i scripts/rclone-sync.sh.
# Biblioteka do sourcowania — nie uruchamiac bezposrednio.
#
# Uklad zdalnego: JEDEN katalog na miesiac, REMOTE:YYYY-MM/, plikami sa
# db-backup-*.tar.gz i media-backup-*.tar.gz z timestampem w nazwie.
#
# CRITICAL: do katalogu miesiecznego wolno wysylac WYLACZNIE `rclone copy`.
# Historycznie bylo `rclone sync /backup/ REMOTE:YYYY-MM/DD/` — do swiezego,
# pustego katalogu dziennego, wiec kazdego dnia leciala cala lokalna retencja
# (7 kopii) i kazdy plik ladowal na zdalnym w 7 egzemplarzach. Po scaleniu do
# katalogu miesiecznego `sync` skasowalby z niego wszystko poza biezacym oknem
# 7 lokalnych kopii — czyli zjadlby archiwum i zaraportowal sukces. Broni tego
# asercja mutacyjna w scripts/test-rclone.sh.
#
# Efekt uboczny, ktory jest tu zaleta: skoro cel jest STALY (a nie pusty
# katalog na kazdy dzien), `copy` wysyla tylko brakujace pliki — 2 dziennie
# zamiast 14 — a jednoczesnie co dzien oferuje cale lokalne okno, wiec dzien,
# w ktorym rclone padl, naprawia sie sam nastepnej nocy.

# rclone_base <remote>
#   Normalizuje target tak, zeby dalo sie do niego dokleic sciezke:
#     "backup_enc:"     -> "backup_enc:"
#     "backup_enc:kat"  -> "backup_enc:kat/"
rclone_base() {
    local base="${1%/}"
    case "$base" in
        *:) printf '%s' "$base" ;;
        *)  printf '%s/' "$base" ;;
    esac
}

# rclone_month_dir <remote> <YYYY-MM>
rclone_month_dir() {
    printf '%s%s/' "$(rclone_base "$1")" "$2"
}

# rclone_keep_months_valid <wartosc>
#   Prawda tylko dla dodatniej liczby calkowitej. Wszystko inne (puste, 0,
#   ujemne, "off", smieci) znaczy "retencja wylaczona" — nigdy blad i nigdy
#   kasowanie na chybil trafil.
rclone_keep_months_valid() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) [ "$1" -gt 0 ] ;;
    esac
}

# _ym_index <YYYY-MM> -> liczba miesiecy od poczatku ery
#   Swiadomie liczymy arytmetycznie zamiast `date -d "-N months"`: busybox
#   (wariant alpine backup-runnera) ma okrojone `date -d` i przy odejmowaniu
#   miesiecy zwraca smieci albo blad. To jest dokladnie ten rodzaj roznicy,
#   ktory nie wyjdzie u nas, tylko na cudzej instalacji.
_ym_index() {
    local y="${1%%-*}" m="${1##*-}"
    printf '%s' "$(( 10#$y * 12 + 10#$m - 1 ))"
}

# rclone_months_to_purge <biezacy YYYY-MM> <keep_months>
#   Czyta liste katalogow YYYY-MM ze stdin, wypisuje te do usuniecia,
#   najstarsze pierwsze. Zostawia dokladnie keep_months najnowszych, liczac
#   z biezacym. Biezacy miesiac nie wyjdzie stad NIGDY.
rclone_months_to_purge() {
    local cur_ym="$1" keep="$2" cur_idx threshold ym
    cur_idx="$(_ym_index "$cur_ym")"
    threshold=$(( cur_idx - keep ))
    while IFS= read -r ym; do
        # Wzorzec SCISLY, nie "same cyfry i myslniki": goly "-" przechodzil
        # przez ten luzniejszy filtr i wywracal _ym_index na `10#:  bledna
        # stala calkowita`, a trap ERR w backup-cycle zamienialby to w awarie
        # calego backupu. Druga warstwa obok wzorca w rclone_list_month_dirs -
        # kazda ma wlasny test, zeby zadna nie zgnila w martwy kod.
        case "$ym" in
            [0-9][0-9][0-9][0-9]-[0-9][0-9]) ;;
            *) continue ;;
        esac
        # Uwaga: `[ ] && continue` jako samodzielna instrukcja wywala
        # skrypt pod `set -e` (backup-cycle ma set -Eeuo pipefail + trap ERR).
        if [ "$ym" = "$cur_ym" ]; then continue; fi
        if [ "$(_ym_index "$ym")" -le "$threshold" ]; then
            printf '%s\n' "$ym"
        fi
    done | sort
}

# rclone_list_month_dirs <base> [dodatkowe argumenty rclone...]
#   Wypisuje katalogi zdalne pasujace DOKLADNIE do YYYY-MM. Cokolwiek innego
#   w remote (katalogi operatora, smieci, stare katalogi dzienne zagniezdzone
#   w miesiacu) jest tym samym niewidoczne dla retencji.
rclone_list_month_dirs() {
    local base="$1"; shift
    local raw
    # Blad rclone i "zero pasujacych katalogow" to dwie ROZNE rzeczy, a pod
    # `set -o pipefail` grep bez trafienia zwraca 1 i wygladalby jak awaria
    # zdalnego. Stad exit rclone sprawdzany osobno, a filtr z `|| true`.
    raw="$(rclone lsf "$base" --dirs-only "$@")" || return 1
    printf '%s\n' "$raw" \
        | sed 's:/$::' \
        | { grep -E '^[0-9]{4}-[0-9]{2}$' || true; } \
        | sort
}

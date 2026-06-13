#!/usr/bin/env bash
#
# KROK 2/3 migracji "pozbadz sie kolacji libc pl_PL". Patrz
# lib-pg-collation-migrate.sh.
#
# Bierze zrzut plain SQL (db-backup-<TS>.sql.gz z kroku 1) i WYCINA z niego
# kolacje pl_PL czystym sed-em:
#   * usuwa  CREATE/ALTER/COMMENT ... COLLATION ... "pl_PL"
#   * usuwa klauzule  COLLATE [public.]"pl_PL"  (z 5 widokow bpp_kronika_*)
# Wynik: <nazwa>-nocollation.sql.gz w katalogu backupow — wejscie kroku 3.
#
# To czysta transformacja tekstu na hoscie: gunzip | sed | gzip. Zaden
# pg_restore, zaden obraz postgres, zaden tar — bo krok 1 daje juz plain
# SQL (patrz lib: kolacja siedzi w TEKSCIE definicji widokow, a tego nie
# da sie wyciac z binarnego -Fd inaczej niz konwertujac go wpierw na SQL).
#
# Uzycie:
#     bash scripts/pg-collation-migrate-2-fix.sh <db-backup-YYYYMMDD-HHMMSS.sql.gz>

set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib-pg-collation-migrate.sh
. "$REPO_DIR/scripts/lib-pg-collation-migrate.sh"

if [ $# -lt 1 ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    sed -n '2,21p' "$0"; exit 0
fi

SRC_GZ="$1"
[ -f "$SRC_GZ" ] || { echo "BLAD: nie ma pliku: $SRC_GZ" >&2; exit 1; }
SRC_GZ="$(cd "$(dirname "$SRC_GZ")" && pwd)/$(basename "$SRC_GZ")"

# Lapiemy stary, binarny format z poprzedniej wersji skryptu (-Fd tarball).
case "$SRC_GZ" in
    *.tar.gz|*.tgz)
        echo "BLAD: to wyglada na tarball (-Fd). Krok 1 produkuje teraz plain" >&2
        echo "      SQL (db-backup-<TS>.sql.gz) — podaj plik .sql.gz." >&2
        exit 1 ;;
esac

BASE="$(basename "$SRC_GZ")"; BASE="${BASE%.sql.gz}"; BASE="${BASE%.gz}"
OUT_DIR="$(dirname "$SRC_GZ")"
OUT_SQL_GZ="${OUT_DIR}/${BASE}-nocollation.sql.gz"

echo ">> Sprawdzam integralnosc wejsciowego gzipa..." >&2
gzip -t "$SRC_GZ"

echo ">> gunzip | sed (wycinam kolacje pl_PL) | gzip -> ${OUT_SQL_GZ##*/}" >&2
gunzip -c "$SRC_GZ" \
    | sed -E \
        -e '/^CREATE COLLATION (public\.)?"?pl_PL"?/d' \
        -e '/^ALTER COLLATION (public\.)?"?pl_PL"?/d' \
        -e '/^COMMENT ON COLLATION (public\.)?"?pl_PL"?/d' \
        -e 's/ COLLATE (public\.)?"pl_PL"//g' \
    | gzip > "$OUT_SQL_GZ"

echo ">> Weryfikacja: zadnych pozostalosci kolacji pl_PL w wyniku..." >&2
if zgrep -nE 'COLLATION[[:space:]]+("?public"?\.)?"?pl_PL|COLLATE[[:space:]]+(public\.)?"pl_PL"' \
        "$OUT_SQL_GZ" >/dev/null 2>&1; then
    echo "BLAD: w wyniku nadal sa odwolania do kolacji pl_PL:" >&2
    zgrep -nE 'COLLATION[[:space:]]+("?public"?\.)?"?pl_PL|COLLATE[[:space:]]+(public\.)?"pl_PL"' \
        "$OUT_SQL_GZ" | head >&2
    rm -f "$OUT_SQL_GZ"
    exit 1
fi

# Sanity: zrzut sprzed migracji bpp 0442 ma jeszcze plpython3u, ktorego stock
# postgres nie ma -> load padnie. Ostrzegamy (nie blokujemy).
if zgrep -qiE 'plpython3u|LANGUAGE plpython' "$OUT_SQL_GZ"; then
    echo "!! OSTRZEZENIE: zrzut zawiera plpython3u (sprzed migracji bpp 0442)." >&2
    echo "   Stock postgres go nie ma -> krok 3 padnie. Zrob NOWY zrzut po" >&2
    echo "   wdrozeniu wersji aplikacji z migracja 0442 (DROP EXTENSION plpython3u)." >&2
fi

echo ">> Gotowe. Poprawiony zrzut:" >&2
printf '%s\n' "$OUT_SQL_GZ"

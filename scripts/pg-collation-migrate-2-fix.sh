#!/usr/bin/env bash
#
# KROK 2/3 migracji "pozbadz sie kolacji libc pl_PL". Patrz
# lib-pg-collation-migrate.sh.
#
# Bierze tarball ze zrzutem katalogowym (-Fd) z kroku 1, konwertuje go na
# czysty SQL i WYCINA kolacje pl_PL:
#   * usuwa  CREATE/ALTER/COMMENT ... COLLATION ... "pl_PL"
#   * usuwa klauzule  COLLATE [public.]"pl_PL"  (z 5 widokow bpp_kronika_*)
# Wynik: <nazwa>-nocollation.sql.gz w katalogu backupow — wejscie kroku 3.
#
# DLACZEGO przez czysty SQL, a nie pg_restore -L: format katalogowy trzyma
# DDL w binarnym toc.dat. `pg_restore -L` umie pominac OBIEKT kolacji, ale
# NIE umie wyciac klauzul COLLATE wstrzyknietych w definicje widokow. Wiec
# konwertujemy do SQL (pg_restore -f -), sed-ujemy, ladujemy psql-em (krok 3).
# Koszt: load jest jednowatkowy (psql -f) zamiast rownoleglego pg_restore -j.
#
# Uzycie:
#     bash scripts/pg-collation-migrate-2-fix.sh <db-backup-YYYYMMDD-HHMMSS.tar.gz>
#
# pg_restore bierzemy z obrazu $PG_TARGET_IMAGE (domyslnie wersja docelowa,
# nowszy pg_restore czyta starsze archiwa).

set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib-pg-collation-migrate.sh
. "$REPO_DIR/scripts/lib-pg-collation-migrate.sh"

if [ $# -lt 1 ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    sed -n '2,20p' "$0"; exit 0
fi

SRC_TAR="$1"
[ -f "$SRC_TAR" ] || { echo "BLAD: nie ma pliku: $SRC_TAR" >&2; exit 1; }
SRC_TAR="$(cd "$(dirname "$SRC_TAR")" && pwd)/$(basename "$SRC_TAR")"

BASE="$(basename "$SRC_TAR")"; BASE="${BASE%.tar.gz}"; BASE="${BASE%.tgz}"
OUT_DIR="$(dirname "$SRC_TAR")"
OUT_SQL_GZ="${OUT_DIR}/${BASE}-nocollation.sql.gz"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo ">> Rozpakowuje $BASE ..." >&2
tar xzf "$SRC_TAR" -C "$TMP"
DUMP_DIR="$(find "$TMP" -maxdepth 1 -mindepth 1 -type d | head -1)"
if [ -z "$DUMP_DIR" ] || [ ! -f "$DUMP_DIR/toc.dat" ]; then
    echo "BLAD: w tarballu nie ma katalogowego zrzutu pg_dump (-Fd, brak toc.dat)." >&2
    exit 1
fi

echo ">> pg_restore -f - (obraz: $PG_TARGET_IMAGE) | sed (wycinam kolacje pl_PL) | gzip" >&2
# pg_restore -f - nie potrzebuje uruchomionego serwera: zamienia archiwum na
# SQL na stdout. Sed na hoscie wycina kolacje, gzip zapisuje wynik.
set -o pipefail
docker run --rm -v "$TMP:/dump:ro" "$PG_TARGET_IMAGE" \
        pg_restore -f - "/dump/$(basename "$DUMP_DIR")" \
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

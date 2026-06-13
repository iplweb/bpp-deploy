#!/usr/bin/env bash
#
# KROK 2/3 migracji "pozbadz sie kolacji libc pl_PL". Patrz
# lib-pg-collation-migrate.sh.
#
# Bierze zrzut plain SQL (db-backup-<TS>.sql z kroku 1) i WYCINA z niego
# kolacje pl_PL czystym sed-em:
#   * usuwa  CREATE/ALTER/COMMENT ... COLLATION ... pl_PL
#   * usuwa naglowkowy komentarz pg_dump "-- Name: pl_PL...; Type: COLLATION"
#   * usuwa klauzule  COLLATE [public.]pl_PL  (z widokow bpp_kronika_*)
# Wynik: <nazwa>-nocollation.sql w katalogu backupow — wejscie kroku 3.
#
# WAZNE — nazwa kolacji jest case-insensitive i moze byc w cudzyslowie albo
# bez. Realne bazy maja `public."pl_PL.utf8"` (cytowana, z kropka i .utf8 w
# srodku), albo `public.pl_pl` (male litery), albo `public."pl_PL"`
# (0001_collation). Wzorzec: (public.)? ( "pl_PL<sufiks>" | goly pl_pl ),
# dowolny case przez klasy [pP][lL] — lapie KAZDY wariant.
#
# UWAGA: ownerow i przywilejow (OWNER TO / GRANT / REVOKE) ten krok NIE
# rusza. Zrzut z kroku 1 robi `pg_dump --no-owner --no-privileges`, wiec rol
# nie ma juz w tekscie (per-bazowy pg_dump i tak nie zrzuca rol — sa cluster-
# level — przez co load do swiezego klastra padalby na "role ... does not
# exist"). Jesli masz STARY zrzut sprzed tej flagi: zrob nowy dump kroku 1.
#
# To czysta transformacja tekstu na hoscie: sed in -> out, bez gzipa, bez
# pg_restore, bez obrazu postgres, bez tar (krok 1 daje juz plain SQL).
#
# Uzycie:
#     bash scripts/pg-collation-migrate-2-fix.sh <db-backup-YYYYMMDD-HHMMSS.sql>

set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib-pg-collation-migrate.sh
. "$REPO_DIR/scripts/lib-pg-collation-migrate.sh"

if [ $# -lt 1 ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    sed -n '2,29p' "$0"; exit 0
fi

SRC_SQL="$1"
[ -f "$SRC_SQL" ] || { echo "BLAD: nie ma pliku: $SRC_SQL" >&2; exit 1; }
SRC_SQL="$(cd "$(dirname "$SRC_SQL")" && pwd)/$(basename "$SRC_SQL")"

# Lapiemy stare formaty z poprzednich wersji (-Fd tarball / gzipowany SQL).
case "$SRC_SQL" in
    *.tar.gz|*.tgz|*.gz)
        echo "BLAD: krok 1 produkuje teraz NIESKOMPRESOWANY plain SQL" >&2
        echo "      (db-backup-<TS>.sql) — podaj plik .sql, nie .gz/.tar.gz." >&2
        exit 1 ;;
esac

BASE="$(basename "$SRC_SQL")"; BASE="${BASE%.sql}"
OUT_DIR="$(dirname "$SRC_SQL")"
OUT_SQL="${OUT_DIR}/${BASE}-nocollation.sql"

# Nazwa kolacji: opcjonalne `public.`, potem ALBO nazwa w cudzyslowie z
# dowolnym sufiksem — realnie `"pl_PL.utf8"` (kropka + .utf8 W SRODKU
# cudzyslowu, prod 2026-06-13), ale tez `"pl_PL.UTF-8"` / `"pl_PL"` — ALBO
# goly identyfikator `pl_pl` (bez kropki, bo niecytowany ident nie ma kropek).
# Dowolny case przez klasy [pP][lL]. Cudzyslowy z $NAME trafiaja do seda
# doslownie — to KLUCZOWE dla nazw z kropka, ktore MUSZA byc cytowane.
QNAME='"[pP][lL]_[pP][lL][^"]*"'
BNAME='[pP][lL]_[pP][lL]'
NAME="(public\\.)?(${QNAME}|${BNAME})"

echo ">> sed (wycinam kolacje pl_PL: \"pl_PL.utf8\"/pl_pl/..., dowolny case) -> ${OUT_SQL##*/}" >&2
sed -E \
    -e "/^CREATE COLLATION ${NAME} /d" \
    -e "/^ALTER COLLATION ${NAME} /d" \
    -e "/^COMMENT ON COLLATION ${NAME} /d" \
    -e "/^-- Name: [pP][lL]_[pP][lL].*Type: COLLATION/d" \
    -e "s/ COLLATE ${NAME}//g" \
    "$SRC_SQL" > "$OUT_SQL"

# Weryfikacja: zadnych aktywnych odwolan do kolacji pl_PL (dowolny case).
# Nie zlapie stringa '0443_drop_pl_PL_collation' z django_migrations (brak
# ^CREATE COLLATION / ` COLLATE ` przed nazwa).
echo ">> Weryfikacja: brak pozostalosci kolacji pl_PL w wyniku..." >&2
RESIDUAL_RE='^(CREATE|ALTER|COMMENT ON) COLLATION (public\.)?"?[pP][lL]_[pP][lL]| COLLATE (public\.)?"?[pP][lL]_[pP][lL]'
if grep -nE "$RESIDUAL_RE" "$OUT_SQL" >/dev/null 2>&1; then
    echo "BLAD: w wyniku nadal sa odwolania do kolacji pl_PL:" >&2
    grep -nE "$RESIDUAL_RE" "$OUT_SQL" | head >&2
    rm -f "$OUT_SQL"
    exit 1
fi

# Sanity: zrzut sprzed migracji bpp 0442 ma jeszcze plpython3u, ktorego stock
# postgres nie ma -> load padnie. Ostrzegamy (nie blokujemy).
if grep -qiE 'plpython3u|LANGUAGE plpython' "$OUT_SQL"; then
    echo "!! OSTRZEZENIE: zrzut zawiera plpython3u (sprzed migracji bpp 0442)." >&2
    echo "   Stock postgres go nie ma -> krok 3 padnie. Zrob NOWY zrzut po" >&2
    echo "   wdrozeniu wersji aplikacji z migracja 0442 (DROP EXTENSION plpython3u)." >&2
fi

echo ">> Gotowe. Poprawiony zrzut:" >&2
printf '%s\n' "$OUT_SQL"

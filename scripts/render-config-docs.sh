#!/usr/bin/env bash
# Wstawia tabele zmiennych operatora (z scripts/config-registry.tsv) do
# docs/konfiguracja/zmienne.md, miedzy znaczniki rejestr:start / rejestr:end.
#   render-config-docs.sh          przepisuje plik (make docs-config-table)
#   render-config-docs.sh --check  exit 1, gdy tabela w docs jest nieaktualna
#                                  (test_configure_registry w tests/test_makefile.sh)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOC="${BPP_CONFIG_DOC:-$REPO_DIR/docs/konfiguracja/zmienne.md}"
START='<!-- rejestr:start (generowane: make docs-config-table, nie edytuj recznie) -->'
END='<!-- rejestr:end -->'

for z in "$START" "$END"; do
	if [ "$(grep -cxF -- "$z" "$DOC")" != 1 ]; then
		echo "BLAD: w $DOC musi byc dokladnie jeden znacznik: $z" >&2
		exit 1
	fi
done

TABELA="$(bash "$REPO_DIR/scripts/configure.sh" --docs)"
NOWY="$(START="$START" END="$END" TABELA="$TABELA" awk '
	$0 == ENVIRON["START"] { print; print ""; print ENVIRON["TABELA"]; print ""; pomin = 1; next }
	$0 == ENVIRON["END"] { pomin = 0 }
	!pomin { print }
' "$DOC")"

if [ "${1:-}" = --check ]; then
	if [ "$NOWY" != "$(cat "$DOC")" ]; then
		echo "Tabela zmiennych w $DOC jest nieaktualna wzgledem scripts/config-registry.tsv — uruchom: make docs-config-table" >&2
		exit 1
	fi
	exit 0
fi
printf '%s\n' "$NOWY" > "$DOC"
echo "Zaktualizowano tabele w $DOC"

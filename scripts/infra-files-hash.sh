#!/usr/bin/env bash
#
# infra-files-hash.sh — suma kontrolna plikow startowych dbservera i pgbouncera,
# zapisywana do $BPP_CONFIGS_DIR/.env jako BPP_INFRA_FILES_HASH.
#
# Po co: `make up` NIE odtwarza dbserver/redis/pgbouncer na sile
# (bez --force-recreate) — Compose robi to sam, gdy zmieni sie obraz albo
# konfiguracja uslugi. Nie widzi natomiast zmian TRESCI plikow bind-mountowanych,
# a oba serwisy czytaja swoje skrypty tylko przy starcie:
#   dbserver:  dbserver/docker-entrypoint-autotune.sh, dbserver/autotune.sh
#   pgbouncer: pgbouncer/entrypoint.sh
# Suma trafia do labela tych uslug (docker-compose.database.yml,
# docker-compose.pgbouncer.yml), wiec zmiana pliku po `git pull` zmienia
# konfiguracje uslugi i Compose odtwarza kontener przy najblizszym `make up`.
#
# Do .env, a NIE tylko jako zmienna eksportowana z Makefile: Compose czyta ten
# plik takze przy golym `docker compose up` (bez make). Gdyby wartosc znala
# tylko recepta make, kazde reczne `docker compose up` widzialoby pusty label
# i restartowalo baze, a nastepny `make up` — znowu.
#
# Dodajesz nowy bind-mount czytany przy starcie przez dbserver/pgbouncer?
# Dopisz plik do PLIKI ponizej.
#
# Fail-open: zaden blad nie zatrzymuje `make up` (exit 0).
#
#   bash scripts/infra-files-hash.sh            # wypisz sume
#   bash scripts/infra-files-hash.sh --zapisz   # zapisz do .env, gdy inna

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${BPP_CONFIGS_DIR:-}/.env"
VAR=BPP_INFRA_FILES_HASH

PLIKI=(
	dbserver/docker-entrypoint-autotune.sh
	dbserver/autotune.sh
	pgbouncer/entrypoint.sh
)

# cksum: POSIX, jest tez w Git Bash/MSYS2; wynik to same cyfry, wiec bez
# znakow, ktorych nie lubi .env (validate-env-quotes) ani Makefile (-include).
# Kazdy plik osobno z nazwa, potem suma calosci — przeniesienie tresci miedzy
# plikami tez zmienia wynik.
suma() {
	local f out
	out=""
	for f in "${PLIKI[@]}"; do
		[ -f "$REPO_DIR/$f" ] || {
			echo "infra-files-hash: brak $f" >&2
			return 1
		}
		out="$out$f $(cksum <"$REPO_DIR/$f")
"
	done
	printf '%s' "$out" | cksum | cut -d' ' -f1
}

if [ "${1:-}" != "--zapisz" ]; then
	suma
	exit $?
fi

if [ -z "${BPP_CONFIGS_DIR:-}" ] || [ ! -f "$ENV_FILE" ]; then
	echo "  suma plikow startowych: pominieta (brak $ENV_FILE)" >&2
	exit 0
fi

nowa="$(suma)" || {
	echo "  suma plikow startowych: pominieta (blad liczenia)" >&2
	exit 0
}
stara="$(grep -E "^$VAR=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r')"
[ "$stara" = "$nowa" ] && exit 0

# Zapis przez `cat >` (nie mv): zostaje tryb i wlasciciel .env.
tmp="$ENV_FILE.infrahash.$$"
if grep -qE "^$VAR=" "$ENV_FILE"; then
	awk -v k="$VAR" -v v="$nowa" 'BEGIN { FS = OFS = "=" } $1 == k { print k "=" v; next } { print }' \
		"$ENV_FILE" >"$tmp" && cat "$tmp" >"$ENV_FILE"
	rm -f "$tmp"
else
	# Trailing newline: recznie edytowany .env bez konca linii skleilby wpis.
	if [ -s "$ENV_FILE" ] && [ -n "$(tail -c1 "$ENV_FILE")" ]; then
		printf '\n' >>"$ENV_FILE"
	fi
	{
		echo ""
		echo "# === Suma plikow startowych dbserver/pgbouncer (make up liczy sam — NIE EDYTUJ) ==="
		echo "$VAR=$nowa"
	} >>"$ENV_FILE"
fi
if [ -n "$stara" ]; then
	echo "  pliki startowe dbserver/pgbouncer zmienione — zostana odtworzone przy tym 'up'"
fi
exit 0

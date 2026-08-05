#!/usr/bin/env bash
#
# site-down-warning.sh — cienka warstwa nad komendami django-countdown (>= 0.3.0)
# dzialajacymi w kontenerze appservera.
#
# W TYM REPO NIE MA ZADNEJ LOGIKI COUNTDOWNU — kazde polecenie to jedno
# wywolanie `manage.py`. Model `SiteCountdown` nalezy do django-countdown
# i tylko tamten pakiet ma prawo do niego pisac.
#
# Uzycie:
#   site-down-warning.sh supported     -> exit 0, gdy obraz zna komendy countdownu
#   site-down-warning.sh enable        -> wywies baner (start_countdown)
#   site-down-warning.sh disable       -> zdejmij blokade i baner (stop_countdown)
#   site-down-warning.sh adjust <±N>   -> przesun DEKLAROWANY POWROT o N minut
#   site-down-warning.sh heartbeat     -> podtrzymaj podloge (extend --at-least)
#   site-down-warning.sh status        -> podglad (show_countdown); JSON=1 -> --json
#
# Zmienne (argument make -> $BPP_CONFIGS_DIR/.env -> stala tutaj):
#   MINUTES  / SITE_DOWN_WARNING_MINUTES   (5)  — dlugosc fazy banera
#   SERVICE  / SITE_DOWN_SERVICE_MINUTES   (10) — deklarowana dlugosc przerwy
#   MESSAGE  / SITE_DOWN_WARNING_MESSAGE        — naglowek banera i strony przerwy
#   LONG_DESCRIPTION / SITE_DOWN_LONG_DESCRIPTION — dluzszy tekst na stronie przerwy
#   SITE_IDS / SITE_DOWN_SITE_IDS          ()   — lista id witryn (multi-host)
#   SITE_DOWN_HEARTBEAT_FLOOR_MINUTES      (5)  — podloga heartbeatu
#
# UWAGA — domyslne cele komend upstreamu NIE sa jednakowe:
#   stop/show           dzialaja na WSZYSTKICH witrynach,
#   start/extend/shorten na BIEZACEJ (start nie ma nawet --all).
# Dlatego przy multi-hoscie (DJANGO_BPP_HOSTNAMES = wiele wierszy Site) trzeba
# podac SITE_IDS, inaczej zablokujemy jedna domene, a reszte zostawimy otwarta.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOCKER="${DOCKER:-docker}"
APPSERVER_SERVICE="${APPSERVER_SERVICE:-appserver}"

MINUTES="${MINUTES:-${SITE_DOWN_WARNING_MINUTES:-5}}"
SERVICE="${SERVICE:-${SITE_DOWN_SERVICE_MINUTES:-10}}"
MESSAGE="${MESSAGE:-${SITE_DOWN_WARNING_MESSAGE:-Planowana przerwa techniczna — aktualizacja systemu}}"
LONG_DESCRIPTION="${LONG_DESCRIPTION:-${SITE_DOWN_LONG_DESCRIPTION:-}}"
SITE_IDS="${SITE_IDS:-${SITE_DOWN_SITE_IDS:-}}"
FLOOR_MINUTES="${SITE_DOWN_HEARTBEAT_FLOOR_MINUTES:-5}"

cd "$REPO_DIR" || {
	echo "BLAD: nie moge wejsc do $REPO_DIR." >&2
	exit 1
}

# -T: bez alokacji TTY — skrypt bywa wolany z crona, ze screena i z petli.
manage() {
	"$DOCKER" compose exec -T "$APPSERVER_SERVICE" python src/manage.py "$@"
}

# Czy obraz w ogole zna komendy countdownu (django-countdown >= 0.3.0)?
#
# NIE robic z tego potoku `manage ... | grep -q`: pod `set -o pipefail` `grep -q`
# konczy sie po pierwszym trafieniu, producent dostaje SIGPIPE (141), a pipefail
# bierze kod najgorszego ogniwa — czyli udane dopasowanie potrafi zwrocic blad.
# Objaw: losowe "obraz nie zna komend" i cicha degradacja do deployu bez
# ostrzezenia. Dlatego najpierw pelny odczyt, potem dopasowanie w samym bashu.
supported() {
	local out
	out="$(manage help --commands 2>/dev/null)" || return 1
	[[ $'\n'"$out"$'\n' == *$'\n'show_countdown$'\n'* ]]
}

require_supported() {
	if supported; then
		return 0
	fi
	cat >&2 <<-EOF
		BLAD: nie moge potwierdzic obslugi przerwy technicznej (brak komendy
		      'show_countdown' albo appserver nie odpowiada).
		      Wymagany dzialajacy appserver z django-countdown >= 0.3.0.
		      Sprawdz: docker compose ps appserver
		      Albo zrob deploy bez ostrzezenia: make run
	EOF
	return 1
}

# Wywolaj komende raz na witryne z SITE_IDS, albo raz bez --site-id (biezaca).
run_per_site() {
	local ids rc=0 id
	ids="$(printf '%s' "${SITE_IDS//,/ }")"
	if [ -z "${ids// /}" ]; then
		manage "$@"
		return $?
	fi
	for id in $ids; do
		manage "$@" --site-id "$id" || rc=$?
	done
	return "$rc"
}

cmd_enable() {
	require_supported || return 1
	local args=(start_countdown --banner "+${MINUTES}m" --service "+${SERVICE}m" --message "$MESSAGE")
	[ -n "$LONG_DESCRIPTION" ] && args+=(--long-description "$LONG_DESCRIPTION")
	# --force: druga proba w tej samej sesji (albo pozostalosc po poprzedniej)
	# ma nadpisac, a nie wywalic sie na "countdown already exists".
	args+=(--noinput --force)
	run_per_site "${args[@]}"
}

cmd_disable() {
	require_supported || return 1
	# Bez --site-id: `stop_countdown` konczy incydent, wiec celowo zamiata
	# wszystkie witryny — lacznie z osieroconym wierszem example.com, ktory
	# tworzy `migrate`. Na instalacji BPP wszystkie domeny sa nasze.
	manage stop_countdown --noinput
}

cmd_adjust() {
	local raw="${1:-}"
	if [ -z "$raw" ]; then
		echo "BLAD: podaj o ile minut, np. adjust +5 albo adjust -5" >&2
		return 2
	fi
	require_supported || return 1

	local sign="+" value="$raw"
	case "$raw" in
		-*) sign="-"; value="${raw#-}" ;;
		+*) value="${raw#+}" ;;
	esac
	case "$value" in
		'' | *[!0-9]*)
			echo "BLAD: '$raw' to nie liczba minut (uzyj np. +5 albo -5)." >&2
			return 2
			;;
	esac
	if [ "$value" -eq 0 ]; then
		echo "BLAD: zero minut nic nie zmienia." >&2
		return 2
	fi

	# Upstream celowo nie przyjmuje liczb ze znakiem: kierunek niesie NAZWA
	# komendy, bo 'shorten +15m' nie da sie zle odczytac, a 'adjust -15m' tak.
	local cmd="extend_countdown"
	[ "$sign" = "-" ] && cmd="shorten_countdown"
	run_per_site "$cmd" --service "+${value}m" --noinput
}

cmd_heartbeat() {
	# Bez `|| true` — pusty cel jest dla --at-least sukcesem, wiec niezerowy kod
	# wyjscia naprawde znaczy "ochrona przestala dzialac" i wolajacy ma prawo
	# to zauwazyc. Sonda wsparcia pominieta: sesja sprawdzila je przed startem.
	run_per_site extend_countdown --at-least "${FLOOR_MINUTES}m" --noinput
}

cmd_status() {
	require_supported || return 1
	# Bez parsowania: ludzki output jest zrobiony do czytania, a --json do
	# przepuszczenia dalej. Parsowanie wymagaloby jq/pythona NA HOSCIE.
	if [ "${JSON:-0}" = "1" ]; then
		manage show_countdown --json
	else
		manage show_countdown
	fi
}

case "${1:-}" in
	supported) supported ;;
	enable) cmd_enable ;;
	disable) cmd_disable ;;
	adjust) cmd_adjust "${2:-}" ;;
	heartbeat) cmd_heartbeat ;;
	status) cmd_status ;;
	*)
		echo "Uzycie: $(basename "$0") {supported|enable|disable|adjust ±N|heartbeat|status}" >&2
		exit 2
		;;
esac

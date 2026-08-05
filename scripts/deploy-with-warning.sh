#!/usr/bin/env bash
#
# deploy-with-warning.sh — deploy BPP z uprzedzeniem uzytkownikow.
#
#   FAZA 1  make pull                  (bez wplywu na uzytkownikow)
#   FAZA 2  baner "za N minut przerwa" (sztywne okno, tick statusu)
#   FAZA 3  odciecie -> make run -> bramka zdrowia
#   FAZA 4  zdjecie blokady
#
# Przeznaczone do prowadzenia pod screenem:
#   screen -dmS bpp-deploy make run-with-warning
#   screen -r bpp-deploy            (odlaczenie: Ctrl-A D)
#
# Regulacja deklarowanego powrotu Z INNEGO OKNA (sesja nic nie czyta z klawiatury):
#   make status-site-down-warning
#   make extend-site-down-warning MINUTES=+10
#   make disable-site-down-warning
#
# Zmienne (wszystkie z domyslnymi — patrz scripts/site-down-warning.sh):
#   MINUTES, SERVICE, MESSAGE, SITE_IDS
#   SITE_DOWN_TICK_INTERVAL       (30 s)  — co ile wypisywac status w oknie banera
#   SITE_DOWN_HEARTBEAT_INTERVAL  (60 s)  — co ile podtrzymywac podloge blokady
#   SITE_DOWN_TEST_WAIT_SECONDS   (—)     — skrocenie okna banera; TYLKO do testow
#
# `make run` dostaje BPP_SKIP_HEALTH_GATE=1 — inaczej prompt [s]/[d] bramki zdrowia
# zablokowalby sesje pod pseudo-TTY screena (kontrakt z CLAUDE.md). Bramke wolamy
# sami, jawnie, po deployu, ze stdin z /dev/null, wiec tez nie pyta.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MAKE="${MAKE:-make}"
WARN="$REPO_DIR/scripts/site-down-warning.sh"
POST_DEPLOY_CHECK="${POST_DEPLOY_CHECK:-$REPO_DIR/scripts/post-deploy-check.sh}"

MINUTES="${MINUTES:-${SITE_DOWN_WARNING_MINUTES:-5}}"
SERVICE="${SERVICE:-${SITE_DOWN_SERVICE_MINUTES:-10}}"
TICK_INTERVAL="${SITE_DOWN_TICK_INTERVAL:-30}"
HEARTBEAT_INTERVAL="${SITE_DOWN_HEARTBEAT_INTERVAL:-60}"
FLOOR_MINUTES="${SITE_DOWN_HEARTBEAT_FLOOR_MINUTES:-5}"

export MINUTES SERVICE

START_TS="$(date +%s)"
CUTOFF_TS=""
# init -> baner nie wisi | banner -> baner wisi, stack nietkniety | blocked ->
# po odcieciu, stack ruszony. Od tego zalezy sprzatanie przy przerwaniu.
PHASE="init"
WARNING_ACTIVE=0
HEARTBEAT_PID=""

cd "$REPO_DIR" || {
	echo "BLAD: nie moge wejsc do $REPO_DIR." >&2
	exit 1
}

# --- Wypisywanie ------------------------------------------------------------

elapsed() {
	local s=$(($(date +%s) - START_TS))
	printf '%02d:%02d' $((s / 60)) $((s % 60))
}

log() { printf '[+%s] %s\n' "$(elapsed)" "$*"; }
log_cont() { printf '         %s\n' "$*"; }

# GNU (-d @) i BSD/macOS (-r) roznia sie skladnia — probujemy obu.
fmt_time() {
	date -d "@$1" '+%H:%M:%S' 2>/dev/null || date -r "$1" '+%H:%M:%S' 2>/dev/null || echo '?'
}

fmt_duration() {
	local s="$1"
	if [ "$s" -ge 60 ]; then
		printf '%d min %d s' $((s / 60)) $((s % 60))
	else
		printf '%d s' "$s"
	fi
}

# --- Heartbeat --------------------------------------------------------------
# Podtrzymuje maintenance_until >= teraz + FLOOR. Gdy sesja zginie, nikt tego nie
# robi i blokada wygasa sama — to jest caly dead-man's switch.

start_heartbeat() {
	(
		while :; do
			if ! bash "$WARN" heartbeat >/dev/null 2>&1; then
				# Bez wyciszania: w trakcie recreate appservera `exec` MUSI sie
				# nie udac i to jest spodziewane, ale trwale milczenie tutaj
				# znaczyloby, ze blokada wygasa w srodku deployu.
				log "OSTRZEZENIE: heartbeat nieudany — ochrona przerwy moze wygasnac."
			fi
			sleep "$HEARTBEAT_INTERVAL"
		done
	) &
	HEARTBEAT_PID=$!
}

stop_heartbeat() {
	[ -n "$HEARTBEAT_PID" ] || return 0
	kill "$HEARTBEAT_PID" 2>/dev/null
	wait "$HEARTBEAT_PID" 2>/dev/null
	HEARTBEAT_PID=""
}

# --- Sprzatanie -------------------------------------------------------------

# shellcheck disable=SC2329  # wolane posrednio przez `trap cleanup EXIT`
cleanup() {
	local rc=$?
	stop_heartbeat
	case "$PHASE" in
		banner)
			log "Przerwano przed odcieciem — zdejmuje ostrzezenie."
			bash "$WARN" disable >/dev/null 2>&1 ||
				log "OSTRZEZENIE: nie udalo sie zdjac ostrzezenia — zrob to recznie: make disable-site-down-warning"
			;;
		blocked)
			log "PRZERWANO albo BLAD po odcieciu — blokada ZOSTAJE (stack w nieznanym stanie)."
			log_cont "stan:          make status-site-down-warning"
			log_cont "wiecej czasu:  make extend-site-down-warning MINUTES=+30"
			log_cont "odblokowanie:  make disable-site-down-warning"
			log_cont "UWAGA: heartbeat juz nie bije — blokada wygasnie sama za <= ${FLOOR_MINUTES} min."
			;;
	esac
	exit "$rc"
}

trap cleanup EXIT
trap 'exit 130' INT TERM

# --- Wsparcie w obrazie -----------------------------------------------------

SUPPORTED=1
if ! bash "$WARN" supported; then
	SUPPORTED=0
	echo ""
	echo "!! Obraz BPP nie zna komend przerwy technicznej (django-countdown >= 0.3.0)."
	echo "!! Deploy pojdzie BEZ ostrzezenia dla uzytkownikow."
	echo ""
	if [ -t 0 ] && [ -t 1 ]; then
		printf "   Kontynuowac? [t/N] "
		read -r answer
		case "$answer" in
			t | T | y | Y) ;;
			*)
				echo "Przerwane."
				exit 1
				;;
		esac
	else
		echo "!! Brak terminala — kontynuuje bez ostrzezenia."
	fi
fi

# --- FAZA 1: obrazy ---------------------------------------------------------

log "=== FAZA 1: pobieranie obrazow (bez wplywu na uzytkownikow) ==="
log "make pull"
# UWAGA: kod wyjscia przechwytujemy PRZED `if`. W `if ! cmd; then rc=$?` operator
# `!` zdazy juz odwrocic status i rc bylby zerem — deploy zglaszalby sukces mimo
# bledu (autoupdate poszedlby spac zamiast krzyknac).
"$MAKE" pull
rc=$?
if [ "$rc" -ne 0 ]; then
	log "BLAD: 'make pull' zakonczony kodem $rc — PRZERYWAM (nic sie jeszcze nie stalo)."
	exit "$rc"
fi
log "pull OK"

# --- FAZA 2: ostrzezenie ----------------------------------------------------

if [ "$SUPPORTED" -eq 1 ]; then
	log "=== FAZA 2: ostrzezenie ==="
	bash "$WARN" enable
	rc=$?
	if [ "$rc" -ne 0 ]; then
		log "BLAD: nie udalo sie wywiesic ostrzezenia (kod $rc) — PRZERYWAM."
		exit "$rc"
	fi
	PHASE="banner"
	WARNING_ACTIVE=1

	wait_seconds="${SITE_DOWN_TEST_WAIT_SECONDS:-$((MINUTES * 60))}"
	CUTOFF_TS=$(($(date +%s) + wait_seconds))
	eta_ts=$((CUTOFF_TS + SERVICE * 60))

	log "ostrzezenie WLACZONE"
	log_cont "odciecie:            $(fmt_time "$CUTOFF_TS")"
	log_cont "deklarowany powrot:  $(fmt_time "$eta_ts")"
	log_cont "regulacja z innego okna: make extend-site-down-warning MINUTES=+5"

	while :; do
		left=$((CUTOFF_TS - $(date +%s)))
		[ "$left" -le 0 ] && break
		step="$TICK_INTERVAL"
		[ "$step" -gt "$left" ] && step="$left"
		sleep "$step"
		left=$((CUTOFF_TS - $(date +%s)))
		[ "$left" -gt 0 ] && log "do odciecia $(fmt_duration "$left") ..."
	done
fi

# --- FAZA 3: przerwa techniczna ---------------------------------------------

log "=== FAZA 3: przerwa techniczna ==="
DOWN_FROM_TS="$(date +%s)"
if [ "$SUPPORTED" -eq 1 ]; then
	PHASE="blocked"
	log "strona ZABLOKOWANA (503 ze strona przerwy)"
	log_cont "heartbeat co ${HEARTBEAT_INTERVAL} s podtrzymuje powrot >= teraz + ${FLOOR_MINUTES} min"
	start_heartbeat
fi

log "make run (BPP_SKIP_HEALTH_GATE=1)"
run_start="$(date +%s)"
BPP_SKIP_HEALTH_GATE=1 "$MAKE" run
rc=$?
if [ "$rc" -ne 0 ]; then
	log "BLAD: 'make run' zakonczony kodem $rc."
	exit "$rc"
fi
log "make run OK ($(fmt_duration $(($(date +%s) - run_start))))"

# Bramka zdrowia jawnie i BEZ promptu (stdin z /dev/null): pytanie [s]/[d]
# zawiesiloby sesje przy zablokowanej stronie.
log "kontrola stanu: $(basename "$POST_DEPLOY_CHECK")"
if ! bash "$POST_DEPLOY_CHECK" </dev/null; then
	log "BLAD: bramka zdrowia zglasza problem — deploy uznany za nieudany."
	exit 1
fi
log "wszystkie uslugi zdrowe"

# --- FAZA 4: koniec ---------------------------------------------------------

stop_heartbeat
log "=== FAZA 4: koniec ==="
if [ "$WARNING_ACTIVE" -eq 1 ]; then
	bash "$WARN" disable
	rc=$?
	if [ "$rc" -ne 0 ]; then
		log "BLAD: nie udalo sie zdjac blokady (kod $rc)!"
		log_cont "zrob to recznie: make disable-site-down-warning"
		exit "$rc"
	fi
	log "ostrzezenie ZDJETE — strona dostepna"
fi

PHASE="done"
now="$(date +%s)"
log "laczny czas sesji $(fmt_duration $((now - START_TS))), niedostepnosc $(fmt_duration $((now - DOWN_FROM_TS)))"
exit 0

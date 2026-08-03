#!/usr/bin/env bash
#
# setup-autoupdate-cron.sh — straznik (watchdog) petli auto-aktualizacji BPP
# jako wpis w crontabie UZYTKOWNIKA (bez sudo, bez /etc/cron.d).
#
# Instaluje jedna linie, ktora co $AUTOUPDATE_CRON_SCHEDULE wola
# `make screen-with-autoupdate`. Ten target jest idempotentny (sesja zyje ->
# nic nie robi), wiec JEDEN wpis pokrywa zarowno restart hosta (nie trzeba
# osobnego @reboot), jak i padniecie sesji screen miedzy restartami.
#
# Zmienne srodowiskowe (wszystkie z domyslnymi):
#   AUTOUPDATE_CRON_SCHEDULE  -> harmonogram straznika (domyslnie `*/15 * * * *`)
#   AUTOUPDATE_CRON_LOG       -> log straznika (domyslnie
#                                $BPP_CONFIGS_DIR/logs/autoupdate-cron.log,
#                                fallback $REPO_DIR/.autoupdate-cron.log)
#   AUTOUPDATE_SCREEN_NAME    -> nazwa sesji screen; tylko do komunikatow
#   CRONTAB                   -> binarka crontab (punkt wstrzykniecia mocka w testach)
#
# MINIMALNY PATH jest ZAMRAZANY w chwili instalacji i trafia jako prefiks
# komendy (nie jako osobna linia `PATH=`, ktora byla by globalna dla wszystkich
# zadan uzytkownika). Cron startuje zadania z jalowym PATH=/usr/bin:/bin — to za
# malo dla hostow, gdzie docker/make/git leza w /usr/local/bin czy
# /opt/homebrew/bin.
#
# MINIMALNY, a nie caly $PATH powloki: crony z rodziny Vixie (Debian/Ubuntu
# `cron`, `cronie`) maja twardy limit dlugosci komendy (MAX_COMMAND, rzedu 1000
# znakow). Powloka operatora z nvm/pyenv/asdf/homebrew/pluginami potrafi miec
# $PATH na 50 katalogow (~3,5 tys. znakow) — taki wpis bywa odrzucany przy
# zapisie crontaba albo, gorzej, wchodzi UCIETY. Dlatego zamrazamy tylko te
# katalogi, w ktorych realnie leza binarki potrzebne wpisowi (make, docker, git,
# screen, bash) plus standardowe systemowe, deduplikowane z zachowaniem
# kolejnosci. Dodatkowo cala linia jest walidowana pod katem dlugosci.
#
# Uruchomienie:
#   bash scripts/setup-autoupdate-cron.sh            (make setup-autoupdate-cron)
#   bash scripts/setup-autoupdate-cron.sh --remove   (make remove-autoupdate-cron)

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CRONTAB="${CRONTAB:-crontab}"
SCHEDULE="${AUTOUPDATE_CRON_SCHEDULE:-*/15 * * * *}"
SCREEN_NAME="${AUTOUPDATE_SCREEN_NAME:-bpp-autoupdate}"

# Marker konczacy nasza linie — po nim (a NIE po tresci komendy) filtrujemy
# stary wpis, dzieki czemu zmiana harmonogramu tez nie dubluje wpisow.
CRON_MARKER="# BPP-AUTOUPDATE"

log()  { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { log "OSTRZEZENIE: $*" >&2; }
die()  { log "BLAD: $*" >&2; exit 1; }

# --- Tryb pracy --------------------------------------------------------------
MODE="install"
case "${1:-}" in
	"")        ;;
	--remove)  MODE="remove" ;;
	-h|--help)
		echo "Uzycie: $0 [--remove]"
		echo "  (bez argumentu) - instaluje/aktualizuje wpis cron straznika"
		echo "  --remove        - usuwa wpis cron straznika"
		exit 0
		;;
	*)
		echo "Uzycie: $0 [--remove]" >&2
		exit 2
		;;
esac

# --- Walidacja harmonogramu (przed dotknieciem czegokolwiek) -----------------
# `%` w polach czasu nie ma znaczenia specjalnego, wiec escapowanie go tam
# byloby skladniowo bledne — prosciej i bezpieczniej odrzucic.
case "$SCHEDULE" in
	*%*) die "harmonogram nie moze zawierac znaku '%' (AUTOUPDATE_CRON_SCHEDULE='$SCHEDULE')." ;;
esac

schedule_ok=0
case "$SCHEDULE" in
	@reboot|@hourly|@daily|@midnight|@weekly|@monthly|@yearly|@annually)
		schedule_ok=1
		;;
	@*)
		schedule_ok=0
		;;
	*)
		# Liczymy pola bez globowania — `*/15 * * * *` rozwinaloby sie do nazw plikow.
		set -f
		# shellcheck disable=SC2086  # celowe dzielenie na pola
		set -- $SCHEDULE
		[ "$#" -eq 5 ] && schedule_ok=1
		set +f
		;;
esac

if [ "$schedule_ok" -ne 1 ]; then
	die "niepoprawny harmonogram: '$SCHEDULE'.
       Dopuszczalne sa dwie formy:
         - piec pol rozdzielonych spacjami, np. '*/15 * * * *'
         - makro: @reboot @hourly @daily @midnight @weekly @monthly @yearly @annually"
fi

# --- Wymagane/opcjonalne narzedzia -------------------------------------------
if ! command -v "$CRONTAB" >/dev/null 2>&1; then
	die "brak polecenia 'crontab' w PATH — nie mam gdzie zapisac wpisu.
       Zainstaluj crona, np.: apt-get install -y cron"
fi

if [ "$MODE" = "install" ]; then
	if ! command -v screen >/dev/null 2>&1; then
		# Nie blad: wpis bedzie poprawny, gdy screen doinstalujesz pozniej.
		warn "brak polecenia 'screen' — straznik nie wystartuje sesji, dopoki go nie doinstalujesz (apt-get install -y screen)."
	fi
	# Sama binarka crontab nie gwarantuje, ze ktokolwiek ten crontab czyta.
	# Detekcja demona jest zawodna (kontenery, macOS, nietypowe inity), wiec
	# ostrzegamy miekko.
	cron_running=0
	pgrep -x cron  >/dev/null 2>&1 && cron_running=1
	pgrep -x crond >/dev/null 2>&1 && cron_running=1
	if [ "$cron_running" -eq 0 ] && command -v systemctl >/dev/null 2>&1; then
		systemctl is-active cron >/dev/null 2>&1 && cron_running=1
		systemctl is-active crond >/dev/null 2>&1 && cron_running=1
	fi
	if [ "$cron_running" -eq 0 ]; then
		warn "nie wykrylem dzialajacego demona cron — wpis moze nigdy nie zostac uruchomiony. Sprawdz: systemctl status cron"
	fi
fi

# --- Sciezka logu ------------------------------------------------------------
# Pusta wartosc AUTOUPDATE_CRON_LOG (tak podaje ja Makefile) = "nie ustawiono".
CONFIGS_DIR="${BPP_CONFIGS_DIR:-}"
if [ -z "$CONFIGS_DIR" ] && [ -f "$REPO_DIR/.env" ]; then
	CONFIGS_DIR="$(grep -E '^BPP_CONFIGS_DIR=' "$REPO_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
	CONFIGS_DIR="${CONFIGS_DIR#\"}"; CONFIGS_DIR="${CONFIGS_DIR%\"}"
	CONFIGS_DIR="${CONFIGS_DIR#\'}"; CONFIGS_DIR="${CONFIGS_DIR%\'}"
fi
case "$CONFIGS_DIR" in
	"~/"*) CONFIGS_DIR="$HOME/${CONFIGS_DIR#\~/}" ;;
esac

LOG="${AUTOUPDATE_CRON_LOG:-}"
if [ -z "$LOG" ]; then
	if [ -n "$CONFIGS_DIR" ]; then
		LOG="$CONFIGS_DIR/logs/autoupdate-cron.log"
	else
		LOG="$REPO_DIR/.autoupdate-cron.log"
	fi
fi
LOG_DIR="$(dirname "$LOG")"

# --- Minimalny PATH dla wpisu ------------------------------------------------
# Tylko katalogi, w ktorych REALNIE leza binarki potrzebne wpisowi, plus
# standardowe systemowe. Dedup z zachowaniem kolejnosci (wykryte przed
# standardowymi), bez pustych i nieistniejacych. Efekt: ~60-120 znakow zamiast
# kilku tysiecy, wiec miescimy sie w MAX_COMMAND Vixie crona.
CRON_PATH_DIRS=()

add_cron_path_dir() {
	local dir="$1" existing
	[ -n "$dir" ] || return 0
	[ -d "$dir" ] || return 0
	for existing in ${CRON_PATH_DIRS+"${CRON_PATH_DIRS[@]}"}; do
		[ "$existing" = "$dir" ] && return 0
	done
	CRON_PATH_DIRS+=("$dir")
}

# `screen` moze zostac doinstalowany pozniej, `docker` moze nie byc w PATH
# w chwili instalacji — brakujace binarki po prostu pomijamy.
for bin in make docker git screen bash; do
	bin_path="$(command -v "$bin" 2>/dev/null)" || bin_path=""
	case "$bin_path" in
		/*) add_cron_path_dir "$(dirname "$bin_path")" ;;
		*)  ;;  # builtin/alias/brak — nie ma katalogu do zamrozenia
	esac
done

for dir in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
	add_cron_path_dir "$dir"
done

CRON_PATH="$(IFS=:; printf '%s' "${CRON_PATH_DIRS[*]}")"
[ -n "$CRON_PATH" ] || CRON_PATH="/usr/bin:/bin"

# Sciezki wchodza do wpisu w pojedynczych cudzyslowach — apostrof w ktorejkolwiek
# rozsypalby cala linie.
case "$REPO_DIR$LOG$CRON_PATH" in
	*"'"*) die "sciezka repo, logu albo PATH zawiera apostrof (') — nie da sie z tego zbudowac bezpiecznego wpisu cron." ;;
esac

# --- Budowa wpisu i walidacja jego dlugosci ----------------------------------
# Niezaescape'owany `%` w KOMENDZIE cron oznacza znak nowej linii: uciolby
# komende, a reszte podal jej na stdin. Escapujemy wylacznie czesc komendy —
# w harmonogramie `%` jest juz odrzucone walidacja wyzej.
CRON_CMD="cd '$REPO_DIR' && PATH='$CRON_PATH' make screen-with-autoupdate >> '$LOG' 2>&1  $CRON_MARKER"
CRON_CMD="${CRON_CMD//%/\\%}"
ENTRY="$SCHEDULE $CRON_CMD"

# Pas bezpieczenstwa na wypadek bardzo dlugiej sciezki repo albo logu. Limit
# ponizej MAX_COMMAND (~1000), zeby zostal margines na roznice miedzy cronami.
CRON_MAX_ENTRY_LEN=900
if [ "$MODE" = "install" ] && [ "${#ENTRY}" -gt "$CRON_MAX_ENTRY_LEN" ]; then
	die "wpis cron ma ${#ENTRY} znakow — powyzej bezpiecznego limitu $CRON_MAX_ENTRY_LEN.
       Crony z rodziny Vixie (Debian/Ubuntu 'cron', 'cronie') maja twardy limit
       dlugosci komendy (MAX_COMMAND, rzedu 1000 znakow): dluzsza linia bywa
       odrzucana przy zapisie albo wchodzi UCIETA.
       Skroc sciezke repozytorium albo ustaw krotszy AUTOUPDATE_CRON_LOG."
fi

# KRYTYCZNE: katalog logu musi istniec ZANIM cokolwiek zapiszemy — w OBU
# trybach, bo trafia tam takze kopia zapasowa crontaba. Domyslnego
# $BPP_CONFIGS_DIR/logs/ nie tworzy dzis zaden inny skrypt ani compose. Bez
# tego: kopia zapasowa pada juz przy instalacji, a nawet gdyby przeszla —
# powloka otwiera `>>` PRZED uruchomieniem `make`, wiec wpis padalby co tick
# (martwy straznik), a cron mailowalby blad do roota co 15 minut.
mkdir -p "$LOG_DIR" || die "nie moge utworzyc katalogu logu: $LOG_DIR"

# --- Odczyt biezacego crontaba ----------------------------------------------
WORK_DIR="$(mktemp -d -t bpp-cron-XXXXXX)" || die "nie moge utworzyc katalogu tymczasowego."
# shellcheck disable=SC2064  # rozwiazujemy WORK_DIR teraz, celowo
trap "rm -rf '$WORK_DIR'" EXIT

CUR="$WORK_DIR/crontab.current"
NEW="$WORK_DIR/crontab.new"
CRON_ERR="$WORK_DIR/crontab.err"

# Stdout i stderr przechwytujemy OSOBNO: potraktowanie kazdego niezerowego kodu
# jako "crontab jest pusty" groziloby wyzerowaniem cudzych wpisow — i to bez
# kopii zapasowej, bo tej tez by wtedy nie bylo.
crontab_exists=1
"$CRONTAB" -l >"$CUR" 2>"$CRON_ERR"
rc=$?
if [ "$rc" -ne 0 ]; then
	if grep -qi 'no crontab' "$CRON_ERR"; then
		crontab_exists=0
		: > "$CUR"
	else
		log "BLAD: 'crontab -l' zakonczony kodem $rc — PRZERYWAM, nie dotykam crontaba." >&2
		sed 's/^/       /' "$CRON_ERR" >&2
		exit 1
	fi
fi

# --- Kopia zapasowa (zawsze, gdy bylo co kopiowac) ---------------------------
if [ -s "$CUR" ]; then
	BACKUP="$LOG_DIR/crontab.bak.$(date +%Y%m%d-%H%M%S)"
	cp "$CUR" "$BACKUP" || die "nie moge zapisac kopii zapasowej crontaba: $BACKUP"
	log "Kopia zapasowa crontaba: $BACKUP"
fi

# --- Tryb --remove -----------------------------------------------------------
if [ "$MODE" = "remove" ]; then
	if [ "$crontab_exists" -eq 0 ]; then
		# Nie tworzymy pustego crontaba tylko po to, zeby nic z niego nie usunac.
		log "Crontab uzytkownika nie istnieje — nie bylo czego usuwac."
		exit 0
	fi
	if ! grep -qF "$CRON_MARKER" "$CUR"; then
		log "Brak wpisow BPP w crontabie ($CRON_MARKER) — nie bylo czego usuwac."
		exit 0
	fi
	grep -vF "$CRON_MARKER" "$CUR" > "$NEW" || true
	"$CRONTAB" "$NEW" || die "zapis crontaba nieudany (plik z nowa trescia: $NEW)."
	log "✓ Wpis cron auto-aktualizacji usuniety. Cudze wpisy pozostaly nietkniete."
	echo ""
	echo "  Sesja screen (jesli dziala) NIE zostala zatrzymana:"
	echo "    screen -S $SCREEN_NAME -X quit"
	exit 0
fi

# --- Tryb instalacji ---------------------------------------------------------
# Filtr po markerze: usuwa nasz stary wpis (takze z innym harmonogramem),
# cudze linie przechodza nietkniete.
grep -vF "$CRON_MARKER" "$CUR" > "$NEW" || true

# $ENTRY zbudowany i zwalidowany wyzej (przed mkdir i przed odczytem crontaba).
printf '%s\n' "$ENTRY" >> "$NEW"
"$CRONTAB" "$NEW" || die "zapis crontaba nieudany (plik z nowa trescia: $NEW)."

log "✓ Wpis cron auto-aktualizacji zainstalowany."
echo ""
echo "  Wpis:"
echo "    $ENTRY"
echo ""
echo "  Dlugosc wpisu:   ${#ENTRY} znakow (limit crona: ok. 1000)"
echo "  Log straznika:   $LOG"
echo "  Podglad sesji:   screen -r $SCREEN_NAME"
echo "  Wycofanie wpisu: make remove-autoupdate-cron"
echo ""
echo "  Straznik zapisuje ~100 B na tick (przy */15 to ~3,5 MB/rok) — gdy log"
echo "  urosnie, wyczysc go recznie: truncate -s 0 '$LOG'"

#!/usr/bin/env bash
#
# autoupdate.sh — JEDEN cykl nienadzorowanej aktualizacji BPP.
#
# Sprawdza, czy pojawil sie nowszy commit na origin/main LUB nowszy obraz Docker.
# Jesli tak: (opcjonalny backup) -> git pull --ff-only -> make run.
# Bezstanowy i idempotentny: brak zmian -> nic nie robi, exit 0.
#
# Harmonogram jest ZEWNETRZNY — `make autoupdate` odpala ten skrypt w petli pod
# screen/tmux; ten sam skrypt dziala tez 1:1 pod cronem/systemd. Skrypt wolany
# swiezo co iteracje, wiec po `git pull` nastepny cykl uzywa juz nowej logiki.
#
# Zmienne srodowiskowe (wszystkie z domyslnymi):
#   AUTOUPDATE_DB_BACKUP=1     -> `make db-backup` przed deployem (domyslnie wyl.)
#   AUTOUPDATE_LOCK_DIR=<dir>   -> nadpisanie katalogu locka (glownie do testow)
#   AUTOUPDATE_LOCK_MAX_AGE_MINUTES=120 -> po tylu minutach trwajacy cykl jest
#                                  glosno zglaszany jako wiszacy (lock zywego
#                                  procesu NIE jest przejmowany), a lock bez
#                                  pliku owner uznawany za osierocony
#   AUTOUPDATE_BOOT_ID=<id>     -> nadpisanie identyfikatora rozruchu (testy)
#   AUTOUPDATE_WARNING_MINUTES  -> gdy > 0, deploy idzie przez sesje z
#                                  ostrzezeniem (baner N minut -> blokada ->
#                                  deploy -> odblokowanie). Puste/0 = jak dotad.
#   AUTOUPDATE_SELF_RESTART=0   -> wylacza samorestart petli po zmianie jej
#                                  wlasnego kodu (patrz sekcja 5)
#
# `make run` dostaje BPP_SKIP_HEALTH_GATE=1 — inaczej prompt [s]/[d] bramki
# zdrowia zablokowalby petle pod pseudo-TTY screena (kontrakt z CLAUDE.md).
#
# Uruchomienie: bash scripts/autoupdate.sh   (albo w petli: make autoupdate)

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MAKE="${MAKE:-make}"
GIT="${GIT:-git}"
DOCKER="${DOCKER:-docker}"
LOCK_DIR="${AUTOUPDATE_LOCK_DIR:-$REPO_DIR/.autoupdate.lock.d}"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# --- Lock (mkdir jest atomowy i przenosny; flock nie ma na macOS) ------------
# Zajety lock: inny cykl auto-update trwa — nie nakladamy sie. (Reczny `make run`
# locka NIE sprawdza.)
#
# OSIEROCONY LOCK. SIGKILL (OOM killer, kill -9) i restart hosta omijaja
# `trap EXIT`, a katalog zostaje na dysku — kazdy kolejny cykl konczylby sie na
# "inny cykl trwa", az ktos zajrzy do screena (produkcja, 2026-09-10: dwie doby).
# Dlatego w locku lezy plik `owner` (pid, rozruch hosta, start), a zajety lock
# przejmujemy TYLKO, gdy da sie wykazac, ze wlasciciel nie zyje: inny rozruch,
# martwy PID albo PID nalezacy juz do innego procesu. Zywego wlasciciela nie
# ruszamy nigdy — ponad AUTOUPDATE_LOCK_MAX_AGE_MINUTES tylko glosno ostrzegamy:
# deploy moze jeszcze trwac, a dwa rownolegle sa gorsze niz jeden stojacy.
LOCK_MAX_AGE_MINUTES="${AUTOUPDATE_LOCK_MAX_AGE_MINUTES:-120}"
case "$LOCK_MAX_AGE_MINUTES" in
	''|*[!0-9]*)
		log "OSTRZEZENIE: AUTOUPDATE_LOCK_MAX_AGE_MINUTES='$LOCK_MAX_AGE_MINUTES' to nie liczba minut — przyjmuje 120."
		LOCK_MAX_AGE_MINUTES=120 ;;
esac

# Rozny po kazdym starcie hosta — PID z locka sprzed restartu nie zostanie
# wziety za zywy, gdy system nada ten numer innemu procesowi.
boot_id() {
	if [ -n "${AUTOUPDATE_BOOT_ID:-}" ]; then
		printf '%s' "$AUTOUPDATE_BOOT_ID"
	elif [ -r /proc/sys/kernel/random/boot_id ]; then
		cat /proc/sys/kernel/random/boot_id
	else
		# macOS. Gdy i tego brak: puste, a porownanie rozruchu jest pomijane
		# (zostaje sprawdzenie PID) — celowo nie przerywamy cyklu.
		sysctl -n kern.boottime 2>/dev/null || true
	fi
}

owner_field() {
	awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$LOCK_DIR/owner" 2>/dev/null
}

lock_acquire() {
	mkdir "$LOCK_DIR" 2>/dev/null || return 1
	# Przez plik tymczasowy + mv: czytajacy widzi plik pelny albo zaden.
	if ! { printf 'pid=%s\nboot=%s\nstarted=%s\n' "$$" "$(boot_id)" "$(date +%s)" > "$LOCK_DIR/owner.tmp" \
		&& mv "$LOCK_DIR/owner.tmp" "$LOCK_DIR/owner"; }; then
		log "OSTRZEZENIE: nie moge zapisac $LOCK_DIR/owner — po awarii lock zwolni dopiero limit $LOCK_MAX_AGE_MINUTES min."
	fi
	return 0
}

# Bez `rm -rf`: kasujemy wylacznie wlasne pliki, wiec pomylkowy
# AUTOUPDATE_LOCK_DIR wskazujacy na cudzy katalog skonczy sie na bledzie rmdir.
lock_remove() {
	rm -f "$LOCK_DIR/owner" "$LOCK_DIR/owner.tmp"
	[ -d "$LOCK_DIR" ] || return 0
	rmdir "$LOCK_DIR" 2>/dev/null && return 0
	log "OSTRZEZENIE: nie moge usunac $LOCK_DIR (zawiera obce pliki?)."
	return 1
}

lock_release() {
	# Cudzego locka nie zwalniamy.
	if [ -f "$LOCK_DIR/owner" ] && [ "$(owner_field pid)" != "$$" ]; then
		return 0
	fi
	lock_remove
}

# 0 + $lock_stale_reason, gdy wlasciciel na pewno nie zyje; 1, gdy zyje albo
# nie da sie tego rozstrzygnac.
lock_is_stale() {
	lock_stale_reason=""
	owner_pid="$(owner_field pid)"
	case "$owner_pid" in
		''|*[!0-9]*)
			# Brak wlasciciela: lock ze starszej wersji skryptu albo SIGKILL
			# miedzy mkdir a zapisem pliku. Zostaje sam wiek katalogu.
			if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +"$LOCK_MAX_AGE_MINUTES" 2>/dev/null)" ]; then
				lock_stale_reason="lock bez wlasciciela starszy niz $LOCK_MAX_AGE_MINUTES min"
				return 0
			fi
			return 1 ;;
	esac

	owner_boot="$(owner_field boot)"
	current_boot="$(boot_id)"
	if [ -n "$owner_boot" ] && [ -n "$current_boot" ] && [ "$owner_boot" != "$current_boot" ]; then
		lock_stale_reason="zalozony przed restartem hosta przez PID $owner_pid"
		return 0
	fi

	# Pusty wynik `ps` znaczy "nie ma procesu" tylko wtedy, gdy `ps` w ogole
	# dziala — inaczej brak ps wzielibysmy za martwego wlasciciela.
	[ -n "$(ps -p "$$" -o args= 2>/dev/null)" ] || return 1
	owner_args="$(ps -p "$owner_pid" -o args= 2>/dev/null)"
	if [ -z "$owner_args" ]; then
		lock_stale_reason="proces PID $owner_pid nie zyje"
		return 0
	fi
	case "$owner_args" in
		*autoupdate.sh*) return 1 ;;
	esac
	lock_stale_reason="PID $owner_pid nalezy juz do innego procesu ($owner_args)"
	return 0
}

# Przejecie pod osobna blokada (tez mkdir): bez niej dwa procesy moglyby naraz
# uznac lock za martwy, a drugi skasowalby SWIEZY lock pierwszego. Pod blokada
# stan sprawdzamy jeszcze raz.
lock_take_over() {
	takeover="$LOCK_DIR.takeover"
	if [ -n "$(find "$takeover" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
		log "Usuwam osierocona blokade przejmowania ($takeover)."
		rmdir "$takeover" 2>/dev/null || log "OSTRZEZENIE: nie moge usunac $takeover."
	fi
	mkdir "$takeover" 2>/dev/null || return 1

	rc=1
	if lock_acquire; then
		rc=0
	elif lock_is_stale && lock_remove && lock_acquire; then
		rc=0
	fi
	rmdir "$takeover" 2>/dev/null || log "OSTRZEZENIE: nie moge usunac $takeover."
	return "$rc"
}

if ! lock_acquire; then
	if lock_is_stale; then
		log "Osierocony lock $LOCK_DIR: $lock_stale_reason — przejmuje."
		if ! lock_take_over; then
			log "Inny cykl auto-update trwa albo wlasnie przejmuje lock ($LOCK_DIR) — pomijam."
			exit 0
		fi
	else
		owner_pid="$(owner_field pid)"
		started="$(owner_field started)"
		log "Inny cykl auto-update trwa (lock: $LOCK_DIR${owner_pid:+, PID $owner_pid}) — pomijam."
		case "$started" in
			''|*[!0-9]*) ;;
			*)
				wiek=$(( ($(date +%s) - started) / 60 ))
				if [ "$wiek" -gt "$LOCK_MAX_AGE_MINUTES" ]; then
					log "UWAGA: ten cykl trwa juz $wiek min — dluzej niz limit $LOCK_MAX_AGE_MINUTES min (AUTOUPDATE_LOCK_MAX_AGE_MINUTES)."
					log "  Lock NIE jest przejmowany, bo proces zyje: $(ps -p "$owner_pid" -o args= 2>/dev/null)"
					log "  Na czym stoi: pstree -p $owner_pid"
					log "  Jesli wisi: kill $owner_pid (w ostatecznosci kill -9) — nastepny cykl przejmie lock sam."
				fi ;;
		esac
		exit 0
	fi
fi
trap lock_release EXIT

cd "$REPO_DIR" || { log "BLAD: nie moge wejsc do $REPO_DIR."; exit 1; }

# --- 1. Git: czy origin/main wyprzedza HEAD (fast-forward mozliwy)? ----------
git_changed=0
if "$GIT" rev-parse --git-dir >/dev/null 2>&1; then
	if "$GIT" fetch --quiet origin 2>/dev/null; then
		local_rev="$("$GIT" rev-parse HEAD 2>/dev/null || true)"
		remote_rev="$("$GIT" rev-parse origin/main 2>/dev/null || true)"
		if [ -n "$remote_rev" ] && [ "$local_rev" != "$remote_rev" ]; then
			if "$GIT" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
				git_changed=1
				log "Nowe commity na origin/main (fast-forward mozliwy)."
			else
				log "OSTRZEZENIE: lokalny main rozjechal sie z origin/main (nie fast-forward) — pomijam git pull."
			fi
		fi
	else
		log "OSTRZEZENIE: 'git fetch' nieudany — pomijam sprawdzenie commitow."
	fi
else
	log "OSTRZEZENIE: $REPO_DIR to nie repozytorium git — pomijam sprawdzenie commitow."
fi

# --- 2. Obrazy: porownaj ID przed/po `docker compose pull` -------------------
# Registry-agnostic, dziala dla :latest (porownujemy digesty, nie tagi).
#
# `head -1` i `${id:-none}` zamiast `|| echo none`: `docker image inspect` na
# NIEISTNIEJACYM tagu wypisuje na stdout PUSTA LINIE i dopiero potem konczy sie
# bledem. Stare `$(... || echo none)` dawalo wiec "\nnone", czyli wpis ROZBITY
# NA DWIE LINIE — mylacy przy czytaniu i psujacy parsowanie ponizej.
compose_image_ids() {
	"$DOCKER" compose config --images 2>/dev/null | sort -u | while IFS= read -r img; do
		[ -n "$img" ] || continue
		id="$("$DOCKER" image inspect --format '{{.Id}}' "$img" 2>/dev/null | head -1)"
		printf '%s %s\n' "$img" "${id:-none}"
	done
}

# 12 znakow po "sha256:" — tyle, ile pokazuje `docker images`.
krotkie_id() {
	case "$1" in
		none) printf 'BRAK' ;;
		*)    printf '%.12s' "${1#sha256:}" ;;
	esac
}

log "Sprawdzam obrazy (docker compose pull)..."
ids_before="$(compose_image_ids)"
"$DOCKER" compose pull 2>&1 | sed 's/^/  /' || log "OSTRZEZENIE: 'docker compose pull' zwrocil blad — porownuje mimo to."
ids_after="$(compose_image_ids)"

# Porownujemy WPIS PO WPISIE, a nie dwa slepe bloki tekstu — z dwoch powodow.
#
# 1. Komunikat musi mowic, KTORY obraz sie zmienil. "Wykryto nowszy obraz
#    Docker." bez nazwy jest niediagnozowalny: przy 18 obrazach nie ma jak
#    ustalic, czy to prawdziwa aktualizacja, czy artefakt.
#
# 2. Przejscia z/na `none` NIE SA nowsza wersja i nie moga wyzwalac deployu.
#    Zmierzone na produkcji 2026-08-05: `mcuadros/ofelia:0.3.21` znikal
#    z listy tagow po KAZDYM deployu, a kolejny cykl widzial "none -> ID"
#    i wdrazal cala produkcje od nowa. Obraz przy tym ani na chwile nie
#    znikal z dysku — pull trwal 2 sekundy, bo nie mial czego sciagac —
#    wracal sam TAG. Ten obraz ma dwa tagi (`0.3.21` oraz nienalezacy do
#    naszego repo `latest`), a `docker system prune -af` z konca `make up`
#    nie mogl go skasowac (trzyma go dzialajacy kontener ofelii), wiec
#    zdjal z niego referencje. Efekt: samopodtrzymujaca sie petla
#    prune -> pull -> "zmiana" -> deploy -> prune, czyli pelny redeploy
#    produkcji co AUTOUPDATE_INTERVAL, w nieskonczonosc.
#
#    Pominiecie tych przejsc niczego nie gubi: prawdziwie nowy obraz zawsze
#    daje `ID_stare -> ID_nowe`, bo dzialajacy stack ma swoje tagi na miejscu.
#    Jedyny przypadek "none -> ID" z prawdziwa trescia to NOWA usluga
#    w compose — a ta przychodzi razem z commitem, wiec deploy i tak sie
#    odpali sciezka `git_changed`.
image_changed=0
while IFS=' ' read -r img id_after; do
	[ -n "$img" ] || continue
	id_before="$(printf '%s\n' "$ids_before" | awk -v i="$img" '$1 == i { print $2; exit }')"
	[ -n "$id_before" ] || id_before=none
	[ "$id_before" = "$id_after" ] && continue

	if [ "$id_before" = none ] || [ "$id_after" = none ]; then
		log "  $img: sam TAG $(krotkie_id "$id_before") -> $(krotkie_id "$id_after") — to nie jest nowsza wersja, pomijam."
		continue
	fi

	image_changed=1
	log "  $img: $(krotkie_id "$id_before") -> $(krotkie_id "$id_after")"
done <<EOF
$ids_after
EOF

if [ "$image_changed" -eq 1 ]; then
	log "Wykryto nowszy obraz Docker."
fi

# --- 3. Decyzja --------------------------------------------------------------
if [ "$git_changed" -eq 0 ] && [ "$image_changed" -eq 0 ]; then
	log "Brak zmian (commity i obrazy aktualne) — nic nie robie."
	exit 0
fi

log "Wykryto zmiany -> deploy."

if [ "${AUTOUPDATE_DB_BACKUP:-0}" = "1" ]; then
	log "AUTOUPDATE_DB_BACKUP=1 -> backup bazy przed deployem."
	if ! "$MAKE" db-backup; then
		log "BLAD: backup bazy nieudany — PRZERYWAM deploy (fail-safe)."
		exit 1
	fi
fi

# Odcisk plikow, ktore definiuja SAMA PETLE (patrz sekcja 5). Musi byc zdjety
# PRZED `git pull`, inaczej nie ma z czym porownac.
loop_files_hash() {
	"$GIT" rev-parse "HEAD:Makefile" "HEAD:mk/deployment.mk" 2>/dev/null | tr '\n' ' '
}
loop_before="$(loop_files_hash)"

if [ "$git_changed" -eq 1 ]; then
	log "git pull --ff-only origin main"
	if ! "$GIT" pull --ff-only origin main; then
		log "BLAD: 'git pull --ff-only' nieudany — PRZERYWAM."
		exit 1
	fi
fi

warning_minutes="${AUTOUPDATE_WARNING_MINUTES:-0}"
if [ -n "$warning_minutes" ] && [ "$warning_minutes" != "0" ]; then
	# Nienadzorowana aktualizacja z uprzedzeniem uzytkownikow: baner na
	# $warning_minutes minut, potem blokada, deploy i odblokowanie. Sesja jest
	# tu bez TTY, wiec okno banera to zwykly sleep, a stary obraz (bez komend
	# django-countdown) degraduje sie do zwyklego deployu zamiast pytac.
	log "AUTOUPDATE_WARNING_MINUTES=$warning_minutes -> deploy z ostrzezeniem."
	MINUTES="$warning_minutes" bash "$REPO_DIR/scripts/deploy-with-warning.sh"
	rc=$?
else
	log "make run (BPP_SKIP_HEALTH_GATE=1)"
	BPP_SKIP_HEALTH_GATE=1 "$MAKE" run
	rc=$?
fi

if [ "$rc" -eq 0 ]; then
	log "✓ Auto-update zakonczony sukcesem."
else
	log "BLAD: deploy zakonczony kodem $rc."
	exit "$rc"
fi

# --- 5. Samorestart petli, gdy `git pull` zmienil JEJ WLASNY kod -------------
#
# CO JEST ZAMROZONE. Ten skrypt jest wolany SWIEZO w kazdej iteracji
# (`bash scripts/autoupdate.sh` w petli z mk/deployment.mk), wiec po `git pull`
# nastepny cykl bierze juz nowa jego wersje — tak samo `make run` odpala nowego
# make'a i widzi nowe cele, skrypty i pliki compose. Zamrozona jest WYLACZNIE
# tresc samej petli: `make autoupdate` rozwinal cialo `while` i wartosc
# $(AUTOUPDATE_INTERVAL) w chwili startu, a ten proces zyje dalej. Zmiana
# interwalu albo ciala petli nie zadziala, dopoki sesja nie wstanie od nowa.
#
# DLACZEGO ZABICIE SESJI, A NIE `exit` Z KODEM-SYGNALEM. Petla ma ksztalt
# `bash scripts/autoupdate.sh || echo ...; sleep; done` — zaden kod wyjscia jej
# nie przerywa. Dodanie `break` wymagaloby zmiany mk/deployment.mk, czyli
# dokladnie tego pliku, ktory w DZIALAJACEJ sesji jest juz zamrozony: mechanizm
# nie zadzialalby dla wlasnego wdrozenia. Zabicie sesji dziala od razu, bo
# siedzi w calosci w tym skrypcie.
#
# CZTERY WARUNKI, wszystkie musza byc spelnione:
#   1. odcisk Makefile + mk/deployment.mk faktycznie sie zmienil,
#   2. AUTOUPDATE_SELF_RESTART != 0 (furtka awaryjna),
#   3. dzialamy pod screenem ($STY) — inaczej nie ma czego zabic ani co wskrzesic,
#   4. w crontabie stoi straznik (marker `# BPP-AUTOUPDATE`) — BEZ NIEGO petla
#      po prostu by stanela na zawsze, czyli auto-update umarlby po cichu przy
#      okazji wlasnej aktualizacji.
# Gdy 1 jest prawda, a 3 albo 4 nie — NIE zabijamy, tylko glosno prosimy
# o reczny restart. Cicha smierc petli jest tu gorsza niz stara petla.
loop_after="$(loop_files_hash)"

if [ "$loop_before" = "$loop_after" ] || [ "${AUTOUPDATE_SELF_RESTART:-1}" = "0" ]; then
	exit 0
fi

log "Zmienil sie kod samej petli (Makefile / mk/deployment.mk)."

# Nazwa sesji prosto z $STY ("<pid>.<nazwa>") — dziala takze przy wlasnym
# AUTOUPDATE_SCREEN_NAME, ktorego make do skryptu nie eksportuje.
sesja="${STY:+${STY#*.}}"
straznik=0
if "${CRONTAB:-crontab}" -l 2>/dev/null | grep -qF '# BPP-AUTOUPDATE'; then
	straznik=1
fi

if [ -z "$sesja" ] || [ "$straznik" -eq 0 ]; then
	log "UWAGA: petla NIE zrestartuje sie sama — dziala ze starym cialem petli i starym AUTOUPDATE_INTERVAL."
	[ -z "$sesja" ]        && log "  powod: nie dziala pod screenem (\$STY puste)"
	[ "$straznik" -eq 0 ]  && log "  powod: brak straznika w crontabie — zainstaluj: make setup-autoupdate-cron"
	log "  zrob to recznie: screen -S <sesja> -X quit  &&  make screen-with-autoupdate"
	exit 0
fi

# Komunikat MUSI przezyc sesje: `screen -X quit` kasuje bufor okna razem z nia,
# wiec operator nie zobaczylby, dlaczego petla zniknela. Log straznika to
# jedyne miejsce, do ktorego zajrzy (tam laduje tez jego wskrzeszenie).
log_straznika="${AUTOUPDATE_CRON_LOG:-$REPO_DIR/.autoupdate-cron.log}"
printf '%s  autoupdate: kod petli zmieniony przez git pull — koncze sesje screen "%s", straznik podniesie ja w nowej wersji.\n' \
	"$(date '+%Y-%m-%d %H:%M:%S')" "$sesja" >> "$log_straznika" 2>/dev/null || true

log "Koncze sesje screen '$sesja' — straznik podniesie petle w nowej wersji (do 15 min)."

# LOCK LECI PRZED ZABICIEM SESJI. `screen -X quit` ubija ten proces bez szansy
# na `trap EXIT`, wiec osierocony katalog locka zatrzymalby KAZDY nastepny cykl
# komunikatem "inny cykl auto-update trwa" — auto-update bylby martwy, a jedynym
# sladem jedna linijka w logu.
trap - EXIT
lock_release

exec screen -S "$sesja" -X quit

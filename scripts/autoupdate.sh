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
# Zajety lock: inny cykl trwa albo trwa reczny deploy — nie nakladamy sie.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
	log "Inny cykl auto-update trwa (lock: $LOCK_DIR) — pomijam."
	exit 0
fi
# shellcheck disable=SC2064  # rozwiazujemy LOCK_DIR teraz, celowo
trap "rmdir '$LOCK_DIR' 2>/dev/null || true" EXIT

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
rmdir "$LOCK_DIR" 2>/dev/null || true

exec screen -S "$sesja" -X quit

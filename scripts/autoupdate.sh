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
compose_image_ids() {
	"$DOCKER" compose config --images 2>/dev/null | sort -u | while IFS= read -r img; do
		[ -n "$img" ] || continue
		printf '%s %s\n' "$img" "$("$DOCKER" image inspect --format '{{.Id}}' "$img" 2>/dev/null || echo none)"
	done
}

log "Sprawdzam obrazy (docker compose pull)..."
ids_before="$(compose_image_ids)"
"$DOCKER" compose pull 2>&1 | sed 's/^/  /' || log "OSTRZEZENIE: 'docker compose pull' zwrocil blad — porownuje mimo to."
ids_after="$(compose_image_ids)"

image_changed=0
if [ "$ids_before" != "$ids_after" ]; then
	image_changed=1
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

if [ "$git_changed" -eq 1 ]; then
	log "git pull --ff-only origin main"
	if ! "$GIT" pull --ff-only origin main; then
		log "BLAD: 'git pull --ff-only' nieudany — PRZERYWAM."
		exit 1
	fi
fi

log "make run (BPP_SKIP_HEALTH_GATE=1)"
if BPP_SKIP_HEALTH_GATE=1 "$MAKE" run; then
	log "✓ Auto-update zakonczony sukcesem."
else
	rc=$?
	log "BLAD: 'make run' zakonczony kodem $rc."
	exit "$rc"
fi

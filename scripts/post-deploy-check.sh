#!/usr/bin/env bash
#
# post-deploy-check.sh — lekka bramka zdrowia po deployu (make up / make run).
#
# Po `docker compose up --wait` (pierwszy krok `up`) healthchecked uslugi sa juz
# zdrowe — inaczej make stanalby PRZED ta bramka. Bramka lapie wiec to, co
# moglo sie zepsuc PO --wait albo czego --wait nie pilnuje:
#   - usluga `unhealthy` (flap tuz po starcie),
#   - usluga `restarting` (crash-loop, takze bez healthchecka).
#
# Read-only: NIE wysyla maili/pushy/Rollbara — te zostaja opt-in w `make doctor`.
# Bramkujemy TYLKO na stanie kontenerow, NIE na grepie bledow w logach (za duzo
# benign "error"/"failed" -> falszywe alarmy). `exited` NIE jest flagowane
# celowo: to lapaloby on-demand uslugi (backup-runner) jako falszywy problem.
#
# Zachowanie:
#   wszystko OK            -> "✓ uslugi zdrowe" + exit 0 (cicho, nie blokuje),
#   problem + stdin=TTY    -> podsumowanie + prompt [s] shell / [d] make doctor /
#                             [dowolny klawisz] wyjscie, exit 1,
#   problem + nie-TTY      -> podsumowanie + exit 1 (bez pytania — bezpieczne dla
#                             cronow/CI/`make up | tee`),
#   wlasny blad bramki     -> fail-open (exit 0), zeby nigdy nie blokowac deployu
#                             z powodu awarii samego checkera.
#
# Prompt idzie na stderr i czyta ze stdin, wiec dziala takze gdy stdout jest
# przekierowany (np. `make up | tee deploy.log`).

set -uo pipefail

# Opt-out dla wewnetrznej automatyki wolajacej `make up` pod `set -e`
# (upgrade-postgres.sh, restore.sh): transient flap zdrowia tuz po restarcie NIE
# moze przerwac ich sekwencji (np. `make up` przed `make migrate`) ani zawiesic
# promptu w TTY-bez-czlowieka. Nowy wewnetrzny wolacz `make up` -> ustaw to samo.
if [ -n "${BPP_SKIP_HEALTH_GATE:-}" ]; then
	exit 0
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MAKE="${MAKE:-make}"

# Fail-open: gdy nie umiemy nawet wejsc do repo, nie blokujemy deployu.
cd "$REPO_DIR" || {
	echo "post-deploy-check: nie moge wejsc do $REPO_DIR — pomijam bramke." >&2
	exit 0
}

# Odpytaj stan uslug. Rozrozniamy BLAD `docker compose ps` (fail-open, ale BEZ
# falszywego "zdrowe" — nie twierdzimy zdrowia, ktorego nie sprawdzilismy) od
# legalnie pustego wyniku.
ps_out="$(docker compose ps --format '{{.Service}}\t{{.State}}\t{{.Health}}' 2>/dev/null)"
ps_rc=$?
if [ "$ps_rc" -ne 0 ]; then
	echo "post-deploy-check: nie udalo sie odpytac dockera (docker compose ps exit $ps_rc)" >&2
	echo "  — pomijam bramke (fail-open); sprawdz recznie: make health" >&2
	exit 0
fi

# <service>\t<state>\t<health>. Problem = health unhealthy LUB state restarting.
problems="$(printf '%s\n' "$ps_out" \
	| awk -F'\t' '
		$3 == "unhealthy" || $2 == "restarting" {
			printf "  - %s (state=%s%s)\n", $1, $2, ($3 == "" ? "" : ", health=" $3)
		}')"

if [ -z "$problems" ]; then
	echo "✓ Wszystkie uslugi zdrowe."
	exit 0
fi

{
	echo ""
	echo "⚠ Po deployu wykryto uslugi w zlym stanie:"
	printf '%s\n' "$problems"
	echo ""
	echo "--- pelny status (make health) ---"
} >&2
"$MAKE" health >&2 || true

# Nie-TTY (CI / cron / przekierowany stdin): nie pytamy, sygnalizujemy bledem.
if [ ! -t 0 ]; then
	echo "" >&2
	echo "Deploy wstal z problemami — sprawdz recznie: make health / make doctor" >&2
	exit 1
fi

# TTY: pojedynczy prompt (s = shell, d = pelna diagnostyka, cokolwiek innego = wyjscie).
printf '\n[s] shell do debugowania · [d] pelna diagnostyka (make doctor) · [dowolny klawisz] wyjscie (auto za 30s): ' >&2
# Timeout: TTY-bez-czlowieka (ssh -t, Ansible pty, niektore CI) spelnia [ -t 0 ],
# wiec bez -t `read` wisialby w nieskonczonosc w srodku deployu. Timeout -> traktuj
# jak "dowolny klawisz" -> wyjscie z exit 1.
read -t 30 -rn1 ans || ans=""
echo >&2
case "$ans" in
	s|S) "${SHELL:-bash}" -i || true ;;
	d|D) "$MAKE" doctor || true ;;
	*)   : ;;  # dowolny inny klawisz -> wyjscie
esac

exit 1

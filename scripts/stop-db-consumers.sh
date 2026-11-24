#!/usr/bin/env bash
#
# stop-db-consumers.sh — przed `docker compose up --force-recreate` (make up)
# zatrzymuje uslugi, ktore korzystaja z bazy/redisa/pgbouncera.
#
# Po co: `up --force-recreate` odtwarza kontenery w kolejnosci zaleznosci, czyli
# NAJPIERW dbserver/redis/pgbouncer, a dopiero potem appserver i workery. Przez
# caly ten czas stare appserver/workery Celery zyja i lapia bledy polaczenia
# (`could not translate host name "dbserver"`, `Error -3 connecting to
# redis:6379`, kombu `'NoneType' object has no attribute 'hostname'` przy
# WorkerShutdown), ktore leca do Sentry/GlitchTip/Rollbara jako falszywe alarmy
# przy KAZDYM wdrozeniu. `depends_on` porzadkuje start i `down`, ale nie chroni
# przed odtworzeniem zaleznosci pod dzialajacym konsumentem.
#
# Ktore uslugi: wyliczane, nie wpisane na sztywno — wszystkie DZIALAJACE
# kontenery projektu, ktore przechodnio zaleza (`depends_on`) od dbserver, redis
# albo pgbouncer. Zaleznosci czytamy z labela `com.docker.compose.depends_on`,
# ktory Compose nadaje kontenerom. To graf ZATRZYMYWANYCH kontenerow (stara
# konfiguracja), czyli dokladnie ten, ktory trzeba zatrzymac — nowa usluga
# dopisana w compose i jeszcze nieuruchomiona nie ma czego zatrzymywac.
# Dzis wychodzi: appserver, authserver, workerserver, denorm-queue, celerybeat,
# flower, ofelia (przez appserver — przy okazji zadna nocna komenda nie trafi
# w srodek deployu) i workerserver-status, jesli akurat dziala. NIE wychodza:
# webserver (nginx ma pokazac strone serwisowa), monitoring, backup-runner,
# rclone, html2docx, motyw-kompilator — zaden nie ma depends_on na baze/redisa.
#
# Fail-open: ten krok nigdy nie blokuje deployu. Brak kontenerow (swieza
# instalacja), blad dockera albo nieudany stop = komunikat i exit 0; `up`
# robi potem to samo co przedtem.
#
# Zmienne:
#   BPP_DEPLOY_STOP_TIMEOUT  — sekundy na lagodne zamkniecie (domyslnie 30;
#                              Compose domyslnie daje 10 przy recreate). Daje
#                              workerowi Celery czas na dokonczenie krotkich
#                              zadan, ZANIM zniknie baza.
#   DOCKER                   — binarka dockera (testy).

set -uo pipefail

DOCKER="${DOCKER:-docker}"
TIMEOUT="${BPP_DEPLOY_STOP_TIMEOUT:-30}"
case "$TIMEOUT" in
	'' | *[!0-9]*)
		echo "stop-db-consumers: BPP_DEPLOY_STOP_TIMEOUT='$TIMEOUT' to nie liczba — uzywam 30." >&2
		TIMEOUT=30
		;;
esac

# Uslugi, ktore `up --force-recreate` odtwarza pod konsumentami.
ROOTS="dbserver redis pgbouncer"

ids="$("$DOCKER" compose ps -q 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ]; then
	echo "stop-db-consumers: 'docker compose ps' zakonczone kodem $rc — pomijam (deploy idzie dalej)." >&2
	exit 0
fi
if [ -z "$ids" ]; then
	echo "Brak dzialajacych kontenerow — nie ma czego zatrzymywac przed odtworzeniem."
	exit 0
fi

# <usluga>|<dep>:<warunek>:<restart>,<dep>:...
# shellcheck disable=SC2086  # lista ID, celowo dzielona na slowa
graph="$("$DOCKER" inspect --format '{{index .Config.Labels "com.docker.compose.service"}}|{{index .Config.Labels "com.docker.compose.depends_on"}}' $ids 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ]; then
	echo "stop-db-consumers: 'docker inspect' zakonczone kodem $rc — pomijam (deploy idzie dalej)." >&2
	exit 0
fi

# Domkniecie przechodnie: konsument = zalezy od korzenia albo od konsumenta.
consumers="$(printf '%s\n' "$graph" | awk -F'|' -v roots="$ROOTS" '
	$1 != "" { n++; svc[n] = $1; deps[n] = $2 }
	END {
		k = split(roots, r, " ")
		for (i = 1; i <= k; i++) inset[r[i]] = 1
		changed = 1
		while (changed) {
			changed = 0
			for (i = 1; i <= n; i++) {
				if (svc[i] in inset) continue
				m = split(deps[i], d, ",")
				for (j = 1; j <= m; j++) {
					split(d[j], parts, ":")
					if (parts[1] in inset) {
						inset[svc[i]] = 1; out[svc[i]] = 1; changed = 1
						break
					}
				}
			}
		}
		for (s in out) print s
	}' | sort -u | tr '\n' ' ')"
consumers="${consumers% }"

if [ -z "$consumers" ]; then
	echo "Brak dzialajacych konsumentow bazy/redisa — nie ma czego zatrzymywac."
	exit 0
fi

echo "Zatrzymuje konsumentow bazy/redisa przed odtworzeniem (timeout ${TIMEOUT}s): $consumers"
# shellcheck disable=SC2086  # lista uslug, celowo dzielona na slowa
if ! "$DOCKER" compose stop -t "$TIMEOUT" $consumers; then
	echo "stop-db-consumers: 'docker compose stop' nieudany — deploy idzie dalej (mozliwe falszywe bledy polaczen w Sentry)." >&2
fi
exit 0

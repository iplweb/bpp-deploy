#!/usr/bin/env bash
# ============================================================================
# configure-rate-limits.sh — interaktywne strojenie limitow nginx-a
# ============================================================================
# Pokazuje stan (CPU, ruch do appservera, odmowy 429 i opoznienia z ostatniej
# doby), pyta, ile CPU hosta BPP moze zajac w szczycie, szacuje z tego
# BPP_NGINX_GLOBAL_RATE i po kolei pyta o kazda zmienna BPP_NGINX_GLOBAL_* /
# BPP_NGINX_IP_*. Zapisuje do $BPP_CONFIGS_DIR/.env TYLKO to, co sie zmienilo
# (brak zmiennej = wartosc domyslna, ktora moze sie zmienic w nowej wersji —
# nie zamrazamy jej w .env), i proponuje `make up-webserver`.
#
# Wartosci domyslne czytamy z defaults/webserver/25-render-bpp-limits.sh —
# jedno zrodlo, zeby kreator nie rozjechal sie z tym, co renderuje nginx.
#
# Szacunek RATE: (CPU kontenerow tej instalacji / rdzenie) / (zadania/s do
# appservera w ostatniej minucie) = koszt 1 r/s. Liczy tez narzut niezalezny
# od ruchu (workery, netdata), wiec ZAWYZA koszt -> propozycja jest
# ostrozna. Przy malym ruchu (< 3 r/s) szacunku nie ma — uruchom w szczycie.
#
# BPP_RLC_FIXTURES: katalog z plikami zamiast dockera/hosta — tylko dla
# testow (test_configure_rate_limits w tests/test_makefile.sh). Wtedy
# `make up-webserver` jest tylko wypisywane, nie uruchamiane.
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RENDER="$REPO_DIR/defaults/webserver/25-render-bpp-limits.sh"
FX="${BPP_RLC_FIXTURES:-}"

# shellcheck source=scripts/lib-nginx-limit-log.sh
. "$REPO_DIR/scripts/lib-nginx-limit-log.sh"

if [ -z "$FX" ] && [ ! -t 0 ]; then
	echo "BLAD: kreator jest interaktywny — uruchom go w terminalu (make configure-rate-limits)." >&2
	exit 1
fi

# --- .env -------------------------------------------------------------------
if [ -z "${BPP_CONFIGS_DIR:-}" ] && [ -f "$REPO_DIR/.env" ]; then
	# shellcheck disable=SC1091
	. "$REPO_DIR/.env"
fi
if [ -z "${BPP_CONFIGS_DIR:-}" ] || [ ! -f "$BPP_CONFIGS_DIR/.env" ]; then
	echo "BLAD: brak \$BPP_CONFIGS_DIR/.env. Uruchom najpierw 'make init-configs'." >&2
	exit 1
fi
ENV_FILE="$BPP_CONFIGS_DIR/.env"

env_has_var() {
	grep -q "^${1}=" "$ENV_FILE" 2>/dev/null
}

get_env_var() {
	local raw
	raw="$(grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
	raw="${raw%$'\r'}"
	raw="${raw#\"}"; raw="${raw%\"}"
	raw="${raw#\'}"; raw="${raw%\'}"
	printf '%s' "$raw"
}

set_env_var() {
	local var_name="$1" value="$2"
	if env_has_var "$var_name"; then
		local tmp="$ENV_FILE.tmp.$$"
		awk -v k="$var_name" -v v="$value" '
			BEGIN { FS=OFS="=" }
			$1 == k { print k "=" v; next }
			{ print }
		' "$ENV_FILE" > "$tmp" && mv "$tmp" "$ENV_FILE"
		echo "  ~ ${var_name}=${value}"
	else
		echo "${var_name}=${value}" >> "$ENV_FILE"
		echo "  + ${var_name}=${value}"
	fi
}

# --- wartosci domyslne z 25-render-bpp-limits.sh ------------------------------
domyslna() {
	local v
	v="$(sed -n "s/^.*liczba_lub_domyslna $1 \([0-9][0-9]*\)).*$/\1/p" "$RENDER")"
	if [ -z "$v" ]; then
		echo "BLAD: nie znalazlem wartosci domyslnej $1 w $RENDER." >&2
		exit 1
	fi
	printf '%s' "$v"
}

ZMIENNE="BPP_NGINX_GLOBAL_RATE BPP_NGINX_GLOBAL_BURST BPP_NGINX_GLOBAL_CONN BPP_NGINX_IP_RATE BPP_NGINX_IP_BURST BPP_NGINX_IP_QUEUE"

opis_zmiennej() {
	case "$1" in
		BPP_NGINX_GLOBAL_RATE)  echo "zadan/s do appservera LACZNIE ze wszystkich IP (0 = bez limitu)" ;;
		BPP_NGINX_GLOBAL_BURST) echo "szpila ponad GLOBAL_RATE obslugiwana od reki" ;;
		BPP_NGINX_GLOBAL_CONN)  echo "zadan do appservera obslugiwanych NARAZ (chroni baze)" ;;
		BPP_NGINX_IP_RATE)      echo "zadan/s z JEDNEGO IP w dluzszym okresie — powyzej klient czeka (0 = wylacz)" ;;
		BPP_NGINX_IP_BURST)     echo "ile ponad IP_RATE z jednego IP idzie od reki (otwarcie strony = kilkanascie)" ;;
		BPP_NGINX_IP_QUEUE)     echo "ile kolejnych CZEKA w kolejce tego IP zamiast dostac 429 (0 = od razu 429)" ;;
	esac
}

# Aktualna wartosc efektywna: z .env, a gdy brak/pusta/smiec — domyslna
# (dokladnie tak, jak traktuje ja 25-render-bpp-limits.sh).
aktualna() {
	local v
	v="$(get_env_var "$1" | tr -d '[:space:]')"
	case "$v" in
		""|*[!0-9]*) domyslna "$1" ;;
		*) printf '%s' "$((10#$v))" ;;
	esac
}

# --- zrodla danych ------------------------------------------------------------
kontener() {  # ID dzialajacego kontenera uslugi tej instalacji
	(cd "$REPO_DIR" && docker compose ps -q "$1" 2>/dev/null | sed -n '1p')
}

rdzenie() {
	if [ -n "$FX" ]; then cat "$FX/ncpu.txt"; return; fi
	nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1
}

obciazenie() {  # load average 1 min
	if [ -n "$FX" ]; then cat "$FX/loadavg.txt"; return; fi
	if [ -r /proc/loadavg ]; then
		awk '{print $1}' /proc/loadavg
	else
		sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}'
	fi
}

statystyki_cpu() {  # "nazwa<TAB>12.34%" dla kontenerow tej instalacji
	if [ -n "$FX" ]; then cat "$FX/docker-stats.txt"; return; fi
	local ids
	ids="$(cd "$REPO_DIR" && docker compose ps -q 2>/dev/null)" || true
	[ -n "$ids" ] || return 0
	# shellcheck disable=SC2086  # lista ID — celowo rozbijana
	docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}' $ids 2>/dev/null || true
}

logi_webservera() {  # $1 = okno --since, $2 = access|error
	if [ -n "$FX" ]; then cat "$FX/$2-$1.log"; return; fi
	local id
	id="$(kontener webserver)"
	[ -n "$id" ] || return 0
	if [ "$2" = access ]; then
		docker logs "$id" --since "$1" 2>/dev/null
	else
		docker logs "$id" --since "$1" 2>&1
	fi
}

# Access log -> "zadan_do_appservera szczyt_na_minute". Do appservera NIE
# dochodza statyki/media/healthz ani to, co nginx odrzucil sam (429/444).
ruch_do_appservera() {
	LC_ALL=C awk '
	$1 !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $1 !~ /^[0-9A-Fa-f]*:[0-9A-Fa-f:.]*$/ { next }
	{
		split($0, q, "\""); split(q[3], st, " ")
		if (st[1] == "429" || st[1] == "444") next
		if ($7 ~ /^\/(static|media)\// || $7 ~ /^\/healthz/) next
		n++; m[substr($4, 2, 17)]++
	}
	END { for (k in m) if (m[k] > max) max = m[k]; printf "%d %d\n", n, max }'
}

# Access log (format bpp_access) -> "mediana_s ile": mediana
# $upstream_response_time odpowiedzi 200 z appservera — realny czas obslugi
# zadania na TEJ maszynie, z prawdziwego miksu ruchu, bez dokladania
# obciazenia. Pola za "$request": status bajty dl_zadania request_time
# upstream_response_time ("-" = nie doszlo do appservera, np. statyk).
mediana_czasu_appservera() {
	LC_ALL=C awk '
	$1 !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $1 !~ /^[0-9A-Fa-f]*:[0-9A-Fa-f:.]*$/ { next }
	{ split($0, q, "\""); split(q[3], st, " ")
	  if (st[1] == "200" && st[5] ~ /^[0-9.]+,?$/) print st[5] + 0 }' | sort -n \
	| LC_ALL=C awk '{ v[NR] = $1 } END { if (NR) printf "%.3f %d\n", v[int((NR + 1) / 2)], NR }'
}

# --- pomiar -------------------------------------------------------------------
echo ""
echo "================================================================"
echo "  Limity ruchu nginx-a (BPP_NGINX_GLOBAL_* / BPP_NGINX_IP_*)"
echo "================================================================"
echo "Mierze... (kilka sekund)"

NCPU="$(rdzenie)"
LOAD="$(obciazenie)"
STATY="$(statystyki_cpu)"
read -r RUCH_MIN _ <<<"$(logi_webservera 60s access | ruch_do_appservera)"
read -r _ SZCZYT_MIN <<<"$(logi_webservera 24h access | ruch_do_appservera)"
ZDARZENIA="$(logi_webservera 24h error | nginx_limit_events)"

# CPU kontenerow tej instalacji jako % CALEGO hosta (docker stats: 100% = 1 rdzen)
CPU_HOST="$(printf '%s\n' "$STATY" | LC_ALL=C awk -F'\t' -v n="$NCPU" '{ gsub(/%/, "", $2); s += $2 } END { printf "%.0f", s / n }')"
CPU_TOP="$(printf '%s\n' "$STATY" | LC_ALL=C awk -F'\t' -v n="$NCPU" '
	$1 != "" { gsub(/%/, "", $2); printf "%s %.0f\n", $1, $2 / n }' | sort -k2,2rn | sed -n '1,3p' \
	| awk '{ n = $1; sub(/-[0-9]+$/, "", n); sub(/^.*-/, "", n); printf "%s%s %s%%", (NR > 1 ? "   " : ""), n, $2 }')"
RPS_TERAZ="$(LC_ALL=C awk -v n="$RUCH_MIN" 'BEGIN { printf "%.1f", n / 60 }')"
RPS_SZCZYT="$(LC_ALL=C awk -v n="$SZCZYT_MIN" 'BEGIN { printf "%.1f", n / 60 }')"

echo ""
echo "== Stan teraz =="
echo "CPU kontenerow BPP: ${CPU_HOST}% hosta (load ${LOAD} / ${NCPU} rdzeni)"
[ -n "$CPU_TOP" ] && echo "  najwiecej: ${CPU_TOP}"
echo "Ruch do appservera: ${RPS_TERAZ} r/s (ostatnia minuta), szczyt doby ${RPS_SZCZYT} r/s (srednia z minuty)"

echo ""
echo "== Ostatnie 24h =="
if [ -z "$ZDARZENIA" ]; then
	echo "Brak odmow 429 i opoznien — limity nikogo nie dotknely."
else
	printf '%s\n' "$ZDARZENIA" | LC_ALL=C awk -F'\t' '
	$1 == "odmowa" { n++; ip[$3]++ }
	$1 == "opoznienie" { d++; dip[$3]++ }
	END {
		for (i in ip) { ni++; if (ip[i] > max) { max = ip[i]; top = i } }
		for (i in dip) nd++
		printf "Odmowy 429: %d dla %d roznych IP\n", n, ni
		if (ni > 1 && 2 * max >= n) {
			printf "  glowny winowajca: %s (%.1f%% odmow)\n", top, 100 * max / n
			printf "  wyrzuceni rykoszetem (bez winowajcy): %d IP, %d zadan\n", ni - 1, n - max
		}
		printf "Spowolnieni (czekali w kolejce, bez bledu): %d zadan od %d IP\n", d, nd
	}'
	echo "  (szczegoly: make rate-limit-stats)"
fi

# --- szacunek RATE z CPU --------------------------------------------------------
odpowiedz() {  # $1 = pytanie, $2 = domyslna; wynik w $ODP
	local x
	printf '%s [%s] > ' "$1" "$2"
	if ! IFS= read -r x; then
		echo ""
		echo "Przerwano (koniec wejscia) — nic nie zapisano."
		exit 1
	fi
	ODP="${x:-$2}"
}

liczba() {  # pytanie, domyslna -> $ODP jako liczba calkowita >= 0
	while true; do
		odpowiedz "$1" "$2"
		ODP="$(printf '%s' "$ODP" | tr -d '[:space:]')"
		case "$ODP" in
			""|*[!0-9]*) echo "  podaj liczbe calkowita >= 0" ;;
			*) ODP=$((10#$ODP)); return ;;
		esac
	done
}

echo ""
SUG_RATE=""
if LC_ALL=C awk -v r="$RUCH_MIN" -v c="$CPU_HOST" 'BEGIN { exit !(r >= 180 && c > 0) }'; then
	while true; do
		liczba "Ile CPU hosta moze zajac BPP w szczycie? (%)" 80
		[ "$ODP" -ge 1 ] && [ "$ODP" -le 100 ] && break
		echo "  podaj procent 1-100"
	done
	CEL="$ODP"
	read -r KOSZT SUG_RATE <<<"$(LC_ALL=C awk -v c="$CPU_HOST" -v r="$RPS_TERAZ" -v cel="$CEL" 'BEGIN {
		k = c / r; s = int(cel / k); if (s < 5) s = 5; if (s > 1000) s = 1000
		printf "%.2f %d\n", k, s }')"
	echo " -> szacunek: 1 r/s ~ ${KOSZT}% CPU hosta => BPP_NGINX_GLOBAL_RATE ~ ${SUG_RATE}"
	echo "    (ostroznie: koszt zawiera tez prace niezalezna od ruchu)"
else
	echo "Ruch w ostatniej minucie jest za maly (${RPS_TERAZ} r/s), zeby oszacowac koszt"
	echo "1 r/s z obserwowanego CPU."
	read -r MEDIANA ILE <<<"$(logi_webservera 24h access | mediana_czasu_appservera)"
	if [ -n "${MEDIANA:-}" ] && LC_ALL=C awk -v m="$MEDIANA" -v n="$ILE" 'BEGIN { exit !(m > 0 && n >= 100) }'; then
		# Rdzenie dla appservera = jego limit CPU (domyslnie 2.0, jak w compose),
		# nie wiecej niz host. Czas odpowiedzi to CPU + czekanie na baze, wiec
		# pojemnosc wychodzi ZANIZONA — i jeszcze 30% zapasu na workery i admina.
		APP_CPU="$(get_env_var APPSERVER_CPU_LIMIT | tr -d '[:space:]')"
		read -r POJEMNOSC SUG_RATE <<<"$(LC_ALL=C awk -v t="$MEDIANA" -v c="${APP_CPU:-2.0}" -v n="$NCPU" 'BEGIN {
			if (c + 0 <= 0 || c + 0 > n) c = n
			p = c / t; s = int(0.7 * p); if (s < 5) s = 5; if (s > 1000) s = 1000
			printf "%.0f %d\n", p, s }')"
		echo "Z access logu doby: mediana czasu obslugi przez appserver ${MEDIANA} s (${ILE} odpowiedzi 200)."
		echo " -> appserver (${APP_CPU:-2.0} CPU) wyciagnie ok. ${POJEMNOSC} r/s => BPP_NGINX_GLOBAL_RATE ~ ${SUG_RATE} (70%)"
		echo "    (orientacyjnie; trafniej dziala kreator uruchomiony w szczycie ruchu)"
	else
		echo "Za malo danych w access logu, zeby oszacowac koszt zadania —"
		echo "uruchom kreator w szczycie ruchu albo po dobie dzialania."
	fi
fi

# --- pytania o zmienne --------------------------------------------------------
echo ""
echo "Enter = wartosc w nawiasie."
declare -a NOWE=()
for v in $ZMIENNE; do
	akt="$(aktualna "$v")"
	prop="$akt"
	if [ "$v" = BPP_NGINX_GLOBAL_RATE ] && [ -n "$SUG_RATE" ]; then
		prop="$SUG_RATE"
	fi
	# BURST nadaza za RATE (~10 s szczytu), jesli RATE zmieniono z kreatora
	if [ "$v" = BPP_NGINX_GLOBAL_BURST ] && [ "${NOWA_GLOBAL_RATE:-}" != "$(aktualna BPP_NGINX_GLOBAL_RATE)" ] && [ "${NOWA_GLOBAL_RATE:-0}" -gt 0 ]; then
		prop=$((NOWA_GLOBAL_RATE * 10))
	fi
	echo ""
	echo "${v} — $(opis_zmiennej "$v")"
	echo "  teraz: ${akt}$(env_has_var "$v" || printf ' (domyslna)')"
	liczba "  nowa" "$prop"
	[ "$v" = BPP_NGINX_GLOBAL_RATE ] && NOWA_GLOBAL_RATE="$ODP"
	NOWE+=("$v=$ODP")
done

# --- podsumowanie i zapis ---------------------------------------------------------
echo ""
echo "== Zmiany =="
declare -a DO_ZAPISU=()
for para in "${NOWE[@]}"; do
	v="${para%%=*}"; n="${para#*=}"; akt="$(aktualna "$v")"
	if [ "$n" != "$akt" ]; then
		echo "  ${v}: ${akt} -> ${n}"
		DO_ZAPISU+=("$para")
	fi
done
if [ "${#DO_ZAPISU[@]}" -eq 0 ]; then
	echo "  (brak — nic nie zapisuje)"
	exit 0
fi

odpowiedz "Zapisac do ${ENV_FILE}? (T/n)" T
case "$ODP" in
	[Nn]*) echo "Nic nie zapisano."; exit 0 ;;
esac
for para in "${DO_ZAPISU[@]}"; do
	set_env_var "${para%%=*}" "${para#*=}"
done

echo ""
echo "Nowe wartosci dzialaja dopiero po restarcie nginx-a (sam webserver, ~1-2 s przerwy)."
odpowiedz "Zrobic teraz make up-webserver? (T/n)" T
case "$ODP" in
	[Nn]*) echo "Pozniej: make up-webserver (albo make up)."; exit 0 ;;
esac
if [ -n "$FX" ]; then
	echo "(fixture) make up-webserver"
	exit 0
fi
make -C "$REPO_DIR" up-webserver
id="$(kontener webserver)"
if [ -n "$id" ]; then
	docker logs "$id" --since 2m 2>&1 | grep '25-render-bpp-limits' || true
fi

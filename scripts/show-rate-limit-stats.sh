#!/usr/bin/env bash
# ============================================================================
# show-rate-limit-stats.sh — KTÓRY limit nginx-a odrzuca żądania (429) i kogo
# ============================================================================
# Czyta error log nginx-a (stderr kontenera webserver) i zlicza komunikaty
# `limiting requests` (limit_req) i `limiting connections` (limit_conn).
# Tylko tam widać NAZWĘ STREFY — access log (make request-stats) ma sam status
# 429, z którego nie odróżnisz limitu per-IP od globalnego. A od strefy zależy,
# co stroić:
#
#   bpp_global        globalne tempo        BPP_NGINX_GLOBAL_RATE / _BURST (.env)
#   bpp_global_conn   globalna równoległość BPP_NGINX_GLOBAL_CONN (.env)
#   bpp_ip_slow       spowalnianie per IP   BPP_NGINX_IP_* (.env) — tu obok odmow
#                     sa tez OPOZNIENIA: zadanie czekalo w kolejce, ale przeszlo
#   bpp_general/api/admin  per-IP           defaults/webserver/* (NIE .env)
#
# Kolumna "top IP %" = udział najbardziej odrzucanego IP w strefie. Globalna
# pula jest JEDNA dla wszystkich IP i vhostów: gdy jeden klient ma w niej
# ~100% odmów, to on ją zjada, a 429 u reszty jest skutkiem ubocznym —
# podniesienie limitu dałoby mu tylko więcej przepustowości do bazy.
#
# Parser linii error logu: scripts/lib-nginx-limit-log.sh (wspolny
# z make configure-rate-limits).
#
# Knoby (zmienne środowiskowe):
#   SINCE=24h          okno `docker logs --since` (np. 72h, 7d, 2026-10-16)
#   TOP=15             ile wierszy w tabelach IP i ścieżek
#   SERVICE=webserver  nazwa serwisu compose
#   RESOLVE=1          dopisz do IP reverse DNS i właściciela bloku
#                      (scripts/lib-ip-resolve.sh, jak w request-stats)
#
# Przykłady:
#   make rate-limit-stats
#   SINCE=7d TOP=30 RESOLVE=1 make rate-limit-stats
# ============================================================================
set -euo pipefail

SINCE="${SINCE:-24h}"
TOP="${TOP:-15}"
SERVICE="${SERVICE:-webserver}"
RESOLVE="${RESOLVE:-0}"

CONTAINERS=()
# BPP_DIAG_FIXTURES: zamiast `docker logs` czyta webserver-error.log z tego
# katalogu. Tylko dla testow (test_diag_db_commands w tests/test_makefile.sh).
if [ -n "${BPP_DIAG_FIXTURES:-}" ]; then
	CONTAINERS=(fixture)
	docker() { cat "$BPP_DIAG_FIXTURES/webserver-error.log"; }
else
	while IFS= read -r _name; do
		[ -n "$_name" ] && CONTAINERS+=("$_name")
	done < <(docker ps --filter "label=com.docker.compose.service=${SERVICE}" --format '{{.Names}}')
fi

if [ "${#CONTAINERS[@]}" -eq 0 ]; then
	echo "BLAD: nie znaleziono uruchomionego kontenera serwisu '${SERVICE}'." >&2
	echo "      (docker ps --filter label=com.docker.compose.service=${SERVICE})" >&2
	echo "      Czy stack dziala? Sprawdz: make ps" >&2
	exit 1
fi

# shellcheck source=scripts/lib-nginx-limit-log.sh
. "$(dirname "$0")/lib-nginx-limit-log.sh"

# Error log ze stdin -> zdarzenia (nginx_limit_events) -> tabele. Sekcje
# sortowane przez `sort` w potoku awk; fflush() przed kazdym, inaczej bufor
# awk i wyjscie sorta sie przeplataja. Tabele IP/vhost/sciezek licza ODMOWY
# (429); opoznienia (kolejka per IP) maja wlasna tabele — to nie byl blad
# dla klienta, tylko wolniejsza odpowiedz.
analyze() {
	local top="$1"
	# LC_ALL=C: printf %.1f w polskim locale daje "80,0", a sort porownuje inaczej
	nginx_limit_events | LC_ALL=C awk -F'\t' -v top="$top" '
	function sekcja(naglowek){ fflush(); printf "\n%s\n", naglowek; fflush() }
	{
		rodzaj=$1; zone=$2; ip=$3; host=$4; path=$5; hour=$6
		events++; zall[zone]=1; hh[hour]=1
		if(rodzaj=="opoznienie"){
			delays++; zd[zone]++; idel[ip]++; hd[hour]++
			next
		}
		grupa=(zone=="bpp_global")?"glob":(zone=="bpp_global_conn")?"conn":"perip"
		total++
		z[zone]++; zi[zone SUBSEP ip]++
		ipc[ip]++; ipz[ip SUBSEP zone]++
		hc[host]++; pc[path]++
		hr[hour]++; hg[hour SUBSEP grupa]++
	}
	END{
		if(!events) exit
		opis["bpp_global"]="globalne tempo -> BPP_NGINX_GLOBAL_RATE/_BURST (.env)"
		opis["bpp_global_conn"]="globalna rownoleglosc -> BPP_NGINX_GLOBAL_CONN (.env)"
		opis["bpp_ip_slow"]="spowalnianie per IP -> BPP_NGINX_IP_* (.env)"
		opis["bpp_general"]="per-IP, reszta (defaults/webserver/*, nie .env)"
		opis["bpp_api"]="per-IP, /api/ (defaults/webserver/*, nie .env)"
		opis["bpp_admin"]="per-IP, /admin/ (defaults/webserver/*, nie .env)"

		for(k in zi){ split(k, a, SUBSEP); zn[a[1]]++
			if(zi[k]>zmax[a[1]]){ zmax[a[1]]=zi[k]; ztop[a[1]]=a[2] } }

		sekcja("== wg strefy ==   odmow | opoznien |  IP | top IP % | strefa")
		cmd="sort -k1,1rn -k2,2rn"
		for(s in zall){
			proc=(z[s]>0) ? sprintf("%7.1f%%", 100*zmax[s]/z[s]) : "       -"
			printf "   %8d %9d %5d %s   %-16s %s\n", z[s], zd[s], zn[s], proc, s, (s in opis)?opis[s]:"" | cmd
		}
		close(cmd)

		if(total){
			sekcja("== top IP (odmowy 429) ==   odmow | strefa (najwiecej odmow) | IP")
			for(k in ipz){ split(k, a, SUBSEP); if(ipz[k]>imax[a[1]]){ imax[a[1]]=ipz[k]; izone[a[1]]=a[2] } }
			cmd="sort -k1,1rn | awk -v t=" top " \"NR<=t\""
			for(i in ipc) printf "   %8d   %-16s   %s\n", ipc[i], izone[i], i | cmd
			close(cmd)

			sekcja("== odmowy wg vhosta (naglowek Host) ==   odmow | host")
			cmd="sort -k1,1rn"
			for(h in hc) printf "   %8d   %s\n", hc[h], h | cmd
			close(cmd)

			sekcja("== najczesciej odrzucane sciezki (bez ?query) ==   odmow | sciezka")
			cmd="sort -k1,1rn | awk -v t=" top " \"NR<=t\""
			for(p in pc) printf "   %8d   %s\n", pc[p], p | cmd
			close(cmd)
		}

		if(delays){
			sekcja("== spowolnieni (czekali w kolejce, NIE odrzuceni) ==   opoznien | IP")
			cmd="sort -k1,1rn | awk -v t=" top " \"NR<=t\""
			for(i in idel) printf "   %8d   %s\n", idel[i], i | cmd
			close(cmd)
		}

		sekcja("== godzinowo ==   odmow | glob | conn | per-IP | opoznien | godzina")
		cmd="sort -k6,7"
		for(h in hh) printf "   %8d %6d %6d %8d %10d   %s\n", hr[h], hg[h SUBSEP "glob"], hg[h SUBSEP "conn"], hg[h SUBSEP "perip"], hd[h], h | cmd
		close(cmd)

		# Wniosek dla stref globalnych: jeden klient zjada wspolna pule.
		fflush()
		for(s in z) if((s=="bpp_global" || s=="bpp_global_conn") && zn[s]>1 && 2*zmax[s]>=z[s])
			printf "\nUWAGA: %.1f%% odmow w strefie %s to jeden IP (%s). Ten klient zjada\n" \
				"wspolna pule; 429 u pozostalych %d IP to skutek uboczny. Podniesienie limitu\n" \
				"da mu tylko wiecej przepustowosci do bazy — przyhamuj go spowalnianiem\n" \
				"per IP (BPP_NGINX_IP_*, make configure-rate-limits) i ustal, co to jest\n" \
				"(RESOLVE=1, sciezki wyzej, godziny = cron?).\n", 100*zmax[s]/z[s], s, ztop[s], zn[s]-1
	}'
}

# shellcheck source=scripts/lib-ip-resolve.sh
. "$(dirname "$0")/lib-ip-resolve.sh"

for c in "${CONTAINERS[@]}"; do
	echo "############################################################"
	echo "# kontener: ${c}   (okno: --since ${SINCE})"
	echo "############################################################"
	# 2>&1: error log nginx-a to STDERR kontenera; stdout (access log) odsiewa
	# wzorzec w analyze(). Status `docker logs` z PIPESTATUS, zeby blad odczytu
	# nie udawal "brak odmow".
	tmpout="$(mktemp)"
	set +e
	docker logs "$c" --since "$SINCE" 2>&1 | analyze "$TOP" >"$tmpout"
	dl_status=${PIPESTATUS[0]}
	set -e
	if [ "$dl_status" -ne 0 ]; then
		echo "  (BLAD: nie udalo sie odczytac logow kontenera ${c} — pomijam)" >&2
	elif grep -q '[^[:space:]]' "$tmpout"; then
		if [ "$RESOLVE" = "1" ]; then
			resolve_annotate "$tmpout"
		else
			cat "$tmpout"
		fi
	else
		echo "  (brak odmow ani opoznien limitow w oknie --since ${SINCE})"
	fi
	rm -f "$tmpout"
	echo
done

echo "Strefy bpp_global* i bpp_ip_slow: make configure-rate-limits (albo .env + make up)."
echo "Strefy per-IP: wersjonowane pliki defaults/webserver/ — docs/architektura/rate-limiting.md"
[ "$RESOLVE" = "1" ] || echo "Kto to jest? RESOLVE=1 make rate-limit-stats (PTR + AS/wlasciciel bloku)."

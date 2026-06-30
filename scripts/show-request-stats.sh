#!/usr/bin/env bash
# ============================================================================
# show-request-stats.sh — szczytowy req/s per IP (admin / api / reszta)
# ============================================================================
# Czyta access log nginx-a (format bpp_access) wprost z `docker logs` kontenera
# webserver i liczy DLA KAŻDEGO IP najwyższą liczbę żądań w jednej sekundzie
# (peak req/s) — czyli dokładnie tę liczbę, którą musi przebić limit nginx
# `limit_req ... rate=`.
#
# Po co: dobór limitów requestów BEZ zgadywania. Patrzysz, ile realnie wyciska
# najgrubszy LEGALNY klient (zwykle Wasz publiczny zakres/uczelnia albo
# wewnętrzne integracje 10.x), i ustawiasz `rate` z zapasem ponad to.
#
# Źródło = stdout kontenera (`access_log /dev/stdout`); stderr (error_log)
# odcinamy przez `2>/dev/null`, więc liczą się wyłącznie linie accessu.
# Na hoście z kilkoma instalacjami BPP leci po każdym kontenerze webserver
# osobno (matchowanie po labelu compose).
#
# Knoby (zmienne środowiskowe):
#   SINCE=72h          okno `docker logs --since` (np. 24h, 7d, 2026-06-29)
#   TOP=15             ile IP pokazać w każdej tabeli
#   SERVICE=webserver  nazwa serwisu compose (gdyby się kiedyś zmieniła)
#
# Ograniczenia (to heurystyka do doboru limitów, nie księgowość):
#   - SINCE jest ograniczone retencją `docker logs` (driver `local`,
#     ~max-size × max-file). Na ruchliwym hoście starsza część okna mogła się
#     już zrotować -> peak bywa NIEDOSZACOWANY (ostrożnie z ustawianiem rate
#     za nisko na tej podstawie; dla pewności weź krótsze, gęstsze okno).
#   - nginx loguje linię w momencie ZAKOŃCZENIA requestu, więc znaczniki czasu
#     nie są ściśle monotoniczne pod obciążeniem -> peak/s bywa lekko zaniżony.
#
# Przykłady:
#   make request-stats
#   SINCE=24h TOP=30 make request-stats
# ============================================================================
set -euo pipefail

SINCE="${SINCE:-72h}"
TOP="${TOP:-15}"
SERVICE="${SERVICE:-webserver}"

# Kontener(y) webservera po labelu compose. >1 = host z wieloma instalacjami BPP.
CONTAINERS=()
while IFS= read -r _name; do
	[ -n "$_name" ] && CONTAINERS+=("$_name")
done < <(docker ps --filter "label=com.docker.compose.service=${SERVICE}" --format '{{.Names}}')

if [ "${#CONTAINERS[@]}" -eq 0 ]; then
	echo "BLAD: nie znaleziono uruchomionego kontenera serwisu '${SERVICE}'." >&2
	echo "      (docker ps --filter label=com.docker.compose.service=${SERVICE})" >&2
	echo "      Czy stack dziala? Sprawdz: make ps" >&2
	exit 1
fi

# Parsuje access log ze stdin -> 3 tabele (admin/api/rest), TOP IP wg peak req/s.
# Tieruje po prefiksie sciezki ($7 = $request rozbity po spacji). Pamiec trzyma
# w ryzach: log jest chronologiczny, wiec licznik "tej sekundy" flushujemy gdy
# znacznik czasu sie zmieni (split("",cur) = przenosne czyszczenie tablicy).
analyze() {
	local top="$1"
	awk '
	function flush(   k){ for(k in cur){ if(cur[k]>peak[k]) peak[k]=cur[k] }; split("",cur) }
	{
		sec=substr($4,2)                 # 30/Jun/2026:18:53:12  (bez wiodacego "[")
		if(sec!=now){ if(now!="") flush(); now=sec }
		ip=$1; path=$7                   # $remote_addr ... "$request" -> $7 = sciezka
		tier=(path ~ /^\/api\//)?"api":(path ~ /^\/admin\//)?"admin":"rest"
		k=tier SUBSEP ip
		cur[k]++; tot[k]++
	}
	END{
		flush()
		for(k in peak){ split(k,a,SUBSEP); print a[1], peak[k], tot[k], a[2] }
	}' \
	| sort -k1,1 -k2,2rn \
	| awk -v top="$top" '
	{ if($1!=t){ printf "\n== %-5s ==  peak_req/s | total | IP\n", $1; t=$1; n=0 }
	  if(++n<=top) printf "   %8d   %8d   %s\n",$2,$3,$4 }'
}

for c in "${CONTAINERS[@]}"; do
	echo "############################################################"
	echo "# kontener: ${c}   (okno: --since ${SINCE})"
	echo "############################################################"
	# Strumieniujemy logi przez awk (pamieciowo bezpieczne — surowe logi nie laduja
	# do zmiennej). errexit chwilowo OFF, by zlapac status `docker logs` z
	# PIPESTATUS i ODROZNIC realny blad odczytu od pustego okna (zamiast cicho
	# raportowac "brak ruchu", co moglo zmylic przy doborze rate).
	tmpout="$(mktemp)"
	set +e
	docker logs "$c" --since "$SINCE" 2>/dev/null | analyze "$TOP" >"$tmpout"
	dl_status=${PIPESTATUS[0]}
	set -e
	if [ "$dl_status" -ne 0 ]; then
		echo "  (BLAD: nie udalo sie odczytac logow kontenera ${c} — pomijam)" >&2
	elif grep -q '[^[:space:]]' "$tmpout"; then
		cat "$tmpout"
	else
		echo "  (brak ruchu w oknie --since ${SINCE})"
	fi
	rm -f "$tmpout"
	echo
done

echo "Wskazowka: 'rate' ustaw z zapasem nad najwyzszym LEGALNYM peakiem"
echo "(zignoruj oczywiste scrapery — pojedyncze chmurowe IP z total ~= peak)."

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
# Kolumny 429/444 = odmowy dla danego IP w oknie:
#   429  limit_req/limit_conn (per-IP ALBO globalny limit do appservera)
#   444  zerwane bez odpowiedzi: WAF (ModSecurity) i blokady brzegu
# Osobna tabela "odmowy" listuje IP z najwiekszą liczbą 429 niezależnie od
# peak — scraper ucięty limitem nie musi być w czołówce tabel peak/s.
#
# Knoby (zmienne środowiskowe):
#   SINCE=72h          okno `docker logs --since` (np. 24h, 7d, 2026-06-29)
#   TOP=15             ile IP pokazać w każdej tabeli
#   SERVICE=webserver  nazwa serwisu compose (gdyby się kiedyś zmieniła)
#   RESOLVE=1          dopisz do IP reverse DNS (PTR) i właściciela bloku
#                      (AS, kraj, nazwa — Team Cymru). Wymaga sieci i `whois`
#                      lub `dig`; bez nich kolumny zostają puste ("-").
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
#   RESOLVE=1 make request-stats
# ============================================================================
set -euo pipefail

SINCE="${SINCE:-72h}"
TOP="${TOP:-15}"
SERVICE="${SERVICE:-webserver}"
RESOLVE="${RESOLVE:-0}"

# Kontener(y) webservera po labelu compose. >1 = host z wieloma instalacjami BPP.
CONTAINERS=()
# BPP_DIAG_FIXTURES: zamiast `docker logs` czyta webserver.log z tego katalogu.
# Tylko dla testow (test_diag_db_commands) — patrz scripts/lib-diag.sh.
if [ -n "${BPP_DIAG_FIXTURES:-}" ]; then
	CONTAINERS=(fixture)
	docker() { cat "$BPP_DIAG_FIXTURES/webserver.log"; }
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

# Parsuje access log ze stdin -> 3 tabele (admin/api/rest), TOP IP wg peak req/s.
# Tieruje po prefiksie sciezki ($7 = $request rozbity po spacji). Pamiec trzyma
# w ryzach: log jest chronologiczny, wiec licznik "tej sekundy" flushujemy gdy
# znacznik czasu sie zmieni (split("",cur) = przenosne czyszczenie tablicy).
analyze() {
	local top="$1"
	awk '
	function flush(   k){ for(k in cur){ if(cur[k]>peak[k]) peak[k]=cur[k] }; split("",cur) }
	# Tylko linie accessu: $1 musi byc adresem IPv4/IPv6. Na stdout leca tez
	# komunikaty startowe obrazu ("20-envsubst-on-templates.sh: ...",
	# "/docker-entrypoint.sh: ...") i bez tego filtra ladowaly w tabeli jako
	# "IP". Bez {1,3}: stary mawk nie zna interwalow w regexach.
	$1 !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $1 !~ /^[0-9A-Fa-f]*:[0-9A-Fa-f:.]*$/ { next }
	{
		sec=substr($4,2)                 # 30/Jun/2026:18:53:12  (bez wiodacego "[")
		if(sec!=now){ if(now!="") flush(); now=sec }
		ip=$1; path=$7                   # $remote_addr ... "$request" -> $7 = sciezka
		# Status = pierwsze slowo za zamykajacym " requestu. Nie $9: zepsuty
		# request ze spacjami przesuwa pola, a " w nim nginx escapuje (\x22).
		split($0,q,"\""); split(q[3],st," "); status=st[1]
		tier=(path ~ /^\/api\//)?"api":(path ~ /^\/admin\//)?"admin":"rest"
		k=tier SUBSEP ip
		cur[k]++; tot[k]++
		if(status=="429"){ r429[k]++; i429[ip]++ }
		if(status=="444"){ r444[k]++; i444[ip]++ }
		itot[ip]++
	}
	END{
		flush()
		# 1. pole = klucz sortowania sekcji (kolejnosc: admin, api, rest, odmowy)
		ord["admin"]=1; ord["api"]=2; ord["rest"]=3
		for(k in peak){ split(k,a,SUBSEP)
			print ord[a[1]] ":" a[1], peak[k], tot[k], r429[k]+0, r444[k]+0, a[2] }
		for(ip in i429) print "4:odmowy", i429[ip], itot[ip], i429[ip], i444[ip]+0, ip
	}' \
	| sort -k1,1 -k2,2rn \
	| awk -v top="$top" '
	{ sec=substr($1,3)
	  if(sec!=t){
		if(sec=="odmowy") printf "\n== odmowy 429 (wszystkie sciezki) ==  429 | 444 | total | IP\n"
		else printf "\n== %-5s ==  peak_req/s | total | 429 | 444 | IP\n", sec
		t=sec; n=0 }
	  if(++n>top) next
	  if(sec=="odmowy") printf "   %8d %6d %8d   %s\n",$4,$5,$3,$6
	  else              printf "   %8d   %8d %6d %6d   %s\n",$2,$3,$4,$5,$6 }'
}

# --- RESOLVE=1: PTR + wlasciciel bloku dla IP z tabel -------------------------
# Wynik: plik "IP<TAB>ptr<TAB>AS | CC | nazwa". Cache per IP w pliku (bash 3.2
# na macOS nie ma tablic asocjacyjnych). Kazde zapytanie z twardym timeoutem —
# wiszacy whois nie moze zablokowac diagnostyki w trakcie incydentu.
_with_timeout() {
	if command -v timeout >/dev/null 2>&1; then timeout 5 "$@"; else "$@"; fi
}

_ptr() {
	local ip="$1" out=""
	if command -v dig >/dev/null 2>&1; then
		out="$(_with_timeout dig +short +time=2 +tries=1 -x "$ip" 2>/dev/null | head -1 || true)"
	elif command -v getent >/dev/null 2>&1; then
		out="$(_with_timeout getent hosts "$ip" 2>/dev/null | awk '{print $2; exit}' || true)"
	fi
	out="${out%.}"
	case "$out" in ""|";;"*) echo "-" ;; *) echo "$out" ;; esac
}

# Team Cymru: "AS | IP | prefiks | CC | rejestr | data | nazwa AS".
_owner() {
	local ip="$1" line="" asn="" rest=""
	if command -v whois >/dev/null 2>&1; then
		line="$(_with_timeout whois -h whois.cymru.com " -v $ip" 2>/dev/null \
			| awk -F'|' 'NR>1 && $1 ~ /[0-9]/ { gsub(/^ +| +$/,"",$1); gsub(/^ +| +$/,"",$3)
				gsub(/^ +| +$/,"",$4); gsub(/^ +| +$/,"",$7)
				print "AS" $1 " " $3 " " $4 " " $7; exit }' || true)"
	elif command -v dig >/dev/null 2>&1; then
		case "$ip" in *:*) ;; *)  # DNS-owy interfejs Cymru: tylko IPv4 (v6 wymaga nibble)
			rest="$(echo "$ip" | awk -F. '{print $4"."$3"."$2"."$1}')"
			line="$(_with_timeout dig +short +time=2 +tries=1 TXT "$rest.origin.asn.cymru.com" 2>/dev/null | head -1 | tr -d '"' || true)"
			asn="$(echo "$line" | awk -F'|' '{gsub(/ /,"",$1); split($1,a," "); print a[1]}')"
			if [ -n "$asn" ]; then
				rest="$(_with_timeout dig +short +time=2 +tries=1 TXT "AS$asn.asn.cymru.com" 2>/dev/null | head -1 | tr -d '"' \
					| awk -F'|' '{gsub(/^ +| +$/,"",$5); print $5}' || true)"
				line="$(echo "$line" | awk -F'|' -v n="$rest" '{gsub(/ /,"",$1); gsub(/ /,"",$2); gsub(/ /,"",$3); print "AS" $1 " " $2 " " $3 " " n}')"
			fi ;;
		esac
	fi
	echo "${line:--}"
}

# Dopisuje "  ptr  [owner]" do wierszy tabel (IP = ostatnie pole).
resolve_annotate() {
	local file="$1" cache ip
	if ! command -v whois >/dev/null 2>&1 && ! command -v dig >/dev/null 2>&1; then
		echo "  (RESOLVE: brak 'whois' i 'dig' — wlasciciel bloku nieznany; apt install whois dnsutils)" >&2
	fi
	cache="$(mktemp)"
	awk '$NF ~ /^[0-9A-Fa-f.:]+$/ && $NF ~ /[.:]/ { print $NF }' "$file" | sort -u \
	| while IFS= read -r ip; do
		printf '%s\t%s\t%s\n' "$ip" "$(_ptr "$ip")" "$(_owner "$ip")"
	done >"$cache"
	# Dwa przebiegi po $file: najpierw szerokosci kolumn, potem druk.
	awk -F'\t' 'FNR==1 { pass++ }
		pass==1 { ptr[$1]=$2; own[$1]=$3; if(length($2)>wp) wp=length($2); next }
		pass==2 { if(length($0)>wl) wl=length($0); next }
		{ n=split($0,f," "); ip=f[n]
		  if(ip in ptr) printf "%-" wl "s   %-" wp "s   %s\n", $0, ptr[ip], own[ip]
		  else print }' "$cache" "$file" "$file"
	rm -f "$cache"
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
		if [ "$RESOLVE" = "1" ]; then
			resolve_annotate "$tmpout"
		else
			cat "$tmpout"
		fi
	else
		echo "  (brak ruchu w oknie --since ${SINCE})"
	fi
	rm -f "$tmpout"
	echo
done

echo "Wskazowka: 'rate' ustaw z zapasem nad najwyzszym LEGALNYM peakiem"
echo "(zignoruj oczywiste scrapery — pojedyncze chmurowe IP z total ~= peak)."
echo "429 = odmowa limitu (per-IP lub globalnego), 444 = WAF/blokada brzegu."
[ "$RESOLVE" = "1" ] || echo "Kto to jest? RESOLVE=1 make request-stats (PTR + AS/wlasciciel bloku)."

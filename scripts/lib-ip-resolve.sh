#!/usr/bin/env bash
# shellcheck shell=bash
#
# RESOLVE=1 dla raportow o ruchu (make request-stats, make rate-limit-stats):
# dopisuje do IP reverse DNS (PTR) i wlasciciela bloku (Team Cymru).
# Biblioteka do sourcowania — nie uruchamiac.
#
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
	# Scisle IPv4/IPv6: raport rate-limit-stats ma tez tabele, ktorej ostatnie
	# pole to nazwa hosta — "cafe.be" przeszloby luzny wzorzec [0-9A-Fa-f.:]+.
	awk '$NF ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || $NF ~ /^[0-9A-Fa-f]*:[0-9A-Fa-f:.]*$/ { print $NF }' "$file" | sort -u \
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

#!/usr/bin/env bash
# shellcheck shell=bash
#
# Zdarzenia limitow nginx-a z error logu (make rate-limit-stats,
# make configure-rate-limits). Biblioteka do sourcowania — nie uruchamiac.
#
# nginx_limit_events: stdin = surowe `docker logs webserver 2>&1`,
# stdout = jedna linia TSV na zdarzenie:
#
#   rodzaj  strefa  ip  host  sciezka  godzina
#
#   rodzaj   odmowa      "limiting requests" / "limiting connections" (429)
#            opoznienie  "delaying request" — zadanie czekalo w kolejce
#                        (limit_req z delay=), ale przeszlo
#   sciezka  bez query stringu — "/x/?page=1" i "?page=2" to jeden endpoint
#   godzina  "RRRR/MM/DD GG:00"
#
# Linie rozpoznajemy po pelnym prefiksie error logu nginx-a
# ("RRRR/MM/DD GG:MM:SS [poziom] pid#tid: [*conn ]..."), a nie po samym
# napisie — access log idzie tym samym `docker logs`, a URL moze zawierac
# dowolny tekst. Opoznienia nginx loguje o poziom NIZEJ niz odmowy
# (limit_req_log_level warn -> opoznienia jako notice).
nginx_limit_events() {
	LC_ALL=C awk '
	function pole(re, off){ if(match($0, re)) return substr($0, RSTART+off, RLENGTH-off); return "-" }
	# Bez {n}: stary mawk nie zna interwalow w regexach.
	$0 !~ /^[0-9][0-9][0-9][0-9]\/[0-9][0-9]\/[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] \[[a-z]+\] [0-9]+#[0-9]+: (\*[0-9]+ )?(limiting (requests|connections)|delaying request)/ { next }
	{
		rodzaj=(index($0, "delaying request") ? "opoznienie" : "odmowa")
		zone=pole("by zone \"[^\"]*\"", 9); sub(/"$/, "", zone)
		ip=pole("client: [^,]*", 8)
		host=pole("host: \"[^\"]*\"", 7); sub(/"$/, "", host)
		path=pole("request: \"[A-Z]+ [^ \"?]*", 10); sub(/^[A-Z]+ /, "", path)
		if(path=="") path="-"
		printf "%s\t%s\t%s\t%s\t%s\t%s\n", rodzaj, zone, ip, host, path, substr($0, 1, 13) ":00"
	}'
}

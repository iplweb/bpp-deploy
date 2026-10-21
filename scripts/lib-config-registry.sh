# shellcheck shell=bash
# ============================================================================
# lib-config-registry.sh — odczyt rejestru zmiennych operatora
# (scripts/config-registry.tsv), walidacja i zapis do .env.
# ============================================================================
# Uzywane przez scripts/configure.sh (make configure / make up / init-configs /
# make config-check / make docs-config-table). Prefiks rej_ — biblioteka bywa
# source'owana obok helperow init-configs (env_has_var, set_env_var...),
# nie wolno ich przeslonic.
#
# Wymaga: REJ_ENV = sciezka do $BPP_CONFIGS_DIR/.env (dla rej_env_*).
# Bez tablic asocjacyjnych — bash 3.2 (macOS) ich nie ma.
# ============================================================================

REJ_PLIK="${REJ_PLIK:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config-registry.tsv}"

# Wiersze rejestru bez komentarzy i pustych linii, pola rozdzielone \037
# (US), NIE tabulatorem: `read` z IFS=$'\t' skleja dwa tabulatory pod rzad
# (tab to "bialy" IFS), wiec pusta kolumna DOMYSLNA przesuwalaby pola.
# Czytaj: while IFS=$'\037' read -r nazwa grupa typ dom pytaj pusta opis
rej_wiersze() {
	awk -F'\t' -v OFS='\037' '!/^#/ && NF == 7 { $1 = $1; print }' "$REJ_PLIK"
}

# Grupy w kolejnosci pierwszego wystapienia, po jednej w linii.
rej_grupy() {
	rej_wiersze | awk -F'\037' '!seen[$2]++ { print $2 }'
}

# --- .env ---------------------------------------------------------------------
rej_env_has() {
	grep -q "^${1}=" "$REJ_ENV" 2>/dev/null
}

rej_env_get() {
	local raw
	raw="$(grep -E "^${1}=" "$REJ_ENV" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
	raw="${raw%$'\r'}"
	raw="${raw#\"}"; raw="${raw%\"}"
	raw="${raw#\'}"; raw="${raw%\'}"
	printf '%s' "$raw"
}

# rej_env_set NAZWA WARTOSC [KOMENTARZ] — podmiana w miejscu albo dopisanie
# na koncu (z komentarzem nad zmienna). Wartosc przez ENVIRON, nie `awk -v`
# (-v interpretuje backslashe). Plik tymczasowy z mktemp (0600, w .env sa
# hasla) i `cat >` zamiast `mv` — zostaje tryb i wlasciciel .env.
rej_env_set() {
	local nazwa="$1" wartosc="$2" komentarz="${3:-}" tmp
	if rej_env_has "$nazwa"; then
		tmp="$(mktemp "$REJ_ENV.tmp.XXXXXX")"
		K="$nazwa" V="$wartosc" awk '
			BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] }
			index($0, k "=") == 1 { print k "=" v; next }
			{ print }
		' "$REJ_ENV" > "$tmp"
		cat "$tmp" > "$REJ_ENV"
		rm -f "$tmp"
	else
		# .env bez konczacego \n skleilby nasza linie z ostatnia
		if [ -s "$REJ_ENV" ] && [ -n "$(tail -c1 "$REJ_ENV")" ]; then
			echo >> "$REJ_ENV"
		fi
		{
			echo ""
			[ -n "$komentarz" ] && echo "# $komentarz"
			printf '%s=%s\n' "$nazwa" "$wartosc"
		} >> "$REJ_ENV"
	fi
}

# Wartosc innej zmiennej dla ${NAZWA} w DOMYSLNA. configure.sh przeslania ja,
# zeby widziec tez jeszcze niezapisane odpowiedzi (LETSENCRYPT_EMAIL <- ADMIN_EMAIL).
rej_odczyt() {
	rej_env_get "$1"
}

# --- wartosci -----------------------------------------------------------------
# Rozwija ${NAZWA} w kolumnie DOMYSLNA: wartosc z .env albo wyliczona.
rej_domyslna() {
	local s="$1" wynik="" przed nazwa wartosc
	while :; do
		# shellcheck disable=SC2016  # dosłowne ${...}, nie rozwijamy
		case "$s" in
			*'${'*'}'*) ;;
			*) break ;;
		esac
		przed="${s%%\$\{*}"
		s="${s#*\$\{}"
		nazwa="${s%%\}*}"
		s="${s#*\}}"
		case "$nazwa" in
			BPP_DOMYSLNY_KATALOG_BACKUPOW)
				wartosc="$(dirname "${BPP_CONFIGS_DIR:-$(dirname "$REJ_ENV")}")/backups" ;;
			*) wartosc="$(rej_odczyt "$nazwa")" ;;
		esac
		wynik="$wynik$przed$wartosc"
	done
	printf '%s' "$wynik$s"
}

# Jak wartosc pokazac na ekranie / w podsumowaniu (sekretow nie pokazujemy).
rej_pokaz() {  # TYP WARTOSC
	if [ "$1" = sekret ]; then
		if [ -n "$2" ]; then printf '(ustawiony, %s znakow)' "${#2}"; else printf '(pusty)'; fi
	else
		if [ -n "$2" ]; then printf '%s' "$2"; else printf '(pusta)'; fi
	fi
}

# rej_waliduj TYP PUSTA WARTOSC — 0 = OK; inaczej komunikat na stdout, 1.
# Zakazane wszedzie: `$` i `#` (.env jest tez `-include` w Makefile, a Compose
# interpoluje `$`), cudzyslowy (Compose przekazuje je literalnie —
# validate-env-quotes.sh), backslash i backtick.
rej_waliduj() {
	local typ="$1" pusta="$2" v="$3"
	if [ -z "$v" ]; then
		[ "$pusta" = tak ] && return 0
		echo "wartosc jest wymagana"; return 1
	fi
	# shellcheck disable=SC1003  # '\' to dosłowny backslash
	case "$v" in
		*'$'*|*'#'*|*'"'*|*"'"*|*'\'*|*'`'*)
			echo "niedozwolony znak (\$ # cudzyslow \\ \`) — psuje .env czytany przez make i Compose"; return 1 ;;
	esac
	case "$typ" in
		email)
			if ! printf '%s' "$v" | grep -Eq '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'; then
				echo "to nie wyglada na adres e-mail"; return 1
			fi ;;
		url)
			case "$v" in
				http://*|https://*) ;;
				*) echo "URL musi zaczynac sie od https:// (albo http://)"; return 1 ;;
			esac
			case "$v" in *[[:space:]]*) echo "URL nie moze zawierac spacji"; return 1 ;; esac ;;
		liczba|id)
			case "$v" in *[!0-9]*)
				if [ "$typ" = id ]; then
					echo "ID widgetu to liczba (z kodu osadzenia: 'widget_id': 205000000433)"
				else
					echo "podaj liczbe calkowita >= 0"
				fi
				return 1 ;;
			esac ;;
		sciezka)
			case "$v" in
				/*) ;;
				*) echo "podaj sciezke bezwzgledna (od /)"; return 1 ;;
			esac ;;
		sekret)
			case "$v" in *[!A-Za-z0-9._~+/=-]*)
				echo "sekret moze zawierac tylko litery, cyfry i . _ ~ + / = -"; return 1 ;;
			esac ;;
		wybor:*)
			case "/${typ#wybor:}/" in
				*"/$v/"*) ;;
				*) echo "dozwolone: ${typ#wybor:}"; return 1 ;;
			esac ;;
		tekst)
			case "$v" in [[:space:]]*|*[[:space:]]) echo "bez spacji na poczatku i koncu"; return 1 ;; esac ;;
		*)
			echo "nieznany typ w rejestrze: $typ"; return 1 ;;
	esac
	return 0
}

# Tabela Markdown dla docs/ (make docs-config-table).
rej_docs() {
	rej_wiersze | awk -F'\037' '
	function md(s) { gsub(/\|/, "\\|", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
	{
		if ($2 != grupa) {
			if (grupa != "") print ""
			grupa = $2
			print "### " grupa
			print ""
			print "| Zmienna | Typ | Domyślnie | Pytanie przy instalacji / `make up` | Może być pusta | Opis |"
			print "|---|---|---|---|---|---|"
		}
		if ($4 == "") d = "*(pusta)*"
		else if ($4 == "${BPP_DOMYSLNY_KATALOG_BACKUPOW}") d = "`backups/` obok katalogu konfiguracyjnego"
		else if ($4 ~ /^\$\{[A-Z_0-9]+\}$/) { d = $4; gsub(/[${}]/, "", d); d = "= `" d "`" }
		else d = "`" $4 "`"
		typ = $3; sub(/^wybor:/, "jedno z: ", typ)
		print "| `" $1 "` | " md(typ) " | " md(d) " | " $5 " | " $6 " | " md($7) " |"
	}'
}

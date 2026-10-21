#!/usr/bin/env bash
# ============================================================================
# configure.sh — zmienne operatora z rejestru (scripts/config-registry.tsv)
# ============================================================================
# Tryby:
#   (bez argumentu)  make configure — menu grup, edycja, zapis na koncu (z)
#   --missing        make up / up-quick / refresh — pyta TYLKO o zmienne
#                    z PYTAJ=tak, ktorych w .env nie ma wcale
#   --init           init-configs — jak --missing, ale koniec wejscia =
#                    wartosc domyslna (testy i instalacja z </dev/null),
#                    a zmienne PYTAJ=nie dopisuje z domyslna bez pytania
#   --check          make config-check / doctor — walidacja wartosci w .env
#   --docs           make docs-config-table — tabela Markdown na stdout
#
# DECYZJA = OBECNOSC ZMIENNEJ W .env. Pusta odpowiedz zapisuje `VAR=`
# (pusta = funkcja wylaczona) i jest zapisana decyzja operatora: make up
# juz o nia nie pyta. Zmiana zdania: make configure.
#
# --missing nie pyta (exit 0, nic nie zapisuje), gdy nie ma kogo pytac:
#   - stdin nie jest terminalem (cron, CI, | tee) — jedna linia przypomnienia,
#   - BPP_SKIP_HEALTH_GATE / BPP_NO_CONFIG_PROMPT ustawione (autoupdate.sh,
#     deploy-with-warning.sh, restore.sh, upgrade-postgres.sh — screen daje
#     pseudo-TTY, prompt zawiesilby petle trzymajaca lock),
#   - brak odpowiedzi przez BPP_CONFIG_PROMPT_TIMEOUT s (domyslnie 120).
# Brak odpowiedzi to NIE decyzja: zapis jest na koncu, wszystko albo nic.
#
# BPP_CO_ASSUME_TTY=1 — tylko dla testow (test_configure_registry
# w tests/test_makefile.sh): traktuj potok jak terminal.
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib-config-registry.sh
. "$REPO_DIR/scripts/lib-config-registry.sh"

TRYB=menu
case "${1:-}" in
	"") ;;
	--missing) TRYB=brakujace ;;
	--init) TRYB=init ;;
	--check) TRYB=sprawdz ;;
	--docs) rej_docs; exit 0 ;;
	*) echo "Uzycie: $0 [--missing|--init|--check|--docs]" >&2; exit 2 ;;
esac

if [ "$TRYB" = brakujace ]; then
	if [ -n "${BPP_SKIP_HEALTH_GATE:-}" ] || [ -n "${BPP_NO_CONFIG_PROMPT:-}" ]; then
		exit 0
	fi
fi
INTERAKTYWNY=0
if [ -t 0 ] || [ -n "${BPP_CO_ASSUME_TTY:-}" ]; then
	INTERAKTYWNY=1
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
REJ_ENV="$BPP_CONFIGS_DIR/.env"
DOKUMENTACJA="https://iplweb.github.io/bpp-deploy/konfiguracja/zmienne/"

# --- --check ------------------------------------------------------------------
if [ "$TRYB" = sprawdz ]; then
	bledy=0; brak=0
	while IFS=$'\037' read -r nazwa _grupa typ _dom pytaj pusta _opis; do
		if ! rej_env_has "$nazwa"; then
			if [ "$pytaj" = tak ]; then
				echo "  ? ${nazwa}: brak decyzji (zapytam przy make up albo: make configure)"
				brak=$((brak + 1))
			fi
			continue
		fi
		v="$(rej_env_get "$nazwa")"
		if ! komunikat="$(rej_waliduj "$typ" "$pusta" "$v")"; then
			echo "  ✗ ${nazwa}=$(rej_pokaz "$typ" "$v"): ${komunikat}"
			bledy=$((bledy + 1))
		fi
	done < <(rej_wiersze)
	if [ "$bledy" -gt 0 ]; then
		echo "Zmienne operatora: ${bledy} z bledna wartoscia w ${REJ_ENV} — popraw: make configure"
		exit 1
	fi
	if [ "$brak" -gt 0 ]; then
		echo "✓ Zmienne operatora poprawne (bez decyzji: ${brak})"
	else
		echo "✓ Zmienne operatora poprawne"
	fi
	exit 0
fi

# --- czytanie odpowiedzi --------------------------------------------------------
TIMEOUT="${BPP_CONFIG_PROMPT_TIMEOUT:-120}"
case "$TIMEOUT" in ""|*[!0-9]*) TIMEOUT=120 ;; esac

# czytaj UKRYJ -> $ODP (przyciete biale znaki); 1 = koniec wejscia / timeout.
czytaj() {
	local x opcje=()
	[ "$TRYB" = brakujace ] && opcje+=(-t "$TIMEOUT")
	[ "$1" = 1 ] && [ -t 0 ] && opcje+=(-s)
	# ${a[@]+...}: pusta tablica pod set -u wywraca bash 3.2 (macOS)
	if ! IFS= read -r ${opcje[@]+"${opcje[@]}"} x; then
		echo ""
		return 1
	fi
	[ "$1" = 1 ] && [ -t 0 ] && echo ""
	x="${x%$'\r'}"
	x="${x#"${x%%[![:space:]]*}"}"; x="${x%"${x##*[![:space:]]}"}"
	ODP="$x"
}

# zapytaj TYP PUSTA OPIS OBECNA -> $NOWA. Enter = OBECNA, '-' = pusta.
# 1 = koniec wejscia (w trybie init: NOWA=OBECNA i 0).
zapytaj() {
	local typ="$1" pusta="$2" opis="$3" obecna="$4" komunikat ukryj=0
	[ "$typ" = sekret ] && ukryj=1
	echo "  ${opis}"
	while true; do
		printf '  > [%s] ' "$(rej_pokaz "$typ" "$obecna")"
		if ! czytaj "$ukryj"; then
			if [ "$TRYB" = init ]; then NOWA="$obecna"; return 0; fi
			return 1
		fi
		case "$ODP" in
			"") NOWA="$obecna" ;;
			-) NOWA="" ;;
			*) NOWA="$ODP" ;;
		esac
		if komunikat="$(rej_waliduj "$typ" "$pusta" "$NOWA")"; then
			return 0
		fi
		echo "  ${komunikat}"
	done
}

# Zmiany do zapisu: rownolegle tablice (bez tablic asocjacyjnych — bash 3.2).
declare -a Z_NAZWA=() Z_WARTOSC=() Z_TYP=() Z_OPIS=()
dodaj_zmiane() {  # NAZWA WARTOSC TYP GRUPA: OPIS
	local i
	for i in ${Z_NAZWA[@]+"${!Z_NAZWA[@]}"}; do
		if [ "${Z_NAZWA[$i]}" = "$1" ]; then
			Z_WARTOSC[i]="$2"; return
		fi
	done
	Z_NAZWA+=("$1"); Z_WARTOSC+=("$2"); Z_TYP+=("$3"); Z_OPIS+=("$4")
}

# Dla ${NAZWA} w DOMYSLNA: oczekujaca zmiana przed .env.
rej_odczyt() {
	local i
	for i in ${Z_NAZWA[@]+"${!Z_NAZWA[@]}"}; do
		[ "${Z_NAZWA[$i]}" = "$1" ] && { printf '%s' "${Z_WARTOSC[$i]}"; return; }
	done
	rej_env_get "$1"
}

# Wartosc biezaca: oczekujaca zmiana > .env > domyslna z rejestru.
biezaca() {  # NAZWA DOMYSLNA_SUROWA
	local i
	for i in ${Z_NAZWA[@]+"${!Z_NAZWA[@]}"}; do
		[ "${Z_NAZWA[$i]}" = "$1" ] && { printf '%s' "${Z_WARTOSC[$i]}"; return; }
	done
	if rej_env_has "$1"; then rej_env_get "$1"; else rej_domyslna "$2"; fi
}

zapisz() {
	local i zmienione=0
	for i in ${Z_NAZWA[@]+"${!Z_NAZWA[@]}"}; do
		if rej_env_has "${Z_NAZWA[$i]}" && [ "$(rej_env_get "${Z_NAZWA[$i]}")" = "${Z_WARTOSC[$i]}" ]; then
			continue
		fi
		if rej_env_has "${Z_NAZWA[$i]}"; then
			echo "  ~ ${Z_NAZWA[$i]}=$(rej_pokaz "${Z_TYP[$i]}" "${Z_WARTOSC[$i]}")"
		else
			echo "  + ${Z_NAZWA[$i]}=$(rej_pokaz "${Z_TYP[$i]}" "${Z_WARTOSC[$i]}")"
		fi
		rej_env_set "${Z_NAZWA[$i]}" "${Z_WARTOSC[$i]}" "${Z_OPIS[$i]}"
		zmienione=1
	done
	[ "$zmienione" = 1 ]
}

# --- --missing / --init ----------------------------------------------------------
# Wiersze rejestru czytamy z deskryptora 3 — stdin jest na odpowiedzi.
if [ "$TRYB" = brakujace ] || [ "$TRYB" = init ]; then
	WIERSZE="$(rej_wiersze)"
	ile=0
	while IFS=$'\037' read -r nazwa _g _t _d pytaj _p _o <&3; do
		if [ "$pytaj" = tak ] && ! rej_env_has "$nazwa"; then ile=$((ile + 1)); fi
	done 3<<<"$WIERSZE"

	if [ "$TRYB" = brakujace ]; then
		[ "$ile" -eq 0 ] && exit 0
		if [ "$INTERAKTYWNY" = 0 ]; then
			echo "INFO: zmienne operatora bez decyzji (${ile}) — uzupelnij: make configure"
			exit 0
		fi
		echo ""
		echo "================================================================"
		echo "  Nowe ustawienia BPP (${ile}) — pytam raz, potem juz nie"
		echo "================================================================"
		echo "Enter = wartosc w nawiasie, '-' = pusta (wylaczone)."
		echo "Pusta odpowiedz to tez decyzja ('nie mamy tego') — zmiana pozniej: make configure"
		echo "Opis zmiennych: $DOKUMENTACJA"
	fi

	while IFS=$'\037' read -r nazwa grupa typ dom pytaj pusta opis <&3; do
		rej_env_has "$nazwa" && continue
		wartosc="$(biezaca "$nazwa" "$dom")"
		if [ "$pytaj" = tak ]; then
			echo ""
			echo "${nazwa}"
			if ! zapytaj "$typ" "$pusta" "$opis" "$wartosc"; then
				echo "Brak odpowiedzi — nic nie zapisano (zapytam ponownie przy nastepnym make up)."
				exit 0
			fi
			wartosc="$NOWA"
		elif [ "$TRYB" = brakujace ]; then
			continue   # PYTAJ=nie: make up nie dopisuje (domyslna zyje w kodzie)
		fi
		dodaj_zmiane "$nazwa" "$wartosc" "$typ" "${grupa}: ${opis}"
	done 3<<<"$WIERSZE"

	echo ""
	if zapisz; then
		echo "Zapisano w ${REJ_ENV}."
	elif [ "$TRYB" = brakujace ]; then
		echo "Bez zmian."
	fi
	exit 0
fi

# --- menu (make configure) -------------------------------------------------------
if [ "$INTERAKTYWNY" = 0 ]; then
	echo "BLAD: make configure jest interaktywne — uruchom w terminalu." >&2
	exit 1
fi

GRUPY="$(rej_grupy)"

edytuj_grupe() {  # GRUPA
	local nazwa grupa typ dom pytaj pusta opis wartosc
	echo ""
	echo "== $1 ==   (Enter = bez zmian, '-' = pusta)"
	while IFS=$'\037' read -r nazwa grupa typ dom pytaj pusta opis <&3; do
		[ "$grupa" = "$1" ] || continue
		wartosc="$(biezaca "$nazwa" "$dom")"
		echo ""
		echo "${nazwa}$(rej_env_has "$nazwa" || printf ' (brak w .env, proponuje domyslna)')"
		if ! zapytaj "$typ" "$pusta" "$opis" "$wartosc"; then
			return 1
		fi
		# Bez zmiany i juz w .env -> nic do zapisu; brak w .env + Enter -> zapis decyzji.
		if rej_env_has "$nazwa" && [ "$NOWA" = "$(rej_env_get "$nazwa")" ]; then
			continue
		fi
		dodaj_zmiane "$nazwa" "$NOWA" "$typ" "${grupa}: ${opis}"
	done 3<<<"$(rej_wiersze)"
}

while true; do
	echo ""
	echo "=== Konfiguracja BPP — ${REJ_ENV} ==="
	n=0
	while IFS= read -r g <&3; do
		n=$((n + 1))
		ile_g="$(rej_wiersze | awk -F'\037' -v g="$g" '$2 == g' | grep -c .)"
		printf '  %d) %-15s (%d)\n' "$n" "$g" "$ile_g"
	done 3<<<"$GRUPY"
	echo "  z) zapisz i wyjdz    q) wyjdz bez zapisu"
	if [ "${#Z_NAZWA[@]}" -gt 0 ]; then
		echo "  Niezapisane zmiany: ${#Z_NAZWA[@]}"
	fi
	printf 'Wybierz: '
	if ! czytaj 0; then
		echo "Koniec wejscia — nic nie zapisano."
		exit 1
	fi
	case "$ODP" in
		z|Z)
			echo ""
			if zapisz; then
				echo "Zapisano w ${REJ_ENV}. Nowe wartosci zadzialaja po: make up"
			else
				echo "Bez zmian."
			fi
			exit 0 ;;
		q|Q)
			[ "${#Z_NAZWA[@]}" -gt 0 ] && echo "Porzucono niezapisane zmiany: ${#Z_NAZWA[@]}"
			exit 0 ;;
		"") ;;
		*[!0-9]*) echo "Nieznany wybor: $ODP" ;;
		*)
			g="$(printf '%s\n' "$GRUPY" | sed -n "${ODP}p")"
			if [ -z "$g" ]; then
				echo "Nieznany wybor: $ODP"
			elif ! edytuj_grupe "$g"; then
				echo "Koniec wejscia — nic nie zapisano."
				exit 1
			fi ;;
	esac
done

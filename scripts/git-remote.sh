#!/usr/bin/env bash
#
# git-remote.sh — przelacza adres remote'a `origin` miedzy HTTPS a SSH.
#
#   https  (make git-bez-klucza) — pobieranie anonimowe po HTTPS; push (gdy nie
#          ma wlasnego pushurl) zostaje po SSH. Dla hostow z auto-update: petla
#          pod screenem nie ma agenta SSH, wiec `git fetch` po SSH konczy sie
#          "Permission denied (publickey)" i nowe COMMITY nie docieraja nigdy
#          (nowe obrazy tak — dlatego latwo to przeoczyc). Tylko dla
#          repozytorium publicznego.
#   ssh    (make git-na-klucz) — jeden adres SSH do pobierania i pushu.
#
# Host i sciezka sa brane z obecnego adresu, nie zaszyte na sztywno — fork albo
# inny host dziala tak samo. Po zmianie sprawdzamy polaczenie `git ls-remote`
# BEZ ZADNYCH PYTAN (GIT_TERMINAL_PROMPT=0, ssh BatchMode=yes): pod screenem
# pytanie o haslo albo login zawisloby w nieskonczonosc.
#
# BPP_REPO_DIR — nadpisanie katalogu repozytorium (wylacznie dla testow).

set -euo pipefail

REPO_DIR="${BPP_REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
MODE="${1:-}"

case "$MODE" in
	https|ssh) ;;
	*)
		echo "Uzycie: $0 https|ssh" >&2
		exit 2 ;;
esac

g() { git -C "$REPO_DIR" "$@"; }

# Poswiadczenia (https://user:token@host) nie moga trafic na ekran ani do logu.
redact() { printf '%s' "$1" | sed -E 's#^([a-z]+://)[^/@]+@#\1***@#'; }

if ! g rev-parse --git-dir >/dev/null 2>&1; then
	echo "BLAD: $REPO_DIR nie jest repozytorium git." >&2
	exit 1
fi
if ! current="$(g config --get remote.origin.url)"; then
	echo "BLAD: brak remote'a 'origin' w $REPO_DIR." >&2
	exit 1
fi

# --- Rozbior adresu na host + sciezke --------------------------------------
ssh_user=git
case "$current" in
	https://*|http://*|ssh://*)
		rest="${current#*://}"
		authority="${rest%%/*}"
		path="${rest#*/}"
		[ "$path" != "$rest" ] || path=""
		userinfo=""
		case "$authority" in *@*) userinfo="${authority%@*}" ;; esac
		host="${authority##*@}"
		host="${host%%:*}"  # port: w ssh:// to port SSH, do HTTPS nie przechodzi
		case "$current" in
			ssh://*) [ -z "$userinfo" ] || ssh_user="$userinfo" ;;
		esac
		;;
	*@*:*)
		# scp-like: uzytkownik@host:sciezka
		authority="${current%%:*}"
		path="${current#*:}"
		host="${authority##*@}"
		ssh_user="${authority%@*}"
		;;
	*)
		host=""
		path=""
		;;
esac

if [ -z "$host" ] || [ -z "$path" ]; then
	echo "BLAD: nie rozpoznaje adresu origin: $(redact "$current")" >&2
	echo "  Obslugiwane: git@host:wlasciciel/repo.git, ssh://git@host/..., https://host/..." >&2
	exit 1
fi

https_url="https://$host/$path"
ssh_url="$ssh_user@$host:$path"

echo "Repozytorium: $REPO_DIR"
echo "Poprzednio:   $(redact "$current")"

# --- Zmiana ------------------------------------------------------------------
if [ "$MODE" = https ]; then
	case "$current" in
		https://*|http://*) echo "Pobieranie juz idzie po HTTPS — adresu nie zmieniam." ;;
		*) g remote set-url origin "$https_url" ;;
	esac
	# Cudzego, jawnie ustawionego pushurl nie nadpisujemy.
	if ! g config --get remote.origin.pushurl >/dev/null; then
		g remote set-url --push origin "$ssh_url"
	fi
else
	[ "$current" = "$ssh_url" ] || g remote set-url origin "$ssh_url"
	if g config --get remote.origin.pushurl >/dev/null; then
		g config --unset remote.origin.pushurl
	fi
fi

echo "Teraz:        pobieranie $(redact "$(g config --get remote.origin.url)")"
echo "              push       $(redact "$(g remote get-url --push origin)")"

# --- Sprawdzenie polaczenia (bez pytan) --------------------------------------
echo ""
echo "Sprawdzam polaczenie (git ls-remote origin)..."
if GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes" \
	g ls-remote --exit-code origin HEAD >/dev/null; then
	echo "✓ Pobieranie dziala."
	exit 0
fi

echo "" >&2
echo "BLAD: nie moge pobrac z origin (zmiana adresu ZOSTAWIONA)." >&2
if [ "$MODE" = https ]; then
	echo "  Repozytorium jest prywatne albo nie ma sieci. Powrot: make git-na-klucz" >&2
	echo "  Dla prywatnego repo uzyj deploy key: docs/eksploatacja/aktualizacje.md" >&2
else
	echo "  W tej sesji nie ma klucza SSH (brak agenta?). Petla auto-update pod screenem" >&2
	echo "  agenta nie ma nigdy — tam 'git fetch' bedzie padal. Publiczne repo: make git-bez-klucza" >&2
fi
exit 1

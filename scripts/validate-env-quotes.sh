#!/usr/bin/env bash
#
# Walidator wartosci w .env pod katem dwoch problemow z Docker Compose:
#
# 1. Otaczajace cudzyslowy (" lub '). Compose przekazuje je literalnie do
#    kontenerow, co psuje m.in.:
#      - POSTGRES_USER  (psql CREATE USER traktuje "bpp" jako rzeczywista nazwe roli)
#      - DJANGO_BPP_REDIS_PORT  (kombu: cannot cast to integer "6379")
#      - DOCKER_VERSION (image tag iplweb/bpp_appserver:"latest" - 404)
#
# 2. Nieuciekniete `$X` w wartosciach (gdzie X to litera/_/{). Compose interpretuje
#    je jako referencje do zmiennych i zastepuje pusta wartoscia (z warningiem
#    `The "x" variable is not set. Defaulting to a blank string.`). Dotyczy
#    haseł i sekretow ktore zawieraja literalny `$`. Compose escape: `$$`.
#
# Uzycie:
#   validate-env-quotes.sh           # walidacja, exit 1 jezeli sa naruszenia
#   validate-env-quotes.sh --fix     # auto-strip cudzyslowow + escape $ in-place,
#                                    # backup .bak.<ts>
#
# Sprawdza dwa pliki (gdy istnieja):
#   - $REPO_DIR/.env              (BPP_CONFIGS_DIR, COMPOSE_PROJECT_NAME, ...)
#   - $BPP_CONFIGS_DIR/.env       (cala konfiguracja aplikacji)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

MODE="check"
if [ "${1:-}" = "--fix" ]; then
    MODE="fix"
elif [ -n "${1:-}" ]; then
    echo "Uzycie: $0 [--fix]" >&2
    exit 2
fi

# Zaladuj BPP_CONFIGS_DIR z repo .env (tym samym sposobem co Makefile linia 11
# `include .env`). Sam BPP_CONFIGS_DIR moze byc w cudzyslowach - wyczysc raw
# zeby trafic do prawdziwego pliku.
BPP_CONFIGS_DIR=""
if [ -f "$REPO_DIR/.env" ]; then
    BPP_CONFIGS_DIR="$(grep -E '^BPP_CONFIGS_DIR=' "$REPO_DIR/.env" 2>/dev/null \
        | tail -1 | cut -d= -f2- || true)"
    BPP_CONFIGS_DIR="${BPP_CONFIGS_DIR#\"}"; BPP_CONFIGS_DIR="${BPP_CONFIGS_DIR%\"}"
    BPP_CONFIGS_DIR="${BPP_CONFIGS_DIR#\'}"; BPP_CONFIGS_DIR="${BPP_CONFIGS_DIR%\'}"
fi

FILES=()
[ -f "$REPO_DIR/.env" ] && FILES+=("$REPO_DIR/.env")
[ -n "$BPP_CONFIGS_DIR" ] && [ -f "$BPP_CONFIGS_DIR/.env" ] && FILES+=("$BPP_CONFIGS_DIR/.env")

if [ ${#FILES[@]} -eq 0 ]; then
    echo "validate-env-quotes: brak .env do walidacji (pierwsze uruchomienie?). Pomijam." >&2
    exit 0
fi

# Wykrywa naruszenia w plikach podanych jako argumenty. Wypisuje na stdout
# linie w formacie "<plik>:<numer-linii>:<typ>:<surowa-linia>" gdzie typ to
# QUOTE (otaczajace cudzyslowy) lub DOLLAR (nieuciekniete $X).
detect_violations() {
    awk '
        # Czy wartosc zawiera nieuciekniety `$` przed znakiem identyfikatora.
        # Przyklad pasujacy: abc$xyz, abc${xyz}, $X. Niepasujacy: abc$$xyz.
        function has_unescaped_dollar(v,    i, c, n, prev, len) {
            len = length(v)
            prev = ""
            for (i = 1; i <= len; i++) {
                c = substr(v, i, 1)
                n = (i < len) ? substr(v, i + 1, 1) : ""
                if (c == "$" && prev != "$" && n ~ /[A-Za-z_{]/) {
                    return 1
                }
                prev = c
            }
            return 0
        }

        /^[[:space:]]*(#|$)/ { next }
        !/^[A-Za-z_][A-Za-z0-9_]*=/ { next }
        {
            line = $0
            sub(/[[:space:]]+$/, "", line)
            val = line
            sub(/^[^=]*=/, "", val)
            if (val ~ /^".*"$/ || val ~ /^'\''.*'\''$/) {
                print FILENAME ":" NR ":QUOTE:" line
                next
            }
            if (has_unescaped_dollar(val)) {
                print FILENAME ":" NR ":DOLLAR:" line
            }
        }
    ' "$@"
}

if [ "$MODE" = "check" ]; then
    violations="$(detect_violations "${FILES[@]}")"
    if [ -z "$violations" ]; then
        exit 0
    fi

    has_quote="$(printf '%s\n' "$violations" | awk -F: '$3 == "QUOTE"' | head -1)"
    has_dollar="$(printf '%s\n' "$violations" | awk -F: '$3 == "DOLLAR"' | head -1)"

    {
        echo ""
        echo "=== BLAD: niepoprawne wartosci w .env ==="
        echo ""
        if [ -n "$has_quote" ]; then
            cat <<'EOF'
[QUOTE] Otaczajace cudzyslowy w wartosciach .env.
Docker Compose przekazuje wartosci LITERALNIE (z cudzyslowami) do kontenerow.
Psuje m.in. POSTGRES_USER, DJANGO_BPP_REDIS_PORT, DOCKER_VERSION.

EOF
        fi
        if [ -n "$has_dollar" ]; then
            cat <<'EOF'
[DOLLAR] Nieuciekniete `$X` w wartosciach .env.
Docker Compose interpretuje `$X` jako referencje do zmiennej i zastepuje pusta
wartoscia (warning: `The "x" variable is not set. Defaulting to a blank string.`).
Aby zachowac literalny `$`, uzyj `$$` (np. haslo `pa$$word`).

EOF
        fi
        echo "Naruszenia:"
        echo ""
        # Format "plik:linia:typ:tresc" -> "  [TYP] plik:linia: tresc".
        echo "$violations" | awk -F: '
            { printf "  [%s] %s:%s:", $3, $1, $2
              for (i = 4; i <= NF; i++) printf "%s%s", (i == 4 ? " " : ":"), $i
              print "" }'
        cat <<'EOF'

Auto-fix:

  make fix-env-quotes

(zapisze backupy .env.bak.<timestamp>, strip-uje cudzyslowy i escape-uje `$`
in-place, potem retry "make <target>".)

EOF
    } >&2
    exit 1
fi

# MODE = fix.
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
fixed_total=0

for f in "${FILES[@]}"; do
    fixed_in_file="$(detect_violations "$f" | wc -l | tr -d ' ')"
    if [ "$fixed_in_file" = "0" ]; then
        echo "$f: brak naruszen do naprawy"
        continue
    fi

    backup="$f.bak.$TIMESTAMP"
    cp "$f" "$backup"

    # Strip jednej warstwy otaczajacych " lub ', a nastepnie escape `$X` ->
    # `$$X` (gdzie X to litera/_/{). Zachowuje komentarze, puste linie i
    # trailing whitespace. Nie tyka linii ktore nie pasuja do KEY=value.
    awk '
        function escape_dollars(v,    out, i, c, n, prev, len) {
            out = ""
            prev = ""
            len = length(v)
            for (i = 1; i <= len; i++) {
                c = substr(v, i, 1)
                n = (i < len) ? substr(v, i + 1, 1) : ""
                if (c == "$" && prev != "$" && n ~ /[A-Za-z_{]/) {
                    out = out "$$"
                } else {
                    out = out c
                }
                prev = c
            }
            return out
        }

        /^[[:space:]]*(#|$)/ { print; next }
        !/^[A-Za-z_][A-Za-z0-9_]*=/ { print; next }
        {
            key = $0; sub(/=.*$/, "", key)
            val = $0; sub(/^[^=]*=/, "", val)
            trail = ""
            if (match(val, /[[:space:]]+$/)) {
                trail = substr(val, RSTART)
                val = substr(val, 1, RSTART - 1)
            }
            if (val ~ /^".*"$/) {
                val = substr(val, 2, length(val) - 2)
            } else if (val ~ /^'\''.*'\''$/) {
                val = substr(val, 2, length(val) - 2)
            }
            val = escape_dollars(val)
            print key "=" val trail
        }
    ' "$f" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"

    echo "$f: $fixed_in_file naruszen naprawionych, backup -> $backup"
    fixed_total=$((fixed_total + fixed_in_file))
done

if [ "$fixed_total" -eq 0 ]; then
    echo "Brak naruszen w zadnym .env. Nic do zrobienia."
fi
exit 0

#!/usr/bin/env bash
#
# Wykrywa wartosci w .env zapisane z otaczajacymi cudzyslowami i opcjonalnie
# strip-uje je in-place.
#
# Docker Compose nie obcina cudzyslowow z .env (inaczej niz `bash source`),
# wiec interpolacja ${VAR} w YAML i injekcja przez env_file: dawalyby literalne
# znaki " lub ' w wartosciach przekazywanych do kontenerow. Psuje to m.in.:
#   - POSTGRES_USER  (psql CREATE USER traktuje "bpp" jako rzeczywista nazwe roli)
#   - RABBITMQ_PORT  (Kombu: cannot cast to integer "5672")
#   - DOCKER_VERSION (image tag iplweb/bpp_appserver:"latest" - 404)
#
# Uzycie:
#   validate-env-quotes.sh           # walidacja, exit 1 jezeli sa cudzyslowy
#   validate-env-quotes.sh --fix     # auto-strip in-place z backupem .bak.<ts>
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
# linie w formacie "<plik>:<numer-linii>:<surowa-linia>".
detect_violations() {
    awk '
        /^[[:space:]]*(#|$)/ { next }
        !/^[A-Za-z_][A-Za-z0-9_]*=/ { next }
        {
            line = $0
            sub(/[[:space:]]+$/, "", line)
            val = line
            sub(/^[^=]*=/, "", val)
            if (val ~ /^".*"$/ || val ~ /^'\''.*'\''$/) {
                print FILENAME ":" NR ":" line
            }
        }
    ' "$@"
}

if [ "$MODE" = "check" ]; then
    violations="$(detect_violations "${FILES[@]}")"
    if [ -z "$violations" ]; then
        exit 0
    fi
    cat >&2 <<'EOF'

=== BLAD: cudzyslowy w wartosciach .env ===

Docker Compose przekazuje wartosci LITERALNIE (z cudzyslowami) do kontenerow.
To psuje m.in.:
  - POSTGRES_USER  (psql CREATE USER traktuje "bpp" jako rzeczywista nazwe roli)
  - RABBITMQ_PORT  (Kombu: cannot cast to integer "5672")
  - DOCKER_VERSION (image tag iplweb/bpp_appserver:"latest" - 404)
  - kazdy inny consumer expecting plain value

Naruszenia:

EOF
    # Format "plik:linia:tresc" -> "  plik:linia: tresc". Tresc moze zawierac ":".
    echo "$violations" | awk -F: '
        { printf "  %s:%s:", $1, $2
          for (i = 3; i <= NF; i++) printf "%s%s", (i == 3 ? " " : ":"), $i
          print "" }' >&2
    cat >&2 <<'EOF'

Auto-fix:

  make fix-env-quotes

(zapisze backupy .env.bak.<timestamp>, strip-uje cudzyslowy in-place,
potem retry "make <target>".)

EOF
    exit 1
fi

# MODE = fix.
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
fixed_total=0

for f in "${FILES[@]}"; do
    fixed_in_file="$(detect_violations "$f" | wc -l | tr -d ' ')"
    if [ "$fixed_in_file" = "0" ]; then
        echo "$f: brak cudzyslowow do strip-niecia"
        continue
    fi

    backup="$f.bak.$TIMESTAMP"
    cp "$f" "$backup"

    # Strip jednej warstwy otaczajacych " lub '. Zachowuje komentarze, puste
    # linie i trailing whitespace. Nie tyka linii ktore nie pasuja do
    # KEY=value (gdzie value otoczone " lub ').
    awk '
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
            print key "=" val trail
        }
    ' "$f" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"

    echo "$f: $fixed_in_file wartosci stripped, backup -> $backup"
    fixed_total=$((fixed_total + fixed_in_file))
done

if [ "$fixed_total" -eq 0 ]; then
    echo "Brak cudzyslowow do strip-niecia w zadnym .env. Nic do zrobienia."
fi
exit 0

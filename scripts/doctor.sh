#!/usr/bin/env bash
#
# BPP doctor - interaktywne menu diagnostyczne.
#
# Od wersji 2026.06 deploy (`make run`) NIE wysyla juz automatycznie testowych
# maili ani nie testuje Rollbara. Diagnostyke odpalasz na zadanie stad.
#
# Kazda pozycja menu wola z powrotem do `make` (test-email / test-ntfy /
# test-rollbar / health / backup-cycle) - single source of truth: straznicy env
# i komendy docker zyja w celach make, nie sa duplikowane tutaj.
#
# Uruchomienie:
#   make doctor                 # interaktywne menu
#   bash scripts/doctor.sh      # j.w.
#   bash scripts/doctor.sh mail # nieinteraktywnie: mail|ntfy|rollbar|health|backup|all
#
# Uwaga: NIE ustawiamy `-e` - zawodzacy pojedynczy test (np. brak env) ma wrocic
# do menu, a nie ubic calego doctora.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# `make doctor` eksportuje MAKE do recipe; fallback na "make" dla bezposredniego
# uruchomienia skryptu.
MAKE="${MAKE:-make}"

# Uruchom cel make z katalogu repo. Nie pozwalamy by porazka ubila doctora.
run_target() {
    ( cd "$REPO_DIR" && "$MAKE" "$1" )
}

# Mapa logicznej pozycji -> cel(e) make. Zwraca 2 dla nieznanej pozycji
# (uzywane w trybie nieinteraktywnym do walidacji argumentu).
run_choice() {
    case "$1" in
        mail)    run_target test-email ;;
        ntfy)    run_target test-ntfy ;;
        rollbar) run_target test-rollbar ;;
        health)  run_target health ;;
        backup)  run_target backup-cycle ;;
        all)
            # "wszystko" = trio powiadomien (dawne post-deploy zachowanie,
            # ale na zadanie). Swiadomie BEZ health/backup.
            run_target test-email
            run_target test-ntfy
            run_target test-rollbar
            ;;
        *)
            echo "BLAD: nieznana pozycja '$1'" >&2
            echo "Dozwolone: mail ntfy rollbar health backup all" >&2
            return 2
            ;;
    esac
}

print_menu() {
    cat <<'EOF'

=== BPP doctor — diagnostyka ===
  1) mail     — wyślij testowe e-maile        (test-email)
  2) ntfy     — wyślij testowy push           (test-ntfy)
  3) rollbar  — wyślij testowe zdarzenie      (test-rollbar)
  4) health   — status usług + ostatnie błędy (health)
  5) backup   — pełny cykl backupu            (backup-cycle)
  6) wszystko — mail + ntfy + rollbar po kolei
  q) wyjście
EOF
}

menu() {
    local choice
    while true; do
        print_menu
        printf 'Wybierz: '
        if ! read -r choice; then
            echo            # ladne zamkniecie na EOF / Ctrl-D
            break
        fi
        case "$choice" in
            1|mail)         run_choice mail || true ;;
            2|ntfy)         run_choice ntfy || true ;;
            3|rollbar)      run_choice rollbar || true ;;
            4|health)       run_choice health || true ;;
            5|backup)       run_choice backup || true ;;
            6|all|wszystko) run_choice all || true ;;
            q|Q|quit|exit)  break ;;
            "")             : ;;   # pusty Enter -> przerysuj menu
            *) echo "Nieznany wybór: $choice" >&2 ;;
        esac
    done
}

# Tryb nieinteraktywny: argument -> jedna pozycja, exit code z make (lub 2).
if [ "$#" -ge 1 ]; then
    run_choice "$1"
    exit $?
fi

menu

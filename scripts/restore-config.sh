#!/usr/bin/env bash
#
# Odtworzenie katalogu konfiguracyjnego ($BPP_CONFIGS_DIR) z archiwum
# config-backup-<TS>.tar.gz (nocny cykl / `make config-backup` / `make backup`).
#
# Uzycie (przez make):
#   make restore-config FILE=/sciezka/config-backup-20261024-023000.tar.gz
#   make restore-config FILE=... BPP_CONFIGS_DIR=/home/bpp/uczelnia   # nowy host
#   make restore-config FILE=... ONLY_ENV=1     # tylko .env, reszta nietknieta
#
# Bezpieczniki:
#   - archiwum rozpakowywane NAJPIERW do prywatnego katalogu tymczasowego
#     (umask 077); wpisy absolutne i z `..` -> odmowa;
#   - gdy docelowy .env istnieje i sie rozni: lista roznic (TYLKO nazwy
#     zmiennych, bez wartosci) i jawne potwierdzenie. EOF / brak TTY / cokolwiek
#     innego niz "tak" = NIE (nic nie zostaje zmienione). Pominiecie pytania:
#     BPP_RESTORE_CONFIG_YES=1;
#   - przed nadpisaniem: kopia poprzedniego .env jako
#     .env.przed-restore-<TS> (0600) oraz - przy pelnym restore - archiwum
#     calego dotychczasowego katalogu w $BPP_CONFIGS_DIR/../config-przed-restore-<TS>.tar.gz
#     (0600).
#
# Brak repo-lokalnego .env (swiezy host): skrypt dopisuje BPP_CONFIGS_DIR
# i COMPOSE_PROJECT_NAME (= basename katalogu, ta sama regula co init-configs),
# zeby NIE trzeba bylo uruchamiac `make`/`init-configs` - ten wygenerowalby
# nowe sekrety, w tym nowy klucz szyfrowania.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Nadpisywalne wylacznie na potrzeby testow (tests/test_makefile.sh).
REPO_ENV="${BPP_REPO_ENV_FILE:-$REPO_DIR/.env}"
FILE="${FILE:-${1:-}}"
TARGET="${BPP_CONFIGS_DIR:-}"
ONLY_ENV="${ONLY_ENV:-}"
TS="$(date +%Y%m%d-%H%M%S)"

die() { echo "BLAD: $*" >&2; exit 1; }

[ -n "$FILE" ] || die "podaj archiwum: make restore-config FILE=.../config-backup-<TS>.tar.gz"
[ -f "$FILE" ] || die "nie ma pliku: $FILE"
[ -r "$FILE" ] || die "brak prawa odczytu $FILE (archiwum ma tryb 0600 - uzyj sudo albo chown)"
[ -n "$TARGET" ] || die "nieznany katalog konfiguracyjny - podaj BPP_CONFIGS_DIR=/sciezka"
case "$TARGET" in
    /*) ;;
    *) die "BPP_CONFIGS_DIR musi byc sciezka absolutna (jest: $TARGET)" ;;
esac

# Walidacja listy wpisow przed rozpakowaniem czegokolwiek.
if ! LIST="$(tar tzf "$FILE")"; then
    die "$FILE nie jest poprawnym archiwum tar.gz"
fi
while IFS= read -r entry; do
    case "$entry" in
        /*|../*|*/../*|*/..|..) die "niebezpieczny wpis w archiwum: $entry" ;;
    esac
done <<< "$LIST"

umask 077
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/bpp-restore-config-XXXXXX")"
# shellcheck disable=SC2317  # wywolywane przez trap
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

tar xzf "$FILE" -C "$STAGE"
[ -f "$STAGE/.env" ] || die "w archiwum nie ma .env - to nie jest backup konfiguracji BPP"

env_names() { grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$1" | cut -d= -f1 | sort -u; }

echo "Archiwum:  $FILE"
echo "Cel:       $TARGET$([ -n "$ONLY_ENV" ] && echo ' (tylko .env)')"

if [ -f "$TARGET/.env" ]; then
    if cmp -s "$STAGE/.env" "$TARGET/.env" && [ -n "$ONLY_ENV" ]; then
        echo ".env jest identyczny z archiwum - nic do zrobienia."
        exit 0
    fi
    echo
    echo "Istniejacy $TARGET/.env zostanie NADPISANY. Roznice (nazwy zmiennych, bez wartosci):"
    # Zmienione wartosci: porownanie linii VAR=... bez ujawniania wartosci.
    changed="$(comm -3 <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$TARGET/.env" | sort -u) \
                       <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$STAGE/.env" | sort -u) \
               | sed 's/^[[:space:]]*//' | cut -d= -f1 | sort -u || true)"
    only_old="$(comm -23 <(env_names "$TARGET/.env") <(env_names "$STAGE/.env") || true)"
    only_new="$(comm -13 <(env_names "$TARGET/.env") <(env_names "$STAGE/.env") || true)"
    [ -n "$only_old" ] && printf '  - zniknie:  %s\n' $only_old
    [ -n "$only_new" ] && printf '  + dojdzie:  %s\n' $only_new
    for v in $changed; do
        # shellcheck disable=SC2116  # echo splaszcza nowe linie do spacji
        case " $(echo $only_old $only_new) " in *" $v "*) continue ;; esac
        printf '  ~ zmiana:   %s\n' "$v"
    done
    [ -z "$changed" ] && echo "  (brak roznic w zmiennych)"
    if grep -qx 'DJANGO_BPP_FIELD_ENCRYPTION_KEY' <<< "$changed"; then
        echo
        echo "  UWAGA: zmienia sie DJANGO_BPP_FIELD_ENCRYPTION_KEY. Sekrety w bazie sa"
        echo "  czytelne tylko kluczem, ktorym je zaszyfrowano - przywracaj .env z tego"
        echo "  samego okresu co baze."
    fi
    echo
    if [ "${BPP_RESTORE_CONFIG_YES:-}" = 1 ]; then
        echo "BPP_RESTORE_CONFIG_YES=1 - bez pytania."
    else
        printf 'Nadpisac? Wpisz "tak", aby kontynuowac: '
        answer=""
        read -r answer || true
        case "$answer" in
            tak|TAK|Tak) ;;
            *) echo "Przerwano - nic nie zostalo zmienione."; exit 1 ;;
        esac
    fi
    cp -p "$TARGET/.env" "$TARGET/.env.przed-restore-$TS"
    chmod 600 "$TARGET/.env.przed-restore-$TS"
    echo "Kopia poprzedniego .env: $TARGET/.env.przed-restore-$TS"
fi

mkdir -p "$TARGET"
if [ -n "$ONLY_ENV" ]; then
    cp "$STAGE/.env" "$TARGET/.env.restore-tmp-$TS"
    chmod 600 "$TARGET/.env.restore-tmp-$TS"
    mv -f "$TARGET/.env.restore-tmp-$TS" "$TARGET/.env"
else
    if [ -n "$(ls -A "$TARGET" 2>/dev/null)" ]; then
        prev="$(dirname "$TARGET")/config-przed-restore-$(basename "$TARGET")-$TS.tar.gz"
        tar czf "$prev" -C "$TARGET" --exclude='./.env.przed-restore-*' . \
            || die "nie udalo sie zarchiwizowac obecnego $TARGET (uprawnienia? uzyj sudo)"
        chmod 600 "$prev"
        echo "Kopia poprzedniego katalogu: $prev"
    fi
    # Z oryginalnego archiwum (lista wpisow zwalidowana wyzej), z `p`:
    # uprawnienia jak w zrodle. NIE z katalogu tymczasowego - jego wpis `./`
    # ma 0700 (mktemp) i zamknalby katalog konfiguracyjny przed kontenerami
    # dzialajacymi jako nie-root (grafana, loki, netdata czytaja bind-mounty).
    tar xpzf "$FILE" -C "$TARGET" \
        || die "nie udalo sie zapisac do $TARGET (uprawnienia? uzyj sudo)"
fi
chmod 600 "$TARGET/.env"
echo "Odtworzono: $TARGET/.env"

# Swiezy host: repo-lokalny .env (wskaznik na katalog konfiguracyjny).
if [ ! -f "$REPO_ENV" ]; then
    {
        echo "BPP_CONFIGS_DIR=$TARGET"
        echo "COMPOSE_PROJECT_NAME=$(basename "$TARGET")"
    } > "$REPO_ENV"
    echo "Zapisano $REPO_ENV (BPP_CONFIGS_DIR, COMPOSE_PROJECT_NAME)."
    echo "Baza zewnetrzna? Dopisz tam BPP_DATABASE_COMPOSE=docker-compose.database.external.yml."
fi

echo
echo "Gotowe. Dalej: make restore (baza + media), potem make up."

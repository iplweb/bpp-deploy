#!/bin/sh
#
# Archiwum katalogu konfiguracyjnego instancji ($BPP_CONFIGS_DIR): .env (hasla,
# DJANGO_BPP_SECRET_KEY, klucz szyfrowania sekretow DJANGO_BPP_FIELD_ENCRYPTION_KEY),
# rclone.conf (haslo remote'a backup_enc:), certyfikaty SSL, konfiguracja
# monitoringu. Bez tego katalogu zrzut bazy jest tylko w polowie uzyteczny:
# sekrety integracji w bazie sa zaszyfrowane kluczem z .env.
#
# Jedno zrodlo prawdy dla:
#   - kroku "config" w scripts/backup-cycle.sh (nocny cykl, backup-runner),
#   - `make config-backup` / `make backup` (efemeryczny kontener alpine).
# W obu przypadkach dziala jako root w kontenerze, wiec czyta tez pliki
# root:root 0600/0700 (letsencrypt/, rclone.conf sprzed rclone_fix_config_owner).
#
# Uzycie: config-backup.sh [TIMESTAMP]
#   Wynik: $BACKUP_DIR/config-backup-<TIMESTAMP>.tar.gz, tryb 0600, wlasciciel
#   = wlasciciel katalogu backupow (zeby `make restore-config` dzialal z konta
#   operatora bez sudo). Na stdout: sciezka archiwum (ostatnia linia).
#
# Zmienne (nadpisywalne tylko na potrzeby testow - produkcja ich nie ustawia):
#   BPP_CONFIG_SRC_DIR - zrodlo, default /configs   (mount :ro)
#   BPP_BACKUP_DIR     - cel,    default /backup
#
# Exit codes:
#   0 - archiwum utworzone
#   1 - blad tar/zapisu (czesciowy plik jest usuwany)
#   4 - brak katalogu zrodlowego (np. kontener sprzed `make up`, bez mountu)
#
# Celowo POSIX sh: dziala pod busybox ash (docker:cli, alpine) i pod bashem
# na hoscie (testy).

set -eu

TS="${1:-$(date +%Y%m%d-%H%M%S)}"
SRC="${BPP_CONFIG_SRC_DIR:-/configs}"
DEST_DIR="${BPP_BACKUP_DIR:-/backup}"
NAME="config-backup-${TS}.tar.gz"
OUT="${DEST_DIR}/${NAME}"
TMP="${DEST_DIR}/.${NAME}.tmp"

if [ ! -f "$SRC/.env" ]; then
    echo "BLAD: brak $SRC/.env - katalog konfiguracyjny nie jest zamontowany." >&2
    echo "      Po aktualizacji bpp-deploy wykonaj: make up" >&2
    exit 4
fi

# umask PRZED utworzeniem pliku, nie chmod po fakcie: archiwum zawiera klucz
# szyfrowania sekretow i hasla, wiec nie moze istniec ani chwili jako 0644.
umask 077

# Wykluczenia: logi (autoupdate-cron, nginx-limit) i katalog backupow, gdyby
# operator umiescil go wewnatrz katalogu konfiguracyjnego - archiwum ma byc
# male (konfiguracja, nie dane).
if ! tar czf "$TMP" -C "$SRC" \
        --exclude='./logs' \
        --exclude='./backups' \
        --exclude='*.log' \
        .; then
    rm -f "$TMP"
    echo "BLAD: tar katalogu konfiguracyjnego $SRC nie powiodl sie" >&2
    exit 1
fi
mv -f "$TMP" "$OUT"
chmod 600 "$OUT"

# Wlasciciel = wlasciciel katalogu backupow (wzorzec rclone_fix_config_owner:
# celujemy we wlasciciela KATALOGU, nie w `id -u` - pod `sudo` byloby to 0).
# Tylko gdy jestesmy rootem; blad to ostrzezenie, nie porazka backupu.
if [ "$(id -u)" = 0 ]; then
    owner="$(stat -c '%u:%g' "$DEST_DIR" 2>/dev/null || stat -f '%u:%g' "$DEST_DIR" 2>/dev/null || true)"
    if [ -n "$owner" ] && ! chown "$owner" "$OUT" 2>/dev/null; then
        echo "UWAGA: nie udalo sie ustawic wlasciciela $owner na $OUT" >&2
    fi
fi

echo "$OUT"

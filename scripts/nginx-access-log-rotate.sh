#!/bin/sh
# Rotacja pliku access_log czytanego przez kolektor netdata web_log.
#
# Uruchamiany przez Ofelia (job-exec na webserverze) — patrz etykiety w
# docker-compose.infrastructure.yml. Docker `local`/`json-file` log driver
# rotuje TYLKO stdout/stderr, a ten plik to zwykly plik na wolumenie
# nginx_access_log — bez rotacji rosnie w nieskonczonosc i zapycha dysk.
#
# Mechanizm: przenosimy biezacy log na .1 (jedna poprzednia generacja,
# nadpisywana przy kazdej rotacji -> max 2 pliki) i robimy `nginx -s reopen`.
# nginx master (PID 1, root) odtwarza sciezke biezacego logu i otwiera nowy
# deskryptor. netdata web_log wykrywa podmiane (inode) i czyta dalej od nowa.
#
# Mozliwa minimalna utrata kilku linii metryk w momencie rotacji — akceptowalne
# dla danych metrycznych (best-effort), surowe linie i tak sa w Loki.

set -eu

LOG_DIR=/var/log/nginx-shared
LOG_FILE="$LOG_DIR/bpp_access.log"

if [ ! -f "$LOG_FILE" ]; then
    echo "nginx-access-log-rotate: brak $LOG_FILE — nic do rotacji"
    exit 0
fi

mv -f "$LOG_FILE" "$LOG_FILE.1"
nginx -s reopen
echo "nginx-access-log-rotate: zrotowano $LOG_FILE -> $LOG_FILE.1 + nginx reopen"

#!/usr/bin/env bash
# DEPRECATED alias -> create-monitoring-user.sh
#
# Wczesniej ten skrypt nadawal role pg_monitor uzytkownikowi APLIKACJI (BPP),
# bo datasource Grafany laczyl sie tym uzytkownikiem. Od teraz monitoring
# uzywa osobnej, read-only roli `bpp_monitor` (bez DDL/DML) - tworzy ja
# create-monitoring-user.sh, ktory robi CREATE ROLE + GRANT pg_monitor +
# pg_read_all_data. Zachowujemy `make grant-pg-monitor` jako alias, zeby
# stare przyzwyczajenia/skrypty dzialaly.

set -euo pipefail

echo "Uwaga: 'grant-pg-monitor' jest przestarzale -> uruchamiam create-monitoring-user."
exec bash "$(cd "$(dirname "$0")" && pwd)/create-monitoring-user.sh" "$@"

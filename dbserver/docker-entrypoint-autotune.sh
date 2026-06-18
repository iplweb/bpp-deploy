#!/usr/bin/env bash
set -Eeuo pipefail

# Autotune entrypoint wrapper. Python-free — it shells out to autotune.sh, so it
# runs equally well INSIDE a custom image or BIND-MOUNTED onto the stock
# `postgres` image (no build, no python3). See examples/docker-compose.yml.

# Honour whatever PGDATA the image uses; default to the classic layout. Stock
# postgres:18+ defaults PGDATA to /var/lib/postgresql/18/docker, so we pin it
# and export it, both for our own appends below and for the upstream scripts.
: "${PGDATA:=/var/lib/postgresql/data}"
export PGDATA

# Path to the (Python-free) autotune script. Bind-mounted to /autotune.sh by
# default; override with AUTOTUNE_SCRIPT when mounting it elsewhere.
AUTOTUNE_SCRIPT="${AUTOTUNE_SCRIPT:-/autotune.sh}"

# Zainicjuj bazę danych standardowo (standardowo dla tego obrazu)
/usr/local/bin/docker-ensure-initdb.sh

# Jeżeli postgresql.conf nie zawiera linii "include_if_exists = /postgresql_optimized.conf"
# to dopisz ją na końcu pliku (idempotentnie):
conf="${PGDATA}/postgresql.conf"
grep -qxF "include_if_exists = '/postgresql_optimized.conf'" "$conf" \
  || echo "include_if_exists = '/postgresql_optimized.conf'" >> "$conf"

# Wygeneruj /postgresql_optimized.conf (bez Pythona — czysty shell + awk)
sh "$AUTOTUNE_SCRIPT" > /postgresql_optimized.conf

# Na tym etapie NIE ma potrzeby restartu serwera PostgreSQL, ponieważ zatrzymała go procedura
# stop_tempserver z docker-ensure-initdb/docker-entrypoint. Zatem, wystartuj wszystko normalnie
# z parametrami takimi, jak przekazane:

exec /usr/local/bin/docker-entrypoint.sh "$@"

#!/bin/sh
# shellcheck shell=sh
#
# Adresowanie kontenerow Compose z wnetrza orkiestratora.
# Biblioteka do sourcowania - nie uruchamiac bezposrednio.
#
# Po nazwie sie nie da: compose generuje `<projekt>-<usluga>-<n>`, a to repo nie
# ustawia `container_name:`. Po labelach jest stabilnie i odporne na zmiane
# numeru repliki.

# bpp_container <nazwa-serwisu>
#   Wypisuje ID pierwszego DZIALAJACEGO kontenera danego serwisu.
#   Status 1, gdy nie ma zadnego - caller ma o czym raportowac, zamiast wolac
#   `docker exec ""` i dostac mylacy komunikat dockera.
bpp_container() {
    _svc="$1"
    _id="$(docker ps --quiet --no-trunc \
        --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME:-}" \
        --filter "label=com.docker.compose.service=${_svc}" \
        --filter "status=running" | sed -n '1p')"
    # `sed -n 1p`, nie `head -1`: head zamyka wejscie i producent dostaje SIGPIPE,
    # co pod `pipefail` wywraca caly cykl.
    [ -n "$_id" ] || return 1
    printf '%s' "$_id"
}

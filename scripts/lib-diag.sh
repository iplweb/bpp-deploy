#!/usr/bin/env bash
# shellcheck shell=bash
#
# Wspolne kawalki read-only diagnostyki bazy (make db-connection-stats,
# make pgbouncer-stats). Biblioteka do sourcowania — nie uruchamiac.
#
# Kazde zrodlo danych idzie przez diag_fetch, ktory pod BPP_DIAG_FIXTURES
# czyta plik zamiast dockera. Istnieje WYLACZNIE dla testow
# (test_diag_db_commands w tests/test_makefile.sh) — asercje maja odpalac
# prawdziwy parser na wyjsciu z prawdziwego pgbouncera/PostgreSQL, a nie
# grepowac zrodlo. Ten sam wzorzec co BPP_BACKUP_DIR w backup-cycle.sh.

# diag_fetch NAZWA KOMENDA... — wyjscie komendy albo fixture NAZWA.
diag_fetch() {
    local nazwa="$1"; shift
    if [ -n "${BPP_DIAG_FIXTURES:-}" ]; then
        cat "$BPP_DIAG_FIXTURES/$nazwa"
        return
    fi
    "$@"
}

# diag_ip_map — linie "<usluga> <ip> [<ip>...]" dla kontenerow TEGO projektu
# compose. Pozwala zamienic client_addr z PostgreSQL/pgbouncera na nazwe
# uslugi. Po labelu, nie po nazwie kontenera (nazwy generuje compose).
diag_ip_map() {
    local ids
    ids="$(docker compose ps -q 2>/dev/null || true)"
    [ -n "$ids" ] || return 0
    # shellcheck disable=SC2086  # celowo: lista ID rozbita po bialych znakach
    docker inspect --format \
        '{{index .Config.Labels "com.docker.compose.service"}}{{range .NetworkSettings.Networks}} {{.IPAddress}}{{end}}' \
        $ids 2>/dev/null || true
}

# diag_service_running USLUGA — 0, gdy usluga ma dzialajacy kontener.
diag_service_running() {
    [ -n "${BPP_DIAG_FIXTURES:-}" ] && return 0
    [ -n "$(docker compose ps -q --status running "$1" 2>/dev/null)" ]
}

# Funkcje awk wspolne dla rendererow: format czasu i mapa IP -> usluga.
# Wklejane na poczatek programu awk (awk nie ma include).
# shellcheck disable=SC2034  # uzywane przez skrypty sourcujace
DIAG_AWK_LIB='
function wiek(s) {
    if (s == "" || s < 0) return "-"
    if (s < 60)    return sprintf("%d s", s)
    if (s < 3600)  return sprintf("%d min", int(s / 60))
    if (s < 86400) return sprintf("%d h %d min", int(s / 3600), int((s % 3600) / 60))
    return sprintf("%d d %d h", int(s / 86400), int((s % 86400) / 3600))
}
function laduj_mape(plik,   linia, n, pola, i) {
    while ((getline linia < plik) > 0) {
        n = split(linia, pola, " ")
        for (i = 2; i <= n; i++) if (pola[i] != "") usluga[pola[i]] = pola[1]
    }
    close(plik)
}
function kto(ip) {
    if (ip == "" || ip == "-") return "(gniazdo lokalne)"
    return (ip in usluga) ? usluga[ip] : ip
}
'

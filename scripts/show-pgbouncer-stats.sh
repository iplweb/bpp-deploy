#!/usr/bin/env bash
# ============================================================================
# show-pgbouncer-stats.sh — stan puli appservera w pgbouncerze (read-only)
# ============================================================================
# `make pgbouncer-stats`. Tlumaczy SHOW POOLS / SHOW CLIENTS z konsoli
# administracyjnej pgbouncera na trzy odpowiedzi:
#
#   1. Czy pula jest pelna?  (klienci w kolejce, najdluzsze czekanie)
#   2. Ile z puli jest naprawde zajete, a ile wolne?  `idle` w
#      pg_stat_activity tego nie powie — w trybie session sesja klienta
#      trzyma backend takze MIEDZY zapytaniami.
#   3. Czy sesje nie wisza bez zapytan?  Klient "active" z dawnym
#      request_time to polaczenie trzymane, ale nieuzywane. Liczba STALA
#      miedzy pomiarami (~ liczba procesow gunicorna) = narzut startowy;
#      ROSNACA = appserver nie oddaje polaczen i w koncu zapcha pule.
#      Dlugie zapytanie tez ma dawny request_time — porownaj z kolumna
#      `active` w `make db-connection-stats`.
#
# Konsola: baza `pgbouncer`, konto DJANGO_BPP_DB_USER (stats_users w
# pgbouncer/entrypoint.sh). Haslo czytane w kontenerze, nie przez `-e`.
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"
# shellcheck source=scripts/lib-diag.sh
. "$REPO_DIR/scripts/lib-diag.sh"

# Z naglowkiem (kolumny szukamy po nazwie — zmieniaja sie miedzy wersjami
# pgbouncera), bez stopki "(N rows)".
pgb_show() {
    docker compose exec -T pgbouncer sh -c '
        PGPASSWORD="$DJANGO_BPP_DB_PASSWORD" PGCONNECT_TIMEOUT=5 \
        psql -X -h 127.0.0.1 -p 6432 -U "$DJANGO_BPP_DB_USER" -d pgbouncer \
             -A -F"|" -P footer=off -c "$1"' sh "$1"
}
# "Teraz" z TEGO SAMEGO kontenera co znaczniki czasu pgbouncera — ta sama
# strefa czasowa, wiec roznica jest poprawna bez wzgledu na TZ.
pgb_now() { docker compose exec -T pgbouncer date '+%Y-%m-%d %H:%M:%S'; }

if ! diag_service_running pgbouncer; then
    echo "BLAD: kontener pgbouncer nie dziala." >&2
    echo "      Na wersji sprzed 2026-09-28 puli nie ma wcale — appserver laczy sie" >&2
    echo "      z baza bezposrednio (git pull && make up). Stan: make ps" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! diag_fetch pgb-pools.txt pgb_show "SHOW POOLS" >"$TMP/pools" \
    || ! diag_fetch pgb-databases.txt pgb_show "SHOW DATABASES" >"$TMP/dbs" \
    || ! diag_fetch pgb-clients.txt pgb_show "SHOW CLIENTS" >"$TMP/clients" \
    || ! diag_fetch pgb-now.txt pgb_now >"$TMP/now"; then
    echo "BLAD: konsola pgbouncera nie odpowiada (komunikat wyzej)." >&2
    exit 1
fi
diag_fetch ip-map.txt diag_ip_map >"$TMP/mapa"

awk -F'|' -v mapa="$TMP/mapa" -v teraz_plik="$TMP/now" "$DIAG_AWK_LIB"'
# Sekundy od dowolnej stalej epoki — liczymy tylko roznice. Czyste awk
# (mktime to rozszerzenie gawk; na hoscie bywa mawk albo BSD awk).
function sek(s,   y, m, d) {
    y = substr(s, 1, 4) + 0; m = substr(s, 6, 2) + 0; d = substr(s, 9, 2) + 0
    if (m <= 2) { y--; m += 12 }
    return (365 * y + int(y / 4) - int(y / 100) + int(y / 400) + int((153 * (m - 3) + 2) / 5) + d) * 86400 \
        + substr(s, 12, 2) * 3600 + substr(s, 15, 2) * 60 + substr(s, 18, 2)
}
# Kolumna po nazwie; brak kolumny = "" (gole $c["x"] dawaloby $0 — cala linie).
function kol(n) { return (n in c) ? $(c[n]) : "" }
function techniczna(db) { return db == "pgbouncer" || db ~ /_health$/ }
BEGIN {
    laduj_mape(mapa)
    getline teraz < teraz_plik; TERAZ = sek(teraz)
}
FNR == 1 { split("", c); for (i = 1; i <= NF; i++) c[$i] = i; next }
FILENAME == ARGV[1] {   # SHOW POOLS
    db = kol("database"); if (techniczna(db)) next
    if (!(db in tryb)) bazy[++nb] = db
    tryb[db] = kol("pool_mode")
    cl_akt[db] += kol("cl_active"); cl_czeka[db] += kol("cl_waiting")
    sv_akt[db] += kol("sv_active"); sv_idle[db] += kol("sv_idle")
    sv_used[db] += kol("sv_used"); sv_test[db] += kol("sv_tested"); sv_login[db] += kol("sv_login")
    w = kol("maxwait") + kol("maxwait_us") / 1000000
    if (w > maxwait[db]) maxwait[db] = w
    next
}
FILENAME == ARGV[2] {   # SHOW DATABASES
    if (techniczna(kol("name"))) next
    pula[kol("name")] = kol("pool_size")
    cel[kol("name")] = kol("host") ":" kol("port") "/" ((kol("database") != "") ? kol("database") : kol("name"))
    next
}
FILENAME == ARGV[3] {   # SHOW CLIENTS
    if (techniczna(kol("database"))) next
    stan = kol("state"); ktory = kto(kol("addr"))
    if (!(ktory in kl_razem)) kl_kto[++nk] = ktory
    kl_razem[ktory]++
    if (stan == "waiting") { kl_w[ktory]++; next }
    if (stan != "active") { kl_inne[ktory]++; next }
    kl_a[ktory]++
    s = TERAZ - sek(kol("request_time"))
    if (s < 10) b1++; else if (s < 60) b2++; else if (s < 300) { b3++; stare++ } else { b4++; stare++ }
    if (s >= 60 && s > najstarsza) { najstarsza = s; najst_kto = ktory; najst_od = kol("connect_time") }
}
END {
    if (nb == 0) { print "Brak puli w pgbouncerze (SHOW POOLS puste)."; exit 1 }
    for (i = 1; i <= nb; i++) {
        db = bazy[i]; wolne = sv_idle[db] + sv_used[db] + sv_test[db]
        printf "== pgbouncer: pula %s -> %s (tryb %s) ==\n", db, cel[db], tryb[db]
        printf "Pula:     %d polaczen do PostgreSQL (PGBOUNCER_POOL_SIZE, po przycieciu)\n", pula[db]
        printf "Serwery:  %d przypisane klientom | %d wolne (%d idle, %d used, %d tested) | %d loguje sie\n", \
            sv_akt[db], wolne, sv_idle[db], sv_used[db], sv_test[db], sv_login[db]
        printf "Klienci:  %d obsluzonych | %d w kolejce | najdluzej czeka %.1f s\n\n", cl_akt[db], cl_czeka[db], maxwait[db]
        if (cl_czeka[db] > 0)
            printf "UWAGA: pula %s jest pelna, w kolejce: %d. Po query_wait_timeout (15 s)\nczekajacy dostaja blad. Sprawdz ponizej, czy sesje nie wisza bez zapytan.\n\n", db, cl_czeka[db]
    }

    print "Obsluzeni klienci — czas od ostatniego zapytania:"
    printf "   %-10s %5d\n   %-10s %5d\n   %-10s %5d\n   %-10s %5d\n\n", "< 10 s", b1, "10-60 s", b2, "1-5 min", b3, "> 5 min", b4

    print "Klienci wg kontenera:"
    for (i = 1; i <= nk; i++) {
        k = kl_kto[i]
        printf "   %-22s %5d  (obsluzeni %d, w kolejce %d, inne %d)\n", k, kl_razem[k], kl_a[k], kl_w[k], kl_inne[k]
    }
    if (nk == 0) print "   (brak)"

    if (stare > 0) {
        printf "\nUWAGA: sesje trzymajace polaczenie ponad minute bez nowego zapytania: %d\n", stare
        printf "(najdluzej: %s, %s; polaczona od %s).\n", najst_kto, wiek(najstarsza), substr(najst_od, 1, 19)
        print "Powtorz pomiar za kilkanascie minut pod ruchem: liczba STALA (~ liczba procesow"
        print "gunicorna) = narzut startowy, niegrozny; ROSNACA = appserver nie oddaje polaczen."
        print "Dlugie zapytania tez tu trafiaja — porownaj z kolumna active w make db-connection-stats."
    }
}' "$TMP/pools" "$TMP/dbs" "$TMP/clients"

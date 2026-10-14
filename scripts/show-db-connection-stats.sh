#!/usr/bin/env bash
# ============================================================================
# show-db-connection-stats.sh — kto trzyma polaczenia z PostgreSQL (read-only)
# ============================================================================
# `make db-connection-stats`. Odpowiada na pytanie z incydentu "KATASTROFALNY:
# przepraszamy, mamy zbyt wielu klientow": ile z max_connections jest zajete
# i PRZEZ KTORY KONTENER. Adresy klientow zamienia na nazwy uslug compose.
#
# Jak czytac: pgbouncer ma twardy sufit (pula), wiec przepelnienie przy
# dzialajacej puli robi "reszta" — uslugi laczace sie bezposrednio (Celery,
# denorm-queue, beat, authserver, netdata). Kolumna "najdluzej bezczynne"
# przy pgbouncerze to wolne polaczenia puli ALBO sesje trzymane przez
# klientow — rozroznia je dopiero `make pgbouncer-stats`.
#
# Dziala w obu trybach bazy: psql leci z kontenera dbserver (w trybie
# external to sentinel) na DJANGO_BPP_DB_HOST. W trybie external adresy
# klientow sa po NAT-cie i zwykle nie mapuja sie na uslugi — wtedy widac IP.
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"
# shellcheck source=scripts/lib-diag.sh
. "$REPO_DIR/scripts/lib-diag.sh"

# Haslo czytane W KONTENERZE z jego env (nie przez `-e`, ktore widac w `ps`).
# SQL jako argument pozycyjny sh — bez sklejania cudzyslowow.
pg_sql() {
    docker compose exec -T dbserver sh -c '
        PGPASSWORD="$DJANGO_BPP_DB_PASSWORD" PGCONNECT_TIMEOUT=5 \
        psql -X -h "$DJANGO_BPP_DB_HOST" -p "${DJANGO_BPP_DB_PORT:-5432}" \
             -U "$DJANGO_BPP_DB_USER" -d "$DJANGO_BPP_DB_NAME" \
             -Atq -F"|" -v ON_ERROR_STOP=1 -c "$1"' sh "$1"
}

SQL_LIMITY="SELECT current_setting('max_connections'),
    current_setting('superuser_reserved_connections'),
    coalesce(current_setting('reserved_connections', true), '0')"

# pid <> pg_backend_pid(): bez tej sondy we wlasnych wynikach.
SQL_KLIENCI="SELECT coalesce(host(client_addr), '-'), coalesce(usename, '?'),
    coalesce(state, '?'), count(*),
    coalesce(max(extract(epoch FROM now() - state_change))
             FILTER (WHERE state = 'idle')::int, -1),
    coalesce(max(extract(epoch FROM now() - xact_start))
             FILTER (WHERE state LIKE 'idle in transaction%')::int, -1)
  FROM pg_stat_activity
  WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
  GROUP BY 1, 2, 3"

if ! diag_service_running dbserver; then
    echo "BLAD: kontener dbserver nie dziala — nie ma skad zapytac bazy (make ps)." >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! diag_fetch pg-limity.txt pg_sql "$SQL_LIMITY" >"$TMP/limity" \
    || ! diag_fetch pg-klienci.txt pg_sql "$SQL_KLIENCI" >"$TMP/klienci"; then
    echo "BLAD: zapytanie do PostgreSQL nie powiodlo sie (komunikat wyzej)." >&2
    echo "      Gdy baza odrzuca polaczenia ('zbyt wielu klientow'), ta sonda tez" >&2
    echo "      nie wejdzie — zostaje: make logs-dbserver, make pgbouncer-stats." >&2
    exit 1
fi
diag_fetch ip-map.txt diag_ip_map >"$TMP/mapa"

awk -F'|' -v mapa="$TMP/mapa" -v limity="$TMP/limity" "$DIAG_AWK_LIB"'
BEGIN {
    laduj_mape(mapa)
    getline l < limity; split(l, L, "|")
    maxc = L[1] + 0; zarezerw = L[2] + L[3]
}
{
    k = kto($1) SUBSEP $2
    if (!(k in razem)) kolejnosc[++n] = k
    stan = $3
    if (stan == "active") akt[k] += $4
    else if (stan == "idle") bezcz[k] += $4
    else if (stan ~ /^idle in transaction/) wtx[k] += $4
    else inne[k] += $4
    razem[k] += $4; suma += $4
    if ($5 > maxidle[k]) maxidle[k] = $5
    if ($6 > maxtx[k]) maxtx[k] = $6
}
END {
    dostepne = maxc - zarezerw
    printf "== PostgreSQL: polaczenia klientow ==\n"
    printf "max_connections %d (w tym %d zarezerwowane dla superusera) | zajete %d", maxc, zarezerw, suma
    if (dostepne > 0) printf " (%d%% dostepnych) | wolne %d", 100 * suma / dostepne, dostepne - suma
    printf "\n\n"
    if (suma == 0) { print "  (brak polaczen klientow poza ta sonda)"; exit }

    # sortowanie malejaco po razem (n jest male — wystarczy wybor)
    for (i = 1; i <= n; i++) idx[i] = kolejnosc[i]
    for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++)
        if (razem[idx[j]] > razem[idx[i]]) { t = idx[i]; idx[i] = idx[j]; idx[j] = t }

    printf "  %-22s %-14s %6s %6s %8s %6s %6s   %s\n", "kto", "rola", "active", "idle", "idle-tx", "inne", "razem", "najdluzej bezczynne"
    for (i = 1; i <= n; i++) {
        k = idx[i]; split(k, p, SUBSEP)
        printf "  %-22s %-14s %6d %6d %8d %6d %6d   %s\n", p[1], p[2], akt[k], bezcz[k], wtx[k], inne[k], razem[k], wiek(maxidle[k])
        if (p[1] == "pgbouncer") pgb += razem[k]
        if (maxtx[k] >= 60) dlugietx = dlugietx sprintf("\n    %s: transakcja otwarta od %s", p[1], wiek(maxtx[k]))
    }

    print ""
    if (dostepne > 0 && suma >= 0.9 * dostepne)
        print "UWAGA: ponad 90% dostepnych polaczen zajete — baza zaraz zacznie odrzucac klientow."
    if (pgb > 0)
        printf "pgbouncer trzyma %d (pula appservera, sufit z PGBOUNCER_POOL_SIZE). Czy to wolne\npolaczenia puli, czy sesje zajete przez appserver — pokaze: make pgbouncer-stats\n", pgb
    if (dlugietx != "")
        printf "UWAGA: \"idle in transaction\" dluzej niz minute (trzyma blokady i slot):%s\n", dlugietx
}' "$TMP/klienci"

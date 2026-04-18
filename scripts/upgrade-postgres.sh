#!/usr/bin/env bash
#
# Major version upgrade Postgresa (np. 16.13 -> 18.3) dla deploymentu BPP.
#
# Strategia: logical dump & restore.
#   1. pg_dump -Fd -j N (przez `make db-backup`) starego clustra
#   2. zachowanie starego volume jako kopii (na wypadek rollbacku)
#   3. bump DJANGO_BPP_POSTGRESQL_VERSION w $BPP_CONFIGS_DIR/.env
#   4. docker compose pull dbserver -> nowy obraz z nowym majorem
#   5. docker compose up -d dbserver -> initdb na nowej wersji w pustym volume
#   6. pg_restore -Fd -j N z tarballa
#   7. make migrate, make up, smoke test
#
# Wybor dump & restore zamiast pg_upgrade jest swiadomy: obraz iplweb/bpp_dbserver
# ma tylko jeden major Postgresa baked in, wiec pg_upgrade in-place wymagalby
# dedykowanego upgrade-image z dwiema binariami. Logical dump wykorzystuje
# istniejacy `make db-backup` i jest forward-compatible przez wiele majorow.
#
# Tryb external (BPP_DATABASE_COMPOSE=docker-compose.database.external.yml) ma
# wlasna, drastycznie prostsza sciezke - upgrade prawdziwej bazy robi admin po
# stronie hosta, deploy repo tylko bumpuje wersje sentinela/backup-runnera.
#
# Wymagania:
#   - Docker Compose v2.20+ (juz wymagane przez include w docker-compose.yml)
#   - Wystarczajaco miejsca na hoscie na: tarball pg_dump + drugi volume z kopia
#     starego PGDATA. Dla DB rozmiaru X potrzeba ~2.5 * X wolnego miejsca.
#   - Upstream image iplweb/bpp_dbserver:<TAG> z nowym majorem MUSI byc juz
#     wypchniety na Docker Hub. Skrypt nie buduje obrazu.
#
# Wywolanie: `make upgrade-postgres` lub bezposrednio `bash scripts/upgrade-postgres.sh`.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ENV="$REPO_DIR/.env"

# Helpery do czytania/pisania .env BEZ `source`. Plik .env uzytkownika moze zawierac
# wartosci ktore shell potraktowalby jako skladnie: `ADMINS=admin <foo@bar.pl>`
# (redirect), backtick w passwordzie, niezamkniete cudzyslowy, znak `$` itd.
# Docker Compose nie ma z tym problemu bo uzywa wlasnego parsera KEY=VALUE,
# a `source` probuje interpretowac cala linie jako bash i sie wywala. Robimy tu
# to co Compose: czytamy tylko surowe pary klucz=wartosc linia po linii.
env_has_var() {
    grep -q "^${1}=" "$2" 2>/dev/null
}

get_env_var() {
    local raw
    raw="$(grep -E "^${1}=" "$2" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
    if [ "${raw#\"}" != "$raw" ] && [ "${raw%\"}" != "$raw" ]; then
        raw="${raw#\"}"; raw="${raw%\"}"
    fi
    if [ "${raw#\'}" != "$raw" ] && [ "${raw%\'}" != "$raw" ]; then
        raw="${raw#\'}"; raw="${raw%\'}"
    fi
    printf '%s' "$raw"
}

set_env_var() {
    local var_name="$1" value="$2" file="$3"
    if env_has_var "$var_name" "$file"; then
        local tmp="$file.tmp.$$"
        awk -v k="$var_name" -v v="$value" '
            BEGIN { FS=OFS="=" }
            $1 == k { print k "=" v; next }
            { print }
        ' "$file" > "$tmp" && mv "$tmp" "$file"
    else
        printf '\n%s=%s\n' "$var_name" "$value" >> "$file"
    fi
}

confirm() {
    local prompt="$1" answer
    read -r -p "$prompt [yes/NO]: " answer
    [ "$answer" = "yes" ]
}

run() {
    echo "+ $*"
    "$@"
}

if [ ! -f "$REPO_ENV" ]; then
    echo "BLAD: brak $REPO_ENV. Najpierw uruchom 'make' zeby zainicjalizowac konfiguracje." >&2
    exit 1
fi

# Repo .env trzyma: BPP_CONFIGS_DIR, COMPOSE_PROJECT_NAME, opcjonalnie BPP_DATABASE_COMPOSE.
BPP_CONFIGS_DIR="$(get_env_var BPP_CONFIGS_DIR "$REPO_ENV")"
COMPOSE_PROJECT_NAME="$(get_env_var COMPOSE_PROJECT_NAME "$REPO_ENV")"
BPP_DATABASE_COMPOSE="$(get_env_var BPP_DATABASE_COMPOSE "$REPO_ENV")"

if [ -z "$BPP_CONFIGS_DIR" ]; then
    echo "BLAD: BPP_CONFIGS_DIR nie ustawione w $REPO_ENV." >&2
    exit 1
fi

APP_ENV="$BPP_CONFIGS_DIR/.env"
if [ ! -f "$APP_ENV" ]; then
    echo "BLAD: brak $APP_ENV. Uruchom 'make init-configs'." >&2
    exit 1
fi

# Aplikacyjne zmienne - ladujemy tylko to, czego skrypt faktycznie uzywa. NIE
# sourcujemy calego .env (patrz komentarz przy get_env_var powyzej).
DJANGO_BPP_DB_PASSWORD="$(get_env_var DJANGO_BPP_DB_PASSWORD "$APP_ENV")"
DJANGO_BPP_DB_HOST="$(get_env_var DJANGO_BPP_DB_HOST "$APP_ENV")"
DJANGO_BPP_DB_PORT="$(get_env_var DJANGO_BPP_DB_PORT "$APP_ENV")"
DJANGO_BPP_DB_USER="$(get_env_var DJANGO_BPP_DB_USER "$APP_ENV")"
DJANGO_BPP_DB_NAME="$(get_env_var DJANGO_BPP_DB_NAME "$APP_ENV")"
DJANGO_BPP_HOST_BACKUP_DIR="$(get_env_var DJANGO_BPP_HOST_BACKUP_DIR "$APP_ENV")"

cd "$REPO_DIR"

# ---------------------------------------------------------------------------
# Tryb external: nie ma lokalnego clustra do upgrade'u. Pokazujemy instrukcje.
# ---------------------------------------------------------------------------
DATABASE_COMPOSE="${BPP_DATABASE_COMPOSE:-docker-compose.database.yml}"

if [ "$DATABASE_COMPOSE" = "docker-compose.database.external.yml" ]; then
    # Fallback na stare nazwy (sprzed rename 2026-04-18): jesli .env nie
    # przeszlo jeszcze przez init-configs po git pull, czytamy z legacy var.
    _cur_ext_major="$(get_env_var DJANGO_BPP_POSTGRESQL_VERSION_MAJOR "$APP_ENV")"
    if [ -z "$_cur_ext_major" ]; then
        _cur_ext_major="$(get_env_var DJANGO_BPP_POSTGRESQL_DB_VERSION "$APP_ENV")"
    fi
    cat <<EOF

=== Tryb EXTERNAL ===

Lokalnie nie ma clustra Postgresa do upgrade'u - dbserver to tylko sentinel
postgres:\${DJANGO_BPP_POSTGRESQL_VERSION_MAJOR}-alpine. Prawdziwa baza zyje
poza compose i jej upgrade jest poza scope tego skryptu.

Procedura po stronie BPP (po skutecznym upgrade'ie zewnetrznej bazy):

  1. Upgrade'uj zewnetrzna baze (managed service, RDS blue/green,
     pg_upgradecluster - cokolwiek odpowiednie dla Twojego setupu).

  2. W $APP_ENV bumpnij:
       DJANGO_BPP_POSTGRESQL_VERSION=<nowy_major>
       DJANGO_BPP_POSTGRESQL_VERSION_MAJOR=<nowy_major>
     (obecnie: ${_cur_ext_major:-<nieustawione>})

  3. make up
     -> recreate sentinela i backup-runnera na nowym obrazie
        postgres:<nowy_major>-alpine.

EOF

    if confirm "Wykonac krok 2 i 3 teraz (autopilot)?"; then
        read -r -p "Nowy major Postgresa (np. 18): " NEW_MAJOR
        if ! [[ "$NEW_MAJOR" =~ ^[0-9]+$ ]]; then
            echo "BLAD: '$NEW_MAJOR' nie jest liczba." >&2
            exit 1
        fi
        run set_env_var DJANGO_BPP_POSTGRESQL_VERSION "$NEW_MAJOR" "$APP_ENV"
        run set_env_var DJANGO_BPP_POSTGRESQL_VERSION_MAJOR "$NEW_MAJOR" "$APP_ENV"
        # Sprzatanie starej nazwy (po rename 2026-04-18) zeby uniknac rozjazdu.
        if env_has_var "DJANGO_BPP_POSTGRESQL_DB_VERSION" "$APP_ENV"; then
            awk '!/^DJANGO_BPP_POSTGRESQL_DB_VERSION=/' "$APP_ENV" > "$APP_ENV.tmp.$$" \
                && mv "$APP_ENV.tmp.$$" "$APP_ENV"
            echo "Usunieto stara DJANGO_BPP_POSTGRESQL_DB_VERSION (po migracji)."
        fi
        echo "Zaktualizowano wersje PostgreSQL na $NEW_MAJOR w $APP_ENV"
        run docker compose pull dbserver backup-runner
        run docker compose up -d dbserver backup-runner
        echo
        echo "Gotowe. Sentinel i backup-runner dzialaja na postgres:${NEW_MAJOR}-alpine."
        echo "Sprawdz: docker compose exec dbserver pg_isready -h \$DJANGO_BPP_DB_HOST"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Tryb local: pelna procedura dump & restore.
# ---------------------------------------------------------------------------

if [ -z "${COMPOSE_PROJECT_NAME:-}" ]; then
    echo "BLAD: COMPOSE_PROJECT_NAME nie ustawione w $REPO_ENV (potrzebne do nazwy volume)." >&2
    exit 1
fi

VOLUME_NAME="${COMPOSE_PROJECT_NAME}_postgresql_data"

if ! docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
    echo "BLAD: volume $VOLUME_NAME nie istnieje. Czy stack byl kiedykolwiek uruchomiony?" >&2
    exit 1
fi

# Sanity check: dbserver dziala i da sie odpytac o wersje.
if ! docker compose ps --status=running --services 2>/dev/null | grep -qx dbserver; then
    echo "BLAD: dbserver nie dziala. Najpierw uruchom 'make up' zeby moc wykonac pg_dump." >&2
    exit 1
fi

CURRENT_PG_VERSION="$(docker compose exec -T dbserver postgres --version 2>/dev/null || echo unknown)"
CURRENT_PG_MAJOR="$(echo "$CURRENT_PG_VERSION" | grep -oE '[0-9]+' | head -1 || echo 0)"
# Czytamy z nowej nazwy (DJANGO_BPP_POSTGRESQL_VERSION) z fallbackiem na stara
# (DJANGO_BPP_DBSERVER_PG_VERSION) - patrz komentarze w docker-compose.database.yml.
CURRENT_POSTGRESQL_VERSION="$(get_env_var DJANGO_BPP_POSTGRESQL_VERSION "$APP_ENV")"
if [ -z "$CURRENT_POSTGRESQL_VERSION" ]; then
    CURRENT_POSTGRESQL_VERSION="$(get_env_var DJANGO_BPP_DBSERVER_PG_VERSION "$APP_ENV")"
fi
CURRENT_POSTGRESQL_VERSION="${CURRENT_POSTGRESQL_VERSION:-16.13 (default z compose, brak w .env)}"

cat <<EOF

=== PostgreSQL Major Upgrade (tryb LOCAL) ===

Project:                            $COMPOSE_PROJECT_NAME
Volume:                             $VOLUME_NAME
Obecna wersja PG (z kontenera):     $CURRENT_PG_VERSION
Obecny DJANGO_BPP_POSTGRESQL_VERSION: $CURRENT_POSTGRESQL_VERSION

Procedura wykona:
  1. Pull nowego obrazu dbservera (fail-fast - zanim cokolwiek destrukcyjnego;
     jesli siec padnie lub tag nie istnieje, dowiemy sie TERAZ a nie po
     skasowaniu volume)
  2. pg_dump aktualnego clustra (przez 'make db-backup')
  3. Zatrzyma dependent services (app, workers, beat, denorm-queue, flower, authserver)
  4. Zatrzyma i usunie kontener dbserver
  5. Skopiuje obecny volume $VOLUME_NAME do volume backupowego
     (wymaga ~rozmiar_PGDATA wolnego miejsca w docker volumes)
  6. Usunie obecny volume $VOLUME_NAME
     (nowy kontener musi uzywac nowego, pustego woluminu - miedzy majorami
      Postgresa NIE ma binarnej kompatybilnosci formatu PGDATA)
  7. Bumpnie DJANGO_BPP_POSTGRESQL_VERSION + _MAJOR w $APP_ENV
  8. Start nowego dbserver -> initdb na nowym majorze
     (w razie failu - prompt o auto-rollback z backup volume)
  9. pg_restore z tarballa
 10. make migrate, make up, smoke test

Stary volume bedzie zachowany pod nowa nazwa az do recznego usuniecia.
Tarball z pg_dump tez zostaje w \$DJANGO_BPP_HOST_BACKUP_DIR.

EOF

echo "Dostepne tagi (psql-<ver>): https://hub.docker.com/r/iplweb/bpp_dbserver/tags"
read -r -p "Nowa wersja dbservera (format MAJOR.MINOR, np. 18.3): " NEW_POSTGRESQL_VERSION
if [ -z "$NEW_POSTGRESQL_VERSION" ]; then
    echo "BLAD: wersja nie moze byc pusta." >&2
    exit 1
fi
if ! [[ "$NEW_POSTGRESQL_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "BLAD: '$NEW_POSTGRESQL_VERSION' nie pasuje do formatu MAJOR.MINOR (np. 18.3)." >&2
    exit 1
fi

EXPECTED_MAJOR="${NEW_POSTGRESQL_VERSION%%.*}"

if [ "$EXPECTED_MAJOR" -le "$CURRENT_PG_MAJOR" ]; then
    echo "BLAD: nowy major ($EXPECTED_MAJOR) <= obecny ($CURRENT_PG_MAJOR). Upgrade w dol nie jest wspierany." >&2
    echo "      Do minor upgrade'u (np. 16.13 -> 16.14) uzyj zwyklego 'docker compose pull dbserver && docker compose up -d dbserver'." >&2
    exit 1
fi

if ! confirm "Kontynuowac upgrade $CURRENT_PG_MAJOR -> $EXPECTED_MAJOR (DJANGO_BPP_POSTGRESQL_VERSION: $CURRENT_POSTGRESQL_VERSION -> $NEW_POSTGRESQL_VERSION)?"; then
    echo "Anulowano."
    exit 0
fi

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_VOLUME="${VOLUME_NAME}_pg${CURRENT_PG_MAJOR}_${TS}"
ROLLBACK_FILE="$BPP_CONFIGS_DIR/.upgrade-rollback-${TS}"

# Trap z duzym banerem na wypadek awarii po krytycznym kroku (gdy
# auto_rollback nie zostal wywolany - np. przerwanie Ctrl-C, blad w obcym
# miejscu, user odmowil auto-rollback).
CRITICAL_STAGE_REACHED=0
on_error() {
    local exit_code=$?
    if [ "$CRITICAL_STAGE_REACHED" = 1 ]; then
        cat >&2 <<EOF

##############################################################################
# UPGRADE PRZERWANY PO KRYTYCZNYM KROKU
##############################################################################
# Exit code: $exit_code
#
# Stan:
#   - Stary volume zachowany jako: $BACKUP_VOLUME
#   - Aktualny volume:              $VOLUME_NAME (moze byc pusty lub czesciowo
#                                                  zapelniony nowym clustrem)
#   - Tarball pg_dump:              $TARBALL (jesli krok 2 sie udal)
#   - Plik rollback:                $ROLLBACK_FILE
#
# ROLLBACK do starego clustra:
#   1. docker compose stop dbserver
#   2. docker compose rm -f dbserver
#   3. docker volume rm $VOLUME_NAME
#   4. docker volume create $VOLUME_NAME
#   5. docker run --rm \\
#        -v $BACKUP_VOLUME:/from:ro \\
#        -v $VOLUME_NAME:/to \\
#        alpine sh -c 'cp -a /from/. /to/'
#   6. W $APP_ENV:
#        DJANGO_BPP_POSTGRESQL_VERSION=$CURRENT_POSTGRESQL_VERSION
#        DJANGO_BPP_POSTGRESQL_VERSION_MAJOR=$CURRENT_PG_MAJOR
#   7. docker compose up -d dbserver
##############################################################################
EOF
    fi
}
trap on_error ERR

# Auto-rollback: odkreca destrukcyjne kroki (bumpa env, skasowanie volume,
# uruchomienie nowego kontenera) wracajac do starego clustra z BACKUP_VOLUME.
# Wywolywane interaktywnie gdy nowy dbserver nie wstaje w [8/10] lub gdy
# wersja kontenera nie pasuje do oczekiwanej. Po wywolaniu BACKUP_VOLUME jest
# usuniety (dane wrocily do $VOLUME_NAME), tarball pg_dump zostaje.
auto_rollback() {
    echo ""
    echo "##############################################################################"
    echo "# AUTO-ROLLBACK"
    echo "##############################################################################"
    run docker compose stop dbserver || true
    run docker compose rm -f dbserver || true
    run docker volume rm "$VOLUME_NAME" 2>/dev/null || true
    run docker volume create "$VOLUME_NAME"
    run docker run --rm \
        -v "$BACKUP_VOLUME:/from:ro" \
        -v "$VOLUME_NAME:/to" \
        alpine sh -c 'cp -a /from/. /to/'
    run docker volume rm "$BACKUP_VOLUME"
    run set_env_var DJANGO_BPP_POSTGRESQL_VERSION "$CURRENT_POSTGRESQL_VERSION" "$APP_ENV"
    run set_env_var DJANGO_BPP_POSTGRESQL_VERSION_MAJOR "$CURRENT_PG_MAJOR" "$APP_ENV"
    run docker compose up -d dbserver

    echo "Czekam az stary dbserver wstanie (max 60s)..."
    for _i in $(seq 1 20); do
        _state="$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q dbserver)" 2>/dev/null || echo none)"
        if [ "$_state" = "healthy" ]; then
            echo "OK - stary cluster wstal."
            # CRITICAL_STAGE zostaje wylaczony zeby trap on_error nie drukowal
            # banera manualnego rollbacku (rollback juz zostal wykonany).
            CRITICAL_STAGE_REACHED=0
            return 0
        fi
        sleep 3
    done
    echo "UWAGA: stary dbserver nie wstal jako healthy w 60s - sprawdz 'docker compose logs dbserver'." >&2
    CRITICAL_STAGE_REACHED=0
    return 1
}

# ---- Krok 1: pre-flight pull (fail-fast) --------------------------------
# WAZNE: robimy to zanim cokolwiek destrukcyjnego. Jesli siec padnie, Docker
# Hub jest nieosiagalny, albo tag nie istnieje (literowka w wersji) - dowiemy
# sie teraz, gdy jeszcze nic nie zostalo zatrzymane ani skasowane. Po sukcesie
# image siedzi w lokalnym cache i krok 8 (up dbserver) jest juz offline-safe.
echo
echo "=== [1/10] Pull nowego obrazu dbserver (pre-flight, fail-fast) ==="
NEW_DBSERVER_IMAGE="iplweb/bpp_dbserver:psql-${NEW_POSTGRESQL_VERSION}"
run docker pull "$NEW_DBSERVER_IMAGE"

# ---- Krok 2: dump ---------------------------------------------------------
echo
echo "=== [2/10] Dump aktualnej bazy (make db-backup) ==="
run make db-backup

# Znajdz najswiezszy tarball - sortowanie po nazwie dziala bo timestamp jest w nazwie.
TARBALL="$(find "${DJANGO_BPP_HOST_BACKUP_DIR}" -maxdepth 1 -name 'db-backup-*.tar.gz' -print | sort | tail -1)"
if [ -z "$TARBALL" ] || [ ! -f "$TARBALL" ]; then
    echo "BLAD: nie znalazlem swiezego tarballa db-backup-*.tar.gz w $DJANGO_BPP_HOST_BACKUP_DIR" >&2
    exit 1
fi
TARBALL_NAME="$(basename "$TARBALL")"
DUMP_DIRNAME="${TARBALL_NAME%.tar.gz}"
echo "Tarball: $TARBALL"

# ---- Krok 3: stop dependent services -------------------------------------
echo
echo "=== [3/10] Zatrzymuje dependent services ==="
# Workery denorm sa zatrzymywane przez dedykowany target (czeka az queue sie oprozni).
run make stop-denorm-celery
# Reszta - bez niczego oczekiwania, te serwisy nie maja persistent state poza baza.
run docker compose stop appserver authserver workerserver-general celerybeat denorm-queue flower

# ---- Krok 4: stop+rm dbserver --------------------------------------------
echo
echo "=== [4/10] Zatrzymuje i usuwam kontener dbserver ==="
run docker compose stop dbserver
run docker compose rm -f dbserver

# Od tego momentu kazdy blad oznacza nieodwracalna zmiane stanu - wlaczamy banner.
CRITICAL_STAGE_REACHED=1

# ---- Krok 5: kopia volume na bok ----------------------------------------
echo
echo "=== [5/10] Tworze kopie volume $VOLUME_NAME -> $BACKUP_VOLUME ==="
run docker volume create "$BACKUP_VOLUME"
run docker run --rm \
    -v "$VOLUME_NAME:/from:ro" \
    -v "$BACKUP_VOLUME:/to" \
    alpine sh -c 'cp -a /from/. /to/'

cat > "$ROLLBACK_FILE" <<EOF
# BPP postgres upgrade rollback info - $TS
OLD_VOLUME=$BACKUP_VOLUME
NEW_VOLUME=$VOLUME_NAME
OLD_POSTGRESQL_VERSION=$CURRENT_POSTGRESQL_VERSION
NEW_POSTGRESQL_VERSION=$NEW_POSTGRESQL_VERSION
OLD_PG_MAJOR=$CURRENT_PG_MAJOR
NEW_PG_MAJOR=$EXPECTED_MAJOR
TARBALL=$TARBALL
EOF
echo "Plik rollback: $ROLLBACK_FILE"

# ---- Krok 6: usun stary volume ------------------------------------------
echo
echo "=== [6/10] Usuwam obecny volume $VOLUME_NAME ==="
run docker volume rm "$VOLUME_NAME"

# ---- Krok 7: bump wersji dbservera i backup-runnera ---------------------
echo
echo "=== [7/10] Bumpuje DJANGO_BPP_POSTGRESQL_VERSION w $APP_ENV ==="
run set_env_var DJANGO_BPP_POSTGRESQL_VERSION "$NEW_POSTGRESQL_VERSION" "$APP_ENV"
echo "DJANGO_BPP_POSTGRESQL_VERSION: $CURRENT_POSTGRESQL_VERSION -> $NEW_POSTGRESQL_VERSION"

# Sprzatanie starej nazwy (po rename 2026-04-18) zeby uniknac rozjazdu
# miedzy VERSION a DBSERVER_PG_VERSION.
if env_has_var "DJANGO_BPP_DBSERVER_PG_VERSION" "$APP_ENV"; then
    awk '!/^DJANGO_BPP_DBSERVER_PG_VERSION=/' "$APP_ENV" > "$APP_ENV.tmp.$$" \
        && mv "$APP_ENV.tmp.$$" "$APP_ENV"
    echo "Usunieto stara DJANGO_BPP_POSTGRESQL_DBSERVER_PG_VERSION (zastapiona przez _VERSION)."
fi

# Jednoczesnie synchronizuj DJANGO_BPP_POSTGRESQL_VERSION_MAJOR (major dla
# backup-runnera) jesli byla spojna z dbserverem. Gdy byla rozjechana
# (np. user swiadomie trzyma backup-runner na nowszej wersji), nie ruszamy jej.
CURRENT_BACKUP_RUNNER_MAJOR="$(get_env_var DJANGO_BPP_POSTGRESQL_VERSION_MAJOR "$APP_ENV")"
if [ -z "$CURRENT_BACKUP_RUNNER_MAJOR" ]; then
    # Fallback na stara nazwe (pre-rename).
    CURRENT_BACKUP_RUNNER_MAJOR="$(get_env_var DJANGO_BPP_POSTGRESQL_DB_VERSION "$APP_ENV")"
fi
if [ -z "$CURRENT_BACKUP_RUNNER_MAJOR" ] || [ "$CURRENT_BACKUP_RUNNER_MAJOR" = "$CURRENT_PG_MAJOR" ]; then
    run set_env_var DJANGO_BPP_POSTGRESQL_VERSION_MAJOR "$EXPECTED_MAJOR" "$APP_ENV"
    echo "DJANGO_BPP_POSTGRESQL_VERSION_MAJOR: ${CURRENT_BACKUP_RUNNER_MAJOR:-<puste>} -> $EXPECTED_MAJOR"
elif [[ "$CURRENT_BACKUP_RUNNER_MAJOR" =~ ^[0-9]+$ ]]; then
    echo "UWAGA: DJANGO_BPP_POSTGRESQL_VERSION_MAJOR=$CURRENT_BACKUP_RUNNER_MAJOR rozjechane z"
    echo "       dbserver ($CURRENT_PG_MAJOR) - nie ruszam (backup-runner moze miec >= wersja serwera)."
    if [ "$CURRENT_BACKUP_RUNNER_MAJOR" -lt "$EXPECTED_MAJOR" ]; then
        echo "       ALE: $CURRENT_BACKUP_RUNNER_MAJOR < $EXPECTED_MAJOR - rozwaz recznie bumpnac po upgrade."
    fi
else
    echo "UWAGA: DJANGO_BPP_POSTGRESQL_VERSION_MAJOR=$CURRENT_BACKUP_RUNNER_MAJOR nie jest liczba - nie ruszam."
fi

# Sprzatanie starej nazwy dla majora (po rename 2026-04-18).
if env_has_var "DJANGO_BPP_POSTGRESQL_DB_VERSION" "$APP_ENV"; then
    awk '!/^DJANGO_BPP_POSTGRESQL_DB_VERSION=/' "$APP_ENV" > "$APP_ENV.tmp.$$" \
        && mv "$APP_ENV.tmp.$$" "$APP_ENV"
    echo "Usunieto stara DJANGO_BPP_POSTGRESQL_DB_VERSION (zastapiona przez _MAJOR)."
fi

# ---- Krok 8: start dbserver ----------------------------------------------
# Obraz jest juz pulled w kroku 1, wiec `up` jest offline-safe.
echo
echo "=== [8/10] Start nowego dbserver ==="
run docker compose up -d dbserver

echo "Czekam az dbserver bedzie healthy (max 180s)..."
HEALTHY=0
for i in $(seq 1 60); do
    STATE="$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q dbserver)" 2>/dev/null || echo none)"
    if [ "$STATE" = "healthy" ]; then
        HEALTHY=1
        echo "OK po ${i}*3s."
        break
    fi
    sleep 3
done
if [ "$HEALTHY" != 1 ]; then
    echo "BLAD: dbserver nie zostal healthy w 180s." >&2
    echo "Logi dbservera (ostatnie 100 linii):" >&2
    docker compose logs --tail=100 dbserver >&2 || true
    echo ""
    if confirm "Wykonac auto-rollback (przywrocic stary cluster z backup volume)?"; then
        auto_rollback || true
        echo ""
        echo "Rollback wykonany. Upgrade nie powiodl sie, stary cluster wrocil."
        echo "Tarball pg_dump zachowany: $TARBALL (mozesz usunac po weryfikacji)."
        exit 1
    fi
    echo "Auto-rollback pominiety - patrz banner z manualnymi krokami." >&2
    exit 1
fi

NEW_PG_VERSION="$(docker compose exec -T dbserver postgres --version 2>/dev/null || echo unknown)"
NEW_PG_MAJOR="$(echo "$NEW_PG_VERSION" | grep -oE '[0-9]+' | head -1 || echo 0)"
echo "Nowa wersja PG: $NEW_PG_VERSION"
if [ "$NEW_PG_MAJOR" != "$EXPECTED_MAJOR" ]; then
    echo "BLAD: spodziewany major $EXPECTED_MAJOR, dostalem $NEW_PG_MAJOR. Sprawdz tag psql-$NEW_POSTGRESQL_VERSION." >&2
    echo ""
    if confirm "Wykonac auto-rollback (przywrocic stary cluster z backup volume)?"; then
        auto_rollback || true
        echo ""
        echo "Rollback wykonany. Upgrade nie powiodl sie (zly tag), stary cluster wrocil."
        exit 1
    fi
    echo "Auto-rollback pominiety - patrz banner z manualnymi krokami." >&2
    exit 1
fi

# ---- Krok 9: pg_restore -------------------------------------------------
echo
echo "=== [9/10] pg_restore z $TARBALL_NAME ==="
# Tarball jest juz w /backup (bind-mount) - rozpakuj wewnatrz kontenera.
run docker compose exec -T dbserver tar xzf "/backup/$TARBALL_NAME" -C /backup
run docker compose exec -T \
    -e "PGPASSWORD=$DJANGO_BPP_DB_PASSWORD" \
    dbserver \
    pg_restore \
        -Fd \
        -j "${PARALLEL_JOBS:-4}" \
        -h "$DJANGO_BPP_DB_HOST" \
        -p "$DJANGO_BPP_DB_PORT" \
        -U "$DJANGO_BPP_DB_USER" \
        -d "$DJANGO_BPP_DB_NAME" \
        --no-owner --no-privileges \
        "/backup/$DUMP_DIRNAME"
# Sprzatamy rozpakowany katalog (ale tarball ZOSTAJE jako disaster recovery).
run docker compose exec -T dbserver rm -rf "/backup/$DUMP_DIRNAME"

# Od tego momentu nowy cluster jest funkcjonalny - blad nie wymaga juz duzego bannera.
CRITICAL_STAGE_REACHED=0

# ---- Krok 10: migrate + up + smoke --------------------------------------
echo
echo "=== [10/10] make migrate + make up ==="
run make migrate
run make up

echo
echo "Smoke test - logi appserver (ostatnie 30 lini):"
docker compose logs --tail=30 appserver || true

cat <<EOF

##############################################################################
# UPGRADE ZAKONCZONY POMYSLNIE
##############################################################################
# $CURRENT_PG_VERSION
#   ->
# $NEW_PG_VERSION
#
# Zachowane (nie usuwane automatycznie):
#   - Stary volume:    $BACKUP_VOLUME
#   - Tarball pg_dump: $TARBALL
#   - Rollback info:   $ROLLBACK_FILE
#
# Sprawdz dzialanie aplikacji w przegladarce + 'make denorm-rebuild' jako
# najbardziej obciazajacy workflow bazy. Kiedy bedziesz zadowolony, sprzatnij:
#
#   docker volume rm $BACKUP_VOLUME
#   rm $ROLLBACK_FILE
#   # tarball mozesz zostawic - jest czescia normalnej rotacji backupow
##############################################################################
EOF

#!/usr/bin/env bash
set -euo pipefail
#
# Proba generalna aktualizacji: czy migracje obrazu-kandydata przechodza na
# kopii produkcyjnej bazy I czy nowa wersja na tej kopii wstaje i odpowiada?
# Dziala CALKOWICIE obok produkcji:
#   - shadow stack (dbserver+redis+appserver) czystym `docker run`, poza
#     projektem Compose, na wlasnej sieci bpp-shadow; bez monitoringu,
#     workerow i nginx - tylko to, co potrzebne do odpowiedzi strony,
#   - shadow-baza z TEGO SAMEGO obrazu co produkcyjny dbserver (stockowy
#     postgres + autotune bind-mountowany z ./dbserver/),
#   - pull kandydata PO TAGU WERSJI - lokalny tag :latest produkcji
#     pozostaje nietkniety,
#   - zero zapisu do .env, zero operacji na kontenerach/wolumenach produkcji.
#
# Uzycie:
#   make test-upgrade                  # kandydat = najnowszy CalVer z Huba
#   make test-upgrade TAG=202606.1386  # jawny kandydat
#   make test-upgrade-clean            # sprzatniecie shadow stacka
#
# Wynik: exit 0 = migracje przechodza, kandydat wstal i odpowiada
#                 (shadow posprzatany);
#        exit 1   = blad;
#        exit 2   = inna proba trwa na tym hoscie (nic nie ruszone).
#
# Bez nadzoru (cron, autoupdate, CI): zadnych pytan, wynik = kod wyjscia.
# Po bledzie shadow stack (~3 GB limitow RAM) ZOSTAJE do inspekcji tylko przy
# terminalu na stdin; bez niego jest sprzatany - nikt go nie obejrzy, a na
# produkcji zjadalby pamiec do nastepnego recznego `make test-upgrade-clean`.
# Logi kandydata trafiaja na wyjscie PRZED sprzataniem. Wymuszenie:
# KEEP_SHADOW=1 (zostaw) / KEEP_SHADOW=0 (sprzataj).

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib-docker-versions.sh
. "$REPO_DIR/scripts/lib-docker-versions.sh"

SHADOW_NET="bpp-shadow"
SHADOW_DB="bpp-shadow-dbserver"
SHADOW_REDIS="bpp-shadow-redis"
SHADOW_APP="bpp-shadow-appserver"
SHADOW_VOL="bpp-shadow-pgdata"
SHADOW_STATIC_VOL="bpp-shadow-staticfiles"
SHADOW_MEDIA_VOL="bpp-shadow-media"
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"
# Limity zasobow shadow stacka - przyciete, zeby nie zaglodzic produkcji.
SHADOW_DB_MEM="${SHADOW_DB_MEM:-1g}"
SHADOW_DB_CPUS="${SHADOW_DB_CPUS:-1.0}"
SHADOW_REDIS_MEM="${SHADOW_REDIS_MEM:-256m}"
SHADOW_MIGRATE_MEM="${SHADOW_MIGRATE_MEM:-2g}"
SHADOW_APP_MEM="${SHADOW_APP_MEM:-2g}"
# Ile sekund czekamy, az kandydat odpowie na /health/ (Phase 1 entrypointu
# robi jeszcze raz baseline_load+migrate - po kroku 6 to no-op, ale import
# Django pod przycietym CPU potrafi trwac).
SHADOW_APP_TIMEOUT="${SHADOW_APP_TIMEOUT:-600}"

cleanup_shadow() {
    docker rm -f "$SHADOW_APP" "$SHADOW_DB" "$SHADOW_REDIS" >/dev/null 2>&1 || true
    docker volume rm -f "$SHADOW_VOL" "$SHADOW_STATIC_VOL" "$SHADOW_MEDIA_VOL" >/dev/null 2>&1 || true
    docker network rm "$SHADOW_NET" >/dev/null 2>&1 || true
}

if [ "${1:-}" = "--clean" ]; then
    echo "Sprzatam shadow stack ($SHADOW_APP, $SHADOW_DB, $SHADOW_REDIS, wolumeny bpp-shadow-*, $SHADOW_NET)..."
    cleanup_shadow
    echo "OK."
    exit 0
fi

if [ -z "${KEEP_SHADOW:-}" ]; then
    if [ -t 0 ]; then KEEP_SHADOW=1; else KEEP_SHADOW=0; fi
fi

# --- Blokada: jedna proba na hosta ---
# Nazwy shadow-kontenerow sa globalne dla demona Dockera, wiec drugi przebieg
# (cron + reczny) zaczalby od cleanup_shadow i ubil pierwszemu baze w polowie
# restore. mkdir jest atomowy; martwy wlasciciel (SIGKILL, reboot) = przejecie.
LOCK_DIR="${TEST_UPGRADE_LOCK_DIR:-${TMPDIR:-/tmp}/bpp-test-upgrade.lock}"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        echo "BLAD: inna proba test-upgrade trwa na tym hoscie (pid $owner, blokada $LOCK_DIR)." >&2
        exit 2
    fi
    echo "Przejmuje osierocona blokade $LOCK_DIR (pid ${owner:-?} nie zyje)."
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "BLAD: nie moge przejac blokady $LOCK_DIR." >&2
        exit 2
    fi
fi
echo "$$" > "$LOCK_DIR/pid"

SHADOW_STARTED=0
# shellcheck disable=SC2317,SC2329  # wywolywane przez trap EXIT
on_exit() {
    rc=$?
    if [ "$rc" -ne 0 ] && [ "$SHADOW_STARTED" = 1 ]; then
        echo "" >&2
        if [ "$KEEP_SHADOW" = 1 ]; then
            echo "Shadow stack ZOSTAJE do inspekcji:" >&2
            echo "  docker logs $SHADOW_APP   # jesli doszlo do startu kandydata" >&2
            echo "  docker exec -it $SHADOW_DB psql -U \"\$DJANGO_BPP_DB_USER\" -d \"\$DJANGO_BPP_DB_NAME\"" >&2
            echo "Sprzatniecie: make test-upgrade-clean" >&2
        else
            echo "Sprzatam shadow stack (bez terminala nikt go nie obejrzy; KEEP_SHADOW=1 zostawia)." >&2
            cleanup_shadow
        fi
    fi
    rm -f "$LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
    return "$rc"
}
trap on_exit EXIT

# --- BPP_CONFIGS_DIR / ENV_FILE ---
if [ -z "${BPP_CONFIGS_DIR:-}" ] && [ -f "$REPO_DIR/.env" ]; then
    BPP_CONFIGS_DIR="$(grep -E '^BPP_CONFIGS_DIR=' "$REPO_DIR/.env" | tail -1 | cut -d= -f2-)"
fi
if [ -z "${BPP_CONFIGS_DIR:-}" ]; then
    echo "BLAD: BPP_CONFIGS_DIR nie jest ustawione (brak $REPO_DIR/.env?)" >&2
    exit 1
fi
export BPP_CONFIGS_DIR
ENV_FILE="$BPP_CONFIGS_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "BLAD: brak pliku $ENV_FILE" >&2
    exit 1
fi

# --- Helper .env (kopia per-skrypt; konwencja: init-configs.sh) ---
get_env_var() {
    local raw
    raw="$(grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
    if [ "${raw#\"}" != "$raw" ] && [ "${raw%\"}" != "$raw" ]; then
        raw="${raw#\"}"; raw="${raw%\"}"
    fi
    if [ "${raw#\'}" != "$raw" ] && [ "${raw%\'}" != "$raw" ]; then
        raw="${raw#\'}"; raw="${raw%\'}"
    fi
    printf '%s' "$raw"
}

DB_NAME="$(get_env_var DJANGO_BPP_DB_NAME)"
DB_USER="$(get_env_var DJANGO_BPP_DB_USER)"
DB_PASSWORD="$(get_env_var DJANGO_BPP_DB_PASSWORD)"
if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
    echo "BLAD: brak DJANGO_BPP_DB_NAME/USER/PASSWORD w $ENV_FILE" >&2
    exit 1
fi

# Tryb bazy: lokalny dbserver (domyslnie) albo zewnetrzna baza z sentinelem.
# Ta sama detekcja co pg-monitoring-setup.sh / create-monitoring-user.sh:
# BPP_DATABASE_COMPOSE w REPO-lokalnym .env. Wyeksportowana zmienna wygrywa
# z plikiem - tak samo jak przy interpolacji samego Compose.
DATABASE_COMPOSE="${BPP_DATABASE_COMPOSE:-$(grep -E '^BPP_DATABASE_COMPOSE=' "$REPO_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)}"
case "$DATABASE_COMPOSE" in
    *external*) DB_MODE=external ;;
    *)          DB_MODE=local ;;
esac

# Wersja PG: ta sama logika dwuwarstwowego fallbacku co docker-compose.database.yml.
PG_VERSION="$(get_env_var DJANGO_BPP_POSTGRESQL_VERSION)"
[ -n "$PG_VERSION" ] || PG_VERSION="$(get_env_var DJANGO_BPP_DBSERVER_PG_VERSION)"
[ -n "$PG_VERSION" ] || PG_VERSION="16.13"
# Tryb external: major jak w docker-compose.database.external.yml.
PG_MAJOR="$(get_env_var DJANGO_BPP_POSTGRESQL_VERSION_MAJOR)"
[ -n "$PG_MAJOR" ] || PG_MAJOR="$(get_env_var DJANGO_BPP_POSTGRESQL_DB_VERSION)"
[ -n "$PG_MAJOR" ] || PG_MAJOR="17"

# Hostname, pod ktorym pytamy kandydata o strone glowna (ALLOWED_HOSTS).
# DJANGO_BPP_HOSTNAMES (multi-host, CSV) ma pierwszenstwo - bierzemy pierwszy.
APP_HOSTNAME="$(get_env_var DJANGO_BPP_HOSTNAMES | cut -d, -f1 | tr -d '[:space:]')"
[ -n "$APP_HOSTNAME" ] || APP_HOSTNAME="$(get_env_var DJANGO_BPP_HOSTNAME)"
[ -n "$APP_HOSTNAME" ] || APP_HOSTNAME="localhost"

# Katalog backupow: ta sama logika fallbacku co mk/database.mk.
BACKUP_DIR="$(get_env_var DJANGO_BPP_HOST_BACKUP_DIR)"
[ -n "$BACKUP_DIR" ] || BACKUP_DIR="$(get_env_var DJANGO_BPP_BACKUP_DIR)"
[ -n "$BACKUP_DIR" ] || BACKUP_DIR="$(cd "$BPP_CONFIGS_DIR/.." && pwd)/backups"
mkdir -p "$BACKUP_DIR"

# Wersja redisa: ta sama co produkcyjna (z compose - zero driftu).
REDIS_IMAGE="$(grep -Eo 'redis:[0-9][0-9.]*' "$REPO_DIR/docker-compose.infrastructure.yml" | head -1)"
[ -n "$REDIS_IMAGE" ] || REDIS_IMAGE="redis:8.6.2"

APPSERVER_REPO="iplweb/bpp_appserver"
cd "$REPO_DIR"

# --- [1/7] Kandydat ---
echo "=== [1/7] Rozwiazuje obraz-kandydata ==="
if [ -n "${TAG:-}" ]; then
    if ! printf '%s' "$TAG" | grep -qE "$CALVER_RE"; then
        echo "BLAD: TAG='$TAG' nie wyglada na tag CalVer (np. 202606.1386)" >&2
        exit 1
    fi
    CANDIDATE="$TAG"
else
    CANDIDATE="$(resolve_latest_calver "$APPSERVER_REPO")"
fi
echo "Kandydat: ${APPSERVER_REPO}:${CANDIDATE}"
# Pull po tagu wersji - lokalny :latest produkcji nietkniety.
docker pull "${APPSERVER_REPO}:${CANDIDATE}"

# --- [2/7] Obraz bazy + rozmiar bazy + kontrola miejsca na dysku i pamieci ---
echo "=== [2/7] Obraz bazy, rozmiar bazy, kontrola miejsca na dysku i pamieci ==="
# Shadow-baza ma startowac z TEGO SAMEGO obrazu co produkcyjny dbserver.
# Tryb lokalny: obraz bierzemy z dzialajacego kontenera (to, na czym produkcja
# NAPRAWDE chodzi), a gdy kontenera nie ma - z .env, jak compose.
# Tryb external: produkcyjny serwer nie jest nasz, a sentinel to -alpine bez
# basha (autotune go wymaga) - bierzemy Debianowy postgres w tym samym majorze.
PROD_DB_CID=""
if [ "$DB_MODE" = local ]; then
    PROD_DB_CID="$(docker compose ps -q dbserver 2>/dev/null | head -1)"
    DB_IMAGE=""
    if [ -n "$PROD_DB_CID" ]; then
        DB_IMAGE="$(docker inspect --format '{{.Config.Image}}' "$PROD_DB_CID" 2>/dev/null || true)"
    fi
    [ -n "$DB_IMAGE" ] || DB_IMAGE="postgres:${PG_VERSION}"
else
    DB_IMAGE="postgres:${PG_MAJOR}"
fi
echo "Tryb bazy: $DB_MODE; obraz shadow-bazy: $DB_IMAGE"
docker image inspect "$DB_IMAGE" >/dev/null 2>&1 || docker pull "$DB_IMAGE"

# Rozmiar bazy mierzymy PRZED kontrola miejsca - to z niego liczymy potrzebne
# miejsce. Tryb lokalny: rozmiar wolumenu danych produkcyjnego dbservera
# (du na wolumenie zamontowanym :ro w jednorazowym kontenerze z obrazem bazy;
# zero ruchu na produkcyjnym postgresie). Tryb external: wolumenu nie ma,
# pytamy baze przez sentinela (on ma psql, PGPASSWORD i adres bazy).
DB_SIZE_MB=""
if [ "$DB_MODE" = local ]; then
    if [ -z "$PROD_DB_CID" ]; then
        echo "BLAD: produkcyjny dbserver nie dziala (docker compose ps -q dbserver) - nie ma czego backupowac." >&2
        exit 1
    fi
    PROD_DB_VOL="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' "$PROD_DB_CID")"
    if [ -z "$PROD_DB_VOL" ]; then
        echo "BLAD: nie znalazlem wolumenu /var/lib/postgresql/data w kontenerze dbserver." >&2
        exit 1
    fi
    DB_SIZE_MB="$(docker run --rm -v "$PROD_DB_VOL":/v:ro --entrypoint du "$DB_IMAGE" -sm /v | cut -f1 | tr -d '[:space:]')"
    echo "Wolumen bazy: $PROD_DB_VOL = ${DB_SIZE_MB} MB"
else
    # shellcheck disable=SC2016  # zmienne rozwija shell w sentinelu, nie tutaj
    DB_SIZE_MB="$(docker compose exec -T dbserver sh -c \
        'psql -h "$DJANGO_BPP_DB_HOST" -p "${DJANGO_BPP_DB_PORT:-5432}" -U "$DJANGO_BPP_DB_USER" -d "$DJANGO_BPP_DB_NAME" -tAc "SELECT pg_database_size(current_database())/1024/1024;"' \
        | tr -d '[:space:]')"
    echo "Baza zewnetrzna: ${DB_SIZE_MB} MB"
fi
case "$DB_SIZE_MB" in
    ''|*[!0-9]*)
        echo "BLAD: nie udalo sie ustalic rozmiaru bazy (wynik: '${DB_SIZE_MB}')." >&2
        exit 1 ;;
esac

if [ "${SKIP_DISK_CHECK:-0}" != "1" ]; then
    NEED_MB=$(( DB_SIZE_MB * 5 / 2 ))   # ~2.5x: dump + untar + shadow volume
    FREE_BACKUP_MB="$(df -Pm "$BACKUP_DIR" | awk 'NR==2 {print $4}')"
    DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
    [ -n "$DOCKER_ROOT" ] || DOCKER_ROOT=/var/lib/docker
    # `|| true`: pod pipefail nieudany df (katalog Dockera niewidoczny z hosta,
    # np. Docker Desktop/OrbStack) cicho ubijalby skrypt zamiast spasc na
    # fallback ponizej.
    FREE_DOCKER_MB="$(df -Pm "$DOCKER_ROOT" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
    [ -n "$FREE_DOCKER_MB" ] || FREE_DOCKER_MB="$FREE_BACKUP_MB"
    echo "Wymagane ~${NEED_MB} MB wolnego miejsca (backup dir: ${FREE_BACKUP_MB} MB, docker root: ${FREE_DOCKER_MB} MB)."
    if [ "$FREE_BACKUP_MB" -lt "$NEED_MB" ] || [ "$FREE_DOCKER_MB" -lt "$NEED_MB" ]; then
        echo "BLAD: za malo miejsca (backup dir: ${FREE_BACKUP_MB} MB, docker root: ${FREE_DOCKER_MB} MB)." >&2
        echo "Wymuszenie pominiecia kontroli: SKIP_DISK_CHECK=1 make test-upgrade" >&2
        exit 1
    fi
else
    echo "(kontrola miejsca pominieta: SKIP_DISK_CHECK=1)"
fi

# Kontrola pamieci. Szczyt shadow stacka = baza + redis + WIEKSZY z (migracja,
# kandydat): kontener migracji konczy sie, zanim kandydat wystartuje. To limity
# (sufity), nie rezerwacje - kontrola jest wiec ostrozna. MemAvailable czytamy
# Z KONTENERA: na Linuksie to RAM hosta, na Docker Desktop/OrbStack - RAM VM,
# w ktorej naprawde wyladuje shadow stack (RAM Maca nic tu nie mowi).
mem_to_mb() {   # 1g / 256m / 512 (MB) -> MB
    case "$1" in
        *[gG]) echo $(( ${1%[gG]} * 1024 )) ;;
        *[mM]) echo "${1%[mM]}" ;;
        *)     echo "$1" ;;
    esac
}
if [ "${SKIP_MEM_CHECK:-0}" != "1" ]; then
    _db_mb="$(mem_to_mb "$SHADOW_DB_MEM")"
    _redis_mb="$(mem_to_mb "$SHADOW_REDIS_MEM")"
    _mig_mb="$(mem_to_mb "$SHADOW_MIGRATE_MEM")"
    _app_mb="$(mem_to_mb "$SHADOW_APP_MEM")"
    _peak_mb="$_mig_mb"; [ "$_app_mb" -gt "$_peak_mb" ] && _peak_mb="$_app_mb"
    NEED_MEM_MB=$(( _db_mb + _redis_mb + _peak_mb ))
    FREE_MEM_MB="$(docker run --rm --entrypoint cat "$DB_IMAGE" /proc/meminfo 2>/dev/null \
        | awk '/^MemAvailable:/ {print int($2/1024)}' || true)"
    case "$FREE_MEM_MB" in
        ''|*[!0-9]*)
            echo "OSTRZEZENIE: nie udalo sie odczytac MemAvailable - pomijam kontrole pamieci." ;;
        *)
            echo "Pamiec: wymagane ~${NEED_MEM_MB} MB (baza ${_db_mb} + redis ${_redis_mb} + max(migracja ${_mig_mb}, kandydat ${_app_mb})), dostepne ${FREE_MEM_MB} MB."
            if [ "$FREE_MEM_MB" -lt "$NEED_MEM_MB" ]; then
                echo "BLAD: za malo wolnej pamieci na shadow stack." >&2
                echo "Mozliwosci: na czas proby zatrzymaj monitoring (netdata/loki/grafana/alloy)," >&2
                echo "  zmniejsz limity (np. SHADOW_APP_MEM=1g SHADOW_MIGRATE_MEM=1g make test-upgrade)," >&2
                echo "  albo wymus: SKIP_MEM_CHECK=1 make test-upgrade" >&2
                exit 1
            fi ;;
    esac
else
    echo "(kontrola pamieci pominieta: SKIP_MEM_CHECK=1)"
fi

# --- [3/7] Backup produkcyjnej bazy ---
echo "=== [3/7] Backup produkcyjnej bazy (make db-backup) ==="
make -C "$REPO_DIR" db-backup
# shellcheck disable=SC2012  # nazwy dumpow kontrolowane (db-backup-<ts>.tar.gz), bez bialych znakow
BACKUP_TAR_PATH="$(ls -t "$BACKUP_DIR"/db-backup-*.tar.gz 2>/dev/null | head -1)"
if [ -z "$BACKUP_TAR_PATH" ]; then
    echo "BLAD: nie znalazlem swiezego dumpa w $BACKUP_DIR" >&2
    exit 1
fi
BACKUP_TAR="$(basename "$BACKUP_TAR_PATH")"
BACKUP_DIRNAME="${BACKUP_TAR%.tar.gz}"
echo "Dump: $BACKUP_TAR_PATH"

# --- [4/7] Shadow stack ---
echo "=== [4/7] Stawiam shadow stack (siec $SHADOW_NET) ==="
cleanup_shadow   # zombie z poprzedniego przebiegu
SHADOW_STARTED=1
docker network create "$SHADOW_NET" >/dev/null
docker volume create "$SHADOW_VOL" >/dev/null
# Lustro serwisu dbserver z docker-compose.database.yml: ten sam obraz, ten sam
# autotune (bind-mount z repo), PGDATA przypiety (postgres:18+ domyslnie pisze
# do podkatalogu wersji), kolacja ICU pl-PL przy initdb, knoby POSTGRESQL_*
# z .env. POSTGRESQL_RAM_THIS_MUCH_GB zerujemy: wartosc dobrana pod produkcje
# przekroczylaby przyciety limit shadow-bazy - autotune ma czytac jej cgroup.
docker run -d --name "$SHADOW_DB" --network "$SHADOW_NET" \
    --env-file "$ENV_FILE" \
    -e POSTGRES_DB="$DB_NAME" \
    -e POSTGRES_USER="$DB_USER" \
    -e POSTGRES_PASSWORD="$DB_PASSWORD" \
    -e PGDATA=/var/lib/postgresql/data \
    -e POSTGRES_INITDB_ARGS="--locale-provider=icu --icu-locale=pl-PL" \
    -e POSTGRESQL_RAM_THIS_MUCH_GB= \
    -v "$REPO_DIR/dbserver/docker-entrypoint-autotune.sh":/usr/local/bin/docker-entrypoint-autotune.sh:ro \
    -v "$REPO_DIR/dbserver/autotune.sh":/autotune.sh:ro \
    -v "$SHADOW_VOL":/var/lib/postgresql/data \
    -v "$BACKUP_DIR":/backup:ro \
    --memory "$SHADOW_DB_MEM" --cpus "$SHADOW_DB_CPUS" \
    --entrypoint bash \
    "$DB_IMAGE" /usr/local/bin/docker-entrypoint-autotune.sh postgres >/dev/null
docker run -d --name "$SHADOW_REDIS" --network "$SHADOW_NET" \
    --memory "$SHADOW_REDIS_MEM" \
    "$REDIS_IMAGE" >/dev/null

echo "Czekam na gotowosc shadow-postgresa..."
for i in $(seq 1 60); do
    if docker exec "$SHADOW_DB" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "BLAD: shadow-postgres nie wstal w 120 s" >&2
        exit 1
    fi
    sleep 2
done

# --- [5/7] Restore dumpa do shadow-bazy ---
echo "=== [5/7] Restore dumpa do shadow-bazy (pg_restore -j $PARALLEL_JOBS) ==="
docker exec "$SHADOW_DB" mkdir -p /tmp/restore
docker exec "$SHADOW_DB" tar xzf "/backup/$BACKUP_TAR" -C /tmp/restore
# --no-owner + --no-privileges: shadow ma tylko jedna role (DJANGO_BPP_DB_USER).
# GRANT-y dla rol, ktorych tu nie ma (uzytkownik monitoringu z
# create-monitoring-user.sh, role zarzadzanej bazy zewnetrznej), konczylyby
# pg_restore bledem i - pod set -e - cala probe, choc z migracjami nie maja
# nic wspolnego.
docker exec "$SHADOW_DB" pg_restore -Fd -j "$PARALLEL_JOBS" --no-owner --no-privileges \
    -U "$DB_USER" -d "$DB_NAME" "/tmp/restore/$BACKUP_DIRNAME"

# --- [6/7] Migracja obrazem-kandydatem ---
echo "=== [6/7] manage.py migrate obrazem ${APPSERVER_REPO}:${CANDIDATE} ==="
# Entrypoint nadpisany: zadnych faz startowych (staticfiles, gunicorn) -
# wylacznie migracja. --env-file daje komplet zmiennych jak w produkcji,
# -e nadpisuje hosty na shadow.
set +e
docker run --rm --network "$SHADOW_NET" \
    --env-file "$ENV_FILE" \
    -e DJANGO_BPP_DB_HOST="$SHADOW_DB" \
    -e DJANGO_BPP_DB_PORT=5432 \
    -e DJANGO_BPP_REDIS_HOST="$SHADOW_REDIS" \
    --memory "$SHADOW_MIGRATE_MEM" \
    --entrypoint python \
    "${APPSERVER_REPO}:${CANDIDATE}" src/manage.py migrate --noinput
MIGRATE_RC=$?
set -e

if [ "$MIGRATE_RC" -ne 0 ]; then
    echo "" >&2
    echo "=== BLAD: migracja ${CANDIDATE} NIE przeszla (exit=$MIGRATE_RC) ===" >&2
    echo "Ponowna proba: TAG=$CANDIDATE make test-upgrade" >&2
    exit 1
fi
echo "Migracje OK."

# --- [7/7] Kandydat wstaje i odpowiada ---
echo "=== [7/7] Start kandydata na kopii bazy (gunicorn, bez nginx/workerow/monitoringu) ==="
# Normalny entrypoint obrazu (te same fazy co w produkcji: baseline/migrate =
# no-op po kroku 6, seed staticow, gunicorn). Wlasne puste wolumeny na static
# i media - produkcyjnych nie dotykamy. Kanaly powiadomien wyzerowane, zeby
# ewentualny blad kandydata nie trafil do produkcyjnego Rollbara/Slacka.
docker volume create "$SHADOW_STATIC_VOL" >/dev/null
docker volume create "$SHADOW_MEDIA_VOL" >/dev/null
docker run -d --name "$SHADOW_APP" --network "$SHADOW_NET" \
    --env-file "$ENV_FILE" \
    -e DJANGO_BPP_DB_HOST="$SHADOW_DB" \
    -e DJANGO_BPP_DB_PORT=5432 \
    -e DJANGO_BPP_REDIS_HOST="$SHADOW_REDIS" \
    -e STATIC_ROOT=/staticroot/ \
    -e DJANGO_BPP_MEDIA_ROOT=/mediaroot \
    -e ROLLBAR_ACCESS_TOKEN= \
    -e DJANGO_BPP_SLACK_WEBHOOK= \
    -v "$SHADOW_STATIC_VOL":/staticroot \
    -v "$SHADOW_MEDIA_VOL":/mediaroot \
    --memory "$SHADOW_APP_MEM" \
    "${APPSERVER_REPO}:${CANDIDATE}" >/dev/null

fail_app() {
    echo "" >&2
    echo "=== BLAD: kandydat ${CANDIDATE} $1 ===" >&2
    echo "Ostatnie linie logu kandydata:" >&2
    docker logs --tail 60 "$SHADOW_APP" 2>&1 | sed 's/^/  /' >&2 || true
    exit 1
}

echo "Czekam, az kandydat odpowie na /health/ (do ${SHADOW_APP_TIMEOUT} s)..."
waited=0
until docker exec "$SHADOW_APP" curl -fsS -o /dev/null http://127.0.0.1:8000/health/ >/dev/null 2>&1; do
    if [ "$(docker inspect --format '{{.State.Running}}' "$SHADOW_APP" 2>/dev/null)" != "true" ]; then
        fail_app "zakonczyl dzialanie przy starcie (exit=$(docker inspect --format '{{.State.ExitCode}}' "$SHADOW_APP" 2>/dev/null))"
    fi
    if [ "$waited" -ge "$SHADOW_APP_TIMEOUT" ]; then
        fail_app "nie odpowiedzial na /health/ w ${SHADOW_APP_TIMEOUT} s"
    fi
    sleep 5
    waited=$(( waited + 5 ))
done
echo "/health/ OK po ~${waited} s."

# Strona glowna: Host z konfiguracji (ALLOWED_HOSTS) i X-Forwarded-Proto
# jak zza nginx. Akceptujemy 2xx/3xx - przekierowanie to tez poprawna odpowiedz
# strony; 4xx/5xx albo brak odpowiedzi = kandydat nie dziala.
ROOT_CODE="$(docker exec "$SHADOW_APP" curl -s -o /dev/null -w '%{http_code}' --max-time 60 \
    -H "Host: $APP_HOSTNAME" -H "X-Forwarded-Proto: https" \
    http://127.0.0.1:8000/ 2>/dev/null || true)"
case "$ROOT_CODE" in
    2??|3??) echo "Strona glowna (Host: $APP_HOSTNAME): HTTP $ROOT_CODE." ;;
    *)       fail_app "nie odpowiada poprawnie na / (Host: $APP_HOSTNAME, HTTP ${ROOT_CODE:-brak})" ;;
esac

echo ""
echo "=== OK: migracje ${CANDIDATE} przechodza na kopii produkcyjnej bazy, kandydat wstaje i odpowiada ==="
echo "Sprzatam shadow stack..."
cleanup_shadow
echo "Gotowe. Produkcja przez caly czas byla nietknieta."
exit 0

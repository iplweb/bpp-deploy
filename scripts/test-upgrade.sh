#!/usr/bin/env bash
set -euo pipefail
#
# Proba generalna aktualizacji: czy migracje obrazu-kandydata przechodza na
# kopii produkcyjnej bazy? Dziala CALKOWICIE obok produkcji:
#   - shadow stack (dbserver+redis) czystym `docker run`, poza projektem
#     Compose, na wlasnej sieci bpp-shadow,
#   - pull kandydata PO TAGU WERSJI - lokalny tag :latest produkcji
#     pozostaje nietkniety,
#   - zero zapisu do .env, zero operacji na kontenerach/wolumenach produkcji.
#
# Uzycie:
#   make test-upgrade                  # kandydat = najnowszy CalVer z Huba
#   make test-upgrade TAG=202606.1386  # jawny kandydat
#   make test-upgrade-clean            # sprzatniecie shadow stacka
#
# Wynik: exit 0 = migracje przechodza (shadow posprzatany);
#        exit != 0 = blad (shadow ZOSTAJE do inspekcji).

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib-docker-versions.sh
. "$REPO_DIR/scripts/lib-docker-versions.sh"

SHADOW_NET="bpp-shadow"
SHADOW_DB="bpp-shadow-dbserver"
SHADOW_REDIS="bpp-shadow-redis"
SHADOW_VOL="bpp-shadow-pgdata"
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"
# Limity zasobow shadow stacka - przyciete, zeby nie zaglodzic produkcji.
SHADOW_DB_MEM="${SHADOW_DB_MEM:-1g}"
SHADOW_DB_CPUS="${SHADOW_DB_CPUS:-1.0}"
SHADOW_REDIS_MEM="${SHADOW_REDIS_MEM:-256m}"
SHADOW_MIGRATE_MEM="${SHADOW_MIGRATE_MEM:-2g}"

cleanup_shadow() {
    docker rm -f "$SHADOW_DB" "$SHADOW_REDIS" >/dev/null 2>&1 || true
    docker volume rm -f "$SHADOW_VOL" >/dev/null 2>&1 || true
    docker network rm "$SHADOW_NET" >/dev/null 2>&1 || true
}

if [ "${1:-}" = "--clean" ]; then
    echo "Sprzatam shadow stack ($SHADOW_DB, $SHADOW_REDIS, $SHADOW_VOL, $SHADOW_NET)..."
    cleanup_shadow
    echo "OK."
    exit 0
fi

print_inspect_help() {
    echo "" >&2
    echo "Shadow stack ZOSTAJE do inspekcji:" >&2
    echo "  docker exec -it $SHADOW_DB psql -U \"\$DJANGO_BPP_DB_USER\" -d \"\$DJANGO_BPP_DB_NAME\"" >&2
    echo "Sprzatniecie: make test-upgrade-clean" >&2
}
trap print_inspect_help ERR

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

# Wersja PG: ta sama logika dwuwarstwowego fallbacku co docker-compose.database.yml.
PG_VERSION="$(get_env_var DJANGO_BPP_POSTGRESQL_VERSION)"
[ -n "$PG_VERSION" ] || PG_VERSION="$(get_env_var DJANGO_BPP_DBSERVER_PG_VERSION)"
[ -n "$PG_VERSION" ] || PG_VERSION="16.13"

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

# --- [1/6] Kandydat ---
echo "=== [1/6] Rozwiazuje obraz-kandydata ==="
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

# --- [2/6] Kontrola miejsca na dysku ---
echo "=== [2/6] Kontrola miejsca na dysku ==="
if [ "${SKIP_DISK_CHECK:-0}" != "1" ]; then
    DB_SIZE_MB="$(docker compose exec -T dbserver psql -U "$DB_USER" -d "$DB_NAME" \
        -tAc "SELECT pg_database_size('$DB_NAME')/1024/1024;" | tr -d '[:space:]')"
    NEED_MB=$(( DB_SIZE_MB * 5 / 2 ))   # ~2.5x: dump + untar + shadow volume
    FREE_BACKUP_MB="$(df -Pm "$BACKUP_DIR" | awk 'NR==2 {print $4}')"
    DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
    FREE_DOCKER_MB="$(df -Pm "$DOCKER_ROOT" 2>/dev/null | awk 'NR==2 {print $4}')"
    [ -n "$FREE_DOCKER_MB" ] || FREE_DOCKER_MB="$FREE_BACKUP_MB"
    echo "Baza: ${DB_SIZE_MB} MB; wymagane ~${NEED_MB} MB wolnego miejsca."
    if [ "$FREE_BACKUP_MB" -lt "$NEED_MB" ] || [ "$FREE_DOCKER_MB" -lt "$NEED_MB" ]; then
        echo "BLAD: za malo miejsca (backup dir: ${FREE_BACKUP_MB} MB, docker root: ${FREE_DOCKER_MB} MB)." >&2
        echo "Wymuszenie pominiecia kontroli: SKIP_DISK_CHECK=1 make test-upgrade" >&2
        exit 1
    fi
else
    echo "(pominieta: SKIP_DISK_CHECK=1)"
fi

# --- [3/6] Backup produkcyjnej bazy ---
echo "=== [3/6] Backup produkcyjnej bazy (make db-backup) ==="
make -C "$REPO_DIR" db-backup
BACKUP_TAR_PATH="$(ls -t "$BACKUP_DIR"/db-backup-*.tar.gz 2>/dev/null | head -1)"
if [ -z "$BACKUP_TAR_PATH" ]; then
    echo "BLAD: nie znalazlem swiezego dumpa w $BACKUP_DIR" >&2
    exit 1
fi
BACKUP_TAR="$(basename "$BACKUP_TAR_PATH")"
BACKUP_DIRNAME="${BACKUP_TAR%.tar.gz}"
echo "Dump: $BACKUP_TAR_PATH"

# --- [4/6] Shadow stack ---
echo "=== [4/6] Stawiam shadow stack (siec $SHADOW_NET) ==="
cleanup_shadow   # zombie z poprzedniego przebiegu
docker network create "$SHADOW_NET" >/dev/null
docker volume create "$SHADOW_VOL" >/dev/null
docker run -d --name "$SHADOW_DB" --network "$SHADOW_NET" \
    -e POSTGRES_DB="$DB_NAME" \
    -e POSTGRES_USER="$DB_USER" \
    -e POSTGRES_PASSWORD="$DB_PASSWORD" \
    -v "$SHADOW_VOL":/var/lib/postgresql/data \
    -v "$BACKUP_DIR":/backup:ro \
    --memory "$SHADOW_DB_MEM" --cpus "$SHADOW_DB_CPUS" \
    "iplweb/bpp_dbserver:psql-${PG_VERSION}" >/dev/null
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

# --- [5/6] Restore dumpa do shadow-bazy ---
echo "=== [5/6] Restore dumpa do shadow-bazy (pg_restore -j $PARALLEL_JOBS) ==="
docker exec "$SHADOW_DB" mkdir -p /tmp/restore
docker exec "$SHADOW_DB" tar xzf "/backup/$BACKUP_TAR" -C /tmp/restore
docker exec "$SHADOW_DB" pg_restore -Fd -j "$PARALLEL_JOBS" --no-owner \
    -U "$DB_USER" -d "$DB_NAME" "/tmp/restore/$BACKUP_DIRNAME"

# --- [6/6] Migracja obrazem-kandydatem ---
echo "=== [6/6] manage.py migrate obrazem ${APPSERVER_REPO}:${CANDIDATE} ==="
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

if [ "$MIGRATE_RC" -eq 0 ]; then
    trap - ERR
    echo ""
    echo "=== OK: migracje ${CANDIDATE} przechodza na kopii produkcyjnej bazy ==="
    echo "Sprzatam shadow stack..."
    cleanup_shadow
    echo "Gotowe. Produkcja przez caly czas byla nietknieta."
    exit 0
else
    echo "" >&2
    echo "=== BLAD: migracja ${CANDIDATE} NIE przeszla (exit=$MIGRATE_RC) ===" >&2
    echo "Shadow stack ZOSTAJE do inspekcji:" >&2
    echo "  docker exec -it $SHADOW_DB psql -U $DB_USER -d $DB_NAME" >&2
    echo "Ponowna proba migracji (po obejrzeniu):" >&2
    echo "  TAG=$CANDIDATE make test-upgrade" >&2
    echo "Sprzatniecie: make test-upgrade-clean" >&2
    exit 1
fi

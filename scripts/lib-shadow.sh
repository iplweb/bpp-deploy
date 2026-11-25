#!/usr/bin/env bash
# Shadow stack - izolowana kopia BPP obok produkcji (dbserver + redis +
# appserver czystym `docker run`, poza projektem Compose, na sieci bpp-shadow).
# Wspolna mechanika dla:
#   - scripts/test-upgrade.sh          (`make test-upgrade`: migracje kandydata
#                                        na kopii produkcyjnej bazy),
#   - scripts/restore-server.sh --proba (`make proba-odtworzenia`: proba
#                                        odtworzenia z kopii ZDALNEJ).
# Biblioteka do sourcowania - bez side-effectow przy source.
#
# Kontrakty (pilnowane w scripts/test-docker-versions.sh):
#   - nazwy bpp-shadow-* sa globalne dla demona Dockera, wiec JEDNA blokada
#     (shadow_lock_acquire) obejmuje obie proby - test-upgrade i proba
#     odtworzenia nie moga sobie nawzajem ubic bazy w polowie restore;
#   - shadow-baza to lustro serwisu dbserver: ten sam obraz, autotune
#     bind-mountowany z ./dbserver/, PGDATA przypiety, ICU pl-PL przy initdb;
#   - haslo bazy przez srodowisko procesu docker (`-e VAR` bez wartosci),
#     nigdy jako wartosc w argv;
#   - zadnych operacji na kontenerach/wolumenach produkcji.
# Wymaga: REPO_DIR (katalog repo).

SHADOW_NET="bpp-shadow"
SHADOW_DB="bpp-shadow-dbserver"
SHADOW_REDIS="bpp-shadow-redis"
SHADOW_APP="bpp-shadow-appserver"
SHADOW_VOL="bpp-shadow-pgdata"
SHADOW_STATIC_VOL="bpp-shadow-staticfiles"
SHADOW_MEDIA_VOL="bpp-shadow-media"
# Limity zasobow shadow stacka - przyciete, zeby nie zaglodzic produkcji.
SHADOW_DB_MEM="${SHADOW_DB_MEM:-1g}"
SHADOW_DB_CPUS="${SHADOW_DB_CPUS:-1.0}"
SHADOW_REDIS_MEM="${SHADOW_REDIS_MEM:-256m}"
SHADOW_MIGRATE_MEM="${SHADOW_MIGRATE_MEM:-2g}"
SHADOW_APP_MEM="${SHADOW_APP_MEM:-2g}"
# Ile sekund czekamy, az kandydat odpowie na /health/.
SHADOW_APP_TIMEOUT="${SHADOW_APP_TIMEOUT:-600}"
# Jedna blokada dla wszystkich uzytkownikow shadow stacka (nazwa historyczna).
SHADOW_LOCK_DIR="${TEST_UPGRADE_LOCK_DIR:-${TMPDIR:-/tmp}/bpp-test-upgrade.lock}"

shadow_cleanup() {
    docker rm -f "$SHADOW_APP" "$SHADOW_DB" "$SHADOW_REDIS" >/dev/null 2>&1 || true
    docker volume rm -f "$SHADOW_VOL" "$SHADOW_STATIC_VOL" "$SHADOW_MEDIA_VOL" >/dev/null 2>&1 || true
    docker network rm "$SHADOW_NET" >/dev/null 2>&1 || true
}

# shadow_lock_acquire -- exit 2 (z procesu wolajacego), gdy inna proba trwa.
# mkdir jest atomowy; martwy wlasciciel (SIGKILL, reboot) = przejecie.
shadow_lock_acquire() {
    local owner
    if ! mkdir "$SHADOW_LOCK_DIR" 2>/dev/null; then
        owner="$(cat "$SHADOW_LOCK_DIR/pid" 2>/dev/null || true)"
        if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
            echo "BLAD: inna proba (test-upgrade / proba odtworzenia) trwa na tym hoscie (pid $owner, blokada $SHADOW_LOCK_DIR)." >&2
            exit 2
        fi
        echo "Przejmuje osierocona blokade $SHADOW_LOCK_DIR (pid ${owner:-?} nie zyje)."
        rm -f "$SHADOW_LOCK_DIR/pid"
        rmdir "$SHADOW_LOCK_DIR" 2>/dev/null || true
        if ! mkdir "$SHADOW_LOCK_DIR" 2>/dev/null; then
            echo "BLAD: nie moge przejac blokady $SHADOW_LOCK_DIR." >&2
            exit 2
        fi
    fi
    echo "$$" > "$SHADOW_LOCK_DIR/pid"
}

shadow_lock_release() {
    rm -f "$SHADOW_LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$SHADOW_LOCK_DIR" 2>/dev/null || true
}

# shadow_start_db <obraz> <env_file> <katalog_z_dumpem> <db_name> <db_user> <db_password>
# Lustro serwisu dbserver z docker-compose.database.yml. POSTGRESQL_RAM_THIS_MUCH_GB
# zerujemy: wartosc dobrana pod produkcje przekroczylaby przyciety limit
# shadow-bazy - autotune ma czytac jej cgroup.
shadow_start_db() {
    local image="$1" env_file="$2" dump_dir="$3" db_name="$4" db_user="$5" db_password="$6"
    docker network create "$SHADOW_NET" >/dev/null
    docker volume create "$SHADOW_VOL" >/dev/null
    POSTGRES_PASSWORD="$db_password" docker run -d --name "$SHADOW_DB" --network "$SHADOW_NET" \
        --env-file "$env_file" \
        -e POSTGRES_DB="$db_name" \
        -e POSTGRES_USER="$db_user" \
        -e POSTGRES_PASSWORD \
        -e PGDATA=/var/lib/postgresql/data \
        -e POSTGRES_INITDB_ARGS="--locale-provider=icu --icu-locale=pl-PL" \
        -e POSTGRESQL_RAM_THIS_MUCH_GB= \
        -v "$REPO_DIR/dbserver/docker-entrypoint-autotune.sh":/usr/local/bin/docker-entrypoint-autotune.sh:ro \
        -v "$REPO_DIR/dbserver/autotune.sh":/autotune.sh:ro \
        -v "$SHADOW_VOL":/var/lib/postgresql/data \
        -v "$dump_dir":/backup:ro \
        --memory "$SHADOW_DB_MEM" --cpus "$SHADOW_DB_CPUS" \
        --entrypoint bash \
        "$image" /usr/local/bin/docker-entrypoint-autotune.sh postgres >/dev/null
}

shadow_start_redis() {
    docker run -d --name "$SHADOW_REDIS" --network "$SHADOW_NET" \
        --memory "$SHADOW_REDIS_MEM" \
        "$1" >/dev/null
}

# shadow_wait_db <db_user> <db_name> -- 1, gdy baza nie wstala w 120 s.
shadow_wait_db() {
    local i
    echo "Czekam na gotowosc shadow-postgresa..."
    for i in $(seq 1 60); do
        if docker exec "$SHADOW_DB" pg_isready -U "$1" -d "$2" >/dev/null 2>&1; then
            return 0
        fi
        if [ "$i" -eq 60 ]; then
            echo "BLAD: shadow-postgres nie wstal w 120 s" >&2
            return 1
        fi
        sleep 2
    done
}

# shadow_restore_db <db-backup-TS.tar.gz> <db-backup-TS> <db_user> <db_name> <jobs>
# --no-owner + --no-privileges: shadow ma tylko jedna role. GRANT-y dla rol,
# ktorych tu nie ma (monitoring, role bazy zewnetrznej), konczylyby pg_restore
# bledem, choc z sama kopia nie maja nic wspolnego.
shadow_restore_db() {
    local tar="$1" dirname="$2" db_user="$3" db_name="$4" jobs="$5"
    docker exec "$SHADOW_DB" mkdir -p /tmp/restore
    docker exec "$SHADOW_DB" tar xzf "/backup/$tar" -C /tmp/restore
    docker exec "$SHADOW_DB" pg_restore -Fd -j "$jobs" --no-owner --no-privileges \
        -U "$db_user" -d "$db_name" "/tmp/restore/$dirname"
}

# shadow_start_app <obraz> <env_file>
# Normalny entrypoint obrazu, wlasne puste wolumeny static/media (media mozna
# wczesniej wypelnic - wolumen tworzymy tylko, gdy go nie ma). Kanaly
# powiadomien wyzerowane - blad shadowa nie trafia do produkcyjnego
# Rollbara/GlitchTipa/Slacka.
shadow_start_app() {
    local image="$1" env_file="$2"
    docker volume create "$SHADOW_STATIC_VOL" >/dev/null
    docker volume create "$SHADOW_MEDIA_VOL" >/dev/null
    docker run -d --name "$SHADOW_APP" --network "$SHADOW_NET" \
        --env-file "$env_file" \
        -e DJANGO_BPP_DB_HOST="$SHADOW_DB" \
        -e DJANGO_BPP_DB_PORT=5432 \
        -e DJANGO_BPP_REDIS_HOST="$SHADOW_REDIS" \
        -e STATIC_ROOT=/staticroot/ \
        -e DJANGO_BPP_MEDIA_ROOT=/mediaroot \
        -e ROLLBAR_ACCESS_TOKEN= \
        -e SENTRY_DSN= \
        -e DJANGO_BPP_SLACK_WEBHOOK= \
        -v "$SHADOW_STATIC_VOL":/staticroot \
        -v "$SHADOW_MEDIA_VOL":/mediaroot \
        --memory "$SHADOW_APP_MEM" \
        "$image" >/dev/null
}

shadow_app_logs() {
    echo "Ostatnie linie logu kandydata:" >&2
    docker logs --tail 60 "$SHADOW_APP" 2>&1 | sed 's/^/  /' >&2 || true
}

# shadow_check_app <hostname>
# 0 = /health/ OK i / odpowiada 2xx/3xx (Host z konfiguracji, X-Forwarded-Proto
# jak zza nginx). Inaczej 1 i SHADOW_APP_ERROR z opisem.
# shellcheck disable=SC2034  # czytane przez wolajacych (test-upgrade, restore-server)
SHADOW_APP_ERROR=""
SHADOW_ROOT_CODE=""
# shellcheck disable=SC2034  # SHADOW_APP_ERROR czytaja wolajacy
shadow_check_app() {
    local host="$1" waited=0
    echo "Czekam, az appserver odpowie na /health/ (do ${SHADOW_APP_TIMEOUT} s)..."
    until docker exec "$SHADOW_APP" curl -fsS -o /dev/null http://127.0.0.1:8000/health/ >/dev/null 2>&1; do
        if [ "$(docker inspect --format '{{.State.Running}}' "$SHADOW_APP" 2>/dev/null)" != "true" ]; then
            SHADOW_APP_ERROR="zakonczyl dzialanie przy starcie (exit=$(docker inspect --format '{{.State.ExitCode}}' "$SHADOW_APP" 2>/dev/null))"
            return 1
        fi
        if [ "$waited" -ge "$SHADOW_APP_TIMEOUT" ]; then
            SHADOW_APP_ERROR="nie odpowiedzial na /health/ w ${SHADOW_APP_TIMEOUT} s"
            return 1
        fi
        sleep 5
        waited=$(( waited + 5 ))
    done
    echo "/health/ OK po ~${waited} s."
    SHADOW_ROOT_CODE="$(docker exec "$SHADOW_APP" curl -s -o /dev/null -w '%{http_code}' --max-time 60 \
        -H "Host: $host" -H "X-Forwarded-Proto: https" \
        http://127.0.0.1:8000/ 2>/dev/null || true)"
    case "$SHADOW_ROOT_CODE" in
        2??|3??) echo "Strona glowna (Host: $host): HTTP $SHADOW_ROOT_CODE." ;;
        *) SHADOW_APP_ERROR="nie odpowiada poprawnie na / (Host: $host, HTTP ${SHADOW_ROOT_CODE:-brak})"
           return 1 ;;
    esac
}

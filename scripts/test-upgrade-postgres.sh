#!/usr/bin/env bash
#
# Integration test dla scripts/upgrade-postgres.sh.
#
# Scenariusz: upgrade iplweb/bpp_dbserver:psql-16.13 -> :psql-18.3.
#
# Test buduje izolowana piaskownice:
#   - wlasny COMPOSE_PROJECT_NAME (unikalny per run)
#   - tymczasowy BPP_CONFIGS_DIR z minimalnym .env
#   - minimalny docker-compose.test.yml (tylko dbserver)
#   - tymczasowo podmienione repo .env (make db-backup czyta stamtad
#     BPP_CONFIGS_DIR; cleanup trap przywraca oryginal)
#
# Kroki 2 (stop serwisow) i 10 (make migrate + make up) sa pomijane bo wymagaja
# pelnego stacka. Pozostale 1, 3-9 lecza przez prawdziwy skrypt.
#
# Uruchomienie: `make test-upgrade-postgres` lub
#   `bash scripts/test-upgrade-postgres.sh`

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/upgrade-postgres.sh"
REPO_ENV="$REPO_DIR/.env"

OLD_VERSION="${OLD_VERSION:-16.13}"
NEW_VERSION="${NEW_VERSION:-18.3}"
EXPECTED_NEW_MAJOR="${NEW_VERSION%%.*}"

if [ ! -f "$SCRIPT" ]; then
    echo "BLAD: brak $SCRIPT" >&2
    exit 1
fi

TEST_ROOT="$(mktemp -d -t bpp-upg-test-XXXXXX)"
TEST_CONFIGS="$TEST_ROOT/configs"
TEST_BACKUP="$TEST_ROOT/backup"
TEST_COMPOSE="$TEST_ROOT/docker-compose.test.yml"
TEST_ENV="$TEST_CONFIGS/.env"
TEST_PROJECT="bppupgtest$(date +%s)$$"
VOLUME_NAME="${TEST_PROJECT}_postgresql_data"
REPO_ENV_BACKUP="$TEST_ROOT/repo-env.orig"

mkdir -p "$TEST_CONFIGS" "$TEST_BACKUP"

REPO_ENV_EXISTED=0
if [ -f "$REPO_ENV" ]; then
    cp "$REPO_ENV" "$REPO_ENV_BACKUP"
    REPO_ENV_EXISTED=1
fi

TEST_FAILED=0

cleanup() {
    local rc=$?
    set +e
    echo ""
    echo "=== CLEANUP ==="
    docker compose -f "$TEST_COMPOSE" -p "$TEST_PROJECT" down -v --remove-orphans 2>/dev/null
    docker volume ls --format '{{.Name}}' 2>/dev/null \
        | grep "^${TEST_PROJECT}_postgresql_data" \
        | while read -r v; do
            docker volume rm "$v" 2>/dev/null
        done
    if [ "$REPO_ENV_EXISTED" = 1 ]; then
        cp "$REPO_ENV_BACKUP" "$REPO_ENV"
    else
        rm -f "$REPO_ENV"
    fi
    rm -rf "$TEST_ROOT"
    if [ "$rc" = 0 ] && [ "$TEST_FAILED" = 0 ]; then
        echo "=========================================="
        echo "  TEST PASSED"
        echo "=========================================="
    else
        echo "=========================================="
        echo "  TEST FAILED (exit $rc)"
        echo "=========================================="
    fi
}
trap cleanup EXIT INT TERM

cat > "$TEST_COMPOSE" <<'COMPOSE_EOF'
services:
  dbserver:
    # iplweb/bpp_dbserver jest zbudowany tylko dla linux/amd64 - na ARM Mac
    # bez platform: musieli bysmy liczyc na auto qemu, ktorego nie ma.
    platform: linux/amd64
    image: iplweb/bpp_dbserver:psql-${DJANGO_BPP_POSTGRESQL_VERSION:-16.13}
    environment:
      POSTGRES_DB: ${DJANGO_BPP_DB_NAME}
      POSTGRES_USER: ${DJANGO_BPP_DB_USER}
      POSTGRES_PASSWORD: ${DJANGO_BPP_DB_PASSWORD}
    volumes:
      - postgresql_data:/var/lib/postgresql/data
      - ${DJANGO_BPP_HOST_BACKUP_DIR}:/backup

volumes:
  postgresql_data:
COMPOSE_EOF

cat > "$TEST_ENV" <<EOF
DJANGO_BPP_POSTGRESQL_VERSION=$OLD_VERSION
DJANGO_BPP_POSTGRESQL_VERSION_MAJOR=${OLD_VERSION%%.*}
DJANGO_BPP_DB_HOST=dbserver
DJANGO_BPP_DB_PORT=5432
DJANGO_BPP_DB_USER=bpp
DJANGO_BPP_DB_PASSWORD=testpass_$(date +%s)
DJANGO_BPP_DB_NAME=bpp
DJANGO_BPP_HOST_BACKUP_DIR=$TEST_BACKUP
EOF

cat > "$REPO_ENV" <<EOF
BPP_CONFIGS_DIR=$TEST_CONFIGS
COMPOSE_PROJECT_NAME=$TEST_PROJECT
EOF

export BPP_CONFIGS_DIR="$TEST_CONFIGS"
export COMPOSE_PROJECT_NAME="$TEST_PROJECT"
export COMPOSE_FILE="$TEST_COMPOSE"
# iplweb/bpp_dbserver jest dostarczany tylko jako linux/amd64. Na ARM Mac
# (M1/M2/M3) musimy to powiedziec Dockerowi explicite. Skrypt w kroku 1 robi
# `docker pull <image>` bez --platform; DOCKER_DEFAULT_PLATFORM dziala na
# docker pull i docker compose, wiec jedna zmienna zalatwia oba.
if [ -z "${DOCKER_DEFAULT_PLATFORM:-}" ]; then
    _arch="$(uname -m)"
    case "$_arch" in
        arm64|aarch64) export DOCKER_DEFAULT_PLATFORM=linux/amd64 ;;
    esac
fi
set -a
# shellcheck disable=SC1090
. "$TEST_ENV"
set +a

cat <<EOF
==========================================
  TEST: upgrade-postgres.sh
  ${OLD_VERSION} -> ${NEW_VERSION}
==========================================

  Test root:       $TEST_ROOT
  Test project:    $TEST_PROJECT
  BPP_CONFIGS_DIR: $TEST_CONFIGS
  Compose file:    $TEST_COMPOSE
  Backup dir:      $TEST_BACKUP
  Volume:          $VOLUME_NAME

EOF

# shellcheck disable=SC2120  # optional arg, default fine
wait_for_healthy() {
    local max_attempts="${1:-40}"
    local container state attempt=0
    state=none
    while [ "$attempt" -lt "$max_attempts" ]; do
        attempt=$((attempt + 1))
        container="$(docker compose -f "$TEST_COMPOSE" -p "$TEST_PROJECT" ps -q dbserver 2>/dev/null || true)"
        if [ -n "$container" ]; then
            state="$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null || echo none)"
            if [ "$state" = "healthy" ]; then
                echo "  dbserver healthy po ${attempt}*3s."
                return 0
            fi
        fi
        sleep 3
    done
    echo "BLAD: dbserver nie wstal jako healthy w $((max_attempts * 3))s (state=$state)." >&2
    docker compose -f "$TEST_COMPOSE" -p "$TEST_PROJECT" logs --tail=60 dbserver >&2
    return 1
}

run_psql() {
    docker compose -f "$TEST_COMPOSE" -p "$TEST_PROJECT" exec -T \
        -e "PGPASSWORD=$DJANGO_BPP_DB_PASSWORD" \
        dbserver \
        psql -v ON_ERROR_STOP=1 \
            -U "$DJANGO_BPP_DB_USER" \
            -d "$DJANGO_BPP_DB_NAME" \
            "$@"
}

echo "=== [pre] Pull + start dbserver $OLD_VERSION ==="
docker compose -f "$TEST_COMPOSE" -p "$TEST_PROJECT" pull dbserver
docker compose -f "$TEST_COMPOSE" -p "$TEST_PROJECT" up -d dbserver
wait_for_healthy

echo
echo "=== [pre] Seed danych testowych ==="
run_psql <<'SQL'
CREATE TABLE upgrade_canary (
    id SERIAL PRIMARY KEY,
    payload TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
INSERT INTO upgrade_canary (payload) VALUES
    ('canary-row-alpha'),
    ('canary-row-beta'),
    ('canary-row-gamma');
SQL

EXPECTED_COUNT=3
BEFORE_COUNT="$(run_psql -tAc "SELECT COUNT(*) FROM upgrade_canary" | tr -d '[:space:]')"
BEFORE_VERSION="$(docker compose -f "$TEST_COMPOSE" -p "$TEST_PROJECT" exec -T dbserver postgres --version)"
BEFORE_MAJOR="$(echo "$BEFORE_VERSION" | grep -oE '[0-9]+' | head -1)"

echo "  Rows przed upgrade:  $BEFORE_COUNT"
echo "  Wersja przed:        $BEFORE_VERSION (major $BEFORE_MAJOR)"

if [ "$BEFORE_COUNT" != "$EXPECTED_COUNT" ]; then
    echo "BLAD: seed - oczekiwano $EXPECTED_COUNT rows, jest $BEFORE_COUNT" >&2
    TEST_FAILED=1
    exit 1
fi
if [ "$BEFORE_MAJOR" != "${OLD_VERSION%%.*}" ]; then
    echo "BLAD: stara wersja - oczekiwano major ${OLD_VERSION%%.*}, jest $BEFORE_MAJOR" >&2
    TEST_FAILED=1
    exit 1
fi

echo
echo "=== RUN upgrade-postgres.sh --noinput --new-version=$NEW_VERSION --skip-step=2,10 ==="
echo
bash "$SCRIPT" \
    --noinput \
    --new-version="$NEW_VERSION" \
    --skip-step=2,10

echo
echo "=== [post] Asercje ==="

AFTER_VERSION="$(docker compose -f "$TEST_COMPOSE" -p "$TEST_PROJECT" exec -T dbserver postgres --version)"
AFTER_MAJOR="$(echo "$AFTER_VERSION" | grep -oE '[0-9]+' | head -1)"
echo "  Wersja po:           $AFTER_VERSION (major $AFTER_MAJOR)"

if [ "$AFTER_MAJOR" != "$EXPECTED_NEW_MAJOR" ]; then
    echo "BLAD: po upgrade oczekiwano major $EXPECTED_NEW_MAJOR, jest $AFTER_MAJOR" >&2
    TEST_FAILED=1
    exit 1
fi

AFTER_COUNT="$(run_psql -tAc "SELECT COUNT(*) FROM upgrade_canary" | tr -d '[:space:]')"
echo "  Rows po upgrade:     $AFTER_COUNT"

if [ "$AFTER_COUNT" != "$EXPECTED_COUNT" ]; then
    echo "BLAD: po upgrade oczekiwano $EXPECTED_COUNT rows, jest $AFTER_COUNT" >&2
    TEST_FAILED=1
    exit 1
fi

PAYLOADS="$(run_psql -tAc "SELECT payload FROM upgrade_canary ORDER BY id" | tr -d '\r' | tr '\n' '|')"
EXPECTED_PAYLOADS="canary-row-alpha|canary-row-beta|canary-row-gamma|"
if [ "$PAYLOADS" != "$EXPECTED_PAYLOADS" ]; then
    echo "BLAD: payloady po upgrade nie pasuja." >&2
    echo "  Oczekiwano: $EXPECTED_PAYLOADS" >&2
    echo "  Dostalem:   $PAYLOADS" >&2
    TEST_FAILED=1
    exit 1
fi
echo "  Payloady:            OK"

if ! docker volume ls --format '{{.Name}}' | grep -q "^${TEST_PROJECT}_postgresql_data_pg${BEFORE_MAJOR}_"; then
    echo "BLAD: backup volume z PGDATA sprzed upgrade'u nie istnieje." >&2
    TEST_FAILED=1
    exit 1
fi
echo "  Backup volume:       OK (zachowany)"

if ! ls "$TEST_CONFIGS"/.upgrade-rollback-* >/dev/null 2>&1; then
    echo "BLAD: brak pliku .upgrade-rollback-* w $TEST_CONFIGS" >&2
    TEST_FAILED=1
    exit 1
fi
echo "  Plik stanu:          OK"

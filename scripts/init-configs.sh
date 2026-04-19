#!/usr/bin/env bash
#
# Inicjalizacja katalogu konfiguracyjnego instancji BPP.
# Wywoływane przez: make init-configs
#
# Argumenty:
#   $1 — obecna wartość BPP_CONFIGS_DIR (może być pusta)
#   $2 — HOME użytkownika
#

set -euo pipefail

BPP_CONFIGS_DIR="${1:-}"
USER_HOME="${2:-$HOME}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DEFAULTS_DIR="$REPO_DIR/defaults"

# --- 1. Oblicz domyślną ścieżkę ---

if [ -n "$BPP_CONFIGS_DIR" ]; then
    DEFAULT_CONFIG_DIR="$BPP_CONFIGS_DIR"
else
    SANITIZED="$( (hostname -f 2>/dev/null || hostname) | tr '.-' '__')"
    DEFAULT_CONFIG_DIR="$USER_HOME/$SANITIZED"
fi

# --- 2. Zapytaj o ścieżkę ---

echo ""
echo "Podaj sciezke do katalogu konfiguracyjnego instancji BPP."
echo "Katalog musi znajdowac sie POZA repozytorium."
echo ""
printf "Sciezka [%s]: " "$DEFAULT_CONFIG_DIR"
read -r INPUT_DIR || true
INPUT_DIR="${INPUT_DIR:-$DEFAULT_CONFIG_DIR}"

# Expand tilde
INPUT_DIR=$(eval echo "$INPUT_DIR")

# Absolutna ścieżka. Jesli katalog istnieje - uzyj `cd && pwd` (najbardziej
# niezawodne). Jesli nie istnieje - zrob absolutyzacje recznie, bo dirname
# na sciezce wzglednej (np. "./foo") daje "." i psuje obliczanie
# DEFAULT_BACKUP_DIR ponizej.
if [ -d "$INPUT_DIR" ]; then
    ABS_CONFIG="$(cd "$INPUT_DIR" && pwd)"
else
    case "$INPUT_DIR" in
        /*) ABS_CONFIG="$INPUT_DIR" ;;
        *)  ABS_CONFIG="$(pwd)/$INPUT_DIR" ;;
    esac
fi

# Walidacja: nie wewnątrz repozytorium
case "$ABS_CONFIG" in
    "$REPO_DIR"*)
        echo "BLAD: Katalog konfiguracyjny nie moze byc wewnatrz repozytorium!"
        exit 1
        ;;
esac

# --- 3. Zapisz do .env w repo ---

PROJECT_NAME="$(basename "$ABS_CONFIG")"

# Zachowaj poprzednio wybrany tryb bazy (external vs lokalna), jeśli istniał.
PREV_DATABASE_COMPOSE=""
if [ -f "$REPO_DIR/.env" ]; then
    PREV_DATABASE_COMPOSE="$(grep -E '^BPP_DATABASE_COMPOSE=' "$REPO_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
fi

echo "BPP_CONFIGS_DIR=$ABS_CONFIG" > "$REPO_DIR/.env"
echo "COMPOSE_PROJECT_NAME=$PROJECT_NAME" >> "$REPO_DIR/.env"
echo "Zapisano BPP_CONFIGS_DIR=$ABS_CONFIG, COMPOSE_PROJECT_NAME=$PROJECT_NAME w .env"
echo ""

# --- 3a. Zapytaj o tryb bazy danych (wewnetrzna vs zewnetrzna) ---

echo "Tryb bazy danych:"
echo "  (1) wewnetrzna - PostgreSQL w kontenerze Docker (domyslne)"
echo "  (2) zewnetrzna - podlaczenie do istniejacego, zewnetrznego serwera PostgreSQL"
echo ""

if [ "$PREV_DATABASE_COMPOSE" = "docker-compose.database.external.yml" ]; then
    DB_MODE_DEFAULT="2"
    DB_MODE_LABEL="zewnetrzna (poprzedni wybor)"
else
    DB_MODE_DEFAULT="1"
    DB_MODE_LABEL="wewnetrzna"
fi

printf "Wybierz tryb [1/2, default: %s - %s]: " "$DB_MODE_DEFAULT" "$DB_MODE_LABEL"
read -r DB_MODE_INPUT || true
DB_MODE_INPUT="${DB_MODE_INPUT:-$DB_MODE_DEFAULT}"

case "$DB_MODE_INPUT" in
    2|external|zewnetrzna|z)
        BPP_EXTERNAL_DB=yes
        echo "BPP_DATABASE_COMPOSE=docker-compose.database.external.yml" >> "$REPO_DIR/.env"
        echo "Zapisano BPP_DATABASE_COMPOSE=docker-compose.database.external.yml w .env"
        ;;
    *)
        BPP_EXTERNAL_DB=no
        ;;
esac
echo ""

# --- 4. Backup jeśli istnieje ---

if [ -d "$ABS_CONFIG" ] && [ -f "$ABS_CONFIG/.env" ]; then
    BACKUP="$ABS_CONFIG.backup-$(date +%Y%m%d-%H%M%S)"
    cp -a "$ABS_CONFIG" "$BACKUP"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!!                                                      !!!"
    echo "!!!   UWAGA: Katalog konfiguracyjny juz istnieje!        !!!"
    echo "!!!   $ABS_CONFIG"
    echo "!!!                                                      !!!"
    echo "!!!   Kopia zapasowa utworzona:                           !!!"
    echo "!!!   $BACKUP"
    echo "!!!                                                      !!!"
    echo "!!!   Istniejace pliki NIE zostana nadpisane.             !!!"
    echo "!!!   Zostana dodane jedynie brakujace pliki/katalogi.    !!!"
    echo "!!!                                                      !!!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
fi

# --- 5. Utwórz strukturę katalogów ---

echo "=== Inicjalizacja katalogu konfiguracyjnego ==="
echo "Katalog: $ABS_CONFIG"
echo ""

mkdir -p "$ABS_CONFIG/ssl"
mkdir -p "$ABS_CONFIG/rclone"
mkdir -p "$ABS_CONFIG/alloy"
mkdir -p "$ABS_CONFIG/loki"
mkdir -p "$ABS_CONFIG/prometheus"
mkdir -p "$ABS_CONFIG/rabbitmq"
mkdir -p "$ABS_CONFIG/grafana/provisioning/datasources"
mkdir -p "$ABS_CONFIG/grafana/provisioning/dashboards"

# --- 6. Kopiuj szablony (nie nadpisuj istniejących) ---

copy_if_missing() {
    local src="$1" dest="$2"
    if [ ! -f "$dest" ]; then
        cp "$src" "$dest"
    fi
}

copy_if_missing "$CONFIG_DEFAULTS_DIR/alloy/config.alloy" "$ABS_CONFIG/alloy/config.alloy"
copy_if_missing "$CONFIG_DEFAULTS_DIR/loki/local-config.yaml" "$ABS_CONFIG/loki/local-config.yaml"
copy_if_missing "$CONFIG_DEFAULTS_DIR/prometheus/prometheus.yml" "$ABS_CONFIG/prometheus/prometheus.yml"
copy_if_missing "$CONFIG_DEFAULTS_DIR/rabbitmq/enabled_plugins" "$ABS_CONFIG/rabbitmq/enabled_plugins"

while IFS= read -r -d '' f; do
    rel="${f#"$CONFIG_DEFAULTS_DIR/grafana/provisioning/"}"
    dest="$ABS_CONFIG/grafana/provisioning/$rel"
    copy_if_missing "$f" "$dest"
done < <(find "$CONFIG_DEFAULTS_DIR/grafana/provisioning" -type f -print0)

# --- 7. Generuj lub uzupełnij .env ---

ENV_FILE="$ABS_CONFIG/.env"

# Sprawdza czy zmienna jest zdefiniowana w pliku .env (nawet z pustą wartością).
# Szuka linii pasującej do: NAZWA_ZMIENNEJ= (z opcjonalną wartością).
env_has_var() {
    grep -q "^${1}=" "$ENV_FILE" 2>/dev/null
}

# Zwraca wartość zmiennej z .env (pusta jeśli brak). Usuwa otaczające
# cudzysłowy (pojedyncze lub podwójne), jeśli wartość byla zapisana w
# postaci KEY="value" lub KEY='value'.
get_env_var() {
    local raw
    raw="$(grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
    # Strip otaczających podwójnych cudzysłowów
    if [ "${raw#\"}" != "$raw" ] && [ "${raw%\"}" != "$raw" ]; then
        raw="${raw#\"}"
        raw="${raw%\"}"
    fi
    # Strip otaczających pojedynczych cudzysłowów
    if [ "${raw#\'}" != "$raw" ] && [ "${raw%\'}" != "$raw" ]; then
        raw="${raw#\'}"
        raw="${raw%\'}"
    fi
    printf '%s' "$raw"
}

# Ustawia (nadpisuje lub dopisuje) zmienną w .env. W przeciwieństwie do
# ensure_env_var nie jest idempotentny - zawsze wymusza podaną wartość.
set_env_var() {
    local var_name="$1" value="$2" comment="${3:-}"

    if env_has_var "$var_name"; then
        # Nadpisz istniejącą linię (BSD/GNU sed compat przez plik tymczasowy).
        local tmp="$ENV_FILE.tmp.$$"
        awk -v k="$var_name" -v v="$value" '
            BEGIN { FS=OFS="=" }
            $1 == k { print k "=" v; next }
            { print }
        ' "$ENV_FILE" > "$tmp" && mv "$tmp" "$ENV_FILE"
        echo "  ~ zaktualizowano ${var_name}"
    else
        echo "" >> "$ENV_FILE"
        if [ -n "$comment" ]; then
            echo "# $comment" >> "$ENV_FILE"
        fi
        echo "# Dopisano automatycznie: $(date '+%Y-%m-%d %H:%M:%S')" >> "$ENV_FILE"
        echo "${var_name}=${value}" >> "$ENV_FILE"
        echo "  + dodano ${var_name}"
    fi
}

# Dopisuje brakującą zmienną do .env. Pyta użytkownika o wartość jeśli
# $3 (ask) jest niepuste — wtedy $2 to wartość domyślna wyświetlana w prompcie.
# Jeśli $3 jest puste, dopisuje $2 jako wartość bez pytania.
# $4 (opcjonalny) — komentarz dopisywany nad zmienną.
ensure_env_var() {
    local var_name="$1" default_val="$2" ask="${3:-}" comment="${4:-}"

    if env_has_var "$var_name"; then
        return 0
    fi

    local value="$default_val"
    if [ -n "$ask" ]; then
        printf "%s [%s]: " "$ask" "$default_val"
        read -r value || true
        value="${value:-$default_val}"
    fi

    echo "" >> "$ENV_FILE"
    if [ -n "$comment" ]; then
        echo "# $comment" >> "$ENV_FILE"
    fi
    echo "# Dopisano automatycznie: $(date '+%Y-%m-%d %H:%M:%S')" >> "$ENV_FILE"
    echo "${var_name}=${value}" >> "$ENV_FILE"
    echo "  + dodano ${var_name}"
}

if [ ! -f "$ENV_FILE" ]; then
    # --- Nowy plik: generuj od zera ---

    DEFAULT_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
    printf "Podaj nazwe hosta dla aplikacji [%s]: " "$DEFAULT_HOSTNAME"
    read -r BPP_HOSTNAME || true
    BPP_HOSTNAME="${BPP_HOSTNAME:-$DEFAULT_HOSTNAME}"
    echo ""

    printf "Nazwa uzytkownika administratora [admin]: "
    read -r ADMIN_USERNAME || true
    ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"

    printf "Email administratora [admin@example.com]: "
    read -r ADMIN_EMAIL || true
    ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"

    printf "Slack webhook URL (opcjonalny, Enter = pomin): "
    read -r SLACK_WEBHOOK || true

    DEFAULT_BACKUP_DIR="$(dirname "$ABS_CONFIG")/backups"
    printf "Katalog backupow [%s]: " "$DEFAULT_BACKUP_DIR"
    read -r BACKUP_DIR || true
    BACKUP_DIR="${BACKUP_DIR:-$DEFAULT_BACKUP_DIR}"

    printf "Google Analytics Property ID (opcjonalny, Enter = pomin): "
    read -r GA_PROPERTY_ID || true

    printf "Google Verification Code (opcjonalny, Enter = pomin): "
    read -r GA_VERIFICATION_CODE || true

    RMQ_PASS="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
    RMQ_COOKIE="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
    SECRET_KEY="$(openssl rand -base64 48 | head -c 50)"

    if [ "$BPP_EXTERNAL_DB" = "yes" ]; then
        echo "=== Konfiguracja zewnetrznej bazy PostgreSQL ==="
        printf "Hostname zewnetrznego serwera PostgreSQL: "
        read -r EXT_DB_HOST || true
        printf "Port [5432]: "
        read -r EXT_DB_PORT || true
        EXT_DB_PORT="${EXT_DB_PORT:-5432}"
        printf "Nazwa bazy danych [bpp]: "
        read -r EXT_DB_NAME || true
        EXT_DB_NAME="${EXT_DB_NAME:-bpp}"
        printf "Uzytkownik bazy [bpp]: "
        read -r EXT_DB_USER || true
        EXT_DB_USER="${EXT_DB_USER:-bpp}"
        printf "Haslo uzytkownika bazy: "
        read -r EXT_DB_PASS || true

        DB_NAME="$EXT_DB_NAME"
        DB_USER="$EXT_DB_USER"
        DB_PASS="$EXT_DB_PASS"
        DB_HOST="$EXT_DB_HOST"
        DB_PORT="$EXT_DB_PORT"

        echo ""
        echo "Probuje wykryc wersje PostgreSQL na $DB_HOST:$DB_PORT..."
        if DETECTED_PG_MAJOR="$("$REPO_DIR/scripts/detect-postgres-version.sh" \
                "$DB_HOST" "$DB_PORT" "$DB_USER" "$DB_PASS" "$DB_NAME" 2>/dev/null)" \
                && [ -n "$DETECTED_PG_MAJOR" ]; then
            echo "Wykryto PostgreSQL major $DETECTED_PG_MAJOR"
            EXT_PG_VERSION="$DETECTED_PG_MAJOR"
        else
            echo "UWAGA: nie udalo sie wykryc wersji (brak polaczenia, bledna auth lub firewall)."
            printf "Podaj wersje major PostgreSQL recznie [17]: "
            read -r EXT_PG_VERSION || true
            EXT_PG_VERSION="${EXT_PG_VERSION:-17}"
        fi
        echo ""
    else
        DB_PASS="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
        DB_NAME="bpp"
        DB_USER="postgres"
        DB_HOST="dbserver"
        DB_PORT="5432"

        echo ""
        echo "=== Wersja PostgreSQL dla dbserver ==="
        echo "Kontener dbserver uzywa obrazu iplweb/bpp_dbserver:psql-<wersja>."
        echo "Dostepne tagi: https://hub.docker.com/r/iplweb/bpp_dbserver/tags"
        echo "Przyklady: 16.13, 17.9, 18.3 (zalecany format MAJOR.MINOR)."
        printf "Wersja PostgreSQL [16.13]: "
        read -r DBSERVER_PG_VERSION || true
        DBSERVER_PG_VERSION="${DBSERVER_PG_VERSION:-16.13}"
        # Wyciagnij major (16.13 -> 16) jako domyslny dla backup-runnera,
        # zeby out-of-the-box pg_dump byl tej samej wersji co serwer.
        DBSERVER_PG_MAJOR="${DBSERVER_PG_VERSION%%.*}"

        printf "Major version PostgreSQL dla backup-runner (pg_dump, >= wersji dbservera) [%s]: " "$DBSERVER_PG_MAJOR"
        read -r EXT_PG_VERSION || true
        EXT_PG_VERSION="${EXT_PG_VERSION:-$DBSERVER_PG_MAJOR}"
    fi

    cat > "$ENV_FILE" <<EOF
# BPP Application Configuration
# BPP Deploy $(git describe --tags --abbrev=0 2>/dev/null || echo "dev")
# Wygenerowano automatycznie przez make init-configs: $(date '+%Y-%m-%d %H:%M:%S')
# Ten plik mozna edytowac recznie -- nie zostanie nadpisany
# przy ponownym uruchomieniu init-configs.

# === Baza danych ===
DJANGO_BPP_DB_NAME=$DB_NAME
DJANGO_BPP_DB_USER=$DB_USER
DJANGO_BPP_DB_PASSWORD=$DB_PASS
DJANGO_BPP_DB_HOST=$DB_HOST
DJANGO_BPP_DB_PORT=$DB_PORT

# === Redis ===
DJANGO_BPP_REDIS_HOST=redis

# === RabbitMQ ===
DJANGO_BPP_RABBITMQ_HOST=rabbitmq
DJANGO_BPP_RABBITMQ_USER=bpp
DJANGO_BPP_RABBITMQ_PASS=$RMQ_PASS
DJANGO_BPP_RABBITMQ_PORT=5672
RABBITMQ_ERLANG_COOKIE=$RMQ_COOKIE

# === Aplikacja ===
DJANGO_BPP_HOSTNAME=$BPP_HOSTNAME
DOCKER_VERSION=latest
DJANGO_BPP_CSRF_EXTRA_ORIGINS=https://$BPP_HOSTNAME
STATIC_ROOT=/staticroot/
DJANGO_SETTINGS_MODULE=django_bpp.settings.production

# === Google (opcjonalne) ===
DJANGO_BPP_GOOGLE_ANALYTICS_PROPERTY_ID=$GA_PROPERTY_ID
DJANGO_BPP_GOOGLE_VERIFICATION_CODE=$GA_VERIFICATION_CODE

# === Bezpieczenstwo ===
DJANGO_BPP_SECRET_KEY=$SECRET_KEY

# === Administrator ===
DJANGO_BPP_ADMIN_USERNAME=$ADMIN_USERNAME
DJANGO_BPP_ADMIN_EMAIL=$ADMIN_EMAIL
ADMINS=$ADMIN_USERNAME <$ADMIN_EMAIL>

# === Powiadomienia (opcjonalne) ===
DJANGO_BPP_SLACK_WEBHOOK=$SLACK_WEBHOOK

# === Backupy ===
DJANGO_BPP_HOST_BACKUP_DIR=$BACKUP_DIR
DJANGO_BPP_BACKUP_KEEP_LAST=7
DJANGO_BPP_RCLONE_REMOTE=backup_enc:

# === Rollbar (opcjonalne, dla notyfikacji backup-cycle) ===
# Gdy puste, backup-cycle.sh pomija powiadomienia. Uzyj tokena typu
# "post_server_item" z https://rollbar.com/<project>/settings/access_tokens/
ROLLBAR_ACCESS_TOKEN=

# === Docker logging (driver "local", binarny, skompresowany zstd) ===
# Rotacja na poziomie hosta. Czasowa retencja zyje w Loki
# (\$BPP_CONFIGS_DIR/loki/local-config.yaml). Te wartosci sa tylko buforem,
# zeby lokalne logi kontenera nie zapelnily dysku zanim Alloy zdazy je wyslac.
# LOG_MAX_SIZE * LOG_MAX_FILE = maksymalny rozmiar logow per kontener.
LOG_MAX_SIZE=150m
LOG_MAX_FILE=5
EOF

    if [ -n "$EXT_PG_VERSION" ]; then
        cat >> "$ENV_FILE" <<EOF

# === Wersja PostgreSQL ===
# W trybie external VERSION i VERSION_MAJOR sa rowne - sentinel i backup-runner
# potrzebuja tylko majora (postgres:<major>-alpine). Zmienne istnieja osobno
# dla spojnosci z trybem lokalnym (gdzie VERSION jest MAJOR.MINOR).
DJANGO_BPP_POSTGRESQL_VERSION=$EXT_PG_VERSION
DJANGO_BPP_POSTGRESQL_VERSION_MAJOR=$EXT_PG_VERSION
EOF
    fi

    # Zmienne wersji dla trybu lokalnego:
    #   DJANGO_BPP_POSTGRESQL_VERSION       - pelny MAJOR.MINOR, tag iplweb/bpp_dbserver:psql-<ver>
    #   DJANGO_BPP_POSTGRESQL_VERSION_MAJOR - derived major, dla backup-runnera (postgres:<major>-alpine)
    # Upgrade majora: `make upgrade-postgres` (logical dump & restore z zachowaniem
    # starego volume jako kopii zapasowej).
    if [ "$BPP_EXTERNAL_DB" != "yes" ] && [ -n "${DBSERVER_PG_VERSION:-}" ]; then
        _dbserver_major="${DBSERVER_PG_VERSION%%.*}"
        cat >> "$ENV_FILE" <<EOF

# === Wersja PostgreSQL ===
# DJANGO_BPP_POSTGRESQL_VERSION - pelny tag dbservera (iplweb/bpp_dbserver:psql-<ver>).
# Nie zmieniaj recznie dla upgrade'u majora - uzyj 'make upgrade-postgres'
# (dump & restore). Minor update (np. 16.13 -> 16.14) mozna zrobic recznie.
DJANGO_BPP_POSTGRESQL_VERSION=$DBSERVER_PG_VERSION
# Auto-derived major (pg_dump backup-runnera musi byc >= wersji serwera).
DJANGO_BPP_POSTGRESQL_VERSION_MAJOR=$_dbserver_major
EOF
    fi

    echo "Wygenerowano $ENV_FILE z losowymi haslami."

else
    # --- Istniejący plik: uzupełnij brakujące zmienne ---

    echo "$ENV_FILE juz istnieje. Sprawdzam brakujace zmienne..."
    echo ""

    DEFAULT_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
    DEFAULT_BACKUP_DIR="$(dirname "$ABS_CONFIG")/backups"

    # W trybie zewnetrznej bazy - zapytaj o parametry polaczenia i nadpisz je
    # w .env (nawet jesli juz byly ustawione na stare wartosci typu "dbserver").
    if [ "$BPP_EXTERNAL_DB" = "yes" ]; then
        _cur_host="$(get_env_var DJANGO_BPP_DB_HOST)"
        _cur_port="$(get_env_var DJANGO_BPP_DB_PORT)"
        _cur_name="$(get_env_var DJANGO_BPP_DB_NAME)"
        _cur_user="$(get_env_var DJANGO_BPP_DB_USER)"
        _cur_pass="$(get_env_var DJANGO_BPP_DB_PASSWORD)"

        # Jesli host wskazuje na lokalny kontener - to poprzednio byla baza
        # wewnetrzna; nie podpowiadaj "dbserver" jako defaultu.
        if [ -z "$_cur_host" ] || [ "$_cur_host" = "dbserver" ]; then
            _cur_host=""
        fi
        if [ -z "$_cur_user" ] || [ "$_cur_user" = "postgres" ]; then
            _cur_user="bpp"
        fi
        if [ -z "$_cur_name" ]; then
            _cur_name="bpp"
        fi
        if [ -z "$_cur_port" ]; then
            _cur_port="5432"
        fi

        echo "=== Konfiguracja zewnetrznej bazy PostgreSQL ==="
        EXT_DB_HOST_INPUT=""
        while [ -z "$EXT_DB_HOST_INPUT" ]; do
            printf "Hostname zewnetrznego serwera PostgreSQL%s: " \
                "${_cur_host:+ [$_cur_host]}"
            read -r EXT_DB_HOST_INPUT || true
            EXT_DB_HOST_INPUT="${EXT_DB_HOST_INPUT:-$_cur_host}"
            if [ -z "$EXT_DB_HOST_INPUT" ]; then
                echo "  Hostname jest wymagany."
            fi
        done
        printf "Port [%s]: " "$_cur_port"
        read -r EXT_DB_PORT_INPUT || true
        EXT_DB_PORT_INPUT="${EXT_DB_PORT_INPUT:-$_cur_port}"
        printf "Nazwa bazy danych [%s]: " "$_cur_name"
        read -r EXT_DB_NAME_INPUT || true
        EXT_DB_NAME_INPUT="${EXT_DB_NAME_INPUT:-$_cur_name}"
        printf "Uzytkownik bazy [%s]: " "$_cur_user"
        read -r EXT_DB_USER_INPUT || true
        EXT_DB_USER_INPUT="${EXT_DB_USER_INPUT:-$_cur_user}"
        printf "Haslo uzytkownika bazy%s: " \
            "${_cur_pass:+ [pozostaw puste aby zachowac obecne]}"
        read -r EXT_DB_PASS_INPUT || true
        EXT_DB_PASS_INPUT="${EXT_DB_PASS_INPUT:-$_cur_pass}"
        echo ""

        set_env_var "DJANGO_BPP_DB_HOST" "$EXT_DB_HOST_INPUT" "Zewnetrzna baza danych"
        set_env_var "DJANGO_BPP_DB_PORT" "$EXT_DB_PORT_INPUT" "Zewnetrzna baza danych"
        set_env_var "DJANGO_BPP_DB_NAME" "$EXT_DB_NAME_INPUT" "Zewnetrzna baza danych"
        set_env_var "DJANGO_BPP_DB_USER" "$EXT_DB_USER_INPUT" "Zewnetrzna baza danych"
        set_env_var "DJANGO_BPP_DB_PASSWORD" "$EXT_DB_PASS_INPUT" "Zewnetrzna baza danych"
    fi

    ensure_env_var "DJANGO_BPP_DB_NAME" "bpp" "" "Baza danych"
    ensure_env_var "DJANGO_BPP_DB_USER" "postgres" "" "Baza danych"
    ensure_env_var "DJANGO_BPP_DB_PASSWORD" \
        "$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)" "" "Baza danych"
    ensure_env_var "DJANGO_BPP_DB_HOST" "dbserver" "" "Baza danych"
    ensure_env_var "DJANGO_BPP_DB_PORT" "5432" "" "Baza danych"

    ensure_env_var "DJANGO_BPP_REDIS_HOST" "redis" "" "Redis"

    ensure_env_var "DJANGO_BPP_RABBITMQ_HOST" "rabbitmq" "" "RabbitMQ"
    ensure_env_var "DJANGO_BPP_RABBITMQ_USER" "bpp" "" "RabbitMQ"
    ensure_env_var "DJANGO_BPP_RABBITMQ_PASS" \
        "$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)" "" "RabbitMQ"
    ensure_env_var "DJANGO_BPP_RABBITMQ_PORT" "5672" "" "RabbitMQ"
    ensure_env_var "RABBITMQ_ERLANG_COOKIE" \
        "$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)" "" "RabbitMQ"

    ensure_env_var "DJANGO_BPP_HOSTNAME" "$DEFAULT_HOSTNAME" \
        "Podaj nazwe hosta dla aplikacji" "Aplikacja"
    ensure_env_var "DOCKER_VERSION" "latest" "" "Aplikacja"
    ensure_env_var "DJANGO_BPP_CSRF_EXTRA_ORIGINS" "https://$DEFAULT_HOSTNAME" "" "Aplikacja"
    ensure_env_var "STATIC_ROOT" "/staticroot/" "" "Pliki statyczne"
    ensure_env_var "DJANGO_SETTINGS_MODULE" \
        "django_bpp.settings.production" "" "Django settings"
    ensure_env_var "DJANGO_BPP_GOOGLE_ANALYTICS_PROPERTY_ID" "" \
        "Google Analytics Property ID (opcjonalny, Enter = pomin)" \
        "Google Analytics (opcjonalne)"
    ensure_env_var "DJANGO_BPP_GOOGLE_VERIFICATION_CODE" "" \
        "Google Verification Code (opcjonalny, Enter = pomin)" \
        "Google Verification (opcjonalne)"

    ensure_env_var "DJANGO_BPP_SECRET_KEY" \
        "$(openssl rand -base64 48 | head -c 50)" "" "Bezpieczenstwo"

    ensure_env_var "DJANGO_BPP_ADMIN_USERNAME" "admin" \
        "Nazwa uzytkownika administratora" "Administrator"
    ensure_env_var "DJANGO_BPP_ADMIN_EMAIL" "admin@example.com" \
        "Email administratora" "Administrator"

    # ADMINS wymaga username + email — budujemy z istniejących wartości
    if ! env_has_var "ADMINS"; then
        # Odczytaj wartości które właśnie dopisaliśmy lub były wcześniej
        _username=$(grep "^DJANGO_BPP_ADMIN_USERNAME=" "$ENV_FILE" | head -1 | cut -d= -f2-)
        _email=$(grep "^DJANGO_BPP_ADMIN_EMAIL=" "$ENV_FILE" | head -1 | cut -d= -f2-)
        ensure_env_var "ADMINS" "$_username <$_email>" "" "Administrator (format Django)"
    fi

    ensure_env_var "DJANGO_BPP_SLACK_WEBHOOK" "" \
        "Slack webhook URL (opcjonalny, Enter = pomin)" "Powiadomienia (opcjonalne)"
    # Migracja: stara nazwa zmiennej DJANGO_BPP_BACKUP_DIR -> nowa
    # DJANGO_BPP_HOST_BACKUP_DIR (dodana gdy dbserver dostal bind-mount
    # /backup, zeby nazwa podkreslala ze to katalog na hoscie).
    if env_has_var "DJANGO_BPP_BACKUP_DIR" && ! env_has_var "DJANGO_BPP_HOST_BACKUP_DIR"; then
        _old_backup_dir="$(get_env_var DJANGO_BPP_BACKUP_DIR)"
        awk '!/^DJANGO_BPP_BACKUP_DIR=/ && !/^# Dopisano automatycznie.*DJANGO_BPP_BACKUP_DIR/' "$ENV_FILE" > "$ENV_FILE.tmp.$$" \
            && mv "$ENV_FILE.tmp.$$" "$ENV_FILE"
        set_env_var "DJANGO_BPP_HOST_BACKUP_DIR" "$_old_backup_dir" \
            "Backupy (migracja z DJANGO_BPP_BACKUP_DIR)"
        echo "  ~ zmigrowalem DJANGO_BPP_BACKUP_DIR -> DJANGO_BPP_HOST_BACKUP_DIR"
    fi

    ensure_env_var "DJANGO_BPP_HOST_BACKUP_DIR" "$DEFAULT_BACKUP_DIR" \
        "Katalog backupow na hoscie" "Backupy"
    ensure_env_var "DJANGO_BPP_BACKUP_KEEP_LAST" "7" \
        "" "Backupy - ile ostatnich kopii kazdego typu trzymac lokalnie"
    ensure_env_var "DJANGO_BPP_RCLONE_REMOTE" "backup_enc:" \
        "" "Backupy - rclone remote (np. backup_enc:)"
    ensure_env_var "ROLLBAR_ACCESS_TOKEN" "" \
        "Rollbar access token (post_server_item, opcjonalny, Enter = pomin)" \
        "Rollbar (notyfikacje backup-cycle)"

    ensure_env_var "LOG_MAX_SIZE" "150m" "" \
        "Docker log rotation - rozmiar jednego pliku (log driver=local, zstd)"
    ensure_env_var "LOG_MAX_FILE" "5" "" \
        "Docker log rotation - liczba trzymanych plikow per kontener"

    # Migracja: DJANGO_BPP_EXTERNAL_POSTGRESQL_DB_VERSION -> DJANGO_BPP_POSTGRESQL_DB_VERSION.
    # (Historyczny rename - zmienna dotyczyla tylko external, po rozszerzeniu na
    # backup-runner przedrostek EXTERNAL zniknal. Zachowane dla bardzo starych .envow.)
    if env_has_var "DJANGO_BPP_EXTERNAL_POSTGRESQL_DB_VERSION" && ! env_has_var "DJANGO_BPP_POSTGRESQL_DB_VERSION"; then
        _old_pg_ver="$(get_env_var DJANGO_BPP_EXTERNAL_POSTGRESQL_DB_VERSION)"
        awk '!/^DJANGO_BPP_EXTERNAL_POSTGRESQL_DB_VERSION=/ && !/^# Dopisano automatycznie.*DJANGO_BPP_EXTERNAL_POSTGRESQL_DB_VERSION/' "$ENV_FILE" > "$ENV_FILE.tmp.$$" \
            && mv "$ENV_FILE.tmp.$$" "$ENV_FILE"
        set_env_var "DJANGO_BPP_POSTGRESQL_DB_VERSION" "$_old_pg_ver" \
            "Wersja PostgreSQL (migracja z DJANGO_BPP_EXTERNAL_POSTGRESQL_DB_VERSION)"
        echo "  ~ zmigrowalem DJANGO_BPP_EXTERNAL_POSTGRESQL_DB_VERSION -> DJANGO_BPP_POSTGRESQL_DB_VERSION"
    fi

    # Migracja 2026-04-18: konsolidacja nazw wersji PostgreSQL.
    #   DJANGO_BPP_DBSERVER_PG_VERSION     -> DJANGO_BPP_POSTGRESQL_VERSION
    #   DJANGO_BPP_POSTGRESQL_DB_VERSION   -> DJANGO_BPP_POSTGRESQL_VERSION_MAJOR
    # VERSION jest source of truth (MAJOR.MINOR lokalnie, MAJOR w external),
    # VERSION_MAJOR jest auto-derived i uzywane przez backup-runner/sentinel.
    if env_has_var "DJANGO_BPP_DBSERVER_PG_VERSION" && ! env_has_var "DJANGO_BPP_POSTGRESQL_VERSION"; then
        _old_ver="$(get_env_var DJANGO_BPP_DBSERVER_PG_VERSION)"
        awk '!/^DJANGO_BPP_DBSERVER_PG_VERSION=/ && !/^# Dopisano automatycznie.*DJANGO_BPP_DBSERVER_PG_VERSION/ && !/^# === Wersja obrazu dbserver ===/ && !/^# Tag iplweb.bpp_dbserver:psql.*MAJOR.MINOR/ && !/^# upgrade.u majora - uzyj .make upgrade-postgres/' \
            "$ENV_FILE" > "$ENV_FILE.tmp.$$" \
            && mv "$ENV_FILE.tmp.$$" "$ENV_FILE"
        set_env_var "DJANGO_BPP_POSTGRESQL_VERSION" "$_old_ver" \
            "Pelna wersja PostgreSQL (MAJOR.MINOR lokalnie, MAJOR w external) - migracja z DJANGO_BPP_DBSERVER_PG_VERSION"
        echo "  ~ zmigrowalem DJANGO_BPP_DBSERVER_PG_VERSION -> DJANGO_BPP_POSTGRESQL_VERSION"
    fi

    if env_has_var "DJANGO_BPP_POSTGRESQL_DB_VERSION" && ! env_has_var "DJANGO_BPP_POSTGRESQL_VERSION_MAJOR"; then
        _old_ver="$(get_env_var DJANGO_BPP_POSTGRESQL_DB_VERSION)"
        awk '!/^DJANGO_BPP_POSTGRESQL_DB_VERSION=/ && !/^# Dopisano automatycznie.*DJANGO_BPP_POSTGRESQL_DB_VERSION/ && !/^# === Wersja PostgreSQL ===/ && !/^# Wspolna dla sentinela/ && !/^# oraz dla backup-runner/ && !/^# musi byc >= wersji serwera/' \
            "$ENV_FILE" > "$ENV_FILE.tmp.$$" \
            && mv "$ENV_FILE.tmp.$$" "$ENV_FILE"
        set_env_var "DJANGO_BPP_POSTGRESQL_VERSION_MAJOR" "$_old_ver" \
            "Major wersja PostgreSQL (derived z DJANGO_BPP_POSTGRESQL_VERSION) - migracja z DJANGO_BPP_POSTGRESQL_DB_VERSION"
        echo "  ~ zmigrowalem DJANGO_BPP_POSTGRESQL_DB_VERSION -> DJANGO_BPP_POSTGRESQL_VERSION_MAJOR"
    fi

    # Derivacja brakujacej polowki pary VERSION/VERSION_MAJOR. Happy-path:
    #   - local fresh: generate sekcja dala obie
    #   - external fresh: generate sekcja dala obie
    #   - post-migracja z DBSERVER_PG_VERSION tylko: derive _MAJOR z _VERSION
    #   - post-migracja z POSTGRESQL_DB_VERSION tylko (stary external .env ktory
    #     nigdy nie mial DBSERVER_PG_VERSION): derive _VERSION z _MAJOR
    if env_has_var "DJANGO_BPP_POSTGRESQL_VERSION" && ! env_has_var "DJANGO_BPP_POSTGRESQL_VERSION_MAJOR"; then
        _val="$(get_env_var DJANGO_BPP_POSTGRESQL_VERSION)"
        set_env_var "DJANGO_BPP_POSTGRESQL_VERSION_MAJOR" "${_val%%.*}" \
            "Major wersja PostgreSQL (derived z DJANGO_BPP_POSTGRESQL_VERSION)"
        echo "  + derive DJANGO_BPP_POSTGRESQL_VERSION_MAJOR=${_val%%.*} z DJANGO_BPP_POSTGRESQL_VERSION"
    fi
    if env_has_var "DJANGO_BPP_POSTGRESQL_VERSION_MAJOR" && ! env_has_var "DJANGO_BPP_POSTGRESQL_VERSION"; then
        _val="$(get_env_var DJANGO_BPP_POSTGRESQL_VERSION_MAJOR)"
        set_env_var "DJANGO_BPP_POSTGRESQL_VERSION" "$_val" \
            "Pelna wersja PostgreSQL (MAJOR.MINOR lokalnie, MAJOR w external)"
        echo "  + derive DJANGO_BPP_POSTGRESQL_VERSION=$_val z DJANGO_BPP_POSTGRESQL_VERSION_MAJOR"
    fi

    # W trybie zewnetrznej bazy - upewnij sie ze major version sentinela jest ustawiony.
    if [ "$BPP_EXTERNAL_DB" = "yes" ] && ! env_has_var "DJANGO_BPP_POSTGRESQL_VERSION_MAJOR"; then
        _db_host="$(get_env_var DJANGO_BPP_DB_HOST)"
        _db_port="$(get_env_var DJANGO_BPP_DB_PORT)"
        _db_user="$(get_env_var DJANGO_BPP_DB_USER)"
        _db_pass="$(get_env_var DJANGO_BPP_DB_PASSWORD)"
        _db_name="$(get_env_var DJANGO_BPP_DB_NAME)"

        echo ""
        echo "Probuje wykryc wersje zewnetrznej bazy PostgreSQL na $_db_host:$_db_port..."
        if DETECTED_PG_MAJOR="$("$REPO_DIR/scripts/detect-postgres-version.sh" \
                "$_db_host" "$_db_port" "$_db_user" "$_db_pass" "$_db_name" 2>/dev/null)" \
                && [ -n "$DETECTED_PG_MAJOR" ]; then
            echo "Wykryto PostgreSQL major $DETECTED_PG_MAJOR"
            ensure_env_var "DJANGO_BPP_POSTGRESQL_VERSION" "$DETECTED_PG_MAJOR" \
                "" "Zewnetrzna baza danych"
            ensure_env_var "DJANGO_BPP_POSTGRESQL_VERSION_MAJOR" "$DETECTED_PG_MAJOR" \
                "" "Zewnetrzna baza danych"
        else
            echo "UWAGA: nie udalo sie wykryc wersji."
            ensure_env_var "DJANGO_BPP_POSTGRESQL_VERSION" "17" \
                "Wersja major zewnetrznego PostgreSQL (np. 17, 16, 15)" \
                "Zewnetrzna baza danych"
            _ext_ver="$(get_env_var DJANGO_BPP_POSTGRESQL_VERSION)"
            ensure_env_var "DJANGO_BPP_POSTGRESQL_VERSION_MAJOR" "${_ext_ver:-17}" \
                "" "Zewnetrzna baza danych"
        fi
    fi

    # W trybie lokalnej bazy - zapytaj o wersje dbservera i backup-runnera.
    if [ "$BPP_EXTERNAL_DB" != "yes" ]; then
        # Tag iplweb/bpp_dbserver:psql-<MAJOR.MINOR>. Default 16.13 to ostatnio
        # znana dobra wersja - dla starych deploymentow po `git pull` daje
        # zgodnosc bit-in-bit z poprzednim hardcoded tagem z docker-compose.
        ensure_env_var "DJANGO_BPP_POSTGRESQL_VERSION" "16.13" \
            "Wersja dbservera (iplweb/bpp_dbserver:psql-<ver>, np. 16.13, 17.9, 18.3)" \
            "Wersja PostgreSQL - upgrade majora przez 'make upgrade-postgres'"

        # Default dla backup-runnera = major z dbservera (16.13 -> 16) tylko
        # gdy zmienna jeszcze nie istnieje. Zachowujemy istniejaca wartosc
        # jesli uzytkownik mial np. backup-runner na 17 a dbserver na 16 (to
        # jest OK bo pg_dump 17 umie dumpowac baze 16).
        _dbserver_ver="$(get_env_var DJANGO_BPP_POSTGRESQL_VERSION)"
        _backup_runner_default="${_dbserver_ver%%.*}"
        ensure_env_var "DJANGO_BPP_POSTGRESQL_VERSION_MAJOR" "${_backup_runner_default:-16}" \
            "Major version lokalnego PostgreSQL (dla backup-runner, >= wersji dbservera)" \
            "Wersja PostgreSQL - auto-derived z DJANGO_BPP_POSTGRESQL_VERSION"
    fi

    echo ""
    echo "Sprawdzanie zakonczone."
fi

# --- 8. Generowanie certyfikatów snakeoil (opcjonalne) ---

if [ ! -f "$ABS_CONFIG/ssl/key.pem" ] || [ ! -f "$ABS_CONFIG/ssl/cert.pem" ]; then
    echo ""
    echo "Brak certyfikatow SSL w $ABS_CONFIG/ssl/"
    printf "Wygenerowac samopodpisane certyfikaty (snakeoil)? [t/N]: "
    read -r GEN_SNAKEOIL || true
    if [ "$GEN_SNAKEOIL" = "t" ] || [ "$GEN_SNAKEOIL" = "T" ] || [ "$GEN_SNAKEOIL" = "y" ] || [ "$GEN_SNAKEOIL" = "Y" ]; then
        # Odczytaj hostname z .env
        SSL_HOSTNAME=$(grep "^DJANGO_BPP_HOSTNAME=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
        SSL_HOSTNAME="${SSL_HOSTNAME:-localhost}"
        echo "Generowanie certyfikatow dla: $SSL_HOSTNAME"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$ABS_CONFIG/ssl/key.pem" \
            -out "$ABS_CONFIG/ssl/cert.pem" \
            -subj "/CN=$SSL_HOSTNAME" \
            -addext "subjectAltName=DNS:$SSL_HOSTNAME" 2>/dev/null
        echo "  Wygenerowano certyfikaty snakeoil SSL."
        echo "  Wazne 365 dni. Mozna pozniej zamienic na wlasciwe certyfikaty."
    fi
fi

# --- 8b. Local overrides (macOS) ---

OVERRIDES_FILE="$REPO_DIR/docker-compose.local_overrides.yml"
if [ ! -f "$OVERRIDES_FILE" ]; then
    if [ "$(uname -s)" = "Darwin" ]; then
        cp "$CONFIG_DEFAULTS_DIR/docker-compose.local_overrides.yml" "$OVERRIDES_FILE"
        echo "  Utworzono docker-compose.local_overrides.yml (macOS — node-exporter wylaczony)"
    else
        # Linux: pusty override, wymagany przez docker-compose.yml include
        echo "# Linux — no overrides needed" > "$OVERRIDES_FILE"
        echo "  Utworzono docker-compose.local_overrides.yml (Linux — pusty)"
    fi
fi

# --- 9. Komunikat końcowy ---

echo ""
echo "=== Gotowe ==="
echo ""
echo "Teraz edytuj pliki w $ABS_CONFIG:"
echo "  1. .env           - sprawdz ustawienia i hasla"
if [ ! -f "$ABS_CONFIG/ssl/key.pem" ] || [ ! -f "$ABS_CONFIG/ssl/cert.pem" ]; then
    echo "  2. ssl/           - dodaj key.pem i cert.pem"
else
    echo "  2. ssl/           - certyfikaty SSL (juz istnieja)"
fi
echo ""
echo "Potem uruchom 'docker compose up -d' aby uruchomic stack."

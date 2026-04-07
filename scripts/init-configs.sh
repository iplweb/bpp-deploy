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

# Absolutna ścieżka
ABS_CONFIG="$(cd "$INPUT_DIR" 2>/dev/null && pwd || echo "$INPUT_DIR")"

# Walidacja: nie wewnątrz repozytorium
case "$ABS_CONFIG" in
    "$REPO_DIR"*)
        echo "BLAD: Katalog konfiguracyjny nie moze byc wewnatrz repozytorium!"
        exit 1
        ;;
esac

# --- 3. Zapisz do .env w repo ---

PROJECT_NAME="$(basename "$ABS_CONFIG")"
echo "BPP_CONFIGS_DIR=$ABS_CONFIG" > "$REPO_DIR/.env"
echo "COMPOSE_PROJECT_NAME=$PROJECT_NAME" >> "$REPO_DIR/.env"
echo "Zapisano BPP_CONFIGS_DIR=$ABS_CONFIG, COMPOSE_PROJECT_NAME=$PROJECT_NAME w .env"
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

    DB_PASS="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
    RMQ_PASS="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
    RMQ_COOKIE="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
    SECRET_KEY="$(openssl rand -base64 48 | head -c 50)"

    cat > "$ENV_FILE" <<EOF
# BPP Application Configuration
# Wygenerowano automatycznie przez make init-configs: $(date '+%Y-%m-%d %H:%M:%S')
# Ten plik mozna edytowac recznie -- nie zostanie nadpisany
# przy ponownym uruchomieniu init-configs.

# === Baza danych ===
DJANGO_BPP_DB_NAME=bpp
DJANGO_BPP_DB_USER=postgres
DJANGO_BPP_DB_PASSWORD=$DB_PASS
DJANGO_BPP_DB_HOST=dbserver
DJANGO_BPP_DB_PORT=5432

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
DJANGO_BPP_BACKUP_DIR=$BACKUP_DIR
EOF
    echo "Wygenerowano $ENV_FILE z losowymi haslami."

else
    # --- Istniejący plik: uzupełnij brakujące zmienne ---

    echo "$ENV_FILE juz istnieje. Sprawdzam brakujace zmienne..."
    echo ""

    DEFAULT_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
    DEFAULT_BACKUP_DIR="$(dirname "$ABS_CONFIG")/backups"

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
    ensure_env_var "DJANGO_BPP_BACKUP_DIR" "$DEFAULT_BACKUP_DIR" \
        "Katalog backupow" "Backupy"

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

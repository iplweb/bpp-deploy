#!/usr/bin/env bash
#
# Konfiguracja limitow zasobow (RAM + CPU) dla serwisow BPP w Dockerze.
#
# Skrypt wykrywa rozmiar hosta, proponuje rozsadne defaulty (30% dla dbserver,
# 15% dla Django/workerow itd.), pyta uzytkownika po kolei i zapisuje wynik
# do $BPP_CONFIGS_DIR/.env jako zmienne <SERVICE>_MEM_LIMIT i
# <SERVICE>_CPU_LIMIT. Compose'y interpretuja te zmienne w sekcji
# deploy.resources.limits.
#
# Uruchamianie: make configure-resources (lub bezposrednio skrypt).
# Nie modyfikuje hosta, nie instaluje nic. Jedyny write: $BPP_CONFIGS_DIR/.env.

set -euo pipefail

# --- Wykrywanie parametrow hosta ---

case "$(uname -s)" in
    Linux)
        TOTAL_RAM_KB=$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo)
        TOTAL_RAM_GB=$(( TOTAL_RAM_KB / 1024 / 1024 ))
        CPU_COUNT=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)
        ;;
    Darwin)
        TOTAL_RAM_BYTES=$(sysctl -n hw.memsize)
        TOTAL_RAM_GB=$(( TOTAL_RAM_BYTES / 1024 / 1024 / 1024 ))
        CPU_COUNT=$(sysctl -n hw.ncpu)
        ;;
    *)
        echo "Blad: nieobslugiwany system operacyjny: $(uname -s)" >&2
        exit 1
        ;;
esac

echo ""
echo "================================================================"
echo "  Konfiguracja limitow zasobow Docker dla BPP"
echo "================================================================"
echo ""
echo "Pracujesz na serwerze z ${TOTAL_RAM_GB} GB RAM i ${CPU_COUNT} rdzeni CPU."
echo ""

if [ "$TOTAL_RAM_GB" -lt 6 ]; then
    echo "UWAGA: host ma mniej niz 6 GB RAM - limity moga byc zbyt ciasne"
    echo "       zeby pomiescic caly stack z komfortowa rezerwa."
    echo ""
fi

# --- Lokalizacja $BPP_CONFIGS_DIR/.env ---

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$REPO_DIR/.env" ]; then
    # shellcheck disable=SC1091
    . "$REPO_DIR/.env"
fi
if [ -z "${BPP_CONFIGS_DIR:-}" ]; then
    echo "Blad: BPP_CONFIGS_DIR nie jest ustawione w $REPO_DIR/.env." >&2
    echo "Uruchom najpierw 'make init-configs'." >&2
    exit 1
fi
ENV_FILE="$BPP_CONFIGS_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "Blad: brak $ENV_FILE. Uruchom najpierw 'make init-configs'." >&2
    exit 1
fi

# --- Budzet: rezerwa dla OS + malych daemonow ---

RESERVE_GB=2
if [ "$TOTAL_RAM_GB" -le 4 ]; then
    RESERVE_GB=1
fi
BUDGET_GB=$(( TOTAL_RAM_GB - RESERVE_GB ))
if [ "$BUDGET_GB" -lt 4 ]; then
    BUDGET_GB=4
fi
BUDGET_MB=$(( BUDGET_GB * 1024 ))

# --- Obliczanie defaultow pamieci (procentowo z budzetu) ---

mem_pct() {
    local pct="$1"
    echo "$(( BUDGET_MB * pct / 100 ))m"
}

DEFAULT_DBSERVER_MEM=$(mem_pct 30)
DEFAULT_APPSERVER_MEM=$(mem_pct 15)
DEFAULT_WORKER_GENERAL_MEM=$(mem_pct 15)
DEFAULT_WORKER_DENORM_MEM=$(mem_pct 15)
DEFAULT_RABBITMQ_MEM=$(mem_pct 8)
DEFAULT_REDIS_MEM=$(mem_pct 5)
DEFAULT_LOKI_MEM=$(mem_pct 5)
DEFAULT_PROMETHEUS_MEM=$(mem_pct 7)

# --- Obliczanie defaultow CPU (ulamek z CPU_COUNT) ---

cpu_frac() {
    local div="$1" min="$2"
    # LC_ALL=C wymusza kropke jako separator dziesietny (inaczej w polskim
    # locale awk zwraca "4,0" zamiast "4.0" i Docker odrzuca wartosc).
    LC_ALL=C awk -v c="$CPU_COUNT" -v d="$div" -v m="$min" \
        'BEGIN { v = c/d; if (v < m) v = m; printf "%.1f\n", v }'
}

DEFAULT_DBSERVER_CPU=$(cpu_frac 4 2.0)
DEFAULT_APPSERVER_CPU=$(cpu_frac 4 2.0)
DEFAULT_WORKER_GENERAL_CPU=$(cpu_frac 4 2.0)
DEFAULT_WORKER_DENORM_CPU=$(cpu_frac 8 1.0)
DEFAULT_RABBITMQ_CPU=$(cpu_frac 16 1.0)
DEFAULT_REDIS_CPU="0.5"
DEFAULT_LOKI_CPU="0.5"
DEFAULT_PROMETHEUS_CPU=$(cpu_frac 16 1.0)

# --- Helpery IO ---

ask() {
    local label="$1" default="$2" answer=""
    # Prompt idzie na stderr, zeby $(ask ...) lapalo tylko wartosc.
    printf "  %-32s [%s]: " "$label" "$default" >&2
    read -r answer || true
    echo "${answer:-$default}"
}

env_has_var() {
    grep -q "^${1}=" "$ENV_FILE" 2>/dev/null
}

set_env_var() {
    local var_name="$1" value="$2"
    if env_has_var "$var_name"; then
        local tmp="$ENV_FILE.tmp.$$"
        awk -v k="$var_name" -v v="$value" '
            BEGIN { FS=OFS="=" }
            $1 == k { print k "=" v; next }
            { print }
        ' "$ENV_FILE" > "$tmp" && mv "$tmp" "$ENV_FILE"
    else
        echo "${var_name}=${value}" >> "$ENV_FILE"
    fi
}

# --- Seria pytan ---

echo "Budzet po rezerwie ${RESERVE_GB} GB dla OS: ${BUDGET_GB} GB."
echo ""
echo "Enter akceptuje wartosc domyslna. Format RAM: <liczba>m lub <liczba>g."
echo "Format CPU: ulamek rdzeni (np. 2.0 = dwa pelne rdzenie)."
echo ""

DB_MEM=$(ask          "dbserver RAM"              "$DEFAULT_DBSERVER_MEM")
DB_CPU=$(ask          "dbserver CPU"              "$DEFAULT_DBSERVER_CPU")
APP_MEM=$(ask         "appserver RAM"             "$DEFAULT_APPSERVER_MEM")
APP_CPU=$(ask         "appserver CPU"             "$DEFAULT_APPSERVER_CPU")
WG_MEM=$(ask          "workerserver-general RAM"  "$DEFAULT_WORKER_GENERAL_MEM")
WG_CPU=$(ask          "workerserver-general CPU"  "$DEFAULT_WORKER_GENERAL_CPU")
WD_MEM=$(ask          "workerserver-denorm RAM"   "$DEFAULT_WORKER_DENORM_MEM")
WD_CPU=$(ask          "workerserver-denorm CPU"   "$DEFAULT_WORKER_DENORM_CPU")
RMQ_MEM=$(ask         "rabbitmq RAM"              "$DEFAULT_RABBITMQ_MEM")
RMQ_CPU=$(ask         "rabbitmq CPU"              "$DEFAULT_RABBITMQ_CPU")
REDIS_MEM=$(ask       "redis RAM"                 "$DEFAULT_REDIS_MEM")
REDIS_CPU=$(ask       "redis CPU"                 "$DEFAULT_REDIS_CPU")
LOKI_MEM=$(ask        "loki RAM"                  "$DEFAULT_LOKI_MEM")
LOKI_CPU=$(ask        "loki CPU"                  "$DEFAULT_LOKI_CPU")
PROM_MEM=$(ask        "prometheus RAM"            "$DEFAULT_PROMETHEUS_MEM")
PROM_CPU=$(ask        "prometheus CPU"            "$DEFAULT_PROMETHEUS_CPU")

echo ""
echo "Zapisuje do $ENV_FILE..."

# Zaznacz sekcje, zeby pozniej uzytkownik latwo znalazl.
if ! env_has_var "DBSERVER_MEM_LIMIT"; then
    {
        echo ""
        echo "# === Limity zasobow Docker (make configure-resources) ==="
        echo "# Host wykryty: ${TOTAL_RAM_GB} GB RAM, ${CPU_COUNT} CPU."
    } >> "$ENV_FILE"
fi

set_env_var DBSERVER_MEM_LIMIT         "$DB_MEM"
set_env_var DBSERVER_CPU_LIMIT         "$DB_CPU"
set_env_var APPSERVER_MEM_LIMIT        "$APP_MEM"
set_env_var APPSERVER_CPU_LIMIT        "$APP_CPU"
set_env_var WORKER_GENERAL_MEM_LIMIT   "$WG_MEM"
set_env_var WORKER_GENERAL_CPU_LIMIT   "$WG_CPU"
set_env_var WORKER_DENORM_MEM_LIMIT    "$WD_MEM"
set_env_var WORKER_DENORM_CPU_LIMIT    "$WD_CPU"
set_env_var RABBITMQ_MEM_LIMIT         "$RMQ_MEM"
set_env_var RABBITMQ_CPU_LIMIT         "$RMQ_CPU"
set_env_var REDIS_MEM_LIMIT            "$REDIS_MEM"
set_env_var REDIS_CPU_LIMIT            "$REDIS_CPU"
set_env_var LOKI_MEM_LIMIT             "$LOKI_MEM"
set_env_var LOKI_CPU_LIMIT             "$LOKI_CPU"
set_env_var PROMETHEUS_MEM_LIMIT       "$PROM_MEM"
set_env_var PROMETHEUS_CPU_LIMIT       "$PROM_CPU"

echo ""
echo "Gotowe. Podsumowanie:"
printf "  %-25s %-10s %s\n" "serwis" "RAM" "CPU"
printf "  %-25s %-10s %s\n" "dbserver"             "$DB_MEM"    "$DB_CPU"
printf "  %-25s %-10s %s\n" "appserver"            "$APP_MEM"   "$APP_CPU"
printf "  %-25s %-10s %s\n" "workerserver-general" "$WG_MEM"    "$WG_CPU"
printf "  %-25s %-10s %s\n" "workerserver-denorm"  "$WD_MEM"    "$WD_CPU"
printf "  %-25s %-10s %s\n" "rabbitmq"             "$RMQ_MEM"   "$RMQ_CPU"
printf "  %-25s %-10s %s\n" "redis"                "$REDIS_MEM" "$REDIS_CPU"
printf "  %-25s %-10s %s\n" "loki"                 "$LOKI_MEM"  "$LOKI_CPU"
printf "  %-25s %-10s %s\n" "prometheus"           "$PROM_MEM"  "$PROM_CPU"
echo ""
echo "Zeby zastosowac nowe limity, uruchom:"
echo "    make up"
echo ""

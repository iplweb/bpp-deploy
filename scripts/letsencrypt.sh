#!/usr/bin/env bash
#
# Let's Encrypt orchestrator dla BPP.
#
# Wywolywane przez:
#   make ssl-letsencrypt-issue [PROD=1] [ACTIVATE=1|0]
#   make ssl-letsencrypt-renew
#
# Subkomendy:
#   issue   - wystaw nowy cert (default staging; PROD=1 dla prawdziwego LE)
#             ACTIVATE: 1 = po sukcesie aktywuj DJANGO_BPP_SSL_MODE=letsencrypt
#                       0 = nie aktywuj (pomin prompt)
#                       (puste, TTY) = interaktywny prompt
#                       (puste, non-TTY) = blad, wymaga swiadomego wyboru
#   renew   - odswiez wszystkie certy (idempotentne, no-op gdy nic nie wymaga
#             odswiezenia). Wczesnie wychodzi gdy DJANGO_BPP_SSL_MODE != letsencrypt.
#
# Cala logika trzyma sie w skrypcie (zgodnie z konwencja repo - mk/ssl.mk
# tylko cienko deleguje tutaj).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- Wczytanie BPP_CONFIGS_DIR i .env aplikacji ---

if [ ! -f "$REPO_DIR/.env" ]; then
    echo "ERROR: brak $REPO_DIR/.env. Uruchom 'make init-configs' najpierw." >&2
    exit 1
fi
# shellcheck disable=SC1091
. "$REPO_DIR/.env"

if [ -z "${BPP_CONFIGS_DIR:-}" ]; then
    echo "ERROR: BPP_CONFIGS_DIR nie jest ustawione w $REPO_DIR/.env." >&2
    exit 1
fi

ENV_FILE="$BPP_CONFIGS_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: $ENV_FILE nie istnieje. Uruchom 'make init-configs' najpierw." >&2
    exit 1
fi

# --- Helpery ---

# Czyta zmienna z .env, strippuje cudzyslowy. Pusty string gdy brak.
read_env_var() {
    local raw
    raw="$(grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
    raw="${raw#\"}"; raw="${raw%\"}"
    raw="${raw#\'}"; raw="${raw%\'}"
    printf '%s' "$raw"
}

# Ustawia (overwrite/append) zmienna w .env.
set_env_var_in_file() {
    local file="$1" var="$2" value="$3"
    if grep -qE "^${var}=" "$file" 2>/dev/null; then
        local tmp="$file.tmp.$$"
        awk -v k="$var" -v v="$value" '
            BEGIN { FS=OFS="=" }
            $1 == k { print k "=" v; next }
            { print }
        ' "$file" > "$tmp" && mv "$tmp" "$file"
    else
        printf '\n# Dopisano automatycznie przez letsencrypt.sh: %s\n%s=%s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$var" "$value" >> "$file"
    fi
}

# Lista hostow (CSV/whitespace -> linie, pomin puste).
parse_hosts() {
    echo "$1" | tr ',' '\n' | tr -d ' \t\r' | awk 'NF > 0'
}

# Uruchamia certbot przez docker compose run.
run_certbot() {
    docker compose --profile letsencrypt run --rm certbot "$@"
}

# --- Stan ---

SUBCMD="${1:-help}"
PROD="${PROD:-0}"
ACTIVATE_FLAG="${ACTIVATE:-}"

SSL_MODE="$(read_env_var DJANGO_BPP_SSL_MODE)"
SSL_MODE="${SSL_MODE:-manual}"

LE_EMAIL="$(read_env_var DJANGO_BPP_LETSENCRYPT_EMAIL)"
if [ -z "$LE_EMAIL" ]; then
    LE_EMAIL="$(read_env_var DJANGO_BPP_ADMIN_EMAIL)"
fi

HOSTNAMES_CSV="$(read_env_var DJANGO_BPP_HOSTNAMES)"
HOSTNAME_SINGLE="$(read_env_var DJANGO_BPP_HOSTNAME)"

if [ -n "$HOSTNAMES_CSV" ]; then
    HOSTS_LIST="$(parse_hosts "$HOSTNAMES_CSV")"
else
    HOSTS_LIST="$(parse_hosts "$HOSTNAME_SINGLE")"
fi

CANONICAL_HOST=""
if [ -n "$HOSTS_LIST" ]; then
    CANONICAL_HOST="$(echo "$HOSTS_LIST" | head -1)"
fi

# --- Subkomendy ---

cmd_help() {
    cat <<EOF
letsencrypt.sh - orchestrator Let's Encrypt dla BPP

Uzycie:
  letsencrypt.sh issue [PROD=1] [ACTIVATE=1|0]
                              wystaw cert (domyslnie staging; PROD=1 = prawdziwy)
                              ACTIVATE=1 - aktywuj DJANGO_BPP_SSL_MODE=letsencrypt
                              ACTIVATE=0 - nie aktywuj (non-interactive guard)
                              brak ACTIVATE w TTY = interaktywny prompt
  letsencrypt.sh renew        odnow wszystkie certy (idempotentne)
  letsencrypt.sh help         ten tekst

Konfiguracja (\$BPP_CONFIGS_DIR/.env):
  DJANGO_BPP_SSL_MODE          manual (default) lub letsencrypt
  DJANGO_BPP_LETSENCRYPT_EMAIL email do LE (fallback: DJANGO_BPP_ADMIN_EMAIL)
  DJANGO_BPP_HOSTNAMES         CSV hostow (preferowane), albo
  DJANGO_BPP_HOSTNAME          pojedynczy host (legacy)

Aktualny stan:
  SSL_MODE = $SSL_MODE
  email    = ${LE_EMAIL:-(brak!)}
  hosty    = $(echo "$HOSTS_LIST" | tr '\n' ' ')
  cert-name = ${CANONICAL_HOST:-(brak!)}
EOF
}

cmd_preflight() {
    # LE_SKIP_PREFLIGHT=1: pomin pre-flight (split-horizon DNS, lokalny test
    # gdzie host.name nie rozwiazuje sie z hosta wykonujacego make, oraz
    # mock-tests gdzie nie chcemy curl-owac niczego).
    if [ "${LE_SKIP_PREFLIGHT:-0}" = "1" ]; then
        echo ">>> Pre-flight pominiety (LE_SKIP_PREFLIGHT=1)"
        return 0
    fi
    # Soft-check: sprawdzamy czy nginx odpowiada na port 80 dla wszystkich
    # hostow. Niepowodzenie = warn, nie blad - LE i tak jest ostatecznym
    # arbitrem (split-horizon DNS, run-z-laptopa-na-remote etc.).
    echo ">>> Pre-flight: nginx port 80 + ACME location dla:"
    local any_failed=0
    while IFS= read -r host; do
        [ -z "$host" ] && continue
        local probe_url="http://${host}/.well-known/acme-challenge/preflight-probe-$$"
        local http_code
        http_code="$(curl -fsS -o /dev/null -w "%{http_code}" --max-time 10 \
            "$probe_url" 2>/dev/null || echo "000")"
        case "$http_code" in
            404)
                echo "    OK  ${host} (404 z bloku ACME, jak oczekiwano)"
                ;;
            000)
                echo "    !!  ${host}: brak odpowiedzi na port 80"
                any_failed=1
                ;;
            *)
                echo "    !   ${host}: HTTP $http_code (oczekiwane 404)"
                any_failed=1
                ;;
        esac
    done <<< "$HOSTS_LIST"

    if [ "$any_failed" = "1" ]; then
        echo ""
        echo "    UWAGA: pre-flight wykryl problem z dostepnoscia. Mozliwe przyczyny:"
        echo "      - DNS nie wskazuje na ten serwer"
        echo "      - firewall blokuje port 80 z lokalu"
        echo "      - nginx nie wystartowal (sprawdz 'make ps')"
        echo "      - split-horizon DNS (lokalnie nie widzi siebie po nazwie)"
        echo "    Probuje dalej - certbot zglosi blad ostatecznie."
    fi
    echo ""
}

cmd_issue() {
    if [ -z "$LE_EMAIL" ]; then
        echo "ERROR: brak emaila dla Let's Encrypt." >&2
        echo "Ustaw DJANGO_BPP_LETSENCRYPT_EMAIL lub DJANGO_BPP_ADMIN_EMAIL w $ENV_FILE." >&2
        exit 1
    fi

    if [ -z "$HOSTS_LIST" ] || [ -z "$CANONICAL_HOST" ]; then
        echo "ERROR: ani DJANGO_BPP_HOSTNAMES, ani DJANGO_BPP_HOSTNAME nie sa ustawione w $ENV_FILE." >&2
        exit 1
    fi

    # Buduj argumenty -d <host>
    local d_args=()
    while IFS= read -r host; do
        [ -z "$host" ] && continue
        d_args+=("-d" "$host")
    done <<< "$HOSTS_LIST"

    cmd_preflight

    local mode_label="STAGING"
    local staging_flag=("--staging")
    if [ "$PROD" = "1" ]; then
        mode_label="PROD"
        staging_flag=()
    fi

    echo ">>> Wystawiam cert ($mode_label):"
    echo "    cert-name: $CANONICAL_HOST"
    echo "    SAN-y:"
    while IFS= read -r host; do
        [ -z "$host" ] && continue
        echo "      - $host"
    done <<< "$HOSTS_LIST"
    echo "    email: $LE_EMAIL"
    echo ""

    if ! run_certbot certonly \
            --webroot -w /var/www/certbot \
            "${d_args[@]}" \
            --cert-name "$CANONICAL_HOST" \
            --email "$LE_EMAIL" \
            --agree-tos -n \
            --keep-until-expiring \
            --expand \
            "${staging_flag[@]}"; then
        echo "" >&2
        echo "BLAD: certbot nie wystawil certu." >&2
        exit 1
    fi

    echo ""
    echo "OK Cert ($mode_label) wystawiony do: $BPP_CONFIGS_DIR/letsencrypt/live/$CANONICAL_HOST/"
    echo ""

    # Staging: koniec na tym etapie - cert nie jest zaufany w przegladarce.
    if [ "$PROD" != "1" ]; then
        echo "To byl cert STAGING (niezaufany w przegladarce, ale potwierdza ze caly"
        echo "pipeline dziala: DNS -> nginx port 80 -> webroot -> LE walidacja)."
        echo ""
        echo "Gdy wszystko OK, uruchom z PROD=1 (zuzywa rate-limit LE!):"
        echo ""
        echo "    make ssl-letsencrypt-issue PROD=1"
        echo ""
        return 0
    fi

    # Prod + mode=letsencrypt: reload nginx, gotowe.
    if [ "$SSL_MODE" = "letsencrypt" ]; then
        echo ">>> SSL_MODE=letsencrypt - reloaduje nginx..."
        docker compose exec webserver /docker-entrypoint.d/30-render-bpp-vhosts.sh
        docker compose exec webserver nginx -t
        docker compose exec webserver nginx -s reload
        echo "OK Nginx serwuje nowy cert."
        return 0
    fi

    # Prod + mode=manual: kolizja, decyzja usera.
    echo "==============================================================="
    echo "  UWAGA: DJANGO_BPP_SSL_MODE=manual"
    echo "==============================================================="
    echo "  -> nginx wciaz serwuje cert z $BPP_CONFIGS_DIR/ssl/"
    echo "  -> Codzienny Ofelia renew bedzie odswiezal LE cert, ale nginx"
    echo "     nie bedzie go serwowal do czasu zmiany trybu."
    echo "  -> Aktywacja: DJANGO_BPP_SSL_MODE=letsencrypt + recreate webservera."
    echo "==============================================================="
    echo ""

    local activate=""
    case "$ACTIVATE_FLAG" in
        1|y|yes|true|t|tak)
            activate=1
            echo "ACTIVATE=1: aktywuje letsencrypt automatycznie (non-interactive)."
            ;;
        0|n|no|false|nie)
            activate=0
            echo "ACTIVATE=0: zostawiam DJANGO_BPP_SSL_MODE=manual (non-interactive)."
            ;;
        "")
            if [ -t 0 ]; then
                printf "Aktywowac DJANGO_BPP_SSL_MODE=letsencrypt teraz? [y/N]: "
                local answer=""
                read -r answer || true
                case "$answer" in
                    y|Y|t|T|yes|tak) activate=1 ;;
                    *) activate=0 ;;
                esac
            else
                echo "ERROR: tryb non-interactive bez ACTIVATE=0|1." >&2
                echo "Ciche pominiecie aktywacji = 90-dniowa bomba zegarowa." >&2
                echo "Ustaw ACTIVATE=1 albo ACTIVATE=0 swiadomie." >&2
                exit 1
            fi
            ;;
        *)
            echo "ERROR: niepoprawna wartosc ACTIVATE='$ACTIVATE_FLAG' (oczekuje 0 lub 1)." >&2
            exit 1
            ;;
    esac

    if [ "$activate" = "1" ]; then
        echo ""
        echo ">>> Aktywuje DJANGO_BPP_SSL_MODE=letsencrypt..."
        set_env_var_in_file "$ENV_FILE" "DJANGO_BPP_SSL_MODE" "letsencrypt"
        echo "OK $ENV_FILE: DJANGO_BPP_SSL_MODE=letsencrypt"
        echo ""
        echo ">>> Recreate webservera (--force-recreate, zeby pickup nowych env)..."
        docker compose up -d --force-recreate webserver
        echo ""
        echo "OK Gotowe. Codzienny Ofelia renew bedzie odswiezal cert automatycznie."
    else
        echo ""
        echo "Zostawiam mode=manual. Kiedy bedziesz gotowy:"
        echo ""
        echo "    1. edytuj $ENV_FILE: DJANGO_BPP_SSL_MODE=letsencrypt"
        echo "    2. make refresh"
        echo ""
    fi
}

cmd_renew() {
    if [ "$SSL_MODE" != "letsencrypt" ]; then
        echo "DJANGO_BPP_SSL_MODE=$SSL_MODE - pomijam renew (LE nieaktywny)."
        echo "Aby aktywowac: edytuj $ENV_FILE i ustaw DJANGO_BPP_SSL_MODE=letsencrypt."
        exit 0
    fi

    echo ">>> certbot renew..."
    if ! run_certbot renew \
            --webroot -w /var/www/certbot \
            --deploy-hook "touch /etc/letsencrypt/.reload-needed"; then
        echo "" >&2
        echo "BLAD: certbot renew nie powiodl sie." >&2
        exit 1
    fi

    # Manualny renew - reloaduje nginx od razu (zamiast czekac na osobny
    # job-exec letsencrypt_reload, ktory dziala 5 min po cron-renewie).
    if [ -f "$BPP_CONFIGS_DIR/letsencrypt/.reload-needed" ]; then
        echo ""
        echo ">>> Sentinel obecny - reloaduje nginx..."
        docker compose exec webserver nginx -t
        docker compose exec webserver nginx -s reload
        rm -f "$BPP_CONFIGS_DIR/letsencrypt/.reload-needed"
        echo "OK Nginx zreloadowany, sentinel usuniety."
    else
        echo ""
        echo "Brak sentinela - zaden cert nie wymagal odswiezenia (nic do reloadu)."
    fi
}

case "$SUBCMD" in
    issue) cmd_issue ;;
    renew) cmd_renew ;;
    help|--help|-h) cmd_help ;;
    *)
        echo "ERROR: nieznana subkomenda '$SUBCMD'." >&2
        echo "" >&2
        cmd_help >&2
        exit 2
        ;;
esac

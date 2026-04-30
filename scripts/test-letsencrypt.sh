#!/usr/bin/env bash
#
# Testy logiki scripts/letsencrypt.sh.
#
# Bez sieci, bez prawdziwego certbota, bez prawdziwego Docker daemona.
# Mockujemy `docker` w PATH przez stub-script, ktory tylko loguje argumenty
# i zwraca 0. Skrypt myśli ze wywolal docker compose run / exec / up.
#
# Uruchomienie: `make test-letsencrypt` lub
#   `bash scripts/test-letsencrypt.sh`

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/letsencrypt.sh"

if [ ! -f "$SCRIPT" ]; then
    echo "BLAD: brak $SCRIPT" >&2
    exit 1
fi

TEST_ROOT="$(mktemp -d -t bpp-letsencrypt-test-XXXXXX)"
MOCK_BIN="$TEST_ROOT/mock-bin"
DOCKER_LOG="$TEST_ROOT/docker-calls.log"

mkdir -p "$MOCK_BIN"

# --- Mock dockera ---
# Loguje argumenty do pliku, zwraca 0. Wystarczy dla wszystkich naszych
# wywolan (compose run, compose exec, compose up -d) - skrypt sprawdza
# tylko exit code.
cat > "$MOCK_BIN/docker" <<EOF
#!/bin/sh
echo "\$*" >> "$DOCKER_LOG"
exit 0
EOF
chmod +x "$MOCK_BIN/docker"

# Skrypt letsencrypt.sh przy aktywacji wykonuje:
#   docker compose up -d --force-recreate webserver
# Mock zwraca 0, ale chcemy tez upewnic sie ze .env zostalo zmodyfikowane
# *przed* wywolaniem (kolejnosc: set_env_var_in_file PRZED docker compose up).
# Mock loguje wiec wywolanie, my asercjujemy plik osobno.

# shellcheck disable=SC2317  # wywolywane przez trap
cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

PASS=0
FAIL=0

green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }

pass()  { green "  PASS: $1"; PASS=$((PASS + 1)); }
fail()  { red   "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_exit() {
    local expected="$1" actual="$2" name="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$name"
    else
        fail "$name (oczekiwane exit=$expected, otrzymano exit=$actual)"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" name="$3"
    # `-- "$needle"` zamyka opcje grepa - inaczej BSD grep (macOS) traktuje
    # potrzebne nam '--webroot' / '--staging' itp. jak swoje wlasne flagi.
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        pass "$name"
    else
        fail "$name (brak '$needle')"
        printf '    --- haystack ---\n%s\n    ----------------\n' \
            "${haystack//$'\n'/$'\n    '}" >&2
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" name="$3"
    if ! printf '%s' "$haystack" | grep -qF -- "$needle"; then
        pass "$name"
    else
        fail "$name (znalazlem '$needle')"
    fi
}

assert_env_value() {
    local file="$1" var="$2" expected="$3" name="$4"
    local actual
    actual="$(grep -E "^${var}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-)"
    if [ "$actual" = "$expected" ]; then
        pass "$name"
    else
        fail "$name (oczekiwano ${var}=${expected}, otrzymano ${var}=${actual})"
    fi
}

# Konfiguracja srodowiska dla pojedynczego testu:
# - swoj REPO z .env wskazujacym na swoj CONFIG dir
# - w CONFIG: .env z hostnames/email/ssl_mode wedle testu
# Wszystkie testy reuse-uja $TEST_ROOT, ale kazdy ma wlasny CONFIG_DIR.
setup_case() {
    local case_name="$1"
    CASE_DIR="$TEST_ROOT/$case_name"
    REPO_COPY="$CASE_DIR/repo"
    CONFIG_DIR="$CASE_DIR/config"
    mkdir -p "$REPO_COPY/scripts" "$CONFIG_DIR"

    cp "$SCRIPT" "$REPO_COPY/scripts/letsencrypt.sh"
    chmod +x "$REPO_COPY/scripts/letsencrypt.sh"
    echo "BPP_CONFIGS_DIR=$CONFIG_DIR" > "$REPO_COPY/.env"

    : > "$DOCKER_LOG"  # Wyczysc log dockera per test
}

# Uruchamia letsencrypt.sh z mockiem dockera w PATH, zwraca stdout+stderr
# i exit code w zmiennych RUN_OUTPUT / RUN_EXIT. LE_SKIP_PREFLIGHT=1 zeby
# nie probowac curl-owac fejkowych hostow.
run_le() {
    local subcmd="$1"
    shift
    # `env` parsuje VAR=value-args runtime'owo, w przeciwienstwie do shell-owej
    # syntaxy `VAR=value cmd` ktora wymaga literalu w zrodle (zexpandowane "$@"
    # nie kwalifikuje sie jako env-prefix). Pozwala wiec testom przekazywac
    # PROD=1 ACTIVATE=0 etc. jako pozycyjne argumenty do run_le.
    set +e
    RUN_OUTPUT="$(
        cd "$REPO_COPY" && \
        env -i \
            HOME="$HOME" \
            PATH="$MOCK_BIN:$PATH" \
            LE_SKIP_PREFLIGHT=1 \
            "$@" \
            bash scripts/letsencrypt.sh "$subcmd" 2>&1 < /dev/null
    )"
    RUN_EXIT=$?
    set -e
}

# ============================================================
# TEST 1: help wyswietla aktualny stan i nie wywoluje dockera
# ============================================================
test_help() {
    yellow "=== Test 1: help drukuje aktualny stan ==="
    setup_case "help_basic"
    cat > "$CONFIG_DIR/.env" <<'EOF'
DJANGO_BPP_HOSTNAME=test.example.org
DJANGO_BPP_ADMIN_EMAIL=admin@example.org
DJANGO_BPP_SSL_MODE=letsencrypt
EOF
    run_le help
    assert_exit "0" "$RUN_EXIT" "help: exit 0"
    assert_contains "$RUN_OUTPUT" "SSL_MODE = letsencrypt" "help: czyta SSL_MODE"
    assert_contains "$RUN_OUTPUT" "test.example.org"        "help: czyta HOSTNAME"
    assert_contains "$RUN_OUTPUT" "admin@example.org"       "help: czyta ADMIN_EMAIL jako fallback dla LETSENCRYPT_EMAIL"
    assert_contains "$RUN_OUTPUT" "cert-name = test.example.org" "help: canonical = single host"

    if [ -s "$DOCKER_LOG" ]; then
        fail "help: nie powinien wywolac dockera"
        printf '    docker calls:\n%s\n' "$(cat "$DOCKER_LOG")" >&2
    else
        pass "help: zero wywolan dockera"
    fi
}

# ============================================================
# TEST 2: renew gating na SSL_MODE=manual -> early-exit, no docker
# ============================================================
test_renew_gates_on_mode_manual() {
    yellow "=== Test 2: renew z mode=manual nie wywoluje dockera ==="
    setup_case "renew_manual"
    cat > "$CONFIG_DIR/.env" <<'EOF'
DJANGO_BPP_HOSTNAME=test.example.org
DJANGO_BPP_SSL_MODE=manual
EOF
    run_le renew
    assert_exit "0" "$RUN_EXIT" "renew/manual: exit 0 (silent skip)"
    assert_contains "$RUN_OUTPUT" "SSL_MODE=manual" "renew/manual: komunikat o pominieciu"
    assert_contains "$RUN_OUTPUT" "pomijam renew"   "renew/manual: explicite mowi 'pomijam'"

    if [ -s "$DOCKER_LOG" ]; then
        fail "renew/manual: nie powinien wywolac dockera"
        printf '    docker calls:\n%s\n' "$(cat "$DOCKER_LOG")" >&2
    else
        pass "renew/manual: zero wywolan dockera"
    fi
}

# ============================================================
# TEST 3: renew z mode=letsencrypt -> wywoluje 'docker compose run certbot renew'
# ============================================================
test_renew_calls_certbot() {
    yellow "=== Test 3: renew z mode=letsencrypt wywoluje certbot renew ==="
    setup_case "renew_le"
    cat > "$CONFIG_DIR/.env" <<'EOF'
DJANGO_BPP_HOSTNAME=test.example.org
DJANGO_BPP_SSL_MODE=letsencrypt
EOF
    run_le renew
    assert_exit "0" "$RUN_EXIT" "renew/le: exit 0"
    local docker_calls
    docker_calls="$(cat "$DOCKER_LOG")"
    assert_contains "$docker_calls" "compose"        "renew/le: wywolal docker compose"
    assert_contains "$docker_calls" "certbot"        "renew/le: serwis 'certbot'"
    assert_contains "$docker_calls" "renew"          "renew/le: subkomenda renew"
    assert_contains "$docker_calls" "--webroot"      "renew/le: --webroot"
    assert_contains "$docker_calls" "--deploy-hook"  "renew/le: --deploy-hook"
    assert_contains "$docker_calls" ".reload-needed" "renew/le: deploy-hook tworzy sentinel"
}

# ============================================================
# TEST 4: issue wymaga emaila -> bez ani LETSENCRYPT_EMAIL ani ADMIN_EMAIL = blad
# ============================================================
test_issue_requires_email() {
    yellow "=== Test 4: issue bez emaila -> blad ==="
    setup_case "issue_no_email"
    cat > "$CONFIG_DIR/.env" <<'EOF'
DJANGO_BPP_HOSTNAME=test.example.org
DJANGO_BPP_SSL_MODE=manual
EOF
    # Brak DJANGO_BPP_LETSENCRYPT_EMAIL i brak DJANGO_BPP_ADMIN_EMAIL
    run_le issue
    if [ "$RUN_EXIT" = "0" ]; then
        fail "issue/no-email: powinien zwrocic blad"
    else
        pass "issue/no-email: blad (exit $RUN_EXIT)"
    fi
    assert_contains "$RUN_OUTPUT" "brak emaila" "issue/no-email: komunikat o braku emaila"
}

# ============================================================
# TEST 5: issue wymaga listy hostow
# ============================================================
test_issue_requires_hosts() {
    yellow "=== Test 5: issue bez hostow -> blad ==="
    setup_case "issue_no_hosts"
    cat > "$CONFIG_DIR/.env" <<'EOF'
DJANGO_BPP_ADMIN_EMAIL=admin@example.org
DJANGO_BPP_SSL_MODE=manual
EOF
    run_le issue
    if [ "$RUN_EXIT" = "0" ]; then
        fail "issue/no-hosts: powinien zwrocic blad"
    else
        pass "issue/no-hosts: blad (exit $RUN_EXIT)"
    fi
    assert_contains "$RUN_OUTPUT" "HOSTNAMES" "issue/no-hosts: wspomina o HOSTNAMES"
}

# ============================================================
# TEST 6: issue (default = staging) wywoluje certonly z --staging
# ============================================================
test_issue_staging_args() {
    yellow "=== Test 6: issue (staging) wywoluje certbot z --staging ==="
    setup_case "issue_staging"
    cat > "$CONFIG_DIR/.env" <<'EOF'
DJANGO_BPP_HOSTNAMES=a.example.org,b.example.org
DJANGO_BPP_ADMIN_EMAIL=admin@example.org
DJANGO_BPP_LETSENCRYPT_EMAIL=le@example.org
DJANGO_BPP_SSL_MODE=manual
EOF
    run_le issue
    assert_exit "0" "$RUN_EXIT" "issue/staging: exit 0"
    local calls
    calls="$(cat "$DOCKER_LOG")"
    assert_contains "$calls" "certonly"           "issue/staging: certonly"
    assert_contains "$calls" "--staging"          "issue/staging: flag --staging"
    assert_contains "$calls" "-d a.example.org"   "issue/staging: -d primary host"
    assert_contains "$calls" "-d b.example.org"   "issue/staging: -d secondary host"
    assert_contains "$calls" "--cert-name a.example.org" "issue/staging: cert-name = canonical"
    assert_contains "$calls" "le@example.org"     "issue/staging: explicit LE email (nadpisuje ADMIN_EMAIL)"
    assert_contains "$calls" "--webroot"          "issue/staging: --webroot"
    assert_contains "$calls" "--expand"           "issue/staging: --expand"
    assert_contains "$calls" "--keep-until-expiring" "issue/staging: --keep-until-expiring"
    # Staging konczy bez prompta - nie powinno byc compose exec ani up -d
    assert_not_contains "$calls" "exec webserver" "issue/staging: nie reloaduje nginx"
    assert_not_contains "$calls" "up -d"          "issue/staging: nie recreate webservera"
}

# ============================================================
# TEST 7: issue PROD=1 -> bez --staging, mode=letsencrypt -> reload nginx
# ============================================================
test_issue_prod_le_mode_reloads() {
    yellow "=== Test 7: issue PROD=1 + mode=letsencrypt reloaduje nginx ==="
    setup_case "issue_prod_le"
    cat > "$CONFIG_DIR/.env" <<'EOF'
DJANGO_BPP_HOSTNAME=prod.example.org
DJANGO_BPP_ADMIN_EMAIL=admin@example.org
DJANGO_BPP_SSL_MODE=letsencrypt
EOF
    run_le issue PROD=1
    assert_exit "0" "$RUN_EXIT" "issue/prod-le: exit 0"
    local calls
    calls="$(cat "$DOCKER_LOG")"
    assert_contains     "$calls" "certonly"        "issue/prod-le: certonly"
    assert_not_contains "$calls" "--staging"       "issue/prod-le: BEZ --staging"
    assert_contains     "$calls" "exec webserver"  "issue/prod-le: docker exec webserver"
    assert_contains     "$calls" "nginx -s reload" "issue/prod-le: nginx -s reload"
    # Mode juz byl letsencrypt - bez prompta, bez recreate
    assert_not_contains "$calls" "up -d"           "issue/prod-le: nie recreate webservera"
}

# ============================================================
# TEST 8: issue PROD=1 + mode=manual + ACTIVATE=0 -> cert wystawiony, env nieflipowany
# ============================================================
test_issue_prod_manual_activate_0() {
    yellow "=== Test 8: issue PROD=1 + manual + ACTIVATE=0 nie flipuje .env ==="
    setup_case "issue_activate_0"
    cat > "$CONFIG_DIR/.env" <<'EOF'
DJANGO_BPP_HOSTNAME=prod.example.org
DJANGO_BPP_ADMIN_EMAIL=admin@example.org
DJANGO_BPP_SSL_MODE=manual
EOF
    run_le issue PROD=1 ACTIVATE=0
    assert_exit "0" "$RUN_EXIT" "issue/activate-0: exit 0"
    local calls
    calls="$(cat "$DOCKER_LOG")"
    assert_contains     "$calls" "certonly"  "issue/activate-0: certonly wykonany"
    assert_not_contains "$calls" "up -d"     "issue/activate-0: BRAK recreate webservera"

    # .env nie powinien byc zmodyfikowany
    assert_env_value "$CONFIG_DIR/.env" "DJANGO_BPP_SSL_MODE" "manual" \
        "issue/activate-0: SSL_MODE pozostal manual"
}

# ============================================================
# TEST 9: issue PROD=1 + mode=manual + ACTIVATE=1 -> flipuje .env, recreate webservera
# ============================================================
test_issue_prod_manual_activate_1() {
    yellow "=== Test 9: issue PROD=1 + manual + ACTIVATE=1 flipuje .env ==="
    setup_case "issue_activate_1"
    cat > "$CONFIG_DIR/.env" <<'EOF'
DJANGO_BPP_HOSTNAME=prod.example.org
DJANGO_BPP_ADMIN_EMAIL=admin@example.org
DJANGO_BPP_SSL_MODE=manual
EOF
    run_le issue PROD=1 ACTIVATE=1
    assert_exit "0" "$RUN_EXIT" "issue/activate-1: exit 0"
    local calls
    calls="$(cat "$DOCKER_LOG")"
    assert_contains "$calls" "certonly" "issue/activate-1: certonly"
    assert_contains "$calls" "up -d --force-recreate webserver" \
        "issue/activate-1: recreate webservera"

    assert_env_value "$CONFIG_DIR/.env" "DJANGO_BPP_SSL_MODE" "letsencrypt" \
        "issue/activate-1: SSL_MODE flipowany na letsencrypt"
}

# ============================================================
# TEST 10: issue PROD=1 + mode=manual + non-interactive bez ACTIVATE -> ERROR
# ============================================================
test_issue_prod_manual_no_activate_non_interactive() {
    yellow "=== Test 10: issue PROD=1 + manual + non-TTY bez ACTIVATE -> blad ==="
    setup_case "issue_non_interactive"
    cat > "$CONFIG_DIR/.env" <<'EOF'
DJANGO_BPP_HOSTNAME=prod.example.org
DJANGO_BPP_ADMIN_EMAIL=admin@example.org
DJANGO_BPP_SSL_MODE=manual
EOF
    # run_le redirect-uje stdin z /dev/null -> non-TTY zawsze.
    # Bez ACTIVATE skrypt powinien wywalic blad (90-dniowa bomba zegarowa).
    run_le issue PROD=1
    if [ "$RUN_EXIT" = "0" ]; then
        fail "issue/non-interactive: powinien zwrocic blad"
    else
        pass "issue/non-interactive: blad (exit $RUN_EXIT)"
    fi
    assert_contains "$RUN_OUTPUT" "non-interactive" "issue/non-interactive: komunikat 'non-interactive'"
    assert_contains "$RUN_OUTPUT" "ACTIVATE" "issue/non-interactive: wspomina ACTIVATE"

    # .env nie powinien byc tknięty
    assert_env_value "$CONFIG_DIR/.env" "DJANGO_BPP_SSL_MODE" "manual" \
        "issue/non-interactive: SSL_MODE nietknięty"
}

# ============================================================
# TEST 11: email fallback - LETSENCRYPT_EMAIL pusty -> bierze ADMIN_EMAIL
# ============================================================
test_email_fallback() {
    yellow "=== Test 11: brak LETSENCRYPT_EMAIL -> fallback do ADMIN_EMAIL ==="
    setup_case "email_fallback"
    cat > "$CONFIG_DIR/.env" <<'EOF'
DJANGO_BPP_HOSTNAME=test.example.org
DJANGO_BPP_ADMIN_EMAIL=admin@uczelnia.pl
DJANGO_BPP_LETSENCRYPT_EMAIL=
DJANGO_BPP_SSL_MODE=manual
EOF
    run_le issue
    assert_exit "0" "$RUN_EXIT" "email-fallback: exit 0"
    local calls
    calls="$(cat "$DOCKER_LOG")"
    assert_contains "$calls" "admin@uczelnia.pl" "email-fallback: ADMIN_EMAIL uzyty"
}

# ============================================================
# TEST 12: multi-host CSV -> wszystkie -d args + cert-name = pierwszy host
# ============================================================
test_multi_host_san() {
    yellow "=== Test 12: multi-host CSV -> SAN cert (-d kazdy, cert-name=pierwszy) ==="
    setup_case "multi_host"
    cat > "$CONFIG_DIR/.env" <<'EOF'
DJANGO_BPP_HOSTNAMES=bpp.federacja.pl,bpp.wizja.pl,bpp.ufam.pl
DJANGO_BPP_ADMIN_EMAIL=admin@example.org
DJANGO_BPP_SSL_MODE=manual
EOF
    run_le issue
    assert_exit "0" "$RUN_EXIT" "multi-host: exit 0"
    local calls
    calls="$(cat "$DOCKER_LOG")"
    assert_contains "$calls" "-d bpp.federacja.pl" "multi-host: -d host[0]"
    assert_contains "$calls" "-d bpp.wizja.pl"     "multi-host: -d host[1]"
    assert_contains "$calls" "-d bpp.ufam.pl"      "multi-host: -d host[2]"
    assert_contains "$calls" "--cert-name bpp.federacja.pl" \
        "multi-host: cert-name = pierwszy host (canonical/SAN)"
}

# ============================================================
# RUN
# ============================================================
test_help
test_renew_gates_on_mode_manual
test_renew_calls_certbot
test_issue_requires_email
test_issue_requires_hosts
test_issue_staging_args
test_issue_prod_le_mode_reloads
test_issue_prod_manual_activate_0
test_issue_prod_manual_activate_1
test_issue_prod_manual_no_activate_non_interactive
test_email_fallback
test_multi_host_san

echo ""
echo "==============================================="
green "PASSED: $PASS"
if [ "$FAIL" -gt 0 ]; then
    red "FAILED: $FAIL"
    exit 1
fi
echo "==============================================="
exit 0

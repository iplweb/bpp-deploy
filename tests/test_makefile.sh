#!/usr/bin/env bash
#
# Testy Makefile — weryfikacja first-run i normal operation paths.
# Uruchomienie: ./tests/test_makefile.sh
#
# Testy działają na tymczasowych katalogach i nie modyfikują repozytorium.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
ERRORS=""

green()  { printf "\033[32m%s\033[0m\n" "$*"; }
red()    { printf "\033[31m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
cyan()   { printf "\033[36m%s\033[0m\n" "$*"; }

pass() { green "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { red "  FAIL: $1"; FAIL=$((FAIL + 1)); ERRORS="${ERRORS}\n  - ${1}"; }
skip() { cyan "  SKIP: $1"; }

assert_file_exists()    { if [ -f "$2" ]; then pass "$1"; else fail "$1 ($2 not found)"; fi; }
assert_dir_exists()     { if [ -d "$2" ]; then pass "$1"; else fail "$1 ($2 not found)"; fi; }
assert_file_contains()  { if grep -q "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1 (missing '$2')"; fi; }
assert_file_not_contains() { if ! grep -q "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1 (found '$2')"; fi; }
assert_file_not_empty() { if [ -s "$2" ]; then pass "$1"; else fail "$1 ($2 is empty)"; fi; }

setup_temp() {
    WORK_DIR=$(mktemp -d)
    REPO_COPY="$WORK_DIR/bpp-deploy"
    # -L dereferencuje symlinki (np. AGENTS.md -> CLAUDE.md) — na Windows Git
    # Bash bez Developer Mode tworzenie symlinkow zawodzi.
    cp -rL "$REPO_DIR" "$REPO_COPY"
    rm -f "$REPO_COPY/.env"
    CONFIG_DIR="$WORK_DIR/test-instance"
}

cleanup_temp() { rm -rf "$WORK_DIR"; }

# ============================================================
# TEST 1: setup (first-run) tworzy .env i uruchamia init-configs
# ============================================================

test_first_run_setup() {
    yellow "=== Test 1: First-run setup tworzy .env i konfigurację ==="

    if ! command -v docker >/dev/null 2>&1; then
        skip "docker niedostepny — pomijam setup-path (wymaga 'docker' i 'docker compose')"
        return
    fi

    setup_temp

    # Uruchom setup z podaną ścieżką przez stdin
    echo "$CONFIG_DIR" | make -C "$REPO_COPY" >/dev/null 2>&1 || true

    assert_file_exists "Repo .env created" "$REPO_COPY/.env"
    assert_file_contains "Repo .env has BPP_CONFIGS_DIR" "BPP_CONFIGS_DIR=" "$REPO_COPY/.env"
    assert_dir_exists "Config dir created" "$CONFIG_DIR"
    assert_file_exists "Config .env generated" "$CONFIG_DIR/.env"
    cleanup_temp
}

# ============================================================
# TEST 2: setup z pustym BPP_CONFIGS_DIR w .env
# ============================================================

test_first_run_empty_env() {
    yellow "=== Test 2: Pusty BPP_CONFIGS_DIR triggers setup ==="

    if ! command -v docker >/dev/null 2>&1; then
        skip "docker niedostepny — pomijam setup-path (wymaga 'docker' i 'docker compose')"
        return
    fi

    setup_temp
    echo "BPP_CONFIGS_DIR=" > "$REPO_COPY/.env"

    echo "$CONFIG_DIR" | make -C "$REPO_COPY" >/dev/null 2>&1 || true

    # Powinien nadpisać .env z nową ścieżką
    assert_file_contains ".env updated" "BPP_CONFIGS_DIR=$CONFIG_DIR" "$REPO_COPY/.env"
    assert_dir_exists "Config dir created" "$CONFIG_DIR"

    cleanup_temp
}

# ============================================================
# TEST 3: init-configs tworzy strukturę katalogów
# ============================================================

test_init_configs_creates_structure() {
    yellow "=== Test 3: init-configs tworzy strukturę katalogów ==="

    setup_temp
    mkdir -p "$CONFIG_DIR"

    make -C "$REPO_COPY" init-configs BPP_CONFIGS_DIR="$CONFIG_DIR" >/dev/null 2>&1

    assert_dir_exists "ssl" "$CONFIG_DIR/ssl"
    assert_dir_exists "rclone" "$CONFIG_DIR/rclone"
    assert_dir_exists "alloy" "$CONFIG_DIR/alloy"
    assert_dir_exists "prometheus" "$CONFIG_DIR/prometheus"
    assert_dir_exists "rabbitmq" "$CONFIG_DIR/rabbitmq"
    assert_dir_exists "grafana datasources" "$CONFIG_DIR/grafana/provisioning/datasources"
    assert_dir_exists "grafana dashboards" "$CONFIG_DIR/grafana/provisioning/dashboards"

    cleanup_temp
}

# ============================================================
# TEST 4: init-configs kopiuje szablony z defaults
# ============================================================

test_init_configs_copies_templates() {
    yellow "=== Test 4: init-configs kopiuje szablonowe pliki ==="

    setup_temp
    mkdir -p "$CONFIG_DIR"

    make -C "$REPO_COPY" init-configs BPP_CONFIGS_DIR="$CONFIG_DIR" >/dev/null 2>&1

    assert_file_exists "alloy config" "$CONFIG_DIR/alloy/config.alloy"
    assert_file_exists "prometheus config" "$CONFIG_DIR/prometheus/prometheus.yml"
    assert_file_exists "rabbitmq plugins" "$CONFIG_DIR/rabbitmq/enabled_plugins"
    assert_file_exists "grafana dashboards.yaml" "$CONFIG_DIR/grafana/provisioning/dashboards/dashboards.yaml"
    assert_file_exists "grafana datasources.yaml.tpl" "$CONFIG_DIR/grafana/provisioning/datasources/datasources.yaml.tpl"

    cleanup_temp
}

# ============================================================
# TEST 5: init-configs generuje .env z losowymi hasłami
# ============================================================

test_init_configs_generates_env() {
    yellow "=== Test 5: init-configs generuje .env z losowymi hasłami ==="

    setup_temp
    mkdir -p "$CONFIG_DIR"

    make -C "$REPO_COPY" init-configs BPP_CONFIGS_DIR="$CONFIG_DIR" >/dev/null 2>&1

    assert_file_exists ".env" "$CONFIG_DIR/.env"
    assert_file_not_empty ".env" "$CONFIG_DIR/.env"
    assert_file_contains "DB password" "DJANGO_BPP_DB_PASSWORD=" "$CONFIG_DIR/.env"
    assert_file_contains "RMQ password" "DJANGO_BPP_RABBITMQ_PASS=" "$CONFIG_DIR/.env"
    assert_file_contains "DB name" "DJANGO_BPP_DB_NAME=bpp" "$CONFIG_DIR/.env"
    assert_file_contains "Hostname" "DJANGO_BPP_HOSTNAME=" "$CONFIG_DIR/.env"

    local db_pass rmq_pass
    db_pass=$(grep 'DJANGO_BPP_DB_PASSWORD=' "$CONFIG_DIR/.env" | cut -d= -f2)
    rmq_pass=$(grep 'DJANGO_BPP_RABBITMQ_PASS=' "$CONFIG_DIR/.env" | cut -d= -f2)

    if [ -n "$db_pass" ]; then pass "DB password non-empty"; else fail "DB password non-empty"; fi
    if [ -n "$rmq_pass" ]; then pass "RMQ password non-empty"; else fail "RMQ password non-empty"; fi
    if [ ${#db_pass} -ge 16 ]; then pass "DB password >= 16 chars (${#db_pass})"; else fail "DB password >= 16 chars (${#db_pass})"; fi

    cleanup_temp
}

# ============================================================
# TEST 6: init-configs generuje DJANGO_BPP_HOST_BACKUP_DIR w .env
# ============================================================

test_init_configs_generates_backup_dir() {
    yellow "=== Test 6: init-configs generuje DJANGO_BPP_HOST_BACKUP_DIR w .env ==="

    setup_temp
    mkdir -p "$CONFIG_DIR"

    make -C "$REPO_COPY" init-configs BPP_CONFIGS_DIR="$CONFIG_DIR" >/dev/null 2>&1

    assert_file_contains "DJANGO_BPP_HOST_BACKUP_DIR in .env" "DJANGO_BPP_HOST_BACKUP_DIR=" "$CONFIG_DIR/.env"

    cleanup_temp
}

# ============================================================
# TEST 7: init-configs nie nadpisuje istniejących plików
# ============================================================

test_init_configs_no_overwrite() {
    yellow "=== Test 7: init-configs nie nadpisuje istniejących plików ==="

    setup_temp
    mkdir -p "$CONFIG_DIR"

    # Pierwsze uruchomienie — generuj pliki
    make -C "$REPO_COPY" init-configs BPP_CONFIGS_DIR="$CONFIG_DIR" >/dev/null 2>&1

    # Zapamiętaj oryginalne zawartości
    local original_pass
    original_pass=$(grep 'DJANGO_BPP_DB_PASSWORD=' "$CONFIG_DIR/.env" | cut -d= -f2)
    # Zmodyfikuj szablonowe pliki, żeby sprawdzić czy nie zostaną nadpisane
    echo "# custom alloy config" > "$CONFIG_DIR/alloy/config.alloy"
    echo "# custom prometheus config" > "$CONFIG_DIR/prometheus/prometheus.yml"
    echo "# custom rabbitmq plugins" > "$CONFIG_DIR/rabbitmq/enabled_plugins"

    # Drugie uruchomienie — nie powinno nadpisać
    make -C "$REPO_COPY" init-configs BPP_CONFIGS_DIR="$CONFIG_DIR" >/dev/null 2>&1

    # Sprawdź .env
    local new_pass
    new_pass=$(grep 'DJANGO_BPP_DB_PASSWORD=' "$CONFIG_DIR/.env" | cut -d= -f2)
    if [ "$original_pass" = "$new_pass" ]; then
        pass ".env unchanged after re-init"
    else
        fail ".env changed after re-init"
    fi

    # Sprawdź szablonowe pliki konfiguracyjne
    assert_file_contains "alloy config preserved" "# custom alloy config" "$CONFIG_DIR/alloy/config.alloy"
    assert_file_contains "prometheus config preserved" "# custom prometheus config" "$CONFIG_DIR/prometheus/prometheus.yml"
    assert_file_contains "rabbitmq plugins preserved" "# custom rabbitmq plugins" "$CONFIG_DIR/rabbitmq/enabled_plugins"

    cleanup_temp
}

# ============================================================
# TEST 8: Różne instancje dostają różne hasła
# ============================================================

test_passwords_are_random() {
    yellow "=== Test 8: Losowe hasła są unikalne ==="

    setup_temp
    local cfg_a="$WORK_DIR/instance-a"
    local cfg_b="$WORK_DIR/instance-b"
    mkdir -p "$cfg_a" "$cfg_b"

    make -C "$REPO_COPY" init-configs BPP_CONFIGS_DIR="$cfg_a" >/dev/null 2>&1
    make -C "$REPO_COPY" init-configs BPP_CONFIGS_DIR="$cfg_b" >/dev/null 2>&1

    local pass_a pass_b
    pass_a=$(grep 'DJANGO_BPP_DB_PASSWORD=' "$cfg_a/.env" | cut -d= -f2)
    pass_b=$(grep 'DJANGO_BPP_DB_PASSWORD=' "$cfg_b/.env" | cut -d= -f2)

    if [ "$pass_a" != "$pass_b" ]; then
        pass "Different instances get different passwords"
    else
        fail "Both instances got same password: $pass_a"
    fi

    cleanup_temp
}

# ============================================================
# TEST 9: Normal path — make help działa
# ============================================================

test_normal_path_help() {
    yellow "=== Test 9: Normal path — make help ==="

    setup_temp
    mkdir -p "$CONFIG_DIR"
    make -C "$REPO_COPY" init-configs BPP_CONFIGS_DIR="$CONFIG_DIR" >/dev/null 2>&1
    echo "BPP_CONFIGS_DIR=$CONFIG_DIR" > "$REPO_COPY/.env"

    local outfile="$WORK_DIR/help.txt"
    make -C "$REPO_COPY" help > "$outfile" 2>&1

    assert_file_contains "help shows Deployment" "Deployment" "$outfile"
    assert_file_contains "help shows db-backup" "db-backup" "$outfile"
    assert_file_contains "help shows config dir" "$CONFIG_DIR" "$outfile"

    cleanup_temp
}

# ============================================================
# TEST 10: Normal path — targets rozpoznawane (dry-run)
# ============================================================

test_normal_path_targets() {
    yellow "=== Test 10: Normal path — targets dostępne ==="

    setup_temp
    mkdir -p "$CONFIG_DIR"
    make -C "$REPO_COPY" init-configs BPP_CONFIGS_DIR="$CONFIG_DIR" >/dev/null 2>&1
    echo "BPP_CONFIGS_DIR=$CONFIG_DIR" > "$REPO_COPY/.env"

    for target in up stop health logs db-backup migrate update-configs init-configs; do
        local outfile="$WORK_DIR/target_${target}.txt"
        make -C "$REPO_COPY" --dry-run "$target" > "$outfile" 2>&1 || true
        if grep -q "No rule to make target" "$outfile"; then
            fail "Target '$target' exists"
        else
            pass "Target '$target' exists"
        fi
    done

    cleanup_temp
}

# ============================================================
# TEST 11: docker-compose — bind mounty, brak starych volumes
# ============================================================

test_compose_bind_mounts() {
    yellow "=== Test 11: docker-compose — bind mounty ==="

    for f in infrastructure monitoring backup; do
        local file="$REPO_DIR/docker-compose.${f}.yml"
        assert_file_contains "$f.yml uses BPP_CONFIGS_DIR" "BPP_CONFIGS_DIR" "$file"
    done

    for vol in ssl_certs rabbitmq_config grafana_provisioning alloy_config prometheus_config rclone_config; do
        if grep -rq "^  ${vol}:" "$REPO_DIR"/docker-compose.*.yml 2>/dev/null; then
            fail "Named volume '$vol' still defined"
        else
            pass "No named volume '$vol'"
        fi
    done

    for f in infrastructure application workers; do
        local file="$REPO_DIR/docker-compose.${f}.yml"
        if grep -q 'env_file' "$file"; then
            assert_file_contains "$f.yml env_file" 'BPP_CONFIGS_DIR' "$file"
        fi
    done
}

# ============================================================
# TEST 12: .env.sample istnieje
# ============================================================

test_env_sample() {
    yellow "=== Test 12: .env.sample ==="
    assert_file_exists ".env.sample" "$REPO_DIR/.env.sample"
    assert_file_contains ".env.sample documented" "BPP_CONFIGS_DIR" "$REPO_DIR/.env.sample"
}

# ============================================================
# TEST 13: configs.mk nie zawiera SCP
# ============================================================

test_no_scp_in_configs() {
    yellow "=== Test 13: mk/configs.mk bez SCP ==="
    local f="$REPO_DIR/mk/configs.mk"
    assert_file_not_contains "configs.mk" "scp " "$f"
    assert_file_not_contains "configs.mk" "ssh.*rm" "$f"
    assert_file_not_contains "configs.mk" "alpine" "$f"
}

# ============================================================
# TEST 14: nginx config template jest syntaktycznie poprawny
# ============================================================
# Spina oficjalny obraz nginx:1.29.7, wykonuje envsubst na templatce
# (tak samo jak robi to entrypoint nginx:alpine/debian), generuje
# dummy self-signed cert i uruchamia `nginx -t`. Bez dockera test SKIP.
# ============================================================

test_nginx_config_valid() {
    yellow "=== Test 14: nginx -t na default.conf.template ==="

    if ! command -v docker >/dev/null 2>&1; then
        skip "docker niedostepny — pomijam nginx -t"
        return
    fi

    if ! docker info >/dev/null 2>&1; then
        skip "docker daemon niedostepny — pomijam nginx -t"
        return
    fi

    local ngx_dir
    ngx_dir=$(mktemp -d)
    mkdir -p "$ngx_dir/templates" "$ngx_dir/conf.d" "$ngx_dir/ssl" "$ngx_dir/html"

    cp "$REPO_DIR/defaults/webserver/default.conf.template" "$ngx_dir/templates/"
    cp "$REPO_DIR/defaults/webserver/security-headers.conf" "$ngx_dir/conf.d/"
    cp "$REPO_DIR/defaults/webserver/maintenance.html" "$ngx_dir/html/"

    # Dummy self-signed cert - nginx -t parsuje plik, wiec musi byc prawidlowy x509.
    # Generujemy w kontenerze, zeby nie wymagac openssl na hoscie (Windows CI).
    docker run --rm \
        -v "$ngx_dir/ssl:/ssl" \
        nginx:1.29.7 \
        sh -c "apt-get update >/dev/null 2>&1 && apt-get install -y openssl >/dev/null 2>&1 && \
               openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
                   -keyout /ssl/key.pem -out /ssl/cert.pem \
                   -subj '/CN=test.example.org' >/dev/null 2>&1" || {
        fail "dummy SSL cert generation"
        rm -rf "$ngx_dir"
        return
    }

    # Uruchom envsubst (jak oficjalny entrypoint nginx) + nginx -t.
    # NGINX_ENVSUBST_FILTER=DJANGO_BPP_ ogranicza substytucje do naszych zmiennych,
    # zeby nie podmieniac np. $host, $uri uzywanych w konfigu.
    local out
    out=$(docker run --rm \
        -e DJANGO_BPP_HOSTNAME=test.example.org \
        -e NGINX_ENVSUBST_FILTER=DJANGO_BPP_ \
        -v "$ngx_dir/templates:/etc/nginx/templates:ro" \
        -v "$ngx_dir/conf.d/security-headers.conf:/etc/nginx/conf.d/security-headers.conf:ro" \
        -v "$ngx_dir/ssl:/etc/ssl/private:ro" \
        -v "$ngx_dir/html/maintenance.html:/usr/share/nginx/html/maintenance.html:ro" \
        --entrypoint sh \
        nginx:1.29.7 \
        -c '/docker-entrypoint.d/20-envsubst-on-templates.sh && nginx -t' 2>&1) || {
        fail "nginx -t na default.conf.template"
        printf '    %s\n' "${out//$'\n'/$'\n    '}"
        rm -rf "$ngx_dir"
        return
    }

    pass "nginx -t na default.conf.template"

    # Dodatkowo: sprawdz czy kluczowe dyrektywy performance sa obecne w
    # wyrenderowanej konfiguracji (zeby regresja nie wywalila optymalizacji).
    local rendered="$ngx_dir/rendered.conf"
    docker run --rm \
        -e DJANGO_BPP_HOSTNAME=test.example.org \
        -e NGINX_ENVSUBST_FILTER=DJANGO_BPP_ \
        -v "$ngx_dir/templates:/etc/nginx/templates:ro" \
        -v "$ngx_dir:/out" \
        --entrypoint sh \
        nginx:1.29.7 \
        -c '/docker-entrypoint.d/20-envsubst-on-templates.sh && cp /etc/nginx/conf.d/default.conf /out/rendered.conf' >/dev/null 2>&1 || true

    if [ -f "$rendered" ]; then
        assert_file_contains "gzip on" "gzip on" "$rendered"
        assert_file_contains "gzip_comp_level ustawiony" "gzip_comp_level" "$rendered"
        assert_file_contains "gzip_vary on" "gzip_vary on" "$rendered"
        assert_file_contains "proxy_buffers wiekszy niz 8x4k" "proxy_buffers 16" "$rendered"
        assert_file_contains "HTTP/2 on" "http2 on" "$rendered"
        assert_file_contains "HTTP/3 QUIC" "listen 443 quic" "$rendered"
    else
        fail "wyrenderowana konfiguracja niedostepna do sprawdzenia dyrektyw"
    fi

    rm -rf "$ngx_dir"
}

# ============================================================
# Run
# ============================================================

echo ""
echo "========================================"
echo "  BPP Deploy — Makefile Tests"
echo "========================================"
echo "  Repo: $REPO_DIR"
echo ""

test_first_run_setup
test_first_run_empty_env
test_init_configs_creates_structure
test_init_configs_copies_templates
test_init_configs_generates_env
test_init_configs_generates_backup_dir
test_init_configs_no_overwrite
test_passwords_are_random
test_normal_path_help
test_normal_path_targets
test_compose_bind_mounts
test_env_sample
test_no_scp_in_configs
test_nginx_config_valid

echo ""
echo "========================================"
if [ "$FAIL" -gt 0 ]; then
    red "  RESULTS: $PASS passed, $FAIL failed"
    echo -e "  Failures:$ERRORS"
    exit 1
else
    green "  RESULTS: $PASS passed, 0 failed"
fi
echo "========================================"

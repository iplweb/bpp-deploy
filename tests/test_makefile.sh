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
    assert_file_contains "DB name" "DJANGO_BPP_DB_NAME=bpp" "$CONFIG_DIR/.env"
    assert_file_contains "Hostname" "DJANGO_BPP_HOSTNAME=" "$CONFIG_DIR/.env"

    local db_pass
    db_pass=$(grep 'DJANGO_BPP_DB_PASSWORD=' "$CONFIG_DIR/.env" | cut -d= -f2)

    if [ -n "$db_pass" ]; then pass "DB password non-empty"; else fail "DB password non-empty"; fi
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
# TEST 14: nginx config (legacy single-host + multi-host)
# ============================================================
# Spina oficjalny obraz nginx:1.29.7, mountuje pelen stack templatow
# (default + vhost + locations + entrypoint script renderujacy vhosty),
# uruchamia caly entrypoint chain (10/15/20/30) i wywoluje nginx -t.
# Test sprawdza dwa tryby: legacy single-host (DJANGO_BPP_HOSTNAME +
# legacy ssl/cert.pem) oraz multi-host (DJANGO_BPP_HOSTNAMES + per-host
# certy w ssl/<host>/). Bez dockera SKIP.
# ============================================================

# Wewnetrzny helper: odpala nginx -t z pelnym entrypoint chain dla danego
# zestawu zmiennych srodowiskowych i layoutu ssl/. Drukuje stdout/stderr
# i ustawia $? = exit code nginx -t.
_run_nginx_t() {
    local ngx_dir="$1"
    shift
    docker run --rm \
        -v "$ngx_dir/templates/default.conf.template:/etc/nginx/templates/default.conf.template:ro" \
        -v "$ngx_dir/conf.d/security-headers.conf:/etc/nginx/conf.d/security-headers.conf:ro" \
        -v "$ngx_dir/bpp-templates/_bpp-locations.conf:/etc/nginx/bpp-templates/_bpp-locations.conf:ro" \
        -v "$ngx_dir/bpp-templates/vhost.conf.template:/etc/nginx/bpp-templates/vhost.conf.template:ro" \
        -v "$ngx_dir/entrypoint/30-render-bpp-vhosts.sh:/docker-entrypoint.d/30-render-bpp-vhosts.sh:ro" \
        -v "$ngx_dir/ssl:/etc/ssl/private:ro" \
        -v "$ngx_dir/html/maintenance.html:/usr/share/nginx/html/maintenance.html:ro" \
        -e NGINX_ENVSUBST_FILTER=DJANGO_BPP_ \
        "$@" \
        --entrypoint sh \
        nginx:1.29.7 \
        -c '
            for f in /docker-entrypoint.d/*.sh; do
                [ -x "$f" ] || continue
                "$f" >&2
            done
            # Skopiuj zrenderowane pliki na bind-mountowany /out aby host mogl je
            # zassertowac po wyjsciu z kontenera.
            cp /etc/nginx/conf.d/default.conf /out/rendered-default.conf 2>/dev/null || true
            for vh in /etc/nginx/conf.d/vhost-*.conf; do
                [ -f "$vh" ] && cp "$vh" /out/ 2>/dev/null || true
            done
            nginx -t
        ' 2>&1
}

test_nginx_config_valid() {
    yellow "=== Test 14: nginx -t (legacy single-host + multi-host) ==="

    if ! command -v docker >/dev/null 2>&1; then
        skip "docker niedostepny — pomijam nginx -t"
        return
    fi

    local docker_os
    docker_os=$(docker info --format '{{.OSType}}' 2>/dev/null) || true
    if [ -z "$docker_os" ]; then
        skip "docker daemon niedostepny — pomijam nginx -t"
        return
    fi
    if [ "$docker_os" != "linux" ]; then
        skip "docker daemon w trybie '$docker_os' (nie linux) — pomijam nginx -t"
        return
    fi

    local ngx_dir
    ngx_dir=$(mktemp -d)
    mkdir -p "$ngx_dir/templates" "$ngx_dir/conf.d" \
             "$ngx_dir/bpp-templates" "$ngx_dir/entrypoint" \
             "$ngx_dir/ssl" "$ngx_dir/html"

    cp "$REPO_DIR/defaults/webserver/default.conf.template" "$ngx_dir/templates/"
    cp "$REPO_DIR/defaults/webserver/security-headers.conf" "$ngx_dir/conf.d/"
    cp "$REPO_DIR/defaults/webserver/_bpp-locations.conf"   "$ngx_dir/bpp-templates/"
    cp "$REPO_DIR/defaults/webserver/vhost.conf.template"   "$ngx_dir/bpp-templates/"
    cp "$REPO_DIR/defaults/webserver/30-render-bpp-vhosts.sh" "$ngx_dir/entrypoint/"
    cp "$REPO_DIR/defaults/webserver/maintenance.html"      "$ngx_dir/html/"
    chmod +x "$ngx_dir/entrypoint/30-render-bpp-vhosts.sh"

    # Dummy self-signed cert - nginx -t parsuje plik, wiec musi byc prawidlowy x509.
    # Generujemy w kontenerze, zeby nie wymagac openssl na hoscie (Windows CI).
    # Generujemy zarowno legacy ssl/{cert,key}.pem (test 14a) jak i
    # ssl/<host>/{cert,key}.pem dla 3 hostow (test 14b).
    docker run --rm \
        -v "$ngx_dir/ssl:/ssl" \
        --entrypoint sh \
        nginx:1.29.7 \
        -c "apt-get update >/dev/null 2>&1 && apt-get install -y openssl >/dev/null 2>&1 && \
            openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
                -keyout /ssl/key.pem -out /ssl/cert.pem \
                -subj '/CN=legacy.example.org' >/dev/null 2>&1 && \
            for h in bpp.federacja.pl bpp.wizja.pl bpp.ufam.pl; do
                mkdir -p /ssl/\$h
                openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
                    -keyout /ssl/\$h/key.pem -out /ssl/\$h/cert.pem \
                    -subj \"/CN=\$h\" >/dev/null 2>&1
            done" || {
        fail "dummy SSL cert generation"
        rm -rf "$ngx_dir"
        return
    }

    # Bind-mount dla wyrzucenia zrenderowanych plikow z kontenera.
    mkdir -p "$ngx_dir/out"

    # --- Test 14a: legacy single-host (DJANGO_BPP_HOSTNAME, brak HOSTNAMES) ---
    local out_a
    out_a=$(_run_nginx_t "$ngx_dir" \
        -e DJANGO_BPP_HOSTNAME=legacy.example.org \
        -v "$ngx_dir/out:/out" 2>&1 || true)
    if echo "$out_a" | grep -q "syntax is ok" && echo "$out_a" | grep -q "test is successful"; then
        pass "nginx -t (legacy single-host)"
        assert_file_exists "vhost-legacy.example.org.conf wygenerowany" \
            "$ngx_dir/out/vhost-legacy.example.org.conf"
    else
        fail "nginx -t (legacy single-host)"
        printf '    %s\n' "${out_a//$'\n'/$'\n    '}"
    fi

    # Wyczysc zrenderowane vhost-y miedzy testami.
    rm -f "$ngx_dir/out"/vhost-*.conf "$ngx_dir/out/rendered-default.conf"

    # --- Test 14b: multi-host (DJANGO_BPP_HOSTNAMES) ---
    local out_b
    out_b=$(_run_nginx_t "$ngx_dir" \
        -e DJANGO_BPP_HOSTNAMES="bpp.federacja.pl,bpp.wizja.pl,bpp.ufam.pl" \
        -v "$ngx_dir/out:/out" 2>&1 || true)
    if echo "$out_b" | grep -q "syntax is ok" && echo "$out_b" | grep -q "test is successful"; then
        pass "nginx -t (multi-host)"
        assert_file_exists "vhost-bpp.federacja.pl.conf"  "$ngx_dir/out/vhost-bpp.federacja.pl.conf"
        assert_file_exists "vhost-bpp.wizja.pl.conf"      "$ngx_dir/out/vhost-bpp.wizja.pl.conf"
        assert_file_exists "vhost-bpp.ufam.pl.conf"       "$ngx_dir/out/vhost-bpp.ufam.pl.conf"
    else
        fail "nginx -t (multi-host)"
        printf '    %s\n' "${out_b//$'\n'/$'\n    '}"
    fi

    # --- Asercje na strukture: kluczowe dyrektywy musza nadal istniec gdzies ---
    # Po refactorze gzip/proxy_buffers zyja w _bpp-locations.conf, http2/quic
    # w default.conf (catch-all) i w kazdym vhost-*.conf.
    local locations="$REPO_DIR/defaults/webserver/_bpp-locations.conf"
    local vhost_tpl="$REPO_DIR/defaults/webserver/vhost.conf.template"
    assert_file_contains "gzip on (locations)"          "gzip on"        "$locations"
    assert_file_contains "gzip_comp_level (locations)"  "gzip_comp_level" "$locations"
    assert_file_contains "gzip_vary on (locations)"     "gzip_vary on"   "$locations"
    assert_file_contains "proxy_buffers 16 (locations)" "proxy_buffers 16" "$locations"
    assert_file_contains "HTTP/2 on (vhost)"            "http2 on"       "$vhost_tpl"
    assert_file_contains "HTTP/3 QUIC (vhost)"          "listen 443 quic" "$vhost_tpl"

    rm -rf "$ngx_dir"
}

# ============================================================
# TEST 15: nginx runtime — startuje, nasluchuje, proxuje do appservera
# ============================================================
# Stawia siec docker, fake-appserver (Python http.server echoujacy Host header)
# i prawdziwego nginx-a z naszym configiem. Sprawdza dwa scenariusze:
#   15a) single-host legacy: DJANGO_BPP_HOSTNAME=legacy.example.org + ssl/cert.pem
#   15b) multi-host:        DJANGO_BPP_HOSTNAMES=3 hosty + ssl/<host>/cert.pem
# Curl-em weryfikuje:
#   - HTTP /healthz catch-all (200)
#   - HTTP znany host -> 301 redirect
#   - HTTP nieznany host -> 444 (drop)
#   - HTTPS znany SNI -> proxy do appservera (body zawiera Host header)
#   - HTTPS nieznany SNI -> ssl_reject_handshake
# ============================================================

test_nginx_runtime() {
    yellow "=== Test 15: nginx runtime — start, listen, proxy ==="

    if ! command -v docker >/dev/null 2>&1; then
        skip "docker niedostepny — pomijam runtime"
        return
    fi
    local docker_os
    docker_os=$(docker info --format '{{.OSType}}' 2>/dev/null || true)
    if [ -z "$docker_os" ]; then
        skip "docker daemon niedostepny — pomijam runtime"
        return
    fi
    if [ "$docker_os" != "linux" ]; then
        skip "docker daemon w trybie '$docker_os' (nie linux) — pomijam runtime"
        return
    fi
    if ! command -v curl >/dev/null 2>&1; then
        skip "curl niedostepny — pomijam runtime"
        return
    fi

    local ngx_dir net_name nginx_cid app_cid
    ngx_dir=$(mktemp -d)
    net_name="bpp-test-net-$$"
    nginx_cid=""
    app_cid=""

    _runtime_cleanup() {
        if [ -n "$nginx_cid" ]; then
            docker stop -t 1 "$nginx_cid" >/dev/null 2>&1 || true
        fi
        if [ -n "$app_cid" ]; then
            docker stop -t 1 "$app_cid" >/dev/null 2>&1 || true
        fi
        docker network rm "$net_name" >/dev/null 2>&1 || true
        rm -rf "$ngx_dir"
    }
    trap _runtime_cleanup RETURN

    # Setup mountow webservera
    mkdir -p "$ngx_dir/templates" "$ngx_dir/conf.d" "$ngx_dir/bpp-templates" \
             "$ngx_dir/entrypoint" "$ngx_dir/ssl" "$ngx_dir/html"
    cp "$REPO_DIR/defaults/webserver/default.conf.template"   "$ngx_dir/templates/"
    cp "$REPO_DIR/defaults/webserver/security-headers.conf"   "$ngx_dir/conf.d/"
    cp "$REPO_DIR/defaults/webserver/_bpp-locations.conf"     "$ngx_dir/bpp-templates/"
    cp "$REPO_DIR/defaults/webserver/vhost.conf.template"     "$ngx_dir/bpp-templates/"
    cp "$REPO_DIR/defaults/webserver/30-render-bpp-vhosts.sh" "$ngx_dir/entrypoint/"
    cp "$REPO_DIR/defaults/webserver/maintenance.html"        "$ngx_dir/html/"
    chmod +x "$ngx_dir/entrypoint/30-render-bpp-vhosts.sh"

    # Generuj certy: legacy ssl/{cert,key}.pem + per-host ssl/<h>/{cert,key}.pem
    docker run --rm -v "$ngx_dir/ssl:/ssl" --entrypoint sh nginx:1.29.7 -c '
        apt-get update >/dev/null 2>&1 && apt-get install -y openssl >/dev/null 2>&1
        openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
            -keyout /ssl/key.pem -out /ssl/cert.pem \
            -subj "/CN=legacy.example.org" >/dev/null 2>&1
        for h in bpp.federacja.pl bpp.wizja.pl bpp.ufam.pl; do
            mkdir -p /ssl/$h
            openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
                -keyout /ssl/$h/key.pem -out /ssl/$h/cert.pem \
                -subj "/CN=$h" >/dev/null 2>&1
        done
    ' || { fail "cert generation"; return; }

    docker network create "$net_name" >/dev/null

    # Fake appserver: Python http.server echo-ujacy Host/X-Forwarded-Host/Path.
    # network-alias=appserver pozwala nginx-owi dosiegnac kontener pod nazwa
    # zgodna z naszym configiem (set $upstream_appserver appserver;).
    local pyscript
    pyscript=$(cat <<'PYEOF'
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = ("OK\n"
                + "Host: " + self.headers.get("Host","?") + "\n"
                + "XFH: " + self.headers.get("X-Forwarded-Host","?") + "\n"
                + "Path: " + self.path + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type","text/plain")
        self.send_header("Content-Length",str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a, **k): pass
HTTPServer(("0.0.0.0",8000),H).serve_forever()
PYEOF
)
    app_cid=$(docker run -d --rm \
        --network "$net_name" --network-alias appserver \
        --name "fake-appserver-$$" \
        python:3-alpine python -c "$pyscript")
    sleep 2

    # Helper: startuje nginx-a, czeka na healthz, drukuje "cid port_80 port_443" na
    # stdout. Caller parsuje przez `read`. Konieczne bo `$(_runtime_start_nginx)`
    # uruchamia subshell — zmiana globalnej $nginx_cid w funkcji nie propagowalaby
    # sie do parenta. Explicit `-p` (a nie -P) bo nginx image EXPOSE-uje tylko 80.
    _runtime_start_nginx() {
        local hostnames="$1" single_host="$2"
        local cid p80 p443
        cid=$(docker run -d --rm --network "$net_name" \
            -p "127.0.0.1:0:80/tcp" \
            -p "127.0.0.1:0:443/tcp" \
            -v "$ngx_dir/templates/default.conf.template:/etc/nginx/templates/default.conf.template:ro" \
            -v "$ngx_dir/conf.d/security-headers.conf:/etc/nginx/conf.d/security-headers.conf:ro" \
            -v "$ngx_dir/bpp-templates/_bpp-locations.conf:/etc/nginx/bpp-templates/_bpp-locations.conf:ro" \
            -v "$ngx_dir/bpp-templates/vhost.conf.template:/etc/nginx/bpp-templates/vhost.conf.template:ro" \
            -v "$ngx_dir/entrypoint/30-render-bpp-vhosts.sh:/docker-entrypoint.d/30-render-bpp-vhosts.sh:ro" \
            -v "$ngx_dir/ssl:/etc/ssl/private:ro" \
            -v "$ngx_dir/html/maintenance.html:/usr/share/nginx/html/maintenance.html:ro" \
            -e NGINX_ENVSUBST_FILTER=DJANGO_BPP_ \
            -e DJANGO_BPP_HOSTNAMES="$hostnames" \
            -e DJANGO_BPP_HOSTNAME="$single_host" \
            nginx:1.29.7) || return 1
        if [ -z "$cid" ]; then return 1; fi
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            p80=$(docker port "$cid" 80/tcp 2>/dev/null | head -1 | sed 's/.*://')
            if [ -n "$p80" ] && curl -sf "http://127.0.0.1:$p80/healthz" >/dev/null 2>&1; then
                p443=$(docker port "$cid" 443/tcp 2>/dev/null | head -1 | sed 's/.*://')
                echo "$cid $p80 $p443"
                return 0
            fi
            sleep 1
        done
        docker stop -t 1 "$cid" >/dev/null 2>&1 || true
        return 1
    }

    _runtime_stop_nginx() {
        if [ -n "$nginx_cid" ]; then
            docker stop -t 1 "$nginx_cid" >/dev/null 2>&1 || true
            nginx_cid=""
        fi
    }

    # ==== 15a: single-host legacy ====
    yellow "  -- 15a: single-host (DJANGO_BPP_HOSTNAME=legacy.example.org) --"
    local port_80 port_443 code body h start_out
    start_out=$(_runtime_start_nginx "" "legacy.example.org") || {
        fail "single-host nginx nie wstal w 15s"
        return
    }
    read -r nginx_cid port_80 port_443 <<< "$start_out"
    pass "single-host nginx wstal i odpowiada na /healthz"

    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port_80/healthz" || true)
    if [ "$code" = "200" ]; then pass "HTTP /healthz catch-all -> 200"
    else fail "HTTP /healthz: got '$code'"; fi

    code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: legacy.example.org" "http://127.0.0.1:$port_80/" || true)
    if [ "$code" = "301" ]; then pass "HTTP legacy.example.org -> 301"
    else fail "HTTP legacy redirect: got '$code'"; fi

    # 444 zamyka polaczenie bez odpowiedzi → curl: http_code=000 + non-zero exit.
    # `|| true` chroni przed set -e; samo "000" w stdout wystarczy do detekcji.
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: unknown.example" "http://127.0.0.1:$port_80/" 2>/dev/null || true)
    if [ "$code" = "000" ]; then pass "HTTP unknown.example -> drop (444)"
    else fail "HTTP unknown.example: got '$code'"; fi

    body=$(curl -sk --resolve "legacy.example.org:$port_443:127.0.0.1" "https://legacy.example.org:$port_443/some/path" || true)
    if echo "$body" | grep -q "Host: legacy.example.org" && echo "$body" | grep -q "Path: /some/path"; then
        pass "HTTPS legacy.example.org -> proxy do appservera (Host + Path)"
    else
        fail "HTTPS legacy: nieoczekiwana odpowiedz: $(echo "$body" | head -c 200)"
    fi

    if curl -sk --resolve "unknown.example:$port_443:127.0.0.1" "https://unknown.example:$port_443/" >/dev/null 2>&1; then
        fail "HTTPS unknown.example: oczekiwany ssl_reject_handshake"
    else
        pass "HTTPS unknown.example -> ssl_reject_handshake"
    fi

    _runtime_stop_nginx

    # ==== 15b: multi-host (3 hosty) ====
    yellow "  -- 15b: multi-host (DJANGO_BPP_HOSTNAMES=federacja+wizja+ufam) --"
    start_out=$(_runtime_start_nginx "bpp.federacja.pl,bpp.wizja.pl,bpp.ufam.pl" "") || {
        fail "multi-host nginx nie wstal w 15s"
        return
    }
    read -r nginx_cid port_80 port_443 <<< "$start_out"
    pass "multi-host nginx wstal i odpowiada na /healthz"

    for h in bpp.federacja.pl bpp.wizja.pl bpp.ufam.pl; do
        body=$(curl -sk --resolve "$h:$port_443:127.0.0.1" "https://$h:$port_443/x" || true)
        if echo "$body" | grep -q "Host: $h"; then
            pass "HTTPS $h -> proxy z Host: $h"
        else
            fail "HTTPS $h: $(echo "$body" | head -c 200)"
        fi

        code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $h" "http://127.0.0.1:$port_80/" || true)
        if [ "$code" = "301" ]; then pass "HTTP $h -> 301"
        else fail "HTTP $h: got '$code'"; fi
    done

    if curl -sk --resolve "intruder.example:$port_443:127.0.0.1" "https://intruder.example:$port_443/" >/dev/null 2>&1; then
        fail "HTTPS intruder.example w multi-host: oczekiwany reject"
    else
        pass "HTTPS intruder.example -> reject (multi-host)"
    fi

    # cleanup via trap RETURN
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
test_nginx_runtime

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

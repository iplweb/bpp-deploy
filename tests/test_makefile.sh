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
SKIP=0
ERRORS=""

green()  { printf "\033[32m%s\033[0m\n" "$*"; }
red()    { printf "\033[31m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
cyan()   { printf "\033[36m%s\033[0m\n" "$*"; }

pass() { green "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { red "  FAIL: $1"; FAIL=$((FAIL + 1)); ERRORS="${ERRORS}\n  - ${1}"; }
skip() { cyan "  SKIP: $1"; SKIP=$((SKIP + 1)); }

# Pod BPP_REQUIRE_DOCKER=1 (ustawiane przez linuksowy job CI, ktory MA dockera)
# brak wymaganego srodowiska to FAIL, nie SKIP — inaczej joby bez dockera
# (macOS/Windows runnery) raportuja zielono praktycznie nic nie asertujac, a
# regresja w renderowaniu nginx/ACME przechodzi niezauwazona.
skip_or_fail() {
    if [ "${BPP_REQUIRE_DOCKER:-0}" = "1" ]; then
        fail "$1 [BPP_REQUIRE_DOCKER=1: wymagane srodowisko niedostepne]"
    else
        skip "$1"
    fi
}

assert_file_exists()    { if [ -f "$2" ]; then pass "$1"; else fail "$1 ($2 not found)"; fi; }
assert_dir_exists()     { if [ -d "$2" ]; then pass "$1"; else fail "$1 ($2 not found)"; fi; }
assert_file_contains()  { if grep -q "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1 (missing '$2')"; fi; }
assert_file_not_contains() { if ! grep -q "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1 (found '$2')"; fi; }
assert_file_not_empty() { if [ -s "$2" ]; then pass "$1"; else fail "$1 ($2 is empty)"; fi; }

# rm -rf z fallbackiem na sudo. Potrzebne po testach uzywajacych docker run,
# ktore zostawiaja pliki nalezace do root (default user w kontenerze) — na
# Linuxie (GHA Ubuntu) host user != root, wiec plain rm dostaje EACCES.
# macOS Docker Desktop user-mapuje volumes wiec rm dziala bez sudo. GHA ma
# passwordless sudo. Lokalnie bez sudo — sudo wisi/faila, fallback na rm
# pokaze oryginalny blad permission denied (degradacja akceptowalna,
# user widzi dlaczego cleanup nie zadzialal).
rm_rf_root() {
    sudo -n rm -rf "$@" 2>/dev/null || rm -rf "$@"
}

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
        skip_or_fail "docker niedostepny — pomijam setup-path (wymaga 'docker' i 'docker compose')"
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
        skip_or_fail "docker niedostepny — pomijam setup-path (wymaga 'docker' i 'docker compose')"
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
    assert_dir_exists "netdata" "$CONFIG_DIR/netdata"
    assert_dir_exists "netdata/go.d" "$CONFIG_DIR/netdata/go.d"
    assert_dir_exists "netdata/health.d" "$CONFIG_DIR/netdata/health.d"
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
    assert_file_exists "netdata.conf" "$CONFIG_DIR/netdata/netdata.conf"
    assert_file_exists "netdata postgres collector" "$CONFIG_DIR/netdata/go.d/postgres.conf"
    assert_file_exists "netdata nginx collector" "$CONFIG_DIR/netdata/go.d/nginx.conf"
    assert_file_exists "netdata web_log collector" "$CONFIG_DIR/netdata/go.d/web_log.conf"
    assert_file_exists "netdata ntfy notify" "$CONFIG_DIR/netdata/health_alarm_notify.conf"
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
    # Zmodyfikuj szablonowe pliki, żeby sprawdzić zachowanie przy re-inicie.
    # UWAGA na dwie klasy plikow:
    #   - FORCE-SYNCOWANE (copy_always): netdata.conf, alloy/config.alloy,
    #     grafana/provisioning/dashboards/*, datasources.yaml.tpl — nadpisywane
    #     ZAWSZE. netdata.conf jest dodatkowo renderowany z .tpl (announce URL),
    #     wiec go tu nie ruszamy.
    #   - copy_if_missing: cala reszta, m.in. health_alarm_notify.conf.
    # Sprawdzamy PO JEDNYM przedstawicielu kazdej klasy.
    echo "# custom alloy config" > "$CONFIG_DIR/alloy/config.alloy"
    echo "# custom netdata notify config" > "$CONFIG_DIR/netdata/health_alarm_notify.conf"

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
    # config.alloy jest FORCE-SYNCOWANY — recznie wpisana tresc MA zniknac.
    # Dwie asercje zamiast jednej: sama nieobecnosc podmienionej tresci przeszlaby
    # takze wtedy, gdyby plik zostal skasowany albo wyzerowany.
    assert_file_not_contains "alloy config force-synced (podmieniona tresc znika)" \
        "# custom alloy config" "$CONFIG_DIR/alloy/config.alloy"
    assert_file_contains "alloy config odtworzony z defaults/" \
        "loki.process" "$CONFIG_DIR/alloy/config.alloy"

    assert_file_contains "netdata config preserved" "# custom netdata notify config" "$CONFIG_DIR/netdata/health_alarm_notify.conf"

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

    for target in up stop health logs db-backup migrate update-configs init-configs \
                  run-with-warning enable-site-down-warning disable-site-down-warning \
                  extend-site-down-warning status-site-down-warning; do
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
# TEST 10a: przerwa techniczna — kontrakty, ktorych nie widac w testach jednostkowych
# ============================================================

# scripts/test-deploy-with-warning.sh sprawdza zachowanie na mockach. Tutaj
# pilnujemy trzech rzeczy, ktore latwo cofnac "porzadkujac" kod, a ktore
# kosztuja awaria produkcyjna.
test_site_down_warning_contract() {
    yellow "=== Test 10a: przerwa techniczna — kontrakty ==="

    local deploy="$REPO_DIR/scripts/deploy-with-warning.sh"
    local warn="$REPO_DIR/scripts/site-down-warning.sh"

    # 1. Bez BPP_SKIP_HEALTH_GATE=1 prompt bramki zdrowia [s]/[d] zawiesza sesje
    #    pod pseudo-TTY screena — przy ZABLOKOWANEJ stronie (kontrakt z CLAUDE.md).
    # shellcheck disable=SC2016  # to WZORZEC grep-a: `$MAKE` ma zostac literalne
    assert_file_contains "sesja wola make run z BPP_SKIP_HEALTH_GATE=1" \
        'BPP_SKIP_HEALTH_GATE=1 "\$MAKE" run' "$deploy"

    # 2. Sonda wsparcia NIE moze byc potokiem do `grep -q`: pod `pipefail`
    #    wczesne zamkniecie potoku przez grep-a daje producentowi SIGPIPE (141),
    #    wiec UDANE dopasowanie zwraca blad. Objaw: losowa cicha degradacja do
    #    deployu bez ostrzezenia.
    if grep -qE 'manage help --commands.*\|.*grep' "$warn"; then
        fail "sonda wsparcia uzywa potoku do grep-a (SIGPIPE + pipefail)"
    else
        pass "sonda wsparcia czyta cale wyjscie przed dopasowaniem"
    fi

    # 3. Heartbeat bez `|| true` — pusty cel jest dla --at-least sukcesem, wiec
    #    niezerowy kod naprawde znaczy "ochrona przerwy przestala dzialac".
    if grep -qE 'extend_countdown --at-least.*\|\| *true' "$warn"; then
        fail "heartbeat wyciszony przez '|| true'"
    else
        pass "heartbeat nie jest wyciszany przez '|| true'"
    fi

    assert_file_contains "heartbeat uzywa --at-least (idempotentna podloga)" \
        'extend_countdown --at-least' "$warn"

    # 4. Blokade zdejmujemy WYLACZNIE po pelnym sukcesie: przerwanie po odcieciu
    #    ma ja zostawic, bo stack jest w nieznanym stanie.
    assert_file_contains "trap rozroznia faze banera i blokady" \
        'blocked)' "$deploy"
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

    for vol in ssl_certs rabbitmq_config grafana_provisioning alloy_config prometheus_data rclone_config; do
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

    # webserver-init MUSI istniec i MUSI poprzedzac webserver.
    #
    # Obraz owasp/modsecurity-crs:nginx startuje nginksa jako uid 101. Swiezy
    # wolumen nazwany Docker tworzy jako root:root, a klucze prywatne powstaja
    # jako root 0600 (openssl i certbot) — bez poprawki uprawnien nginx dostaje
    # [emerg] Permission denied i CALY SERWIS LEZY. Zdarzylo sie na produkcji
    # 2026-08-04 (access log).
    #
    # `scripts/test-waf.sh` sprawdza, ze sam mechanizm wystarcza nginksowi do
    # startu, ale robi to wlasnym `docker run` — nie zauwazylby, gdyby serwis
    # zniknal z compose. Stad te asercje.
    local infra="$REPO_DIR/docker-compose.infrastructure.yml"
    assert_file_contains "webserver-init zadeklarowany" '^  webserver-init:' "$infra"
    assert_file_contains "webserver-init chownuje wolumen access logu" \
        'chown -R nginx:nginx /var/log/nginx-shared' "$infra"
    assert_file_contains "webserver-init naprawia certy manualne" \
        'chown -R 0:nginx /etc/ssl/private' "$infra"
    # `$$d`, nie `$d` — patrz test_compose_shell_vars_escaped. Ta asercja
    # sprawdza tylko, ze krok w ogole istnieje; czy DZIALA (tzn. czy zmienna
    # przezyla interpolacje Compose) weryfikuje dopiero tamten test, bo grep
    # po zrodle YAML-a interpolacji nie widzi.
    # shellcheck disable=SC2016  # to WZORZEC grep-a: `$$d` ma zostac literalne
    assert_file_contains "webserver-init naprawia certy Let's Encrypt" \
        'chgrp -R nginx "\$\$d"' "$infra"
    assert_file_contains "webserver-init dziala jako root" 'user: "0:0"' "$infra"
    assert_file_contains "webserver czeka na webserver-init" \
        'condition: service_completed_successfully' "$infra"

    # Klucz konta ACME NIE moze byc udostepniany nginksowi — mozna nim wystawiac
    # i odwolywac certy. Poprawka obejmuje wylacznie live/ i archive/.
    if grep -q 'chgrp -R nginx /etc/letsencrypt/accounts' "$infra"; then
        fail "webserver-init udostepnia klucz konta ACME (accounts/)"
    else
        pass "webserver-init nie rusza klucza konta ACME"
    fi

    # Bez tego odnowienie certu miedzy restartami zostawiloby klucz nieczytelny
    # dla nginksa i reload odbilby sie o Permission denied — cert wygaslby mimo
    # poprawnego renew.
    assert_file_contains "renew certbota poprawia uprawnienia klucza" \
        'chgrp -R 101 /etc/letsencrypt/live' \
        "$REPO_DIR/docker-compose.application.yml"
    assert_file_contains "letsencrypt.sh ma hook uprawnien" \
        'LE_DEPLOY_HOOK=' "$REPO_DIR/scripts/letsencrypt.sh"

    # Klucz snakeoil nie moze zostac z domyslnym 0600 openssl-a.
    # shellcheck disable=SC2016  # jw. — `$_key` to fragment wzorca, nie zmienna
    assert_file_contains "snakeoil: klucz 0640" \
        'chmod 0640 "\$_key"' "$REPO_DIR/scripts/generate-snakeoil-certs.sh"
}

# ============================================================
# TEST 11a: Compose nie zjada zmiennych shellowych z `command:`
# ============================================================

# Compose interpoluje `$VAR` ZANIM odda string do kontenera i nie odroznia
# zmiennej shella od swojej. `$d` z petli `for d in ...` znika, zostaje pusty
# string — `[ -d "" ]` jest zawsze falszywe, wiec petla za kazdym razem robi
# `continue` i naprawa uprawnien Let's Encrypt CICHO NIE WYKONUJE SIE WCALE.
# `set -e` nic nie zglosi, bo formalnie nic nie zawiodlo.
#
# Objaw widoczny dla operatora: `make up` wypisuje
#   WARN The "d" variable is not set. Defaulting to a blank string.
#
# Ten test celowo patrzy na WYRENDEROWANY `docker compose config`, a nie na
# tekst YAML-a. Asercja po zrodle nie widzi interpolacji — dokladnie dlatego
# poprzednia wersja tego pliku sprawdzala literalne `chgrp -R nginx "$d"`
# i przez caly czas byla zielona przy niedzialajacej funkcji.
test_compose_shell_vars_escaped() {
    yellow "=== Test 11a: interpolacja Compose nie zjada zmiennych shella ==="

    if ! command -v docker >/dev/null 2>&1; then
        skip_or_fail "docker niedostepny — pomijam render compose config"
        return
    fi

    local cfg_dir out err
    cfg_dir=$(mktemp -d)
    out="$cfg_dir/rendered.yml"
    err="$cfg_dir/stderr.txt"

    # Minimalny .env: bez BACKUP_DIR compose wywala sie twardo na spec wolumenu
    # (`invalid spec: :/backup:`) i nie dochodzi do renderowania w ogole.
    printf 'DJANGO_BPP_HOST_BACKUP_DIR=%s\n' "$cfg_dir" > "$cfg_dir/.env"

    if ! (cd "$REPO_DIR" && BPP_CONFIGS_DIR="$cfg_dir" docker compose config \
            > "$out" 2> "$err"); then
        fail "docker compose config nie wyrenderowal sie ($(tail -1 "$err"))"
        rm_rf_root "$cfg_dir"
        return
    fi

    # `docker compose config` re-serializuje wynik jako plik compose, wiec
    # zescapowane `$$` zostaje `$$` (round-trip). Renderowane `$$d` jest wiec
    # dowodem POPRAWNOSCI: gdyby w zrodle bylo `$d`, tu bylby pusty string.
    # shellcheck disable=SC2016  # `$$d` to wzorzec grep-a, ma zostac literalne
    if grep -q '\[ -d "\$\$d" \]' "$out"; then
        pass "webserver-init: zmienna petli \$d przetrwala interpolacje"
    else
        fail "webserver-init: \$d zjedzone przez Compose (brak '[ -d \"\$\$d\" ]')"
    fi

    if grep -q '\[ -d "" \]' "$out"; then
        fail "webserver-init: pusty test katalogu — petla zawsze robi continue"
    else
        pass "webserver-init: brak pustego '[ -d \"\" ]' w komendzie"
    fi

    # Objaw, ktory widzi operator w logu `make up`. Compose bez TTY loguje
    # w logfmt i escape'uje cudzyslowy (`The \"d\" variable`), z TTY nie —
    # wzorzec musi lapac oba warianty, inaczej test przechodzi na zielono
    # przy realnym warningu.
    if grep -Eq 'The \\?"d\\?" variable is not set' "$err"; then
        fail "compose config ostrzega o zmiennej 'd' (niezescapowane \$d)"
    else
        pass "compose config nie ostrzega o zmiennej 'd'"
    fi

    rm_rf_root "$cfg_dir"
}

# ============================================================
# TEST 11b: dashboard WAF-a liczy wylacznie trafienia regul
# ============================================================

test_waf_audit_only_rules() {
    yellow "=== Test 11b: WAF — audit log tylko z trafien regul ==="

    local infra="$REPO_DIR/docker-compose.infrastructure.yml"
    local waf="$REPO_DIR/defaults/grafana/provisioning/dashboards/waf.json"

    # `SecAuditEngine RelevantOnly` loguje transakcje takze wtedy, gdy zadna
    # regula sie nie zapalila — wystarczy, ze status pasuje do
    # SecAuditLogRelevantStatus (domyslnie: kazde 4xx poza 404 i kazde 5xx).
    # Bez nadpisania do audit logu wpadaja 401 z auth_request na panelach,
    # 429 z limit_req i 5xx z lezacego appservera. Produkcja 2026-08-05.
    assert_file_contains "audit log nie loguje po kodzie statusu" \
        'MODSEC_AUDIT_LOG_RELEVANT_STATUS' "$infra"

    # Druga warstwa: nawet gdyby ktos przywrocil domyslna wartosc (to jawny
    # knob w .env), panele nie moga liczyc wpisow bez reguly. Kazde zapytanie
    # po audit logu MUSI miec oba filtry.
    local audyt filtr
    audyt="$(grep -c 'modsec_src = \\"audit\\"' "$waf")"
    filtr="$(grep -c 'modsec_src = \\"audit\\" | modsec_rule_id != \\"\\"' "$waf")"
    if [ "$audyt" -gt 0 ] && [ "$audyt" -eq "$filtr" ]; then
        pass "waf.json: wszystkie $audyt zapytan audytowych filtruja modsec_rule_id"
    else
        fail "waf.json: $filtr z $audyt zapytan audytowych filtruje modsec_rule_id"
    fi
}

# ============================================================
# TEST 11c: WAF — klikalny cross-filtr (regula / atak / IP / sciezka)
# ============================================================
# Istnieje, bo wbudowane "Filter for value" Grafany na tym dashboardzie
# NIE DZIALA i dziala w najgorszy sposob: wywala wszystkie panele naraz.
# Grafana 12.4.2, datasource.ts:
#     addAdHocFilters() -> addLabelToQuery(acc, key, operator, value)
# — bez piatego argumentu `labelType`. A modifyQuery.ts bez niego zgaduje:
#     if (parserPositions.length === 0) return addFilterToStreamSelector(...)
# Nasze zapytania nie maja ani jednego parsera, wiec filtr LADUJE W SELEKTORZE
# STRUMIENIA: {job="docker", service="webserver", modsec_msg="..."}. A pola
# modsec_* to structured metadata (swiadomie — patrz config.alloy: modsec_uri
# x modsec_client jako labele wysadzilyby kardynalnosc indeksu), wiec zaden
# strumien nie pasuje i kazdy panel pokazuje "No data".
# Tego przycisku NIE DA SIE wylaczyc z JSON-a (setDashboardPanelContext.ts
# ustawia onAddAdHocFilter bezwarunkowo; `filterable: false` dotyczy filtra
# kolumny i nic tu nie zmienia). Jedyna obrona to dac operatorowi wlasna,
# dzialajaca sciezke — te zmienne i te data linki.
# ============================================================

test_waf_crossfilter() {
    yellow "=== Test 11c: WAF — klikalny cross-filtr ==="

    local waf="$REPO_DIR/defaults/grafana/provisioning/dashboards/waf.json"

    local v
    for v in rule attack client uri score; do
        assert_file_contains "waf.json: zmienna $v istnieje" "\"name\": \"$v\"" "$waf"
    done

    # `|| true` obowiazkowe pod `set -e` — grep -c przy zerze trafien konczy
    # sie kodem 1 i bez tego wywala CALY zestaw testow zamiast tej asercji.
    local zapytan
    zapytan="$(grep -c '"expr":' "$waf" || true)"

    # modsec_rule_id / _client / _uri / _score Alloy ustawia w OBU blokach
    # structured metadata (audit i nginx), wiec te filtry moga i musza byc
    # w KAZDYM zapytaniu — takze w panelu logow. Brak w jednym = filtr dziala
    # "prawie", co jest gorsze, niz gdyby nie dzialal wcale.
    local f n opis
    # shellcheck disable=SC2016  # to WZORCE grep-a: `$rule` itd. maja zostac literalne
    for f in 'modsec_rule_id =~ \"$rule\"' 'modsec_client =~ \"$client\"' \
             'modsec_uri =~ \"$uri\"' 'modsec_score =~ \"$score\"'; do
        opis="${f%% *}"
        n="$(grep -cF -- "$f" "$waf" || true)"
        if [ "$zapytan" -gt 0 ] && [ "$n" -eq "$zapytan" ]; then
            pass "waf.json: $opis filtrowany w $n z $zapytan zapytan"
        else
            fail "waf.json: $opis filtrowany w $n z $zapytan zapytan"
        fi
    done

    # modsec_attack to ASYMETRIA, nie przeoczenie: do error.log trafiaja
    # wylacznie reguly decyzyjne (949110/959100) z tagiem anomaly-evaluation,
    # wiec blok nginx w config.alloy tego pola NIE USTAWIA. Wpuszczenie
    # $attack do panelu logow oznaczaloby, ze wybor kategorii ataku czysci
    # "Ostatnie trafienia" — czyli dokladnie ten sam objaw, ktory naprawiamy.
    local audyt natt
    audyt="$(grep -cF 'modsec_src = \"audit\"' "$waf" || true)"
    # shellcheck disable=SC2016  # jw. — `$attack` to fragment wzorca, nie zmienna
    natt="$(grep -cF 'modsec_attack =~ \"$attack\"' "$waf" || true)"
    if [ "$audyt" -gt 0 ] && [ "$natt" -eq "$audyt" ]; then
        pass "waf.json: \$attack w $natt z $audyt zapytan audytowych"
    else
        fail "waf.json: \$attack w $natt z $audyt zapytan audytowych"
    fi
    # shellcheck disable=SC2016  # jw. — oba wzorce maja zostac literalne
    if grep -F 'modsec_src = \"nginx\"' "$waf" | grep -qF '$attack'; then
        fail "waf.json: \$attack wpuszczony do panelu logow (nginx nie ma tego pola)"
    else
        pass "waf.json: \$attack trzymany z dala od panelu logow"
    fi

    # PARSER-ZASLEPKA NA KONCU KAZDEGO POTOKU — bez niego wbudowane Grafany
    # "Filter for value" WYWALA CALY DASHBOARD.
    #
    # Grafana 12.4.2, modifyQuery.ts: addLabelToQuery() dostaje od
    # datasource.ts wywolanie BEZ argumentu `labelType`, wiec zgaduje miejsce
    # wstawienia filtra:
    #
    #     if (parserPositions.length === 0) return addFilterToStreamSelector(...)
    #
    # Bez parsera filtr laduje w SELEKTORZE STRUMIENIA:
    # {job="docker", service="webserver", modsec_client="1.2.3.4"} — a modsec_*
    # to structured metadata (swiadomie: modsec_uri x modsec_client jako labele
    # wysadzilyby kardynalnosc indeksu), wiec zaden strumien nie pasuje i KAZDY
    # panel pokazuje "No data". Z parserem trafia do potoku jako label filter
    # i po prostu DZIALA. Zmierzone na stendzie (loki 3.7.1 + grafana 12.4.2,
    # 60 wpisow audytowych): bez parsera 60 -> "No data" i 11 pustych paneli,
    # z parserem 60 -> 20, jeden panel pusty zgodnie z prawda.
    #
    # DLACZEGO AKURAT `logfmt` Z JAWNA ETYKIETA:
    #   - `| pattern "<_>"` Loki ODRZUCA ("at least one capture is required"),
    #   - `| json` wywala __error__ na liniach error.log (nie sa JSON-em),
    #   - gole `| logfmt` przechodzi bez bledu, ale WYCIAGA smieci: na
    #     prawdziwych liniach z tests/fixtures/alloy-loglines.txt byly to
    #     `level`, `msg`, `ts`, `duration`, `___export`, `___plik`. `level`
    #     jest szczegolnie szkodliwy — konkurowalby z `detected_level`, ktorego
    #     jedynym zrodlem ma byc config.alloy (zamkniety slownik 7 wartosci).
    # Jawna etykieta z nieistniejacego klucza nie wyciaga NICZEGO, a `drop`
    # sprzata pusta etykiete, zeby nie zasmiecala panelu logow.
    #
    # POZYCJA JEST ISTOTNA: parser musi byc OSTATNIM ogniwem potoku. Wtedy
    # miele wylacznie linie, ktore przeszly juz przez `modsec_src` i filtry
    # zmiennych — a nie caly strumien webservera.
    local nparser
    nparser="$(grep -cF 'logfmt bpp_noop=\"__bpp_noop__\" | drop bpp_noop' "$waf" || true)"
    if [ "$zapytan" -gt 0 ] && [ "$nparser" -eq "$zapytan" ]; then
        pass "waf.json: parser-zaslepka w $nparser z $zapytan zapytan"
    else
        fail "waf.json: parser-zaslepka w $nparser z $zapytan zapytan (bez niego 'Filter for value' zabija dashboard)"
    fi

    local zle_miejsce
    # shellcheck disable=SC2016  # to WZORZEC grep-a: `$__range`/`$__interval` maja zostac literalne
    zle_miejsce="$(grep '"expr":' "$waf" \
        | grep -cvE 'drop bpp_noop( \[\$__(range|interval)\])?[")]' || true)"
    if [ "$zle_miejsce" -eq 0 ]; then
        pass "waf.json: parser-zaslepka jest ostatnim ogniwem kazdego potoku"
    else
        fail "waf.json: w $zle_miejsce zapytaniach parser-zaslepka nie jest na koncu potoku"
    fi

    local linkow p
    linkow="$(grep -c '"url": "/d/' "$waf" || true)"
    if [ "$linkow" -eq 0 ]; then
        fail "waf.json: brak data linkow na tabelach"
    else
        pass "waf.json: $linkow data linkow na tabelach"
    fi

    # Kazdy data link musi niesc KOMPLET zmiennych, inaczej klik po cichu
    # zresetowalby pozostale filtry. Format :queryparam, NIE recznie sklejone
    # `var-x=${x}` — tylko on poprawnie rozwija zmienne multi-value (na
    # powtorzone `var-x=a&var-x=b`) i tylko on zachowuje stan `$__all`.
    for p in vhost action rule attack client uri score; do
        n="$(grep -oE "\\\$\{$p:queryparam\}|var-$p=" "$waf" | wc -l | tr -d ' ')"
        if [ "$linkow" -gt 0 ] && [ "$n" -eq "$linkow" ]; then
            pass "waf.json: zmienna $p w $n z $linkow linkow"
        else
            fail "waf.json: zmienna $p w $n z $linkow linkow"
        fi
    done

    # REGRESJA: link zaczynajacy sie od "?" GUBI SCIEZKE dashboardu. Wyglada
    # na URL wzgledny (RFC 3986 zachowalby sciezke), ale Grafana nie robi
    # resolucji — podaje string do locationService.push(), a router parsuje
    # "?var-x=1" jako pathname "" i laduje na stronie glownej. Tak wlasnie
    # przez dwa commity nie dzialal cross-filtr na Log Monitoring: asercje
    # sprawdzaly OBECNOSC fragmentu w JSON-ie, nie SKUTEK kliknięcia.
    if grep -q '"url": "?' "$waf"; then
        fail "waf.json: data link zaczyna sie od '?' — zgubi sciezke dashboardu"
    else
        pass "waf.json: data linki niosa sciezke dashboardu"
    fi

    # modsec_uri jest jedynym z tych pol, ktorego wartosc kontroluje ATAKUJACY,
    # a trafia do operatora `=~`. Sciezki skanerow sa pelne metaznakow regexa
    # (`?`, `+`, `.`), wiec link cytuje wartosc literalnie przez \Q...\E.
    # Backslash MUSI byc podwojony (%5C%5C): samo `\Q` LogQL odrzuca
    # ("parse error: invalid char escape"), dopiero `\\Q` przechodzi unquoting
    # i dociera do RE2 jako \Q. Zmierzone na loki 3.7.1: 40/40 linii dla
    # /wp-login.php. ZNANE OGRANICZENIE: sciezka z LITERALNYM backslashem
    # (np. sonda ThinkPHP /index.php?s=index/\think\app/...) wymagalaby
    # podwojenia takze backslashy w wartosci, czego data link Grafany nie
    # potrafi — taki klik wroci pusty. Sciezki z %5C (postac realnie logowana
    # przez ModSecurity) dzialaja normalnie. Reguly/ataki/IP/score sa
    # z zamknietych alfabetow ([0-9], attack-[a-z-], IP) i cytowania nie
    # potrzebuja — dostaja samo :percentencode.
    assert_file_contains "waf.json: link po sciezce cytuje wartosc przez \\\\Q...\\\\E" \
        'var-uri=%5C%5CQ' "$waf"
}

# ============================================================
# TEST: Log Monitoring — filtr ModSecurity we wszystkich panelach
# ============================================================

test_log_monitoring_waf_filter() {
    yellow "=== Test: Log Monitoring — filtr ModSecurity ==="

    local dash="$REPO_DIR/defaults/grafana/provisioning/dashboards/error-monitoring.json"

    # Fragment potoku musi byc w KAZDYM z trzech paneli. Eksport dashboardu
    # z UI Grafany po recznej edycji potrafi zgubic go z jednego — wtedy filtr
    # dziala "prawie", co jest gorsze, niz gdyby nie dzialal wcale.
    # `|| true` jest tu OBOWIAZKOWE: skrypt leci pod `set -e`, a `grep -c`
    # przy zerowej liczbie trafien konczy sie kodem 1 — bez tego przypisanie
    # wywala CALY zestaw testow zamiast pozwolic tej jednej asercji zawiesc.
    local n
    # shellcheck disable=SC2016  # to WZORZEC grep-a: `${waf:raw}` ma zostac literalne
    n="$(grep -cF '${waf:raw}' "$dash" || true)"
    if [ "$n" -eq 3 ]; then
        pass "error-monitoring.json: filtr WAF-a we wszystkich 3 panelach"
    else
        fail "error-monitoring.json: filtr WAF-a w $n z 3 paneli"
    fi

    # Interpolacja MUSI byc przez :raw. Samo $waf przy wlaczonym multi-value
    # zamieniloby `.*` na `\.\*` — zapytanie zostaje skladniowo poprawne,
    # tylko przestaje cokolwiek zwracac. Cicha awaria.
    # shellcheck disable=SC2016  # jw. — `\$waf` to fragment wzorca, nie zmienna
    if grep -q '\$waf[^:]' "$dash"; then
        fail "error-monitoring.json: goly \$waf zamiast \${waf:raw}"
    else
        pass "error-monitoring.json: zmienna waf interpolowana przez :raw"
    fi

    assert_file_contains "zmienna waf istnieje" \
        '"name": "waf"' "$dash"

    # Trzy opcje, bajt w bajt. Zadna nie moze byc pusta — Grafana nie sparsuje
    # opcji `custom` bez wartosci i wstawi do zapytania sam tekst opcji.
    assert_file_contains "opcja 'wszystko' = no-op" \
        'modsec_src=~\\"\.\*\\"' "$dash"
    assert_file_contains "opcja 'tylko WAF' = linia error.log" \
        'modsec_src=\\"nginx\\"' "$dash"
    assert_file_contains "opcja 'bez WAF' = brak klucza" \
        'modsec_src=\\"\\"' "$dash"

    # Ta sama regresja co w waf.json — patrz komentarz przy test_waf_crossfilter.
    # Tu byla realna: linki "?var-service=..." z 989bf83/ef6e8ad przez dwa
    # commity wyrzucaly operatora na strone glowna Grafany zamiast filtrowac.
    if grep -q '"url": "?' "$dash"; then
        fail "error-monitoring.json: data link zaczyna sie od '?' — zgubi sciezke dashboardu"
    else
        pass "error-monitoring.json: data linki niosa sciezke dashboardu"
    fi

    local linkow v n
    linkow="$(grep -c '"url": "/d/' "$dash" || true)"
    if [ "$linkow" -eq 2 ]; then
        pass "error-monitoring.json: $linkow data linki cross-filtra"
    else
        fail "error-monitoring.json: $linkow z 2 data linkow cross-filtra"
    fi
    for v in service container level waf; do
        n="$(grep -oE "\\\$\{$v:queryparam\}|var-$v=" "$dash" | wc -l | tr -d ' ')"
        if [ "$linkow" -gt 0 ] && [ "$n" -eq "$linkow" ]; then
            pass "error-monitoring.json: zmienna $v w $n z $linkow linkow"
        else
            fail "error-monitoring.json: zmienna $v w $n z $linkow linkow"
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
# TEST 16: init-configs w trybie multi-host
# ============================================================
# Gdy DJANGO_BPP_HOSTNAMES jest ustawione w .env, init-configs powinien:
#   - NIE pytac o DJANGO_BPP_HOSTNAME (auto-fill z pierwszego hosta listy)
#   - auto-derive DJANGO_BPP_CSRF_EXTRA_ORIGINS z calej listy
# ============================================================

test_init_configs_multihost_skips_hostname() {
    yellow "=== Test 16: init-configs w trybie multi-host ==="

    setup_temp
    mkdir -p "$CONFIG_DIR"

    # Pierwszy run - generuje fresh .env z single-host (HOSTNAME)
    make -C "$REPO_COPY" init-configs BPP_CONFIGS_DIR="$CONFIG_DIR" >/dev/null 2>&1 \
        || { fail "init-configs (1st run)"; cleanup_temp; return; }

    # Symuluj user-edit: usun HOSTNAME i CSRF, dodaj HOSTNAMES (jak user
    # ktory przeszedl na multi-host i zapomnial/usunal HOSTNAME)
    awk '!/^DJANGO_BPP_HOSTNAME=/ && !/^DJANGO_BPP_CSRF_EXTRA_ORIGINS=/' \
        "$CONFIG_DIR/.env" > "$CONFIG_DIR/.env.tmp"
    mv "$CONFIG_DIR/.env.tmp" "$CONFIG_DIR/.env"
    echo "DJANGO_BPP_HOSTNAMES=alpha.pl,beta.pl,gamma.pl" >> "$CONFIG_DIR/.env"

    # Drugi run z odlaczonym stdin - jakikolwiek prompt by zawiesil albo dostal EOF.
    # Test kluczowy: czy init-configs odpala sie czysto (bez interakcji) i auto-fill.
    if make -C "$REPO_COPY" init-configs BPP_CONFIGS_DIR="$CONFIG_DIR" </dev/null >/dev/null 2>&1; then
        pass "init-configs runs cleanly w trybie multi-host"
    else
        fail "init-configs crashed w trybie multi-host"
        cleanup_temp
        return
    fi

    # HOSTNAME nie moze byc auto-filled w trybie multi-host (Django w bpp
    # czyta ALBO HOSTNAME ALBO HOSTNAMES, oba ustawione = konflikt).
    assert_file_not_contains "HOSTNAME nie auto-filled w multi-host" \
        "^DJANGO_BPP_HOSTNAME=" "$CONFIG_DIR/.env"

    # CSRF powinno byc derived z calej listy (czysto deploy-side default,
    # nie konfliktuje z Django).
    assert_file_contains "CSRF derived ze wszystkich hostow" \
        "^DJANGO_BPP_CSRF_EXTRA_ORIGINS=https://alpha.pl,https://beta.pl,https://gamma.pl$" \
        "$CONFIG_DIR/.env"

    cleanup_temp
}

# ============================================================
# TEST 14: nginx config (legacy single-host + multi-host)
# ============================================================
# Spina oficjalny obraz nginx:1.30.2, mountuje pelen stack templatow
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
        -v "$ngx_dir/conf.d/00-log-format.conf:/etc/nginx/conf.d/00-log-format.conf:ro" \
        -v "$ngx_dir/conf.d/security-headers.conf:/etc/nginx/conf.d/security-headers.conf:ro" \
        -v "$ngx_dir/bpp-templates/_bpp-locations.conf:/etc/nginx/bpp-templates/_bpp-locations.conf:ro" \
        -v "$ngx_dir/bpp-templates/vhost.conf.template:/etc/nginx/bpp-templates/vhost.conf.template:ro" \
        -v "$ngx_dir/entrypoint/30-render-bpp-vhosts.sh:/docker-entrypoint.d/30-render-bpp-vhosts.sh:ro" \
        -v "$ngx_dir/ssl:/etc/ssl/private:ro" \
        -v "$ngx_dir/nginx-shared:/var/log/nginx-shared" \
        -v "$ngx_dir/html/maintenance.html:/usr/share/nginx/html/maintenance.html:ro" \
        -e NGINX_ENVSUBST_FILTER=DJANGO_BPP_ \
        "$@" \
        --entrypoint sh \
        nginx:1.30.2 \
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
        skip_or_fail "docker niedostepny — pomijam nginx -t"
        return
    fi

    local docker_os
    docker_os=$(docker info --format '{{.OSType}}' 2>/dev/null) || true
    if [ -z "$docker_os" ]; then
        skip_or_fail "docker daemon niedostepny — pomijam nginx -t"
        return
    fi
    if [ "$docker_os" != "linux" ]; then
        skip_or_fail "docker daemon w trybie '$docker_os' (nie linux) — pomijam nginx -t"
        return
    fi

    local ngx_dir
    ngx_dir=$(mktemp -d)
    mkdir -p "$ngx_dir/templates" "$ngx_dir/conf.d" \
             "$ngx_dir/bpp-templates" "$ngx_dir/entrypoint" \
             "$ngx_dir/ssl" "$ngx_dir/html" "$ngx_dir/nginx-shared"

    cp "$REPO_DIR/defaults/webserver/default.conf.template" "$ngx_dir/templates/"
    cp "$REPO_DIR/defaults/webserver/00-log-format.conf"    "$ngx_dir/conf.d/"
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
        nginx:1.30.2 \
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
        rm_rf_root "$ngx_dir"
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

    # --- Asercje na ACME location (Let's Encrypt webroot) w port-80 bloku ---
    assert_file_contains "ACME location w vhost (port 80)" \
        "/.well-known/acme-challenge/" "$vhost_tpl"
    assert_file_contains "ACME root /var/www/certbot (vhost)" \
        "/var/www/certbot" "$vhost_tpl"

    # ============================================================
    # 14c-e: SSL_MODE=letsencrypt - resolver cert paths
    # ============================================================
    # Generujemy fejkowe certy LE w letsencrypt/live/<host>/{fullchain,privkey}.pem
    # i sprawdzamy czy 30-render-bpp-vhosts.sh wybiera wlasciwa sciezke
    # (per-host > canonical/SAN > manual fallback).

    # KAZDY scenariusz dostaje WLASNE drzewo katalogow, montowane pod ta sama
    # sciezka w kontenerze. NIE WOLNO tego uproscic do jednego katalogu
    # modyfikowanego miedzy przebiegami (`rm` + kolejny `docker run`) —
    # na macOS (Docker Desktop / OrbStack) cache atrybutow bind-mounta jest
    # WSPOLDZIELONY MIEDZY KONTENERAMI i po usunieciu pliku na hoscie kolejny
    # kontener dostaje NIESWIEZY, pozytywny `stat`:
    #     ls  (readdir) -> katalog pusty      (swieze)
    #     [ -f ] (stat) -> prawda             (z cache)
    #     fopen         -> ENOENT             (prawda o dysku)
    # 30-render-bpp-vhosts.sh wybiera sciezke certu wlasnie przez `[ -f ]`,
    # wiec renderowal LE-owy vhost dla nieistniejacego certu, a `nginx -t`
    # wywracal sie na [emerg] cannot load certificate. Test 14e byl przez to
    # czerwony na macOS i zielony w CI (Linux — bind-mount bez cache'u).
    # Sprawdzone eksperymentalnie 2026-08-05; `sleep` NIE pomaga (cache
    # unieważnia sie przy dostepie, nie po czasie).
    mkdir -p "$ngx_dir/le-per-host/live" "$ngx_dir/le-canonical/live" \
             "$ngx_dir/le-none/live"

    docker run --rm -v "$ngx_dir/le-per-host:/le" --entrypoint sh nginx:1.30.2 -c '
        apt-get update >/dev/null 2>&1 && apt-get install -y openssl >/dev/null 2>&1
        for h in bpp.federacja.pl bpp.wizja.pl bpp.ufam.pl; do
            mkdir -p "/le/live/$h"
            openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
                -keyout "/le/live/$h/privkey.pem" -out "/le/live/$h/fullchain.pem" \
                -subj "/CN=$h" >/dev/null 2>&1
        done
        # openssl leci tu jako ROOT, wiec privkey.pem powstaje z trybem 0600
        # root:root. Kopia host-side ponizej robiona jest jako zwykly user i na
        # LINUKSIE dostaje "cp: cannot open ... privkey.pem: Permission denied".
        # Na macOS (Docker Desktop / OrbStack) bind-mount pokazuje pliki jako
        # wlasnosc uzytkownika hosta, wiec tam przechodzi — ta sama asymetria
        # macOS/Linux, ktora CLAUDE.md opisuje przy uprawnieniach kluczy LE.
        # Certy sa jednorazowe i wyrzucane, wiec rozluznienie trybu jest tu
        # bezpieczne; identyczny zabieg (chmod -R a+rX) robi scripts/test-waf.sh.
        chmod -R a+rX /le
    ' || { fail "stub LE cert generation"; rm_rf_root "$ngx_dir"; return; }

    # Kopia host-side na NOWA sciezke — zaden kontener jej wczesniej nie
    # stat-owal, wiec nie ma czego serwowac z cache'u. `le-none` zostaje puste.
    cp -R "$ngx_dir/le-per-host/live/bpp.federacja.pl" \
          "$ngx_dir/le-canonical/live/bpp.federacja.pl"

    # --- Test 14c: per-host LE certy obecne dla wszystkich hostow ---
    rm -f "$ngx_dir/out"/vhost-*.conf "$ngx_dir/out/rendered-default.conf"
    local out_c
    out_c=$(_run_nginx_t "$ngx_dir" \
        -e DJANGO_BPP_HOSTNAMES="bpp.federacja.pl,bpp.wizja.pl,bpp.ufam.pl" \
        -e DJANGO_BPP_SSL_MODE=letsencrypt \
        -v "$ngx_dir/le-per-host:/etc/letsencrypt:ro" \
        -v "$ngx_dir/out:/out" 2>&1 || true)
    if echo "$out_c" | grep -q "syntax is ok" && echo "$out_c" | grep -q "test is successful"; then
        pass "nginx -t (LE per-host)"
        # Kazdy vhost powinien wskazywac na sciezke LE swojego hosta
        for h in bpp.federacja.pl bpp.wizja.pl bpp.ufam.pl; do
            local vh="$ngx_dir/out/vhost-$h.conf"
            assert_file_contains "vhost $h: ssl_certificate -> /etc/letsencrypt/live/$h/fullchain.pem" \
                "/etc/letsencrypt/live/$h/fullchain.pem" "$vh"
            assert_file_contains "vhost $h: ssl_certificate_key -> /etc/letsencrypt/live/$h/privkey.pem" \
                "/etc/letsencrypt/live/$h/privkey.pem" "$vh"
            assert_file_not_contains "vhost $h: nie uzywa manual cert" \
                "/etc/ssl/private" "$vh"
        done
    else
        fail "nginx -t (LE per-host)"
        printf '    %s\n' "${out_c//$'\n'/$'\n    '}"
    fi

    # --- Test 14d: SAN — tylko canonical (pierwszy host) ma LE cert ---
    # Drzewo `le-canonical` ma WYLACZNIE canonical (przygotowane wyzej, nie
    # przez kasowanie w locie — patrz komentarz o cache'u bind-mounta).
    # Wszystkie 3 vhosty powinny wskazywac na canonical fullchain.
    rm -f "$ngx_dir/out"/vhost-*.conf "$ngx_dir/out/rendered-default.conf"
    local out_d
    out_d=$(_run_nginx_t "$ngx_dir" \
        -e DJANGO_BPP_HOSTNAMES="bpp.federacja.pl,bpp.wizja.pl,bpp.ufam.pl" \
        -e DJANGO_BPP_SSL_MODE=letsencrypt \
        -v "$ngx_dir/le-canonical:/etc/letsencrypt:ro" \
        -v "$ngx_dir/out:/out" 2>&1 || true)
    if echo "$out_d" | grep -q "syntax is ok" && echo "$out_d" | grep -q "test is successful"; then
        pass "nginx -t (LE SAN — canonical only)"
        # Canonical powinien uzywac swojego LE; pozostale 2 fallbackuja na canonical
        assert_file_contains "vhost canonical: LE per-host" \
            "/etc/letsencrypt/live/bpp.federacja.pl/fullchain.pem" \
            "$ngx_dir/out/vhost-bpp.federacja.pl.conf"
        assert_file_contains "vhost wizja: SAN fallback na canonical LE" \
            "/etc/letsencrypt/live/bpp.federacja.pl/fullchain.pem" \
            "$ngx_dir/out/vhost-bpp.wizja.pl.conf"
        assert_file_contains "vhost ufam: SAN fallback na canonical LE" \
            "/etc/letsencrypt/live/bpp.federacja.pl/fullchain.pem" \
            "$ngx_dir/out/vhost-bpp.ufam.pl.conf"
    else
        fail "nginx -t (LE SAN)"
        printf '    %s\n' "${out_d//$'\n'/$'\n    '}"
    fi

    # --- Test 14e: SSL_MODE=letsencrypt ale BRAK LE certow -> fallback manual ---
    # Soft-fallback to manual paths zeby nginx wstal na snakeoil zanim user
    # wystawi LE cert (typowy first-deploy scenariusz).
    # Drzewo `le-none` jest puste OD POCZATKU — celowo, zamiast kasowac certy
    # z drzewa uzytego przez poprzedni kontener (patrz komentarz o cache'u).
    rm -f "$ngx_dir/out"/vhost-*.conf "$ngx_dir/out/rendered-default.conf"
    local out_e
    out_e=$(_run_nginx_t "$ngx_dir" \
        -e DJANGO_BPP_HOSTNAMES="bpp.federacja.pl,bpp.wizja.pl,bpp.ufam.pl" \
        -e DJANGO_BPP_SSL_MODE=letsencrypt \
        -v "$ngx_dir/le-none:/etc/letsencrypt:ro" \
        -v "$ngx_dir/out:/out" 2>&1 || true)
    if echo "$out_e" | grep -q "syntax is ok" && echo "$out_e" | grep -q "test is successful"; then
        pass "nginx -t (LE mode, brak certow -> fallback manual)"
        # Wszystkie vhosty powinny uzywac manual per-host certow ($ngx_dir/ssl/<h>/)
        for h in bpp.federacja.pl bpp.wizja.pl bpp.ufam.pl; do
            assert_file_contains "vhost $h: fallback na manual per-host (mode=letsencrypt, brak LE)" \
                "/etc/ssl/private/$h/cert.pem" "$ngx_dir/out/vhost-$h.conf"
            assert_file_not_contains "vhost $h: nie zostawil LE path" \
                "/etc/letsencrypt/" "$ngx_dir/out/vhost-$h.conf"
        done
    else
        fail "nginx -t (LE mode, fallback manual)"
        printf '    %s\n' "${out_e//$'\n'/$'\n    '}"
    fi

    rm_rf_root "$ngx_dir"
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
        skip_or_fail "docker niedostepny — pomijam runtime"
        return
    fi
    local docker_os
    docker_os=$(docker info --format '{{.OSType}}' 2>/dev/null || true)
    if [ -z "$docker_os" ]; then
        skip_or_fail "docker daemon niedostepny — pomijam runtime"
        return
    fi
    if [ "$docker_os" != "linux" ]; then
        skip_or_fail "docker daemon w trybie '$docker_os' (nie linux) — pomijam runtime"
        return
    fi
    if ! command -v curl >/dev/null 2>&1; then
        skip_or_fail "curl niedostepny — pomijam runtime"
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
        rm_rf_root "$ngx_dir"
    }
    trap _runtime_cleanup RETURN

    # Setup mountow webservera
    mkdir -p "$ngx_dir/templates" "$ngx_dir/conf.d" "$ngx_dir/bpp-templates" \
             "$ngx_dir/entrypoint" "$ngx_dir/ssl" "$ngx_dir/html" "$ngx_dir/nginx-shared"
    cp "$REPO_DIR/defaults/webserver/default.conf.template"   "$ngx_dir/templates/"
    cp "$REPO_DIR/defaults/webserver/00-log-format.conf"      "$ngx_dir/conf.d/"
    cp "$REPO_DIR/defaults/webserver/security-headers.conf"   "$ngx_dir/conf.d/"
    cp "$REPO_DIR/defaults/webserver/_bpp-locations.conf"     "$ngx_dir/bpp-templates/"
    cp "$REPO_DIR/defaults/webserver/vhost.conf.template"     "$ngx_dir/bpp-templates/"
    cp "$REPO_DIR/defaults/webserver/30-render-bpp-vhosts.sh" "$ngx_dir/entrypoint/"
    cp "$REPO_DIR/defaults/webserver/maintenance.html"        "$ngx_dir/html/"
    chmod +x "$ngx_dir/entrypoint/30-render-bpp-vhosts.sh"

    # Generuj certy: legacy ssl/{cert,key}.pem + per-host ssl/<h>/{cert,key}.pem
    docker run --rm -v "$ngx_dir/ssl:/ssl" --entrypoint sh nginx:1.30.2 -c '
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
    # Webroot dla ACME challenge - zawsze mountowany. Pusty dla 15a/15b
    # (curl-e nie probuja ACME). 15c pre-stage-uje plik przed startem nginx-a.
    mkdir -p "$ngx_dir/webroot/.well-known/acme-challenge"

    _runtime_start_nginx() {
        local hostnames="$1" single_host="$2"
        local cid p80 p443
        cid=$(docker run -d --rm --network "$net_name" \
            -p "127.0.0.1:0:80/tcp" \
            -p "127.0.0.1:0:443/tcp" \
            -v "$ngx_dir/templates/default.conf.template:/etc/nginx/templates/default.conf.template:ro" \
            -v "$ngx_dir/conf.d/00-log-format.conf:/etc/nginx/conf.d/00-log-format.conf:ro" \
            -v "$ngx_dir/conf.d/security-headers.conf:/etc/nginx/conf.d/security-headers.conf:ro" \
            -v "$ngx_dir/bpp-templates/_bpp-locations.conf:/etc/nginx/bpp-templates/_bpp-locations.conf:ro" \
            -v "$ngx_dir/bpp-templates/vhost.conf.template:/etc/nginx/bpp-templates/vhost.conf.template:ro" \
            -v "$ngx_dir/entrypoint/30-render-bpp-vhosts.sh:/docker-entrypoint.d/30-render-bpp-vhosts.sh:ro" \
            -v "$ngx_dir/ssl:/etc/ssl/private:ro" \
            -v "$ngx_dir/nginx-shared:/var/log/nginx-shared" \
            -v "$ngx_dir/webroot:/var/www/certbot:ro" \
            -v "$ngx_dir/html/maintenance.html:/usr/share/nginx/html/maintenance.html:ro" \
            -e NGINX_ENVSUBST_FILTER=DJANGO_BPP_ \
            -e DJANGO_BPP_HOSTNAMES="$hostnames" \
            -e DJANGO_BPP_HOSTNAME="$single_host" \
            nginx:1.30.2) || return 1
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

    _runtime_stop_nginx

    # ==== 15c: ACME challenge serwowany z webroot, redirect dla pozostalych ====
    # Krytyczna asercja: location /.well-known/acme-challenge/ jest umieszczony
    # PRZED redirectem na HTTPS (longest-prefix match) i serwuje pliki z
    # webroot zamiast zwracac 301. Bez tego LE-walidacja by nie zadzialala.
    yellow "  -- 15c: ACME challenge serwowany z webroot --"
    # Pre-stage challenge file (reuzywamy nginx_dir/webroot ktory jest mount-em).
    local token="bpp-test-token-$$"
    local content="bpp-test-challenge-content-$$"
    echo -n "$content" > "$ngx_dir/webroot/.well-known/acme-challenge/$token"

    start_out=$(_runtime_start_nginx "" "acme.example.org") || {
        fail "ACME-test nginx nie wstal w 15s"
        return
    }
    read -r nginx_cid port_80 port_443 <<< "$start_out"
    pass "ACME-test nginx wstal"

    # Trzeba podpisac cert dla acme.example.org pod 15a/15b uzywaja innych
    # hostow, wiec generujemy ad-hoc snakeoil w istniejacym ssl/ - ale dla
    # 15c interesuje nas tylko port 80 (HTTP), wiec pomijamy.

    # Krok 1: ACME challenge -> 200 + content
    local probe_url="http://127.0.0.1:$port_80/.well-known/acme-challenge/$token"
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: acme.example.org" "$probe_url" || true)
    if [ "$code" = "200" ]; then
        pass "GET /.well-known/acme-challenge/<token> -> 200 (zamiast 301)"
    else
        fail "ACME challenge: oczekiwane 200, otrzymano '$code'"
    fi
    body=$(curl -s -H "Host: acme.example.org" "$probe_url" || true)
    if [ "$body" = "$content" ]; then
        pass "GET ACME challenge: tresc pasuje do pliku w webroot"
    else
        fail "ACME challenge body: oczekiwano '$content', otrzymano '$body'"
    fi

    # Krok 2: nieistniejacy ACME token -> 404 (location matchuje, plik nie ma)
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: acme.example.org" \
        "http://127.0.0.1:$port_80/.well-known/acme-challenge/missing-$$" || true)
    if [ "$code" = "404" ]; then
        pass "GET /.well-known/acme-challenge/missing -> 404 (NIE 301)"
    else
        fail "ACME missing: oczekiwane 404, otrzymano '$code' (mogl byc 301 jesli location jest po redirecie)"
    fi

    # Krok 3: inne path-e dalej dostaja 301 - location bloku nie zaburzyl reszty
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: acme.example.org" \
        "http://127.0.0.1:$port_80/admin/" || true)
    if [ "$code" = "301" ]; then
        pass "GET /admin/ wciaz dostaje 301 (redirect na HTTPS dziala)"
    else
        fail "GET /admin/: oczekiwane 301, otrzymano '$code'"
    fi

    _runtime_stop_nginx

    # ==== 15d: /.well-known/ przechodzi na HTTPS, ukryte pliki dalej blokowane ====
    # Regresja, ktora juz raz wystapila na produkcji: `location ~ /\.` (blokada
    # plikow ukrytych) to REGEX, a regexy w nginksie maja pierwszenstwo przed
    # zwyklymi prefiksami — wiec przechwytywal /.well-known/ i zwracal 403.
    # Skutek: metadane serwera autoryzacji OAuth (RFC 8414) byly nieosiagalne i
    # discovery klienta MCP padalo przed logowaniem. Lekarstwo to modyfikator
    # `^~`, ktory stawia prefiks PONAD regexami.
    #
    # Ten test pilnuje OBU stron kontraktu naraz — samo "przepusc .well-known"
    # dalo by sie spelnic kasujac blokade plikow ukrytych, co byloby regresja
    # bezpieczenstwa. Dlatego .git/.env musza dalej dostawac 403.
    yellow "  -- 15d: /.well-known/ (OAuth discovery) vs blokada plikow ukrytych --"
    start_out=$(_runtime_start_nginx "" "legacy.example.org") || {
        fail "well-known-test nginx nie wstal w 15s"
        return
    }
    read -r nginx_cid port_80 port_443 <<< "$start_out"

    # Metadane AS MUSZA dojsc do Django (nie 403). Appserver echo-uje Path,
    # wiec sprawdzamy takze, ze sciezka dolecila w calosci — samo 200 moglo by
    # pochodzic z przypadkowego statycznego pliku.
    body=$(curl -sk --resolve "legacy.example.org:$port_443:127.0.0.1" \
        "https://legacy.example.org:$port_443/.well-known/oauth-authorization-server" || true)
    if echo "$body" | grep -q "Path: /.well-known/oauth-authorization-server"; then
        pass "HTTPS /.well-known/oauth-authorization-server -> proxy do appservera"
    else
        fail "well-known OAuth: oczekiwano proxy, otrzymano: $(echo "$body" | head -c 200)"
    fi

    # Blokada plikow ukrytych MUSI przetrwac wyjatek na .well-known.
    #
    # Akceptujemy DWA wyniki, bo `_bpp-locations.conf` ma
    # `error_page 403 = @odrzuc_bez_odpowiedzi` — kazde 403 (i to z `deny all`,
    # i to od ModSecurity) jest zamieniane na 444, czyli zamkniecie polaczenia
    # bez odpowiedzi. curl raportuje wtedy kod `000`. To NIE jest oslabienie
    # blokady, tylko jej wzmocnienie: skaner nie dostaje ani kodu, ani naglowkow.
    # Samo `403` zostaje na liscie na wypadek, gdyby ktos wylaczyl `error_page`.
    #
    # Istotne, ze test dopuszcza `000` DOPIERO tutaj: asercja wyzej sprawdzila,
    # ze ten sam nginx odpowiada 200 na legalna sciezke, wiec `000` nie moze
    # oznaczac "serwer nie wstal".
    for hidden in "/.git/config" "/.env"; do
        code=$(curl -sk -o /dev/null -w '%{http_code}' \
            --resolve "legacy.example.org:$port_443:127.0.0.1" \
            "https://legacy.example.org:$port_443$hidden" || true)
        if [ "$code" = "403" ] || [ "$code" = "000" ]; then
            pass "HTTPS $hidden -> zablokowane (kod '$code')"
        else
            fail "$hidden: oczekiwane 403 lub zerwane polaczenie, otrzymano '$code' (blokada oslabiona!)"
        fi
    done

    # cleanup via trap RETURN
}

# ============================================================
# TEST: configure-resources — staly cap + uslugi zmienne
# ============================================================
# Capy fixed sa niezalezne od RAM hosta, wiec asercja jest deterministyczna
# na kazdym runnerze. Uslugi zmienne sprawdzamy tylko na obecnosc (wartosc
# zalezy od RAM hosta / sciezki overcommit przy <12 GB).
test_configure_resources() {
    echo "TEST: configure-resources — staly cap + uslugi zmienne"
    local cfg
    cfg=$(mktemp -d)
    printf 'BPP_CONFIGS_DIR=%s\n' "$cfg" > "$cfg/.env"

    # 4 zmienne MEM + 7 CPU = 11 promptow; karmimy nadmiarem pustych linii.
    if ! printf '\n%.0s' {1..20} \
        | BPP_CONFIGS_DIR="$cfg" bash "$REPO_DIR/scripts/configure-resources.sh" >/dev/null 2>&1; then
        fail "configure-resources zwrocil blad"
        rm -rf "$cfg"; return
    fi

    assert_file_contains "redis cap 1g"      "REDIS_MEM_LIMIT=1024m"  "$cfg/.env"
    assert_file_contains "alloy cap 192m"    "ALLOY_MEM_LIMIT=192m"   "$cfg/.env"
    assert_file_contains "loki cap 512m"     "LOKI_MEM_LIMIT=512m"    "$cfg/.env"
    assert_file_contains "flower cap 128m"   "FLOWER_MEM_LIMIT=128m"  "$cfg/.env"
    assert_file_contains "netdata cap 320m"  "NETDATA_MEM_LIMIT=320m" "$cfg/.env"
    assert_file_contains "grafana cap 192m"  "GRAFANA_MEM_LIMIT=192m" "$cfg/.env"
    assert_file_contains "dozzle cap 64m"    "DOZZLE_MEM_LIMIT=64m"   "$cfg/.env"
    assert_file_contains "appserver obecny"  "APPSERVER_MEM_LIMIT="   "$cfg/.env"
    assert_file_contains "dbserver obecny"   "DBSERVER_MEM_LIMIT="    "$cfg/.env"
    # Po konsolidacji+renamie: jeden worker `workerserver` -> WORKER_MEM_LIMIT
    # (obie kolejki); stare WORKER_GENERAL_*/WORKER_DENORM_* znikaja.
    assert_file_contains "worker obecny"     "WORKER_MEM_LIMIT="      "$cfg/.env"
    assert_file_not_contains "brak worker-general" "WORKER_GENERAL_MEM_LIMIT=" "$cfg/.env"
    assert_file_not_contains "brak worker-denorm"  "WORKER_DENORM_MEM_LIMIT="  "$cfg/.env"
    assert_file_contains "redis maxmemory 819mb" "REDIS_MAXMEMORY=819mb" "$cfg/.env"
    # CPU pisany tylko dla 6 uslug zmiennych/wybranych; fixed-only nie dostaja CPU.
    assert_file_contains "dbserver CPU obecny"   "DBSERVER_CPU_LIMIT="   "$cfg/.env"
    assert_file_contains "worker CPU obecny"     "WORKER_CPU_LIMIT="     "$cfg/.env"
    assert_file_not_contains "flower bez CPU"    "FLOWER_CPU_LIMIT="     "$cfg/.env"

    rm -rf "$cfg"
}

# ============================================================
# TEST: configure-resources — konsolidacja+rename workerow
# ============================================================
# Stary .env (sprzed konsolidacji) ma WORKER_GENERAL_*/WORKER_DENORM_*. Re-run
# configure-resources zapisuje jeden WORKER_* i usuwa wszystkie stare nazwy.
test_configure_resources_worker_consolidation() {
    echo "TEST: configure-resources — konsolidacja+rename workerow (WORKER_*)"
    local cfg
    cfg=$(mktemp -d)
    {
        printf 'BPP_CONFIGS_DIR=%s\n' "$cfg"
        printf 'WORKER_GENERAL_MEM_LIMIT=1700m\n'
        printf 'WORKER_GENERAL_CPU_LIMIT=2.0\n'
        printf 'WORKER_DENORM_MEM_LIMIT=1500m\n'
        printf 'WORKER_DENORM_CPU_LIMIT=1.0\n'
    } > "$cfg/.env"

    if ! printf '\n%.0s' {1..20} \
        | BPP_CONFIGS_DIR="$cfg" bash "$REPO_DIR/scripts/configure-resources.sh" >/dev/null 2>&1; then
        fail "configure-resources zwrocil blad"
        rm -rf "$cfg"; return
    fi

    assert_file_contains     "nowy WORKER_MEM_LIMIT"     "WORKER_MEM_LIMIT="         "$cfg/.env"
    assert_file_not_contains "stary GENERAL usuniety"    "WORKER_GENERAL_MEM_LIMIT=" "$cfg/.env"
    assert_file_not_contains "stary GENERAL CPU usuniety" "WORKER_GENERAL_CPU_LIMIT=" "$cfg/.env"
    assert_file_not_contains "stary DENORM usuniety"     "WORKER_DENORM_MEM_LIMIT="  "$cfg/.env"
    assert_file_not_contains "stary DENORM CPU usuniety" "WORKER_DENORM_CPU_LIMIT="  "$cfg/.env"

    rm -rf "$cfg"
}

# ============================================================
# TEST: init-configs — ALTCHA (klucz HMAC + flaga captchy) w swiezym .env
# ============================================================
# Captcha zgloszen publikacji jest bezwartosciowa bez losowego klucza HMAC
# (znany klucz => wyzwanie da sie podrobic), wiec swiezy .env musi dostac oba.
test_init_configs_generates_altcha() {
    yellow "=== Test: init-configs generuje ALTCHA_HMAC_KEY + ZGLOS_CAPTCHA_ENABLED ==="

    setup_temp
    mkdir -p "$CONFIG_DIR"

    make -C "$REPO_COPY" init-configs BPP_CONFIGS_DIR="$CONFIG_DIR" >/dev/null 2>&1

    assert_file_contains "ZGLOS_CAPTCHA_ENABLED=1 w .env" \
        "ZGLOS_CAPTCHA_ENABLED=1" "$CONFIG_DIR/.env"

    # `|| true`: pod `set -e` puste grep (=1) ubiloby caly przebieg testow
    # zamiast zaraportowac FAIL ponizej.
    local key
    key=$(grep '^ALTCHA_HMAC_KEY=' "$CONFIG_DIR/.env" | cut -d= -f2 || true)
    # 32 bajty losowe = 64 znaki hex (openssl rand -hex 32).
    if printf '%s' "$key" | grep -qE '^[0-9a-f]{64}$'; then
        pass "ALTCHA_HMAC_KEY to 64 znaki hex"
    else
        fail "ALTCHA_HMAC_KEY to 64 znaki hex (jest: '${key}')"
    fi

    cleanup_temp
}

# ============================================================
# TEST: ensure-config-files — self-heal ALTCHA na starym .env
# ============================================================
# `git pull && make up` na .env sprzed captchy musi zapalic ja bez recznego kroku
# (regula kompatybilnosci wstecznej z CLAUDE.md). Jednoczesnie: klucz nie moze sie
# regenerowac przy kazdym `make up` (rotacja = uniewaznienie wyzwan w locie), a
# swiadome ZGLOS_CAPTCHA_ENABLED=0 musi przezyc upgrade.
# ============================================================
# TEST: retencja Loki — migracja do .env i render z force-syncem
# ============================================================
# local-config.yaml przeszedl z copy_if_missing na render+force-sync. Jedyne,
# co temu do tej pory stalo na przeszkodzie, to retencja per-stream, ktora
# docs/monitoring/logowanie.md wprost kazalo edytowac w tym pliku. Wartosci sa
# teraz w .env, a migracja MUSI je wyluskac ze STAREGO yamla — wpisanie stalej
# z repo po cichu przestawiloby operatorowi retencje przy `git pull && make up`.
# ============================================================

test_rclone_single_source_of_truth() {
    yellow "=== Test: uklad zdalnego backupu ma JEDNO zrodlo prawdy ==="

    # Zachowanie (copy-nie-sync, retencja) pokrywa scripts/test-rclone.sh,
    # ktory odpala prawdziwy backup-cycle.sh z atrapami. Tutaj pilnujemy
    # wylacznie tego, czego uruchomienie skryptu nie widzi: zeby sciezka
    # docelowa nie wrocila do Makefile'a. Do sierpnia 2026 ta sama sklejka
    # "$(date +%Y-%m)/$(date +%d)/" byla wpisana w dwoch miejscach naraz
    # (mk/rclone.mk i backup-cycle.sh) i nic nie pilnowalo ich zgodnosci.
    assert_file_not_contains "mk/rclone.mk nie sklada wlasnej sciezki dziennej" \
        'date +%d' "$REPO_DIR/mk/rclone.mk"
    assert_file_not_contains "mk/rclone.mk nie wola rclone sync" \
        'sync /backup' "$REPO_DIR/mk/rclone.mk"
    assert_file_contains "mk/rclone.mk deleguje do scripts/rclone-sync.sh" \
        'rclone-sync.sh' "$REPO_DIR/mk/rclone.mk"

    assert_file_exists "scripts/lib-rclone.sh istnieje" "$REPO_DIR/scripts/lib-rclone.sh"
    assert_file_exists "scripts/rclone-sync.sh istnieje" "$REPO_DIR/scripts/rclone-sync.sh"

    # Oba miejsca wysylajace na zdalny musza brac katalog z tej samej funkcji.
    local f
    for f in scripts/backup-cycle.sh scripts/rclone-sync.sh; do
        assert_file_contains "$f zrodluje lib-rclone.sh" \
            'lib-rclone.sh' "$REPO_DIR/$f"
        assert_file_contains "$f liczy katalog przez rclone_month_dir" \
            'rclone_month_dir' "$REPO_DIR/$f"
    done

    # scripts/test-rclone.sh musi byc w petli `make test` ORAZ w CI — inaczej
    # pokrycie rozjezdza sie po cichu (ostrzezenie nad targetem `test`).
    assert_file_contains "make test wola test-rclone.sh" \
        'test-rclone.sh' "$REPO_DIR/Makefile"
    assert_file_contains "CI wola test-rclone.sh" \
        'test-rclone.sh' "$REPO_DIR/.github/workflows/ci.yml"

    # `make rclone-config` musi isc przez skrypt, a nie wolac rclone wprost:
    # po kreatorze trzeba jeszcze wyrownac wlasciciela rclone.conf (kontener
    # jest rootem, a przenosiny serwera robi zwykly `rsync` z konta operatora).
    # Sama funkcja jest testowana naprawde w scripts/test-rclone.sh; tutaj
    # pilnujemy tylko, ze nikt nie "uproscil" targetu z powrotem do goleg
    # `docker compose exec ... rclone config`.
    assert_file_exists "scripts/rclone-config.sh istnieje" \
        "$REPO_DIR/scripts/rclone-config.sh"
    assert_file_contains "mk/rclone.mk deleguje do scripts/rclone-config.sh" \
        '/scripts/rclone-config.sh' "$REPO_DIR/mk/rclone.mk"
    assert_file_contains "rclone-config.sh wyrownuje wlasciciela configu" \
        'rclone_fix_config_owner' "$REPO_DIR/scripts/rclone-config.sh"
}

# Wycina blok JEDNEGO serwisu z pliku compose (od "  <svc>:" do nastepnego
# klucza na tym samym wcieciu) i zdejmuje linie komentarzy. Bez tego asercje
# na pliku compose nie umieja pasc: docker-compose.backup.yml jest gesto
# komentowany i te same stringi ('/var/run/docker.sock', 'pipefail') wystepuja
# w komentarzach nad asertowanymi liniami, a wzorce wspolne dla obu serwisow
# ('env_file: ...') trafiaja w sasiedni serwis. Udowodnione mutacyjnie:
# usuniecie mountu socketu, `(set -o pipefail)` z healthchecku i env_file
# z backup-runnera dawalo 0 FAIL na wersji grepujacej caly plik.
svc_block() {
    awk -v s="^  $1:" '$0 ~ s {inb=1; next} inb && /^  [a-z]/ {exit} inb' "$2" \
        | grep -v '^[[:space:]]*#'
}

# Asercja na tresci bloku serwisu (dopasowanie DOSLOWNE, grep -F).
assert_svc_contains() {
    local name="$1" needle="$2" block="$3"
    if printf '%s\n' "$block" | grep -qF -- "$needle"; then pass "$name"
    else fail "$name (brak '$needle' w bloku serwisu, bez komentarzy)"; fi
}

test_backup_runner_is_orchestrator() {
    yellow "=== Test: backup-runner jest orkiestratorem, nie kombajnem ==="

    local yml="$REPO_DIR/docker-compose.backup.yml"

    if grep -qE 'apt-get|apk add' "$yml"; then
        fail "backup-runner nadal doinstalowuje pakiety w runtime"
    else
        pass "backup-runner nie instaluje niczego w runtime"
    fi

    # Wszystkie asercje na bloku serwisu backup-runner BEZ komentarzy
    # (svc_block wyzej) - grep po calym pliku nie umial pasc.
    local runner
    runner="$(svc_block backup-runner "$yml")"
    if [ -z "$runner" ]; then
        fail "svc_block nie znalazl serwisu backup-runner w $yml"
        return
    fi
    pass "svc_block znalazl serwis backup-runner"
    assert_svc_contains "orkiestrator ma docker.sock" \
        '/var/run/docker.sock:/var/run/docker.sock' "$runner"
    assert_svc_contains "orkiestrator ma media do tarowania" \
        'media:/mediaroot:ro' "$runner"
    # Bez tego mountu `[ ! -f "$RCLONE_CONFIG" ]` w kroku 4 cyklu jest prawdziwe
    # ZAWSZE i cykl pada co noc na fail rclone-config-missing 3.
    assert_svc_contains "orkiestrator widzi config rclone (:ro)" \
        '/config/rclone:ro' "$runner"
    assert_svc_contains "orkiestrator dostaje COMPOSE_PROJECT_NAME" \
        'COMPOSE_PROJECT_NAME' "$runner"
    # Bez env_file cykl czyta same defaulty. Najgrozniejsze: operator
    # z DJANGO_BPP_RCLONE_KEEP_MONTHS= (udokumentowany wylacznik) dostaje
    # WLACZONE kasowanie zdalnych kopii. Serwis `rclone` ma wlasny env_file,
    # wiec asercja MUSI byc zakotwiczona w bloku backup-runnera.
    # shellcheck disable=SC2016  # to WZORZEC grep-a: ${...} ma zostac literalne
    assert_svc_contains "orkiestrator ma env_file" \
        'env_file: ${BPP_CONFIGS_DIR}/.env' "$runner"
    assert_svc_contains "healthcheck sonduje socket" 'docker version' "$runner"
    assert_svc_contains "healthcheck sonduje pipefail" '(set -o pipefail)' "$runner"
}

test_rclone_config_mount_writable() {
    yellow "=== Test: config rclone montowany read-write ==="

    # Katalog z rclone.conf NIE moze byc montowany :ro. rclone tego pliku nie
    # tylko czyta:
    #   1. `rclone config` (czyli `make rclone-config`) zapisuje go przez
    #      temp-plik + rename W TYM SAMYM katalogu — przy :ro konfiguracji nie
    #      da sie w ogole utworzyc: kazda odpowiedz w kreatorze konczy sie
    #      "Failed to save config after 10 tries: ... read-only file system",
    #      a kreator mimo to brnie dalej, wiec operator dochodzi do konca i
    #      dopiero potem odkrywa, ze nic nie powstalo.
    #   2. Po kazdym wygasnieciu access-tokenu OAuth rclone dopisuje tam nowy
    #      token — dokumentacja rclone (--config): "the configuration file must
    #      be writable, because rclone needs to update the tokens inside it".
    #      Gdzie refresh-token jest jednorazowy (Box), brak zapisu rozwala
    #      autoryzacje NA TRWALE.
    # Mount byl :ro od pierwszego commita (6514c1a, 2026-04-07), wiec
    # udokumentowany `make rclone-config` nie zadzialal ani razu.
    #
    # Od orkiestratora (Zadanie 3) sa DWA mounty tego samego katalogu w tym
    # pliku: `rclone` (serwis, ktory pisze token/config) ma go RW, a
    # `backup-runner` (orkiestrator, ktory tylko sprawdza `[ -f ... ]` przed
    # wysylka) ma go CELOWO :ro. Sprawdzenie nie moze wiec byc ani blankietowym
    # "nigdzie w pliku nie ma :ro" (legalny mount orkiestratora zapalalby
    # falszywy alarm), ani "gdziekolwiek w pliku jest mount bez :ro" — mutacja
    # ZAMIANY ROL (orkiestrator RW, serwis rclone :ro) przechodzila na zielono,
    # a to jest dokladnie regresja, dla ktorej ten test istnieje. Obie asercje
    # sa wiec kotwiczone w blokach serwisow przez svc_block.
    local yml="$REPO_DIR/docker-compose.backup.yml"

    # shellcheck disable=SC2016  # to WZORZEC grep-a: ${...} ma zostac literalne
    assert_file_contains "config rclone jest montowany" \
        '${BPP_CONFIGS_DIR}/rclone:/config/rclone' "$yml"

    local rclone_svc runner
    rclone_svc="$(svc_block rclone "$yml")"
    runner="$(svc_block backup-runner "$yml")"
    if [ -z "$rclone_svc" ] || [ -z "$runner" ]; then
        fail "svc_block nie znalazl serwisu rclone/backup-runner w $yml"
        return
    fi
    if printf '%s\n' "$rclone_svc" | grep -qE '/config/rclone$'; then
        pass "serwis rclone: config montowany read-write (bez sufiksu :ro)"
    else
        fail "serwis rclone: brak mountu /config/rclone bez :ro — make rclone-config nie zapisze pliku"
    fi
    if printf '%s\n' "$runner" | grep -qF '/config/rclone:ro'; then
        pass "backup-runner: config montowany :ro (zapis robi wylacznie serwis rclone)"
    else
        fail "backup-runner: mount /config/rclone musi miec :ro — orkiestrator tylko sprawdza [ -f ]"
    fi
}

test_rclone_service_declared() {
    yellow "=== Test: rclone jako zadeklarowany serwis compose ==="

    # Obraz uzyty wylacznie w `docker run` bylby (a) sciagany dopiero o 2:30,
    # bo compose ciagnie tylko obrazy zadeklarowanych serwisow, i (b) kasowany
    # przez `docker system prune -af` na koncu `make up`, ktory usuwa obrazy
    # "without at least one container associated to them". Dzialajacy serwis
    # rozwiazuje oba problemy naraz.
    local yml="$REPO_DIR/docker-compose.backup.yml"

    assert_file_contains "serwis rclone zadeklarowany" '^  rclone:' "$yml"
    assert_file_contains "rclone: obraz z domyslna wartoscia" \
        'BPP_RCLONE_IMAGE:-' "$yml"
    assert_file_contains "rclone: restart always (Ofelia potrzebuje celu)" \
        'restart: always' "$yml"
    assert_file_contains "rclone: logging anchor" 'logging: \*default-logging' "$yml"
    assert_file_contains "rclone: montuje skrypty" './scripts:/scripts:ro' "$yml"
    # Sonda CA zostaje mimo ze upstreamowy obraz ja ma: BPP_RCLONE_IMAGE pozwala
    # podstawic dowolny obraz, a CLAUDE.md zakazuje usuwania tego sprawdzenia.
    assert_file_contains "rclone: healthcheck sprawdza bundle CA" \
        'ca-certificates.crt' "$yml"

    assert_file_contains "mk/rclone.mk celuje w serwis rclone" \
        'exec rclone' "$REPO_DIR/mk/rclone.mk"

    # Recepta targetu: linie zaczynajace sie tabem, do pierwszej linii bez taba.
    recipe_of() {
        awk -v t="^$1:" '
            $0 ~ t { inr = 1; next }
            inr && /^\t/ { print; next }
            inr && !/^\t/ { exit }
        ' "$2"
    }

    local mk="$REPO_DIR/mk/rclone.mk"
    local t
    for t in rclone-sync rclone-config rclone-check; do
        if recipe_of "$t" "$mk" | grep -q 'backup-runner'; then
            fail "target $t nadal celuje w backup-runner"
        else
            pass "target $t celuje w serwis rclone"
        fi
    done
    # backup-cycle CELOWO exec-uje w backup-runnerze: to orkiestrator cyklu
    # (docker:cli), ktory pg_dump/rclone/notyfikacje deleguje przez `docker
    # exec`. Przeniesienie targetu do serwisu rclone albo dbservera rozbija
    # cykl (tam nie ma docker.sock ani shima `rclone()`).
    if recipe_of backup-cycle "$mk" | grep -q 'backup-runner'; then
        pass "backup-cycle exec-uje w backup-runnerze (orkiestratorze)"
    else
        fail "backup-cycle nie celuje w backup-runner (orkiestrator cyklu)"
    fi
}

test_backup_pg_image_retired() {
    yellow "=== Test: BPP_BACKUP_PG_IMAGE wygaszona ==="

    # Zmienna byla potrzebna, gdy backup-runner wspoldzielil obraz Postgresa
    # z dbserverem (tryb external: postgres:<major>-alpine). Orkiestrator na
    # docker:cli obrazu Postgresa nie potrzebuje - pg_dump wykonuje przez
    # `docker exec` w dbserverze. Wzorzec martwej flagi jak
    # DJANGO_BPP_ENABLE_HTML2DOCX_IMAGE: przestajemy zapisywac, ale NIE
    # usuwamy ze starych .env i nic sie na nia nie wywraca.
    for f in scripts/init-configs.sh scripts/ensure-config-files.sh; do
        if grep -qE '^[^#]*BPP_BACKUP_PG_IMAGE=' "$REPO_DIR/$f"; then
            fail "$f nadal zapisuje BPP_BACKUP_PG_IMAGE"
        else
            pass "$f nie zapisuje BPP_BACKUP_PG_IMAGE"
        fi
    done
    if grep -q 'BPP_BACKUP_PG_IMAGE' "$REPO_DIR/docker-compose.backup.yml"; then
        fail "compose nadal czyta BPP_BACKUP_PG_IMAGE"
    else
        pass "compose nie czyta BPP_BACKUP_PG_IMAGE"
    fi
}

test_loki_retention_migration() {
    yellow "=== Test: retencja Loki — migracja do .env + render ==="

    local cfg
    cfg=$(mktemp -d)
    mkdir -p "$cfg/loki"

    # Stara instalacja: .env bez LOKI_RETENTION_*, a yaml RECZNIE PRZESTROJONY
    # (mniejszy dysk: 168h zamiast 720h, appserver 999h zamiast 2160h).
    printf 'BPP_CONFIGS_DIR=%s\n' "$cfg" > "$cfg/.env"
    cat > "$cfg/loki/local-config.yaml" <<'YAML'
limits_config:
  retention_period: 168h  # 7 dni - maly dysk
  retention_stream:
    - selector: '{service="appserver"}'
      priority: 1
      period: 999h
    - selector: '{service="dbserver"}'
      priority: 1
      period: 2160h
    - selector: '{service="webserver"}'
      priority: 1
      period: 4320h
YAML

    if ! BPP_CONFIGS_DIR="$cfg" bash "$REPO_DIR/scripts/ensure-config-files.sh" >/dev/null 2>&1; then
        fail "ensure-config-files zwrocil blad (stara instalacja Loki)"
        rm -rf "$cfg"; return
    fi

    assert_file_contains "migracja: LOKI_RETENTION_DEFAULT z yamla (168h, nie 720h)" \
        '^LOKI_RETENTION_DEFAULT=168h$' "$cfg/.env"
    assert_file_contains "migracja: LOKI_RETENTION_APPSERVER z yamla (999h)" \
        '^LOKI_RETENTION_APPSERVER=999h$' "$cfg/.env"
    assert_file_contains "migracja: LOKI_RETENTION_WEBSERVER z yamla (4320h)" \
        '^LOKI_RETENTION_WEBSERVER=4320h$' "$cfg/.env"

    # Render musi ODTWORZYC strojenie operatora, a nie je skasowac.
    assert_file_contains "render: retencja operatora przezyla force-sync" \
        'retention_period: 168h' "$cfg/loki/local-config.yaml"
    assert_file_contains "render: per-stream operatora przezyl force-sync" \
        'period: 999h' "$cfg/loki/local-config.yaml"
    # Zaden placeholder nie moze przeciec do pliku, ktory czyta Loki.
    assert_file_not_contains "render: brak nierozwinietych placeholderow" \
        '__RETENTION_' "$cfg/loki/local-config.yaml"
    # Force-sync ma dowozic RESZTE pliku: klucz dodany w repo po instalacji
    # (tu: wylaczona wbudowana detekcja poziomow) musi sie pojawic.
    assert_file_contains "force-sync: reszta configu dociera na stara instalke" \
        'discover_log_levels: false' "$cfg/loki/local-config.yaml"

    rm -rf "$cfg"

    # Swieza instalacja: brak starego yamla -> wartosci domyslne z repo.
    cfg=$(mktemp -d)
    printf 'BPP_CONFIGS_DIR=%s\n' "$cfg" > "$cfg/.env"
    if ! BPP_CONFIGS_DIR="$cfg" bash "$REPO_DIR/scripts/ensure-config-files.sh" >/dev/null 2>&1; then
        fail "ensure-config-files zwrocil blad (swieza instalacja Loki)"
        rm -rf "$cfg"; return
    fi
    assert_file_contains "swieza instalka: LOKI_RETENTION_DEFAULT=720h" \
        '^LOKI_RETENTION_DEFAULT=720h$' "$cfg/.env"
    assert_file_contains "swieza instalka: render 720h" \
        'retention_period: 720h' "$cfg/loki/local-config.yaml"
    assert_file_contains "swieza instalka: render webserver 4320h" \
        'period: 4320h' "$cfg/loki/local-config.yaml"

    # Idempotencja: drugi przebieg nie przestawia wartosci.
    BPP_CONFIGS_DIR="$cfg" bash "$REPO_DIR/scripts/ensure-config-files.sh" >/dev/null 2>&1 || true
    local n
    n="$(grep -c '^LOKI_RETENTION_DEFAULT=' "$cfg/.env" || true)"
    if [ "$n" -eq 1 ]; then
        pass "LOKI_RETENTION_DEFAULT wystepuje raz po dwoch przebiegach"
    else
        fail "LOKI_RETENTION_DEFAULT wystepuje $n razy po dwoch przebiegach"
    fi

    rm -rf "$cfg"
}

test_ensure_config_files_altcha_selfheal() {
    yellow "=== Test: ensure-config-files dosypuje ALTCHA do starego .env ==="

    local cfg
    cfg=$(mktemp -d)

    # Stary .env: bez ALTCHA_HMAC_KEY i bez ZGLOS_CAPTCHA_ENABLED.
    printf 'BPP_CONFIGS_DIR=%s\nDJANGO_BPP_SECRET_KEY=stary-sekret\n' "$cfg" > "$cfg/.env"

    if ! BPP_CONFIGS_DIR="$cfg" bash "$REPO_DIR/scripts/ensure-config-files.sh" >/dev/null 2>&1; then
        fail "ensure-config-files zwrocil blad (stary .env)"
        rm -rf "$cfg"; return
    fi

    assert_file_contains "self-heal: ZGLOS_CAPTCHA_ENABLED=1" \
        "ZGLOS_CAPTCHA_ENABLED=1" "$cfg/.env"

    local key
    key=$(grep '^ALTCHA_HMAC_KEY=' "$cfg/.env" | cut -d= -f2 || true)
    if printf '%s' "$key" | grep -qE '^[0-9a-f]{64}$'; then
        pass "self-heal: ALTCHA_HMAC_KEY to 64 znaki hex"
    else
        fail "self-heal: ALTCHA_HMAC_KEY to 64 znaki hex (jest: '${key}')"
    fi

    # Idempotencja: drugi przebieg NIE rotuje klucza.
    if ! BPP_CONFIGS_DIR="$cfg" bash "$REPO_DIR/scripts/ensure-config-files.sh" >/dev/null 2>&1; then
        fail "ensure-config-files zwrocil blad (drugi przebieg)"
        rm -rf "$cfg"; return
    fi
    local key2
    key2=$(grep '^ALTCHA_HMAC_KEY=' "$cfg/.env" | cut -d= -f2 || true)
    if [ "$key" = "$key2" ]; then
        pass "ALTCHA_HMAC_KEY stabilny miedzy przebiegami"
    else
        fail "ALTCHA_HMAC_KEY stabilny miedzy przebiegami (zrotowal sie)"
    fi
    # Dokladnie jedna linia z kluczem (brak duplikatu klucza w .env).
    local key_lines
    key_lines=$(grep -c '^ALTCHA_HMAC_KEY=' "$cfg/.env" || true)
    if [ "$key_lines" = "1" ]; then
        pass "ALTCHA_HMAC_KEY wystepuje raz"
    else
        fail "ALTCHA_HMAC_KEY wystepuje raz (jest: $key_lines)"
    fi

    rm -rf "$cfg"

    # Instalacja ktora dostala sam klucz (bpp-deploy generuje go od PR #19), ale
    # nigdy flagi - to najliczniejszy przypadek w praktyce (m.in. staging).
    # Flaga MUSI sie dopisac mimo ze klucz juz istnieje, a klucz zostac nietkniety.
    cfg=$(mktemp -d)
    local stary_klucz="aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff0000000011111111"
    printf 'BPP_CONFIGS_DIR=%s\nALTCHA_HMAC_KEY=%s\n' "$cfg" "$stary_klucz" > "$cfg/.env"

    if ! BPP_CONFIGS_DIR="$cfg" bash "$REPO_DIR/scripts/ensure-config-files.sh" >/dev/null 2>&1; then
        fail "ensure-config-files zwrocil blad (.env z samym kluczem)"
        rm -rf "$cfg"; return
    fi

    assert_file_contains "istniejacy klucz + brak flagi => flaga dopisana" \
        "ZGLOS_CAPTCHA_ENABLED=1" "$cfg/.env"
    assert_file_contains "istniejacy klucz NIE zostal podmieniony" \
        "ALTCHA_HMAC_KEY=$stary_klucz" "$cfg/.env"

    rm -rf "$cfg"

    # Swiadome wylaczenie captchy przez operatora przezywa `make up`.
    cfg=$(mktemp -d)
    printf 'BPP_CONFIGS_DIR=%s\nZGLOS_CAPTCHA_ENABLED=0\n' "$cfg" > "$cfg/.env"

    if ! BPP_CONFIGS_DIR="$cfg" bash "$REPO_DIR/scripts/ensure-config-files.sh" >/dev/null 2>&1; then
        fail "ensure-config-files zwrocil blad (.env z captcha OFF)"
        rm -rf "$cfg"; return
    fi

    assert_file_contains "ZGLOS_CAPTCHA_ENABLED=0 nienaruszone" \
        "ZGLOS_CAPTCHA_ENABLED=0" "$cfg/.env"
    assert_file_not_contains "captcha OFF nie zostala wlaczona" \
        "ZGLOS_CAPTCHA_ENABLED=1" "$cfg/.env"

    rm -rf "$cfg"
}

# ============================================================
# TEST: walidacja sciezki katalogu konfiguracyjnego
#
# Trzy regresje z jednego miejsca (scripts/lib-config-path.sh):
#  1. katalog-rodzenstwo o wspolnym prefiksie nazwy byl odrzucany jako
#     "wewnatrz repozytorium" — wzorzec "$REPO_DIR"* bez ukosnika,
#  2. pod Windows KAZDA sciezka natywna (C:\dane\bpp) nie pasowala do wzorca
#     /*, byla wiec doklejana do $(pwd) — czyli do repozytorium — i odrzucana;
#     przechodzilo wylacznie ".." (istnieje, obsluguje je galaz `cd && pwd`),
#  3. kontrola: katalog naprawde wewnatrz repo ma byc NADAL odrzucany.
#
# Punkt 2 wykonuje sie realnie na runnerze Windows (job test-windows w CI);
# poza nim to samo pokrywa scripts/test-config-path.sh na atrapie cygpath.
# ============================================================

test_init_configs_path_validation() {
    yellow "=== Test: walidacja sciezki katalogu konfiguracyjnego ==="

    setup_temp

    # 1. Rodzenstwo o wspolnym prefiksie: <work>/bpp-deploy-configs lezy OBOK
    #    repozytorium <work>/bpp-deploy, nie w nim.
    #
    #    `pwd -P` jest konieczne, inaczej test jest PUSTY na macOS: init-configs
    #    liczy REPO_DIR z getcwd() (/private/var/...), a $WORK_DIR z mktemp to
    #    /var/... — prefiksy nie maja szans sie pokryc i nawet zepsuta walidacja
    #    przechodzi.
    local work_phys
    work_phys="$(cd "$WORK_DIR" && pwd -P)"
    local sibling="$work_phys/bpp-deploy-configs"
    local out="$WORK_DIR/sibling.log"
    if make -C "$REPO_COPY" init-configs BPP_CONFIGS_DIR="$sibling" >"$out" 2>&1 </dev/null; then
        assert_file_contains "katalog obok repo zapisany w .env" \
            "BPP_CONFIGS_DIR=$sibling" "$REPO_COPY/.env"
    else
        fail "katalog obok repo (wspolny prefiks nazwy) odrzucony: $(tail -3 "$out" | tr '\n' ' ')"
    fi

    # 2. Kontrola: katalog wewnatrz repozytorium nadal odrzucany. Bez tego
    #    asercja z punktu 1 przechodzilaby takze po skasowaniu calej walidacji.
    #
    #    Sciezka WZGLEDNA ("configs") swiadomie — to realna pomylka usera, a
    #    przy okazji jedyna postac odporna na symlinki w $TMPDIR: init-configs
    #    absolutyzuje ja wzgledem wlasnego CWD, wiec obie strony porownania
    #    powstaja tak samo (na macOS /var vs /private/var rozjechaloby sie).
    rm -f "$REPO_COPY/.env"
    out="$WORK_DIR/inside.log"
    if make -C "$REPO_COPY" init-configs BPP_CONFIGS_DIR=configs >"$out" 2>&1 </dev/null; then
        fail "katalog WEWNATRZ repozytorium zostal przyjety"
    else
        assert_file_contains "katalog wewnatrz repo odrzucony" "wewnatrz repozytorium" "$out"
        if [ -f "$REPO_COPY/.env" ]; then
            fail ".env nie powinien powstac po odrzuceniu sciezki"
        else
            pass ".env nie powstal po odrzuceniu sciezki"
        fi
    fi

    # 3. Sciezka w postaci natywnej Windows, podana na stdin jak przez usera.
    rm -f "$REPO_COPY/.env"
    if command -v cygpath >/dev/null 2>&1; then
        local win_cfg
        win_cfg="$(cygpath -w "$WORK_DIR")\\win-instance"
        out="$WORK_DIR/windows.log"
        printf '%s\n' "$win_cfg" | make -C "$REPO_COPY" init-configs >"$out" 2>&1 || true
        assert_file_not_contains "natywna sciezka Windows nie jest brana za wnetrze repo" \
            "wewnatrz repozytorium" "$out"
        assert_dir_exists "katalog z natywnej sciezki Windows utworzony" "$WORK_DIR/win-instance"
    else
        skip "natywna sciezka Windows (C:\\...) — wymaga Git Bash/MSYS2"
    fi

    cleanup_temp
}

# ============================================================
# TEST: install-docker pod Windows (Git Bash) idzie przez wingeta
# ============================================================
#
# Windows jest udawany stubem `cygpath` w PATH (ta sama konwencja co
# scripts/test-config-path.sh), dzieki czemu regresja jest lapana takze na
# Linuksie i macOS — a tam wlasnie chodzi CI.
#
# Sedno kontraktu: galaz windowsowa MUSI wykonac sie PRZED sprawdzeniem
# roota. Test biegnie jako zwykly user, wiec gdyby ktos ja przestawil nizej,
# skrypt skonczylby sie komunikatem o sudo i asercje pojda na czerwono.
test_install_docker_windows() {
    yellow "=== Test: install-docker pod Windows (winget) ==="

    setup_temp

    local stub_bin="$WORK_DIR/stub-bin"
    mkdir -p "$stub_bin"

    cat > "$stub_bin/cygpath" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${@: -1}"
EOF

    # Stub wingeta loguje argumenty, zeby dalo sie zweryfikowac cala komende
    # (w tym --source winget, bez ktorego winget pyta o wybor zrodla).
    cat > "$stub_bin/winget" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK_DIR/winget-args.log"
exit 0
EOF
    # Stub sudo to bezpiecznik, nie asercja: gdyby ktos przestawil galaz
    # windowsowa PO sprawdzeniu roota, skrypt poszedlby w `exec sudo` i na
    # runnerze CI (passwordless sudo) NAPRAWDE zainstalowalby dockera z apt.
    cat > "$stub_bin/sudo" <<'EOF'
#!/usr/bin/env bash
echo "STUB-SUDO: galaz linuksowa nie powinna sie tu wykonac" >&2
exit 1
EOF
    chmod +x "$stub_bin/cygpath" "$stub_bin/winget" "$stub_bin/sudo"

    # PATH bez katalogow systemu operacyjnego poza /usr/bin i /bin — na
    # prawdziwym runnerze Windows odcina to PRAWDZIWEGO wingeta z
    # %LOCALAPPDATA%\Microsoft\WindowsApps, wiec przypadek "brak wingeta"
    # nizej testuje to, co ma testowac, a nie lokalna instalacje.
    local win_path="$stub_bin:/usr/bin:/bin"
    local out="$WORK_DIR/install-docker-win.log"

    if PATH="$win_path" bash "$REPO_COPY/scripts/install-docker.sh" >"$out" 2>&1 </dev/null; then
        pass "install-docker konczy sie sukcesem pod Windows bez roota"
    else
        fail "install-docker pod Windows zwrocil blad: $(tail -3 "$out" | tr '\n' ' ')"
    fi

    assert_file_exists "winget zostal wywolany" "$WORK_DIR/winget-args.log"
    assert_file_contains "winget instaluje Docker.DockerDesktop z -e --source winget" \
        "^install -e --id Docker.DockerDesktop --source winget$" "$WORK_DIR/winget-args.log"

    # Kontrola: galaz linuksowa nie mogla sie zaczac. Gdyby windowsowa stala
    # PO sprawdzeniu roota, dostalibysmy komunikat o sudo zamiast instalacji.
    assert_file_not_contains "pod Windows nie ma proby podbicia uprawnien" "STUB-SUDO" "$out"
    assert_file_not_contains "pod Windows nie rusza apt" "Instaluje Docker dla" "$out"

    # --- Brak wingeta: odsylamy do Instalatora aplikacji w Sklepie ---
    rm -f "$stub_bin/winget"
    out="$WORK_DIR/install-docker-no-winget.log"

    if PATH="$win_path" bash "$REPO_COPY/scripts/install-docker.sh" >"$out" 2>&1 </dev/null; then
        fail "brak wingeta powinien konczyc sie bledem, a skrypt zwrocil sukces"
    else
        pass "brak wingeta konczy sie bledem"
    fi
    assert_file_contains "brak wingeta odsyla do Instalatora aplikacji" \
        "apps.microsoft.com/detail/9nblggh4nns1" "$out"

    cleanup_temp
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
test_site_down_warning_contract
test_compose_bind_mounts
test_compose_shell_vars_escaped
test_waf_audit_only_rules
test_waf_crossfilter
test_log_monitoring_waf_filter
test_env_sample
test_no_scp_in_configs
test_init_configs_multihost_skips_hostname
test_nginx_config_valid
test_nginx_runtime
test_configure_resources
test_configure_resources_worker_consolidation
test_init_configs_generates_altcha
test_loki_retention_migration
test_ensure_config_files_altcha_selfheal
test_init_configs_path_validation
test_install_docker_windows
test_rclone_single_source_of_truth
test_backup_runner_is_orchestrator
test_rclone_config_mount_writable
test_rclone_service_declared
test_backup_pg_image_retired

echo ""
echo "========================================"
if [ "$FAIL" -gt 0 ]; then
    red "  RESULTS: $PASS passed, $FAIL failed, $SKIP skipped"
    echo -e "  Failures:$ERRORS"
    exit 1
else
    green "  RESULTS: $PASS passed, 0 failed, $SKIP skipped"
    if [ "$SKIP" -gt 0 ]; then
        yellow "  (uruchom z BPP_REQUIRE_DOCKER=1, by skipy srodowiskowe traktowac jako FAIL)"
    fi
fi
echo "========================================"

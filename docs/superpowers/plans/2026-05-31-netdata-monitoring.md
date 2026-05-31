# Netdata Monitoring + ntfy.sh Alerts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zastąpić metrykową połowę monitoringu (Prometheus + node-exporter + postgres-exporter) agentem Netdata, dodać alerty push przez ntfy.sh na telefon. Loki + Alloy + Grafana zostają jako stack logowy.

**Architecture:** Jeden kontener `netdata` (oficjalny `netdata/netdata`) auto-wykrywa wszystkie kontenery przez Docker socket, monitoruje Postgresa przez `go.d/postgres` (DSN z istniejących env vars), wysyła alerty na publiczny ntfy.sh przez wbudowany `health_alarm_notify.conf`. UI Netdaty wystawione pod `/netdata/` za istniejącym authserverem (ten sam wzorzec co Grafana). Plan podzielony na **dwie fazy**: faza 1 dodaje Netdatę obok obecnego stacku (bezpiecznie, testowalnie); faza 2 usuwa redundantne Prometheus + exportery dopiero po walidacji fazy 1.

**Tech Stack:**
- `netdata/netdata:v1.99.0` (latest stable, pinned)
- ntfy.sh (publiczny serwer + losowy topic jako sekret)
- Docker Compose v2.20+ (include directive)
- nginx (existing webserver) + authserver (existing Django auth proxy)
- Postgres `pg_monitor` role (read na `pg_stat_*`)

**Test strategy (infra TDD analog):** Dla każdego taska — najpierw "validation command" (jak sprawdzić że jest broken przed zmianą), potem implementacja, potem ten sam command (PASS), commit. Smoke testy wymagają działającej instancji Dockera; gdy brak hosta — pomiń `docker compose up` steps i potwierdź tylko `docker compose config` (parsowanie YAML).

**Critical context:**
- Worktree na `~/Programowanie/bpp-deploy-worktrees/netdata-monitoring`, branch `feat/netdata-monitoring`
- Backwards compat NIENARUSZALNY — patrz `CLAUDE.md` sekcja "Backwards Compatibility and `.env` Migrations". Stary `.env` musi działać po `git pull && make up` bez ręcznej edycji
- `BPP_CONFIGS_DIR` jest poza repo (np. `~/publikacje-uczelnia/`); `defaults/` to template kopiowany przez `ensure-config-files.sh` (copy_if_missing — nie nadpisuje)
- `health_alarm_notify.conf` jest **sourced jako bash** przez agenta — `${NTFY_TOPIC}` w pliku zadziała, ale tylko jeśli zmienna jest w środowisku kontenera
- Postgres collector w trybie **internal** (dbserver w compose): `host=dbserver`. W trybie **external** (`BPP_DATABASE_COMPOSE=docker-compose.database.external.yml`): host z `.env`. **Ten sam DSN dla obu** — bo czerpiemy `${DJANGO_BPP_DB_HOST}` z `.env`, który już jest tam ustawiony per tryb

---

## File Structure

**Created:**
- `defaults/netdata/netdata.conf` — main config: bind 0.0.0.0:19999, registry off, anonymous stats off
- `defaults/netdata/go.d/postgres.conf` — Postgres collector, DSN z env vars
- `defaults/netdata/go.d/nginx.conf` — nginx stub_status (opcjonalny — wymaga zmiany nginx)
- `defaults/netdata/health_alarm_notify.conf` — ntfy konfiguracja (sourced as bash)
- `defaults/netdata/health.d/.gitkeep` — placeholder na przyszłe custom alerty
- `scripts/grant-pg-monitor.sh` — grant `pg_monitor` na rolę BPP w dbserver
- `mk/monitoring.mk` — Make targety: `ntfy-test`, `health-netdata`, `logs-netdata`, `netdata-shell`
- `docs/superpowers/plans/2026-05-31-netdata-monitoring.md` — ten plan

**Modified:**
- `docker-compose.monitoring.yml` — +service `netdata` (faza 1), −services `prometheus`, `node-exporter`, `postgres-exporter` (faza 2), volumes
- `scripts/ensure-config-files.sh` — kopiuje `defaults/netdata/` rekurencyjnie do `BPP_CONFIGS_DIR/netdata/`, tworzy `mkdir -p` dla `health.d/`
- `scripts/init-configs.sh` — generuje `NTFY_TOPIC` (random hex 16) jeśli brak w `.env`; pyta o `DJANGO_BPP_NTFY_SERVER` (default `https://ntfy.sh`); ASCII potwierdzenie po inicjalizacji
- `defaults/webserver/_bpp-locations.conf` — +blok `location /netdata/` z `auth_request`
- `defaults/grafana/provisioning/datasources/datasources.yaml.tpl` — usunąć blok Prometheus (faza 2)
- `Makefile` — `include mk/monitoring.mk` na koniec
- `CLAUDE.md` — Services / Architecture Overview / Monitoring Access / Logging sections

**Untouched (potwierdzić podczas walidacji):** `docker-compose.application.yml`, `docker-compose.workers.yml`, `docker-compose.database.yml`, `docker-compose.infrastructure.yml`, `docker-compose.backup.yml`, `defaults/alloy/`, `defaults/loki/`.

---

## Phase 1 — Add Netdata (no removals)

Po tej fazie repo deploy ma **i** Prometheus stack **i** Netdatę. To pozwala porównać obok siebie i nie tracić obserwowalności, jeśli coś z Netdatą nie zagra.

### Task 1: Dodać Netdata service do compose (bez startowania)

**Files:**
- Modify: `docker-compose.monitoring.yml` (dodać nowy service `netdata` przed `volumes:` na końcu pliku; dodać `netdata_lib` i `netdata_cache` do `volumes:`)

- [ ] **Step 1.1: Validation — sprawdź że netdata jeszcze nie istnieje w compose**

Run:
```bash
docker compose config --services 2>/dev/null | grep -c '^netdata$'
```
Expected: `0` (service nie istnieje przed zmianą).

- [ ] **Step 1.2: Dopisać service `netdata` w `docker-compose.monitoring.yml`**

Wstawić **przed sekcją `volumes:`** (czyli przed linią `volumes:` na końcu pliku) następujący blok (zachowaj wcięcia 2-spacjowe zgodnie z resztą pliku):

```yaml
  netdata:
    image: netdata/netdata:v1.99.0
    container_name: netdata
    hostname: ${DJANGO_BPP_HOSTNAME:-bpp}
    restart: always
    logging: *default-logging
    pid: host
    cap_add:
      - SYS_PTRACE
      - SYS_ADMIN
    security_opt:
      - apparmor:unconfined
    environment:
      # NTFY_TOPIC eksportowany do agenta - health_alarm_notify.conf
      # interpoluje go w `DEFAULT_RECIPIENT_NTFY` (sourced as bash).
      - NTFY_TOPIC=${NTFY_TOPIC}
      - NTFY_SERVER=${DJANGO_BPP_NTFY_SERVER:-https://ntfy.sh}
      # Postgres collector DSN z istniejących zmiennych .env - dziala
      # zarowno w trybie internal (host=dbserver) jak i external
      # (host=external.example.com z .env).
      - PG_USER=${DJANGO_BPP_DB_USER}
      - PG_PASSWORD=${DJANGO_BPP_DB_PASSWORD}
      - PG_HOST=${DJANGO_BPP_DB_HOST}
      - PG_PORT=${DJANGO_BPP_DB_PORT}
      - PG_DB=${DJANGO_BPP_DB_NAME}
      # Wylacz anonimowa telemetrie Netdaty do netdata.cloud.
      - DO_NOT_TRACK=1
      # Bez claimingu - praca w pelni lokalna (bez Netdata Cloud).
      - DISABLE_TELEMETRY=1
    volumes:
      # Configi (bind-mount z BPP_CONFIGS_DIR, RO).
      - ${BPP_CONFIGS_DIR}/netdata/netdata.conf:/etc/netdata/netdata.conf:ro
      - ${BPP_CONFIGS_DIR}/netdata/go.d:/etc/netdata/go.d:ro
      - ${BPP_CONFIGS_DIR}/netdata/health_alarm_notify.conf:/etc/netdata/health_alarm_notify.conf:ro
      - ${BPP_CONFIGS_DIR}/netdata/health.d:/etc/netdata/health.d:ro
      # Persistent state (named volumes).
      - netdata_lib:/var/lib/netdata
      - netdata_cache:/var/cache/netdata
      # Host visibility (RO).
      - /etc/passwd:/host/etc/passwd:ro
      - /etc/group:/host/etc/group:ro
      - /etc/localtime:/etc/localtime:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /etc/os-release:/host/etc/os-release:ro
      - /var/log:/host/var/log:ro
      # Docker socket dla auto-discovery kontenerow + cgroup metryk.
      - /var/run/docker.sock:/var/run/docker.sock:ro
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:19999/api/v1/info"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    deploy:
      resources:
        limits:
          memory: ${NETDATA_MEM_LIMIT:-256m}
          cpus: "${NETDATA_CPU_LIMIT:-1.0}"
```

I dopisać do sekcji `volumes:` na końcu pliku:

```yaml
volumes:
  grafana_data:
  prometheus_data:
  loki_data:
  netdata_lib:
  netdata_cache:
```

- [ ] **Step 1.3: Validation — `docker compose config` parsuje, netdata widoczny**

Run:
```bash
docker compose config --services 2>&1 | grep '^netdata$'
docker compose config 2>&1 | grep -A2 'netdata:' | head -5
```
Expected: linia `netdata`, brak błędów YAML.

Run też:
```bash
docker compose config 2>&1 | grep -E '^\s*-\s+(netdata_lib|netdata_cache):'
```
Expected: dwa wpisy volume.

- [ ] **Step 1.4: Commit**

```bash
git add docker-compose.monitoring.yml
git commit -m "feat(netdata): add netdata service to monitoring compose

Adds netdata agent (v1.99.0) with full host visibility, Docker socket
for container auto-discovery, named volumes for persistent state and
resource limits (256m/1.0 default). Service is added but not yet
started in this commit - configs come in subsequent tasks."
```

---

### Task 2: Dodać defaults/netdata/ z configami

**Files:**
- Create: `defaults/netdata/netdata.conf`
- Create: `defaults/netdata/go.d/postgres.conf`
- Create: `defaults/netdata/health_alarm_notify.conf`
- Create: `defaults/netdata/health.d/.gitkeep`

- [ ] **Step 2.1: Validation — confirm dir does not yet exist**

Run:
```bash
ls -d defaults/netdata 2>/dev/null && echo EXISTS || echo MISSING
```
Expected: `MISSING`.

- [ ] **Step 2.2: Utworzyć `defaults/netdata/netdata.conf`**

Zawartość:
```ini
# Netdata main config.
# Bind do wszystkich interfejsow w sieci Dockera (nginx dosiega
# po nazwie DNS `netdata:19999`). Port nie jest expose-owany na hosta.
[global]
    run as user = netdata
    # Domyslna rozdzielczosc 1s.
    update every = 1
    # Bez wlasnego registry (rzecz dla multi-node deploymentow).
    memory mode = dbengine
    page cache size = 32
    dbengine multihost disk space = 512

[web]
    bind to = 0.0.0.0:19999
    # URL prefix dla reverse-proxy nginx (location /netdata/).
    # Netdata sam obsluzy stripping prefiksu w URL-ach assetow.
    allow connections from = localhost 10.* 172.* 192.168.*
    allow dashboard from = localhost 10.* 172.* 192.168.*
    allow badges from = *
    allow streaming from = *
    allow netdata.conf from = localhost

[registry]
    # Bez globalnej rejestracji - praca pelni lokalna.
    enabled = no

[health]
    enabled = yes
```

- [ ] **Step 2.3: Utworzyć `defaults/netdata/go.d/postgres.conf`**

Zawartość:
```yaml
# Postgres collector - DSN budowany z env vars przekazanych przez
# docker-compose.monitoring.yml. Dziala w obu trybach (internal/external).
update_every: 5
jobs:
  - name: bpp
    dsn: 'postgres://${PG_USER}:${PG_PASSWORD}@${PG_HOST}:${PG_PORT}/${PG_DB}?sslmode=disable'
    timeout: 10
    # collect_databases_matching: '*'  # opcjonalne, domyslnie tylko biezaca DB
```

- [ ] **Step 2.4: Utworzyć `defaults/netdata/health_alarm_notify.conf`**

To jest plik shell-script (sourced jako bash przez agenta). Pelna stockowa wersja ma ~1500 linii — zostawiamy tylko nasz override (Netdata merge'uje z wbudowanym):

```bash
#!/usr/bin/env bash
# Override stockowego health_alarm_notify.conf.
# Wlacza tylko kanal ntfy - reszta wylaczona zeby agent nie probowal
# slack/discord/email-a bez konfiguracji.

# Wylacz wszystkie inne kanaly (whitespace-separated).
SEND_EMAIL="NO"
SEND_PUSHOVER="NO"
SEND_SLACK="NO"
SEND_DISCORD="NO"
SEND_TELEGRAM="NO"
SEND_OPSGENIE="NO"
SEND_PAGERDUTY="NO"
SEND_ROCKETCHAT="NO"
SEND_TWILIO="NO"
SEND_MSTEAM="NO"
SEND_KAVENEGAR="NO"
SEND_PD="NO"
SEND_IRC="NO"
SEND_AWSSNS="NO"
SEND_SYSLOG="NO"
SEND_CUSTOM="NO"

# ntfy.sh - jedyny aktywny kanal.
SEND_NTFY="YES"
# Topic + serwer eksportowane do kontenera w docker-compose.monitoring.yml.
DEFAULT_RECIPIENT_NTFY="${NTFY_SERVER}/${NTFY_TOPIC}"

# Wszystkie role (sysadmin, dba, webmaster, ...) ida na ten sam topic.
# Jesli kiedys bedziesz chciec rozdzielic critical na osobny topic,
# dorzuc tu role_recipients_ntfy[critical]="${NTFY_SERVER}/bpp-crit".
role_recipients_ntfy[sysadmin]="${DEFAULT_RECIPIENT_NTFY}"
role_recipients_ntfy[dba]="${DEFAULT_RECIPIENT_NTFY}"
role_recipients_ntfy[webmaster]="${DEFAULT_RECIPIENT_NTFY}"
role_recipients_ntfy[domainadmin]="${DEFAULT_RECIPIENT_NTFY}"
role_recipients_ntfy[proxyadmin]="${DEFAULT_RECIPIENT_NTFY}"
```

- [ ] **Step 2.5: Utworzyć pusty `defaults/netdata/health.d/.gitkeep`**

Bash:
```bash
mkdir -p defaults/netdata/health.d
touch defaults/netdata/health.d/.gitkeep
```

- [ ] **Step 2.6: Validation — wszystkie pliki istnieją**

Run:
```bash
ls -la defaults/netdata/ defaults/netdata/go.d/ defaults/netdata/health.d/
```
Expected: 4 nowe pliki + katalog `health.d/` z `.gitkeep`.

- [ ] **Step 2.7: Commit**

```bash
git add defaults/netdata/
git commit -m "feat(netdata): add default configs for agent + ntfy notifications

netdata.conf disables registry + binds 0.0.0.0:19999 (reverse-proxied
via nginx /netdata/ - not exposed on host). postgres.conf builds DSN
from \${PG_*} env vars (works for both internal and external DB modes).
health_alarm_notify.conf is shell-sourced override that enables only
ntfy channel and routes all roles to \${NTFY_SERVER}/\${NTFY_TOPIC}."
```

---

### Task 3: Wpiąć netdata w `ensure-config-files.sh` + `init-configs.sh`

**Files:**
- Modify: `scripts/ensure-config-files.sh` (dodać kopiowanie `defaults/netdata/` → `BPP_CONFIGS_DIR/netdata/`)
- Modify: `scripts/init-configs.sh` (dodać generację `NTFY_TOPIC` i `DJANGO_BPP_NTFY_SERVER`)

- [ ] **Step 3.1: Validation — confirm ensure-config-files.sh nie wie o netdata**

Run:
```bash
grep -c 'netdata' scripts/ensure-config-files.sh
```
Expected: `0`.

- [ ] **Step 3.2: Rozszerzyć `scripts/ensure-config-files.sh`**

Po linii `mkdir -p "$BPP_CONFIGS_DIR/grafana/provisioning/dashboards"` (obecnie 42) dodać:

```bash
mkdir -p "$BPP_CONFIGS_DIR/netdata/go.d"
mkdir -p "$BPP_CONFIGS_DIR/netdata/health.d"
```

Po istniejącej pętli `find "$DEFAULTS_DIR/grafana/provisioning"` (kończy się ~linii 75) dodać:

```bash
# Netdata configi (rekursywnie, copy_if_missing).
while IFS= read -r -d '' f; do
    rel="${f#"$DEFAULTS_DIR/netdata/"}"
    dest="$BPP_CONFIGS_DIR/netdata/$rel"
    mkdir -p "$(dirname "$dest")"
    copy_if_missing "$f" "$dest"
done < <(find "$DEFAULTS_DIR/netdata" -type f -print0)
```

- [ ] **Step 3.3: Validation — ensure-config-files dry-run**

Run (wymaga `BPP_CONFIGS_DIR` ustawione i istniejące):
```bash
BPP_CONFIGS_DIR=/tmp/bpp-test-configs mkdir -p /tmp/bpp-test-configs
BPP_CONFIGS_DIR=/tmp/bpp-test-configs bash scripts/ensure-config-files.sh
ls /tmp/bpp-test-configs/netdata/ /tmp/bpp-test-configs/netdata/go.d/
rm -rf /tmp/bpp-test-configs
```
Expected: `netdata.conf`, `health_alarm_notify.conf`, `health.d/`, `go.d/postgres.conf` istnieją w `/tmp/bpp-test-configs/netdata/`.

- [ ] **Step 3.4: Rozszerzyć `scripts/init-configs.sh` o generację `NTFY_TOPIC`**

Znaleźć blok migracji `.env` (wokół linii 580-660 — szukać `ensure_env_var` z innymi zmiennymi).

W sekcji "Nowy plik" (wokół linii 224, po pytaniach o hostname/admin) dodać:

```bash
    # Generuj losowy NTFY_TOPIC (sekret - kto zna URL czyta alerty).
    NTFY_TOPIC_GENERATED="$(openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | xxd -p -c 32)"
```

Następnie w bloku, gdzie zapisuje wstępny `.env` (znajdź `cat > "$ENV_FILE"` lub kolejne `echo "VAR=..." >> "$ENV_FILE"`), dodać linie:

```bash
echo "" >> "$ENV_FILE"
echo "# Netdata + ntfy.sh alerts (push na komorke)" >> "$ENV_FILE"
echo "NTFY_TOPIC=$NTFY_TOPIC_GENERATED" >> "$ENV_FILE"
echo "DJANGO_BPP_NTFY_SERVER=https://ntfy.sh" >> "$ENV_FILE"
echo "" >> "$ENV_FILE"
echo "# Subskrybuj ten topic w aplikacji ntfy na telefonie:" >> "$ENV_FILE"
echo "# https://ntfy.sh/$NTFY_TOPIC_GENERATED" >> "$ENV_FILE"
```

W sekcji "istniejący plik" (część skryptu obsługująca migracje, mniej więcej `if env_has_var "DJANGO_BPP_BACKUP_DIR"` na linii ~581) **przed** ostatnimi liniami sekcji migracji dodać blok:

```bash
# Migracja: dodaj NTFY_TOPIC i DJANGO_BPP_NTFY_SERVER dla istniejacych
# deploymentow (Netdata + ntfy.sh).
if ! env_has_var "NTFY_TOPIC"; then
    _topic="$(openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | xxd -p -c 32)"
    set_env_var "NTFY_TOPIC" "$_topic" \
        "Sekretny topic dla push-alertow Netdaty (subskrybuj w app ntfy)"
    echo "  ! Subskrybuj na telefonie: https://ntfy.sh/$_topic"
fi

ensure_env_var "DJANGO_BPP_NTFY_SERVER" "https://ntfy.sh" "" \
    "Serwer ntfy do alertow (default publiczny ntfy.sh)"
```

- [ ] **Step 3.5: Validation — init-configs.sh migracja na istniejącym `.env`**

Run:
```bash
TEST_DIR=/tmp/bpp-init-test
rm -rf "$TEST_DIR" && mkdir -p "$TEST_DIR"
cat > "$TEST_DIR/.env" <<'EOF'
COMPOSE_PROJECT_NAME=bpp_test
DJANGO_BPP_HOSTNAME=test.example.com
DJANGO_BPP_DB_HOST=dbserver
DJANGO_BPP_DB_PORT=5432
DJANGO_BPP_DB_NAME=bpp
DJANGO_BPP_DB_USER=bpp
DJANGO_BPP_DB_PASSWORD=secret
EOF
# Symulacja init-configs.sh tylko z migracja .env (nie potrzeba prompts)
# - wywolaj recznie sekcje migracji:
BPP_CONFIGS_DIR="$TEST_DIR" bash -c '
    ENV_FILE="$BPP_CONFIGS_DIR/.env"
    source <(sed -n "149,222p" scripts/init-configs.sh)  # helpers
    if ! env_has_var "NTFY_TOPIC"; then
        _topic="$(openssl rand -hex 16)"
        set_env_var "NTFY_TOPIC" "$_topic" "test"
    fi
    grep "^NTFY_TOPIC=" "$ENV_FILE"
'
rm -rf "$TEST_DIR"
```
Expected: `NTFY_TOPIC=<32-hex-chars>` w outpucie.

- [ ] **Step 3.6: Commit**

```bash
git add scripts/ensure-config-files.sh scripts/init-configs.sh
git commit -m "feat(netdata): wire netdata configs into init-configs pipeline

ensure-config-files.sh now recursively copies defaults/netdata/ to
BPP_CONFIGS_DIR/netdata/ (copy_if_missing - non-destructive).
init-configs.sh generates random NTFY_TOPIC (openssl rand -hex 16)
for fresh installs AND migrates existing .env files. Topic is a
secret (anyone with the URL reads alerts), so it's never logged
beyond the one-time setup prompt."
```

---

### Task 4: Dodać nginx `location /netdata/` za authserverem

**Files:**
- Modify: `defaults/webserver/_bpp-locations.conf` (dodać blok po `location /flower/` — okolice linii 245)

- [ ] **Step 4.1: Validation — confirm /netdata/ nie jest jeszcze proxowany**

Run:
```bash
grep -c 'location /netdata/' defaults/webserver/_bpp-locations.conf
```
Expected: `0`.

- [ ] **Step 4.2: Dopisać blok `location /netdata/`**

Po istniejącym bloku `location /flower/` (kończy się na linii ~244 — szukać `}` po `proxy_pass http://$upstream_flower:5555;`), **przed** sekcją `# SECURITY BLOCKS`, dodać:

```nginx

# ============================================================================
# NETDATA PROXY (port 19999)
# ============================================================================
# Uses variables for hostname to defer DNS resolution to request time.
# If netdata service is not running, requests will get 502 instead of
# nginx failing to start.
location /netdata/ {
    # Use Docker's internal DNS resolver (127.0.0.11)
    resolver 127.0.0.11 valid=30s;
    set $upstream_netdata netdata;

    # Require superuser authentication from BPP
    auth_request /_bpp_superuser_auth;

    # Get user info from BPP response headers
    auth_request_set $bpp_user  $upstream_http_x_webauth_user;
    auth_request_set $bpp_email $upstream_http_x_webauth_email;
    auth_request_set $bpp_name  $upstream_http_x_webauth_name;

    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Real-IP $remote_addr;

    # WebSocket support (Netdata uses WS for live charts)
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";

    # Disable buffering for live data streams
    proxy_buffering off;

    # Strip /netdata/ prefix - trailing slash in proxy_pass does the rewrite
    proxy_pass http://$upstream_netdata:19999/;

    # Redirect to BPP login on auth failure
    error_page 401 = @bpp_login;
}
```

- [ ] **Step 4.3: Validation — blok dopisany, składnia nginx parsuje**

Run:
```bash
grep -A2 'location /netdata/' defaults/webserver/_bpp-locations.conf | head -3
```
Expected: trzy linie z `location /netdata/ {` + dwie po.

Jeśli masz lokalnego `nginx -t` lub kontener już chodzi:
```bash
docker compose exec webserver nginx -t 2>&1 | tail -3
```
Expected: `nginx: configuration file ... test is successful`.

- [ ] **Step 4.4: Commit**

```bash
git add defaults/webserver/_bpp-locations.conf
git commit -m "feat(netdata): expose Netdata UI at /netdata/ behind authserver

Same pattern as /grafana/ - auth_request to /_bpp_superuser_auth gates
access, trailing-slash proxy_pass strips the /netdata/ prefix.
WebSocket headers enabled (Netdata uses WS for live charts), buffering
disabled for stream-style data."
```

---

### Task 5: Make targets dla netdata + ntfy

**Files:**
- Create: `mk/monitoring.mk`
- Modify: `Makefile` (dodać `include mk/monitoring.mk`)

- [ ] **Step 5.1: Validation — `make ntfy-test` nie istnieje**

Run:
```bash
grep -rn '^ntfy-test:' mk/ Makefile
```
Expected: brak outputu (exit 1).

- [ ] **Step 5.2: Utworzyć `mk/monitoring.mk`**

Zawartość:
```makefile
# Monitoring helpers (Netdata + ntfy).

.PHONY: ntfy-test health-netdata logs-netdata netdata-shell

NTFY_TOPIC ?= $(shell grep '^NTFY_TOPIC=' $(BPP_CONFIGS_DIR)/.env 2>/dev/null | cut -d= -f2-)
NTFY_SERVER ?= $(shell grep '^DJANGO_BPP_NTFY_SERVER=' $(BPP_CONFIGS_DIR)/.env 2>/dev/null | cut -d= -f2- || echo https://ntfy.sh)

# Wyslij testowe powiadomienie na ntfy - potwierdzenie ze appka na
# telefonie subskrybuje wlasciwy topic i konfiguracja dziala.
ntfy-test:
	@if [ -z "$(NTFY_TOPIC)" ]; then \
		echo "BLAD: NTFY_TOPIC nie ustawione w $(BPP_CONFIGS_DIR)/.env"; \
		echo "      Uruchom: make init-configs"; \
		exit 1; \
	fi
	@echo "Wysylam test na $(NTFY_SERVER)/$(NTFY_TOPIC)"
	@curl -fsSL \
		-H "Title: BPP test notification" \
		-H "Tags: white_check_mark,bpp" \
		-H "Priority: 3" \
		-d "To jest test z make ntfy-test. Jesli to widzisz, alerty dzialaja." \
		"$(NTFY_SERVER)/$(NTFY_TOPIC)" >/dev/null
	@echo "Wyslane. Sprawdz appke ntfy na telefonie."

# Healthcheck endpoint Netdaty (z hosta, przez nginx) - oczekuj 200.
health-netdata:
	@curl -sf -o /dev/null -w "Netdata UI: HTTP %{http_code}\n" \
		http://localhost/netdata/api/v1/info || echo "Netdata niedostepna"
	@docker compose exec -T netdata wget -qO- http://localhost:19999/api/v1/info \
		| head -c 200 && echo ""

# Live logi netdata.
logs-netdata:
	docker compose logs -f --tail=100 netdata

# Shell w kontenerze netdata (debugging).
netdata-shell:
	docker compose exec netdata bash
```

- [ ] **Step 5.3: Dodać include do `Makefile`**

W `Makefile` na końcu (po istniejącym `include mk/remote.mk`, linia 168) dopisać:

```makefile
include mk/monitoring.mk
```

- [ ] **Step 5.4: Validation — `make help` listuje nowe targety**

Run:
```bash
make -n ntfy-test 2>&1 | head -3
```
Expected: brak `*** No rule to make target` (target istnieje, choć wykonanie zatrzymane na `-n`).

- [ ] **Step 5.5: Commit**

```bash
git add mk/monitoring.mk Makefile
git commit -m "feat(netdata): add make targets for ntfy + netdata operations

make ntfy-test  - wysyla test push na topic z .env (potwierdza ze
                  subskrypcja na telefonie dziala)
make health-netdata - curl-uje /netdata/api/v1/info przez nginx i
                      bezposrednio (sanity check)
make logs-netdata / netdata-shell - skroty operacyjne"
```

---

### Task 6: Grant `pg_monitor` dla wewnętrznego dbserver

**Files:**
- Create: `scripts/grant-pg-monitor.sh`
- Modify: `mk/monitoring.mk` (dodać target `grant-pg-monitor`)

- [ ] **Step 6.1: Validation — skrypt nie istnieje**

Run:
```bash
ls scripts/grant-pg-monitor.sh 2>/dev/null && echo EXISTS || echo MISSING
```
Expected: `MISSING`.

- [ ] **Step 6.2: Utworzyć `scripts/grant-pg-monitor.sh`**

Zawartość:
```bash
#!/usr/bin/env bash
# Nadaje role pg_monitor uzytkownikowi BPP w dbserver.
# pg_monitor (built-in od PG 10) daje read na pg_stat_*, pg_stat_database*
# itd. - bez DDL/DML, best-practice dla collectorow monitoringowych.
#
# Idempotentne: GRANT ... TO ... powtorzony nic nie psuje.
# Tryb external: nie dziala (DBA musi grantnac recznie), skrypt to wykryje
# i wyswietli SQL do skopiowania.

set -euo pipefail

: "${BPP_CONFIGS_DIR:?BPP_CONFIGS_DIR not set}"

ENV_FILE="$BPP_CONFIGS_DIR/.env"
[ -f "$ENV_FILE" ] || { echo "BLAD: brak $ENV_FILE"; exit 1; }

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

DB_USER="${DJANGO_BPP_DB_USER:?}"
DB_NAME="${DJANGO_BPP_DB_NAME:?}"

SQL="GRANT pg_monitor TO \"$DB_USER\";"

# Wykryj tryb external - dbserver w external mode nie jest serwisem compose.
if ! docker compose ps --services 2>/dev/null | grep -q '^dbserver$'; then
    echo "Wykryto tryb external (dbserver nie jest w compose)."
    echo ""
    echo "Wykonaj recznie na zewnetrznym serwerze Postgres:"
    echo "  $SQL"
    echo ""
    echo "Bez tego collector Netdaty zglosi 'permission denied for view pg_stat_*'."
    exit 0
fi

echo "Granting pg_monitor TO $DB_USER w dbserver..."
docker compose exec -T dbserver psql -U "$DB_USER" -d "$DB_NAME" -c "$SQL"
echo "OK."
```

- [ ] **Step 6.3: Nadać `+x` i dopisać Make target do `mk/monitoring.mk`**

Bash:
```bash
chmod +x scripts/grant-pg-monitor.sh
```

W `mk/monitoring.mk` dopisać na końcu:
```makefile
# Nadaje role pg_monitor uzytkownikowi BPP (internal) lub wyswietla
# instrukcje (external). Idempotentne.
.PHONY: grant-pg-monitor
grant-pg-monitor:
	@bash scripts/grant-pg-monitor.sh
```

- [ ] **Step 6.4: Validation — skrypt ma `+x`, target istnieje**

Run:
```bash
test -x scripts/grant-pg-monitor.sh && echo OK
grep -c 'grant-pg-monitor:' mk/monitoring.mk
```
Expected: `OK`, `1`.

- [ ] **Step 6.5: Commit**

```bash
git add scripts/grant-pg-monitor.sh mk/monitoring.mk
git commit -m "feat(netdata): script + make target for pg_monitor grant

scripts/grant-pg-monitor.sh detects internal vs external DB mode.
Internal: execs psql in dbserver and runs GRANT pg_monitor.
External: prints the SQL for the DBA to run manually.
Idempotent - GRANT can be re-run safely."
```

---

## Phase 1 milestone: live test

Po fazie 1 user może już uruchomić Netdatę obok istniejącego stacku:

```bash
make update-configs   # kopiuje defaults/netdata/ do BPP_CONFIGS_DIR/netdata/
make init-configs     # dopisuje NTFY_TOPIC do .env
make up               # podnosi netdata + caly stack
make grant-pg-monitor # daje role pg_monitor
make ntfy-test        # potwierdz push na telefon
```

Otwórz `https://<host>/netdata/` (przez authserver) — powinien być dashboard. Otwórz appkę ntfy na telefonie, subskrybuj `https://ntfy.sh/<NTFY_TOPIC z .env>` — powinieneś dostać push z `make ntfy-test`.

**Walidacja przed fazą 2:** zostaw Netdatę chodzącą **co najmniej 24h**. Sprawdź czy:
- Dashboard pokazuje metryki wszystkich kontenerów (appserver, dbserver, redis, workers, grafana, loki, alloy, sama netdata)
- Postgres collector pokazuje `pg_stat_*` (a nie "permission denied")
- Co najmniej jeden alert się odpalił i przyszedł na telefon (np. ręcznie: `stress --cpu 4` na hoście, albo ręczne wypełnienie partycji)
- Loki + Grafana dalej działa (logi przeszukiwalne)

Jeśli wszystko OK — przechodzimy do fazy 2 (usunięcie redundantnego Prometheus stacku). Jeśli nie — STOP, debug, **nie usuwaj Prometheusa**.

---

## Phase 2 — Remove redundant Prometheus stack

### Task 7: Usunąć `prometheus`, `node-exporter`, `postgres-exporter`

**Files:**
- Modify: `docker-compose.monitoring.yml` (usunąć 3 services + volume `prometheus_data`)
- Modify: `defaults/grafana/provisioning/datasources/datasources.yaml.tpl` (usunąć blok Prometheus)
- Modify: `scripts/ensure-config-files.sh` (usunąć `mkdir -p prometheus/` + linię `copy_if_missing prometheus.yml`)

- [ ] **Step 7.1: Validation — confirm services istnieją (przed usunięciem)**

Run:
```bash
docker compose config --services 2>/dev/null | grep -E '^(prometheus|node-exporter|postgres-exporter)$'
```
Expected: 3 linie.

- [ ] **Step 7.2: Usunąć trzy services z `docker-compose.monitoring.yml`**

Z pliku `docker-compose.monitoring.yml` usunąć:
- blok `prometheus:` (linie ~95-115)
- blok `postgres-exporter:` (linie ~117-132)
- blok `node-exporter:` (linie ~134-149)
- w sekcji `volumes:` na końcu pliku usunąć linię `  prometheus_data:`

Po edycji plik `docker-compose.monitoring.yml` powinien zawierać tylko: `dozzle`, `loki`, `grafana`, `alloy`, `netdata`.

- [ ] **Step 7.3: Usunąć Prometheus datasource z Grafana template**

W `defaults/grafana/provisioning/datasources/datasources.yaml.tpl` usunąć blok:

```yaml
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
    jsonData:
      timeInterval: "15s"
```

W bloku `Loki` zmienić `isDefault: false` → `isDefault: true` (żeby Grafana miała jakikolwiek default datasource).

- [ ] **Step 7.4: Wyczyścić `ensure-config-files.sh` z Prometheusa**

Usunąć linię:
```bash
mkdir -p "$BPP_CONFIGS_DIR/prometheus"
```
oraz:
```bash
copy_if_missing "$DEFAULTS_DIR/prometheus/prometheus.yml" "$BPP_CONFIGS_DIR/prometheus/prometheus.yml"
```

**Uwaga**: nie usuwamy `defaults/prometheus/` (zostaje jako artefakt historyczny — gdyby ktoś chciał wrócić). Można usunąć w osobnym commicie później.

- [ ] **Step 7.5: Validation — services zniknęły, compose dalej parsuje**

Run:
```bash
docker compose config --services 2>&1 | grep -E '^(prometheus|node-exporter|postgres-exporter)$' | wc -l
docker compose config 2>&1 | grep -c "BLAD\|ERROR\|error"
```
Expected: `0`, `0`.

Run też:
```bash
docker compose config --services
```
Expected: lista zawiera `netdata`, NIE zawiera `prometheus`, `node-exporter`, `postgres-exporter`.

- [ ] **Step 7.6: Commit**

```bash
git add docker-compose.monitoring.yml defaults/grafana/provisioning/datasources/datasources.yaml.tpl scripts/ensure-config-files.sh
git commit -m "refactor(monitoring): remove prometheus + exporters (replaced by netdata)

Netdata covers host metrics (node-exporter), Postgres stats
(postgres-exporter via go.d/postgres) and own time-series storage
(prometheus). Grafana datasource for Prometheus removed; Loki promoted
to default datasource (only one left).

prometheus_data volume removed - existing volume on running hosts will
be cleaned up by 'make prune-orphan-volumes' next time it runs.

defaults/prometheus/ kept as historical artifact - delete later in
separate commit if no rollback path needed."
```

---

### Task 8: Sprzątanie env vars (resource limits)

**Files:**
- Modify: `scripts/configure-resources.sh` (jeśli ma sekcje dla usuwanych serwisów)

- [ ] **Step 8.1: Validation — znaleźć referencje do usuwanych vars**

Run:
```bash
grep -nE 'PROMETHEUS_MEM_LIMIT|PROMETHEUS_CPU_LIMIT|NODE_EXPORTER|PG_EXPORTER' scripts/*.sh defaults/ Makefile mk/ 2>/dev/null
```
Zapisz wszystkie miejsca — w każdym albo usuwamy, albo zostawiamy z komentarzem (jeśli to skrypt który czyta `.env` i nie ma sensu wywalać).

- [ ] **Step 8.2: Usunąć z `scripts/configure-resources.sh` sekcje dla usuwanych serwisów**

(Jeśli skrypt ma osobne prompty dla `PROMETHEUS_MEM_LIMIT`, `NODE_EXPORTER_*`, `PG_EXPORTER_*` — usunąć je. Jeśli używa pętli — pominąć usunięte serwisy.)

Dodać prompty dla `NETDATA_MEM_LIMIT` (default `256m`) i `NETDATA_CPU_LIMIT` (default `1.0`) — wzorując się na istniejących sekcjach high-risk.

- [ ] **Step 8.3: Validation — referencje wyczyszczone**

Run:
```bash
grep -nE 'PROMETHEUS_MEM_LIMIT|PROMETHEUS_CPU_LIMIT|NODE_EXPORTER|PG_EXPORTER' scripts/configure-resources.sh
```
Expected: brak outputu (lub komentarze tylko).

**Uwaga — backwards compat**: `.env` u usera może mieć `PROMETHEUS_MEM_LIMIT=...` — to OK, Docker Compose ignoruje nieużywane zmienne, nic się nie zepsuje. Nie dodajemy migracji "usuń stare vars" — to nadgorliwość.

- [ ] **Step 8.4: Commit**

```bash
git add scripts/configure-resources.sh
git commit -m "chore(monitoring): drop prometheus/exporter limits, add netdata limits

Old PROMETHEUS_*, NODE_EXPORTER_*, PG_EXPORTER_* env vars are no longer
read by any compose file - they remain harmless in user .env files
(Docker Compose ignores unreferenced vars). No migration needed.

NETDATA_MEM_LIMIT=256m (default), NETDATA_CPU_LIMIT=1.0 - sized for
8GB host baseline like the other high-risk services."
```

---

### Task 9: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md` (sekcje: Services, Logging, Architecture Overview, Monitoring Access, Resource Limits)

- [ ] **Step 9.1: Sekcja "Services" w "Architecture Overview"**

Zmienić podsekcję "Monitoring" z:

```
**Monitoring**: `prometheus` (30d retention), `loki`, `grafana` (auth proxy), `alloy` (log shipping), `postgres-exporter`, `node-exporter`, `dozzle` (path `/dozzle`).
```

na:

```
**Monitoring**: `netdata` (metryki hosta + Dockera + Postgresa, 1s rozdzielczosc, gotowe alerty, push na ntfy.sh - path `/netdata/`), `loki` + `alloy` (zbieranie + retencja logow per service), `grafana` (frontend do Loki + LogQL, path `/grafana/`), `dozzle` (live tail logow kontenerow, path `/dozzle/`).
```

- [ ] **Step 9.2: Sekcja "Monitoring Access"**

Zastąpić:

```
All behind nginx + authserver auth: `https://<domain>/grafana/`, `/flower/`, `/dozzle/`. Prometheus and Loki are not publicly exposed.

For CLI: `make logs-<service>`, `make celery-stats`, `make celery-status`, `make health`, `make ps`.
```

na:

```
All behind nginx + authserver auth: `https://<domain>/netdata/`, `/grafana/`, `/flower/`, `/dozzle/`. Loki is not publicly exposed (queried only via Grafana).

For CLI: `make logs-<service>`, `make logs-netdata`, `make celery-stats`, `make celery-status`, `make health`, `make health-netdata`, `make ps`, `make ntfy-test`.

**Alerty na komorke**: Netdata wysyla push na publiczny ntfy.sh. Topic
(sekret) jest w `${BPP_CONFIGS_DIR}/.env` jako `NTFY_TOPIC`. Subskrybuj
w appce ntfy: `https://ntfy.sh/<NTFY_TOPIC>`. Test: `make ntfy-test`.
```

- [ ] **Step 9.3: Sekcja "Logging" — usunąć retencję Prometheusa**

W bloku tekstowym o retencji Loki, na końcu usunąć linię:

```
Prometheus retention: 30d / 4GB (separate, in `monitoring.yml`).
```

Dodać akapit o Netdata:

```
**Netdata** — tiered retention (ostatnie godziny w 1s, dni w 1m, tygodnie w 1h) w `netdata_lib` volume (~512MB ceiling). Konfig w `${BPP_CONFIGS_DIR}/netdata/netdata.conf`. Alerty wbudowane w agencie - edycja w `health.d/` (path `${BPP_CONFIGS_DIR}/netdata/health.d/`). Push przez `health_alarm_notify.conf` (ntfy.sh, jeden topic per deployment).
```

- [ ] **Step 9.4: Sekcja "Resource Limits"**

W liście "Daemons" zamienić exportery na netdata. Dodać:

```
`netdata` 256m/1.0 (zbiera metryki ~20 kontenerow co 1s; jesli host >16GB i chcesz dluzsza historie, podnies do 512m i `dbengine multihost disk space = 2048` w netdata.conf).
```

Usunąć referencje do `postgres-exporter` / `node-exporter` / `prometheus`.

- [ ] **Step 9.5: Sekcja "Make Targets"**

W liście "Logs" dodać `make logs-netdata`, w "Misc" dodać `make ntfy-test`, `make health-netdata`, `make grant-pg-monitor`.

- [ ] **Step 9.6: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude.md): update monitoring sections for netdata + ntfy

Reflects the new split: netdata = metrics+alerts (replaces prometheus
+ exporters), Loki+Alloy+Grafana = logs only. Adds ntfy.sh phone
push as the alert channel. Updates Make targets list and resource
limits table."
```

---

### Task 10: Walidacja końcowa + smoke test guide

**Files:**
- Read-only validation, jeden commit z drobnym fix-upem jeśli coś wyjdzie

- [ ] **Step 10.1: `docker compose config` parsuje cały stack**

Run (w pełnym repo, z ustawionym `BPP_CONFIGS_DIR`):
```bash
docker compose config --quiet && echo OK || echo BROKEN
```
Expected: `OK`.

- [ ] **Step 10.2: Lista services post-zmianach**

Run:
```bash
docker compose config --services | sort
```
Expected (przy pełnym include): zawiera `netdata`, NIE zawiera `prometheus`, `node-exporter`, `postgres-exporter`.

- [ ] **Step 10.3: Backwards compat — stary `.env` bez `NTFY_TOPIC`**

Run:
```bash
TEST=/tmp/bpp-bc-test
rm -rf "$TEST" && mkdir -p "$TEST"
cat > "$TEST/.env" <<'EOF'
COMPOSE_PROJECT_NAME=bpp_bc
DJANGO_BPP_HOSTNAME=bc.test
BPP_CONFIGS_DIR=/tmp/bpp-bc-test
DJANGO_BPP_DB_HOST=dbserver
DJANGO_BPP_DB_PORT=5432
DJANGO_BPP_DB_NAME=bpp
DJANGO_BPP_DB_USER=bpp
DJANGO_BPP_DB_PASSWORD=secret
EOF
BPP_CONFIGS_DIR="$TEST" docker compose --env-file "$TEST/.env" config --quiet \
    && echo "BC OK (stary .env parsuje)" \
    || echo "BC BROKEN - sprawdz interpolacje NTFY_TOPIC"
rm -rf "$TEST"
```
Expected: `BC OK`. Jeśli broken — w `docker-compose.monitoring.yml` zmienić `${NTFY_TOPIC}` na `${NTFY_TOPIC:-}` w sekcji env netdaty (compose interpolation default).

- [ ] **Step 10.4: Smoke test guide dla usera (dopisać do końca planu)**

Dodać do tego pliku planu na końcu sekcję "User smoke test checklist":

```markdown
### User smoke test (po deployowaniu)

Na hoście z worktree'em `feat/netdata-monitoring`:

1. `make init-configs` — dopisze `NTFY_TOPIC` do `.env`
2. `make update-configs` — kopia `defaults/netdata/` do `BPP_CONFIGS_DIR/netdata/`
3. `make up` — start (lub `make refresh` jesli juz chodzi z stara wersja)
4. `make grant-pg-monitor` — gdy dbserver healthy
5. `make ntfy-test` — push na telefon (jednorazowy test)
6. Otworz `https://<host>/netdata/` w przegladarce (zaloguj sie przez authserver)

Diff vs main: `git diff main..feat/netdata-monitoring --stat`.
Powrot do main: `git checkout main && make refresh`.
```

- [ ] **Step 10.5: Commit (jeśli coś poprawione w 10.3)**

Jeśli step 10.3 wymagał fixu — commit:
```bash
git add docker-compose.monitoring.yml
git commit -m "fix(netdata): default empty NTFY_TOPIC for compose interpolation

Old .env files without NTFY_TOPIC otherwise warn during 'docker compose
config'. Empty default is fine - init-configs.sh fills it in on next run."
```

Jeśli wszystko od razu działa — bez commitu, tylko dopisanie tekstu do planu (commit dokumentacyjny).

---

## Self-Review Checklist (executor reads before starting)

1. **Spec coverage**: każdy element rekomendacji ("Netdata zamiast Prometheusa", "ntfy publiczny", "Grafana = log viewer", "Postgres collector z env vars", "auto-discovery kontenerów") ma swoje zadanie ✓
2. **Phase 1 testability**: po fazie 1 stack jest dalej działający (Netdata DOŁOŻONA, nic nie usunięte). User może żyć tygodniami na fazie 1 zanim odpali fazę 2.
3. **Backwards compat**: brak nowych required vars; `NTFY_TOPIC` ma fallback (default `${NTFY_TOPIC:-}` jeśli step 10.3 ujawni warning) + migrację w `init-configs.sh`. Zgodne z CLAUDE.md sekcja "Backwards Compatibility".
4. **Idempotencja**: `ensure-config-files.sh` używa `copy_if_missing`, `init-configs.sh` używa `env_has_var` przed dopisaniem, `grant-pg-monitor.sh` używa `GRANT` (idempotentny). Wszystko bezpieczne do wielokrotnego wywołania.
5. **Reverse path**: `git checkout main && make refresh` przywraca poprzedni stack (Prometheus stack zostaje w `defaults/prometheus/`, volume `prometheus_data` może być nadal na hoście).

## Risks / Open questions

- **`netdata.conf` `[web].allow_*` zakresy IP**: założyłem `10.* 172.* 192.168.*` dla Docker bridge. Jeśli user ma custom Docker network z innym pulą — Netdata zwróci 403. Workaround: `allow connections from = *` (ale to wystawia agent na cały Docker net wewnętrznie — nie problem skoro nginx i tak gates auth).
- **Netdata v1.99.0**: pinned. Jeśli to nie istnieje na DockerHub w momencie wykonania — bumpnij do najnowszego stable (`netdata/netdata:stable` nie polecane, brak reproducibility).
- **Stary `prometheus_data` volume na hoście**: po fazie 2 zostaje orphan. `make prune-orphan-volumes` go usunie. Nie usuwamy automatycznie — user może chcieć eksport historycznych metryk.
- **`web_log` collector dla nginx access loga**: NIE w tym planie. To osobny ticket — wymaga zmiany nginx (drugi `access_log` do pliku na shared volume + mount do Netdaty). Można zrobić w fazie 3 po stabilizacji.

---

## User smoke test (po deployowaniu)

Na hoście z worktree'em `feat/netdata-monitoring`:

1. `make init-configs` — dopisze `NTFY_TOPIC` do `.env`
2. `make update-configs` — kopia `defaults/netdata/` do `BPP_CONFIGS_DIR/netdata/`
3. `make up` — start (lub `make refresh` jeśli już chodzi)
4. `make grant-pg-monitor` — gdy dbserver healthy
5. `make ntfy-test` — push na telefon (jednorazowy test)
6. Otwórz `https://<host>/netdata/` w przeglądarce (zaloguj się przez authserver)

Diff vs main: `git diff main..feat/netdata-monitoring --stat`.
Powrót do main: `git checkout main && make refresh`.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **Django-based academic publication management system (BPP - Bibliografia Publikacji Pracowników)** deployment configuration. This repository contains Docker Compose orchestration and deployment scripts - the actual Django source code runs inside containers.

**Important**: This is a **deployment configuration repository**, not source code. The Django application lives at `/src/` inside the Docker containers.

## Technology Stack

- **Backend**: Django (Python) with PostgreSQL database
- **Task Queue**: Celery with RabbitMQ broker + specialized denormalization workers
- **Web Server**: Nginx reverse proxy (official nginx image + bind-mounted config)
- **Containerization**: Docker Compose with custom iplweb/* images
- **Scheduling**: Ofelia (Docker-native cron) + Celery Beat
- **Monitoring**: Prometheus + Loki + Grafana stack with custom dashboards
- **Log Processing**: Grafana Alloy with multi-pattern level extraction

## Configuration Architecture

### Modular Docker Compose Structure

The deployment uses Docker Compose **include directive** (requires v2.20+) to split configuration into logical components:

```yaml
docker-compose.yml              # Main orchestration (include + env_file for interpolation)
├── docker-compose.monitoring.yml     # Prometheus, Loki, Grafana, Alloy, exporters
├── docker-compose.database.yml       # PostgreSQL + postgresql_data volume
├── docker-compose.infrastructure.yml # Nginx, Redis, RabbitMQ + infrastructure volumes
├── docker-compose.application.yml    # Django app servers + shared volumes (staticfiles, media)
├── docker-compose.workers.yml        # Celery workers (general, denorm, beat, flower, denorm-queue)
└── docker-compose.backup.yml         # backup-runner (pg_dump + tar media + rclone + Rollbar)
```

**Key Pattern**: Volumes are defined in the file that "owns" them logically, but can be referenced by services in any included file. For example, `staticfiles` and `media` are defined in `application.yml` but referenced by worker services.

**Environment Variable Interpolation**: Each `include` entry has `env_file: ${BPP_CONFIGS_DIR}/.env` which loads deployment-specific variables (DB credentials, hostname, etc.) for `${VAR}` interpolation in included YAML files. `BPP_CONFIGS_DIR` itself is resolved from the repo-local `.env` (read automatically by Docker Compose). This means `docker compose up` works directly without needing `make` to export variables.

### Configuration Directory (`BPP_CONFIGS_DIR`)

Configuration files live **outside the repository** in a separate directory pointed to by `BPP_CONFIGS_DIR` (set in repo `.env`). This directory is created automatically on first `make` run via `init-configs`.

```
$BPP_CONFIGS_DIR/                       # e.g. ~/publikacje-uczelnia/
├── .env                                # Application variables (DB, RabbitMQ, hostname, admin)
├── ssl/
│   ├── key.pem                         # SSL private key
│   └── cert.pem                        # SSL certificate
├── rclone/
│   └── rclone.conf                     # Cloud backup configuration
├── alloy/
│   └── config.alloy                    # Log processing pipeline
├── prometheus/
│   └── prometheus.yml                  # Scrape configs for django, postgres, rabbitmq, node
├── rabbitmq/
│   └── enabled_plugins                 # RabbitMQ plugins configuration
├── grafana/
│   └── provisioning/
│       ├── datasources/
│       │   ├── datasources.yaml.tpl    # Template (envsubst)
│       │   └── datasources.yaml        # Generated from template
│       └── dashboards/
│           ├── dashboards.yaml         # Dashboard provider configuration
│           └── *.json                  # 5 dashboard definitions
```

Config files are bind-mounted directly into containers (no SCP or named volume copying needed).

**Template configs**: `defaults/` in the repo contains default/template versions of config files. These are copied to `BPP_CONFIGS_DIR` during `init-configs` (without overwriting existing files).

### First Run Setup

```bash
make                    # First run: prompts for config directory path,
                        # hostname, admin username/email, Slack webhook,
                        # backup directory, PostgreSQL version for dbserver
                        # (default 16.13 — patrz lista tagow:
                        # https://hub.docker.com/r/iplweb/bpp_dbserver/tags).
                        # Generates random passwords.
                        # Edit $BPP_CONFIGS_DIR/.env
make                    # Second run: starts services normally
```

**Wersja PostgreSQL**: kontener `dbserver` uzywa obrazu
`iplweb/bpp_dbserver:psql-${DJANGO_BPP_POSTGRESQL_VERSION}`. Format wersji
`MAJOR.MINOR` (np. `16.13`, `17.9`, `18.3`). Domyslnie `16.13`. Upgrade majorow
wymaga dump/restore - uzyj `make upgrade-postgres`, nie edytuj recznie zmiennej.
Obok jest `DJANGO_BPP_POSTGRESQL_VERSION_MAJOR` (auto-derived z VERSION) uzywane
przez backup-runnera (`postgres:<major>-alpine` - pg_dump musi byc >= wersji
serwera). W trybie external (`BPP_DATABASE_COMPOSE=docker-compose.database.external.yml`)
obie zmienne zawieraja sam major (sentinel i backup-runner uzywaja tylko majora).

### Monitoring Stack Configuration

#### Prometheus Metrics Collection
Configured to scrape 4 metric endpoints (15s interval):
- **django** (appserver:8000/metrics) - Application metrics
- **postgres** (postgres-exporter:9187) - Database metrics
- **rabbitmq** (rabbitmq:15692) - Message queue metrics
- **node** (node-exporter:9100) - System metrics

#### Grafana Data Sources
Three pre-configured data sources:
1. **Prometheus** (default) - Time-series metrics from all exporters
2. **Loki** - Log aggregation from Docker containers via Alloy
3. **PostgreSQL** - Direct database queries for custom dashboards

#### Grafana Alloy Log Processing
Sophisticated multi-pattern log level extraction pipeline:
- JSON structured logs (level field)
- Key-value format: `level=INFO`
- Python logging: `INFO:module:message`
- Bracketed format: `[ERROR]`
- Python warnings: `UserWarning`, `DeprecationWarning`
- Standalone level words with normalization (WARN→warning, FATAL→error)

Logs are automatically labeled with:
- `container` - Docker container name
- `service` - Docker Compose service name
- `project` - Docker Compose project name
- `detected_level` - Extracted log level

#### Pre-configured Dashboards
Five production-ready Grafana dashboards:
1. **Disk Usage** - Filesystem monitoring
2. **Error Monitoring** - Application error tracking with log level filtering
3. **HTTP Performance** - Request metrics and error rates
4. **PostgreSQL Health** - Database performance and connections
5. **PostgreSQL Maintenance** - Database maintenance metrics

### Volume Distribution Pattern

Named volumes are used for **data only** (not configuration). Config files are bind-mounted from `$BPP_CONFIGS_DIR`.

| File | Named Volumes (data) |
|------|---------------------|
| database.yml | `postgresql_data` |
| infrastructure.yml | `redis`, `rabbitmq_data` |
| application.yml | `staticfiles`, `media` |
| monitoring.yml | `grafana_data`, `prometheus_data`, `loki_data` |
| backup.yml | (no named volumes — backup-runner uses bind-mount from host) |

**Cross-file References**: Services in `workers.yml` reference `staticfiles` and `media` volumes defined in `application.yml`. Docker Compose merges all volume definitions before resolving references.

#### Staticfiles volume — kontrakt z obrazem appservera

Volume `staticfiles` jest wypełniany przez `appserver` (mount `/staticroot`) i serwowany przez `webserver/nginx` (mount `/var/www/html/staticroot`, alias w `defaults/webserver/default.conf.template`). Źródłem jest **pre-populowany katalog w obrazie** — `collectstatic` odpala się przy buildzie obrazu `iplweb/bpp_appserver` (nie na starcie kontenera), wynik ląduje w `/app/staticroot.baked/` wewnątrz obrazu.

Jak to wpada do named volume (gdzie bpp-deploy każe Django pisać przez `STATIC_ROOT=/staticroot/`):

1. **Entrypoint appservera** (`docker/appserver/entrypoint-appserver.sh` w repo `bpp`) przy starcie Phase 2 robi `cp -ru /app/staticroot.baked/. "$STATIC_ROOT/"`.
2. `cp -ru` seeduje świeży (pusty) volume pełnym zestawem plików **i** przy upgrade obrazu dopisuje nowsze pliki bez kasowania istniejących. Docker auto-populate named volume działa tylko przy pierwszym uruchomieniu — ten cp to jego generalizacja.
3. **Runtime nie uruchamia `collectstatic`** — `.baked` to dokładnie ten sam wynik (collectstatic na buildzie ma dostęp do `node_modules`, runtime już nie), więc cp wystarcza. Fallback uruchamia collectstatic tylko przy obrazach sprzed wprowadzenia `.baked`.

**Co to dla deploymentu znaczy**:
- `STATIC_ROOT=/staticroot/` w `.env` (ustawiane przez `init-configs.sh`) — override image default `/app/staticroot`. Entrypoint honoruje `$STATIC_ROOT` i tam kopiuje `.baked`.
- `staticfiles:/staticroot` mount w `docker-compose.application.yml` i `docker-compose.workers.yml` — pusty volume przy pierwszym `make up`, dopełniony przez entrypoint.
- `staticfiles:/var/www/html/staticroot` mount w `docker-compose.infrastructure.yml` (webserver) — nginx widzi ten sam volume pod inną ścieżką i serwuje.
- **Po `make refresh`** (docker compose pull + recreate): volume zostaje, entrypoint robi `cp -ru` → dociąga nowe pliki z nowego obrazu.
- **Po `make prune-orphan-volumes`** lub świeży setup: volume pusty → entrypoint wypełnia od zera z `.baked`.

**Gotcha**: jeśli w starym obrazie (sprzed tej zmiany) pliki leżały w `/app/staticroot` zamiast `.baked`, a nowy entrypoint szuka `.baked` — ochrania nas `if [ -d /app/staticroot.baked ]` w entrypoincie (backward-compat dla obrazów pre-contract). Wersje obrazów bpp i bpp-deploy muszą być bumpowane razem, ale brak `.baked` nie wywala appservera — tylko zostawia volume niepopulowany (trzeba wtedy ręcznie odpalić `collectstatic`).

### Authentication and Security Patterns

#### Grafana Auth Proxy
Grafana uses auth proxy mode, authenticated via nginx + authserver:
- Header-based authentication: `X-WEBAUTH-USER`, `X-WEBAUTH-EMAIL`, `X-WEBAUTH-NAME`
- Auto-signup enabled with Admin role assignment
- Django authserver validates user sessions before proxying

#### Service Healthchecks
Healthchecks are defined either in Docker Compose files or in Docker images (Dockerfile `HEALTHCHECK`).

**Compose-level healthchecks:**
- **authserver**: HTTP check (`curl /health/`)
- **redis**: `redis-cli ping`
- **rabbitmq**: `rabbitmqctl authenticate_user` with credentials
- **grafana**: HTTP check (`wget --spider /api/health`)

**Image-level healthchecks** (defined in Dockerfile, not in compose):
- **dbserver**: PostgreSQL ready check
- **appserver**: HTTP health endpoint
- **workerserver-general**, **workerserver-denorm**: Celery ping

**No healthcheck:**
- **denorm-queue**: healthcheck commented out in compose (was `pgrep -f denorm_queue`)

**Important**: Double-dollar escaping (e.g. `$$RABBITMQ_DEFAULT_USER`) is required in Docker Compose healthcheck commands to prevent premature variable expansion by Compose.

### Log Management Strategy

**Reduced Logging**: Most services configured with `warn` or `error` log levels to reduce noise:
- Prometheus: `--log.level=warn`
- Loki: `-log.level=warn`
- Grafana: `GF_LOG_LEVEL=error`
- RabbitMQ: Error-level logging for connections, channels, mirroring
- Alloy: `level = "warn"`

#### Docker log driver — rotacja lokalna

Wszystkie serwisy stacka używają drivera `local` (binarny, skompresowany zstd, ~2–4× mniejszy niż `json-file`). Konfiguracja jest zdefiniowana przez wspólny YAML anchor `x-logging` na górze każdego z compose'ów:

```yaml
x-logging: &default-logging
  driver: "local"
  options:
    max-size: "${LOG_MAX_SIZE:-150m}"
    max-file: "${LOG_MAX_FILE:-5}"
```

**Dlaczego per-plik a nie globalnie**: YAML anchors **nie przechodzą przez granice `include:`** — każdy z siedmiu `docker-compose.*.yml` musi mieć własną definicję anchora. Koszt: 5 linii duplikatu × 7 plików. Korzyść: zero grzebania w `/etc/docker/daemon.json` na hoście, żadnego sudo, wszystko wersjonowane, zero wpływu na inne kontenery na hoście.

**Tuning**: `LOG_MAX_SIZE` / `LOG_MAX_FILE` w `$BPP_CONFIGS_DIR/.env` (default 150m × 5 = max 750MB per kontener). Sufit dla ~20 kontenerów ≈ 3–4GB na dysku hosta (zstd kompresja realnie obniża o 2–4×) — to tylko **bufor do czasu aż Alloy wyśle logi do Loki**, nie retencja czasowa.

**Gotcha**: Dodając nowy serwis do compose'a, dodaj `logging: *default-logging` — inaczej Docker użyje defaultowego `json-file` bez rotacji i log może puchnąć bez ograniczeń.

#### Loki — retencja czasowa per-serwis

Retencja **czasowa** (w dniach) żyje w Loki, nie w Docker logging driverze. Konfiguracja: `defaults/loki/local-config.yaml` (bind-mount do `loki:/etc/loki/local-config.yaml`). Compactor włączony, retencja aktywna przez `limits_config.retention_stream` + label `service` ustawiany przez Alloy z `com.docker.compose.service`:

| Serwis | Retencja | Uzasadnienie |
|--------|----------|--------------|
| `appserver` | 90 dni | logi Django dla debug incydentów |
| `dbserver` | 90 dni | logi Postgresa (slow query, locks) |
| `webserver` | 180 dni | access log nginx, compliance/traffic analysis |
| (default) | 30 dni | wszystko pozostałe (workery, infrastruktura, monitoring) |

**Tuning retencji**: edytuj `$BPP_CONFIGS_DIR/loki/local-config.yaml` i `docker compose restart loki`. Selektory używają `{service="<compose-service-name>"}` — zmiana nazwy serwisu w compose wymaga aktualizacji selektora.

**Prometheus**: osobna retencja 30d / 4GB (metryki, nie logi) — zob. `docker-compose.monitoring.yml`.

## Available Make Targets

### Deployment
```bash
make run                      # Full deployment pipeline (pull, build, configs, up, test-email)
make up                       # Start all services (force recreate)
make up-quick                 # Quick start without recreation
make stop                     # Stop all services
make pull                     # Pull latest Docker images
make refresh                  # Full refresh (prune, pull, recreate)
make restart-appserver        # Restart application server only
```

### Database
```bash
make migrate                  # Run Django migrations (stops workers safely)
make db-backup                # Create parallel database backup (tar.gz, pg_dump -Fd)
make dbshell                  # Django database shell
make dbshell-psql             # Direct PostgreSQL shell
make upgrade-postgres         # Major version upgrade (np. 15 -> 18) via dump & restore
```

### Shell Access
```bash
make shell                    # Bash in application container
make shell-python             # Django Python shell
make shell-plus               # Django shell_plus (enhanced)
make shell-dbserver           # Bash in database container
make shell-workerserver       # Bash in worker container
make createsuperuser          # Create Django admin user (uses DJANGO_BPP_ADMIN_USERNAME/EMAIL from .env)
make changepassword           # Change admin password
```

### Logs & Monitoring
```bash
make logs                     # View all service logs
make logs-appserver           # View application server logs
make logs-celery              # View Celery worker logs
make logs-dbserver            # View database logs
make logs-denorm              # View denorm-queue logs
make ps                       # Show running containers
make health                   # Quick health check of all services
```

### Celery/Background Tasks
```bash
make celery-stats             # View active tasks and queues
make celery-status            # Check Celery worker status (runs workerserver-status)
make denorm-rebuild           # Rebuild denormalization tables
make denorm-purge-queues      # Clear denormalization queue
make denorm-flush             # Flush denormalization via queue
```

### Configuration
```bash
make update-configs           # Regenerate templated configs (datasources.yaml)
make update-ssl-certs         # Reload nginx to pick up new SSL certs
make init-configs             # Re-initialize config directory structure
make generate-snakeoil-certs  # Generate self-signed SSL certificates
```

### Host Management
```bash
make base-host-update-upgrade # Update system packages on host
make base-host-reboot         # Reboot host
make install-docker           # Install Docker on this host
```

### Docker Maintenance
```bash
make docker-clean             # Clean unused Docker resources
make prune-orphan-volumes     # Remove orphan volumes
make open-docker-volume       # Open Docker volume in shell (interactive, uses fzf)
make rmrf                     # Remove all containers (dangerous! prompts for confirmation)
```

### Django Utilities
```bash
make invalidate               # Invalidate Django cache
make test-email               # Test email configuration (uses DJANGO_BPP_ADMIN_EMAIL from .env)
```

### Rclone Backup
```bash
make rclone-sync              # Sync backups to cloud storage
make rclone-config            # Configure rclone interactively
make rclone-check             # List files in cloud backup
```

### Misc
```bash
make wait                     # Wait for GitHub Actions Docker build, then refresh
make release                  # Wypuść nowy release (tag + push)
make version                  # Pokaż obecną wersję z git-tagow
```

## Release Process

Releasy są kalendarzowe: `YYYY.MM.DD` (pierwszy tego dnia) lub `YYYY.MM.DD.N` (kolejne - suffix auto-inkrementowany od 0). Np. `2026.04.19`, `2026.04.19.0`, `2026.04.19.1`.

**Workflow (`make release` → `scripts/release.sh`)**:

1. Wyliczenie kolejnej wersji z dzisiejszej daty + istniejących tagów.
2. `sed` w `README.md` podmienia badge `version-X.Y.Z-blue` na nową wersję.
3. `git add README.md && git commit -m "release: $VERSION"`.
4. `git tag $VERSION`.
5. `git push origin main --tags` (commity + tag w jednym rzucie).

**Normalny flow release'u feature'a**:

```bash
# 1. Commit merytoryczny (fix/feat/refactor) - osobno
git add <pliki> && git commit -m "<scope>: ..."

# 2. Opcjonalnie push samego commita (albo pominąć - release.sh i tak push-nie)
git push origin main

# 3. Release - sam zrobi kolejny commit (badge bump) + tag + push --tags
make release
```

**Uwagi**:
- Skrypt `scripts/release.sh` zakłada że working tree jest czyste (poza `README.md` który sam zmodyfikuje). Niezacommitowane zmiany w innych plikach zostaną w tree - commit release'u tego nie ruszy, ale warto mieć clean state.
- Wersja jest pobierana w Makefile przez `git describe --tags --abbrev=0` (pokazuje się w `make help`).
- Brak `CHANGELOG.md` - historia releasów to `git log --grep='^release:'`. Opis zmian w wiadomościach commitów feature'owych między tagami.
- Wersjonowanie **kalendarzowe, nie semver** - nie wymaga decyzji major/minor/patch. Breaking changes sygnalizujemy w wiadomości commita + README, nie w numerze wersji.

## Architecture Overview

### Microservices Architecture

**Core Services:**
- `appserver` - Main Django application + migrations
- `authserver` - Lightweight Django auth service for nginx authentication (no migrations/collectstatic)
- `dbserver` - PostgreSQL with custom denormalization system
- `webserver` - Nginx reverse proxy + static file serving
- `redis` - Cache and session storage

**Worker Services:**
- `workerserver-general` - General Celery tasks (queue: celery)
- `workerserver-denorm` - Denormalization tasks (queue: denorm) with reduced logging
- `celerybeat` - Periodic task scheduler (depends on `service_started`, not `service_healthy`)
- `denorm-queue` - **Single-instance** PostgreSQL LISTEN → Celery bridge
- `flower` - Celery monitoring UI (port 5555, path `/flower`)

**Monitoring Services:**
- `prometheus` - Metrics storage and querying (30-day retention)
- `loki` - Log aggregation backend
- `grafana` - Visualization and dashboards (auth via authserver proxy)
- `alloy` - Log collection and processing from Docker containers
- `postgres-exporter` - PostgreSQL metrics exporter for Prometheus
- `node-exporter` - System metrics exporter for Prometheus
- `dozzle` - Real-time Docker log viewer (optional, path `/dozzle`)

**Support Services:**
- `ofelia` - Docker cron scheduler for maintenance tasks
- `backup-runner` - Codzienny pełny cykl backupu: pg_dump bazy, tar volumenu media, lokalna rotacja (KEEP_LAST), rclone sync na zdalny serwer, notyfikacja Rollbar (level `info`/`error`). Obraz `postgres:$DJANGO_BPP_POSTGRESQL_VERSION_MAJOR-alpine` z runtime-install rclone/curl/jq. Scheduler: Ofelia label w samym kontenerze (cron `0 30 2 * * *`). Ręczny trigger: `make backup-cycle`.

### Service Profiles

**Manual Profile Services**: Some services are configured with `profiles: ['manual']` and don't start automatically:
- **workerserver-status**: Diagnostic tool for checking Celery worker status on-demand
- Run with: `docker compose run --rm workerserver-status`

### Data Flow Patterns

1. **Web Requests**: nginx → Django (appserver)
2. **Background Tasks**: Django → Celery → specialized workers
3. **Database Changes**: PostgreSQL triggers → LISTEN → denorm-queue → Celery
4. **Static Files**: Served directly by nginx from shared volumes
5. **Scheduled Jobs**: Ofelia → Django management commands
6. **Logs**: Docker containers → Alloy → Loki → Grafana
7. **Metrics**: Services → Prometheus exporters → Prometheus → Grafana
8. **Authentication**: nginx → authserver (Django) → validates session → proxies to Grafana/Dozzle

## Critical Deployment Patterns

### Service Dependencies
- `appserver` must start before workers (handles migrations)
- Workers depend on `appserver` being healthy (which transitively depends on `dbserver`)
- `denorm-queue` requires `workerserver-denorm` to be healthy
- `authserver` is a lightweight service that starts quickly (seconds) - no migrations or collectstatic
- `celerybeat` uses `service_started` for appserver (not `service_healthy`) to allow faster startup

### Running Commands In Containers
Komendy Django/Celery wywolujemy natywnym `python` / `celery` (obrazy sa odchudzone, `uv` juz sie tam nie znajduje):
- Django management: `python src/manage.py <command>` (CWD w obrazie to katalog nad `src/`)
- Celery: `celery -A django_bpp.celery_tasks <command>` (console script w PATH)
- Przyklad: `python src/manage.py denorm_rebuild --no-flush`

### Safe Migration Process
```bash
# The migrate target automatically:
# 1. Stops denormalization workers
# 2. Runs migrations
# 3. Restarts workers
make migrate
```

### PostgreSQL Major Version Upgrade

`make upgrade-postgres` (skrypt: `scripts/upgrade-postgres.sh`) wykonuje pelny upgrade
Postgresa miedzy major wersjami (np. 16.13 -> 18.3) metoda **logical dump & restore**:

1. `make db-backup` -> swiezy `pg_dump -Fd -j N` tarball w `$DJANGO_BPP_HOST_BACKUP_DIR`
2. Stop dependent services (app, workers, beat, denorm-queue, flower, authserver)
3. Stop+rm kontener `dbserver`
4. **Kopia volume `${COMPOSE_PROJECT_NAME}_postgresql_data`** do volume backupowego
   `..._pg<old>_<ts>` (zachowana, do recznego usuniecia po weryfikacji)
5. Usuniecie obecnego volume `${COMPOSE_PROJECT_NAME}_postgresql_data` — nowy kontener
   **musi uzywac nowego, pustego woluminu**, poniewaz miedzy majorami Postgresa
   NIE ma binarnej kompatybilnosci formatu PGDATA.
6. Bump `DJANGO_BPP_POSTGRESQL_VERSION` (+ `DJANGO_BPP_POSTGRESQL_VERSION_MAJOR`
   dla backup-runnera, gdy byla spojna) w `$BPP_CONFIGS_DIR/.env`
7. `docker compose pull dbserver` + `up -d dbserver` -> initdb na nowym majorze
8. `pg_restore -Fd -j N` z tarballa
9. `make migrate` + `make up` + smoke test logow appserver

**Wymagania**: nowy obraz `iplweb/bpp_dbserver:psql-<MAJOR.MINOR>` musi byc juz
wypchniety na Docker Hub (lista tagow:
https://hub.docker.com/r/iplweb/bpp_dbserver/tags). Skrypt nie buduje obrazu -
tylko go pull-uje. Wolne miejsce na hoscie: ~2.5x rozmiar PGDATA (tarball + kopia
volume).

**Tryb external** (`BPP_DATABASE_COMPOSE=docker-compose.database.external.yml`): skrypt
wykrywa tryb i pokazuje 3-stopniowa instrukcje (admin upgrade'uje zewnetrzna baze
sam, skrypt opcjonalnie bumpuje `DJANGO_BPP_POSTGRESQL_VERSION` + `_MAJOR` i
recreate-uje sentinel + backup-runner).

**Auto-rollback przy failed startup**: gdy nowy dbserver nie wstaje w kroku
[8/10] (np. blad initu, healthcheck timeout, niezgodny layout volume'u jak w
PG18+), skrypt zapyta `"Wykonac auto-rollback?"`. Po potwierdzeniu odkrecamy
bump .env, kasujemy niedzialajacy `postgresql_data`, przywracamy go z
`BACKUP_VOLUME` i startujemy stary dbserver - wraca do stanu sprzed upgrade'u.
Backup volume zostaje usuniety po sukcesie (dane sa juz w oryginalnym volume).
Tarball pg_dump pozostaje jako disaster recovery.

**Rollback**: stary volume + tarball pozostaja zachowane. W razie problemu - patrz
plik `$BPP_CONFIGS_DIR/.upgrade-rollback-<ts>` z dokladnymi krokami.

**Wznowienie od konkretnego kroku** (`--from-step=N`): skrypt zapisuje stan do
`$BPP_CONFIGS_DIR/.upgrade-rollback-<ts>` ZARAZ po potwierdzeniu upgrade'u (przed
krokiem 1), a po kroku 3 dopisuje tam sciezke tarballa. Dzieki temu, jesli ktos
krok padnie - np. krok 8 (start nowego dbservera) - mozna wznowic od niego bez
ponownego wykonywania dumpa/kopiowania volume:

```bash
bash scripts/upgrade-postgres.sh --from-step=8
# auto-detect najnowszego pliku stanu z $BPP_CONFIGS_DIR
# albo jawnie: --rollback-file=$BPP_CONFIGS_DIR/.upgrade-rollback-<ts>
```

Komunikat o awarii (trap `on_error`) pokazuje dokladna komende do wznowienia.
Niektore kroki nie sa w pelni idempotentne - np. krok 5 wywali sie jesli
BACKUP_VOLUME juz istnieje (usun go recznie), a krok 9 zglosi konflikty gdy
baza ma juz czesciowo wlane dane. `--help` dla pelnego opisu.

### Environment-Specific Behavior
- **Environment Markers**: Database may be automatically marked with environment identifiers
- **Backup Configuration**: Rclone backup jobs may be enabled or disabled based on environment requirements

## Scheduled Maintenance (Ofelia)

Daily maintenance tasks run automatically:
- **22:00** - Denormalization rebuild
- **01:30** - Sitemap refresh
- **03:30** - Rebuild kolejnosc (publication ordering)
- **04:30** - Rebuild autor_jednostka (author-unit relationships)
- **Saturday 21:30** - PBN (Polish Bibliography Network) sync

## Key Integration Points

### External Services
- **LDAP**: Institutional authentication
- **SMTP**: Institutional mail server for notifications
- **PBN Integration**: National bibliography synchronization
- **Sentry**: Error monitoring and performance tracking

### Denormalization System
This application uses a sophisticated denormalization system:
- PostgreSQL triggers detect data changes
- `LISTEN/NOTIFY` mechanism sends events to `denorm-queue`
- Specialized Celery workers rebuild materialized views
- Critical for performance with large academic datasets

**CRITICAL**: The `denorm-queue` service must run as a **single instance only** to avoid duplicate message processing. Do not scale this service.

## Monitoring and Observability

### Accessing Monitoring Tools

All monitoring tools are protected by nginx + authserver authentication:

- **Grafana**: `https://<domain>/grafana/` - Dashboards and data exploration
- **Flower**: `https://<domain>/flower/` - Celery task monitoring
- **Dozzle**: `https://<domain>/dozzle/` - Real-time Docker logs
- **Prometheus**: Not publicly exposed (internal only)
- **Loki**: Not publicly exposed (internal only)

### Monitoring Workflows

**Check Application Errors**:
1. Open Grafana → "Error Monitoring" dashboard
2. Filter by log level (error, critical, warning)
3. Click on error to see full log context

**Monitor Database Performance**:
1. Open Grafana → "PostgreSQL Health" dashboard
2. Check connection count, query performance, cache hit ratio
3. Review "PostgreSQL Maintenance" for vacuum/analyze status

**Monitor HTTP Performance**:
1. Open Grafana → "HTTP Performance" dashboard
2. View request rates, response times, error rates by endpoint
3. Correlate with application logs via Loki

**Check Celery Tasks**:
1. Open Flower → Active tasks tab
2. View task success/failure rates
3. Check worker status and queue lengths
4. Or use: `make celery-stats` for CLI output

**Real-time Log Viewing**:
1. Use Dozzle for live log streaming with search
2. Or use: `make logs-appserver` for service-specific logs
3. Or use Grafana Explore with Loki datasource for advanced queries

## Development Workflow

### Typical Development Process
1. **Deploy changes**: `make run` (full) or `make up-quick` (fast)
2. **Debug issues**: `make logs-appserver` or `make shell`
3. **Database changes**: `make migrate` (handles worker coordination)
4. **Monitor background tasks**: `make celery-stats` or `make celery-status`
5. **Test functionality**: Check scheduled jobs with `make logs`

### Remote Host Management
```bash
make base-host-update-upgrade # Update system packages on host
make base-host-reboot         # Reboot host
make install-docker           # Install Docker on host
```

## Configuration Customization

### Directory Layout

```
~/
├── bpp-deploy/                     # This repo (git clone)
│   ├── .env                        # Points to config dir (BPP_CONFIGS_DIR=...)
│   └── defaults/             # Default/template config files
│
├── publikacje-uczelnia/            # Config directory (BPP_CONFIGS_DIR)
│   ├── .env                        # App variables (DB, RabbitMQ, hostname)
│   ├── ssl/, rclone/, alloy/...    # Service configs (bind-mounted)
│   └── grafana/provisioning/       # Dashboards & datasources
│
└── backups/                        # Database + media backups (DJANGO_BPP_HOST_BACKUP_DIR)
```

### Deployment-Specific Files (in `$BPP_CONFIGS_DIR`)

1. **`.env`** - Database credentials, RabbitMQ passwords (auto-generated), hostname, admin username/email, Slack webhook
2. **`ssl/key.pem`**, **`ssl/cert.pem`** - SSL certificates
3. **`rclone/rclone.conf`** - Cloud backup credentials
4. **`grafana/provisioning/datasources/datasources.yaml.tpl`** - Grafana DB credentials

### Configuration Updates

Config files are bind-mounted directly — editing files in `$BPP_CONFIGS_DIR` takes effect immediately (or after service restart).

- `make update-configs` - Regenerates `datasources.yaml` from template (envsubst)
- `make update-ssl-certs` - Reloads nginx to pick up new SSL certificates
- `make init-configs` - Re-creates missing config directory structure
- `make configure-resources` - Tune Docker memory/CPU limits for this host (interactive)
- `make generate-snakeoil-certs` - Generates self-signed SSL certificates (won't overwrite existing)
- `make generate-snakeoil-certs-force` - Regenerates self-signed SSL certificates (overwrites existing)

### Resource Limits (`deploy.resources.limits`)

Wszystkie serwisy stacka (poza `backup-runner` — odpala się raz dziennie na 10 minut) mają limity pamięci i CPU sparametryzowane przez env vars, żeby runaway container (memory leak, heavy query, burst pod obciążeniem) nie mógł zjeść całego hosta:

**High-risk (core workload)**:
- `dbserver` — `DBSERVER_MEM_LIMIT` / `DBSERVER_CPU_LIMIT` (default 2g / 2.0)
- `appserver` — `APPSERVER_MEM_LIMIT` / `APPSERVER_CPU_LIMIT` (default 1g / 2.0)
- `workerserver-general` — `WORKER_GENERAL_MEM_LIMIT` / `WORKER_GENERAL_CPU_LIMIT` (default 1g / 2.0)
- `workerserver-denorm` — `WORKER_DENORM_MEM_LIMIT` / `WORKER_DENORM_CPU_LIMIT` (default 1g / 1.0)
- `rabbitmq` — `RABBITMQ_MEM_LIMIT` / `RABBITMQ_CPU_LIMIT` (default 512m / 1.0)
- `redis` — `REDIS_MEM_LIMIT` / `REDIS_CPU_LIMIT` + wewnętrzny `REDIS_MAXMEMORY` (z `allkeys-lru` eviction policy, musi być mniejszy od Docker limit żeby ewiktowanie działało zanim Docker zabije kontener; default 256m / 0.5)
- `loki` — `LOKI_MEM_LIMIT` / `LOKI_CPU_LIMIT` (default 256m / 0.5)
- `prometheus` — `PROMETHEUS_MEM_LIMIT` / `PROMETHEUS_CPU_LIMIT` (default 512m / 1.0)

**Monitoring & support daemons** (small, ale z limitami jako defense-in-depth):
- `flower` — `FLOWER_MEM_LIMIT` / `FLOWER_CPU_LIMIT` (default 768m / 0.5 — akumuluje historię zadań Celery)
- `alloy` — `ALLOY_MEM_LIMIT` / `ALLOY_CPU_LIMIT` (default 384m / 0.5)
- `denorm-queue` — `DENORM_QUEUE_MEM_LIMIT` / `DENORM_QUEUE_CPU_LIMIT` (default 320m / 1.0)
- `celerybeat` — `CELERYBEAT_MEM_LIMIT` / `CELERYBEAT_CPU_LIMIT` (default 320m / 0.25)
- `authserver` — `AUTHSERVER_MEM_LIMIT` / `AUTHSERVER_CPU_LIMIT` (default 320m / 1.0)
- `grafana` — `GRAFANA_MEM_LIMIT` / `GRAFANA_CPU_LIMIT` (default 192m / 1.0)
- `webserver` (nginx) — `WEBSERVER_MEM_LIMIT` / `WEBSERVER_CPU_LIMIT` (default 256m / 2.0 — proxy_buffers 16x16k = 256 KB/conn przy HTML buforowaniu, burst 500 concurrent = +110 MB; plus HTTP/3 QUIC per-packet TLS)
- `postgres-exporter` — `PG_EXPORTER_MEM_LIMIT` / `PG_EXPORTER_CPU_LIMIT` (default 64m / 0.25)
- `node-exporter` — `NODE_EXPORTER_MEM_LIMIT` / `NODE_EXPORTER_CPU_LIMIT` (default 64m / 0.25)
- `dozzle` — `DOZZLE_MEM_LIMIT` / `DOZZLE_CPU_LIMIT` (default 64m / 0.25)
- `ofelia` — `OFELIA_MEM_LIMIT` / `OFELIA_CPU_LIMIT` (default 64m / 0.25)

**Domyślne wartości** w compose'ach są skrojone pod host 8 GB (najmniejszy rozsądny deployment), więc stack startuje out-of-the-box po `git pull && make up` bez żadnej akcji użytkownika. Defaulty dla małych daemonów są bliskie ~1.5× obserwowanej realnej konsumpcji, z podłogą 64m dla najlżejszych procesów.

**Tuning pod większy host**: `make configure-resources` wykrywa RAM i CPU (Linux `/proc/meminfo` + `nproc`, macOS `sysctl`), proponuje proporcjonalny podział (30% RAM dla Postgresa, 15% dla Django/workerów itd.) i interaktywnie pyta o akceptację każdego serwisu. Wynik ląduje w `$BPP_CONFIGS_DIR/.env` i jest odczytywany przez compose przy następnym `make up`. (Skrypt pokrywa obecnie tylko serwisy high-risk; tuning małych daemonów rób ręcznie w `.env` jeśli defaulty się nie sprawdzają.)

**Bez limitu**: `backup-runner` (ephemeral, ~10 min/dobę), `workerserver-status` (profile=manual, ad-hoc).

### Nightly Restarts (memory leak mitigation)

Python-owe procesy long-running (gunicorn, Celery) puchną z czasem niezależnie od limitów — to real memory leak, nie burst. Zamiast podbijać limity, **restartujemy je nocą** przez Ofelię, staggered w oknie 05:00–05:25 (po backup 02:30, rebuild_autor_jednostka 04:30, przed godzinami pracy):

| Czas | Serwis |
|---|---|
| 05:00 | appserver |
| 05:05 | workerserver-general |
| 05:10 | workerserver-denorm |
| 05:15 | flower |
| 05:20 | celerybeat |
| 05:25 | denorm-queue |

Mechanizm: `ofelia.job-exec.restart_self.command: "kill 1"` — Ofelia przez docker.sock (ro) wykonuje `docker exec <container> kill 1`, PID 1 dostaje SIGTERM, graceful shutdown, `restart: always` wskrzesza kontener. Żadnych nowych serwisów, socket pozostaje read-only. Restart ~10s na serwis, uptime SLO nie cierpi.

**Wylaczanie restartu**: wszystkie etykiety ofelia zyja w compose'ach - zeby wylaczyc restart np. appservera, zakomentuj `ofelia.job-exec.restart_self.*` labels w `docker-compose.application.yml`. Brak env-var toggle'a (restart to gwarancja, nie opcja).

### Optional Feature Flags

**`DJANGO_BPP_ENABLE_HTML2DOCX_IMAGE`** (default: `false`) — gdy `true`, `make pull` / `make up` dociaga obraz `iplweb/html2docx:latest`. To opcjonalny fallback dla eksportu HTML → DOCX: większość instalacji korzysta z pandoca dostępnego w obrazie `appserver` i nie potrzebuje html2docx. Włączaj tylko dla instalacji, gdzie pandoc zawodzi (np. nietypowe tabele HTML). Flaga żyje tylko po stronie deploymentu (Makefile) — nie jest propagowana do Django, kontroluje wyłącznie `docker pull`.

### Backwards Compatibility and `.env` Migrations — CRITICAL

**Reguła:** nowa wersja `bpp-deploy` musi dać się uruchomić na **starym** `$BPP_CONFIGS_DIR/.env`, bez wymagania od użytkownika ręcznych edycji pliku. Deploymenty produkcyjne są aktualizowane przez `git pull && make up` i każdy obowiązkowy krok ręczny jest potencjalnym powodem do awarii. Dotyczy to w szczególności:

- **Rename zmiennych** w `.env` (np. `DJANGO_BPP_BACKUP_DIR` → `DJANGO_BPP_HOST_BACKUP_DIR`, `DJANGO_BPP_EXTERNAL_POSTGRESQL_DB_VERSION` → `DJANGO_BPP_POSTGRESQL_DB_VERSION`, `DJANGO_BPP_DBSERVER_PG_VERSION` → `DJANGO_BPP_POSTGRESQL_VERSION`, `DJANGO_BPP_POSTGRESQL_DB_VERSION` → `DJANGO_BPP_POSTGRESQL_VERSION_MAJOR`)
- **Dodanie nowej zmiennej z defaultem w compose** (np. dwuwarstwowy fallback `${DJANGO_BPP_POSTGRESQL_VERSION:-${DJANGO_BPP_DBSERVER_PG_VERSION:-16.13}}` w compose daje stare .envy dalej dzialajace, nowe dostaja wartosc z init-configs, fallback default na ostatni przypadek)
- **Zmiana semantyki** istniejących zmiennych
- **Nowe zmienne wymagane** przez nowe serwisy/skrypty
- **Restrukturyzacja** układu katalogów konfiguracyjnych

**Obowiązkowe dwie warstwy zabezpieczenia**:

1. **Fallback w kodzie czytającym** — Makefile/skrypty muszą akceptować starą nazwę jako alternatywę (np. `ifdef OLD_VAR; NEW_VAR := $(OLD_VAR); endif` w Makefile). Daje to natychmiastowe działanie po `git pull` bez żadnej akcji użytkownika.
2. **Migracja w `scripts/init-configs.sh`** — gdy user uruchomi `make init-configs` (co i tak zaleca się po każdym upgrade), skrypt musi wykryć starą nazwę i zmienić ją na nową w `.env`, zachowując wartość. Wzorzec:

```bash
if env_has_var "OLD_NAME" && ! env_has_var "NEW_NAME"; then
    _val="$(get_env_var OLD_NAME)"
    awk '!/^OLD_NAME=/ && !/^# Dopisano automatycznie.*OLD_NAME/' "$ENV_FILE" > "$ENV_FILE.tmp.$$" \
        && mv "$ENV_FILE.tmp.$$" "$ENV_FILE"
    set_env_var "NEW_NAME" "$_val" "Komentarz (migracja z OLD_NAME)"
    echo "  ~ zmigrowalem OLD_NAME -> NEW_NAME"
fi
```

Pomocnicze funkcje w `init-configs.sh`: `env_has_var`, `get_env_var` (strip-uje otaczające cudzysłowy), `set_env_var` (nadpisuje lub dopisuje). Ich sygnatury są stabilne — używaj ich zamiast własnego `grep`/`sed`.

**Czego NIE robić**:

- NIE dodawać nowej wymaganej zmiennej bez defaultu w compose (`${VAR:-default}`) lub bez migracji w init-configs.
- NIE usuwać starej zmiennej bez migracji nawet jeśli "nikt już nie powinien jej używać".
- NIE zakładać że user przeczyta release notes i zedytuje `.env` ręcznie.
- NIE łamać kompatybilności w pół-release (najpierw dodaj nową nazwę + fallback + migrację, dopiero w następnym release-u pomyśl o usunięciu starej po latach).

## Important Notes

### Container Patterns
- Use service-specific log commands (`make logs-appserver`)
- Always use `make` targets instead of direct `docker-compose`
- Monitor Celery queue health regularly

### Safety Considerations
- **Always backup before major changes**: `make db-backup`
- **Environment safety**: Verify environment-specific configurations (database markers, backup settings)
- **Service coordination**: Use provided targets that handle dependencies
- **Health checks**: Services have dependency health checks configured

### Django Application Access
Since this is a deployment repo, Django source code is inside containers:
```bash
make shell  # Access container with Django code at /src/
# Inside container: python src/manage.py <command>
```

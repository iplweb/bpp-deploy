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
                        # backup directory. Generates random passwords.
                        # Edit $BPP_CONFIGS_DIR/.env
make                    # Second run: starts services normally
```

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

**Flower Logs**: JSON driver with rotation (max 10MB, 3 files) to prevent disk filling.

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
```

## Architecture Overview

### Microservices Architecture

**Core Services:**
- `appserver` - Main Django application + migrations (uses **uv** package manager)
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
- `backup-runner` - Codzienny pełny cykl backupu: pg_dump bazy, tar volumenu media, lokalna rotacja (KEEP_LAST), rclone sync na zdalny serwer, notyfikacja Rollbar (level `info`/`error`). Obraz `postgres:$DJANGO_BPP_POSTGRESQL_DB_VERSION-alpine` z runtime-install rclone/curl/jq. Scheduler: Ofelia label w samym kontenerze (cron `0 30 2 * * *`). Ręczny trigger: `make backup-cycle`.

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

### Python Package Management
The project uses **uv** (ultra-fast Python package manager) instead of pip:
- Commands: `uv run src/manage.py <command>` instead of `python manage.py <command>`
- Used in: appserver, denorm-queue, all Ofelia scheduled jobs
- Example: `uv run src/manage.py denorm_rebuild --no-flush`

### Safe Migration Process
```bash
# The migrate target automatically:
# 1. Stops denormalization workers
# 2. Runs migrations
# 3. Restarts workers
make migrate
```

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
- `make generate-snakeoil-certs` - Generates self-signed SSL certificates (won't overwrite existing)
- `make generate-snakeoil-certs-force` - Regenerates self-signed SSL certificates (overwrites existing)

### Backwards Compatibility and `.env` Migrations — CRITICAL

**Reguła:** nowa wersja `bpp-deploy` musi dać się uruchomić na **starym** `$BPP_CONFIGS_DIR/.env`, bez wymagania od użytkownika ręcznych edycji pliku. Deploymenty produkcyjne są aktualizowane przez `git pull && make up` i każdy obowiązkowy krok ręczny jest potencjalnym powodem do awarii. Dotyczy to w szczególności:

- **Rename zmiennych** w `.env` (np. `DJANGO_BPP_BACKUP_DIR` → `DJANGO_BPP_HOST_BACKUP_DIR`, `DJANGO_BPP_EXTERNAL_POSTGRESQL_DB_VERSION` → `DJANGO_BPP_POSTGRESQL_DB_VERSION`)
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
# Inside container: uv run src/manage.py <command>
```

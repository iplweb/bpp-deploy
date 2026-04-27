# CLAUDE.md

Guidance for Claude Code working in this repository.

## Project Overview

**Django-based academic publication management system (BPP — Bibliografia Publikacji Pracowników)**, deployment configuration only. Django source code lives at `/src/` **inside the Docker containers** — this repo contains Docker Compose orchestration and deployment scripts.

**Stack**: Django + PostgreSQL, Celery + RabbitMQ, Nginx, Redis, Ofelia (cron), Prometheus + Loki + Grafana + Alloy, custom `iplweb/*` images.

## Configuration Architecture

### Modular Docker Compose (include directive, v2.20+)

```
docker-compose.yml              # Main orchestration
├── docker-compose.monitoring.yml     # Prometheus, Loki, Grafana, Alloy, exporters
├── docker-compose.database.yml       # PostgreSQL + postgresql_data volume
├── docker-compose.infrastructure.yml # Nginx, Redis, RabbitMQ
├── docker-compose.application.yml    # appserver, authserver, ofelia, autoheal + staticfiles/media volumes
├── docker-compose.workers.yml        # Celery (general, denorm, beat, flower, denorm-queue)
└── docker-compose.backup.yml         # backup-runner
```

Volumes are defined in the file that owns them but referenced cross-file (e.g. `staticfiles`/`media` defined in `application.yml`, used by workers).

Each `include:` entry has `env_file: ${BPP_CONFIGS_DIR}/.env` so `${VAR}` interpolation works in included YAML. `BPP_CONFIGS_DIR` is read from repo-local `.env` automatically by Compose — `docker compose up` works directly without `make`.

### Configuration Directory (`BPP_CONFIGS_DIR`)

Configuration lives **outside the repository** (e.g. `~/publikacje-uczelnia/`). Created on first `make` run by `init-configs`. Contents: `.env`, `ssl/`, `rclone/`, `alloy/`, `prometheus/`, `rabbitmq/`, `grafana/provisioning/{datasources,dashboards}/`. Bind-mounted directly into containers.

Repo's `defaults/` holds template configs copied in by `init-configs` (without overwriting existing).

### First Run

```bash
make    # First run: prompts for config dir, hostname, admin user/email,
        # Slack webhook, backup dir, PostgreSQL version. Generates random
        # passwords. Edit $BPP_CONFIGS_DIR/.env if needed.
make    # Second run: starts services normally.
```

### PostgreSQL Version

`dbserver` uses `iplweb/bpp_dbserver:psql-${DJANGO_BPP_POSTGRESQL_VERSION}`, format `MAJOR.MINOR` (e.g. `16.13`, `17.9`, `18.3`). Default `16.13`. Major upgrades require dump/restore — use `make upgrade-postgres`, do **not** edit the variable manually.

`DJANGO_BPP_POSTGRESQL_VERSION_MAJOR` (auto-derived from `_VERSION`) is used by `backup-runner` (`postgres:<major>-alpine` — `pg_dump` must be ≥ server version). External mode (`BPP_DATABASE_COMPOSE=docker-compose.database.external.yml`): both vars hold the major only.

Image tags: https://hub.docker.com/r/iplweb/bpp_dbserver/tags

### Staticfiles volume — contract with appserver image

`staticfiles` is populated by `appserver` (mount `/staticroot`) and served by `webserver/nginx` (mount `/var/www/html/staticroot`). Source is `/app/staticroot.baked/` baked into the appserver image at build time (when `node_modules` is available — runtime no longer has it).

1. Appserver entrypoint (`docker/appserver/entrypoint-appserver.sh` in `bpp` repo) at Phase 2 runs `cp -ru /app/staticroot.baked/. "$STATIC_ROOT/"`.
2. `cp -ru` seeds an empty volume **and** tops up newer files on image upgrade without deleting existing content.
3. Runtime does **not** run `collectstatic` — the `.baked` directory is the same output. Fallback runs `collectstatic` only for pre-`.baked` images.

`STATIC_ROOT=/staticroot/` in `.env` overrides image default `/app/staticroot`. Backward-compat: entrypoint guards with `if [ -d /app/staticroot.baked ]`. After `make refresh` or `make prune-orphan-volumes`, volume gets repopulated from `.baked`.

### Authentication

Grafana uses auth proxy mode behind nginx + authserver (Django). Headers: `X-WEBAUTH-USER`, `X-WEBAUTH-EMAIL`, `X-WEBAUTH-NAME`. Auto-signup as Admin.

### Healthchecks

**Compose-level**: `authserver` (HTTP `/health/`), `redis` (`redis-cli ping`), `rabbitmq` (`rabbitmqctl authenticate_user`), `grafana` (HTTP `/api/health`).

**Image-level** (Dockerfile `HEALTHCHECK`): `dbserver` (pg_isready), `appserver` (HTTP), `workerserver-general`/`workerserver-denorm` (`celery inspect ping` via RabbitMQ — flaps when AMQP connection breaks), `denorm-queue` (`pgrep -f denorm_queue`).

**Reactive restart on unhealthy** (sidecar `autoheal`): Docker does NOT restart containers based on failed healthchecks (`restart: always` only reacts to process exit). `willfarrell/autoheal:1.2.0` (in `application.yml`) monitors containers labeled `autoheal=true` via Docker API and restarts them on `Health.Status=unhealthy`. Currently watched: `workerserver-general`, `workerserver-denorm`, `denorm-queue` — without this, a stuck Celery worker (broken AMQP, kombu reconnect loop) would stay unhealthy forever because the process is still alive.

**Important**: Double-dollar escaping (e.g. `$$RABBITMQ_DEFAULT_USER`) in healthcheck commands prevents premature variable expansion by Compose.

### Logging

**Reduced verbosity**: Prometheus/Loki/Grafana/Alloy/RabbitMQ all set to `warn` or `error`.

**Docker log driver — local rotation**: All services use the `local` driver (binary, zstd-compressed, ~2–4× smaller than `json-file`) via shared `x-logging` YAML anchor at the top of each compose file:

```yaml
x-logging: &default-logging
  driver: "local"
  options:
    max-size: "${LOG_MAX_SIZE:-150m}"
    max-file: "${LOG_MAX_FILE:-5}"
```

YAML anchors do **not** cross `include:` boundaries — each of the 7 compose files needs its own `x-logging` definition. This is intentional: zero `daemon.json` host edits, all versioned, no impact on other host containers. **When adding a new service: include `logging: *default-logging` or it will fall back to unrotated `json-file`.**

Defaults: 150m × 5 = 750MB per container (~3–4GB ceiling for ~20 containers, halved by zstd) — buffer until Alloy ships logs to Loki, not time-based retention.

**Loki — time-based retention per service**: configured in `defaults/loki/local-config.yaml` via `limits_config.retention_stream` keyed on `service` label set by Alloy from `com.docker.compose.service`:

| Service | Retention | Why |
|---|---|---|
| `appserver` | 90 d | Django logs for incident debugging |
| `dbserver` | 90 d | slow queries, locks |
| `webserver` | 180 d | nginx access log, compliance/traffic |
| (default) | 30 d | workers, infrastructure, monitoring |

Tuning: edit `$BPP_CONFIGS_DIR/loki/local-config.yaml` + `docker compose restart loki`. Selectors use `{service="<compose-service-name>"}`.

Prometheus retention: 30d / 4GB (separate, in `monitoring.yml`).

## Make Targets

`make help` is the source of truth. Notable targets:

- **Deploy**: `make run` (full pipeline), `make up` / `make up-quick`, `make refresh` (prune + pull + recreate), `make stop`, `make restart-appserver`
- **DB**: `make migrate` (safely stops denorm workers first), `make db-backup`, `make dbshell`, `make dbshell-psql`, `make upgrade-postgres`
- **Shell**: `make shell` (appserver), `make shell-python`, `make shell-plus`, `make shell-dbserver`, `make shell-workerserver`, `make createsuperuser`, `make changepassword`
- **Logs**: `make logs`, `make logs-appserver`, `make logs-celery`, `make logs-dbserver`, `make logs-denorm`, `make ps`, `make health`
- **Celery**: `make celery-stats`, `make celery-status`, `make denorm-rebuild`, `make denorm-purge-queues`, `make denorm-flush`
- **Config**: `make update-configs`, `make update-ssl-certs`, `make init-configs`, `make configure-resources`, `make generate-snakeoil-certs[-force]`
- **Maintenance**: `make docker-clean`, `make prune-orphan-volumes`, `make open-docker-volume`, `make rmrf` (dangerous, prompts)
- **Backup**: `make rclone-sync`, `make rclone-config`, `make rclone-check`, `make backup-cycle`
- **Misc**: `make wait` (wait for GH Actions build then refresh), `make release`, `make version`, `make test-email`, `make invalidate`

## Architecture Overview

### Services

**Core**: `appserver` (Django + migrations), `authserver` (Django auth proxy for nginx — no migrations/collectstatic, starts in seconds), `dbserver` (PostgreSQL + denormalization), `webserver` (Nginx), `redis`.

**Workers**: `workerserver-general` (queue: celery), `workerserver-denorm` (queue: denorm), `celerybeat` (depends on `service_started`, not `_healthy`, for faster startup), `denorm-queue` (PG LISTEN → Celery bridge), `flower` (port 5555, path `/flower`).

**Monitoring**: `prometheus` (30d retention), `loki`, `grafana` (auth proxy), `alloy` (log shipping), `postgres-exporter`, `node-exporter`, `dozzle` (path `/dozzle`).

**Support**: `ofelia` (Docker cron), `autoheal` (sidecar), `backup-runner` (daily `pg_dump` + tar media + rclone + Rollbar; image `postgres:$DJANGO_BPP_POSTGRESQL_VERSION_MAJOR-alpine`; scheduled by Ofelia label `0 30 2 * * *`; manual: `make backup-cycle`).

**Manual profile** (`profiles: ['manual']`, not started automatically): `workerserver-status` — run via `docker compose run --rm workerserver-status`.

### Data Flow

Web: nginx → Django. Background tasks: Django → Celery. DB changes: PG triggers → LISTEN → `denorm-queue` → Celery. Static: nginx serves shared volume. Cron: Ofelia → Django mgmt commands. Logs: containers → Alloy → Loki → Grafana. Metrics: services → Prometheus → Grafana. Auth: nginx → authserver → proxies Grafana/Dozzle.

**CRITICAL**: `denorm-queue` must run as a **single instance** to avoid duplicate message processing. Do not scale.

## Critical Deployment Patterns

### Service Dependencies
- `appserver` starts before workers (handles migrations); workers depend on `appserver` healthy (transitively `dbserver`)
- `denorm-queue` requires `workerserver-denorm` healthy
- `celerybeat` uses `service_started` (not `_healthy`) for `appserver` for faster startup

### Running Commands In Containers
Images are slim — `uv` is no longer present. Use native `python` / `celery`:
- Django: `python src/manage.py <command>` (CWD is the dir above `src/`)
- Celery: `celery -A django_bpp.celery_tasks <command>`

### Safe Migrations
`make migrate` automatically: stops denorm workers → runs migrations → restarts workers.

### PostgreSQL Major Version Upgrade

`make upgrade-postgres` (script: `scripts/upgrade-postgres.sh`) does logical dump & restore (e.g. 16.13 → 18.3):

1. `make db-backup` — fresh `pg_dump -Fd -j N` tarball in `$DJANGO_BPP_HOST_BACKUP_DIR`
2. Stop dependent services (app, workers, beat, denorm-queue, flower, authserver)
3. Stop+rm `dbserver`
4. Copy volume `${COMPOSE_PROJECT_NAME}_postgresql_data` → `..._pg<old>_<ts>` (kept for manual deletion after verification)
5. Delete `${COMPOSE_PROJECT_NAME}_postgresql_data` — new container needs an empty volume because PGDATA format is **not** binary-compatible across majors
6. Bump `DJANGO_BPP_POSTGRESQL_VERSION` (+ `_MAJOR` when consistent) in `$BPP_CONFIGS_DIR/.env`
7. `docker compose pull dbserver` + `up -d dbserver` → initdb on new major
8. `pg_restore -Fd -j N` from tarball
9. `make migrate` + `make up` + smoke-test appserver logs

**Requirements**: image `iplweb/bpp_dbserver:psql-<MAJOR.MINOR>` already pushed (script does not build, only pulls). Disk: ~2.5× PGDATA (tarball + volume copy).

**External mode**: script detects and shows 3-step instructions (admin upgrades external DB themselves; script optionally bumps `_VERSION` + `_MAJOR` and recreates sentinel + backup-runner).

**Auto-rollback on failed startup**: if new dbserver fails at step [8/10] (init error, healthcheck timeout, incompatible volume layout — e.g. PG18+), script asks `"Wykonac auto-rollback?"`. On confirm: revert `.env` bump, delete broken `postgresql_data`, restore from `BACKUP_VOLUME`, start old dbserver. Backup volume removed after success. Tarball kept as DR.

**Resume from a step** (`--from-step=N`): script writes state to `$BPP_CONFIGS_DIR/.upgrade-rollback-<ts>` right after upgrade confirmation (before step 1) and after step 3 appends tarball path. If a step fails (e.g. step 8), resume without redoing dump/volume copy:

```bash
bash scripts/upgrade-postgres.sh --from-step=8
# auto-detects newest state file, or pass --rollback-file=<path>
```

Failure trap (`on_error`) prints exact resume command. Step 5 fails if `BACKUP_VOLUME` already exists (delete manually); step 9 reports conflicts if data is partially loaded. `--help` for full description.

**Manual rollback**: old volume + tarball stay. See `$BPP_CONFIGS_DIR/.upgrade-rollback-<ts>` for steps.

### Scheduled Maintenance (Ofelia)

Daily: 22:00 denorm rebuild, 01:30 sitemap, 03:30 rebuild_kolejnosc, 04:30 rebuild_autor_jednostka. Saturday 21:30: PBN sync.

### Nightly Restarts (memory leak mitigation)

Long-running Python procs (gunicorn, Celery) bloat regardless of limits — real memory leak, not burst. Staggered restart 05:00–05:25 (after 02:30 backup, 04:30 rebuild, before working hours):

| Time | Service |
|---|---|
| 05:00 | appserver |
| 05:05 | workerserver-general |
| 05:10 | workerserver-denorm |
| 05:15 | flower |
| 05:20 | celerybeat |
| 05:25 | denorm-queue |

Mechanism: `ofelia.job-exec.restart_self.command: "kill 1"` — Ofelia execs `kill 1` via `docker.sock` (ro), PID 1 gets SIGTERM, graceful shutdown, `restart: always` resurrects. No new services, socket stays read-only.

To disable for a specific service: comment out `ofelia.job-exec.restart_self.*` labels in the relevant compose file. No env-var toggle — restart is a guarantee, not an option.

## Resource Limits (`deploy.resources.limits`)

All services (except `backup-runner` — ephemeral, ~10 min/day) have `*_MEM_LIMIT` / `*_CPU_LIMIT` env vars so a runaway container can't eat the host. Defaults are sized for an **8 GB host** (smallest reasonable deployment) — stack works out-of-the-box after `git pull && make up`.

**High-risk** (defaults): `dbserver` 2g/2.0, `appserver` 1g/2.0, `workerserver-general` 1g/2.0, `workerserver-denorm` 1g/1.0, `rabbitmq` 512m/1.0, `redis` 256m/0.5 (+ internal `REDIS_MAXMEMORY` with `allkeys-lru`, must be < Docker limit so eviction beats OOM kill), `loki` 256m/0.5, `prometheus` 512m/1.0.

**Daemons**: `flower` 768m/0.5 (accumulates Celery task history), `alloy` 384m/0.5, `denorm-queue` 320m/1.0, `celerybeat` 320m/0.25, `authserver` 320m/1.0, `webserver` 256m/2.0 (proxy_buffers 16×16k = 256 KB/conn, +HTTP/3 QUIC TLS), `grafana` 192m/1.0, exporters/dozzle/ofelia 64m/0.25, `autoheal` 32m/0.1.

**Tuning**: `make configure-resources` detects host RAM/CPU (Linux `/proc/meminfo`+`nproc`, macOS `sysctl`), proposes proportional split (30% Postgres, 15% Django/workers, …), interactive per-service. Writes `$BPP_CONFIGS_DIR/.env`. Currently covers high-risk only — tune small daemons manually if defaults misbehave.

**No limit**: `backup-runner` (ephemeral), `workerserver-status` (manual profile).

## Optional Feature Flags

**`DJANGO_BPP_ENABLE_HTML2DOCX_IMAGE`** (default `false`): when `true`, `make pull`/`make up` pulls `iplweb/html2docx:latest` as a fallback for HTML→DOCX export. Most installs use pandoc in the appserver image — enable only when pandoc fails (unusual HTML tables). Deployment-side flag only, not propagated to Django.

## Backwards Compatibility and `.env` Migrations — CRITICAL

A new `bpp-deploy` version **must** run on the **old** `$BPP_CONFIGS_DIR/.env` without manual editing. Production deployments update via `git pull && make up` — every required manual step is a potential outage. This applies to:

- **Renaming variables** (e.g. `DJANGO_BPP_BACKUP_DIR` → `DJANGO_BPP_HOST_BACKUP_DIR`, `DJANGO_BPP_DBSERVER_PG_VERSION` → `DJANGO_BPP_POSTGRESQL_VERSION`, `DJANGO_BPP_POSTGRESQL_DB_VERSION` → `DJANGO_BPP_POSTGRESQL_VERSION_MAJOR`)
- **Adding new variables with compose default** — two-tier fallback like `${DJANGO_BPP_POSTGRESQL_VERSION:-${DJANGO_BPP_DBSERVER_PG_VERSION:-16.13}}` keeps old `.env`s working, new ones get `init-configs` value, default as last resort
- Changing semantics of existing variables; new required variables; restructuring config dirs

**Mandatory two-layer protection**:

1. **Fallback in the reader** — Makefile/scripts must accept the old name as alternative (`ifdef OLD_VAR; NEW_VAR := $(OLD_VAR); endif`). Works immediately after `git pull`, no user action required.
2. **Migration in `scripts/init-configs.sh`** — when user runs `make init-configs` (recommended after every upgrade anyway), detect old name and rename in `.env` while preserving value:

```bash
if env_has_var "OLD_NAME" && ! env_has_var "NEW_NAME"; then
    _val="$(get_env_var OLD_NAME)"
    awk '!/^OLD_NAME=/ && !/^# Dopisano automatycznie.*OLD_NAME/' "$ENV_FILE" > "$ENV_FILE.tmp.$$" \
        && mv "$ENV_FILE.tmp.$$" "$ENV_FILE"
    set_env_var "NEW_NAME" "$_val" "Komentarz (migracja z OLD_NAME)"
    echo "  ~ zmigrowalem OLD_NAME -> NEW_NAME"
fi
```

Helpers in `init-configs.sh`: `env_has_var`, `get_env_var` (strips surrounding quotes), `set_env_var` (overwrite or append). Stable signatures — use them instead of custom `grep`/`sed`.

**Don't**: add a new required variable without compose default (`${VAR:-default}`) and without migration; remove an old variable without migration even if "no one should be using it"; assume the user reads release notes and edits `.env` manually; break compatibility in half a release (always: add new name + fallback + migration first; remove old name only years later).

## Release Process

Calendar versioning: `YYYY.MM.DD` (first of the day) or `YYYY.MM.DD.N` (auto-incremented suffix from 0). E.g. `2026.04.19`, `2026.04.19.0`, `2026.04.19.1`.

`make release` → `scripts/release.sh`:
1. Compute next version from today's date + existing tags
2. `sed` README badge `version-X.Y.Z-blue` → new version
3. `git add README.md && git commit -m "release: $VERSION"`
4. `git tag $VERSION`
5. `git push origin main --tags`

Working tree must be clean (except README, which the script modifies). No `CHANGELOG.md` — history is `git log --grep='^release:'`. Calendar versioning: no major/minor/patch decision; signal breaking changes in commit message + README.

## Monitoring Access

All behind nginx + authserver auth: `https://<domain>/grafana/`, `/flower/`, `/dozzle/`. Prometheus and Loki are not publicly exposed.

For CLI: `make logs-<service>`, `make celery-stats`, `make celery-status`, `make health`, `make ps`.

## Safety

- Always `make db-backup` before major changes
- Use `make` targets instead of raw `docker compose` (they handle dependencies)
- Verify environment-specific config (database markers, backup settings) before destructive operations

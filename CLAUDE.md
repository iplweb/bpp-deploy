# CLAUDE.md

Guidance for Claude Code working in this repository.

> **Operator documentation lives in `docs/`** (MkDocs Material, published to
> [iplweb.github.io/bpp-deploy](https://iplweb.github.io/bpp-deploy/)). This file is
> **agent steering** — repo conventions, CRITICAL safety rules, contracts and file
> pointers. When you need a full operational how-to (SSL, PostgreSQL upgrade, monitoring,
> backups), read the linked `docs/` page rather than duplicating it here.
>
> **Keeping docs in sync is a first-class task.** When you change deployment behavior,
> use the **`docs-sync` skill** (`.claude/skills/docs-sync/`) — it maps what belongs in
> README vs `docs/` vs this file, and lists which pages to touch for each kind of change.

## Project Overview

**Django-based academic publication management system (BPP — Bibliografia Publikacji Pracowników)**, deployment configuration only. Django source code lives at `/src/` **inside the Docker containers** — this repo contains Docker Compose orchestration and deployment scripts.

**Stack**: Django + PostgreSQL, Celery + Redis (broker + result backend), Nginx, Ofelia (cron), Netdata (metryki + alerty → ntfy.sh) + Loki + Grafana + Alloy (logi), custom `iplweb/*` images.

## Documentation map

| Surface | Audience | Owns |
|---|---|---|
| `README.md` | New operator on GitHub | Install + first-run config + pointer into docs |
| `docs/` (MkDocs) | Operator running BPP | All operational + reference detail |
| `CLAUDE.md` (this file) | AI agents editing the repo | Conventions, CRITICAL rules, contracts, file pointers |

Operator topics and their canonical pages:

- Config architecture / force-sync: `docs/konfiguracja/architektura.md`
- SSL (manual/Let's Encrypt): `docs/konfiguracja/ssl.md`
- Multi-host: `docs/konfiguracja/multi-host.md`
- Resource limits: `docs/konfiguracja/limity-zasobow.md`
- PostgreSQL versions/upgrade: `docs/konfiguracja/postgresql.md`
- Make commands: `docs/eksploatacja/komendy.md`
- Backups / server migration: `docs/eksploatacja/backup-i-rclone.md`, `docs/eksploatacja/przenosiny-serwera.md`
- Monitoring / logging / slow queries: `docs/monitoring/*`
- Services / healthchecks / Ofelia jobs: `docs/architektura/*`
- Rate limiting (nginx, per-tier `limit_req`): `docs/architektura/rate-limiting.md`
- Backwards-compat contract: `docs/rozwoj/backwards-compatibility.md` (summarized below — read both)

## Configuration Architecture (essentials)

Full detail: `docs/konfiguracja/architektura.md`.

### Modular Docker Compose (`include`, v2.20+)

```
docker-compose.yml                    # Main orchestration
├── docker-compose.monitoring.yml     # Netdata, Loki, Grafana, Alloy, Dozzle
├── docker-compose.database.yml       # PostgreSQL + postgresql_data volume
├── docker-compose.infrastructure.yml # Nginx, Redis
├── docker-compose.application.yml    # appserver, authserver, ofelia, autoheal + staticfiles/media volumes
├── docker-compose.workers.yml        # Celery (general, denorm, beat, flower, denorm-queue)
└── docker-compose.backup.yml         # backup-runner
```

Volumes are defined in the file that owns them but referenced cross-file (e.g. `staticfiles`/`media` in `application.yml`, used by workers). Each `include:` has `env_file: ${BPP_CONFIGS_DIR}/.env`. `BPP_CONFIGS_DIR` is read from repo-local `.env` by Compose — `docker compose up` works without `make`.

### Config dir (`BPP_CONFIGS_DIR`) and `defaults/`

Configuration lives **outside the repository** (e.g. `~/publikacje-uczelnia/`), created on first `make` by `init-configs`. `defaults/` holds templates copied in by `init-configs` **without overwriting** (`copy_if_missing`) — user-tuned configs survive upgrades.

### CRITICAL: force-synced files (overwritten on every `make up`/`refresh`/`run`)

These are overwritten from `defaults/` via `copy_always` (only when content differs):

- `grafana/provisioning/dashboards/*`
- `grafana/provisioning/datasources/datasources.yaml.tpl`
- `netdata/netdata.conf` (rendered host-side from `defaults/netdata/netdata.conf.tpl`)

**Why force-sync:** versioned, read-only-in-UI artifacts must reach existing installs on `git pull && make up`. `netdata.conf` can't interpolate `${VAR}`, so the hostname is substituted into `[registry] registry to announce = https://<host>/netdata` (drives the "View node" button in ntfy alerts). `datasources.yaml.tpl` force-sync is what lets changes like "Grafana connects via read-only `bpp_monitor`" reach old installs. The rendered `datasources.yaml` comes from `scripts/generate-grafana-datasources.sh` (reads `.env` from disk — **not** make's parse-time export, so a freshly-generated `DJANGO_BPP_PG_MONITOR_PASSWORD` isn't rendered empty on first `make up`).

User-tunable knobs are parametrized via `.env` (`NETDATA_DBENGINE_TIER0_RETENTION_MB`, `NETDATA_DBENGINE_PAGE_CACHE_MB`) so force-overwrite doesn't wipe manual tuning. **Don't tell users to hand-edit force-synced files — point them at `.env` knobs.** Everything else under the config dir stays `copy_if_missing`. Dashboards removed from `defaults/` are left in place; UI-created Grafana dashboards live in its DB and are unaffected.

### Staticfiles volume — contract with appserver image

`staticfiles` is populated by `appserver` (mount `/staticroot`) and served by `webserver`/nginx (mount `/var/www/html/staticroot`). Source is `/app/staticroot.baked/` baked into the appserver image at build time. Entrypoint Phase 2 runs `cp -ru /app/staticroot.baked/. "$STATIC_ROOT/"` — seeds an empty volume and tops up newer files on upgrade without deleting. Runtime does **not** run `collectstatic` (fallback only for pre-`.baked` images). `STATIC_ROOT=/staticroot/` in `.env` overrides image default. After `make refresh`/`prune-orphan-volumes`, volume is repopulated from `.baked`.

### Media volume — `DJANGO_BPP_MEDIA_ROOT` is required

User uploads land in the `media` volume mounted at `/mediaroot` in every Django container. **`DJANGO_BPP_MEDIA_ROOT=/mediaroot` in `.env` is required** — without it Django falls back to its built-in default (`~/bpp-media` = `/root/bpp-media` in the container), which is **not** on the volume: uploads vanish on recreate and are excluded from backups (`backup-cycle.sh` tars `/mediaroot`). Set in two places (sibling of `STATIC_ROOT`): the fresh-`.env` heredoc + `ensure_env_var` in `scripts/init-configs.sh`, and an append-only self-heal (`_ensure_var`) in `scripts/ensure-config-files.sh` so `git pull && make up` fixes old `.env` files with no manual step. Don't add a new media path without keeping all three in sync. Detail: `docs/konfiguracja/architektura.md`.

### PostgreSQL version vars

`dbserver` uses the **stock official** `postgres:${DJANGO_BPP_POSTGRESQL_VERSION}` image (Debian, **not** `-alpine` — the entrypoint needs `bash`; `MAJOR.MINOR`; fresh installs default **`18.4`** via `init-configs`, but the Compose safety-net stays `:-16.13` so an ancient `.env`-less PG16 install isn't silently handed a PG18 image) with the autotune scripts in **`dbserver/`** (`autotune.sh` + `docker-entrypoint-autotune.sh`, copied verbatim from `iplweb/bpp-dbserver`) **bind-mounted** read-only on top. The old `iplweb/bpp_dbserver` image is **discontinued** — autotune was its only delta over stock postgres. These scripts are versioned code delivered by `git pull` — **not** force-synced into `$BPP_CONFIGS_DIR`. CRITICAL contracts: (1) `PGDATA` is pinned to `/var/lib/postgresql/data` (stock `postgres:18+` defaults to a versioned subdir → would ignore the existing volume and re-init blank — never change the mount to `/var/lib/postgresql`); (2) fresh installs init with `POSTGRES_INITDB_ARGS=--locale-provider=icu --icu-locale=pl-PL` (Polish collation; **fresh PGDATA only**, never re-collates existing clusters); (3) stock postgres has no built-in healthcheck, so `dbserver` defines its own `pg_isready -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"` (appserver/authserver `depend_on: service_healthy`); (4) `dbserver` needs a **service-level** `env_file: ${BPP_CONFIGS_DIR}/.env` — the `include`-level `env_file` is interpolation-only and is NOT injected into the container. `DJANGO_BPP_POSTGRESQL_VERSION_MAJOR` (auto-derived) drives the **external-mode sentinel** tag and the upgrade step. `backup-runner` **shares an image** rather than pulling its own: its `image:` is `${BPP_BACKUP_PG_IMAGE:-postgres:${DJANGO_BPP_POSTGRESQL_VERSION:-${DJANGO_BPP_DBSERVER_PG_VERSION:-16.13}}}` — **unset by default → the exact same Debian image as `dbserver`** (100% shared layers, ~0 MB extra on disk; an `-alpine` would share nothing with Debian and cost ~350 MB). Its `command` detects `apk` vs `apt-get` so it works on **both** images. Only **external mode** sets `BPP_BACKUP_PG_IMAGE=postgres:<major>-alpine` (so backup shares with the alpine sentinel, not a stray Debian): written by `init-configs` on fresh installs, self-healed into old `.env` by `ensure-config-files` on `make up` (gated on `BPP_DATABASE_COMPOSE=docker-compose.database.external.yml`). New var → Compose default present, no migration needed. Major upgrades require dump/restore — use `make upgrade-postgres`, do **not** edit the var manually. Full procedure (rollback, resume): `docs/konfiguracja/postgresql.md`.

### Image version pinning (`DOCKER_VERSION`) and upgrade rehearsal

`DOCKER_VERSION` pins the 5 `iplweb/bpp_*` images (default `latest` — compose
fallback `${DOCKER_VERSION:-latest}` must stay for backwards compat).
`make zaspawaj-wersje` welds the version **actually running in the appserver
container** (not the local `latest` tag) into `.env` via the stable
`set_env_var` helper; updating a pinned host requires an explicit
`make zaspawaj-wersje TAG=<new>`. `make test-upgrade` is the migration
rehearsal: fresh `db-backup` → shadow stack (`bpp-shadow-*`, plain
`docker run` outside the Compose project) → `pg_restore` → candidate-image
`manage.py migrate` with overridden entrypoint. It must never touch
production containers, volumes, the local `latest` tag, or `.env`. Candidate
images are pulled **by version tag**, never via `:latest`. Shared
digest↔CalVer logic lives in `scripts/lib-docker-versions.sh`
(tests: `make test-docker-versions`). Detail: `docs/eksploatacja/komendy.md`.

## Critical Deployment Patterns

### Running commands in containers

Images are slim — `uv` is no longer present. Use native `python` / `celery`:

- Django: `python src/manage.py <command>` (CWD is the dir above `src/`)
- Celery: `celery -A django_bpp.celery_tasks <command>`

### Safe migrations

`make migrate` automatically: stops denorm workers → runs migrations → restarts workers.

### CRITICAL: denorm-queue is single-instance

`denorm-queue` (PG `LISTEN` → Celery bridge) **must** run as a **single instance** to avoid duplicate message processing. **Do not scale.**

### Single `workerserver` — both queues

As of June 2026 there is **one** Celery worker, `workerserver` (was `workerserver-general` + `workerserver-denorm`), consuming **both** queues. We set `CELERY_QUEUE: "celery,denorm"` **explicitly** in compose (not relying on the new image default) so the merge works on the **current published image too** — otherwise the `denorm` queue would have no consumer until the new image ships. **No strict priority** — kombu round-robins the queues (deliberate per the BPP single-worker spec: `denorm`/`flush_single` tasks are short). Concurrency (default **75% cores**) and child recycling are configured in the **BPP image** `app.conf` (via `celery_tasks.py`) through `CELERY_WORKER_*` env (`CELERY_WORKER_CONCURRENCY`, `_CONCURRENCY_PERCENT`, `_MAX_MEMORY_PER_CHILD`, `_MAX_TASKS_PER_CHILD`, `_POOL`, `_PREFETCH_MULTIPLIER`) — read only by the June-2026+ image. Env rename (`WORKER_GENERAL_*`→`WORKER_*`, drop `WORKER_DENORM_*`) has the mandatory two-layer protection: Compose fallback `${WORKER_MEM_LIMIT:-${WORKER_GENERAL_MEM_LIMIT:-…}}` + `init-configs` migration (`configure-resources` also recomputes + cleans). Detail: `docs/konfiguracja/limity-zasobow.md#concurrency-celery`.

### Logging — add `logging` to new services

All services use the `local` log driver via a per-file `x-logging` YAML anchor. **YAML anchors do not cross `include:` boundaries** — each of the 7 compose files defines its own `x-logging`. **When adding a new service: include `logging: *default-logging` or it falls back to unrotated `json-file`.** Full logging/retention detail: `docs/monitoring/logowanie.md`.

### Rate limiting (nginx)

Per-IP `limit_req` on `/admin/` (50r/s), `/api/` (60r/s) and the rest (`location /`, 100r/s), all `nodelay`, `burst = rate`. **Two-file split: zones (`limit_req_zone` + `rate`) live in `defaults/webserver/default.conf.template` (http context); the `limit_req` directives (+ `burst`) live in `defaults/webserver/_bpp-locations.conf` (server context).** Hardcoded, **not** `.env` — nginx `envsubst` can't do `${VAR:-default}` and `_bpp-locations.conf` isn't envsubst'd at all. Versioned bind-mounted files (not `$BPP_CONFIGS_DIR`), so `git pull && make up` activates changes with no migration. CRITICAL: (1) `limit_req_status 429;` MUST stay — default 503 would hit `error_page 502 503 504 /maintenance.html` (throttled users get the maintenance page) and trip netdata's 5xx alert; `limit_req_log_level warn;` keeps 429 floods out of the `error`-level error-monitoring dashboard. (2) **No global/aggregate cap by design** — per-IP only; whole-host capacity is governed downstream by appserver workers + Docker CPU/RAM limits (`make configure-resources`), not a static front-door req/s (nginx is blind to per-request cost). (3) `/static/`, `/media/`, `/healthz` and auth-gated panels are deliberately unlimited. Measure real per-IP peaks with `make request-stats` before tuning. Detail: `docs/architektura/rate-limiting.md`.

### Healthchecks & autoheal

Docker does NOT restart on failed healthcheck (`restart: always` only reacts to process exit). Sidecar `autoheal` restarts containers labeled `autoheal=true` on `Health.Status=unhealthy` (watched: `workerserver`, `celerybeat`). `celerybeat`'s healthcheck is a lightweight **heartbeat-file freshness** probe (`HeartbeatScheduler` in the bpp image touches `/tmp/celerybeat-heartbeat` every tick; the Compose `test:` is a dispatcher that falls back to the old `healthcheck_broker.py` cold-import probe on pre-June-2026 images — the heavy probe under a low CPU cap was what delayed celerybeat to ~218s on startup). **`denorm-queue` is intentionally NOT autoheal-watched** — its Compose healthcheck is commented out, so it has no health status to react to; it relies on the nightly staggered `kill 1` restart (Ofelia, 05:25) instead. Double-dollar escaping (`$$DJANGO_BPP_DB_USER`) in healthcheck commands prevents premature Compose expansion. Detail: `docs/architektura/healthchecks-autoheal.md`.

### Service dependencies

`appserver` (migrations) before the worker; `workerserver` depends on `appserver` healthy; `denorm-queue` requires `workerserver` healthy; `celerybeat` uses `service_started` for `appserver` (faster start). Service table + data flow: `docs/architektura/uslugi.md`.

### Scheduled jobs / nightly restarts (Ofelia)

Daily maintenance, SSL renew, log rotation, and staggered 05:00–05:25 nightly restarts (`kill 1` via read-only `docker.sock`) are Ofelia labels in the compose files. Full schedule: `docs/architektura/zadania-ofelia.md`.

## Resource Limits

All services (except `backup-runner`) have `*_MEM_LIMIT`/`*_CPU_LIMIT` env vars, sized for an **8 GB host** by default. `make configure-resources` detects host RAM/CPU and proposes a proportional split. RAM limit is **hard** (OOM kill), CPU is **soft** (throttling). Full table + tuning: `docs/konfiguracja/limity-zasobow.md`.

## Optional Feature Flags

**`DJANGO_BPP_ENABLE_HTML2DOCX_IMAGE`** (default `false`): when `true`, `make pull`/`make up` pulls `iplweb/html2docx:latest` as a fallback for HTML→DOCX export. Most installs use pandoc in the appserver image — enable only when pandoc fails. Deployment-side flag only, not propagated to Django.

## Backwards Compatibility and `.env` Migrations — CRITICAL

A new `bpp-deploy` version **must** run on the **old** `$BPP_CONFIGS_DIR/.env` without manual editing. Production updates via `git pull && make up` — every required manual step is a potential outage. Full contract + code patterns: `docs/rozwoj/backwards-compatibility.md`.

**Mandatory two-layer protection** when renaming/adding/changing variables:

1. **Fallback in the reader** — Makefile/scripts accept the old name (`ifdef OLD_VAR; NEW_VAR := $(OLD_VAR); endif`). Works immediately after `git pull`, no user action.
2. **Migration in `scripts/init-configs.sh`** — detect old name and rename in `.env` preserving value, using the stable helpers `env_has_var`, `get_env_var`, `set_env_var` (not custom `grep`/`sed`).

New variables added must have a Compose default (`${VAR:-default}`), ideally a two-tier fallback like `${NEW:-${OLD:-default}}`.

**Don't**: add a new required var without Compose default + migration; remove an old var without migration even if "no one should use it"; assume the user reads release notes and edits `.env` manually; break compatibility in half a release (always add new name + fallback + migration first; remove old name only years later).

## Release Process

Calendar versioning `YYYY.MM.DD[.N]`. `make release` (`scripts/release.sh`): compute next version → `sed` README badge → commit `release: $VERSION` → tag → push `main --tags`. Working tree must be clean (except README). No `CHANGELOG.md` — history is `git log --grep='^release:'`. Detail: `docs/eksploatacja/wydanie.md`.

## Safety

- `make up` (hence `make run`) ends with `docker system prune -af` **after** the stack is healthy (`--wait`) and **before** the html2docx pull (so the fallback image survives). No `--volumes` → named data volumes are safe; but `-af` removes **all** unused images host-wide (incl. non-BPP). Use `make up-quick` on shared/dev hosts to skip it. Don't "fix" this by adding `--volumes`.
- `make up` ends with a **read-only health gate** (`scripts/post-deploy-check.sh`, hooked into the `up` recipe → `run` inherits it; `up-quick` does NOT). Flags compose services that are `unhealthy`/`restarting` (NOT `exited` — that would false-positive on on-demand `backup-runner`). All OK → `✓` + exit 0; problem + **TTY** → prompt `[s]`hell/`[d]`octor + exit 1; problem + **non-TTY** (CI/cron/`| tee`) → exit 1, no prompt. **Fail-open** on the checker's own errors (can't `cd`, no compose) → exit 0, never blocks a deploy. Read-only by design — does NOT send mail/ntfy/Rollbar (those stay opt-in in `make doctor`). Gates on container state, not log-error greps (too noisy). **CRITICAL for internal callers:** any script invoking `make up` non-interactively under `set -e` (currently `scripts/upgrade-postgres.sh` before its `make migrate`, and `scripts/restore.sh`) MUST `export BPP_SKIP_HEALTH_GATE=1` first — else a transient post-`--wait` flap makes the gate `exit 1` (aborting the script mid-sequence) or, under a no-human PTY (`ssh -t`/Ansible), the prompt blocks (mitigated by a 30s `read -t` timeout). A new `make up` caller → set the same env. Tests: `make test-post-deploy-check` (mocks docker/make; like `test-doctor`, not yet in CI's `tests/test_makefile.sh`).
- Always `make db-backup` before major changes
- Use `make` targets instead of raw `docker compose` (they handle dependencies)
- Verify environment-specific config (database markers, backup settings) before destructive operations
- `make help` is the source of truth for available targets

## Documentation maintenance (for agents)

- Operator how-tos go in `docs/`; install/first-run goes in `README.md` (synced pair with `docs/instalacja/`); agent steering stays here.
- Use the **`docs-sync` skill** before editing docs — it has the change→files checklist.
- After editing docs, run `mkdocs build --strict` (catches broken links / nav gaps). The `docs.yml` workflow runs the same on push to `main`.

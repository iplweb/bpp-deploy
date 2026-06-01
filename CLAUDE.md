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

### PostgreSQL version vars

`dbserver` uses `iplweb/bpp_dbserver:psql-${DJANGO_BPP_POSTGRESQL_VERSION}` (`MAJOR.MINOR`, default `16.13`). `DJANGO_BPP_POSTGRESQL_VERSION_MAJOR` (auto-derived) is used by `backup-runner` (`postgres:<major>-alpine`). Major upgrades require dump/restore — use `make upgrade-postgres`, do **not** edit the var manually. Full procedure (rollback, resume): `docs/konfiguracja/postgresql.md`.

## Critical Deployment Patterns

### Running commands in containers

Images are slim — `uv` is no longer present. Use native `python` / `celery`:

- Django: `python src/manage.py <command>` (CWD is the dir above `src/`)
- Celery: `celery -A django_bpp.celery_tasks <command>`

### Safe migrations

`make migrate` automatically: stops denorm workers → runs migrations → restarts workers.

### CRITICAL: denorm-queue is single-instance

`denorm-queue` (PG `LISTEN` → Celery bridge) **must** run as a **single instance** to avoid duplicate message processing. **Do not scale.**

### Logging — add `logging` to new services

All services use the `local` log driver via a per-file `x-logging` YAML anchor. **YAML anchors do not cross `include:` boundaries** — each of the 7 compose files defines its own `x-logging`. **When adding a new service: include `logging: *default-logging` or it falls back to unrotated `json-file`.** Full logging/retention detail: `docs/monitoring/logowanie.md`.

### Healthchecks & autoheal

Docker does NOT restart on failed healthcheck (`restart: always` only reacts to process exit). Sidecar `autoheal` restarts containers labeled `autoheal=true` on `Health.Status=unhealthy` (watched: `workerserver-general`, `workerserver-denorm`). **`denorm-queue` is intentionally NOT autoheal-watched** — its Compose healthcheck is commented out, so it has no health status to react to; it relies on the nightly staggered `kill 1` restart (Ofelia, 05:25) instead. Double-dollar escaping (`$$DJANGO_BPP_DB_USER`) in healthcheck commands prevents premature Compose expansion. Detail: `docs/architektura/healthchecks-autoheal.md`.

### Service dependencies

`appserver` (migrations) before workers; workers depend on `appserver` healthy; `denorm-queue` requires `workerserver-denorm` healthy; `celerybeat` uses `service_started` for `appserver` (faster start). Service table + data flow: `docs/architektura/uslugi.md`.

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

- Always `make db-backup` before major changes
- Use `make` targets instead of raw `docker compose` (they handle dependencies)
- Verify environment-specific config (database markers, backup settings) before destructive operations
- `make help` is the source of truth for available targets

## Documentation maintenance (for agents)

- Operator how-tos go in `docs/`; install/first-run goes in `README.md` (synced pair with `docs/instalacja/`); agent steering stays here.
- Use the **`docs-sync` skill** before editing docs — it has the change→files checklist.
- After editing docs, run `mkdocs build --strict` (catches broken links / nav gaps). The `docs.yml` workflow runs the same on push to `main`.

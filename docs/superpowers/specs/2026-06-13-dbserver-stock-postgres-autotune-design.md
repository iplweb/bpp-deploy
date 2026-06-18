# Spec: migrate `dbserver` from `iplweb/bpp_dbserver` to stock `postgres` + bind-mounted autotune

- **Date:** 2026-06-13
- **Status:** approved design, pre-implementation
- **Scope decision:** full — swap the image **and** simplify the major-upgrade flow
- **Locale decision:** fresh installs initialise with ICU `pl-PL` collation

## 1. Background & motivation

The custom image `iplweb/bpp_dbserver:psql-<MAJOR.MINOR>` is **discontinued**. The
`iplweb/bpp-dbserver` GitHub repo no longer contains a `Dockerfile` — it now ships only
the autotune scripts (`autotune.sh`, `autotune.py`, `docker-entrypoint-autotune.sh`) plus
`examples/docker-compose.yml`, which demonstrates running the autotune step on the **stock
`postgres` image** via a bind-mounted entrypoint (no custom build, no `python3`).

The only thing the discontinued image added on top of stock PostgreSQL was the autotune
step (auto-generated pgtune-style config sized to the container's memory limit). Therefore
this repo migrates the local `dbserver` to the stock `postgres` image with the autotune
scripts bind-mounted on top.

Today this repo references the discontinued image in:

- `docker-compose.database.yml` — the real local DB server (the primary target).
- `scripts/upgrade-postgres.sh` — major-version upgrade (dump/restore) flow.
- `scripts/test-upgrade-postgres.sh` — upgrade test harness.
- `scripts/init-configs.sh` — comments/messages and `.env` version-var setup.

The backup runner (`docker-compose.backup.yml`) and the external-DB sentinel
(`docker-compose.database.external.yml`) already use stock `postgres:<major>-alpine` and are
**out of scope** — they do not run a real DB cluster.

## 2. Goals / non-goals

**Goals**

1. Local `dbserver` runs stock `postgres:<MAJOR.MINOR>` with autotune bind-mounted.
2. Existing `postgresql_data` volumes keep working with **no dump/restore** for the image
   swap (same PG major).
3. Fresh installs initialise with ICU `pl-PL` collation.
4. Major-upgrade flow simplified: no "wait for a prebuilt image" prerequisite; upgrade test
   runs natively on Apple Silicon.
5. No manual `.env` editing required on `git pull && make up` (backwards-compat contract).

**Non-goals**

- Changing the external-DB sentinel or backup-runner images.
- Re-collating existing clusters (ICU `pl-PL` applies to fresh init only).
- Switching the upgrade strategy away from dump/restore (still required across majors).
- Removing the `DJANGO_BPP_POSTGRESQL_VERSION` / `_MAJOR` variables or their migrations.

## 3. The autotune scripts (copied into this repo)

Copied **verbatim** from `iplweb/bpp-dbserver@main` (the scripts are "ours"). Two files,
placed in a new repo-root directory `dbserver/`:

- `dbserver/autotune.sh` — pure `/bin/sh` + `awk` pgtune-style generator. **cgroup-aware**:
  reads `/sys/fs/cgroup/memory.max` (v2) or `memory.limit_in_bytes` (v1), falls back to
  `/proc/meminfo`, and sizes `shared_buffers` (RAM/4), `effective_cache_size` (3·RAM/4),
  `work_mem`, `maintenance_work_mem`, WAL, parallelism, etc. Uses **95%** of the detected
  limit by default. Has a `--test` self-check (byte-parity with the Python original).
- `dbserver/docker-entrypoint-autotune.sh` — `#!/usr/bin/env bash` wrapper:
  1. defaults & exports `PGDATA` (`/var/lib/postgresql/data`),
  2. runs `/usr/local/bin/docker-ensure-initdb.sh` (standard image initdb),
  3. idempotently appends `include_if_exists = '/postgresql_optimized.conf'` to
     `$PGDATA/postgresql.conf`,
  4. generates `/postgresql_optimized.conf` by running `$AUTOTUNE_SCRIPT` (default
     `/autotune.sh`),
  5. `exec /usr/local/bin/docker-entrypoint.sh "$@"`.

**Delivery mechanism: bind-mount from the repo working tree — NOT force-sync into
`$BPP_CONFIGS_DIR`.** Rationale: these are versioned code, not user-tunable config, so a
`git pull` keeps them current with zero machinery. This mirrors the existing pattern where
`backup-runner` bind-mounts `./scripts:/scripts:ro`. Compose resolves the relative paths
against the compose-file directory (the repo), independent of CWD. **No `chmod +x` needed:**
neither script is exec'd directly — the entrypoint is invoked as `["bash", "...autotune.sh"]`
and the wrapper runs autotune via `sh "$AUTOTUNE_SCRIPT"` — so a missing exec bit on the `:ro`
mount is irrelevant.

**Autotune env knobs** (all optional; read from the container's *runtime* environment). To
make these reach the script, the `dbserver` service gets its own **service-level**
`env_file: ${BPP_CONFIGS_DIR}/.env` (see §4). The `include`-level `env_file` in
`docker-compose.yml` only supplies variables for **compose-file interpolation** and is **not**
injected into containers — so a service-level `env_file` is required (this is exactly how the
external sentinel at `docker-compose.database.external.yml:39` and `backup-runner` already
work). `compose` applies `environment:` over `env_file`, so our explicit `POSTGRES_*`/`PGDATA`/
`POSTGRES_INITDB_ARGS` keys always win. None of the autotune knobs are currently set anywhere
in the repo, so defaults apply:
`POSTGRESQL_RAM_PERCENT` (0.95), `POSTGRESQL_RAM_THIS_MUCH_GB`, `POSTGRESQL_DEFAULT_RAM`
(4096), `POSTGRESQL_UNSAFE_BUT_FAST`, `POSTGRESQL_MAX_LOCKS_PER_TRANSACTION`,
`POSTGRESQL_MAX_PRED_LOCKS_PER_TRANSACTION`.

## 4. `docker-compose.database.yml` changes

Target `dbserver` service:

```yaml
dbserver:
  logging: *default-logging
  # Stock PostgreSQL (obraz oficjalny, Debian) + autotune bind-mountowany z repo.
  # Tag wybiera DJANGO_BPP_POSTGRESQL_VERSION (MAJOR.MINOR). Dwuwarstwowy fallback:
  # nowa nazwa -> stara (DJANGO_BPP_DBSERVER_PG_VERSION) -> default 16.13.
  # Tagi: https://hub.docker.com/_/postgres
  image: postgres:${DJANGO_BPP_POSTGRESQL_VERSION:-${DJANGO_BPP_DBSERVER_PG_VERSION:-16.13}}
  restart: always
  # Service-level env_file: wstrzykuje .env do RUNTIME kontenera (include-level
  # env_file sluzy tylko interpolacji compose, NIE trafia do kontenera). Daje to
  # autotune'owi knoby POSTGRESQL_* i jest spojne z sentinelem/backup-runnerem.
  env_file: ${BPP_CONFIGS_DIR}/.env
  # bash + docker-ensure-initdb.sh => obraz Debianowy (NIE -alpine).
  entrypoint: ["bash", "/usr/local/bin/docker-entrypoint-autotune.sh"]
  command: ["postgres"]
  environment:
    POSTGRES_DB: ${DJANGO_BPP_DB_NAME}
    POSTGRES_USER: ${DJANGO_BPP_DB_USER}
    POSTGRES_PASSWORD: ${DJANGO_BPP_DB_PASSWORD}
    # KRYTYCZNE: stock postgres:18+ domyslnie ma PGDATA=/var/lib/postgresql/18/docker.
    # Bez tego pinu istniejacy volume zostalby zignorowany i baza zainicjowana od zera.
    PGDATA: /var/lib/postgresql/data
    # Tylko przy PUSTYM PGDATA (fresh install): kolacja ICU pl-PL dla polskiego sortowania.
    POSTGRES_INITDB_ARGS: "--locale-provider=icu --icu-locale=pl-PL"
  volumes:
    - ./dbserver/docker-entrypoint-autotune.sh:/usr/local/bin/docker-entrypoint-autotune.sh:ro
    - ./dbserver/autotune.sh:/autotune.sh:ro
    - postgresql_data:/var/lib/postgresql/data
    - ${DJANGO_BPP_HOST_BACKUP_DIR}:/backup
  healthcheck:
    # Stock postgres nie ma wbudowanego healthchecku (dawny obraz mial HEALTHCHECK
    # w Dockerfile). appserver/authserver maja depends_on: dbserver: service_healthy,
    # wiec healthcheck jest WYMAGANY. Podwojny $$ zapobiega ekspansji przez Compose.
    # Uzywamy POSTGRES_USER/POSTGRES_DB (ustawione jawnie w environment: wyzej, wiec
    # ZAWSZE obecne) zamiast DJANGO_BPP_DB_* - nie zalezy od env_file.
    test: ["CMD-SHELL", "pg_isready -U \"$$POSTGRES_USER\" -d \"$$POSTGRES_DB\""]
    interval: 10s
    timeout: 5s
    retries: 5
    start_period: 60s
  deploy:
    resources:
      limits:
        memory: ${DBSERVER_MEM_LIMIT:-2g}
        cpus: "${DBSERVER_CPU_LIMIT:-2.0}"
```

Unchanged: the `postgresql_data` volume definition, the `${DJANGO_BPP_HOST_BACKUP_DIR}`
bind, the resource limits (autotune reads this cgroup memory limit), the `logging` anchor.

`pg_isready` with no `-h` connects via the local socket inside the container; this verifies
the cluster (not merely the port). `start_period: 60s` covers cold start and first-init.

### Decisions baked in (flagged earlier, no further input requested)

- Scripts live in **`dbserver/`** at repo root (vs `scripts/dbserver/`).
- Healthcheck cadence: `interval 10s / timeout 5s / retries 5 / start_period 60s`.
- `POSTGRES_INITDB_ARGS` mirrors the upstream example **verbatim**
  (`--locale-provider=icu --icu-locale=pl-PL`); no explicit `--encoding`/`--locale` — the
  stock image's `LANG=en_US.utf8` supplies a UTF-8 `LC_CTYPE` and UTF8 encoding, which is
  ICU-compatible.
- Healthcheck uses `$$POSTGRES_USER`/`$$POSTGRES_DB` (set in `environment:`), not
  `$$DJANGO_BPP_DB_*` — guaranteed present and independent of `env_file`.
- **PG18 caveat:** `postgres:18+` relocated its declared `VOLUME` from
  `/var/lib/postgresql/data` to `/var/lib/postgresql`. We deliberately keep mounting
  `postgresql_data` at `/var/lib/postgresql/data` **and** pin `PGDATA` there (matching the
  existing volume and the upstream example). Do **not** "modernise" the mount to
  `/var/lib/postgresql` — that would orphan every existing cluster.

## 5. Backwards compatibility

- **No `.env` migration needed.** `DJANGO_BPP_POSTGRESQL_VERSION` (e.g. `16.13`) already maps
  directly to a valid stock tag `postgres:16.13`. The two-tier fallback to
  `DJANGO_BPP_DBSERVER_PG_VERSION` is preserved in the compose `image:` line.
- **Existing volumes** start unchanged: same PG major, and `PGDATA` is pinned to the existing
  mount path, so stock postgres reads the existing cluster (the old image was stock postgres +
  autotune). No dump/restore for the swap.
- **Accepted divergence:** fresh installs collate Polish via ICU `pl-PL`; pre-existing volumes
  keep their original collation. `POSTGRES_INITDB_ARGS` never re-collates an existing cluster.

## 6. Upgrade flow simplification

`scripts/upgrade-postgres.sh`:

- `NEW_DBSERVER_IMAGE` (currently `iplweb/bpp_dbserver:psql-${NEW_POSTGRESQL_VERSION}`, ~line
  552) → `postgres:${NEW_POSTGRESQL_VERSION}`. The `docker pull` (~line 679) still works.
- Remove the "upstream image with the new major MUST already be published" prerequisite and
  the `hub.docker.com/r/iplweb/bpp_dbserver/tags` messaging (~lines 27, 507). Stock postgres
  always publishes every major.
- Dump → recreate volume → restore across majors is **unchanged** (still required).

`scripts/test-upgrade-postgres.sh`:

- Drop **both** the inline `platform: linux/amd64` key + comment (~lines 86-89) **and** the
  `DOCKER_DEFAULT_PLATFORM=linux/amd64` export block (~lines 121-130). Removing only the
  inline key would leave the `export` still force-pulling amd64 under qemu — it affects both
  `docker pull` and `docker compose`. Stock postgres is multi-arch → native on Apple Silicon.
- Point the harness at `postgres:${DJANGO_BPP_POSTGRESQL_VERSION:-16.13}` (~line 89) and
  **mirror the production service**: service-level `env_file: ${BPP_CONFIGS_DIR}/.env`,
  bind-mount the autotune scripts, set `entrypoint`/`command`, pin `PGDATA`, and add the
  `pg_isready -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"` healthcheck — same C1 fix as §4, so the
  test reflects the real deployment. The healthcheck here is **mandatory, not cosmetic**:
  `wait_for_healthy` (~lines 152-171) polls `.State.Health.Status`, and stock postgres has no
  baked-in `HEALTHCHECK` (the old image did) — without it the test loops until timeout.

## 7. Touch-ups

- `scripts/init-configs.sh`: reword comments/messages mentioning
  `iplweb/bpp_dbserver:psql-<ver>` and the hub.docker.com tags page (~lines 301-302, 421-435,
  756-760) to stock-`postgres` wording. **The version-variable logic and the old-name
  migrations stay exactly as they are** (`DJANGO_BPP_POSTGRESQL_VERSION` = MAJOR.MINOR,
  `_MAJOR` derived; migrations from `DJANGO_BPP_DBSERVER_PG_VERSION` /
  `DJANGO_BPP_POSTGRESQL_DB_VERSION` preserved).
- `scripts/check-image-versions.sh`: this script skips `iplweb/*` images. After the swap,
  `postgres:<ver>` is no longer skipped, so it joins the version report. That is desirable for
  minor updates but will also surface major bumps (e.g. `16.x → 18.x`) that actually require
  `make upgrade-postgres`. Add a one-line comment noting this; **no logic change.**

## 8. Documentation (via the `docs-sync` skill)

- `docs/konfiguracja/postgresql.md` — image source, autotune mechanism, simplified upgrade
  flow.
- `docs/konfiguracja/limity-zasobow.md` — note that the DB autotune reads the `DBSERVER_MEM_LIMIT`
  cgroup limit (~95%), so `make configure-resources` drives PostgreSQL tuning.
- `CLAUDE.md` — "PostgreSQL version vars" and "Running commands in containers" sections:
  replace the `iplweb/bpp_dbserver` references; document the bind-mounted autotune + `dbserver/`
  dir + the force-sync exception (these scripts are bind-mounted, not force-synced).
- `README.md` — only if it names the image.
- Run `mkdocs build --strict` afterwards.

## 9. Verification

1. `docker compose config` validates (interpolation + merged service).
2. `bash dbserver/autotune.sh --test` passes (built-in parity self-test).
3. Bring `dbserver` up on a copy of an existing-style `postgresql_data` volume: starts
   `healthy`, `/postgresql_optimized.conf` is generated, `SHOW shared_buffers;` tracks
   `DBSERVER_MEM_LIMIT` (≈ limit/4).
4. Fresh-init smoke test: empty volume → `SHOW lc_collate;` / `datlocprovider` reflects ICU
   `pl-PL`.
5. `appserver`/`authserver` reach `service_healthy` gate (depend on `dbserver` healthy).
6. Existing CI green: Makefile tests (Linux/macOS/Windows) + docker-compose validation.
7. Upgrade path: `scripts/test-upgrade-postgres.sh` runs on Apple Silicon without
   `platform: linux/amd64`.

## 10. Risks & mitigations

| Risk | Mitigation |
|---|---|
| `postgres:18+` re-inits a blank cluster on an existing volume | Pin `PGDATA=/var/lib/postgresql/data` (matches existing mount). |
| Missing healthcheck → `appserver`/`authserver` never start | Add `pg_isready` healthcheck (§4). |
| Healthcheck/autotune vars silently empty — `include`-level `env_file` is interpolation-only, not injected into the container | Service-level `env_file` on `dbserver`; healthcheck uses the explicit `environment:` keys `$$POSTGRES_USER`/`$$POSTGRES_DB` (§3/§4). |
| Using `-alpine` (no bash) breaks the entrypoint | Use the Debian-based `postgres:<ver>` tag explicitly. |
| ICU locale id invalid on the chosen major | `--icu-locale` valid on PG 15–18; default `16.13` is in range. |
| `check-image-versions.sh` suggests a major jump as "latest" | Documented comment; major bumps go through `make upgrade-postgres`. |

## 11. Out of scope / follow-ups

- Removing the discontinued image's old tags from anyone's local cache (they still exist on
  Docker Hub; existing installs keep working until they `git pull`).
- Stray repo-root artifacts (`#docker-compose.database.yml#`, `REVIEW.md~`) — unrelated.

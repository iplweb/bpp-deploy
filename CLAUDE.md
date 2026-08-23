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
- Planned-downtime deploys (`run-with-warning`): `docs/eksploatacja/przerwa-techniczna.md`
- Backups / server migration: `docs/eksploatacja/backup-i-rclone.md`, `docs/eksploatacja/przenosiny-serwera.md`
- Monitoring / logging / slow queries: `docs/monitoring/*`
- Services / healthchecks / Ofelia jobs: `docs/architektura/*`
- Rate limiting (nginx, per-tier `limit_req`): `docs/architektura/rate-limiting.md`
- Edge hardening (nginx, `server_tokens`, blokady `*.php`/CMS/`{{…}}`, timeouty): `docs/architektura/utwardzenie-brzegu.md`
- WAF (ModSecurity + OWASP CRS, wykluczenia reguł): `docs/architektura/waf.md`
- Backwards-compat contract: `docs/rozwoj/backwards-compatibility.md` (summarized below — read both)

**Traps for code authors — read the page BEFORE editing the matching file.** Each collects failure modes that are invisible in review and produce a "nothing works" symptom with no log trace:

| Editing… | Read first |
|---|---|
| `defaults/grafana/provisioning/dashboards/*.json` | `docs/rozwoj/pulapki-grafany.md` |
| `defaults/alloy/config.alloy` | `docs/rozwoj/pulapki-alloy.md` |
| `scripts/autoupdate.sh`, `scripts/deploy-with-warning.sh`, `scripts/site-down-warning.sh`, `mk/deployment.mk` | `docs/rozwoj/pulapki-wdrozenia.md` |
| `defaults/webserver/*` | `docs/architektura/waf.md` + `docs/architektura/utwardzenie-brzegu.md` |
| kompresja (`gzip_*`, brotli, zstd) w `_bpp-locations.conf` | `docs/rozwoj/pulapki-kompresji.md` |

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
- `alloy/config.alloy`
- `loki/local-config.yaml` (rendered host-side from `defaults/loki/local-config.yaml.tpl`)

Everything else under the config dir stays `copy_if_missing`. Dashboards removed from `defaults/` are left in place; UI-created Grafana dashboards live in Grafana's DB and are unaffected.

**Rule:** versioned, read-only-in-UI artifacts must reach existing installs on `git pull && make up`. Anything the operator may legitimately tune is parametrized via `.env` instead (`NETDATA_DBENGINE_*`, `LOKI_RETENTION_*`) so the overwrite can't wipe it. **Never tell users to hand-edit a force-synced file — point them at the `.env` knob.**

**Adding a file to this list:** an existing install must keep its tuned values. Read them out of the operator's current file and write them into `.env` (what the Loki retention migration does with `awk`) — writing repo constants silently resets tuning on a plain `git pull && make up`, exactly what the backwards-compat contract forbids. Render guards and the `init-configs`-before-`.env` ordering: `docs/konfiguracja/architektura.md`.

Leaving a config on `copy_if_missing` freezes it **at install time forever** — that's how the CRS severity mapping (`60ea290`) reached no deployment at all, and why Loki's level detection had to ship as a CLI flag workaround. Both are cautionary tales, not patterns to copy.

### Staticfiles volume — contract with appserver image

`staticfiles` is populated by `appserver` (mount `/staticroot`) and served by `webserver`/nginx (mount `/var/www/html/staticroot`). Source is `/app/staticroot.baked/` baked into the appserver image at build time. Entrypoint Phase 2 runs `cp -rf /app/staticroot.baked/. "$STATIC_ROOT/"` — seeds an empty volume and **always overwrites** on upgrade (`-u` was a trap: `.baked` mtimes come from image build, so a recent restart made `-u` skip the copy and leave stale files). Files absent from `.baked` survive — `cp` doesn't delete. Runtime does **not** run `collectstatic` (fallback only for pre-`.baked` images). `STATIC_ROOT=/staticroot/` in `.env` overrides image default. After `make refresh`/`prune-orphan-volumes`, volume is repopulated from `.baked`.

**Compression is the appserver image's job, not ours.** `gzip_static on` is set in `_bpp-locations.conf`, but it only means "serve `x.js.gz` if it exists" — with no `.gz` files it is a **silent no-op** (it was, for the whole life of that config: 3429 files, 0 `.gz`). The `.gz` must be generated **in the same build step as the source file**, because nginx serving `x.js.gz` **does not compare mtime with `x.js`** — a stale `.gz` means serving old JS forever, to every browser, with no log trace. Don't "fix" a missing-`.gz` by adding a runtime compression step over the `staticfiles` volume. Brotli/zstd have been measured and rejected — **don't re-propose them without reading the page**, three separate blockers make it a custom-image project, not a config change. Detail: `docs/rozwoj/pulapki-kompresji.md`.

### Media volume — `DJANGO_BPP_MEDIA_ROOT` is required

User uploads land in the `media` volume mounted at `/mediaroot` in every Django container. **`DJANGO_BPP_MEDIA_ROOT=/mediaroot` in `.env` is required** — without it Django falls back to its built-in default (`~/bpp-media` = `/root/bpp-media` in the container), which is **not** on the volume: uploads vanish on recreate and are excluded from backups (`backup-cycle.sh` tars `/mediaroot`). Set in two places (sibling of `STATIC_ROOT`): the fresh-`.env` heredoc + `ensure_env_var` in `scripts/init-configs.sh`, and an append-only self-heal (`_ensure_var`) in `scripts/ensure-config-files.sh` so `git pull && make up` fixes old `.env` files with no manual step. Don't add a new media path without keeping all three in sync. Detail: `docs/konfiguracja/architektura.md`.

### PostgreSQL version vars

`dbserver` uses the **stock official** `postgres:${DJANGO_BPP_POSTGRESQL_VERSION}` image (Debian, **not** `-alpine` — the entrypoint needs `bash`) with the autotune scripts in **`dbserver/`** **bind-mounted** read-only on top. The old `iplweb/bpp_dbserver` image is **discontinued** — autotune was its only delta. Those scripts are versioned code delivered by `git pull` — **not** force-synced into `$BPP_CONFIGS_DIR`.

Four contracts, each fatal if dropped:

1. **`PGDATA` pinned to `/var/lib/postgresql/data`** — stock `postgres:18+` defaults to a versioned subdir → would ignore the existing volume and re-init blank. Never change the mount to `/var/lib/postgresql`.
2. **Fresh installs init with `POSTGRES_INITDB_ARGS=--locale-provider=icu --icu-locale=pl-PL`** — fresh PGDATA only, never re-collates an existing cluster.
3. **`dbserver` defines its own healthcheck** (`pg_isready`) — stock postgres has none, and appserver/authserver `depend_on: service_healthy`.
4. **`dbserver` needs a service-level `env_file`** — the `include`-level one is interpolation-only and is NOT injected into the container.

Fresh installs default **`18.4`**; the Compose safety-net stays **`:-16.13`** so an ancient `.env`-less PG16 install isn't handed a PG18 image. `backup-runner` **shares `dbserver`'s image** by default (`BPP_BACKUP_PG_IMAGE` unset → 100% shared layers); only **external mode** points it at `postgres:<major>-alpine`, written by `init-configs` and self-healed by `ensure-config-files`. Major upgrades require dump/restore — use `make upgrade-postgres`, do **not** edit the var manually. Detail: `docs/konfiguracja/postgresql.md`.

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

### Log level (`detected_level`) — single source, closed vocabulary

`defaults/alloy/config.alloy` is the **only** producer of `detected_level` (Loki's built-in `discover_log_levels` is off; its twin `discover_service_name` can't be disabled compatibly and stays on as a cosmetic duplicate). Vocabulary is a **closed set of 7**: `critical, error, warn, info, debug, trace, unknown` — every detector writes its own `lvl_*` key and a single `stage.template` gate picks the first non-empty in trust order. **Don't add normalization as another `stage.replace`** — extend the gate.

**Before editing that file read `docs/rozwoj/pulapki-alloy.md`.** Three ways to break it invisibly: consecutive `stage.regex` overwrite the same key (**last wins**), `stage.template` referencing a key `stage.json` didn't create renders the literal `<no value>`, and `\berror\b` matches *inside* a URL path. Verify with `make test-alloy` (real config, real log lines).

WAF hits produce **two Loki entries per request** (`modsec_src` = `audit` / `nginx`) with **different field sets**. **Any aggregation must filter BOTH `modsec_src="audit"` (or it double-counts) AND `modsec_rule_id != ""`** (or 401s/429s/5xx count as attacks); the logs panel deliberately shows `nginx`. The 15 `modsec_*` fields are structured metadata, never stream labels. Hits are levelled `warn`, not `error`. Detail: `docs/architektura/waf.md`.

### Logging — add `logging` to new services

All services use the `local` log driver via a per-file `x-logging` YAML anchor. **YAML anchors do not cross `include:` boundaries** — each of the 7 compose files defines its own `x-logging`. **When adding a new service: include `logging: *default-logging` or it falls back to unrotated `json-file`.** Full logging/retention detail: `docs/monitoring/logowanie.md`.

### Rate limiting (nginx)

Per-IP `limit_req` on `/admin/` (50r/s), `/api/` (60r/s) and the rest (`location /`, 100r/s), all `nodelay`, `burst = rate`. **Two-file split: zones (`limit_req_zone` + `rate`) live in `defaults/webserver/default.conf.template` (http context); the `limit_req` directives (+ `burst`) live in `defaults/webserver/_bpp-locations.conf` (server context).** Hardcoded, **not** `.env` — nginx `envsubst` can't do `${VAR:-default}` and `_bpp-locations.conf` isn't envsubst'd at all. Versioned bind-mounted files (not `$BPP_CONFIGS_DIR`), so `git pull && make up` activates changes with no migration. CRITICAL: (1) `limit_req_status 429;` MUST stay — default 503 would hit `error_page 502 503 504 /maintenance.html` (throttled users get the maintenance page) and trip netdata's 5xx alert; `limit_req_log_level warn;` keeps 429 floods out of the `error`-level error-monitoring dashboard. (2) **No global/aggregate cap by design** — per-IP only; whole-host capacity is governed downstream by appserver workers + Docker CPU/RAM limits (`make configure-resources`), not a static front-door req/s (nginx is blind to per-request cost). (3) `/static/`, `/media/`, `/healthz` and auth-gated panels are deliberately unlimited. Measure real per-IP peaks with `make request-stats` before tuning. Detail: `docs/architektura/rate-limiting.md`.

### Edge hardening (nginx) — blocks that are *not* the WAF

Requests that are not attacks but are **not ours** (CRS passes them, correctly). All in versioned bind-mounts → `git pull && make up`, no `.env` migration. Four rules + `server_tokens`, all covered by `make test-waf` (48 cases). Detail: `docs/architektura/utwardzenie-brzegu.md`.

Four rules → `444` (executable extensions, ~30 foreign-app prefixes, template literals `{{…}}`/`${…}`) plus client timeouts. Constraints that are non-obvious and were each established by measurement:

- **`php[0-9]*` is a class, not an enumeration** — real probes include `.php73`, `.php56`, `.PhP7`.
- **The trailing `(/|$)` on the prefix list is mandatory** — without it `administrator` also catches `/admin/` (the Django panel). Generic English words (`console`, `debug`) are deliberately excluded — they could become real BPP paths.
- **Do not extend the prefix list speculatively.** Measured volume is ~0.3 req/h, scanner wordlists have tens of thousands of entries (completeness is unreachable), and every entry risks colliding with a future BPP URL. Re-derive from your own log, don't copy from the internet.
- **Template-literal matching must not rely on `\s*`** — nginx does not decode `+` to space in the *path*, so `%7B%7B+clickURL+%7D%7D` slipped past the previous pattern for months.
- **`server_tokens off;` is a regression fix, not a new policy** — the image's own directive vanished with the template we overwrite, and **setting `SERVER_TOKENS` in Compose does nothing** (no template reads it any more).

**CRITICAL — never add `client_body_timeout` to `default.conf.template`.** The CRS image sets it in the `http` context; a repeat there is `[emerg] directive is duplicate` → the whole site fails to start. Tune it via the `CLIENT_BODY_TIMEOUT` env var instead; same for `KEEPALIVE_TIMEOUT` and `WORKER_CONNECTIONS`. `client_header_timeout`/`send_timeout` are *not* set by the image, so they live in our file.

**Trap for any change here: regex `location` beats plain prefix.** That is *why* these rules also cover `/static/` and `/media/` — and why no extension we actually serve may enter the list (`\.js$` would kill the site's static assets, even though the identical entry inside the `/media/` block is correct). Same class of bug that forced `^~` on `/.well-known/`.

### WAF (ModSecurity + OWASP CRS)

`webserver` is `owasp/modsecurity-crs:nginx` and **blocks** (`MODSEC_RULE_ENGINE=On`, `BLOCKING_PARANOIA=1`). Local exclusions live in `defaults/webserver/modsecurity-override.conf.template` (versioned bind-mount, ID range `1-99999`). CRITICAL: the file is included **before** CRS rules, so `SecRuleRemoveById` there is a no-op — you must use a `ctl` action inside your own rule, which runs during the transaction. **`ctl:responseBodyAccess` does not exist in libmodsecurity v3** — nginx refuses to start with it (`Expecting an action, got: …`); working `ctl` actions include `ruleEngine`, `auditEngine`, `ruleRemoveById` (ranges `A-B` OK) and `ruleRemoveByTag`.

**Outbound rules (`RESPONSE-95x`) are the trap** — they scan the *response body*, a single `severity:ERROR` hit already meets `ANOMALY_OUTBOUND=4`, and `959100` fires in `phase:4` when headers are usually already sent, so it can't return 403 and the access log records **`500 0`** — a symptom pointing nowhere near the WAF. Rule `10004` strips `950000-959999` for `/grafana/`, `/dozzle/`, `/flower/`, `/netdata/`; inbound protection there stays fully enforced. Rule `10005` disables `920280` for h2/h3 (connector can't see `:authority`).

**Rule `10007` strips `931100` on `^/(o|\.well-known)/` — without it the whole OAuth flow is dead.** Symptom: API/MCP login dies on a **torn connection** (`curl 52`, no 403 — we map blocks to 444) and Grafana shows *"RFI Attack: URL Parameter using IP Address"*. Cause: CRS treats the loopback `redirect_uri=http://127.0.0.1:<port>/callback` as RFI — the form RFC 8252 §7.3 **requires** (`localhost` is NOT RECOMMENDED there, and ironically passes). Severity CRITICAL = 5 at threshold 5, so one hit blocks. **Don't narrow this to `ctl:ruleRemoveTargetById=…;ARGS:redirect_uri`** — it fixes `/o/authorize/` + `/o/token/` but not DCR, where the arg is `ARGS:json.redirect_uris.array_0` (name depends on body format *and* array index), so client registration still 403s. **Don't widen it past those two prefixes** either: control assertions in `make test-waf` require the same payload to stay blocked elsewhere, because without them the OAuth cases pass even with the rule deleted. **`/o/` and `/.well-known/` are one surface — keep them together**: the client reads `authorization_endpoint`/`token_endpoint` out of the discovery document before it can touch `/o/` at all. Escape the dot (`\.well-known`) — unescaped, the alternation with `o` matches any one-char prefix. Separately, `/.well-known/` also has a **routing** trap that looks identical but leaves no WAF log at all: regex `location ~ /\.` outranks a plain prefix and 403s discovery, which is why `_bpp-locations.conf` needs `^~` there. Detail: `docs/architektura/waf.md#oauth-petla-zwrotna`.

**Rule `10008` drops `accept-charset` from `920450`'s restricted-header list.** Symptom to recognize: a user is blocked on a **perfectly valid URL** (the report was `/bpp/rekord/`) — `920450` is the **only** CRS rule that blocks with no relation to path, args or body, so check it first whenever the URI looks innocent. It matches header *names* against `tx.restricted_headers`; `accept-charset` is there as a bot fingerprint (deprecated header), not as an attack signature, and older HTTP libraries and bibliographic harvesters still send it. **Don't `ctl:ruleRemoveById=920450`** — the same list carries `proxy` (httpoxy, CVE-2016-5385); redefine the list via `SecAction` instead, which works only because our file is included *before* CRS and `REQUEST-901-INITIALIZATION.conf` sets the default only if unset. Don't move this to `crs-setup.conf`'s commented `900250` — that file isn't ours and `git pull` wouldn't update it. Both test cases are mandatory: without the `Proxy`-still-blocked control, deleting the whole rule would also pass. Detail: `docs/architektura/waf.md#naglowki-zakazane`.

**`/grafana/` is exempt from the WAF entirely (rule `10006`, `ctl:ruleEngine=Off`) — not the same thing as `10004`.** Symptom when it's missing: **every panel on every dashboard shows "No data"** while Grafana itself looks healthy (only `POST /grafana/api/ds/query` is 403'd, GETs pass). **Don't "fix" this by excluding `932110`** — the coupling is structural: LogQL is metacharacter-dense by nature and the WAF dashboard's cross-filters feed the WAF its own findings, so every new dashboard field would add another rule to exclude. Exempting is safe only because the location sits behind `auth_request /_bpp_superuser_auth`. **Don't extend `10006` to the other three panels without measuring**, and don't drop `/grafana/` from `10004`.

**Admin model forms (`^/admin/<app>/<model>/`) run with `ctl:ruleEngine=DetectionOnly` (rule `10009`) — the login form deliberately does NOT.** Symptom that puts you here: an editor can't save a record and the request leaves **no trace in the Django logs at all** (it never reached Django). Free scientific text at PL1 lights a new CRS rule every few weeks — `932130`, then `932115`, `933210`, `930110` — so **don't "fix" a new one by appending another rule ID**; the whole path is already permissive, and a fresh block there means `10009` isn't reaching the install. **Never re-target this rule at `REQUEST_URI`** — the pattern has two variable segments, so `?next=/admin/` closes it on `/admin/login/` and would strip the entire CRS from the only anonymously reachable admin endpoint, which is exactly where the real attacks land (338 blocks in 7 days, measured 2026-08-23). Accepting real RCE/SQLi/XSS on those forms is the deliberate price, pinned by three `CENA:` PASS assertions in `make test-waf`; a green run with those flipped to BLOK means someone narrowed the rule. Detail: `docs/architektura/waf.md#formularze-admina`.

Two asymmetries to know before trusting a green run: `make test-waf` does **not** cover the `10004` exclusion (locally `auth_request` suppresses response inspection; production differs, cause unexplained) — but it **does** cover `10006` and h3 for real, verified red-without-the-rule. Detail: `docs/architektura/waf.md`.

### Grafana dashboards — two traps that both look like "everything is No data"

Both were live in shipped dashboards; both were invisible to assertions that only grepped the JSON. **Read `docs/rozwoj/pulapki-grafany.md` before editing dashboard JSON.**

**1. A data link starting with `?` loses the dashboard path.** `"url": "?var-service=…"` *looks* like a valid relative URL, but Grafana does no URL resolution — the string goes to `locationService.push()`, whose router parses it as `pathname: ''` → **Grafana home page**. **Always write `"/d/<uid>?…"`** (works under the production subpath too). Interpolate with **`${var:queryparam}`** — only that expands multi-value variables and preserves `$__all` — and add **`:percentencode`** on `${__data.fields.X}` accessors, or a `?` inside the value splits the query string. Every link must carry the **complete** variable set, otherwise a click silently resets the other filters.

**2. Grafana's own "Filter for value" breaks any dashboard querying structured metadata.** The ad-hoc filter is injected into the **stream selector**, `modsec_*` are structured metadata by design, so no stream matches and **every** panel goes empty at once. **The button cannot be removed from dashboard JSON.** The fix is a **no-op parser** ending every `waf.json` query — `| logfmt bpp_noop="__bpp_noop__" | drop bpp_noop` — which flips Grafana's internal guess to the label-filter branch. **It must stay the LAST pipeline stage** (otherwise it chews the whole webserver stream instead of the already-filtered lines); a separate assertion guards the position independently of the presence check. `error-monitoring.json` deliberately does **not** get this: its ad-hoc filters target real stream labels, and moving them into the pipeline would trade an index lookup for a full scan on the one dashboard querying *all* containers.

Field-set asymmetry any new WAF filter must respect: `modsec_attack`, `modsec_rules`, `modsec_code`, `modsec_method`, `modsec_paranoia` exist **only** on the audit twin. Applying `$attack` to the logs panel (which deliberately shows `nginx`) would empty it whenever a category is selected — i.e. reproduce the very bug. Guarded by `test_waf_crossfilter` in `tests/test_makefile.sh`. Detail: `docs/architektura/waf.md#pulapka-filtrow-ad-hoc`.

### CRITICAL: webserver runs unprivileged — `webserver-init` must precede it

`owasp/modsecurity-crs:nginx` is built on the **unprivileged** nginx variant (`USER nginx`, uid 101, pid in `/tmp`). The plain `nginx` image used before the WAF migration ran master as **root** and could read anything. Now every file nginx opens must be reachable by uid 101 — and two are not, both fatal at startup (`[emerg]` → the whole site is down):

1. **Named volumes** are created by Docker as `root:root 0755` → nginx cannot create `bpp_access.log`.
2. **Private keys** are created `root` `0600` — `openssl` default in `generate-snakeoil-certs.sh`, and certbot's hardcoded `BASE_PRIVKEY_MODE = 0o600` with `live/`+`archive/` at `0700`. Affects **both** SSL modes (in `letsencrypt` mode a missing cert falls back to the same snakeoil).

The one-shot `webserver-init` service (`docker-compose.infrastructure.yml`, `user: "0:0"`, `restart: "no"`, `depends_on: service_completed_successfully`) fixes both on every `make up`. Ownership model: **owner stays root, group becomes `nginx`, mode `0640` (dirs `0750`)** — never world-readable. `chown`/`chgrp` **by name, not uid**, so an upstream uid change can't silently break it. `letsencrypt/accounts/` is deliberately untouched (ACME account key can issue/revoke certs).

**Renewals happen without a restart**, so `webserver-init` alone is not enough — the same `chgrp`/`chmod` lives in certbot's `--deploy-hook` in two places: the Ofelia label in `docker-compose.application.yml` and `LE_DEPLOY_HOOK` in `scripts/letsencrypt.sh` (used for issue **and** renew). Without it a renewed cert would be unreadable, reload would fail, and the cert would expire despite a successful `renew`.

**Testing trap:** bind mounts from `mktemp -d` do NOT reproduce this — they inherit host ownership (and on macOS/OrbStack appear as the container user), so uid 101 can write. Only **named volumes** reproduce production. `test-waf.sh` uses one deliberately, and `chmod -R a+rX "$TMP"` on its cert dir (0700 dir + 0600 key would block nginx on Linux). Static assertions in `tests/test_makefile.sh` guard the compose wiring.

### Healthchecks & autoheal

Docker does NOT restart on failed healthcheck (`restart: always` only reacts to process exit). Sidecar `autoheal` restarts containers labeled `autoheal=true` on `Health.Status=unhealthy` (watched: `workerserver`, `celerybeat`). `celerybeat`'s healthcheck is a lightweight **heartbeat-file freshness** probe (`HeartbeatScheduler` in the bpp image touches `/tmp/celerybeat-heartbeat` every tick; the Compose `test:` is a dispatcher that falls back to the old `healthcheck_broker.py` cold-import probe on pre-June-2026 images — the heavy probe under a low CPU cap was what delayed celerybeat to ~218s on startup). **`denorm-queue` is intentionally NOT autoheal-watched** — its Compose healthcheck is commented out, so it has no health status to react to; it relies on the nightly staggered `kill 1` restart (Ofelia, 05:25) instead. Double-dollar escaping (`$$DJANGO_BPP_DB_USER`) in healthcheck commands prevents premature Compose expansion. Detail: `docs/architektura/healthchecks-autoheal.md`.

### CRITICAL: `$$` in *every* inline shell — `command:`, `entrypoint:`, `healthcheck:`, Ofelia labels

Compose interpolates `$VAR` **before** the string reaches the container and cannot tell a shell variable from its own. **Every `$` meant for the shell must be `$$`** — including loop variables, not just env vars. Failure is silent: Compose substitutes an empty string (with a `WARN The "d" variable is not set` that scrolls past in `make up`), the code still parses, and `set -e` reports nothing. `webserver-init`'s Let's Encrypt fixup shipped as `for d in …; do [ -d "$d" ]` and rendered `[ -d "" ]` → always false → **the whole loop was a no-op from day one**.

**Comments inside a `- |` block scalar are NOT YAML comments** — they are part of the string, so Compose interpolates them too. A comment *explaining* the `$$` rule, written inside the block with a bare `$d`, generates the very warning it documents. Put such notes above the `command:` key as real YAML comments.

**Don't assert this by grepping the YAML source** — a source grep cannot see interpolation, which is exactly how the buggy loop stayed green under an assertion matching `chgrp -R nginx "$d"`. The check must run `docker compose config` and inspect the rendered output (`test_compose_shell_vars_escaped` in `tests/test_makefile.sh`). Note `config` round-trips `$$` as `$$` (its output is itself a compose file), so **`$$d` in the render is the passing state**; a bare `""` is the bug.

### Service dependencies

`appserver` (migrations) before the worker; `workerserver` depends on `appserver` healthy; `denorm-queue` requires `workerserver` healthy; `celerybeat` uses `service_started` for `appserver` (faster start). Service table + data flow: `docs/architektura/uslugi.md`.

### Scheduled jobs / nightly restarts (Ofelia)

Daily maintenance, SSL renew, log rotation, and staggered 05:00–05:25 nightly restarts (`kill 1` via read-only `docker.sock`) are Ofelia labels in the compose files. Full schedule: `docs/architektura/zadania-ofelia.md`.

### Planned downtime — `make run-with-warning`

Deploy session that warns users first: `make pull` → banner for N min → cutoff → `make run` → unblock (`scripts/deploy-with-warning.sh`, primitives in `scripts/site-down-warning.sh`, targets in `mk/deployment.mk`). **This repo holds ZERO countdown logic** — the banner/503 page and every state change belong to `django-countdown` (>= 0.3.0) in the BPP image; we only shell out to `manage.py`. Don't reintroduce a `manage.py shell` path writing to `SiteCountdown`. Operator doc: `docs/eksploatacja/przerwa-techniczna.md`.

Contracts that are easy to break while "cleaning up" — rationale and failure modes in `docs/rozwoj/pulapki-wdrozenia.md`:

- **Default targets differ per upstream command**: `stop_countdown`/`show_countdown` hit **all** sites, `start_countdown`/`extend_countdown`/`shorten_countdown` only the **current** one — and `start_countdown` has **no `--all`**. Multi-host therefore needs the `SITE_IDS` loop, or you block one domain and leave the rest open.
- **Never `|| true` the heartbeat.** An empty target is *deliberately* a success for `extend_countdown --at-least`, so a non-zero exit really does mean "the dead-man's floor lapsed" — log it loudly and continue, don't silence it.
- **The support probe must not pipe into `grep -q`.** Under `set -o pipefail` a *successful* match returns failure (producer dies of SIGPIPE) → random silent degradation to a deploy with no warning. Read the whole output first, then match in bash.
- **`BPP_SKIP_HEALTH_GATE=1` on `make run`** (same reason as `autoupdate.sh`), then invoke `post-deploy-check.sh` explicitly with `</dev/null` so its `[s]/[d]` prompt can't hang the session while the site is blocked.
- **Trap is phase-dependent**: interrupted during the banner → `stop_countdown` (nothing happened); interrupted/failed after cutoff → **keep the block** (stack in unknown state) and let the heartbeat floor expire it.
- Depends on `proxy_intercept_errors` staying **off** — otherwise nginx swallows Django's 503 and shows `maintenance.html` instead of the countdown page.

New vars (`SITE_DOWN_*`, `AUTOUPDATE_WARNING_MINUTES`) are all optional with in-script defaults — no `.env` migration needed. `make test-deploy-with-warning` runs as **its own CI step**, next to `scripts/test-autoupdate.sh`; both exercise the `make run` path, so a regression in one tends to surface in the other.

### Unattended auto-update (`scripts/autoupdate.sh`)

One cycle: new commit on `origin/main` **or** new Docker image → optional backup → `git pull --ff-only` → `make run`. The loop lives in `mk/deployment.mk` (`make autoupdate`, usually under `screen`); the script is invoked **fresh each iteration**, so a `git pull` reaches the next cycle by itself. Operator doc: `docs/eksploatacja/aktualizacje.md`.

**Image change detection compares entries pairwise, and `none` transitions never count.** A missing local *tag* is not a newer version — `docker system prune -af` (end of `make up`) can't delete an image a running container holds, so it drops the reference instead, and reading `none → ID` as an update redeployed **all of production, every cycle, forever**. Skipping those transitions loses nothing: a genuinely new image always yields `ID_old → ID_new`, and a new compose service arrives with a commit anyway. Also **log which image changed** — a nameless "Wykryto nowszy obraz Docker." over 18 images is undiagnosable. Note `docker image inspect` on a missing tag prints an **empty line on stdout** before failing; use `| head -1` + `${id:-none}`.

**Loop self-restart — the only frozen thing is the loop itself.** `make autoupdate` expands its `while` body and `$(AUTOUPDATE_INTERVAL)` at start, so changes to `Makefile`/`mk/deployment.mk` don't reach a running session. The script fingerprints those two files **before** the pull and, if they changed, ends its own screen session so the cron watchdog respawns it. Four hard conditions: fingerprint differs, `AUTOUPDATE_SELF_RESTART != 0`, running under `screen` (`$STY`, which also yields the session name), and a watchdog marker `# BPP-AUTOUPDATE` in `crontab -l`. Missing screen/watchdog → **warn, don't kill**: a silently dead loop is worse than a stale one.

**CRITICAL: release the lock dir (and clear the `trap`) *before* `exec screen -X quit`** — that kill gives no chance to run `trap EXIT`, and an orphaned lock stops every later cycle with "inny cykl trwa", i.e. auto-update dies with one log line as the only trace. Guarded by an explicit assertion in `scripts/test-autoupdate.sh`. Don't try to make the loop `break` on an exit code instead: that edit lives in the very file a running session has already frozen, so it could never deploy itself.

## Resource Limits

All services (except `backup-runner`) have `*_MEM_LIMIT`/`*_CPU_LIMIT` env vars, sized for an **8 GB host** by default. `make configure-resources` detects host RAM/CPU and proposes a proportional split. RAM limit is **hard** (OOM kill), CPU is **soft** (throttling). Full table + tuning: `docs/konfiguracja/limity-zasobow.md`.

## Optional Feature Flags

**`ZGLOS_CAPTCHA_ENABLED`** (`1`) + **`ALTCHA_HMAC_KEY`** (64-hex): ALTCHA proof-of-work captcha on the **public** (anonymous-only) publication-submission form. Both are written by the `_ensure_var` self-heal in `scripts/ensure-config-files.sh` — the single place; `init-configs.sh` calls that script, so fresh installs are covered too (do **not** add a second copy to the `.env` heredoc). **Order is load-bearing: key first, flag second** — a flag without a real key is worthless (Django falls back to a public sentinel → forgeable challenges). The flag is written **independently** of whether the key was just generated: installs that already got the key alone (since PR #19) would never light up if the two were coupled. Never rotate an existing key on a later `make up` — it invalidates challenges held by open forms. Operator opt-out is `ZGLOS_CAPTCHA_ENABLED=0`; `_ensure_var` never overwrites a non-empty value, so it survives. No Compose change needed: both reach Django via the wholesale `env_file`. Needs a BPP image ≥ `202607.1398`; older images ignore both. Operator doc: `docs/konfiguracja/architektura.md`.

**OIDC / Keycloak account binding** — `DJANGO_BPP_OIDC_GRACE_BIND` + `DJANGO_BPP_OIDC_TRUSTED_EMAIL_DOMAINS` (CSV) + `DJANGO_BPP_OIDC_GRACE_BIND_PRIVILEGED`, all off by default, all with a `DJANGO_BPP_OIDC_<SKROT>_…` variant that wins over the bare one. **Symptom that identifies this situation:** Keycloak login completes end-to-end (302 → 302 → 200, **no 403 — the WAF is not involved**) but the user stays logged out, and `appserver` logs `OIDC: konto z tym adresem już istnieje — połącz je z SSO przez profil` plus an AXES failure on `/oidc/callback/`. Cause: BPP matches identities by `(issuer, sub)`, never by e-mail (matching by e-mail = account takeover), so pre-SSO accounts have no binding yet. The built-in remedy (profile → „Połącz konto z SSO") requires a **local password**, so it is a dead end on pure-SSO installs — that's what these flags are for. Trust comes from the **domain list**, not `email_verified`: LDAP realms put the institutional address in `mail` and a private one in `email`, and `email_verified` describes the latter. **Anti-fixes — do NOT:** clear the account's e-mail to dodge the collision (creates a second empty account, orphans the real one with its permissions/PBN token/linked `Autor`); make the backend match users by e-mail again; or set `GRACE_BIND_PRIVILEGED` without a domain list (it's a deliberate no-op — the list is the only gate protecting admin accounts). No Compose change needed: all three reach Django via the wholesale `env_file`. Needs a BPP image with `iplweb/bpp#753`; older images ignore them. Operator doc: `docs/konfiguracja/architektura.md`.

**html2docx fallback** — optional **HTTP sidecar** (`docker-compose.application.yml`, `profiles: ['html2docx']`), off by default. HTML→DOCX export normally uses pandoc from the appserver image; the sidecar is for hosts where pandoc core-dumps (VMWare ESX). Enabling is **two** opt-ins in **two different** `.env` files: `COMPOSE_PROFILES=html2docx` in the **repo-local** `.env` (starts the container) + `DJANGO_BPP_HTML2DOCX_URL=http://html2docx:3030/convert` in `$BPP_CONFIGS_DIR/.env` (points Django at it). Missing URL = soft degradation, not a crash. No published port, **no `docker.sock`** — removing the socket from `appserver` (which used to `docker run` the converter) was the whole point of the change. Image pinned by `HTML2DOCX_VERSION`, independent of `DOCKER_VERSION`. The old flag `DJANGO_BPP_ENABLE_HTML2DOCX_IMAGE` is **dead** — nothing reads it; `init-configs` deliberately neither writes nor strips it (harmless in old `.env`). Operator doc: `docs/konfiguracja/architektura.md`.

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

- `make up` (hence `make run`) ends with `docker system prune -af` **after** the stack is healthy (`--wait`) — the optional `html2docx` sidecar, when its profile is on, is already **up** at that point, so its image counts as in-use and survives the prune. No `--volumes` → named data volumes are safe; but `-af` removes **all** unused images host-wide (incl. non-BPP). Use `make up-quick` on shared/dev hosts to skip it. Don't "fix" this by adding `--volumes`.
- `make up` ends with a **read-only health gate** (`scripts/post-deploy-check.sh`, hooked into the `up` recipe → `run` inherits it; `up-quick` does NOT). Flags compose services that are `unhealthy`/`restarting` (NOT `exited` — that would false-positive on on-demand `backup-runner`). All OK → `✓` + exit 0; problem + **TTY** → prompt `[s]`hell/`[d]`octor + exit 1; problem + **non-TTY** (CI/cron/`| tee`) → exit 1, no prompt. **Fail-open** on the checker's own errors (can't `cd`, no compose) → exit 0, never blocks a deploy. Read-only by design — does NOT send mail/ntfy/Rollbar (those stay opt-in in `make doctor`). Gates on container state, not log-error greps (too noisy). **CRITICAL for internal callers:** any script invoking `make up` non-interactively under `set -e` (currently `scripts/upgrade-postgres.sh` before its `make migrate`, and `scripts/restore.sh`) MUST `export BPP_SKIP_HEALTH_GATE=1` first — `scripts/autoupdate.sh` does the same for its unattended `make run` (the gate's prompt would otherwise block the auto-update loop under screen's pseudo-TTY) — else a transient post-`--wait` flap makes the gate `exit 1` (aborting the script mid-sequence) or, under a no-human PTY (`ssh -t`/Ansible), the prompt blocks (mitigated by a 30s `read -t` timeout). A new `make up` caller → set the same env. Tests: `make test-post-deploy-check` (mocks docker/make; like `test-doctor`, not yet in CI's `tests/test_makefile.sh`).
- Always `make db-backup` before major changes
- Use `make` targets instead of raw `docker compose` (they handle dependencies)
- Verify environment-specific config (database markers, backup settings) before destructive operations
- `make help` is the source of truth for available targets

## Documentation maintenance (for agents)

- Operator how-tos go in `docs/`; install/first-run goes in `README.md` (synced pair with `docs/instalacja/`); agent steering stays here.
- Use the **`docs-sync` skill** before editing docs — it has the change→files checklist.
- After editing docs, run `mkdocs build --strict` (catches broken links / nav gaps). The `docs.yml` workflow runs the same on push to `main`.

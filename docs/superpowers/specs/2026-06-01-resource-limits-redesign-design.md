# Resource limits redesign — design

**Date:** 2026-06-01
**Status:** Approved

## Problem

`make configure-resources` only sizes 7 services and splits the whole post-OS-reserve
budget by flat percentage weights. The other ~10 services rely on compose `${VAR:-default}`
fallbacks that `configure-resources` never touches, and several of those defaults are
oversized (flower 768m, alloy 384m). The operator wants explicit, sane per-service caps
and a model that reflects how the stack actually consumes RAM: a set of services with a
fixed ceiling, and a few hungry services that should absorb whatever is left.

## Model

Split services into two groups.

### FIXED (pinned to a cap, subtracted from the budget first)

| Service | Cap |
|---|---|
| redis | 1024m |
| netdata | 320m |
| authserver | 320m |
| celerybeat | 320m |
| denorm-queue | 320m |
| alloy | 192m |
| loki | 192m |
| grafana | 192m |
| flower | 128m |
| webserver | 256m |
| dozzle | 64m |
| ofelia | 64m |
| autoheal | 32m |

Σ ≈ 3424 MB (~3.34 GB).

`alloy` and `loki` were raised from the operator's initial 128m to 192m after review:
both spike under log volume/query load and 128m risks OOM. `flower` keeps 128m but its
in-memory task history is bounded with `--max-tasks 10000` so the cap is safe.

### VARIABLE (floor + surplus weight, absorb the remaining pool)

| Service | Floor | Surplus weight |
|---|---|---|
| dbserver | 1536m | 40% |
| appserver | 2048m | 25% |
| worker-general | 1536m | 20% |
| worker-denorm | 1536m | 15% |

### Uncapped, by design (documented)

`backup-runner` (batch pg_dump/restore/rclone, memory-spiky), `certbot` (short-lived SSL
job), `workerserver-status` (`celery status` one-shot, `profiles: ['manual']`).

## Algorithm

```
budget = (TOTAL_RAM - OS_reserve)
pool   = budget - Σ(fixed caps)
surplus = pool - Σ(floors)
if surplus >= 0:
    each variable = floor + surplus * (weight / 100)
else:
    each variable = floor            # host too small
    print overcommit / OOM warning
```

`Σ(fixed) + Σ(floors) + OS_reserve ≈ 3424 + 6656 + 2048 = 12128 MB ≈ 12 GB`, so 12 GB is
the minimum where every floor fits (dbserver at floor, zero surplus). Recommended is
16 GB+ so surplus flows to the variable group.

## Interaction & output

- Fixed services are **pinned to their cap** — not asked interactively (operators tune them
  in `.env` if ever needed). Shown in the summary.
- The 4 variable services are asked interactively for MEM, with surplus redistribution
  across the still-unasked variable services when the operator deviates from a default.
- **CPU logic is unchanged (RAM-only change):** the script keeps asking CPU for the same 7
  services it does today (the 4 variable + redis/loki/netdata) with the existing CPU
  weights. The 9 other fixed services get MEM only — no CPU written, they keep compose CPU
  defaults.
- The script writes every `*_MEM_LIMIT` (fixed at cap, variable computed) plus
  `REDIS_MAXMEMORY` (80% of redis cap) and CPU for the 7, to `$BPP_CONFIGS_DIR/.env`. `.env`
  becomes the single source of truth.
- An already-exported `BPP_CONFIGS_DIR` takes precedence over repo-local `.env` (testability
  + power users); repo `.env` remains the fallback.

## Compose default sync

The new caps become the compose `${VAR:-default}` fallbacks so installs that never run
`configure-resources` also benefit:

| Var | old | new |
|---|---|---|
| REDIS_MEM_LIMIT | 256m | 1g |
| NETDATA_MEM_LIMIT | 256m | 320m |
| ALLOY_MEM_LIMIT | 384m | 192m |
| LOKI_MEM_LIMIT | 256m | 192m |
| FLOWER_MEM_LIMIT | 768m | 128m |
| WORKER_GENERAL_MEM_LIMIT | 1g | 1536m |
| WORKER_DENORM_MEM_LIMIT | 1g | 1536m |
| APPSERVER_MEM_LIMIT | 1g | 2g |

`dbserver` keeps its 2g compose default. Unchanged: authserver, celerybeat, denorm-queue,
grafana, dozzle, webserver, ofelia, autoheal.

## Backwards compatibility

Raising a ceiling is safe (more headroom, never more OOM). The only OOM risk is the three
*lowered* ceilings (alloy, loki, flower) on existing installs at `git pull && make up`;
flower is protected by `--max-tasks`, alloy/loki were raised to 192m to reduce risk. No
manual `.env` step is required (compose defaults apply automatically), honoring the
backwards-compat contract. `REDIS_MAXMEMORY` defaults to 200mb in compose and is only
raised when the operator re-runs `configure-resources`, so the redis ceiling bump is safe.

## Docs

- `docs/konfiguracja/limity-zasobow.md` — rewrite the model section (fixed/variable),
  new caps table, 12 GB min / 16 GB recommended, uncapped-services note, netdata
  cap-vs-retention caveat.
- `README.md` — new "Wymagania sprzętowe" section: min 12 GB RAM, recommended 16 GB+.

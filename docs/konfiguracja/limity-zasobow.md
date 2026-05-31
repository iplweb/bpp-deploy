# Limity zasobów

Wszystkie usługi (oprócz `backup-runner` — efemeryczny, ~10 min/dzień) mają zmienne
`*_MEM_LIMIT` / `*_CPU_LIMIT`, żeby rozszalały kontener nie zjadł hosta. Domyślne
wartości są dobrane pod **host 8 GB** (najmniejsze rozsądne wdrożenie) — stack działa
out-of-the-box po `git pull && make up`.

## `make configure-resources`

Podczas pierwszego uruchomienia `make` skrypt `configure-resources` jest odpalany
automatycznie — wykrywa RAM i liczbę rdzeni hosta (Linux `/proc/meminfo`+`nproc`,
macOS `sysctl`), proponuje proporcjonalny podział budżetu między 7 serwisów wysokiego
ryzyka i pyta o akceptację każdej wartości. Jeśli odstąpisz od defaultu dla któregoś
serwisu, pozostałe mają budżet proporcjonalnie powiększony lub zmniejszony.

!!! info "RAM twardy, CPU miękki"
    Docker traktuje limit RAM jako **twardy** (przekroczenie → OOM kill), a CPU jako
    **miękki** (throttling bez zabijania). RAM ustawiaj z zapasem.

Wynik ląduje w `$BPP_CONFIGS_DIR/.env` jako `DBSERVER_MEM_LIMIT`, `APPSERVER_MEM_LIMIT`
itd. Możesz wrócić i przekonfigurować w każdej chwili: `make configure-resources`.

`configure-resources` proponuje podział proporcjonalny (np. 30% Postgres, 15%
Django/workery, …). Obecnie obejmuje serwisy wysokiego ryzyka — małe demony strój
ręcznie, jeśli defaulty się nie sprawdzą.

## Domyślne limity

### Wysokie ryzyko

| Serwis | RAM | CPU | Uwagi |
|---|---|---|---|
| `dbserver` | 2g | 2.0 | |
| `appserver` | 1g | 2.0 | |
| `workerserver-general` | 1g | 2.0 | |
| `workerserver-denorm` | 1g | 1.0 | |
| `redis` | 768m | 1.5 | broker + cache + result backend; wewn. `REDIS_MAXMEMORY` z `allkeys-lru` musi być < limit Dockera, żeby eviction wyprzedził OOM kill |
| `loki` | 256m | 0.5 | |

### Demony

| Serwis | RAM | CPU | Uwagi |
|---|---|---|---|
| `flower` | 768m | 0.5 | gromadzi historię zadań Celery |
| `alloy` | 384m | 0.5 | |
| `denorm-queue` | 320m | 1.0 | |
| `celerybeat` | 320m | 0.25 | |
| `authserver` | 320m | 1.0 | |
| `webserver` | 256m | 2.0 | proxy_buffers 16×16k = 256 KB/conn, + HTTP/3 QUIC TLS |
| `netdata` | 256m | 1.0 | `NETDATA_MEM_LIMIT`/`NETDATA_CPU_LIMIT`; dbengine + auto-discovery przez Docker socket |
| `grafana` | 192m | 1.0 | |
| `dozzle` / `ofelia` | 64m | 0.25 | |
| `autoheal` | 32m | 0.1 | |

!!! tip "Host > 16 GB"
    Jeśli host ma więcej RAM i chcesz dłuższej historii metryk, podnieś `netdata` do
    512m + ustaw `NETDATA_DBENGINE_TIER0_RETENTION_MB=2048` w `.env`
    (`netdata.conf` jest [force-syncowany](architektura.md#netdataconf-renderowany-host-side) —
    nie edytuj go ręcznie).

### Bez limitu

`backup-runner` (efemeryczny), `workerserver-status` (profil `manual`).

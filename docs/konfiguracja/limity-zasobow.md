# Limity zasobów

Każdy kontener (poza trzema efemerycznymi — patrz [Bez limitu](#bez-limitu)) ma zmienne
`*_MEM_LIMIT` / `*_CPU_LIMIT`, żeby rozszalały kontener nie zjadł hosta. RAM jest limitem
**twardym** (przekroczenie → OOM kill), CPU **miękkim** (throttling). Domyślne wartości
docierają do każdej instalacji przez `${VAR:-default}` w plikach compose, więc stack działa
out-of-the-box po `git pull && make up`.

!!! warning "Minimalne wymagania sprzętowe"
    **Minimum: 12 GB RAM. Zalecane: 16 GB+ RAM.** Suma stałych limitów (~3,3 GB) +
    minimalne progi usług zmiennych (dbserver/appserver/workery = 6,5 GB) + rezerwa OS
    (2 GB) daje ~12 GB. Przy 12 GB wszystko się mieści, ale ciasno (dbserver na minimum,
    zerowa nadwyżka). Dopiero od 16 GB nadwyżka realnie zasila bazę, aplikację i workery.
    Poniżej 12 GB `configure-resources` ostrzega o ryzyku OOM.

## Model: stałe capy + usługi zmienne

`configure-resources` dzieli usługi na dwie grupy:

- **Stały cap (FIXED)** — usługi o przewidywalnym apetycie na RAM dostają sztywny sufit
  i są **odejmowane od budżetu w pierwszej kolejności**. Przypisywane automatycznie
  (bez pytania); dostrajasz je w `.env`, jeśli kiedykolwiek zajdzie potrzeba.
- **Zmienne (VARIABLE)** — `dbserver`, `appserver` i dwa workery dzielą **pozostałą pulę**
  (budżet − rezerwa OS − suma stałych capów) według wzoru *floor + waga nadwyżki*.

```
pula     = (RAM hosta − rezerwa OS) − Σ(stałe capy)
nadwyżka = pula − Σ(floory)
każda usługa zmienna = floor + nadwyżka × (waga / 100)
```

Jeśli `nadwyżka < 0` (host < 12 GB), skrypt przypisuje same floory i ostrzega o
przekroczeniu budżetu (ryzyko OOM).

## `make configure-resources`

Przy pierwszym uruchomieniu `make` skrypt `configure-resources` jest odpalany
automatycznie — wykrywa RAM i liczbę rdzeni hosta (Linux `/proc/meminfo`+`nproc`,
macOS `sysctl`), przypisuje stałe capy, wylicza podział puli między 4 usługi zmienne
i pyta o akceptację ich wartości (RAM + CPU). Odstąpienie od defaultu redystrybuuje
nadwyżkę między pozostałe usługi zmienne. Możesz wrócić w każdej chwili:
`make configure-resources`.

!!! info "RAM twardy, CPU miękki"
    Docker traktuje limit RAM jako **twardy** (przekroczenie → OOM kill), a CPU jako
    **miękki** (throttling bez zabijania). RAM ustawiaj z zapasem.

Wynik ląduje w `$BPP_CONFIGS_DIR/.env` jako `DBSERVER_MEM_LIMIT`, `REDIS_MEM_LIMIT` itd.
oraz `REDIS_MAXMEMORY` (≈80% limitu Redisa, żeby eviction `allkeys-lru` wyprzedził
OOM kill). `.env` staje się jednym źródłem prawdy dla limitów RAM. CPU jest zapisywane
dla 7 usług (4 zmienne + `redis`/`loki`/`netdata`); pozostałe korzystają z CPU z compose.

## Usługi ze stałym capem

| Serwis | RAM | Uwagi |
|---|---|---|
| `redis` | 1g | broker + cache + result backend; `REDIS_MAXMEMORY` (`allkeys-lru`) ≈ 80% limitu |
| `netdata` | 320m | dbengine + auto-discovery; patrz uwaga niżej o retencji |
| `authserver` | 320m | Django + gunicorn (SSO) |
| `celerybeat` | 320m | scheduler — pojedynczy proces |
| `denorm-queue` | 320m | most PG `LISTEN` → Celery, pojedynczy proces |
| `alloy` | 192m | kolektor logów; podniesione z 128m (spike przy dużym wolumenie) |
| `loki` | 192m | magazyn logów; podniesione z 128m (spike przy zapytaniach) |
| `grafana` | 192m | |
| `flower` | 128m | historia zadań w RAM ograniczona `FLOWER_MAX_TASKS=10000` |
| `webserver` | 256m | nginx; proxy_buffers + HTTP/3 QUIC |
| `dozzle` | 64m | przeglądarka logów (Go) |
| `ofelia` | 64m | scheduler cron (Go) |
| `autoheal` | 32m | restart kontenerów po unhealthy |

Razem ≈ **3,3 GB**. Capy te są odejmowane od budżetu, a reszta trafia do usług zmiennych.

## Usługi zmienne (dzielą pulę)

| Serwis | Floor (minimum) | Waga nadwyżki |
|---|---|---|
| `dbserver` | 1.5g | 40% |
| `appserver` | 2g | 25% |
| `workerserver-general` | 1.5g | 20% |
| `workerserver-denorm` | 1.5g | 15% |

`dbserver` dostaje największą wagę (Postgres najlepiej wykorzystuje RAM na
`shared_buffers` i cache stron). `appserver` ma najwyższy floor — gunicorn akumuluje
pamięć (stąd nocny restart `kill 1`).

!!! tip "Netdata: cap kontra retencja"
    Cap `netdata` (320m) to limit **twardy**. Jeśli wydłużasz historię metryk przez
    `NETDATA_DBENGINE_TIER0_RETENTION_MB` / `NETDATA_DBENGINE_PAGE_CACHE_MB` w `.env`,
    **podnieś również `NETDATA_MEM_LIMIT`** — inaczej netdata zostanie ubity przez OOM.
    Plik `netdata.conf` jest [force-syncowany](architektura.md#netdataconf-renderowany-host-side) —
    nie edytuj go ręcznie, używaj knobów `.env`.

## Bez limitu

Trzy usługi celowo nie mają limitu RAM:

- `backup-runner` — efemeryczny (`pg_dump`/`restore`/`rclone`, ~10 min/dzień, skoki pamięci)
- `certbot` — krótko żyjące zadanie SSL (wydanie/odnowienie certyfikatu)
- `workerserver-status` — `celery status`, profil `manual`, kończy się natychmiast

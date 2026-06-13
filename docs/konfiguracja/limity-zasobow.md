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
| `workerserver` | 1.5g | 35% |

`dbserver` dostaje największą wagę (Postgres najlepiej wykorzystuje RAM na
`shared_buffers` i cache stron). `appserver` ma najwyższy floor — gunicorn akumuluje
pamięć (stąd nocny restart `kill 1`).

!!! info "DBSERVER_MEM_LIMIT steruje strojeniem Postgresa (autotune)"
    `dbserver` to stockowy obraz `postgres` z bind-mountowanym skryptem
    `dbserver/autotune.sh`, który przy starcie **czyta limit pamięci cgroup**
    (`DBSERVER_MEM_LIMIT`) i generuje `/postgresql_optimized.conf` z `shared_buffers`,
    `effective_cache_size`, `work_mem`, WAL itd. dobranymi do **~95%** tego limitu. Czyli
    `make configure-resources` nie tylko ogranicza kontener — pośrednio stroi też samego
    Postgresa. Nie trzeba ręcznie edytować `postgresql.conf`. Szczegóły:
    [PostgreSQL](postgresql.md). `workerserver` przejął wagę dwóch poprzednich
workerów (20% + 15% = 35%) — patrz [Concurrency Celery](#concurrency-celery) niżej,
bo jego realny apetyt na RAM zależy od liczby procesów-dzieci prefork.

!!! info "Konsolidacja workerów (czerwiec 2026)"
    Wcześniej były **dwa** workery (`workerserver-general` + `workerserver-denorm`),
    każdy z floorem 1.5g i osobnymi zmiennymi `WORKER_GENERAL_*` / `WORKER_DENORM_*`.
    Teraz jeden `workerserver` obsługuje **obie** kolejki (`celery` + `denorm`) ze
    zmiennymi `WORKER_MEM_LIMIT` / `WORKER_CPU_LIMIT`. Stare nazwy nadal działają po
    `git pull && make up` (Compose ma fallback
    `${WORKER_MEM_LIMIT:-${WORKER_GENERAL_MEM_LIMIT:-1536m}}`); `make init-configs`
    przepisuje wartość na nową nazwę, a `make configure-resources` zapisuje świeżo
    policzoną — oba usuwają nieużywane `WORKER_GENERAL_*`/`WORKER_DENORM_*`.

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

## Concurrency Celery

Limit RAM (`WORKER_MEM_LIMIT`) to tylko **twardy sufit**. To, ile worker
realnie zje, zależy od **liczby procesów-dzieci prefork** — Celery w trybie prefork
uruchamia 1 proces-nadzorcę + N dzieci, a **każde dziecko to pełna kopia Django**
(~250 MB RSS). Bez ograniczenia Celery bierze domyślnie **tyle dzieci, ile rdzeni
hosta** — na maszynie 16-rdzeniowej to 16 × ~250 MB ≈ 4 GB z jednego kontenera.

Dlatego obraz `iplweb/bpp_workerserver` (czerwiec 2026+) liczy concurrency
**domyślnie 75% rdzeni** hosta (zostawia zapas dla PostgreSQL, gunicorna appservera
i systemu). Konfiguracja siedzi w `app.conf` (czytana przez `celery_tasks.py`), więc
działa niezależnie od sposobu startu. Sterujesz nią przez `.env` (zmienne
`CELERY_WORKER_*` — wszystkie opcjonalne):

| Zmienna `.env` | Domyślnie | Działanie |
|---|---|---|
| `CELERY_WORKER_CONCURRENCY` | (puste) | Sztywna liczba dzieci. Ustawiona — **wygrywa** nad procentem. |
| `CELERY_WORKER_CONCURRENCY_PERCENT` | `75` | Procent rdzeni hosta (pula prefork), gdy brak jawnego concurrency. 75% = 3/4, min 1. |
| `CELERY_WORKER_MAX_MEMORY_PER_CHILD` | `300000` *(deploy)* | Próg RSS dziecka w **KB** — po przekroczeniu Celery recykluje dziecko (oddaje pamięć do OS). Tnie narost między nocnymi restartami. W compose ustawione na 300 MB; w samym obrazie domyślnie brak limitu. |
| `CELERY_WORKER_MAX_TASKS_PER_CHILD` | (puste) | Recykling dziecka po N zadaniach (alternatywa/uzupełnienie powyższego). |
| `CELERY_WORKER_POOL` | `prefork` (Linux) | Typ puli; macOS dev = `threads`. |
| `CELERY_WORKER_PREFETCH_MULTIPLIER` | (Celery: 4) | `worker_prefetch_multiplier`. |
| `CELERY_QUEUE` | `celery,denorm` | Kolejki workera (round-robin, bez ścisłego priorytetu). Ustawione w compose, nie ruszaj. |

!!! warning "Wymaga obrazu z czerwca 2026+"
    Zmienne `CELERY_WORKER_*` oraz domyślne `CELERY_QUEUE=celery,denorm` czyta **obraz**
    `iplweb/bpp_workerserver`. Na starszym obrazie zmienne `CELERY_WORKER_*` są
    ignorowane (Celery bierze rdzenie) — ale konsolidacja i tak działa, bo
    `CELERY_QUEUE=celery,denorm` ustawiamy **jawnie w compose** (stary obraz to honoruje).
    Po `make pull` (nowy obraz) dochodzi domyślne 75% rdzeni i recykling dzieci.

!!! danger "Hosty z dużą liczbą vCPU a mało RAM"
    Concurrency liczy się z **rdzeni**, a `WORKER_MEM_LIMIT` z **RAM hosta** —
    te dwie liczby o sobie nie wiedzą. Na maszynie typu „16 vCPU / 16 GB" 75% rdzeni =
    12 dzieci × ~250 MB ≈ 3 GB może przekroczyć przydzielony limit i wpaść w
    **OOM-kill loop**. Na takich hostach ustaw `CELERY_WORKER_CONCURRENCY` ręcznie
    (np. tyle, by `concurrency × 300 MB < WORKER_MEM_LIMIT`) albo podnieś
    `WORKER_MEM_LIMIT`. `CELERY_WORKER_MAX_MEMORY_PER_CHILD` (domyślnie 300 MB
    w compose) ogranicza wzrost pojedynczego dziecka, ale nie sumy `N × limit`.

### appserver — `WEB_CONCURRENCY` (gunicorn)

`appserver` to osobny model: gunicorn z async `UvicornWorker`. `WEB_CONCURRENCY`
(domyślnie **1** w obrazie) = liczba procesów gunicorna, każdy ~200 MB. Async worker
obsługuje setki połączeń na proces, więc **nie potrzebujesz wielu** — 1–2 wystarczają,
zwłaszcza gdy ciężką robotę pchasz na Celery. To ręczny knob w `.env`; skaluj w górę
tylko jeśli zależy Ci na odporności na blokady CPU lub mniejszych rozłączeniach
WebSocketów przy recyklingu. Pamiętaj: każdy `+1` to ~200 MB do `APPSERVER_MEM_LIMIT`.

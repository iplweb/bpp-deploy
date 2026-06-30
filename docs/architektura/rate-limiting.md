# Rate limiting (nginx)

Nginx ogranicza tempo żądań **per IP** dla ruchu trafiającego do Django, żeby
pojedynczy klient (scraper, brute-force, zepsuta integracja) nie zapchał drzwi
wejściowych i nie zagłodził legalnych użytkowników. To **nie** jest mechanizm
ochrony pojemności całego serwera — tym zajmują się workery appservera i limity
Dockera (patrz [Brak globalnego sufitu](#brak-globalnego-sufitu-pojemnosc-jest-nizej)).

Limity są **wbudowane w wersjonowany config** (dostarczany przez `git pull`),
nie w `$BPP_CONFIGS_DIR/.env` — wchodzą w życie przy najbliższym `make up` lub
reloadzie nginx, bez żadnej migracji `.env`.

## Trzy tiery

Klucz limitu to `$binary_remote_addr` — realny IP klienta (nginx sam terminuje
TLS, jest edge'em). Wartości to ~2× zmierzony szczytowy **legalny** req/s per IP
(zmierzony przez [`make request-stats`](#pomiar-przed-strojeniem)).

| Ścieżka | `rate` | `burst` | Po co |
|---|---|---|---|
| **`/admin/`** | 50 r/s | 50 | Edytorów jest garstka — realnego nie tyka; siatka na brute-force loginu i skanery. |
| **`/api/`** (w tym `/api/v1/`) | 60 r/s | 60 | Integracje mają więcej luzu niż przeglądarka, ale jeden IP nie zapcha workerów. |
| **reszta** (`location /`) | 100 r/s | 100 | Publiczny serwis. Statyki to omijają, więc to 100 *dynamicznych* req/s na IP. |

Wszystkie z `nodelay` — szpila (np. kilkanaście XHR-ów z jednego otwarcia
strony) jest serwowana **od ręki**, a nie kolejkowana z opóźnieniem. `rate` to
sufit długoterminowy, `burst` to chwilowa górka ponad niego (≈ 1 s zapasu).

## Status 429, nie 503 — i poziom logu

Domyślnie odrzucenie `limit_req` zwraca **503**. W tym deploymencie byłoby to
podwójnie szkodliwe, bo `_bpp-locations.conf` ma
`error_page 502 503 504 /maintenance.html;` — zdławiony user dostałby stronę
**„konserwacja"**, a Netdata zaalarmowałaby na 5xx. Dlatego ustawione jest
globalnie:

```nginx
limit_req_status 429;       # zdławienie = 429, nie 503 (brak strony "konserwacja", brak alertu 5xx)
limit_req_log_level warn;   # 429 logowane jako warn, nie error — nie pompuje dashboardu error-monitoring
```

`limit_req_log_level warn` jest istotne: domyślnie każde 429 ląduje w
`error_log` na poziomie `error`, a [dashboard error-monitoring](../monitoring/dashboardy-grafany.md)
jest keyowany po `detected_level` — flood 429 sam napompowałby metrykę i alerty
błędów. `warn` to neutralizuje.

## Co NIE jest limitowane (celowo)

`/static/`, `/media/`, `/healthz`, `/metrics` oraz panele za auth superusera
(`/grafana/`, `/dozzle/`, `/flower/`, `/netdata/`) mają własne locationy **bez**
`limit_req`:

- statyki/media serwuje sam nginx przez `sendfile` — tani ruch, nie ma po co go dławić;
- `/healthz` musi być nielimitowane, bo bije w nie healthcheck Dockera;
- panele i tak są chronione auth-subrequestem (`/_bpp_superuser_auth`).

## Brak globalnego sufitu — pojemność jest niżej {#brak-globalnego-sufitu-pojemnosc-jest-nizej}

**Świadomie nie ma globalnego (agregatowego) limitu req/s.** nginx liczy
requesty, ale jest ślepy na ich koszt (cached lookup vs 30-sekundowy raport) i na
wysycenie CPU/dysku/workerów — statyczny req/s we froncie jest złym przybliżeniem
pojemności. „Nie pociągnąć serwera" realizują **niżej**, dokładniej i w sposób
skalowany do maszyny:

- **worker pool appservera** (WSGI) — N workerów = twardy sufit równoczesnych requestów;
- **limity CPU/RAM Dockera** — sized do hosta przez [`make configure-resources`](../konfiguracja/limity-zasobow.md);
- **Celery concurrency**, `max_connections` PostgreSQL, autotune dbservera.

Jeśli agregatowy ruch przekracza to, co host uciąga, właściwą reakcją jest
kolejkowanie/503 na warstwie workerów (i ewentualnie większy host), a nie
prewencyjne 429 dla legalnych userów na froncie.

## Pomiar przed strojeniem

Nie zgaduj progów — zmierz realny ruch:

```bash
make request-stats              # peak req/s per IP (admin/api/reszta), okno 72h
SINCE=24h TOP=30 make request-stats
```

Komenda czyta access logi nginx-a (`docker logs` kontenera `webserver`) i dla
każdego IP liczy najwyższą liczbę żądań w jednej sekundzie. Ustaw `rate` z
zapasem nad **najwyższym legalnym** peakiem (oczywiste scrapery — pojedyncze
chmurowe IP z `total ≈ peak` — zignoruj). Uwaga: okno jest ograniczone retencją
`docker logs`, więc na ruchliwym hoście peak bywa lekko niedoszacowany.

## Strojenie

Wartości są w **wersjonowanych** plikach (nie w `.env` — nginxowy `envsubst` nie
umie domyślnych wartości `${VAR:-…}`):

- **`defaults/webserver/default.conf.template`** — definicje stref (`limit_req_zone`)
  i `rate`, w kontekście `http`. Tu zmieniasz tempo.
- **`defaults/webserver/_bpp-locations.conf`** — `limit_req` w locationach
  (`/api/`, `/admin/`, `/`) i `burst`.

Po edycji: `git pull && make up` (albo reload nginx) podnosi nowe wartości na
wszystkich instalacjach. **Kanarek po wdrożeniu:** 429 na znanym legalnym IP
(Wasz zakres uczelni / wewnętrzne `10.x`) = podnieś `rate` danego tieru.
Liczbę 429 widać w access logu i w Netdata web_log.

!!! note "Wspólny config dla wszystkich instalacji"
    Pliki są bind-mountowane z repo na każdym serwerze, więc te same liczby
    obowiązują na całej flocie — dobierz je pod **najcięższy** profil ruchu.

# Rate limiting (nginx)

Nginx ogranicza ruch trafiający do Django na dwóch poziomach:

- **per IP** — żeby pojedynczy klient (scraper, brute-force, zepsuta integracja)
  nie zapchał drzwi wejściowych i nie zagłodził legalnych użytkowników;
- **globalnie** — jedna pula dla wszystkich adresów naraz, żeby ruch rozłożony na
  tysiące IP nie położył appservera i bazy (patrz [Limit globalny](#limit-globalny)).

Limity per IP są **wbudowane w wersjonowany config** (dostarczany przez
`git pull`), nie w `$BPP_CONFIGS_DIR/.env` — wchodzą w życie przy najbliższym
`make up` lub reloadzie nginx, bez żadnej migracji `.env`. Limit globalny ma
rozsądne wartości domyślne i da się go stroić zmiennymi w `.env`.

Rate limiting ogranicza **tempo** żądań, ale ich nie ocenia. Żądania, które nigdy
nie powinny dojść do Django (sondy o `*.php`, prefiksy obcych CMS-ów), odcina
[Utwardzenie brzegu](utwardzenie-brzegu.md); rozpoznane ataki — [WAF](waf.md).

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
`error_log` na poziomie `error`, a [dashboard „Log Monitoring"](../monitoring/dashboardy-grafany.md#log-monitoring)
jest keyowany po `detected_level` — flood 429 sam napompowałby metrykę i alerty
błędów. `warn` to neutralizuje.

## `/.well-known/` — wyjątek przed blokadą plików ukrytych

`_bpp-locations.conf` blokuje pliki ukryte regexem `location ~ /\.` (żeby nikt
nie pobrał `/.git/config` ani `/.env`). Ta reguła łapała też `/.well-known/` —
standardową przestrzeń metadanych serwisu (RFC 8615), w której leżą m.in.
metadane serwera autoryzacji OAuth (`/.well-known/oauth-authorization-server`,
RFC 8414) i `security.txt`. Efekt: 403 i **padające logowanie klientów MCP**,
które przed logowaniem robią discovery — mimo że `/o/authorize/`, `/o/token/`
i `/o/register/` działały normalnie.

Naprawa korzysta z kolejności matchowania locationów w nginksie: **regex `~` ma
pierwszeństwo przed zwykłym prefiksem**, więc żaden prefiksowy `location` nie
mógł wyprzedzić blokady — dopiero modyfikator `^~` stawia prefiks **ponad**
regexami:

```nginx
location ^~ /.well-known/ {
    limit_req zone=bpp_general burst=100 nodelay;
    try_files $uri @proxy_to_app;
}
```

Ruch idzie do Django z tierem ogólnym (100 r/s). Django odpowiada 404 na nieznane
ścieżki `.well-known`, więc nic się nie odsłania, a `/.git/*` i `/.env` dalej
łapie regex poniżej. Obie strony kontraktu pilnuje test 15d w
`tests/test_makefile.sh` — „naprawa" polegająca na skasowaniu blokady plików
ukrytych nie przejdzie jako zielona.

!!! note "ACME (Let's Encrypt) to osobna ścieżka"
    Walidacja HTTP-01 (`/.well-known/acme-challenge/`) nigdy nie była dotknięta:
    obsługuje ją blok port-80 w `vhost.conf.template`, który nie includuje
    `_bpp-locations.conf` ([SSL](../konfiguracja/ssl.md)).

## Co NIE jest limitowane (celowo)

`/static/`, `/media/`, `/healthz`, `/metrics` oraz panele za auth superusera
(`/grafana/`, `/dozzle/`, `/flower/`, `/netdata/`) mają własne locationy **bez**
`limit_req`:

- statyki/media serwuje sam nginx przez `sendfile` — tani ruch, nie ma po co go dławić;
- `/healthz` musi być nielimitowane, bo bije w nie healthcheck Dockera;
- panele i tak są chronione auth-subrequestem (`/_bpp_superuser_auth`).

## Limit globalny {#limit-globalny}

Limity per IP nic nie dają, gdy ruch jest rozłożony na tysiące adresów.
**27 września 2026** na `publikacje.up.lublin.pl` scraper puszczony przez sieć
rezydencjalnych proxy (**~6800 różnych IP, średnio jedno żądanie na adres**,
osiem podrobionych user-agentów Chrome, zero pobrań z `/static/`) rozkręcał się
od rana do **~2000 żądań/min**. Appserver przyjmował wszystko naraz, każde
żądanie trzymało własne połączenie z PostgreSQL, a baza po przekroczeniu
`max_connections` odpowiadała `too many clients` wszystkim — także workerom.
Strona nie odpowiadała przez ~3 minuty.

Dlatego obok limitów per IP każdy location kierujący ruch do appservera
(`/`, `/api/`, `/admin/`, `/.well-known/`) ma **wspólną pulę dla wszystkich IP
i wszystkich vhostów**:

| Zmienna w `.env` | Domyślnie | Znaczenie |
|---|---|---|
| `BPP_NGINX_GLOBAL_RATE` | `20` | Żądań/s do appservera łącznie, ze wszystkich IP (1200/min). |
| `BPP_NGINX_GLOBAL_BURST` | `200` | Górka ponad `RATE` obsługiwana od ręki (~10 s szczytu). |
| `BPP_NGINX_GLOBAL_CONN` | `60` | Żądań do appservera obsługiwanych **naraz**. |

Ponad limit nginx oddaje od razu **429** (nie 503 — ten sam powód co
[wyżej](#status-429-nie-503-i-poziom-logu)), zamiast pozwolić, żeby żądania
spiętrzyły się w appserverze i w bazie.

- **Wartość pusta albo brak zmiennej** = wartość domyślna.
- **`0`** = dany limit wyłączony (np. `BPP_NGINX_GLOBAL_RATE=0` zostawia tylko
  limit równoczesnych żądań).
- **Błędna wartość** (`abc`, `-5`, `6 0`) nie kładzie strony: webserver loguje
  `OSTRZEZENIE` i używa wartości domyślnej.

Zmiana wartości: wpisz zmienną do `$BPP_CONFIGS_DIR/.env` i uruchom `make up`.
Webserver wstanie z nowym środowiskiem, a skrypt `25-render-bpp-limits.sh`
wygeneruje konfigurację od nowa. Aktualne wartości widać w logu startu:

```bash
docker compose logs webserver | grep 25-render
# 25-render-bpp-limits.sh: globalny limit do appservera: tempo 20 r/s (burst 200), rownoleglosc 60 naraz
```

**Co jest poza limitem globalnym:** `/static/`, `/media/`, `/healthz` i panele
za auth (tak jak w przypadku limitów per IP) oraz **WebSockety**
(`/asgi/notifications/`) — wiszą godzinami, więc liczone w limicie równoległości
zjadałyby go samym faktem, że redaktorzy mają otwarte karty.

!!! warning "Globalny limit dotyka też legalnych użytkowników"
    Tak jest z definicji: gdy scraper wyczerpie pulę, 429 dostają wszyscy, do czasu
    aż pula się odnowi. To świadomy wybór — krótkie 429 zamiast kilku minut
    całkowitej niedostępności i błędów w bazie dla wszystkich, łącznie z zadaniami
    w tle. Kanarek po wdrożeniu: 429 w access logu **bez** floodu w tle = podnieś
    `BPP_NGINX_GLOBAL_RATE`.

### Druga warstwa: limit w samym appserverze

Nginx jest ślepy na koszt żądania: 20 szybkich stron to nie to samo co 20
kilkuminutowych raportów. Dlatego appserver ma własny limit —
**`GUNICORN_LIMIT_CONCURRENCY`** (domyślnie **80 na proces**, `0` = wyłączony).
Ponad limit od razu oddaje 503, zamiast otwierać kolejne połączenie do bazy.
Wymaga obrazu BPP z tą zmianą; starsze obrazy ignorują zmienną. Szczegóły:
[Limity zasobów](../konfiguracja/limity-zasobow.md#appserver-web_concurrency-gunicorn).

Obie warstwy razem pilnują **pojemności**. Pozostałe mechanizmy, które ją
ograniczają:

- **limity CPU/RAM Dockera** — dobrane do hosta przez [`make configure-resources`](../konfiguracja/limity-zasobow.md);
- **współbieżność Celery**, `max_connections` PostgreSQL i autotune dbservera.

Sprawdzenie na żywym nginksie: `make test-nginx-limits` (pula wspólna dla
różnych IP, 429 ponad limit równoległości, WebSockety i `/static/` poza
limitem, błędne wartości i `0`).

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

Limit globalny stroisz zmiennymi `BPP_NGINX_GLOBAL_*` (patrz
[wyżej](#limit-globalny)). Limity **per IP** są w **wersjonowanych** plikach
(nie w `.env` — nginxowy `envsubst` nie umie domyślnych wartości `${VAR:-…}`):

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

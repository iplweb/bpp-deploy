# pgbouncer przed PostgreSQL dla appservera — projekt

Data: 2026-09-27 · Status: kształt zatwierdzony; wersja 2 po review (poprawki
W1–W6, D1–D11), do przeglądu

## Cel

Przyspieszyć odpowiedzi appservera, usuwając większość kosztu nawiązywania
połączenia z PostgreSQL przy **każdym** żądaniu HTTP.

### Pomiar, który to uzasadnia (publikacje.up.lublin.pl, 2026-09-27)

Z kontenera `appserver`, 30 prób, mediany:

| Co | Czas |
|---|---|
| nowe połączenie `psycopg2.connect` (SCRAM + fork backendu) | **18 ms** (13–33) |
| pierwsze zapytanie na świeżym połączeniu (zimny catcache) | 9,7 ms |
| to samo zapytanie drugi raz | 1,5 ms |
| całe żądanie do appservera (24 h, n = 33 207) | **100 ms** (p90 145, p99 1063) |

Django ma `CONN_MAX_AGE=0` — każde żądanie otwiera i zamyka połączenie.

### Co pgbouncer zdejmie, a czego nie

- **Znika:** fork backendu PostgreSQL i zimny catcache/relcache. `DISCARD ALL`
  przy zwrocie do puli to `CLOSE ALL; SET SESSION AUTHORIZATION DEFAULT; RESET
  ALL; DEALLOCATE ALL; UNLISTEN *; SELECT pg_advisory_unlock_all(); DISCARD
  PLANS; DISCARD TEMP; DISCARD SEQUENCES`
  (<https://www.postgresql.org/docs/current/sql-discard.html>) — cache katalogu
  zostaje ciepły. `DISCARD PLANS` dotyka tylko planów PL/pgSQL (triggery denormu),
  przeplanowanych raz na połączenie klienta — dziś i tak płaconych.
- **Zostaje:** SCRAM na odcinku Django → pgbouncer. libpq liczy PBKDF2, a
  pgbouncer z hasłem jawnym w `auth_file` buduje sekret SCRAM ad hoc przy każdym
  logowaniu klienta (losowa sól), w jednowątkowej pętli zdarzeń.
- **Szacunek:** koszt połączenia spada z ~18 ms + ~8 ms zimnego cache do rzędu
  **3–6 ms**. To szacunek ze składowych; efekt mierzymy (*Kryteria akceptacji*).

Dlaczego nie `CONN_MAX_AGE > 0`: appserver działa pod ASGI, gdzie Django nie
radzi sobie z trwałymi połączeniami (żądania trafiają do różnych wątków).
Pula zewnętrzna omija problem bez zmiany obrazu BPP.

### Co to NIE jest

Ochrona przed floodem. Tę dają limity z 2026-09-27 (globalny w nginx,
`GUNICORN_LIMIT_CONCURRENCY` w obrazie BPP). pgbouncer w trybie `session` nie
zmniejsza liczby równoczesnych połączeń do bazy — zmniejsza koszt każdego z nich.

## Decyzje (ustalone z operatorem)

1. **Przez pulę idzie wyłącznie `appserver`.** authserver (auth paneli, znikomy
   ruch), Celery, denorm-queue (`LISTEN`), netdata (`bpp_monitor` ma widzieć
   prawdziwy serwer) i backup/restore (`docker exec` w `dbserver`) — bez zmian.
2. **Domyślnie włączone.** `git pull && make up` przełącza appserver na pulę bez
   edycji `.env`.
3. **Dwa zestawy zmiennych, bez podmiany znaczenia.** `DJANGO_BPP_DB_HOST`/`_PORT`
   dalej znaczy „prawdziwa baza”. Nowe `BPP_APPSERVER_DB_HOST`/`_PORT` (prefiks
   `BPP_` jak inne zmienne czytane tylko przez deploy, np. `BPP_NGINX_GLOBAL_*`)
   wskazują, dokąd łączy się appserver.
4. **Jedna konfiguracja dla bazy w compose i zewnętrznej.** pgbouncer łączy się
   z `DJANGO_BPP_DB_HOST`/`_PORT`, niezależnie od trybu. Baza zewnętrzna jest
   dedykowana BPP i nie wymaga TLS.
5. **Tryb `session`, na sztywno.** Powód: Django tworzy nazwane kursory
   `WITH HOLD` w autocommicie (`QuerySet.iterator()`;
   `django/db/backends/postgresql/base.py`: `withhold=self.connection.autocommit`),
   a tabela zgodności (<https://www.pgbouncer.org/features.html>) daje
   `WITH HOLD CURSOR: Never` w trybie `transaction`; tak samo `LISTEN`, `SET`,
   `PREPARE`. (BPP używa wyłącznie `pg_advisory_xact_lock` — to NIE jest powód.)
   `session` wspiera wszystko, a przy zwrocie do puli wykonuje `DISCARD ALL`
   (`server_reset_query`, domyślnie tylko w tym trybie).
6. **To samo konto co dziś.** `auth_file` generowany z `DJANGO_BPP_DB_USER`
   i `DJANGO_BPP_DB_PASSWORD` z `.env`; `auth_type = scram-sha-256` (dopuszcza
   w `auth_file` hasło jawne). `auth_query` i kopiowanie sekretów SCRAM
   odrzucone — więcej ruchomych części przy jednym użytkowniku aplikacji.

## Architektura

```
                 ┌──────────── appserver ────────────┐
                 │ DJANGO_BPP_DB_HOST=${BPP_APPSERVER_DB_HOST:-pgbouncer}
                 │ DJANGO_BPP_DB_PORT=${BPP_APPSERVER_DB_PORT:-6432}
                 └──────────────┬────────────────────┘
                                │ SCRAM (to samo konto)
                         ┌──────▼──────┐
                         │  pgbouncer  │ pool_mode=session, :6432
                         └──────┬──────┘
                                │ DJANGO_BPP_DB_HOST:DJANGO_BPP_DB_PORT
            ┌───────────────────▼────────────────────┐
            │ dbserver (compose)  ALBO  baza zewn.   │◄── authserver, Celery,
            └────────────────────────────────────────┘    denorm-queue, netdata
```

### Pliki

| Plik | Rola |
|---|---|
| `docker-compose.pgbouncer.yml` (nowy) | usługa `pgbouncer`, własne `x-logging` (anchory nie przechodzą przez `include:`) |
| `docker-compose.yml` | `include:` nowego pliku z `env_file: ${BPP_CONFIGS_DIR}/.env` |
| `docker-compose.application.yml` | appserver: nadpisanie `DJANGO_BPP_DB_HOST`/`_PORT` w `environment:` + `depends_on: pgbouncer: service_started` |
| `pgbouncer/entrypoint.sh` (nowy) | wersjonowany kod wykonywalny (precedens: `dbserver/`, nie `defaults/` — to nie szablon konfiguracji operatora); renderuje `pgbouncer.ini` + `userlist.txt`, sprawdza `max_connections`, potem `exec pgbouncer` |
| `scripts/configure-resources.sh` | `pgbouncer:64` na liście MEM + prefiks `PGBOUNCER` |

`environment:` w compose ma pierwszeństwo przed `env_file:`, więc nadpisanie
działa bez ruszania `.env`. Interpolacja `${BPP_APPSERVER_DB_HOST}` czyta
`$BPP_CONFIGS_DIR/.env` przez `env_file` na poziomie `include:` (precedens:
`${DJANGO_BPP_ENABLE_PROMETHEUS:-false}` w `docker-compose.application.yml`).

### Usługa `pgbouncer`

- Obraz `edoburu/pgbouncer:${PGBOUNCER_VERSION:-v1.25.2-p0}` — utrzymywany
  (wydanie 2026-06-10), budowany z oficjalnego tarballa, działa jako `postgres`
  (uid 70), ma `pg_isready`, `psql`, `nc`; `/etc/pgbouncer` należy do `postgres`.
- `entrypoint: ["sh", "/bpp-entrypoint.sh"]` — przez interpreter, nie przez bit
  `+x` (ten sam wzorzec co `dbserver`; `+x` w tym repo już ginął, `cc8439d`).
  Skrypt POSIX `sh` (Alpine/busybox). Własny zamiast entrypointu obrazu: tamten
  wpisuje hasło do `userlist.txt` bez escapowania (`"` w haśle psuje plik)
  i wkleja wartości do formatu `printf` (`%` psuje konfigurację).
- `env_file: ${BPP_CONFIGS_DIR}/.env` na poziomie usługi (ten z `include:`
  służy tylko interpolacji — ta sama lekcja co przy `dbserver`).
- `depends_on: dbserver: service_healthy` — w trybie zewnętrznym `dbserver` to
  sentinel sondujący prawdziwą bazę, więc działa w obu trybach.
- `restart: always`, `logging: *default-logging`.
- `deploy.resources.limits`: `PGBOUNCER_MEM_LIMIT` (domyślnie `64m`),
  `PGBOUNCER_CPU_LIMIT` (domyślnie `0.5`).
- Bez opublikowanego portu — tylko sieć compose.

### appserver → pgbouncer: `service_started`, nie `service_healthy`

Z `service_healthy` wyłącznik puli nie działałby w scenariuszu, w którym jest
najbardziej potrzebny: gdy pgbouncer nie osiąga `healthy`, `make up` staje na
„container pgbouncer is unhealthy”, nawet po przełączeniu appservera na bazę.
Gwarancję, że baza żyje, daje pozostawione `dbserver: service_healthy`;
pgbouncer startuje w ułamku sekundy; ewentualny wyścig kończy się jednym
restartem appservera (`restart: always`).

### Healthcheck — osobna pula dla sondy

Sonda `psql … -c 'SELECT 1'` przez **osobny wpis** bazy `<NAME>_health` z
`pool_size=1`. Przez główną pulę sonda stałaby w kolejce pod nasyceniem
(60 zajętych połączeń = limit nginx), padałaby 3× i robiła pgbouncera
`unhealthy` dokładnie podczas ruchu, który limity mają obsłużyć — `make up`,
`post-deploy-check` i `make doctor` alarmowałyby fałszywie. `pool_size` jest
per wpis, a `max_db_connections` liczy się per baza pgbouncera, więc alias nie
gryzie się z limitem głównej puli (<https://www.pgbouncer.org/config.html>).

`interval: 10s`, `timeout: 5s`, `retries: 3`, `start_period: 10s`.
Hasło: `PGPASSWORD=$$DJANGO_BPP_DB_PASSWORD` (`$$` — Compose interpoluje `$`).
Sprawdza całą ścieżkę: pgbouncer → uwierzytelnienie → baza.

Uwaga: healthcheck **appservera** (`/health/`, `SELECT 1`) idzie przez główną
pulę — stąd domyślna pula 80 z zapasem ponad `BPP_NGINX_GLOBAL_CONN` (60).

### Konfiguracja renderowana przez `entrypoint.sh`

`/etc/pgbouncer/pgbouncer.ini`:

```ini
[databases]
<NAME>        = host=<DJANGO_BPP_DB_HOST> port=<DJANGO_BPP_DB_PORT>
<NAME>_health = host=<DJANGO_BPP_DB_HOST> port=<DJANGO_BPP_DB_PORT> dbname=<NAME> pool_size=1

[pgbouncer]
listen_addr = *
listen_port = 6432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = session
default_pool_size = <PGBOUNCER_POOL_SIZE>
max_db_connections = <PGBOUNCER_POOL_SIZE>
max_client_conn = <PGBOUNCER_MAX_CLIENT_CONN>
query_wait_timeout = 15
log_connections = 0
log_disconnections = 0
stats_users = <DJANGO_BPP_DB_USER>
```

- Wpisy baz **bez `user=`** — pgbouncer loguje się do PostgreSQL danymi klienta
  (tym samym kontem).
- `server_reset_query` domyślne (`DISCARD ALL`); `server_tls_sslmode` domyślne
  `prefer` — przy bazie z włączonym SSL pgbouncer użyje TLS bez weryfikacji CA,
  bez — połączy się jawnie. Nie wpisujemy go, bo to wartość domyślna.
- `ignore_startup_parameters` nie ustawiamy: psycopg2/libpq nie wysyła
  `extra_float_digits` (to JDBC/Npgsql), a `client_encoding` jest śledzony
  domyślnie.
- `log_connections`/`log_disconnections` = 0: domyślne `1` dałyby 2 linie logu
  na każde żądanie HTTP (~66 tys./dobę do Loki). Błędy logowania i `stats:` co
  60 s zostają.
- `stats_users` = konto aplikacji: read-only `SHOW POOLS`/`SHOW STATS` na
  konsoli `pgbouncer` bez nowego sekretu (diagnostyka `cl_waiting` przy pełnej
  puli).
- `query_wait_timeout = 15` (domyślnie 120): pełna pula to dziś szybki błąd,
  po zmianie żądanie by wisiało; 15 s ogranicza czas trzymania slotu uvicorna
  i `limit_conn`.

`/etc/pgbouncer/userlist.txt`: `"<user>" "<hasło>"`, każdy `"` w polu podwojony
(<https://www.pgbouncer.org/config.html>: *„Double quotes in a field value can
be escaped by writing two double quotes”*). Uprawnienia `0600`.

### Sprawdzenie `max_connections` przy starcie

Autotune daje `max_connections = 100 × RAM_GB` (cap 250, `dbserver/autotune.sh`);
na małych hostach to 50–100, a do tego samego serwera łączą się bezpośrednio
Celery, denorm-queue, authserver, celerybeat, netdata i backup. Pula większa niż
`max_connections` wpada w pętlę `server_login_retry` (15 s) z opóźnionymi
błędami u klientów.

Entrypoint po wyrenderowaniu odpytuje bazę bezpośrednio (`psql -h
$DJANGO_BPP_DB_HOST … -c 'SHOW max_connections'`, to samo konto). Jeśli
`PGBOUNCER_POOL_SIZE > max_connections − 40` → `OSTRZEZENIE` w logu i przycięcie
puli do `max(10, max_connections − 40)`. 40 = zapas na połączenia bezpośrednie
(Celery przy 75 % rdzeni, denorm-queue, beat, authserver, netdata, backup, sesje
administracyjne). Gdy zapytanie się nie powiedzie → `OSTRZEZENIE`, bez
przycinania, start kontynuowany (nie blokujemy strony na sondzie pomocniczej).

### Zmienne

| Zmienna | Domyślnie | Uwagi |
|---|---|---|
| `BPP_APPSERVER_DB_HOST` | `pgbouncer` | wyłączenie puli: adres prawdziwej bazy |
| `BPP_APPSERVER_DB_PORT` | `6432` | wyłączenie puli: port prawdziwej bazy |
| `PGBOUNCER_POOL_SIZE` | `80` | zapas ponad `BPP_NGINX_GLOBAL_CONN` (60) na healthcheck appservera i joby Ofelii; przycinane do `max_connections − 40` |
| `PGBOUNCER_MAX_CLIENT_CONN` | `1000` | przekroczenie to twardy błąd, nie kolejka; połączenia klienckie są tanie; ma być ≫ `GUNICORN_LIMIT_CONCURRENCY` × `WEB_CONCURRENCY` |
| `PGBOUNCER_VERSION` | `v1.25.2-p0` | przypięty tag, jak `HTML2DOCX_VERSION` |
| `PGBOUNCER_MEM_LIMIT` / `_CPU_LIMIT` | `64m` / `0.5` | jak reszta `*_LIMIT`; wpisywane przez `make configure-resources` |

Liczby walidowane w skrypcie jak w `defaults/webserver/25-render-bpp-limits.sh`:
puste = domyślna, śmieć = `OSTRZEZENIE` + domyślna. Brak nowej zmiennej
wymaganej — **zero migracji `.env`**, stary `.env` działa (kontrakt
backwards-compat).

Wyłączenie puli (`docs/konfiguracja/pgbouncer.md`):

```
BPP_APPSERVER_DB_HOST=dbserver     # albo host zewnętrznej bazy
BPP_APPSERVER_DB_PORT=5432
make up
```

Usługa `pgbouncer` dalej działa bezczynnie (kilka MB) — celowo, bez warunkowego
compose; jedno pokrętło, łatwy powrót. Dzięki `service_started` powrót działa
także, gdy pgbouncer jest `unhealthy`.

## Awarie

| Sytuacja | Skutek | Obrona |
|---|---|---|
| pgbouncer pada | leży strona (appserver); Celery, denorm, panele działają | `restart: always`; bramka zdrowia `make up`; wyłącznik działa mimo `unhealthy` |
| baza niedostępna | appserver dostaje błąd połączenia natychmiast (`server_login_retry`), powrót po awarii opóźniony o ≤ 15 s | healthcheck `pgbouncer` czerwony, widoczny w `make doctor` |
| błędne hasło w `.env` | pgbouncer wstaje, logowanie klienta pada | healthcheck czerwony; appserver zwraca błędy bazy |
| pula pełna | klient czeka do 15 s (`query_wait_timeout`), potem błąd | limity nginx/appservera trzymają ruch poniżej puli; `SHOW POOLS` (`stats_users`) i `stats:` w logu pokazują `cl_waiting`/`wait` |
| pula > `max_connections` | — | przycięcie przy starcie z `OSTRZEZENIE` |
| zmiana hasła | `.env` → `make up` odtwarza kontener (zmiana `env_file`) | — |

## Testy

**Statyczne** (`tests/test_makefile.sh`, na wyrenderowanym `docker compose config`
— grep po źródle nie widzi interpolacji):

- domyślnie appserver ma `DJANGO_BPP_DB_HOST=pgbouncer`, `_PORT=6432`;
- z `BPP_APPSERVER_DB_HOST=dbserver` + `_PORT=5432` — bezpośrednio;
- **żaden inny** serwis nie łączy się z `pgbouncer` (authserver, workerserver,
  celerybeat, denorm-queue, flower, netdata);
- appserver → pgbouncer ma `condition: service_started`;
- `pgbouncer` ma `logging`, limity, `depends_on: dbserver`, serwisowy
  `env_file`, entrypoint przez `sh`;
- `$$` w healthchecku przetrwał render (`test_compose_shell_vars_escaped`);
- `configure-resources` zna `pgbouncer` (asercje kompletu MEM).

**Na żywo** (`scripts/test-pgbouncer.sh` → `make test-pgbouncer`, do CI obok
`test-nginx-limits`): prawdziwy `postgres` (SCRAM) + `pgbouncer` z naszym
`entrypoint.sh`:

1. logowanie przez pulę tym samym kontem;
2. hasło z `"`, `%`, `$`, spacją — logowanie działa;
3. `LISTEN` działa przez pulę;
4. **reset sesji między klientami**, w fazach: A bierze
   `pg_advisory_lock(42)` i zostaje połączony → B dostaje
   `pg_try_advisory_lock(42) = false`; A się rozłącza → B (nowe połączenie
   klienta) dostaje `true`. Plus `SET` z A nie jest widoczny w kolejnym
   połączeniu (`RESET ALL`). (Samo „B dostaje lock po A” przeszłoby też
   w `transaction` — lock sesyjny jest reentrantny na tym samym backendzie.)
5. dwa kolejne połączenia klienta dostają **ten sam** `pg_backend_pid()` —
   dowód ponownego użycia, czyli źródła przyspieszenia;
6. `psql --single-transaction -f` ze skryptem `SET`/`CREATE TABLE`/`COPY` —
   odpowiednik `baseline_load` przy świeżej instalacji;
7. healthcheck: zielony normalnie; **zielony przy nasyconej głównej puli**
   (klienci trzymają wszystkie `POOL_SIZE` połączeń); czerwony przy złym haśle;
8. śmieć w `PGBOUNCER_POOL_SIZE` → ostrzeżenie + domyślna, pgbouncer wstaje;
9. `POOL_SIZE` > `max_connections − 40` (baza z niskim `max_connections`) →
   przycięcie + `OSTRZEZENIE`.

Mutacje, które muszą wywrócić test: bez podwajania `"` (2), `pool_mode =
transaction` (4), `server_reset_query =` pusty (4), sonda przez główną pulę (7).

## Pomiar wydajności

Skrypt pomiarowy z 2026-09-27 (czas `connect` + zapytanie zimne/ciepłe z
kontenera appservera), uruchomiony przed i po. Do zmierzenia jako **opcja, nie
domyślna**: `auth_type = md5` na odcinku appserver → pgbouncer (sieć wewnętrzna
compose) zdejmuje PBKDF2 po obu stronach — jeśli pomiar pokaże, że SCRAM
dominuje pozostały koszt, osobna decyzja.

## Kryteria akceptacji

- testy statyczne i `make test-pgbouncer` zielone lokalnie i w CI;
- na publikacje.up.lublin.pl po wdrożeniu: czas `connect` + pierwsze zapytanie
  (dziś 18 + 9,7 ms) spada do rzędu ≤ 8 ms, a mediana `request_time` w access
  logu nie rośnie;
- `make doctor` i bramka zdrowia `make up` zielone.

## Dokumentacja

- `docs/konfiguracja/pgbouncer.md` (nowa): po co i co realnie daje, co idzie
  przez pulę, zmienne, wyłączenie, tryb zewnętrzny, diagnostyka (`SHOW POOLS`
  przez `stats_users`, `stats:` w logu).
- `docs/architektura/uslugi.md`: nowa usługa, zależności.
- `docs/konfiguracja/limity-zasobow.md`: `PGBOUNCER_*_LIMIT`, relacja
  `DBSERVER_MEM_LIMIT → max_connections → PGBOUNCER_POOL_SIZE`.
- `docs/eksploatacja/komendy.md`: `make test-pgbouncer`.
- `mkdocs.yml` nav.
- `CLAUDE.md` — tylko tripwire'y: wyłącznie `session` (powód: `WITH HOLD`
  cursors); nie przepinać `DJANGO_BPP_DB_HOST` na pulę; denorm-queue nigdy przez
  pulę; własny entrypoint zamiast obrazowego (escapowanie); sonda przez osobny
  wpis `_health`; `service_started`, nie `service_healthy`.

## Poza zakresem

Celery przez pulę; tryb `transaction`; TLS do bazy; kolektor netdata dla
pgbouncera; konsola admina (`admin_users`); `.gitattributes` z `*.sh eol=lf`
(problem istniejący, dotyczy też `dbserver/*.sh`); sprzątanie zdublowanych
zmiennych `DJANGO_BPP_DB_*` w `.env` na publikacje.up.lublin.pl (osobno, przed
wdrożeniem).

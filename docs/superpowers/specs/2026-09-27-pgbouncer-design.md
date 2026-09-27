# pgbouncer przed PostgreSQL dla appservera — projekt

Data: 2026-09-27 · Status: zatwierdzony kształt, spec do przeglądu

## Cel

Przyspieszyć odpowiedzi appservera, usuwając koszt nawiązywania połączenia
z PostgreSQL przy **każdym** żądaniu HTTP.

### Pomiar, który to uzasadnia (publikacje.up.lublin.pl, 2026-09-27)

Z kontenera `appserver`, 30 prób, mediany:

| Co | Czas |
|---|---|
| nowe połączenie `psycopg2.connect` (SCRAM, fork backendu) | **18 ms** (13–33) |
| pierwsze zapytanie na świeżym połączeniu (zimny catcache) | 9,7 ms |
| to samo zapytanie drugi raz | 1,5 ms |
| całe żądanie do appservera (24 h, n = 33 207) | **100 ms** (p90 145, p99 1063) |

Django ma `CONN_MAX_AGE=0` — każde żądanie otwiera i zamyka połączenie. Szacunek
straty: ~15–25 ms na żądanie (~15–25 % mediany). To **szacunek ze składowych**;
efekt po wdrożeniu mierzymy osobno (sekcja *Kryteria akceptacji*).

Dlaczego nie `CONN_MAX_AGE > 0`: appserver działa pod ASGI, gdzie Django nie
radzi sobie z trwałymi połączeniami (żądania trafiają do różnych wątków; na
produkcji silnik to już `django_bpp.db_connclosed_fix`). Pula zewnętrzna omija
problem bez zmiany obrazu BPP.

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
   dalej znaczy „prawdziwa baza”. Nowe `DJANGO_BPP_DB_APP_HOST`/`_APP_PORT`
   wskazują, dokąd łączy się appserver.
4. **Jedna konfiguracja dla bazy w compose i zewnętrznej.** pgbouncer łączy się
   z `DJANGO_BPP_DB_HOST`/`_PORT`, niezależnie od trybu. Baza zewnętrzna jest
   dedykowana BPP i nie wymaga TLS.
5. **Tryb `session`, na sztywno.** `transaction` łamie `LISTEN`, session-level
   advisory locks (`src/django_bpp/db_locks.py`), `WITH HOLD` cursory, `SET`
   i `PREPARE` (tabela zgodności: <https://www.pgbouncer.org/features.html>).
   `session` wspiera wszystko, a przy zwrocie do puli wykonuje `DISCARD ALL`
   (`server_reset_query`, domyślnie tylko w tym trybie).
6. **To samo konto co dziś.** `auth_file` generowany z `DJANGO_BPP_DB_USER`
   i `DJANGO_BPP_DB_PASSWORD` z `.env`; `auth_type = scram-sha-256` (dopuszcza
   w `auth_file` hasło jawne). `auth_query` i kopiowanie sekretów SCRAM
   odrzucone — więcej ruchomych części przy jednym użytkowniku aplikacji.

## Architektura

```
                 ┌──────────── appserver ────────────┐
                 │ DJANGO_BPP_DB_HOST=${DJANGO_BPP_DB_APP_HOST:-pgbouncer}
                 │ DJANGO_BPP_DB_PORT=${DJANGO_BPP_DB_APP_PORT:-6432}
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
| `docker-compose.application.yml` | appserver: nadpisanie `DJANGO_BPP_DB_HOST`/`_PORT` w `environment:` + `depends_on: pgbouncer: service_healthy` |
| `defaults/pgbouncer/entrypoint.sh` (nowy) | renderuje `pgbouncer.ini` + `userlist.txt`, potem `exec pgbouncer` |

`environment:` w compose ma pierwszeństwo przed `env_file:`, więc nadpisanie
działa bez ruszania `.env`. Interpolacja `${DJANGO_BPP_DB_APP_HOST}` czyta
`$BPP_CONFIGS_DIR/.env` przez `env_file` na poziomie `include:`.

### Usługa `pgbouncer`

- Obraz `edoburu/pgbouncer:${PGBOUNCER_VERSION:-v1.25.2-p0}` — utrzymywany
  (wydanie 2026-06-10), budowany z oficjalnego tarballa, działa jako `postgres`
  (uid 70), ma `pg_isready`, `psql`, `nc`; `/etc/pgbouncer` należy do `postgres`.
- `entrypoint: ["/bpp-entrypoint.sh"]` — **własny** skrypt zamiast entrypointu
  obrazu. Tamten wpisuje hasło do `userlist.txt` bez escapowania (`"` w haśle
  psuje plik) i wkleja wartości do formatu `printf` (`%` psuje konfigurację).
- `env_file: ${BPP_CONFIGS_DIR}/.env` na poziomie usługi (ten z `include:`
  służy tylko interpolacji — ta sama lekcja co przy `dbserver`).
- `depends_on: dbserver: service_healthy` — w trybie zewnętrznym `dbserver` to
  sentinel sondujący prawdziwą bazę, więc działa w obu trybach.
- `restart: always`, `logging: *default-logging`.
- `deploy.resources.limits`: `PGBOUNCER_MEM_LIMIT` (domyślnie `64m`),
  `PGBOUNCER_CPU_LIMIT` (domyślnie `0.5`).
- Bez opublikowanego portu — tylko sieć compose.

### Healthcheck

`psql` przez pgbouncer do bazy: `SELECT 1` na `127.0.0.1:6432` kontem aplikacji
(`PGPASSWORD=$$DJANGO_BPP_DB_PASSWORD`, `$$` — Compose interpoluje `$`).
Sprawdza całą ścieżkę: pgbouncer → uwierzytelnienie → baza. `pg_isready` sam
w sobie sprawdzałby tylko, czy pgbouncer przyjmuje połączenia.

### Konfiguracja renderowana przez `entrypoint.sh`

`/etc/pgbouncer/pgbouncer.ini`:

```ini
[databases]
<DJANGO_BPP_DB_NAME> = host=<DJANGO_BPP_DB_HOST> port=<DJANGO_BPP_DB_PORT>

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = session
default_pool_size = <PGBOUNCER_POOL_SIZE>
max_db_connections = <PGBOUNCER_POOL_SIZE>
max_client_conn = <PGBOUNCER_MAX_CLIENT_CONN>
query_wait_timeout = 30
server_tls_sslmode = prefer
ignore_startup_parameters = extra_float_digits
```

Pozycja bazy **bez `user=`** — pgbouncer loguje się do PostgreSQL danymi klienta
(tym samym kontem). `server_reset_query` zostaje domyślne (`DISCARD ALL`).
`server_tls_sslmode = prefer`: TLS nie jest wymagany, a `prefer` działa z nim
i bez niego.

`/etc/pgbouncer/userlist.txt`: `"<user>" "<hasło>"`, każdy `"` w polu podwojony
(format z dokumentacji: *„Double quotes in a field value can be escaped by
writing two double quotes”*). Uprawnienia `0600`.

### Zmienne

| Zmienna | Domyślnie | Uwagi |
|---|---|---|
| `DJANGO_BPP_DB_APP_HOST` | `pgbouncer` | wyłączenie puli: adres prawdziwej bazy |
| `DJANGO_BPP_DB_APP_PORT` | `6432` | wyłączenie puli: port prawdziwej bazy |
| `PGBOUNCER_POOL_SIZE` | `60` | = `BPP_NGINX_GLOBAL_CONN`; musi być wyraźnie < `max_connections` |
| `PGBOUNCER_MAX_CLIENT_CONN` | `200` | > `GUNICORN_LIMIT_CONCURRENCY` (80) × `WEB_CONCURRENCY` |
| `PGBOUNCER_VERSION` | `v1.25.2-p0` | przypięty tag, jak `HTML2DOCX_VERSION` |
| `PGBOUNCER_MEM_LIMIT` / `_CPU_LIMIT` | `64m` / `0.5` | jak reszta `*_LIMIT` |

Liczby walidowane w skrypcie jak w `25-render-bpp-limits.sh`: puste = domyślna,
śmieć = `OSTRZEZENIE` w logu + domyślna. Brak nowej zmiennej wymaganej — **zero
migracji `.env`**, stary `.env` działa (kontrakt backwards-compat).

Wyłączenie puli (`docs/konfiguracja/pgbouncer.md`):

```
DJANGO_BPP_DB_APP_HOST=dbserver     # albo host zewnętrznej bazy
DJANGO_BPP_DB_APP_PORT=5432
make up
```

Usługa `pgbouncer` dalej działa bezczynnie (kilka MB) — celowo, bez warunkowego
compose; jedno pokrętło, łatwy powrót.

## Awarie

| Sytuacja | Skutek | Obrona |
|---|---|---|
| pgbouncer pada | leży strona (appserver); Celery, denorm, panele działają | `restart: always`; bramka zdrowia `make up` |
| baza niedostępna | jak dziś — appserver dostaje błąd połączenia | healthcheck `pgbouncer` czerwony, widoczny w `make doctor` |
| błędne hasło w `.env` | pgbouncer wstaje, logowanie klienta pada | healthcheck (`psql` przez pulę) czerwony → appserver nie startuje |
| pula pełna | klient czeka do `query_wait_timeout` (30 s), potem błąd | limity nginx/appservera trzymają ruch poniżej rozmiaru puli |
| zmiana hasła | `.env` → `make up` odtwarza kontener (zmiana `env_file`) | — |

## Testy

**Statyczne** (`tests/test_makefile.sh`, na wyrenderowanym `docker compose config`
— grep po źródle nie widzi interpolacji):

- domyślnie appserver ma `DJANGO_BPP_DB_HOST=pgbouncer`, `_PORT=6432`;
- z `DJANGO_BPP_DB_APP_HOST=dbserver` + `_PORT=5432` — bezpośrednio;
- **żaden inny** serwis nie łączy się z `pgbouncer` (authserver, workerserver,
  celerybeat, denorm-queue, flower, netdata);
- `pgbouncer` ma `logging`, limity, `depends_on: dbserver`, serwisowy `env_file`;
- `$$` w healthchecku przetrwał render (`test_compose_shell_vars_escaped`).

**Na żywo** (`scripts/test-pgbouncer.sh` → `make test-pgbouncer`, do CI obok
`test-nginx-limits`): prawdziwy `postgres` (SCRAM) + `pgbouncer` z naszym
`entrypoint.sh`:

1. logowanie przez pulę tym samym kontem;
2. hasło z `"`, `%`, `$`, spacją — logowanie działa;
3. `LISTEN` działa; advisory lock wzięty w połączeniu A jest **zwolniony** po
   rozłączeniu A (`DISCARD ALL`) — połączenie B go dostaje;
4. dwa kolejne połączenia klienta dostają **ten sam** `pg_backend_pid()` —
   dowód ponownego użycia, czyli źródła przyspieszenia;
5. baza pod nazwą hosta inną niż `dbserver` (symulacja trybu zewnętrznego);
6. śmieć w `PGBOUNCER_POOL_SIZE` → ostrzeżenie + domyślna, pgbouncer wstaje;
7. healthcheck czerwony przy złym haśle.

Mutacje do sprawdzenia: bez podwajania `"`, `pool_mode=transaction`
(przypadek 3 musi paść), `DISCARD ALL` wyłączone.

## Kryteria akceptacji

- testy statyczne i `make test-pgbouncer` zielone lokalnie i w CI;
- na publikacje.up.lublin.pl po wdrożeniu: skrypt pomiarowy (jak z 2026-09-27)
  pokazuje spadek kosztu połączenia appserver → baza wyraźnie poniżej 18 ms,
  a mediana `request_time` w access logu nie rośnie;
- `make doctor` i bramka zdrowia `make up` zielone.

## Dokumentacja

- `docs/konfiguracja/pgbouncer.md` (nowa): po co, co idzie przez pulę, zmienne,
  wyłączenie, tryb zewnętrzny, diagnostyka (`SHOW POOLS` przez konsolę admina
  nie jest włączona — logi `docker compose logs pgbouncer`).
- `docs/architektura/uslugi.md`: nowa usługa, zależności.
- `docs/konfiguracja/limity-zasobow.md`: `PGBOUNCER_*_LIMIT`, relacja
  `POOL_SIZE` ↔ `max_connections`.
- `mkdocs.yml` nav.
- `CLAUDE.md` — tylko tripwire'y: wyłącznie `session`; nie przepinać
  `DJANGO_BPP_DB_HOST` na pulę; denorm-queue nigdy przez pulę; własny entrypoint
  zamiast obrazowego (escapowanie); `POOL_SIZE` < `max_connections`.

## Poza zakresem

Celery przez pulę; tryb `transaction`; TLS do bazy; kolektor netdata dla
pgbouncera; konsola admina pgbouncera; sprzątanie zdublowanych zmiennych
`DJANGO_BPP_DB_*` w `.env` na publikacje.up.lublin.pl (osobno, przed wdrożeniem).

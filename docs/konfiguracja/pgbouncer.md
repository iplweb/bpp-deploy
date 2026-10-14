# pgbouncer — pula połączeń dla appservera

Appserver łączy się z PostgreSQL przez **pgbouncer** w trybie `session`.
Włączone domyślnie, bez żadnej zmiany w `.env`.

## Po co

Django w appserverze otwiera nowe połączenie z bazą przy **każdym** żądaniu
i zamyka je na końcu. Pomiar na publikacje.up.lublin.pl (27.09.2026): samo
połączenie kosztowało **18 ms**, a pierwsze zapytanie na świeżym połączeniu
kolejne ~8 ms (zimny cache katalogu) — przy medianie całego żądania 100 ms.

pgbouncer trzyma gotowe połączenia z bazą i oddaje je kolejnym żądaniom. Znika
tworzenie procesu PostgreSQL i zimny cache; zostaje tańsze logowanie do samego
pgbouncera (SCRAM).

To **nie** jest ochrona przed zalewem ruchu — tę dają
[limity nginx i appservera](../architektura/rate-limiting.md#limit-globalny).

## Co idzie przez pulę

| Serwis | Połączenie z bazą |
|---|---|
| appserver | **przez pgbouncer** |
| authserver, workerserver, celerybeat, denorm-queue, flower | bezpośrednio |
| netdata (`bpp_monitor`) | bezpośrednio — ma widzieć prawdziwy serwer |
| backup / restore | `docker exec` w `dbserver` — bez zmian |

pgbouncer łączy się z `DJANGO_BPP_DB_HOST`/`DJANGO_BPP_DB_PORT` — czyli
z `dbserver` albo z [bazą zewnętrzną](postgresql.md). Ta sama konfiguracja
w obu trybach. Logowanie tym samym kontem co dotąd
(`DJANGO_BPP_DB_USER`/`_PASSWORD`).

## Zmienne (`$BPP_CONFIGS_DIR/.env`)

| Zmienna | Domyślnie | Znaczenie |
|---|---|---|
| `BPP_APPSERVER_DB_HOST` | `pgbouncer` | dokąd łączy się appserver |
| `BPP_APPSERVER_DB_PORT` | `6432` | port dla powyższego |
| `PGBOUNCER_POOL_SIZE` | `80` | maks. połączeń pgbouncera do bazy |
| `PGBOUNCER_MAX_CLIENT_CONN` | `1000` | maks. połączeń appservera do pgbouncera |
| `PGBOUNCER_VERSION` | `v1.25.2-p0` | tag obrazu `edoburu/pgbouncer` |
| `PGBOUNCER_MEM_LIMIT` / `_CPU_LIMIT` | `64m` / `0.5` | [limity zasobów](limity-zasobow.md) |

Pusta wartość = domyślna; błędna liczba = `OSTRZEZENIE` w logu i domyślna.

Appserver bezpośrednio do bazy (z pominięciem puli):

```
BPP_APPSERVER_DB_HOST=dbserver     # albo host bazy zewnętrznej
BPP_APPSERVER_DB_PORT=5432
```

potem `make up`. Usługa `pgbouncer` dalej działa i dalej musi być zdrowa.

## Pula a `max_connections`

Do tego samego serwera łączą się też bezpośrednio Celery, denorm-queue
i reszta. Przy starcie pgbouncer odczytuje `max_connections` i — jeśli pula
się nie mieści — **przycina ją** z ostrzeżeniem w logu:

```
bpp-pgbouncer: OSTRZEZENIE: PGBOUNCER_POOL_SIZE=80 przekracza max_connections=100 minus rezerwa 40 — przycinam do 60. Obniz BPP_NGINX_GLOBAL_CONN do <= 60 albo podnies DBSERVER_MEM_LIMIT (autotune: 100 polaczen na 1 GB).
```

## Diagnostyka

```bash
make pgbouncer-stats        # stan puli: kolejka, wolne/zajęte, sesje wiszące bez zapytań
make db-connection-stats    # kto trzyma połączenia z PostgreSQL, rozbite na kontenery
docker compose logs pgbouncer | grep bpp-pgbouncer     # konfiguracja przy starcie
docker compose logs pgbouncer | grep stats             # co 60 s; pole "wait" > 0 = kolejka
```

Obie komendy są tylko do odczytu. Przy podejrzeniu „baza nie wyrabia” idź po
kolei:

1. **`make db-connection-stats`** — ile z `max_connections` jest zajęte i przez kogo.
   Przy działającej puli pgbouncer ma twardy sufit (`PGBOUNCER_POOL_SIZE`), więc
   jeśli PostgreSQL odrzuca klientów (`too many clients` /
   `zbyt wielu klientów`), przepełnienie robi **reszta**: usługi łączące się
   bezpośrednio. Kolumna `idle-tx` > 0 przez dłużej niż minutę to otwarta
   transakcja trzymająca blokady.
2. **`make pgbouncer-stats`** — czy pula jest pełna. `w kolejce` > 0 znaczy, że
   appserver czeka na wolne połączenie (po 15 s dostaje błąd).

!!! warning "`idle` w PostgreSQL nie znaczy „wolne” w puli"
    Pula pracuje w trybie `session`: połączenie z bazą jest przypisane do
    klienta na **całe jego połączenie**, także między zapytaniami. Backend
    pgbouncera widoczny w `pg_stat_activity` jako `idle` może więc być wolnym
    połączeniem puli albo sesją, którą appserver trzyma i nic na niej nie robi.
    Rozróżnia je dopiero `make pgbouncer-stats` (`Serwery: N przypisane
    klientom | M wolne`).

Sekcja „czas od ostatniego zapytania” w `make pgbouncer-stats` wyłapuje sesje,
które trzymają połączenie, ale nie pytają bazy. Jedna próbka nic nie
rozstrzyga — **powtórz pomiar za kilkanaście minut pod ruchem**:

- liczba **stała**, mniej więcej równa liczbie procesów gunicorna, to narzut
  startowy (każdy worker trzyma jedno połączenie) — niegroźny;
- liczba **rosnąca** znaczy, że appserver nie oddaje połączeń po żądaniu
  i w końcu zapcha pulę. Doraźnie pomaga wyższe `PGBOUNCER_POOL_SIZE` (o ile
  `max_connections` ma zapas — patrz `make db-connection-stats`), przyczyna jest
  w obrazie BPP.

Długie zapytanie też ma dawny czas ostatniego zapytania — porównaj z kolumną
`active` w `make db-connection-stats`.

## Awarie

pgbouncer jest infrastrukturą jak `dbserver`: gdy jest `unhealthy`, appserver
nie startuje, a `make up` kończy się błędem. Celery, denorm i panele działają
dalej.

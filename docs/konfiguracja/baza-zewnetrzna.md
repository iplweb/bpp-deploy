# Baza zewnętrzna (PostgreSQL poza Dockerem)

Domyślnie BPP uruchamia PostgreSQL w kontenerze `dbserver` i sam o niego dba:
wersja, strojenie, kodowanie, backup. W trybie **bazy zewnętrznej** BPP łączy się
z istniejącym serwerem PostgreSQL (osobna maszyna, klaster uczelniany, usługa
zarządzana). Ta strona opisuje cały proces: co przygotować na serwerze bazy, jak
podłączyć BPP i za co od tej pory odpowiadasz sam.

!!! tip "Kiedy baza zewnętrzna ma sens"
    Gdy uczelnia ma już administrowany serwer PostgreSQL (z backupem, replikacją,
    monitoringiem), albo baza ma dostać więcej zasobów, niż zmieści host aplikacji.
    W innych przypadkach baza w Dockerze jest prostsza — stroi się sama i nie
    wymaga niczego po drugiej stronie.

## Co się zmienia w trybie zewnętrznym

| | Baza w Dockerze | Baza zewnętrzna |
|---|---|---|
| Kontener `dbserver` | prawdziwy PostgreSQL | **wartownik** (`postgres:<major>-alpine`): sprawdza, czy baza żyje, i daje `psql`/`pg_dump` w pasującej wersji |
| Strojenie (`shared_buffers`, `max_connections`…) | automatyczne przy każdym starcie | **Twoje** — gotowiec: [`make db-autotune-external`](#4-strojenie) |
| Kodowanie i kolacja (ICU `pl-PL`) | ustawiane przy pierwszym starcie | **Twoje** — przy `CREATE DATABASE` |
| Upgrade PostgreSQL | `make upgrade-postgres` | po Twojej stronie ([PostgreSQL](postgresql.md#tryb-external)) |
| Nocny backup (`pg_dump`) | działa | **działa** — przez wartownika, dump ląduje na hoście BPP |
| Metryki (Netdata, Grafana) | automatycznie | po założeniu roli `bpp_monitor` ([krok 5](#5-monitoring)) |
| Logi serwera bazy w Grafanie | tak | **nie** — BPP nie widzi logów obcej maszyny |
| Wolne zapytania | `make pg-monitoring-setup` | ten sam target wypisuje SQL do wykonania ręcznie |

Połączenia: `appserver` łączy się przez [pgbouncer](pgbouncer.md), a Celery,
denorm-queue, celerybeat, authserver, Netdata i backup — **bezpośrednio** z serwerem
bazy. Dla serwera bazy wszystkie przychodzą z adresu IP hosta BPP (Docker robi NAT).

## 1. Wymagania wobec serwera

- **PostgreSQL 16 lub nowszy** (zalecany 18). Baza świeżej instalacji powstaje
  z gotowego zrzutu robionego na PostgreSQL 16; kolacja ICU per baza wymaga
  co najmniej 15.
- **Rozszerzenia z pakietu `contrib`**: `btree_gist`, `hstore`, `pg_trgm`, `unaccent`.
  W pakietach Debiana/Ubuntu (`postgresql-<wersja>`) i w obrazach Dockera są
  w zestawie; w usługach zarządzanych zwykle są na liście dozwolonych.
- **Superuser nie jest potrzebny w aplikacji.** Wszystkie cztery rozszerzenia są
  „zaufane" (*trusted*), więc właściciel bazy założy je sam. Starsze wersje BPP
  wymagały `plpython3u` (a więc superusera i pakietu `postgresql-plpython3`) —
  obecne już nie.
- **Sieć**: host BPP musi dosięgnąć serwera bazy na porcie PostgreSQL (domyślnie
  5432). Kreator sprawdza połączenie z hosta (`docker run --network host`), więc
  zadziała to, co działa z samego hosta.

## 2. Przygotowanie serwera bazy

Wszystko poniżej wykonujesz **na serwerze bazy, jako superuser** (np.
`sudo -u postgres psql`).

### Rola i baza

```sql
-- Hasło: długie i losowe, np. z `openssl rand -base64 24`.
CREATE ROLE bpp LOGIN PASSWORD 'TU-WPISZ-HASLO';

CREATE DATABASE bpp
    OWNER bpp
    ENCODING 'UTF8'
    TEMPLATE template0
    LOCALE_PROVIDER icu
    ICU_LOCALE 'pl-PL';
```

Dlaczego tak:

- **`OWNER bpp`** — właściciel bazy może zakładać w niej tabele i zaufane
  rozszerzenia. Nie dawaj roli `bpp` atrybutu `SUPERUSER` ani `CREATEROLE`.
- **`ICU_LOCALE 'pl-PL'`** — polska kolejność sortowania (`Ł` po `L`, `Ś` po `S`,
  `Ż` na końcu) przy listach autorów, jednostek i źródeł. Tak samo powstaje baza
  w Dockerze. Kolacji **nie da się zmienić** na istniejącej bazie bez dump/restore —
  ustaw ją od razu.
- **`TEMPLATE template0`** — wymagane przy kolacji innej niż w szablonie.

Sprawdzenie (po `\c bpp`):

```sql
SELECT datlocprovider FROM pg_database WHERE datname = current_database();
-- i  (= ICU)

SELECT string_agg(x, ' ' ORDER BY x)
FROM unnest(ARRAY['Łukasz','Lucyna','Żaneta','Zenon','Ćwik','Cyran','Śliwa','Szot']) x;
-- Cyran Ćwik Lucyna Łukasz Szot Śliwa Zenon Żaneta
```

Jeśli `Ł`, `Ś`, `Ż` lądują na końcu listy, baza ma złą kolację — usuń ją i załóż
jeszcze raz, póki jest pusta.

!!! note "Rozszerzenia możesz założyć z góry"
    Nie jest to wymagane — przy pierwszym starcie appserver założy je sam jako
    właściciel bazy. Jeśli jednak polityka serwera zabrania zakładania rozszerzeń
    zwykłym rolom (część usług zarządzanych), załóż je jako superuser:

    ```sql
    \c bpp
    CREATE EXTENSION IF NOT EXISTS btree_gist;
    CREATE EXTENSION IF NOT EXISTS hstore;
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
    CREATE EXTENSION IF NOT EXISTS unaccent;
    ```

### Dostęp sieciowy (`pg_hba.conf`, `listen_addresses`) {#dostep-sieciowy}

W `postgresql.conf` serwer musi słuchać na interfejsie widocznym dla hosta BPP:

```ini
listen_addresses = '*'          # albo konkretny adres
password_encryption = scram-sha-256
```

W `pg_hba.conf` wpuść **adres hosta BPP** (nie sieć Dockera — kontenery wychodzą
przez NAT z adresem hosta) do bazy `bpp`, dla roli aplikacji i roli monitoringu:

```text
# TYPE  DATABASE  USER         ADDRESS            METHOD
host    bpp       bpp          192.0.2.10/32      scram-sha-256
host    bpp       bpp_monitor  192.0.2.10/32      scram-sha-256
```

Po zmianie `pg_hba.conf` wystarczy przeładowanie (`SELECT pg_reload_conf();`),
po zmianie `listen_addresses` — restart PostgreSQL. Otwórz też port na firewallu
serwera bazy, wyłącznie dla adresu hosta BPP.

!!! warning "Szyfrowanie połączenia (SSL)"
    BPP nie wymusza SSL do bazy, a **monitoring (Netdata, Grafana) łączy się
    bez SSL** (`sslmode=disable` na sztywno), więc wpisy `hostssl` (wymuszające
    SSL) zablokują co najmniej metryki.
    Używaj `host` i trzymaj ruch w sieci prywatnej/VPN między hostem BPP a bazą.

## 3. Podłączenie BPP

Przy pierwszym `make` kreator pyta o tryb bazy:

```text
Tryb bazy danych:
  (1) wewnetrzna - PostgreSQL w kontenerze Docker (domyslne)
  (2) zewnetrzna - podlaczenie do istniejacego, zewnetrznego serwera PostgreSQL
```

Wybierz **2** i podaj host, port, nazwę bazy, użytkownika i hasło z kroku 2.
Kreator połączy się z bazą, **wykryje wersję PostgreSQL** i dobierze do niej obraz
wartownika. Jeśli połączenie się nie uda (firewall, `pg_hba.conf`, hasło), zapyta
o wersję ręcznie — wtedy wróć do kroku 2, zanim przejdziesz dalej.

Kreator zapisuje:

- w **repo-lokalnym** `.env`: `BPP_DATABASE_COMPOSE=docker-compose.database.external.yml`
  (to przełącza tryb),
- w `$BPP_CONFIGS_DIR/.env`: `DJANGO_BPP_DB_HOST`, `_PORT`, `_NAME`, `_USER`,
  `_PASSWORD`, `DJANGO_BPP_POSTGRESQL_VERSION_MAJOR`.

Potem zwykłe `make up`. Przy pierwszym starcie appserver widzi pustą bazę i w kilka
sekund wczytuje do niej gotowy schemat (zamiast odtwarzać kilkaset migracji),
a następnie dociąga najnowsze migracje. Kreator `/setup/` w przeglądarce zakłada
pierwsze konto administratora.

!!! note "Przełączenie istniejącej instalacji na bazę zewnętrzną"
    Uruchom ponownie `make init-configs` i wybierz tryb 2 — kreator nadpisze
    parametry połączenia w `.env`. Dane przenieś przez dump/restore
    ([Baza danych](../eksploatacja/baza-danych.md)); najpierw `make db-backup`.

## 4. Strojenie serwera bazy {#4-strojenie}

Baza w Dockerze stroi się sama; zewnętrznej BPP nie widzi, więc gotowiec liczysz
z jej parametrów:

```bash
make db-autotune-external RAM=16G CPU=8    # RAM i rdzenie SERWERA BAZY
```

Dostajesz fragment `postgresql.conf`, to samo jako `ALTER SYSTEM`, listę
parametrów wymagających restartu i porównanie z obecnymi ustawieniami.
Szczegóły: [Autotune dla bazy zewnętrznej](postgresql.md#autotune-external).

**Ile połączeń potrzebuje BPP.** Na `max_connections` składają się:

- pula pgbouncera dla appservera (`PGBOUNCER_POOL_SIZE`, domyślnie 80),
- połączenia bezpośrednie: Celery (ok. ¾ rdzeni hosta BPP), denorm-queue,
  celerybeat, authserver, Netdata, backup, sesje administracyjne,
- 3 sloty zarezerwowane dla superusera (`superuser_reserved_connections`).

pgbouncer przy starcie odczytuje `max_connections` z serwera i **sam przycina pulę**
do `max_connections − max(40, 20 + ¾ × rdzenie hosta BPP)` (z ostrzeżeniem w logu).
Praktycznie: **co najmniej 150**, a bezpiecznie tyle, ile wyliczy autotune
(100 na każdy 1 GB RAM bazy, maks. 250). Wyższe `max_connections` bez RAM-u nie
pomaga — przy skanie botów baza padnie z braku pamięci, zanim zabraknie połączeń.
Po każdej zmianie `max_connections` zrestartuj pgbouncer:
`docker compose restart pgbouncer`.

**Wpisz RAM serwera bazy do `.env`** — z niego `make up` liczy
[budżet połączeń](pgbouncer.md#budzet-polaczen), czyli pulę pgbouncera i limit
równoczesnych żądań w nginksie, tak żeby nadmiar ruchu dostawał 429, zamiast
dochodzić do bazy:

```bash
BPP_DB_RAM=16G
BPP_DB_CPUS=8     # opcjonalnie; domyślne CPU= dla make db-autotune-external
```

Z tymi zmiennymi `make db-autotune-external` nie potrzebuje już parametrów.
Sprawdzenie: `make db-budget`.

Jak sprawdzić, kto trzyma połączenia: `make db-connection-stats` i
`make pgbouncer-stats` (w trybie zewnętrznym zamiast nazw kontenerów zobaczysz
zwykle adres hosta BPP).

## 5. Monitoring {#5-monitoring}

Netdata i Grafana czytają statystyki bazy jako rola tylko do odczytu `bpp_monitor`
(hasło generuje się samo w `.env` jako `DJANGO_BPP_PG_MONITOR_PASSWORD`). Na bazie
zewnętrznej BPP nie może jej założyć sam, więc wypisze gotowy SQL:

```bash
make create-monitoring-user
```

Wykonaj wypisany SQL na serwerze bazy jako superuser i dopisz `bpp_monitor`
w `pg_hba.conf` ([krok 2](#dostep-sieciowy)). Bez tej roli
Grafana i Netdata zgłaszają `password authentication failed for user "bpp_monitor"`.

Wolne zapytania (`pg_stat_statements`, `log_min_duration_statement`):

```bash
make pg-monitoring-setup
```

W trybie zewnętrznym target niczego nie zmienia, tylko wypisuje SQL — w tym zmianę
`shared_preload_libraries`, która wymaga restartu PostgreSQL. Szczegóły:
[Wolne zapytania](../monitoring/slow-queries.md).

!!! info "Czego BPP nie widzi"
    Logi samego serwera bazy (restarty, `out of memory`, błędy uwierzytelnienia)
    zostają na tamtej maszynie — dashboardy Grafany ich nie pokażą. Błędy, które
    dotrą do aplikacji (np. `too many clients`), trafią do logów `appserver`
    i — jeśli skonfigurowany — do Rollbara.

## 6. Backup

`make db-backup` i nocny cykl backupu działają bez zmian: `pg_dump` wykonuje się
w kontenerze-wartowniku (ta sama wersja major co serwer), a dump trafia do
katalogu backupów **na hoście BPP** i dalej przez rclone
([Backup i rclone](../eksploatacja/backup-i-rclone.md)). Backup po stronie serwera
bazy (WAL, snapshoty, replika) to osobna sprawa jego administratora — nocny dump
BPP go nie zastępuje.

Przy [odtwarzaniu konfiguracji](../eksploatacja/backup-i-rclone.md#backup-konfiguracji-env)
na nowym hoście dopisz ręcznie do repo-lokalnego `.env`:
`BPP_DATABASE_COMPOSE=docker-compose.database.external.yml`.

## 7. Aktualizacje PostgreSQL

Upgrade serwera bazy robisz po swojej stronie (`pg_upgradecluster`, usługa
zarządzana, blue/green). `make upgrade-postgres` w trybie zewnętrznym tylko
prowadzi przez kroki i aktualizuje wersję wartownika w `.env`
([PostgreSQL — tryb external](postgresql.md#tryb-external)). Próba aktualizacji
BPP (`make test-upgrade`) robi lokalną kopię bazy na hoście BPP —
[Aktualizacje](../eksploatacja/aktualizacje.md#baza-zewnetrzna).

## Lista kontrolna

- [ ] PostgreSQL ≥ 16, `contrib` zainstalowany
- [ ] rola `bpp` (bez superusera) i baza `bpp` z `OWNER bpp`, ICU `pl-PL`, `template0`
- [ ] `listen_addresses`, `pg_hba.conf` (`bpp` + `bpp_monitor` z adresu hosta BPP), firewall
- [ ] `make` → tryb **2**, kreator wykrył wersję
- [ ] `make db-autotune-external RAM=… CPU=…` → wklejone, PostgreSQL zrestartowany
- [ ] `BPP_DB_RAM` (i `BPP_DB_CPUS`) w `.env`, `make db-budget` pokazuje pulę i limit nginx
- [ ] `make up`, `/setup/` w przeglądarce
- [ ] `make create-monitoring-user` → SQL wykonany; Grafana pokazuje metryki bazy
- [ ] `make db-backup` przechodzi

## Rozwiązywanie problemów

| Objaw | Przyczyna | Co zrobić |
|---|---|---|
| Kreator: „nie udalo sie wykryc wersji" | brak połączenia z hosta BPP | `pg_hba.conf`, `listen_addresses`, firewall; test: `psql -h <host> -U bpp bpp` z hosta BPP |
| `no pg_hba.conf entry for host "…"` | w `pg_hba.conf` jest inny adres niż ten, z którego przychodzi BPP | wpisz adres z komunikatu (to adres hosta BPP po NAT) |
| `permission denied to create extension` | rola `bpp` nie jest właścicielem bazy albo serwer blokuje rozszerzenia | `ALTER DATABASE bpp OWNER TO bpp;` albo załóż rozszerzenia jako superuser (krok 2) |
| `extension "… " is not available` | brak pakietu `contrib` | zainstaluj `postgresql-contrib` dla swojej wersji |
| `password authentication failed for user "bpp_monitor"` | rola monitoringu nie istnieje albo ma inne hasło | `make create-monitoring-user`, wykonaj SQL |
| `sorry, too many clients already` | `max_connections` za małe na pulę + połączenia bezpośrednie | [krok 4](#4-strojenie), `make db-connection-stats` |
| Polskie nazwiska sortują się źle (`Ł` po `Z`) | baza nie ma kolacji ICU `pl-PL` | dump → nowa baza wg kroku 2 → restore |

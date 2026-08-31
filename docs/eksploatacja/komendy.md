# Najważniejsze komendy

```bash
make help             # Pełna lista wszystkich targetów Make (źródło prawdy)
```

`make help` jest źródłem prawdy — poniżej tematyczny przegląd najważniejszych targetów.

## Wdrożenie

```bash
make run                # Pełne wdrożenie (pull, build, configs, up)
make up                 # Start wszystkich usług (force recreate) + sprzątanie Dockera
make up-quick           # Szybki start bez recreation (bez sprzątania)
make refresh            # prune + pull + recreate (po update obrazu)
make wait               # Czeka na build z GH Actions, potem make refresh
make stop               # Zatrzymaj usługi
make restart-appserver  # Restart serwera aplikacji
```

### Wdrożenie z uprzedzeniem użytkowników

```bash
make run-with-warning                      # pull → baner 5 min → run → odblokowanie
make run-with-warning MINUTES=10 SERVICE=20 MESSAGE="Aktualizacja raportów"

make enable-site-down-warning              # sam baner, bez wdrożenia
make extend-site-down-warning MINUTES=+10  # przesuń deklarowany powrót
make status-site-down-warning              # stan przerwy (JSON=1 = dane maszynowe)
make disable-site-down-warning             # awaryjne odblokowanie strony
```

Pełny opis (fazy, zachowanie przy błędzie, multi-host, zabezpieczenie na wypadek
padniętej sesji): [Przerwa techniczna z ostrzeżeniem](przerwa-techniczna.md).

!!! note "Sprzątanie Dockera po `make up` / `make run`"
    Po **udanym** starcie (`--wait` — wszystkie usługi zdrowe) `make up` (a więc i
    `make run`) uruchamia `docker system prune -af` i wypisuje tylko ile miejsca
    zwolniono (`Zwolniono na dysku: …`). Usuwa to nieużywane obrazy (w tym stare
    wersje obrazów BPP po aktualizacji), zatrzymane kontenery, niepodpięte sieci i
    cache builda. **Bez `--volumes`** — nazwane wolumeny z danymi (`postgresql_data`,
    `media`, `staticfiles`) są bezpieczne. Uwaga: `-af` usuwa **wszystkie** nieużywane
    obrazy na hoście, także spoza BPP — na maszynie współdzielonej z innymi projektami
    używaj `make up-quick` (nie sprząta). Opcjonalny serwis `html2docx` (gdy
    włączony profilem `COMPOSE_PROFILES=html2docx`) jest już **UP przed** prune,
    więc jego obraz jest w użyciu i prune go nie usunie.

## Baza danych

```bash
make migrate          # Migracje Django (bezpiecznie zatrzymuje workery denorm)
make db-backup        # Backup bazy (równoległy pg_dump, tar.gz)
make dbshell          # Django database shell
make dbshell-psql     # Bezpośredni psql
make upgrade-postgres # Upgrade major wersji PostgreSQL (np. 16.13 → 18.3)
```

Szczegóły: [Baza danych](baza-danych.md), [PostgreSQL](../konfiguracja/postgresql.md).

## Shell i konta

```bash
make shell              # Shell w appserverze
make shell-python       # Python shell (Django)
make shell-plus         # shell_plus (django-extensions)
make shell-dbserver     # Shell w kontenerze bazy
make shell-workerserver # Shell w workerze
make createsuperuser    # Utwórz superusera Django
make changepassword     # Zmień hasło użytkownika
```

## Monitoring i logi

```bash
make health           # Szybki healthcheck wszystkich usług
make ps               # Lista kontenerów
make logs             # Logi wszystkich usług
make logs-appserver   # Logi serwera aplikacji
make logs-celery      # Logi workerów Celery
make logs-dbserver    # Logi bazy
make logs-denorm      # Logi denormalizacji
make logs-netdata     # Logi Netdaty (metryki + alerty)
make celery-stats     # Statystyki zadań Celery
make celery-status    # Status workerów
make request-stats    # Szczytowy req/s per IP (admin/api/reszta) z logów nginx
```

`make request-stats` czyta access logi nginx-a (`docker logs` kontenera
`webserver`) i pokazuje, ile żądań na sekundę w piku robi każdy IP — rozbite na
`/admin/`, `/api/` i resztę. Służy do doboru limitów requestów bez zgadywania.
Knoby: `SINCE=24h TOP=30 make request-stats` (domyślnie `SINCE=72h`, `TOP=15`).

Szczegóły: [Monitoring i logi](../monitoring/przeglad.md),
[Rate limiting (nginx)](../architektura/rate-limiting.md).

## Diagnostyka powiadomień / usług

!!! note "Automatyczna bramka zdrowia po deployu"
    `make up` i `make run` kończą się **lekką, read-only bramką**
    (`scripts/post-deploy-check.sh`) sprawdzającą stan kontenerów
    (`unhealthy` / `restarting`). Gdy wszystko OK — wypisuje
    `✓ Wszystkie uslugi zdrowe.` i kończy kodem **0** (cicho). Gdy coś jest w złym
    stanie: w terminalu pyta `[s] shell · [d] make doctor · [dowolny klawisz]
    wyjście` (auto-wyjście po 30 s) i kończy kodem **≠ 0**; w trybie
    nieinteraktywnym (CI / cron / `make up | tee`) wypisuje problem i zwraca
    **≠ 0** bez pytania. Bramka **nie** wysyła maili/pushy/Rollbara — testy
    powiadomień zostają na żądanie (poniżej). Aby ją pominąć (np. własna
    automatyka wołająca `make up` pod `set -e`), ustaw `BPP_SKIP_HEALTH_GATE=1`
    w środowisku.

Deploy (`make run`) **nie** wysyła już automatycznie testowych maili ani nie testuje
Rollbara — diagnostykę uruchamiasz na żądanie. Najprościej przez interaktywne menu:

```bash
make doctor           # menu: mail / ntfy / rollbar / health / backup / wszystko
```

Pojedyncze testy (każdy robi dokładnie jedną rzecz) można też wywołać wprost:

```bash
make test-email       # Wyślij testowe e-maile (wymaga DJANGO_BPP_ADMIN_EMAIL)
make test-rollbar     # Wyślij testowe zdarzenie do Rollbara (wymaga ROLLBAR_ACCESS_TOKEN)
make test-ntfy        # Wyślij testowy push na ntfy (wymaga NTFY_TOPIC)
make ntfy-test        # Deprecated alias dla test-ntfy
```

W menu pozycja **wszystko** = mail + ntfy + rollbar po kolei (dawne zachowanie
po deployu, ale na żądanie). `health` i `backup` (pełny cykl: pg_dump + media +
rclone + powiadomienie Rollbar) to osobne pozycje menu.

## Celery / denormalizacja

```bash
make celery-stats         # Statystyki zadań
make denorm-rebuild       # Pełna przebudowa denormalizacji
make denorm-purge-queues  # Czyszczenie kolejek denorm
make denorm-flush         # Flush denorm
```

## Konfiguracja

```bash
make update-configs           # Regeneruj datasources.yaml z szablonu
make update-ssl-certs         # Przeładuj nginx po zmianie certyfikatów
make init-configs             # Uzupełnij brakujące pliki/zmienne (idempotentne)
make configure-resources      # Dostrój limity RAM/CPU
make generate-snakeoil-certs  # Wygeneruj samopodpisane certyfikaty SSL
make ssl-letsencrypt-issue    # Wystaw cert Let's Encrypt (PROD=1 dla prawdziwego)
make ssl-letsencrypt-renew    # Manualny renew certów LE
```

Szczegóły: [SSL](../konfiguracja/ssl.md), [Limity zasobów](../konfiguracja/limity-zasobow.md).

## Backup

```bash
make db-backup        # Pojedynczy pg_dump (równoległy, tar.gz)
make backup-cycle     # Pełen cykl: pg_dump + tar mediów + rclone copy + retencja zdalna
make rclone-config    # Konfiguracja zdalnego backupu (Google Drive, S3, ...)
make rclone-sync      # Wymuszona wysyłka do chmury (bez retencji — ta należy do cyklu nocnego)
make rclone-check     # Sprawdzenie spójności kopii zdalnej
```

Szczegóły: [Backup i rclone](backup-i-rclone.md).

## Konserwacja

```bash
make invalidate              # Wyczyść cache (cacheops + page cache), BEZ wylogowywania
make check-quic              # Sprawdź, czy UDP/443 (HTTP/3 QUIC) dochodzi z zewnątrz
make docker-clean            # Sprzątanie Dockera
make prune-orphan-volumes    # Usuń osierocone wolumeny
make open-docker-volume      # Otwórz wolumen do podglądu
make rmrf                    # Niebezpieczne, pyta o potwierdzenie
```

`make invalidate` woła się automatycznie na końcu `make up`; ręcznie przydaje się
po zmianie danych „obok" aplikacji. Czyści cache zapytań (`manage.py invalidate all`)
oraz **chirurgicznie** wyrenderowany page cache — po wzorcu klucza, nie
`FLUSHDB`. To celowe: page cache i **sesje** dzielą tę samą bazę Redisa, więc
flush całej bazy wylogowywałby wszystkich przy każdym deployu.

## Testy

```bash
make test-waf                # Czy WAF blokuje ataki i przepuszcza legalny ruch BPP
make test-alloy              # Czy pipeline logów nadaje poprawny poziom i pola modsec_*
make test-docker-versions    # Logika mapowania digest ↔ CalVer
make test-config-path        # Normalizacja ścieżki katalogu konfiguracyjnego
make test-grafana-datasources # Render datasources.yaml (działa bez gettexta)
make test-upgrade            # Próba generalna migracji na kopii produkcyjnej bazy
make test-deploy-with-warning # Sesja wdrożenia z ostrzeżeniem (mocki, bez Dockera)
```

`test-waf` i `test-alloy` **nie wymagają `.env`, działającej instalacji ani sieci
produkcyjnej** — stawiają własne kontenery i sprzątają po sobie. Kod wyjścia = liczba
niezgodności, więc nadają się do CI.

- **`make test-waf`** stawia atrapę backendu i webserver z *prawdziwą* konfiguracją
  z `defaults/webserver/`, po czym strzela baterią zapytań o znanym z góry wyniku.
  Payloady ataku to prawdziwe próby sqlmap z lipca 2026. Szczegóły:
  [WAF](../architektura/waf.md#sprawdzenie-czy-waf-dziala-make-test-waf).
- **`make test-config-path`** sprawdza `scripts/lib-config-path.sh` — czyli to, co
  `make init-configs` robi ze ścieżką podaną przez użytkownika: ścieżki windowsowe
  (`C:\dane\bpp`, także wklejone w cudzysłowach), tyldę, białe znaki i wykrywanie
  katalogu wewnątrz repozytorium. Windows symulowany atrapami `cygpath`/`uname`
  w `PATH`, więc test jest wiarygodny również na Linuksie i macOS. Bez sieci
  i Dockera, trwa ułamek sekundy.
- **`make test-grafana-datasources`** renderuje `datasources.yaml` z *prawdziwego*
  szablonu, mając **`envsubst` wycięty z `PATH`** — czyli w warunkach Windows, który
  nie ma gettexta. Sprawdza też, że hasła z metaznakami (`&`, `\`, `/`) przechodzą
  dosłownie i że pusty sekret `bpp_monitor` nadal jest odrzucany.
- **`make test-alloy`** przepuszcza *prawdziwy* `defaults/alloy/config.alloy` przez
  zestaw prawdziwych linii logu, podmieniając wyłącznie źródło (plik zamiast Dockera)
  i ujście (`loki.echo` zamiast zapisu do Loki). Sprawdza `detected_level` oraz pola
  `modsec_*`. `ALLOY_TEST_KEEP=1` zostawia kontener do obejrzenia.

!!! note "Na maszynie bez repo-owego `.env`"
    Bez pliku `.env` obok `docker-compose.yml` Makefile wchodzi w tryb pierwszego
    uruchomienia i wystawia **tylko** cel `setup` — `make test-alloy` zgłosi wtedy
    „No rule to make target". Skrypty można wołać wprost:
    `./scripts/test-alloy.sh`, `./scripts/test-waf.sh`.

## Wydanie i wersja

```bash
make release          # Tag + push: YYYY.MM.DD lub YYYY.MM.DD.N (calendar versioning)
make version          # Wyświetl bieżącą wersję
```

Szczegóły: [Wydanie](wydanie.md).

## Zarządzanie hostem

```bash
make base-host-update-upgrade  # Aktualizacja systemu (apt update + full-upgrade)
make base-host-reboot          # Restart hosta
make install-docker            # Instalacja Dockera na hoście
```

`make install-docker` rozpoznaje system samodzielnie:

- **Linux (Debian/Ubuntu)** — `docker-ce` z oficjalnego repozytorium apt Dockera;
  skrypt sam podbija uprawnienia przez `sudo`.
- **Windows (Git Bash)** — Docker Desktop przez
  `winget install -e --id Docker.DockerDesktop --source winget`. Gdy wingeta brak,
  komenda odsyła do [Instalatora aplikacji](https://apps.microsoft.com/detail/9nblggh4nns1?hl=pl-PL&gl=PL)
  ze Sklepu Microsoft. Po instalacji uruchom Docker Desktop z menu Start.

Inne dystrybucje Linuksa (Fedora, Arch, openSUSE) i macOS — patrz
[Instalacja](../instalacja/index.md).

## Aktualizacje i wersje obrazów

```bash
make zaspawaj-wersje          # Przypnij DOCKER_VERSION do wersji działającego appservera
make zaspawaj-wersje TAG=...  # Przypnij jawnie podaną wersję (tag CalVer)
make test-upgrade             # Próba generalna: migracje kandydata na kopii bazy
make test-upgrade TAG=...     # Próba generalna jawnie wskazanego kandydata
make test-upgrade-clean       # Sprzątnięcie shadow stacka po nieudanej próbie
make autoupdate               # Pętla: co ~2h sprawdź nowy obraz/commit → auto-deploy
make screen-with-autoupdate   # Odpal pętlę auto-update w tle, w sesji screen
make setup-autoupdate-cron    # Wpis cron pilnujący pętli (przeżywa reboot i crash sesji)
make remove-autoupdate-cron   # Usuń wpis cron auto-aktualizacji
make test-autoupdate-cron     # Unit-testy scripts/setup-autoupdate-cron.sh
```

Pełny opis przepływu bezpiecznej aktualizacji (pinowanie wersji, shadow stack,
rollback): [Aktualizacje i wersje obrazów](aktualizacje.md).
Nienadzorowana pętla auto-update (`make autoupdate` pod `screen`):
[Automatyczna aktualizacja](aktualizacje.md#automatyczna-aktualizacja-make-autoupdate).
Strażnik pilnujący, żeby pętla żyła:
[Strażnik w cronie](aktualizacje.md#straznik-w-cronie-make-setup-autoupdate-cron).

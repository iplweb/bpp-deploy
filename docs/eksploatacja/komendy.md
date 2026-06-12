# Najważniejsze komendy

```bash
make help             # Pełna lista wszystkich targetów Make (źródło prawdy)
```

`make help` jest źródłem prawdy — poniżej tematyczny przegląd najważniejszych targetów.

## Wdrożenie

```bash
make run                # Pełne wdrożenie (pull, build, configs, up)
make up                 # Start wszystkich usług (force recreate)
make up-quick           # Szybki start bez recreation
make refresh            # prune + pull + recreate (po update obrazu)
make wait               # Czeka na build z GH Actions, potem make refresh
make stop               # Zatrzymaj usługi
make restart-appserver  # Restart serwera aplikacji
```

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
make ntfy-test        # Wyślij testowy push na ntfy (alerty na telefon)
```

Szczegóły: [Monitoring i logi](../monitoring/przeglad.md).

## Celery / denormalizacja

```bash
make celery-stats         # Statystyki zadań
make denorm-rebuild       # Pełna przebudowa denormalizacji
make denorm-purge-queues  # Czyszczenie kolejek denorm
make denorm-flush         # Flush denorm
```

## Konfiguracja

```bash
make update-configs           # Regeneruj datasources.yaml (envsubst)
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
make backup-cycle     # Pełen cykl: pg_dump + tar mediów + rclone + powiadomienia
make rclone-config    # Konfiguracja zdalnego backupu (Google Drive, S3, ...)
make rclone-sync      # Wymuszona synchronizacja z chmurą
make rclone-check     # Sprawdzenie spójności kopii zdalnej
```

Szczegóły: [Backup i rclone](backup-i-rclone.md).

## Konserwacja

```bash
make docker-clean            # Sprzątanie Dockera
make prune-orphan-volumes    # Usuń osierocone wolumeny
make open-docker-volume      # Otwórz wolumen do podglądu
make rmrf                    # Niebezpieczne, pyta o potwierdzenie
```

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

## Aktualizacje i wersje obrazów

```bash
make zaspawaj-wersje          # Przypnij DOCKER_VERSION do wersji działającego appservera
make zaspawaj-wersje TAG=...  # Przypnij jawnie podaną wersję (tag CalVer)
make test-upgrade             # Próba generalna: migracje kandydata na kopii bazy
make test-upgrade TAG=...     # Próba generalna jawnie wskazanego kandydata
make test-upgrade-clean       # Sprzątnięcie shadow stacka po nieudanej próbie
```

Pełny opis przepływu bezpiecznej aktualizacji (pinowanie wersji, shadow stack,
rollback): [Aktualizacje i wersje obrazów](aktualizacje.md).

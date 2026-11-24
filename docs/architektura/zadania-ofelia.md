# Zadania okresowe (Ofelia)

Ofelia to cron dla Dockera — harmonogram żyje w labelach kontenerów w plikach Compose
(głównie `docker-compose.application.yml`), więc nie trzeba nic przepisywać przy
[przenosinach serwera](../eksploatacja/przenosiny-serwera.md).

Wszystkie godziny na tej stronie są w strefie [`BPP_CRON_TZ`](#strefa-czasowa)
(domyślnie czas polski).

## Konserwacja

| Czas | Zadanie |
|---|---|
| 22:00 | denorm rebuild |
| 01:30 | sitemap |
| 01:45 | [backup](../eksploatacja/backup-i-rclone.md) (job-exec na `backup-runner` — orkiestratorze, który deleguje ciężkie kroki przez `docker exec`; [wyłączalny](../eksploatacja/backup-i-rclone.md#wylaczenie-backupu) przez `DJANGO_BPP_BACKUP_ENABLED=0`) |
| 03:30 | rebuild_kolejnosc |
| 04:00 | [Let's Encrypt renew](../konfiguracja/ssl.md#codzienny-renew) (job-run certbot) |
| 04:05 | LE reload (job-exec nginx, jeśli sentinel) |
| 04:10 | [rotacja nginx access logu](../monitoring/logowanie.md#nginx-access-log-dwa-cele-jednoczesnie) |
| 04:30 | rebuild_autor_jednostka |
| sob. 21:30 | PBN sync |

## Nocne restarty (mitygacja wycieków pamięci)

Długo żyjące procesy Pythona (gunicorn, Celery) puchną niezależnie od limitów — realny
memory leak, nie burst. Staggered restart **05:00–05:25** (po backupie 01:45 i rebuildzie
04:30, przed godzinami pracy):

| Czas | Serwis |
|---|---|
| 05:00 | appserver |
| 05:05 | workerserver |
| 05:15 | flower |
| 05:20 | celerybeat |
| 05:25 | denorm-queue |

### Mechanizm

`ofelia.job-exec.restart_self.command: "kill 1"` — Ofelia exec-uje `kill 1` przez
`docker.sock` (ro), PID 1 dostaje SIGTERM, graceful shutdown, `restart: always`
wskrzesza. Żadnych nowych serwisów, socket zostaje read-only.

**Wyjątek: `denorm-queue` dostaje `kill -INT 1` (SIGINT).** PID 1 w kontenerze
ignoruje każdy sygnał, dla którego proces nie zainstalował handlera, a PID 1 w
`denorm-queue` to goły `python src/manage.py denorm_queue` — obsługuje tylko SIGINT
(Pythonowy `KeyboardInterrupt`). Zwykły `kill 1` był więc no-opem: kontener nigdy się
nie restartował (`StartedAt` bez zmian dzień po dniu). Z SIGINT proces kończy się
czysto w < 1 s, a `restart: always` go podnosi. Ten sam powód stoi za
`stop_signal: SIGINT` tego serwisu (szybkie `docker stop`).

Pozostałe serwisy obsługują SIGTERM (sprawdzone maską `SigCgt` w `/proc/1/status`
i żywym `docker exec … kill 1`), więc zostają przy `kill 1`:

| Serwis | PID 1 | SIGTERM |
|---|---|---|
| appserver | `gunicorn` (entrypoint robi `exec`) | graceful shutdown workerów |
| workerserver | `celery worker` | warm shutdown |
| celerybeat | `celery beat` | zapis harmonogramu i wyjście |
| flower | `celery flower` | wyjście |
| denorm-queue | `python manage.py denorm_queue` | **ignorowany** → `kill -INT 1` |

!!! tip "Jak sprawdzić, czy nocny restart naprawdę zaszedł"
    `docker inspect -f '{{.State.StartedAt}}' <kontener>` — po 05:25 czasu
    `BPP_CRON_TZ` każdy z pięciu kontenerów powinien mieć dzisiejszą datę startu.

!!! note "Wyłączenie dla serwisu"
    Zakomentuj labele `ofelia.job-exec.restart_self.*` w odpowiednim pliku Compose.
    Brak przełącznika env-var — restart jest gwarancją, nie opcją.

## Strefa czasowa

Ofelia liczy harmonogramy w strefie ze zmiennej **`BPP_CRON_TZ`** (domyślnie
`Europe/Warsaw`), ustawianej **tylko** w kontenerze `ofelia` — pozostałe kontenery
zostają w UTC. Do listopada 2026 Ofelia chodziła w UTC, więc wszystko startowało
o 1–2 h później, a nocne restarty wypadały latem o 7:00 czasu polskiego.

Zmiana strefy (wpis w `$BPP_CONFIGS_DIR/.env`) wchodzi w życie po `make up` —
kontener `ofelia` musi zostać odtworzony. Powrót do starego zachowania:
`BPP_CRON_TZ=UTC`.

!!! warning "Żadnych jobów między 02:00 a 03:00"
    W strefie z czasem letnim ta godzina w ostatnią niedzielę marca **nie istnieje**,
    a w ostatnią niedzielę października **występuje dwa razy** — job zaplanowany na ten
    czas raz w roku wypadnie albo pójdzie podwójnie. Dlatego backup jest o 01:45, nie
    o 02:30.

# Zadania okresowe (Ofelia)

Ofelia to cron dla Dockera — harmonogram żyje w labelach kontenerów w plikach Compose
(głównie `docker-compose.application.yml`), więc nie trzeba nic przepisywać przy
[przenosinach serwera](../eksploatacja/przenosiny-serwera.md).

## Konserwacja

| Czas | Zadanie |
|---|---|
| 22:00 | denorm rebuild |
| 01:30 | sitemap |
| 02:30 | [backup](../eksploatacja/backup-i-rclone.md) (`backup-runner`) |
| 03:30 | rebuild_kolejnosc |
| 04:00 | [Let's Encrypt renew](../konfiguracja/ssl.md#codzienny-renew) (job-run certbot) |
| 04:05 | LE reload (job-exec nginx, jeśli sentinel) |
| 04:10 | [rotacja nginx access logu](../monitoring/logowanie.md#nginx-access-log-dwa-cele-jednoczesnie) |
| 04:30 | rebuild_autor_jednostka |
| sob. 21:30 | PBN sync |

## Nocne restarty (mitygacja wycieków pamięci)

Długo żyjące procesy Pythona (gunicorn, Celery) puchną niezależnie od limitów — realny
memory leak, nie burst. Staggered restart **05:00–05:25** (po backupie 02:30 i rebuildzie
04:30, przed godzinami pracy):

| Czas | Serwis |
|---|---|
| 05:00 | appserver |
| 05:05 | workerserver-general |
| 05:10 | workerserver-denorm |
| 05:15 | flower |
| 05:20 | celerybeat |
| 05:25 | denorm-queue |

### Mechanizm

`ofelia.job-exec.restart_self.command: "kill 1"` — Ofelia exec-uje `kill 1` przez
`docker.sock` (ro), PID 1 dostaje SIGTERM, graceful shutdown, `restart: always`
wskrzesza. Żadnych nowych serwisów, socket zostaje read-only.

!!! note "Wyłączenie dla serwisu"
    Zakomentuj labele `ofelia.job-exec.restart_self.*` w odpowiednim pliku Compose.
    Brak przełącznika env-var — restart jest gwarancją, nie opcją.

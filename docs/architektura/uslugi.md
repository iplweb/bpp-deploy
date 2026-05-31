# Usługi i przepływ danych

## Usługi

### Core

| Usługa | Opis |
|---|---|
| **appserver** | Serwer aplikacji Django + migracje |
| **authserver** | Django auth proxy dla nginx — bez migracji/collectstatic, startuje w sekundy |
| **dbserver** | PostgreSQL + denormalizacja |
| **webserver** | Nginx (reverse proxy + static files) |
| **redis** | Cache, broker Celery i result backend |

### Workery

| Usługa | Opis |
|---|---|
| **workerserver-general** | Ogólne zadania Celery (queue: `celery`) |
| **workerserver-denorm** | Zadania denormalizacji (queue: `denorm`) |
| **celerybeat** | Harmonogram zadań okresowych (`service_started`, nie `_healthy` — szybszy start) |
| **denorm-queue** | Bridge PostgreSQL `LISTEN` → Celery |
| **flower** | UI monitorowania Celery (port 5555, path `/flower`) |

!!! danger "denorm-queue — pojedyncza instancja"
    `denorm-queue` **musi** działać jako **jedna instancja**, żeby uniknąć podwójnego
    przetwarzania wiadomości. **Nie skaluj.**

### Monitoring

| Usługa | Opis |
|---|---|
| **netdata** | Metryki hosta/kontenerów/PostgreSQL, 1s, alerty push na ntfy.sh (`/netdata/`) |
| **loki** + **alloy** | Zbieranie i retencja logów per service |
| **grafana** | Frontend do Loki/LogQL + dashboardy (`/grafana/`) |
| **dozzle** | Live tail logów kontenerów (`/dozzle/`) |

### Support

| Usługa | Opis |
|---|---|
| **ofelia** | Cron dla Dockera ([zadania okresowe](zadania-ofelia.md)) |
| **autoheal** | Sidecar restartujący niezdrowe kontenery ([healthchecks](healthchecks-autoheal.md)) |
| **backup-runner** | Codzienny `pg_dump` + tar media + rclone + Rollbar (`postgres:<major>-alpine`; Ofelia `0 30 2 * * *`; manual: `make backup-cycle`) |

### Profil `manual`

`workerserver-status` (`profiles: ['manual']`, nie startuje automatycznie) —
`docker compose run --rm workerserver-status`.

## Przepływ danych

- **Web**: nginx → Django.
- **Zadania w tle**: Django → Celery.
- **Zmiany w bazie**: triggery PG → `LISTEN` → `denorm-queue` → Celery.
- **Static**: nginx serwuje wspólny wolumen.
- **Cron**: Ofelia → komendy zarządzające Django.
- **Logi**: kontenery → Alloy → Loki → Grafana.
- **Metryki**: kontenery + host + PostgreSQL + nginx → Netdata (1s, lokalne UI + alerty);
  push na ntfy.sh przy alertach.
- **Auth**: nginx → authserver → proxy do Grafany/Dozzle.

## Zależności startu

- `appserver` startuje przed workerami (obsługuje migracje); workery zależą od
  `appserver` healthy (tranzytywnie `dbserver`).
- `denorm-queue` wymaga `workerserver-denorm` healthy.
- `celerybeat` używa `service_started` (nie `_healthy`) dla `appserver` — szybszy start.

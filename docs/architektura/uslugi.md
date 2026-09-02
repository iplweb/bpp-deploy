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
| **workerserver** | Jeden worker Celery obsługujący **obie** kolejki: `celery` (ogólne + długie joby) oraz `denorm` (denormalizacja) |
| **celerybeat** | Harmonogram zadań okresowych (`service_started`, nie `_healthy` — szybszy start) |
| **denorm-queue** | Bridge PostgreSQL `LISTEN` → Celery |
| **flower** | UI monitorowania Celery (port 5555, path `/flower`) |

!!! info "Jeden worker, dwie kolejki"
    Do czerwca 2026 były dwa osobne kontenery (`workerserver-general` +
    `workerserver-denorm`). Każdy forkował tyle procesów prefork ile rdzeni hosta,
    więc zżerały ~2× pełna kopia Django. Konsolidacja do **jednego**
    `workerserver` (`-Q celery,denorm`) oszczędza jedną kopię Django i połowę
    procesów-dzieci. Zadania kolejki `denorm` (`flush_single`) są krótkie, więc
    spokojnie współdzielą worker z kolejką domyślną.

    **Bez ścisłego priorytetu** — kombu robi round-robin po kolejkach (świadoma
    decyzja: zadania denorm są krótkie, nie blokują interaktywnych na długo). Liczba
    procesów-dzieci (concurrency, domyślnie **75% rdzeni**) i recykling pod kątem
    pamięci konfigurują się przez zmienne `CELERY_WORKER_*` czytane przez obraz BPP —
    patrz [Limity zasobów](../konfiguracja/limity-zasobow.md#concurrency-celery).

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
| **backup-runner** | **Orkiestrator** codziennego cyklu backupu (obraz `docker:28-cli`, bezczynny `sleep infinity`). Sam robi tylko sekwencję i tar; `pg_dump` wykonuje przez `docker exec` w `dbserver`, wysyłkę w serwisie `rclone`, notyfikację Rollbara przez `appserver`. Ofelia `0 30 2 * * *`; manual: `make backup-cycle`. Szczegóły: [Backup i rclone](../eksploatacja/backup-i-rclone.md#codzienny-backup) |
| **rclone** | Zadeklarowany, stale działający serwis z rclone (obraz `rclone/rclone`, bezczynny `sleep infinity`) — wykonuje `rclone copy` i retencję zdalną cyklu nocnego oraz targety `make rclone-config/-sync/-check`. Jako serwis (a nie `docker run --rm`), bo compose ściąga obrazy tylko zadeklarowanych serwisów, a `docker system prune -af` na końcu `make up` kasowałby obraz bez działającego kontenera. [Szczegóły](../eksploatacja/backup-i-rclone.md#serwis-rclone) |

### Usługi za profilem (nie startują z `make up`)

Compose'owe `profiles:` trzymają te usługi poza domyślnym `docker compose up`:

| Usługa | Profil | Kiedy działa |
|---|---|---|
| **workerserver-status** | `manual` | Na żądanie: `docker compose run --rm workerserver-status` |
| **certbot** | `letsencrypt` | Na żądanie z `make ssl-letsencrypt-issue` / `-renew` oraz z codziennego joba Ofelii ([SSL](../konfiguracja/ssl.md)) |
| **html2docx** | `html2docx` | Opcjonalny sidecar HTTP fallbacku konwersji HTML→DOCX (gdy pandoc z obrazu appservera zawiedzie) — opt-in, patrz [Architektura konfiguracji](../konfiguracja/architektura.md#fallback-htmldocx-opcjonalny-sidecar-html2docx) |

## Przepływ danych

- **Web**: nginx → Django.
- **Zadania w tle**: Django → Celery.
- **Zmiany w bazie**: triggery PG → `LISTEN` → `denorm-queue` → Celery.
- **Static**: nginx serwuje wspólny wolumen.
- **Cron**: Ofelia → komendy zarządzające Django.
- **Backup**: Ofelia → `backup-runner` (orkiestrator) → `docker exec`: `pg_dump`
  w `dbserver`, `rclone copy` w serwisie `rclone`, notyfikacja przez `appserver`.
- **Logi**: kontenery → Alloy → Loki → Grafana.
- **Metryki**: kontenery + host + PostgreSQL + nginx → Netdata (1s, lokalne UI + alerty);
  push na ntfy.sh przy alertach.
- **Auth**: nginx → authserver → proxy do Grafany/Dozzle.

## Zależności startu

- `appserver` startuje przed workerami (obsługuje migracje); workery zależą od
  `appserver` healthy (tranzytywnie `dbserver`).
- `denorm-queue` wymaga `workerserver` healthy.
- `celerybeat` używa `service_started` (nie `_healthy`) dla `appserver` — szybszy start.

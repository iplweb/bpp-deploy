# Healthchecks i autoheal

## Healthchecki

### Compose-level

- `authserver` — HTTP `/health/`
- `redis` — `redis-cli ping`
- `grafana` — HTTP `/api/health`

### Image-level (Dockerfile `HEALTHCHECK`)

- `dbserver` — `pg_isready`
- `appserver` — HTTP
- `workerserver` — `celery inspect ping` via Redis broker
  (flapuje, gdy połączenie z brokerem się zrywa)
- `denorm-queue` — `pgrep -f denorm_queue`

!!! note "Escaping podwójnego dolara"
    Podwójne `$$` (np. `$$DJANGO_BPP_DB_USER`) w komendach healthcheck zapobiega
    przedwczesnej ekspansji zmiennej przez Compose.

## Autoheal — reaktywny restart niezdrowych kontenerów

Docker **nie** restartuje kontenerów na podstawie nieudanego healthchecku (`restart: always`
reaguje tylko na wyjście procesu). Sidecar `willfarrell/autoheal:1.2.0` (w
`application.yml`) monitoruje kontenery z labelem `autoheal=true` przez Docker API i
restartuje je przy `Health.Status=unhealthy`.

Obecnie obserwowane: `workerserver`.

Bez tego utknięty worker Celery (zerwane połączenie z brokerem, pętla reconnect kombu)
zostałby `unhealthy` na zawsze, bo proces wciąż żyje.

!!! warning "`denorm-queue` nie jest objęty autoheal"
    `denorm-queue` **nie** ma labela `autoheal=true`: jego healthcheck na poziomie
    Compose jest zakomentowany, więc kontener nie raportuje statusu zdrowia, na który
    autoheal mógłby zareagować. Odzyskiwanie opiera się na nocnym, rozłożonym w czasie
    restarcie (`kill 1` przez Ofelię o 05:25). Jeśli most PG `LISTEN` → Celery
    utknie w ciągu dnia, denormalizacja stoi do najbliższego nocnego restartu —
    warto to mieć na uwadze przy diagnostyce opóźnień w przeliczaniu.

# Healthchecks i autoheal

## Healthchecki

### Compose-level

- `authserver` — HTTP `/health/`
- `redis` — `redis-cli ping`
- `grafana` — HTTP `/api/health`
- `celerybeat` — świeżość pliku-heartbeatu `/tmp/celerybeat-heartbeat`
  (`HeartbeatScheduler` dotyka go co tick); sonda tylko sprawdza `mtime` — bez
  importu Django i bez sprawdzania redisa (redis ma własny healthcheck). `test:`
  to **dyspozytor**: `healthcheck_beat.py` gdy obraz go ma (czerwiec 2026+),
  inaczej fallback na starą `healthcheck_broker.py` (cold-import + broker connect)
  dla wstecznej zgodności z pinowanym starym obrazem. Wcześniej sama broker-sonda
  pod niskim capem CPU trwała 4–10 s i wydłużała start celerybeat do ~218 s.

### Image-level (Dockerfile `HEALTHCHECK`)

- `dbserver` — `pg_isready`
- `appserver` — HTTP
- `workerserver` — `celery inspect ping` via Redis broker
  (flapuje, gdy połączenie z brokerem się zrywa)
- `celerybeat` — `healthcheck_beat.py` (świeżość heartbeatu); nadpisywany przez
  `test:` na poziomie Compose (patrz wyżej)
- `denorm-queue` — `pgrep -f denorm_queue`

!!! note "Escaping podwójnego dolara"
    Podwójne `$$` (np. `$$DJANGO_BPP_DB_USER`) w komendach healthcheck zapobiega
    przedwczesnej ekspansji zmiennej przez Compose.

## Autoheal — reaktywny restart niezdrowych kontenerów

Docker **nie** restartuje kontenerów na podstawie nieudanego healthchecku (`restart: always`
reaguje tylko na wyjście procesu). Sidecar `willfarrell/autoheal:1.2.0` (w
`application.yml`) monitoruje kontenery z labelem `autoheal=true` przez Docker API i
restartuje je przy `Health.Status=unhealthy`.

Obecnie obserwowane: `workerserver`, `celerybeat`.

Bez tego utknięty worker Celery (zerwane połączenie z brokerem, pętla reconnect kombu)
zostałby `unhealthy` na zawsze, bo proces wciąż żyje. Analogicznie `celerybeat`:
gdy beat żyje, ale przestaje tykać, heartbeat się starzeje → `unhealthy` → autoheal
restartuje (a nocny `kill 1` o 05:20 i tak go cyklicznie odświeża).

!!! warning "`denorm-queue` nie jest objęty autoheal"
    `denorm-queue` **nie** ma labela `autoheal=true`: jego healthcheck na poziomie
    Compose jest zakomentowany, więc kontener nie raportuje statusu zdrowia, na który
    autoheal mógłby zareagować. Odzyskiwanie opiera się na nocnym, rozłożonym w czasie
    restarcie (`kill 1` przez Ofelię o 05:25). Jeśli most PG `LISTEN` → Celery
    utknie w ciągu dnia, denormalizacja stoi do najbliższego nocnego restartu —
    warto to mieć na uwadze przy diagnostyce opóźnień w przeliczaniu.

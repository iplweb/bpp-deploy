# Netdata i alerty ntfy

Netdata zbiera metryki hosta, kontenerów Dockera, PostgreSQL i nginx w rozdzielczości 1s,
ma setki gotowych reguł health i wysyła push na telefon przez publiczny ntfy.sh.

## Retencja (tiered storage)

Ostatnie godziny w 1s, dni w 1m, tygodnie/miesiące w 1h — w wolumenie `netdata_lib`
(~512MB sufit per `dbengine tier 0 retention size` w `netdata.conf`).

Config `${BPP_CONFIGS_DIR}/netdata/netdata.conf` jest **renderowany z
`defaults/netdata/netdata.conf.tpl` i force-syncowany** (patrz
[Architektura konfiguracji](../konfiguracja/architektura.md#netdataconf-renderowany-host-side)).

!!! warning "Nie edytuj `netdata.conf` ręcznie"
    Strój przez `.env`:

    - `NETDATA_DBENGINE_TIER0_RETENTION_MB` — rozmiar retencji tier 0
    - `NETDATA_DBENGINE_PAGE_CACHE_MB` — cache stron
    - `NETDATA_DOCKER_UPDATE_EVERY` — interwał kolektora go.d `docker` w sekundach (domyślnie 30; plik `go.d/docker.conf` też jest force-syncowany)

## Przycisk „View node" w ntfy

`[registry]` jest włączony, a `registry to announce` wskazuje `https://<host>/netdata`,
żeby przycisk **„View node"** w powiadomieniu ntfy przekierowywał do lokalnej Netdaty
zamiast `registry.my-netdata.io`. Wymaga jednorazowej wizyty na dashboardzie z danej
przeglądarki — rejestr zapisuje wtedy URL per cookie.

## Alerty

- Wbudowane reguły health w agencie (setki gotowych defaultów).
- Custom alerty w `${BPP_CONFIGS_DIR}/netdata/health.d/`.
- Push przez `health_alarm_notify.conf` (sourced jako bash, kanał ntfy z
  `${NTFY_SERVER}/${NTFY_TOPIC}`).

### Wyłączone wbudowane alerty

Kilka wbudowanych reguł na instalacjach BPP generowało dziesiątki powiadomień dziennie,
na które nie dało się nic zrobić. Są wyłączone w sekcji `[health]` (`enabled alarms`)
w `netdata.conf` — plik jest renderowany i force-syncowany z `netdata.conf.tpl`, więc
zmiana dociera na instalację przez `git pull && make up`:

| Reguła | Dlaczego wyłączona |
|---|---|
| `web_log_web_slow` | porównuje średnią z 1 min z dwukrotnością średniej z 10 min — raporty, eksporty i crawlery przełączają ją co chwilę |
| `web_log_1m_redirects`, `web_log_1m_successful` | udziały 3xx / „udanych" odpowiedzi zależą głównie od botów (przekierowania na logowanie, 4xx, blokady WAF); awarię aplikacji pokazuje `web_log_1m_internal_errors` (5xx), który zostaje |
| `postgres_table_cache_io_ratio` | cache hit pojedynczej tabeli — niski po każdym restarcie bazy (zimny cache) |

W miejsce `web_log_web_slow` jest `bpp_web_log_slow` (`health.d/bpp_web_log.conf`):
średni czas odpowiedzi z **5 minut** powyżej **3 s** (ostrzeżenie) / **10 s** (krytyczny),
liczony tylko przy ruchu powyżej 30 zapytań na minutę. Plik jest kopiowany tylko, gdy go
brakuje (`copy_if_missing`), więc progi można dostroić lokalnie.

### Alerty na komórkę

Netdata wysyła push na publiczny ntfy.sh. Topic (sekret) jest generowany losowo przy
`make init-configs`, przechowywany jako `NTFY_TOPIC` w `${BPP_CONFIGS_DIR}/.env`.
Subskrybuj w aplikacji ntfy: `https://ntfy.sh/<NTFY_TOPIC>`. Test:

```bash
make test-ntfy        # (dawniej make ntfy-test — alias nadal działa)
```

## Kolektory `go.d`

W `${BPP_CONFIGS_DIR}/netdata/go.d/` (nadpisują wbudowane defaulty mountem RO):

| Plik | Co zbiera |
|---|---|
| `postgres.conf` | metryki PostgreSQL (DSN z `.env`; internal i external mode) |
| `nginx.conf` | live metryki połączeń z endpointu `stub_status` (osobny `server { listen 8090; }` w `default.conf.template`; port **nie** publikowany — osiągalny tylko w sieci Dockera: `netdata → webserver:8090`) |
| `web_log.conf` | metryki z parsowania access logu nginx (kody HTTP, metody, bandwidth, percentyle czasów) → wbudowane alerty na 5xx/latencje. Źródło: `/var/log/nginx-shared/bpp_access.log` |
| `docker.conf` | liczniki kontenerów (stany, health) i obrazów przez Docker API (socket RO). **Renderowany i force-syncowany** z `docker.conf.tpl`, interwał **30 s** — na Dockerze 29+ z magazynem obrazów containerd każde zbieranie kosztuje ~1 s CPU w `dockerd` i `containerd`; przy dawnych 3 s oba demony stały na ~35% rdzenia. Tuning: `NETDATA_DOCKER_UPDATE_EVERY` w `.env`, nie w pliku ([szczegóły](../konfiguracja/architektura.md#netdatagoddockerconf-renderowany-host-side)) |

`web_log` **nie** dubluje Loki — Loki trzyma surowe linie do przeszukiwania, `web_log`
liczy metryki @1s i alertuje na ntfy.

## Dedykowany użytkownik monitoringu PostgreSQL

W trybie internal dbserver po wdrożeniu uruchom raz:

```bash
make create-monitoring-user
```

Tworzy read-only rolę `bpp_monitor` używaną przez kolektor `go.d/postgres` i datasource
Grafany (zamiast superusera aplikacji).

## CLI

```bash
make logs-netdata     # logi Netdaty
make netdata-shell    # shell w kontenerze netdata
make test-ntfy        # test pushu (alias: make ntfy-test)
```

# Logowanie

**Zmniejszona gadatliwość**: Loki/Grafana/Alloy ustawione na `warn` lub `error`.

## Docker log driver — rotacja lokalna

Wszystkie usługi używają drivera `local` (binarny protobuf, mniejszy niż `json-file`)
przez wspólny YAML anchor `x-logging` na górze każdego pliku Compose. Kompresja (gzip)
dotyczy **tylko zrotowanych plików** — aktywny plik jest nieskompresowany, więc tailowanie
pokazuje czytelny tekst między markerami ramek.

```yaml
x-logging: &default-logging
  driver: "local"
  options:
    max-size: "${LOG_MAX_SIZE:-150m}"
    max-file: "${LOG_MAX_FILE:-5}"
```

!!! warning "Anchory nie przekraczają granic `include:`"
    YAML anchory **nie** przechodzą między plikami `include:` — każdy z 7 plików Compose
    ma własną definicję `x-logging`. To celowe: zero edycji `daemon.json`, wszystko
    wersjonowane. **Dodając nowy serwis: dołącz `logging: *default-logging`, inaczej
    spadnie do nierotowanego `json-file`.**

Defaulty: 150m × 5 = 750MB per kontener (~3–4GB sufit dla ~20 kontenerów, zmniejszone
przez gzip na segmentach) — to bufor zanim Alloy wyśle logi do Loki, nie retencja czasowa.

## Loki — retencja czasowa per service

Konfigurowana w `defaults/loki/local-config.yaml` przez `limits_config.retention_stream`
po labelu `service` (ustawianym przez Alloy z `com.docker.compose.service`):

| Service | Retencja | Po co |
|---|---|---|
| `appserver` | 90 d | logi Django do debugowania incydentów |
| `dbserver` | 90 d | slow queries, locki |
| `webserver` | 180 d | access log nginx, compliance/ruch |
| (default) | 30 d | workery, infrastruktura, monitoring |

Strojenie: edytuj `$BPP_CONFIGS_DIR/loki/local-config.yaml` + `docker compose restart loki`.
Selektory: `{service="<nazwa-serwisu-compose>"}`.

## nginx access log — dwa cele jednocześnie

Główny ruch loguje się w formacie `bpp_access` (`defaults/webserver/00-log-format.conf`:
combined + `$request_length`/`$request_time`/`$upstream_response_time`) z
`vhost.conf.template` do **dwóch** sinków:

- `access_log /dev/stdout bpp_access;` → Docker → Alloy → Loki → Grafana
  (`{service="webserver"}`, search/forensics).
- `access_log /var/log/nginx-shared/bpp_access.log bpp_access;` → wolumen `nginx_access_log`
  (RO w Netdacie) → kolektor `web_log` (metryki + alerty).

Szumne locationy (`/healthz`, `/static`, `/media`, acme, security-blocks) mają własne
`access_log off` w `_bpp-locations.conf` i nadpisują oba sinki. Plik na wolumenie rotuje
Ofelia codziennie **04:10** (`scripts/nginx-access-log-rotate.sh`: `mv` na `.1` +
`nginx -s reopen`, max 2 generacje) — Docker log driver rotuje tylko stdout/stderr,
nie ten plik.

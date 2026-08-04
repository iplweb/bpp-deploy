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

## Poziom logu (`detected_level`)

Loki nie dostaje poziomu logu z kontenerów — trzeba go **wywnioskować z treści linii**.
Robi to `defaults/alloy/config.alloy` i wstawia wynik jako label `detected_level`.

Dozwolone wartości to **zamknięty zbiór siedmiu**:

| Wartość | Skąd |
|---|---|
| `critical` | `critical`, `crit`, `fatal`, `alert`, `emerg` |
| `error` | `error`, `err` |
| `warn` | `warn`, `warning` i wszystko kończące się na `Warning` (`SecurityWarning`, `DeprecationWarning`…) — **oraz każde trafienie WAF-a** |
| `info` | `info`, `notice` |
| `debug` | `debug` |
| `trace` | `trace` |
| `unknown` | nic nie pasowało |

Zbiór jest zamknięty celowo: normalizacja jest **jedną bramką** na końcu pipeline'u,
a nie łańcuchem poprawek. Wartość spoza tabeli nie ma jak trafić na label.

!!! warning "Jedno źródło — wbudowane wykrywanie w Loki jest wyłączone"
    Loki 3.x ma własne `discover_log_levels` (domyślnie **włączone**), które dokleja
    `detected_level` jako structured metadata ze swoim słownikiem
    (`trace/debug/info/warn/error/fatal/critical`). Przy dwóch detektorach pod tą samą
    nazwą dropdown „Log Level" w Grafanie pokazywał **sumę obu słowników** — równolegle
    `warn` i `warning`, do tego `fatal` i przeciekłe `securitywarning` — a w szczegółach
    linii pojawiał się `detected_level_extracted` (Loki dokleja ten sufiks przy kolizji
    stream labela ze structured metadata).

    Wyłącza to flaga `-validation.discover-log-levels=false` w `command:` usługi `loki`
    w `docker-compose.monitoring.yml`. **Flagą, a nie kluczem w `local-config.yaml`** —
    ten plik jest `copy_if_missing` (patrz wyżej: operator stroi w nim retencję), więc
    zmiana w nim nigdy nie dotarłaby na istniejącą instalację. Compose jest wersjonowany,
    więc `git pull && make up` wystarcza.

Stare dane zachowują poprzednie wartości aż do wygaśnięcia retencji — dropdown czyści
się stopniowo, po 30 dniach dla większości usług i po 180 dla `webserver`. To normalne,
nie wymaga kasowania danych.

!!! note "`service_name` obok `service`"
    Bliźniacza funkcja Loki `discover_service_name` dokleja label `service_name`,
    duplikujący nasz `service`. **Zostaje włączona**: analogiczna flaga jej nie wyłącza
    (`-validation.discover-service-name=` dopisuje pusty wpis do listy domyślnej,
    zamiast ją czyścić), a wyłączenie przez YAML zadziałałoby tylko na świeżych
    instalacjach. To kosmetyczny duplikat — używaj `service`.

Weryfikacja pipeline'u: [`make test-alloy`](../eksploatacja/komendy.md#testy).

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

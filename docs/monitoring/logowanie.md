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

Konfigurowana przez `limits_config.retention_stream` po labelu `service` (ustawianym
przez Alloy z `com.docker.compose.service`):

| Service | Zmienna w `.env` | Domyślnie | Po co |
|---|---|---|---|
| `appserver` | `LOKI_RETENTION_APPSERVER` | `2160h` (90 d) | logi Django do debugowania incydentów |
| `dbserver` | `LOKI_RETENTION_DBSERVER` | `2160h` (90 d) | slow queries, locki |
| `webserver` | `LOKI_RETENTION_WEBSERVER` | `4320h` (180 d) | access log nginx, compliance/ruch |
| (default) | `LOKI_RETENTION_DEFAULT` | `720h` (30 d) | workery, infrastruktura, monitoring |

**Strój przez `.env`, nie przez plik.** `$BPP_CONFIGS_DIR/loki/local-config.yaml` jest
**renderowany i nadpisywany przy każdym `make up`** — ręczna zmiana w nim przepadnie
przy najbliższym `git pull`. Poprawnie:

```bash
# w $BPP_CONFIGS_DIR/.env
LOKI_RETENTION_WEBSERVER=8760h   # rok

make up     # renderuje config i przeładowuje Loki
```

Format wartości to `<liczba><jednostka>` (`h`, `d`, `m`, `s`) — dokładnie to, co
przyjmuje Loki. Wartość w innym formacie jest **ignorowana** i podmieniana na
domyślną z repo: Loki z niepoprawnym `duration` w ogóle nie wstaje, a wyglądałoby to
jak awaria monitoringu, nie jak literówka w `.env`.

!!! info "Migracja starszych instalacji jest automatyczna"
    Do sierpnia 2026 retencja siedziała wprost w `local-config.yaml` i ta strona
    kazała edytować ten plik. Przy pierwszym `make up` po aktualizacji wartości
    zostają **odczytane z Twojego pliku** i przepisane do `.env` — Twoje strojenie
    jest zachowane, nie trzeba nic robić ręcznie.

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
    w `docker-compose.monitoring.yml`. Flaga powstała, **gdy `local-config.yaml` był
    jeszcze `copy_if_missing`** — klucz w tym pliku nie dotarłby wtedy na żadną
    istniejącą instalację. Od sierpnia 2026 plik jest renderowany i force-syncowany
    (patrz wyżej), więc `discover_log_levels: false` w nim **działa już wszędzie**;
    oba zapisy są zgodne i celowo zostawione razem.

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

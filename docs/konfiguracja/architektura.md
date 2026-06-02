# Architektura konfiguracji

## Modularny Docker Compose (dyrektywa `include`)

Wymaga Compose v2.20+. Główna orkiestracja jest rozbita na pliki tematyczne:

```
docker-compose.yml                    # Główna orkiestracja
├── docker-compose.monitoring.yml     # Netdata, Loki, Grafana, Alloy, Dozzle
├── docker-compose.database.yml       # PostgreSQL + wolumen postgresql_data
├── docker-compose.infrastructure.yml # Nginx, Redis
├── docker-compose.application.yml    # appserver, authserver, ofelia, autoheal + wolumeny staticfiles/media
├── docker-compose.workers.yml        # Celery (general, denorm, beat, flower, denorm-queue)
└── docker-compose.backup.yml         # backup-runner
```

Wolumeny są definiowane w pliku, który jest ich właścicielem, ale referowane między
plikami (np. `staticfiles`/`media` zdefiniowane w `application.yml`, używane przez workery).

Każdy wpis `include:` ma `env_file: ${BPP_CONFIGS_DIR}/.env`, żeby interpolacja `${VAR}`
działała w dołączanym YAML-u. `BPP_CONFIGS_DIR` jest odczytywany z repo-lokalnego `.env`
automatycznie przez Compose — `docker compose up` działa bezpośrednio, bez `make`.

## Katalog konfiguracyjny (`BPP_CONFIGS_DIR`)

Konfiguracja żyje **poza repozytorium** (np. `~/publikacje-uczelnia/`). Tworzony przy
pierwszym `make` przez `init-configs`. Zawartość: `.env`, `ssl/`, `rclone/`, `alloy/`,
`loki/`, `netdata/{go.d,health.d}/`, `grafana/provisioning/{datasources,dashboards}/`.
Bind-mountowany bezpośrednio do kontenerów.

Katalog `defaults/` repozytorium trzyma szablonowe configi kopiowane przez `init-configs`
**bez nadpisywania istniejących** (`copy_if_missing`) — więc dostrojone przez użytkownika
configi (`loki/`, `netdata/health.d/`, `netdata/go.d/`, `alloy/`) przeżywają aktualizacje.

## Pliki force-syncowane (nadpisywane przy każdym deploy)

!!! warning "Wyjątek od `copy_if_missing`"
    Trzy artefakty są **nadpisywane z `defaults/` przy każdym `ensure-config-files`**
    (czyli każdym `make up` / `refresh` / `run`) przez `copy_always` (tylko gdy treść
    się różni):

    - `grafana/provisioning/dashboards/*`
    - `grafana/provisioning/datasources/datasources.yaml.tpl`
    - `netdata/netdata.conf`

To dlatego, że są to wersjonowane, „read-only-w-UI" artefakty: zaktualizowany dashboard
albo datasource w repo ma trafić na żywe wdrożenie automatycznie z `git pull && make up`,
bez ręcznego `cp`.

### `netdata.conf` — renderowany host-side

`netdata.conf` jest renderowany z `defaults/netdata/netdata.conf.tpl` (tak jak
`go.d/postgres.conf.tpl`) — bo `netdata.conf` nie umie interpolować `${VAR}`, a hostname
wdrożenia musi trafić do `[registry] registry to announce = https://<host>/netdata`.
Ten URL steruje przyciskiem **„View node"** w powiadomieniach ntfy — bez nadpisywania
istniejąca instalacja trzymałaby stary config i przycisk wskazywałby `registry.my-netdata.io`.

Pokrętła dla użytkownika (retencja dbengine) są parametryzowane przez `.env`
(`NETDATA_DBENGINE_TIER0_RETENTION_MB`, `NETDATA_DBENGINE_PAGE_CACHE_MB`), żeby
force-overwrite nie kasował ręcznego strojenia. **Nie edytuj `netdata.conf` ręcznie —
strój przez `.env`.**

### `datasources.yaml.tpl` — dlaczego force-sync

Z `copy_if_missing` zaktualizowana instalacja trzymałaby stary `.tpl`, więc zmiana typu
„Grafana łączy się przez read-only rolę `bpp_monitor` zamiast superusera aplikacji"
nigdy nie dotarłaby do istniejących wdrożeń. Renderowany `datasources.yaml` (ze skryptu
`scripts/generate-grafana-datasources.sh`, który czyta `.env` z dysku — **nie**
parse-time export make'a, więc świeżo wygenerowane `DJANGO_BPP_PG_MONITOR_PASSWORD` nie
jest renderowane jako puste przy pierwszym `make up`) jest plikiem żywym; `.tpl` to jego
źródło.

Dashboardy usunięte z `defaults/` są zostawiane na miejscu (nie kasowane); dashboardy
tworzone w UI Grafany żyją w jej bazie i nie są ruszane.

## Staticfiles — kontrakt z obrazem appservera

Wolumen `staticfiles` jest wypełniany przez `appserver` (mount `/staticroot`) i serwowany
przez `webserver`/nginx (mount `/var/www/html/staticroot`). Źródłem jest
`/app/staticroot.baked/` wbudowane w obraz appservera na etapie build (gdy dostępne jest
`node_modules` — runtime już go nie ma).

1. Entrypoint appservera w Fazie 2 robi `cp -ru /app/staticroot.baked/. "$STATIC_ROOT/"`.
2. `cp -ru` zasiewa pusty wolumen **i** dokłada nowsze pliki przy upgrade obrazu, bez
   kasowania istniejącej treści.
3. Runtime **nie** odpala `collectstatic` — katalog `.baked` to ten sam output. Fallback
   odpala `collectstatic` tylko dla obrazów sprzed `.baked`.

`STATIC_ROOT=/staticroot/` w `.env` nadpisuje domyślne `/app/staticroot` z obrazu.
Po `make refresh` lub `make prune-orphan-volumes` wolumen jest ponownie wypełniany z `.baked`.

## Media (pliki uploadowane) — `DJANGO_BPP_MEDIA_ROOT`

Pliki wgrywane przez użytkowników (załączniki, PDF-y, eksporty) trafiają do wolumenu
`media`, montowanego pod `/mediaroot` we **wszystkich** kontenerach Django (appserver,
authserver, workery Celery; `backup-runner` montuje go read-only).

`DJANGO_BPP_MEDIA_ROOT=/mediaroot` w `.env` jest **wymagane**. Bez niego Django bierze
swój wbudowany domyślny `MEDIA_ROOT` (`~/bpp-media`, czyli `/root/bpp-media` w
kontenerze), który **nie leży na wolumenie** — pliki użytkowników:

- znikają przy każdym `docker compose up`/`recreate` (są w warstwie kontenera, nie w
  wolumenie),
- **nie trafiają do backupu** (`backup-cycle.sh` taruje `/mediaroot`, nie `/root`).

Zmienna jest ustawiana automatycznie:

- **nowe instalacje** — wpisywana do `.env` przez `make init-configs` (obok
  `STATIC_ROOT`),
- **istniejące instalacje** — dopisywana (append-only, nie nadpisuje wartości ustawionej
  ręcznie) przez `scripts/ensure-config-files.sh` przy każdym `make up`/`refresh`, więc
  `git pull && make up` na starym `.env` naprawia ją bez ręcznych kroków.

Możesz nadpisać wartość ręcznie w `.env` (np. inny punkt montowania) — self-heal jej nie
ruszy. **Bez cudzysłowów** — `validate-env-quotes` odrzuca wartości w cudzysłowach.

## Pierwsze uruchomienie — dwa przebiegi `make`

```bash
make    # Pierwszy raz: pyta o katalog konfiguracyjny, hostname, admina,
        # webhook, katalog backupów, wersję PostgreSQL. Generuje losowe hasła.
make    # Drugi raz: startuje usługi normalnie.
```

Patrz [Pierwsze uruchomienie](../instalacja/pierwsze-uruchomienie.md).

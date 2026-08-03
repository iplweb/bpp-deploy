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

## Captcha zgłoszeń publikacji — `ZGLOS_CAPTCHA_ENABLED` i `ALTCHA_HMAC_KEY`

Publiczny formularz zgłaszania publikacji jest dostępny bez logowania, więc widzą go też
boty. Chroni go **ALTCHA** — captcha typu proof-of-work: przeglądarka liczy zadanie
obliczeniowe w tle, bez klikania w zdjęcia. Jest self-hosted (żadnych usług zewnętrznych,
żadnych danych osobowych wysyłanych na zewnątrz).

Captcha dotyczy **wyłącznie niezalogowanych**. Zalogowany użytkownik nie zobaczy jej
nigdy, a obok widgetu jest podpowiedź, że zalogowanie pomija weryfikację.

Dwie zmienne w `.env`:

| Zmienna | Wartość | Znaczenie |
|---|---|---|
| `ALTCHA_HMAC_KEY` | 64 znaki hex (losowe) | Klucz podpisujący wyzwania ALTCHA |
| `ZGLOS_CAPTCHA_ENABLED` | `1` / `0` | Włącza captchę (`0` = wyłączona) |

Obie ustawiają się automatycznie, bez ręcznego kroku — dopisuje je
`scripts/ensure-config-files.sh` przy każdym `make up`/`refresh` (a `make init-configs`
woła ten skrypt pod spodem, więc nowe instalacje dostają je tak samo). Na starym `.env`
wystarczy `git pull && make up`.

Klucz jest generowany **raz** i potem nietykany — kolejne `make up` go nie rotują
(rotacja unieważniłaby wyzwania trzymane przez otwarte w przeglądarkach formularze).

**Aby wyłączyć captchę**, ustaw w `.env`:

```
ZGLOS_CAPTCHA_ENABLED=0
```

Wartość przeżyje kolejne `git pull && make up` — self-heal nie nadpisuje istniejących
wartości. Samo **usunięcie linii nie wystarczy**: zostanie dopisana z powrotem.

!!! warning "Nie włączaj captchy bez losowego klucza"
    `ZGLOS_CAPTCHA_ENABLED=1` przy braku (albo placeholderze) `ALTCHA_HMAC_KEY` daje
    captchę **możliwą do podrobienia** — klucz podpisujący jest wtedy znany publicznie.
    Automatyka pilnuje kolejności (klucz zawsze przed flagą). Django sygnalizuje zły stan
    ostrzeżeniem `zglos_publikacje.W001` przy starcie. Jeśli dopisujesz zmienne ręcznie —
    dopisz **obie**:

    ```bash
    openssl rand -hex 32   # wynik wklej jako ALTCHA_HMAC_KEY
    ```

Captcha wymaga obrazu BPP z ALTCHA (wydania od `202607.1398` wzwyż). Na starszym obrazie
zmienne są nieszkodliwe — Django ich po prostu nie czyta.

## Fallback HTML→DOCX — opcjonalny sidecar `html2docx`

Eksport do DOCX robi **pandoc z obrazu appservera** i to wystarcza w większości
instalacji. Na nielicznych hostach (np. wirtualizacja VMWare ESX) pandoc potrafi
się wywalić core dumpem — dla takich przypadków jest **opcjonalny sidecar HTTP**
`iplweb/html2docx`, do którego Django odsyła konwersję.

Sidecar jest **domyślnie wyłączony**. Włączenie to **dwa** kroki opt-in — w
**dwóch różnych** plikach `.env`:

| Krok | Plik | Wpis |
|---|---|---|
| 1. Uruchom kontener | `.env` w **katalogu repo** `bpp-deploy` | `COMPOSE_PROFILES=html2docx` |
| 2. Wskaż go Django | `.env` w `$BPP_CONFIGS_DIR` | `DJANGO_BPP_HTML2DOCX_URL=http://html2docx:3030/convert` |

Sam krok 1 podnosi kontener, ale nikt do niego nie zagląda; sam krok 2 kieruje
Django pod adres, którego nie ma. Brak `DJANGO_BPP_HTML2DOCX_URL` to **miękka
degradacja** — fallback jest po prostu wyłączony, nic się nie wywraca.

Sidecar nie ma publikowanego portu (żyje tylko w sieci projektu, jako
`html2docx:3030`) ani `docker.sock` — poprzednia implementacja uruchamiała
konwersję przez `docker run` z gniazda Dockera podmontowanego do appservera i to
właśnie zdjęcie tego gniazda było celem zmiany. Obraz wersjonuje się niezależnie
od `DOCKER_VERSION` — pin przez `HTML2DOCX_VERSION`.

!!! info "Stara flaga `DJANGO_BPP_ENABLE_HTML2DOCX_IMAGE` jest martwa"
    Do lipca 2026 fallback włączała flaga `DJANGO_BPP_ENABLE_HTML2DOCX_IMAGE=true`,
    która powodowała `docker pull` obrazu przy `make up`. Ten mechanizm został
    usunięty. Flaga w istniejących `.env` jest **nieszkodliwa** (nikt jej już nie
    czyta) — nie trzeba jej kasować, ale nic już nie robi.

## Pierwsze uruchomienie — dwa przebiegi `make`

```bash
make    # Pierwszy raz: pyta o katalog konfiguracyjny, hostname, admina,
        # webhook, katalog backupów, wersję PostgreSQL. Generuje losowe hasła.
make    # Drugi raz: startuje usługi normalnie.
```

Patrz [Pierwsze uruchomienie](../instalacja/pierwsze-uruchomienie.md).

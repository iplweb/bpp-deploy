# Architektura konfiguracji

## Modularny Docker Compose (dyrektywa `include`)

Wymaga Compose v2.20+. Główna orkiestracja jest rozbita na pliki tematyczne:

```
docker-compose.yml                    # Główna orkiestracja
├── docker-compose.monitoring.yml     # Netdata, Loki, Grafana, Alloy, Dozzle
├── docker-compose.database.yml       # PostgreSQL + wolumen postgresql_data  (domyslnie)
│   └ docker-compose.database.external.yml   # baza zewnetrzna — podmiana przez ${BPP_DATABASE_COMPOSE}
├── docker-compose.infrastructure.yml # Nginx, Redis
├── docker-compose.application.yml    # appserver, authserver, ofelia, autoheal + wolumeny staticfiles/media
├── docker-compose.workers.yml        # workerserver, denorm-queue, workerserver-status, celerybeat, flower
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
configi (`loki/`, `netdata/health.d/`, `netdata/go.d/`) przeżywają aktualizacje.

## Pliki force-syncowane (nadpisywane przy każdym deploy)

!!! warning "Wyjątek od `copy_if_missing`"
    Cztery artefakty są **nadpisywane z `defaults/` przy każdym `ensure-config-files`**
    (czyli każdym `make up` / `refresh` / `run`) przez `copy_always` (tylko gdy treść
    się różni):

    - `grafana/provisioning/dashboards/*`
    - `grafana/provisioning/datasources/datasources.yaml.tpl`
    - `netdata/netdata.conf`
    - `alloy/config.alloy`
    - `loki/local-config.yaml`

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

### `config.alloy` — dlaczego force-sync

Pipeline logów w Alloy (wykrywanie poziomu, rozkładanie trafień WAF-a na pola) to
**kod wersjonowany, nie konfiguracja użytkownika** — nie ma w nim ani jednego
pokrętła opisanego jako do edycji; wszystko, co operator stroi, siedzi w `.env`.

Przy `copy_if_missing` ten plik był **zamrożony w stanie z dnia instalacji na
zawsze**. Dotknęło to konkretnej zmiany: mapowanie severity OWASP CRS na poziom
logu, dodane w commicie `60ea290` i opisane w dokumentacji jako działające, nie
dotarło na żadne istniejące wdrożenie. Ta sama pułapka co przy
`datasources.yaml.tpl`, tylko wykryta później.

!!! danger "Nie edytuj `config.alloy` ręcznie"
    Zmiany przepadną przy najbliższym `make up`. Jeśli potrzebujesz innego
    zachowania pipeline'u logów — to zmiana w repo, nie w katalogu konfiguracyjnym.

Analogicznie **`webserver-init`** (jednorazowy serwis w
`docker-compose.infrastructure.yml`) naprawia przy każdym `make up` uprawnienia
wolumenu access logu oraz kluczy prywatnych — nginx w obrazie CRS chodzi jako
uid 101 i bez tego nie wstaje. Szczegóły: [SSL](ssl.md#uprawnienia-kluczy-prywatnych).

### `loki/local-config.yaml` — renderowany host-side

Ostatni config monitoringu, który został przeniesiony na force-sync (sierpień 2026).
Przedtem był `copy_if_missing`, czyli — tak jak `config.alloy` przed `60ea290` —
**zamrożony w stanie z dnia instalacji na zawsze**: żadna zmiana schematu, limitów
czy compactora nie docierała na działające wdrożenia. Widać to po obejściu, które
z tego wynikło: wyłączenie wbudowanego wykrywania poziomu logu w Loki musiało
pojechać **flagą CLI** w `docker-compose.monitoring.yml`, bo kluczem w tym pliku
nie miało jak — patrz [Logowanie](../monitoring/logowanie.md#poziom-logu-detected_level).

Blokadą była jedna rzecz: retencja per-stream, którą operator ma prawo dopasować do
swojego dysku. Siedzi teraz w `.env` (`LOKI_RETENTION_DEFAULT`, `_APPSERVER`,
`_DBSERVER`, `_WEBSERVER`), a plik jest renderowany z
`defaults/loki/local-config.yaml.tpl` — dokładnie tym samym mechanizmem co
`netdata.conf`. **Nie edytuj `local-config.yaml` ręcznie — strój przez `.env`**
([tabela wartości](../monitoring/logowanie.md#loki-retencja-czasowa-per-service)).

Istniejące instalacje nie wymagają żadnego ręcznego kroku: przy pierwszym `make up`
wartości zostają odczytane ze starego pliku i przepisane do `.env`, więc ręczne
strojenie przeżywa aktualizację.

!!! note "Dlaczego migracja czyta stary plik, zamiast wpisać stałe z repo"
    Wpisanie wartości domyślnych zresetowałoby po cichu retencję dostrojoną przez
    operatora — przy zwykłym `git pull && make up`, czyli dokładnie to, czego
    zabrania [kontrakt kompatybilności wstecznej](../rozwoj/backwards-compatibility.md).
    Stąd odczyt `awk`-iem z istniejącego `local-config.yaml`.

    Render ma dwie osłony, obie dlatego, że **Loki z niepoprawnym `duration`
    w ogóle nie wstaje** — a operator odczytałby to jako awarię monitoringu, nie
    jako literówkę w `.env`: przepuszczana jest wyłącznie postać
    `<liczba><jednostka>`, a podmiana pliku jest odrzucana, jeśli przetrwał
    w nim którykolwiek placeholder `__RETENTION_*`.

    Świeże instalacje: `init-configs` woła `ensure-config-files` **zanim powstanie
    `.env`**, więc pierwszy render używa wartości domyślnych z repo, a pierwszy
    `make up` dopisuje zmienne i renderuje ponownie bajt w bajt (`cmp` nie widzi
    zmiany). Ta sama sekwencja co przy `ALTCHA_HMAC_KEY` — dlatego `init-configs`
    nie dostaje drugiej kopii tej logiki.

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

1. Entrypoint appservera w Fazie 2 robi `cp -rf /app/staticroot.baked/. "$STATIC_ROOT/"`.
2. `cp -rf` zasiewa pusty wolumen **i** przy upgrade obrazu **zawsze nadpisuje**.
   Wariant `-u` był tu pułapką: mtime w `.baked` pochodzi z czasu builda obrazu, więc
   restart późniejszy niż build (typowe przy szybkich deployach) powodował, że `-u`
   pomijał kopiowanie i wolumen zostawał ze starymi plikami.
3. Pliki, których nie ma w `.baked` (np. custom branding wgrany po wdrożeniu),
   przeżywają — `cp` nie kasuje treści spoza źródła.
4. Runtime **nie** odpala `collectstatic` — katalog `.baked` to ten sam output. Fallback
   odpala `collectstatic` tylko dla obrazów sprzed `.baked`.

Pliki tekstowe w `.baked` są **prekompresowane gzipem już na etapie builda obrazu**
(a wyjście django-compressora w `CACHE/` — przy starcie kontenera), dzięki czemu
`gzip_static on` po stronie nginksa ma co serwować. Powód, dla którego nie wolno
tego robić później, na wolumenie: [Pułapki — kompresja odpowiedzi](../rozwoj/pulapki-kompresji.md).

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

## Logowanie przez Keycloak (OIDC) — zaufane domeny i wiązanie istniejących kont

BPP potrafi logować przez Keycloaka obok zwykłego hasła (metody działają równolegle —
OIDC niczego nie przejmuje). Tożsamość wiąże się z kontem po parze **`(issuer, sub)`**,
nie po adresie e-mail: `sub` nadaje serwer tożsamości i jest niezmienny, a e-mail da się
w realmie po prostu wpisać. Gdyby BPP dopasowywało po adresie, ktoś z prawem edycji
własnego adresu mógłby przejąć cudze konto.

Skutek uboczny tej zasady: **konto założone przed wdrożeniem SSO nie ma jeszcze wpisu
`(issuer, sub)`**. Przy pierwszym logowaniu przez Keycloaka BPP widzi, że konto z tym
adresem już istnieje, i odmawia — nie zakłada drugiego i nie „przejmuje" istniejącego:

```
failed to get or create user: OIDC: konto z tym adresem już istnieje —
połącz je z SSO przez profil (re-auth hasłem), nie tworzę konta.
```

Domyślna ścieżka to **Profil użytkownika → „Połącz konto z SSO"**, z potwierdzeniem
hasłem. Wymaga to jednak **hasła lokalnego** — w instalacji, gdzie logowanie idzie
wyłącznie przez Keycloaka, konta go nie mają i ta droga jest zamknięta.

Dla takich instalacji są trzy zmienne w `.env`:

| Zmienna | Wartość | Znaczenie |
|---|---|---|
| `DJANGO_BPP_OIDC_GRACE_BIND` | `1` / `0` | Włącza jednorazowe dowiązanie istniejącego konta przy logowaniu |
| `DJANGO_BPP_OIDC_TRUSTED_EMAIL_DOMAINS` | domeny po przecinku | Adresy w tych domenach uznajemy za instytucjonalne |
| `DJANGO_BPP_OIDC_GRACE_BIND_PRIVILEGED` | `1` / `0` | Pozwala dowiązać także konto z uprawnieniami |

Przykład:

```
DJANGO_BPP_OIDC_GRACE_BIND=1
DJANGO_BPP_OIDC_TRUSTED_EMAIL_DOMAINS=uczelnia.edu.pl,student.uczelnia.edu.pl
DJANGO_BPP_OIDC_GRACE_BIND_PRIVILEGED=1
```

Każda z nich ma wariant z prefiksem skrótu uczelni (`DJANGO_BPP_OIDC_<SKROT>_…`), który
ma pierwszeństwo przed wariantem bez prefiksu — przydatne w instalacji multi-host.
Wszystkie trzy domyślnie są **wyłączone**; instalacja, która ich nie ustawi, zachowuje
się dokładnie jak dotąd. Nie trzeba nic zmieniać w Compose — zmienne docierają do Django
hurtowym `env_file`.

### Dlaczego lista domen, a nie `email_verified`

Realmy oparte o LDAP często wystawiają **dwa** adresy: instytucjonalny w claimie `mail`
i prywatny w `email`. BPP domyślnie bierze `mail`. Flaga `email_verified` opisuje
natomiast claim `email`, czyli akurat ten prywatny — dla adresu pochodzącego z katalogu
instytucji jest po prostu nieadekwatna. Dlatego zaufanie bierze się z **domeny**: adres
z właściwego claimu, w wypisanej domenie, jest wiarygodny niezależnie od `email_verified`.

Dopasowanie domen jest **dokładne** — bez subdomen i bez wieloznaczników. Domenę
studencką trzeba wypisać osobno obok pracowniczej.

Kolejność claimów da się przestawić przez `DJANGO_BPP_OIDC_EMAIL_CLAIMS` (lista po
przecinku), gdy realm trzyma adres instytucjonalny gdzie indziej.

!!! warning "Lista domen jest jedynym zabezpieczeniem trybu uprzywilejowanego"
    `DJANGO_BPP_OIDC_GRACE_BIND_PRIVILEGED=1` pozwala dowiązać konto administratora —
    z `is_staff`, uprawnieniami i tokenem PBN. Rolę bramki przejmuje wtedy w całości
    lista domen plus założenie, że **użytkownik nie może samodzielnie zmienić sobie
    adresu w katalogu instytucji**. Zanim to włączysz, potwierdź to z działem IT.

    Blokada wzajemna chroni przed przypadkiem: bez `TRUSTED_EMAIL_DOMAINS` ta flaga
    **nie robi nic**. Zostają też trzy bezpieczniki — dokładnie jedno konto z danym
    adresem, konto aktywne i brak tożsamości w tym samym realmie (konta związanego już
    z innym `sub` nie da się przejąć).

!!! danger "Nie „naprawiaj" tego czyszczeniem adresu e-mail"
    Skasowanie adresu na istniejącym koncie faktycznie usuwa kolizję — i tworzy **drugie,
    puste konto**, a to prawdziwe, z uprawnieniami i powiązanym autorem, zostaje
    osierocone. Objaw znika, problem się mnoży.

Wiązanie jest **jednorazowe**: po pierwszym udanym logowaniu konto ma wpis
`(issuer, sub)` i dalej rozpoznaje się już po nim, niezależnie od tych ustawień.

Funkcja wymaga obrazu BPP z tą zmianą (`feat(oidc): zaufanie po domenie
instytucjonalnej`, PR #753). Na starszym obrazie zmienne są nieszkodliwe — Django ich
po prostu nie czyta.

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

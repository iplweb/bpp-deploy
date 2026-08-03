# WAF na brzegu (ModSecurity + OWASP CRS)

Webserver BPP nie jest gołym nginksem — to obraz
[`owasp/modsecurity-crs:nginx`](https://github.com/coreruleset/modsecurity-crs-docker),
czyli **ten sam oficjalny nginx** plus moduł ModSecurity i reguły OWASP Core
Rule Set. Zapytania są sprawdzane pod kątem znanych klas ataków, zanim dotkną
Django.

!!! warning "Domyślnie tryb `DetectionOnly` — WAF nic nie blokuje"
    Świeża instalacja startuje z `MODSEC_RULE_ENGINE=DetectionOnly`: CRS
    **loguje** trafienia, ale przepuszcza ruch. Włączenie blokowania to
    świadoma decyzja po zebraniu baseline — patrz [Włączanie
    blokowania](#wlaczanie-blokowania).

## Po co to jest

Przegląd błędów z lipca 2026 pokazał zautomatyzowany skan SQL injection
(sqlmap) przeciwko jednej z instalacji: 2 165 żądań z payloadami
`UNION ALL SELECT` i `UPDATEXML(…)`. Wszystkie odbiły się o routing Django
(HTTP 404) i nic nie wyciekło, ale:

- skan przyszedł z **1 342 adresów IP, z czego 1 340 użyto dokładnie raz** —
  więc `limit_req` (per-IP) nie miał czego złapać,
- User-Agenty były rotowane na przeglądarkowe, więc filtr po UA też by nie zadziałał.

Jedyną skuteczną dźwignią przy takim rozkładzie jest **filtrowanie po treści
żądania** — czyli dokładnie to, co robi WAF.

## Konfiguracja

Wszystko przez zmienne w `.env` (Compose ma sensowne domyślne, więc świeża
instalacja nie wymaga żadnych zmian).

| Zmienna | Domyślnie u nas | Domyślnie w obrazie | Po co |
|---|---|---|---|
| `MODSEC_RULE_ENGINE` | `DetectionOnly` | `On` | rozruch dwuetapowy |
| `BLOCKING_PARANOIA` | `1` | `1` | poziom agresywności reguł |
| `MODSEC_REQ_BODY_LIMIT` | `132120576` (126 MiB) | `13107200` (12,5 MiB) | **musi być ≥ `client_max_body_size 120M`** |
| `MODSEC_REQ_BODY_NOFILES_LIMIT` | `4194304` (4 MiB) | `131072` (128 KiB) | duże formularze BPP |

!!! danger "Nie obniżaj limitów ciała żądania"
    Domyślne wartości ModSecurity są **znacznie niższe** niż to, co przepuszcza
    nginx. Przy domyślnych: importy POLON/PBN powyżej 12,5 MiB dostają 413,
    a masowa edycja (BPP dopuszcza `DATA_UPLOAD_MAX_NUMBER_FIELDS=50000`)
    przekracza 128 KiB i też leci 413. Objaw dla użytkownika jest mylący —
    „import nie działa" — i pojawia się dopiero przy dużym pliku, czyli długo
    po wdrożeniu.

## Dwie pułapki integracyjne (przeczytaj przed zmianą configu nginksa)

Obraz CRS różni się od gołego nginksa w dwóch miejscach, które łatwo przeoczyć.

### 1. Inny katalog wyjściowy envsubst

Obraz ustawia **`NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx`** (goły nginx ma
`/etc/nginx/conf.d`), a jego szablony odwzorowują całe drzewo `/etc/nginx`.

Dlatego `default.conf.template` montujemy pod
**`/etc/nginx/templates/conf.d/default.conf.template`**, a nie prosto w
`templates/`. Mount w starym miejscu wyrenderowałby się do
`/etc/nginx/default.conf`, którego `include /etc/nginx/conf.d/*.conf` **nie
obejmuje** — konfiguracja BPP zniknęłaby, a **nginx wstałby bez błędu**.
To awaria cicha: `nginx -t` jej nie wykryje.

Nasz plik celowo **nadpisuje** `default.conf` z obrazu. Wersja z obrazu to
generyczny reverse-proxy z `listen … default_server` i własną mapą
`$connection_upgrade` — jedno i drugie kolidowałoby z konfiguracją BPP.
Nadpisanie **nie wyłącza WAF-a**: `modsecurity on;` siedzi w osobnym
`conf.d/modsecurity.conf`.

### 2. Brak `NGINX_ENVSUBST_FILTER`

Wcześniej Compose ustawiał `NGINX_ENVSUBST_FILTER: "DJANGO_BPP_"`. **Tego już
nie ma i nie wolno tego przywracać.** Szablony obrazu CRS używają 75 zmiennych
(`WORKER_CONNECTIONS`, `LOGLEVEL`, `MODSEC_*`, `SSL_*`…); z filtrem
zostałyby dosłowne i nginx nie wstałby w ogóle (`invalid number
"${WORKER_CONNECTIONS}"`).

Filtr chronił konfigurację BPP przed nadgorliwym podstawianiem — ale
`default.conf.template` **nie używa żadnych zmiennych środowiskowych**
(nginksowe `$http_upgrade` i `$connection_upgrade` to zmienne runtime, których
envsubst i tak nie rusza), więc stracił rację bytu. Vhosty renderuje
`30-render-bpp-vhosts.sh` własnym `envsubst` z jawną listą zmiennych, niezależnie
od tego mechanizmu.

## Włączanie blokowania

Nie włączaj `On` od razu. Kolejność:

1. Zostaw `DetectionOnly` i zbierz trafienia z audit logu ModSecurity
   (leci na stdout w formacie JSON — widoczny w Dozzle i w Loki).
2. Przejrzyj, które reguły zapaliły się na **legalnym** ruchu. Miejsca, w
   których to niemal pewne:
      - panel admina `dbtemplates` — superuser POST-uje surowy HTML, co jest
        kanonicznym fałszywym alarmem rodziny 941 (XSS),
      - `/api/v1/zapytanie/*` — składnia DjangoQL przypomina SQL, rodzina 942.
3. Dla każdego takiego przypadku dopisz wykluczenie przez
   `SecRuleUpdateTargetById` / `SecRuleRemoveById` w osobnym pliku —
   **nigdy przez edycję plików CRS**, bo rozjedzie się przy aktualizacji obrazu.
4. Dopiero wtedy ustaw w `.env`:

    ```bash
    MODSEC_RULE_ENGINE=On
    ```

    i `make run`. Wdrażaj instalacja po instalacji, nie wszystkie naraz.

## Rollback

Konfiguracja nginksa jest montowana wolumenami, więc powrót to jedna linia:

```yaml
# docker-compose.infrastructure.yml
image: nginx:1.30.2
```

…plus przywrócenie mountu `default.conf.template` prosto do
`/etc/nginx/templates/` i `NGINX_ENVSUBST_FILTER: "DJANGO_BPP_"`. Wszystkie trzy
zmiany muszą wrócić razem — patrz pułapki wyżej.

## Co WAF pokrywa, a czego nie

CRS obejmuje m.in. SQL injection (rodzina 942), path traversal i LFI (930),
command injection (932), XSS (941), SSTI i SSRF (934), fingerprinty skanerów (913).

Czego **nie** rozwiązuje: 404 generowanych przez legalne boty wyszukiwarek na
martwych URL-ach. Te adresy wyglądają całkowicie normalnie i nginx nie wie z
góry, że zapytanie skończy się 404 — to zadanie dla przekierowań 301 po stronie
aplikacji, nie dla WAF-a.

Pełne uzasadnienie decyzji i odrzucone warianty:
`docs/superpowers/specs/2026-08-03-waf-owasp-crs-design.md`.

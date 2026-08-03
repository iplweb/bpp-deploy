# WAF na brzegu (ModSecurity + OWASP CRS)

Webserver BPP nie jest gołym nginksem — to obraz
[`owasp/modsecurity-crs:nginx`](https://github.com/coreruleset/modsecurity-crs-docker),
czyli **ten sam oficjalny nginx** plus moduł ModSecurity i reguły OWASP Core
Rule Set. Zapytania są sprawdzane pod kątem znanych klas ataków, zanim dotkną
Django.

!!! danger "WAF BLOKUJE — rozpoznany atak dostaje zerwane połączenie"
    `MODSEC_RULE_ENGINE=On`. Żądanie z rozpoznanym atakiem dostaje od
    ModSecurity 403, które nginx zamienia na **444: zamknięcie połączenia bez
    żadnej odpowiedzi**. Skaner nie dostaje ani kodu, ani strony błędu, ani
    nagłówków.

    Dwie ścieżki są z blokowania wyjęte i tylko obserwowane —
    `/admin/dbtemplates/` i `/api/v1/zapytanie/` (patrz [Wykluczenia
    reguł](#wykluczenia-regul)).

    **Awaryjne zejście do obserwacji** — w **repo-owym** `.env` (tym obok
    `docker-compose.yml`, nie w `${BPP_CONFIGS_DIR}/.env` — patrz
    `.env.sample`):
    ```bash
    MODSEC_RULE_ENGINE=DetectionOnly
    ```
    i `make run`.

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
| `MODSEC_RULE_ENGINE` | `On` | `On` | blokowanie włączone |
| `BLOCKING_PARANOIA` | `1` | `1` | poziom agresywności reguł |
| `MODSEC_REQ_BODY_LIMIT` | `132120576` (126 MiB) | `13107200` (12,5 MiB) | **musi być ≥ `client_max_body_size 120M`** |
| `MODSEC_REQ_BODY_NOFILES_LIMIT` | `4194304` (4 MiB) | `131072` (128 KiB) | duże formularze BPP |
| `MODSEC_AUDIT_LOG_PARTS` | `AHZ` | `ABIJDEFHZ` | **bez ciał i bez nagłówków w logu** |

!!! danger "Nie przywracaj domyślnych `MODSEC_AUDIT_LOG_PARTS`"
    Domyślne `ABIJDEFHZ` zawiera `I` (ciało żądania) i `E` (ciało odpowiedzi,
    do 1 MiB). Przy nich każda oflagowana transakcja zapisuje do stdout —
    a stamtąd przez Alloy do Loki — pełną treść strony, a **oflagowany POST na
    formularz logowania zapisałby przesłane hasło**. To nie jest tylko kwestia
    objętości logów, tylko danych osobowych.

    Nie wystarczy usunąć ciał. Część `B` to **nagłówki żądania, a w nich
    `Cookie` z `sessionid`** — czyli poświadczenie. Kto ma dostęp do Loki,
    mógłby przejąć sesję zalogowanego użytkownika. Potwierdzone na stagingu
    2026-08-03.

    `AHZ` = nagłówek transakcji (**w tym linia żądania z URI, czyli payload**)
    + komunikaty reguł + domknięcie. Do diagnostyki komplet. User-Agent nie
    ginie — jest w access logu nginksa (`bpp_access`), do skorelowania po
    czasie i adresie IP.

    **Inspekcja ciał nadal działa** (`MODSEC_REQ_BODY_ACCESS=on`) — wyłączamy
    tylko ich *logowanie*, więc ataki w POST są dalej wykrywane.

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

## Wykluczenia reguł

Własne naddefinicje idą do `defaults/webserver/modsecurity-override.conf.template`
(montowany jako `/etc/nginx/templates/modsecurity.d/modsecurity-override.conf.template`).
`setup.conf` obrazu includuje ten plik **przed** regułami CRS — co ma
praktyczną konsekwencję: **`SecRuleRemoveById` tam nie zadziała**, bo reguły
CRS jeszcze nie istnieją w momencie parsowania. Działa natomiast akcja `ctl`
we własnej regule, bo wykonuje się w trakcie transakcji.

Zakres ID `1-99999` jest zarezerwowany dla reguł lokalnych (CRS używa
`900000-999999`).

Obecnie są tam trzy reguły:

- **`id:10001` — healthcheck poza audytem.** Healthcheck Dockera
  (`curl http://127.0.0.1:80/healthz` co 10 s) zapalał regułę `920350`
  („Host header is a numeric IP address"), bo w nagłówku `Host` jest numeryczny
  adres. To ~8 640 wpisów audytowych na dobę, które topiły realne trafienia.
  Wyciszamy **logowanie** dla tej jednej ścieżki (`ctl:auditEngine=Off`), a nie
  regułę globalnie — na ruchu z zewnątrz `920350` jest sensowna, bo skanery
  wołają po IP, nie po nazwie.

- **`id:10002` — `/admin/dbtemplates/` tylko obserwowane.** Superuser edytuje
  tam szablony HTML, czyli POST-uje surowy HTML z JavaScriptem — kanoniczny
  fałszywy alarm rodziny 941 (XSS), opisany wprost w dokumentacji CRS.

- **`id:10003` — `/bpp/zapytanie/` i `/api/v1/zapytanie/` tylko obserwowane.**
  Użytkownik wpisuje tam dowolny tekst zapytania DjangoQL, więc zapalić się
  może praktycznie każda rodzina reguł — nie tylko 942 (SQL). Potwierdzone na
  stagingu 2026-08-03: `query=test = 5/etc/passwd` zapaliło `930120` (LFI),
  `932235` i `932160` (RCE), łączny score 15 przy progu 5 → blokada.

    **Są dwa endpointy i łatwo wykluczyć tylko jeden:** `/bpp/zapytanie/` to
    interfejs użytkownika (`bpp/src/bpp/urls.py:113`), `/api/v1/zapytanie/` to
    wariant API. Ten pierwszy jest ważniejszy — to w nim ludzie realnie piszą
    zapytania.

Reguły 10002 i 10003 schodzą dla swoich ścieżek do `ctl:ruleEngine=DetectionOnly`:
trafienia nadal trafiają do audit logu (i posłużą do napisania precyzyjnych
wykluczeń), ale nikomu nie urywają połączenia. To **tępe narzędzie na start** —
patrz [Zawężanie wykluczeń po baseline](#zawezanie-wykluczen-po-baseline).

## Logi WAF-a w Grafanie

Audit log ModSecurity to JSON **bez pola `level`**, więc pipeline wykrywania
poziomu w Alloy kończył się na `detected_level=unknown`. `defaults/alloy/config.alloy`
ma dedykowany `stage.match`, który dla linii zawierających `ModSecurity-nginx`
mapuje `severity` reguły CRS (skala sysloga) na poziom logu:

| severity CRS | `detected_level` |
|---|---|
| 0–2 (EMERGENCY/ALERT/CRITICAL) | `critical` |
| 3 (ERROR) | `error` |
| 4 (WARNING) | `warning` |
| 5–6 (NOTICE/INFO) | `info` |
| 7 (DEBUG) | `debug` |

Blok musi zostać **poniżej** ogólnych reguł w tym pliku — nadpisuje ich wynik.

Przykładowe zapytanie LogQL do przeglądania trafień:

```logql
{service="webserver"} |~ "ModSecurity-nginx" | json
  | line_format "{{.transaction_request_uri}} → {{.transaction_messages_0_details_ruleId}}"
```

## Sprawdzenie, czy WAF dziala — `make test-waf`

```bash
make test-waf
```

Stawia **stack testowy**: atrapę backendu, która na każde żądanie odpowiada
`200 pass`, oraz webserver z **prawdziwą** konfiguracją z `defaults/webserver/`.
Potem strzela baterią zapytań, gdzie każde ma z góry znany oczekiwany wynik —
i wypisuje `OK` albo `FAIL` per przypadek. Kod wyjścia = liczba niezgodności.

Nie wymaga `.env`, działającej instalacji ani sieci produkcyjnej; sprząta po
sobie własne kontenery i sieć.

Payloady ataku to **prawdziwe próby z lipca 2026** (sqlmap przeciwko
`publikacje.up.lublin.pl`), nie wymyślone przykłady. Po stronie „ma przejść"
siedzą realne wzorce ruchu BPP: eksporty raportów z sortowaniem, wyszukiwanie
tekstem zawierającym angielskie `select … from`, DjangoQL, `dbtemplates`.

Zmienne:

- `WAF_TEST_PORT` — port na hoście (domyślnie `18443`),
- `MODSEC_RULE_ENGINE` — ustaw `DetectionOnly`, żeby zobaczyć, co **by** zostało
  zablokowane, bez faktycznego blokowania.

!!! note "Czego ten test NIE obejmuje"
    Sprawdza wyłącznie warstwę brzegową. Sondy o pliki `*.php` (phpMyAdmin,
    WordPress) przechodzą tutaj, bo blokuje je dopiero
    `MaliciousRequestBlockingMiddleware` po stronie Django — a w tym stacku
    backend jest atrapą. To jest w teście oznaczone jako oczekiwany `PASS`.

## Dlaczego 444, a nie 403

444 to niestandardowy kod nginksa: **zamknij połączenie, nie wysyłając nic**.
Wbrew intuicji nie oznacza to, że klient wisi — połączenie jest zrywane
natychmiast, po prostu bez odpowiedzi.

`_bpp-locations.conf` mapuje `error_page 403` na `return 444`. Trafiają tam
**wyłącznie 403 wygenerowane przez sam nginx**: blokada ModSecurity oraz nasze
własne `deny all` (pliki ukryte, kopie zapasowe, `/metrics`, wykonywalne
w `/media/`).

!!! warning "Nie włączaj `proxy_intercept_errors`"
    403 zwracane przez **Django** (`PermissionDenied`) **nie** wpada w
    `error_page`, bo `proxy_intercept_errors` jest domyślnie wyłączone i
    celowo tego nie zmieniamy. Dzięki temu użytkownik bez uprawnień widzi
    normalną stronę „brak dostępu", a nie zerwane połączenie. Włączenie tej
    dyrektywy gdziekolwiek w konfiguracji zepsuje to natychmiast.

Cena 444: **fałszywy alarm jest znacznie trudniejszy do zdiagnozowania**.
Użytkownik nie zobaczy komunikatu, tylko „połączenie przerwane" — i nie ma jak
się domyślić, że zatrzymał go WAF. Dlatego dwie ścieżki, o których z góry
wiadomo, że będą fałszywie alarmować, są wyjęte z blokowania.

## Zawężanie wykluczeń po baseline

Reguły 10002/10003 to tępe narzędzie — wyłączają blokowanie dla całej ścieżki.
Docelowo zastąp je celowanymi wykluczeniami:

1. Zostaw `DetectionOnly` i zbierz trafienia z audit logu ModSecurity
   (leci na stdout w formacie JSON — widoczny w Dozzle i w Loki).
2. Przejrzyj, które reguły zapaliły się na **legalnym** ruchu. Miejsca, w
   których to niemal pewne:
      - panel admina `dbtemplates` — superuser POST-uje surowy HTML, co jest
        kanonicznym fałszywym alarmem rodziny 941 (XSS),
      - `/api/v1/zapytanie/*` — składnia DjangoQL przypomina SQL, rodzina 942.
3. Dla każdego takiego przypadku dopisz wykluczenie w
   `defaults/webserver/modsecurity-override.conf.template` — **nigdy przez
   edycję plików CRS**, bo rozjedzie się przy aktualizacji obrazu. Pamiętaj o
   ograniczeniu z sekcji [Wykluczenia reguł](#wykluczenia-regul): plik jest
   includowany **przed** regułami CRS, więc użyj własnej reguły z akcją `ctl`
   (np. `ctl:ruleRemoveTargetById`, `ctl:auditEngine=Off`), a nie
   `SecRuleRemoveById`.
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

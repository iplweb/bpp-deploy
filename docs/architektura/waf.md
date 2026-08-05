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
| `MODSEC_AUDIT_LOG_RELEVANT_STATUS` | `^$` (nigdy) | `^(?:5\|4(?!04))` | **audit log wyłącznie z trafień reguł** |
| `ALLOWED_HTTP_VERSIONS` | + `HTTP/3 HTTP/3.0` | `HTTP/1.0 HTTP/1.1 HTTP/2 HTTP/2.0` | **bez tego h3 jest blokowane w całości** |

!!! danger "Nie usuwaj HTTP/3 z `ALLOWED_HTTP_VERSIONS`"
    Reguła **920430** („HTTP protocol version is not allowed by policy") ma
    severity CRITICAL = **5 punktów**, czyli dokładnie próg blokowania — jedno
    trafienie wystarczy, żeby zerwać połączenie. Domyślna lista CRS nie zna
    HTTP/3, a my h3 włączamy świadomie (`listen 443 quic` + `Alt-Svc`), więc
    **każde** żądanie h3 dostawałoby 444.

    Objaw jest wyjątkowo paskudny: przeglądarka raz przełączona na h3 trzyma się
    go przez dobę (`Alt-Svc: ma=86400`), więc to pełna niedostępność serwisu bez
    żadnego komunikatu. Deklarujemy wersję zamiast wyłączać regułę — polityka
    wersji protokołu zostaje egzekwowana.

!!! warning "Obraz CRS to tag pływający"
    `owasp/modsecurity-crs:nginx` nie jest przypięty do wersji. Przebudowa
    z 2026-08-05 zaczęła egzekwować 920430 i **zablokowała h3** — złapał to
    dopiero `make test-waf` w CI, dzień po tym, jak ten sam test przechodził.
    Po każdej aktualizacji obrazu warto puścić `make test-waf`.

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

## Wykluczenia reguł {#wykluczenia-regul}

Własne naddefinicje idą do `defaults/webserver/modsecurity-override.conf.template`
(montowany jako `/etc/nginx/templates/modsecurity.d/modsecurity-override.conf.template`).
`setup.conf` obrazu includuje ten plik **przed** regułami CRS — co ma
praktyczną konsekwencję: **`SecRuleRemoveById` tam nie zadziała**, bo reguły
CRS jeszcze nie istnieją w momencie parsowania. Działa natomiast akcja `ctl`
we własnej regule, bo wykonuje się w trakcie transakcji.

Zakres ID `1-99999` jest zarezerwowany dla reguł lokalnych (CRS używa
`900000-999999`).

Obecnie jest ich pięć:

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

- **`id:10004` — panele administracyjne bez inspekcji ciała odpowiedzi.**
  `/grafana/`, `/dozzle/`, `/flower/` i `/netdata/` dostają
  `ctl:ruleRemoveById=950000-959999`, czyli zdjęcie całej rodziny reguł
  **wychodzących**. Szczegóły i uzasadnienie: [Reguły wychodzące](#reguly-wychodzace).

- **`id:10005` — `920280` („Request Missing a Host Header") wyłączone dla
  HTTP/2 i HTTP/3.** W h2/h3 adres serwera jedzie w pseudo-nagłówku
  `:authority`, którego konektor ModSecurity-nginx (v1.0.4) nie widzi. Reguła
  (severity CRITICAL = 5 pkt) zapalała się więc na **każdym** żądaniu h3 i sama
  z siebie osiągała próg anomalii → `949110` blokowało wszystko, także zwykłe
  `GET /`. Ponieważ vhost reklamuje `Alt-Svc: h3=":443"; ma=86400`, przeglądarka
  raz przełączona na h3 trzymała się go przez dobę — czyli pełna niedostępność
  serwisu bez żadnego komunikatu. Nic przy tym nie tracimy: nginx sam odrzuca
  błędem 400 żądanie h2/h3 bez `:authority` (i 1.1 bez `Host:`), zanim dojdzie
  do aplikacji.

Reguły 10002 i 10003 schodzą dla swoich ścieżek do `ctl:ruleEngine=DetectionOnly`:
trafienia nadal trafiają do audit logu (i posłużą do napisania precyzyjnych
wykluczeń), ale nikomu nie urywają połączenia. To **tępe narzędzie na start** —
patrz [Zawężanie wykluczeń po baseline](#zawezanie-wykluczen-po-baseline).

Reguła 10004 jest węższa: zdejmuje **tylko** reguły wychodzące, więc żądania
przychodzące do paneli są nadal w pełni blokowane.

!!! warning "`ctl:responseBodyAccess` nie istnieje w libmodsecurity v3"
    Naturalnym zapisem dla 10004 byłoby `ctl:responseBodyAccess=Off`, ale
    silnik tej akcji **nie zna** i nginx z nią **nie wstaje**:
    `Expecting an action, got: ctl:responseBodyAccess`. Sprawdzone na
    `owasp/modsecurity-crs:nginx` (ModSecurity v3.0.16). Z akcji `ctl` działają
    m.in. `ruleEngine`, `auditEngine`, `ruleRemoveById` (także z zakresem `A-B`)
    i `ruleRemoveByTag`.

## Reguły wychodzące — inspekcja ciała odpowiedzi {#reguly-wychodzace}

Poza regułami sprawdzającymi **żądanie** CRS ma rodzinę `RESPONSE-95x`, która
skanuje **ciało odpowiedzi** w poszukiwaniu wycieków: komunikatów błędów
PHP/SQL/Javy, listingów katalogów, web shelli. Obraz ma je włączone domyślnie
(`MODSEC_RESP_BODY_ACCESS=on`, typy `text/plain text/html text/xml`, limit
1 MiB) i **my tego nie zmieniamy** — dlatego trzeba o nich wiedzieć.

Ta rodzina ma dwie własności, które łatwo przeoczyć:

**1. Próg wyjściowy wynosi 4, a jedno trafienie poziomu ERROR to już 4 punkty.**
Zmienna `ANOMALY_OUTBOUND=4` (wobec `ANOMALY_INBOUND=5`). Reguła o
`severity:ERROR` dokłada dokładnie 4 — więc **pojedyncze** trafienie od razu
przekracza próg i `959100` kończy `deny`. Reguły wychodzące nie mają zapasu,
jaki mają wejściowe.

**2. Blokowanie wychodzące nie blokuje czysto — psuje odpowiedź.**
`959100` działa w `phase:4`, czyli na ciele odpowiedzi, gdy nginx **zwykle
wysłał już nagłówki**. Nie da się wtedy zwrócić 403, a więc i naszego
[444](#dlaczego-444-a-nie-403). Zamiast blokady dostajemy:

```
"GET /grafana/ HTTP/2.0" 500 0 1378 0.038
[error] ModSecurity: Access denied with code 403 (phase 4) ... while sending to client
[alert] header already sent while sending to client
```

Użytkownik widzi **urwaną albo pustą stronę**, a w access logu zostaje `500 0`.
Objaw nie wskazuje na WAF w żaden sposób.

### Dlaczego panele są z tego wyjęte (reguła 10004)

Potwierdzony przypadek ze stagingu, 2026-08-03: `/grafana/` było nie do
otwarcia. Winna reguła **`953100` „PHP Information Leakage"**, która używa
operatora `@pmFromFile php-errors.data` — dopasowania **po podciągu**, bez
granic słowa i bez rozróżniania wielkości liter. W tym pliku danych jest wpis
`SQLConnect` (funkcja ODBC z PHP), a Grafana wstrzykuje w `index.html` obiekt
`window.grafanaBootData` z kluczem **`"sqlConnectionLimits"`**. Ciąg
`sqlConnect` siedzi w jego środku, więc reguła zapala się na **każdej** stronie
Grafany.

Za `/grafana/`, `/dozzle/`, `/flower/` i `/netdata/` nie stoi żadna aplikacja
BPP — stoi gotowy dashboard innego producenta, dostępny wyłącznie dla superusera
(`auth_request /_bpp_superuser_auth`). Skanowanie jego HTML-a pod kątem wycieku
błędów PHP nie chroni przed niczym.

Zmierzone na prawdziwych obrazach paneli, przez prawdziwą konfigurację
z `defaults/webserver/`:

| Panel | Sprawdzone strony | Reguły wychodzące |
|---|---|---|
| **Grafana** | `/`, `/dashboards`, `/connections/datasources`, `/explore` | **`953100` + `959100` → blokada** |
| Dozzle | `/` | czysto |
| Flower | `/`, `/tasks`, `/broker`, `/worker/x` | czysto |
| Netdata | `/`, `/v3/index.html` (100 KB) | czysto |

Wykluczenie obejmuje mimo to wszystkie cztery — są tej samej natury, a kolejna
wersja każdego z nich może wnieść własny fałszywy alarm.

!!! note "Aplikacja BPP nadal jest skanowana"
    10004 dotyczy **wyłącznie** czterech ścieżek paneli. Odpowiedzi Django lecą
    przez reguły wychodzące jak dotąd — i tam mają sens, bo to nasz kod może
    wypluć komunikat błędu bazy danych.

## Logi WAF-a w Grafanie

Jest gotowy dashboard **[WAF (ModSecurity / OWASP CRS)](../monitoring/dashboardy-grafany.md#waf-modsecurity-owasp-crs)**
— rankingi reguł, adresów IP i ścieżek, kategorie ataków, rozkład anomaly score.
Poniżej opis danych, na których stoi.

### Dwa wpisy na jedno żądanie

Każde oflagowane żądanie zostawia w stdout webservera **dwa** wpisy:

1. **linię tekstową** nginksowego error.log (`ModSecurity: Access denied…`),
2. **wpis audit logu** w JSON.

Cała treść analityczna jest w (2). Do error.log trafiają **wyłącznie reguły
decyzyjne** — `949110` (inbound) i `959100` (outbound) — bo w CRS z anomaly
scoringiem pojedyncze reguły ataku się tam nie logują. Rodzaj ataku (`942xxx` SQLi,
`941xxx` XSS, `930xxx` LFI) jest więc **tylko** w JSON-ie. Widać to gołym okiem na
jednym przebiegu `make test-waf`: 8 linii error.log wobec 11 wpisów audit.

**Oba wpisy dostają pola `modsec_*`** — bo to na linię z error.log patrzy człowiek
w „Log Monitoring" (audit log to ściana JSON-a), a bez własnych pól dałoby się ją
filtrować wyłącznie pełnotekstowo. Te pola są dziś fundamentem dropdownu
**`ModSecurity`** na tamtym dashboardzie (`wszystko` / `tylko WAF` / `bez WAF` —
patrz [Dashboardy Grafany](../monitoring/dashboardy-grafany.md#log-monitoring)):
`tylko WAF` to `modsec_src="nginx"`, a `bez WAF` to `modsec_src=""`, które łapie
linie nieposiadające tego klucza w ogóle. Rozróżnia je **`modsec_src`**:

| `modsec_src` | Co to | Ma `modsec_attack` / `modsec_rules` |
|---|---|---|
| `audit` | wpis audit logu (JSON) | tak — pełny łańcuch reguł i kategoria ataku |
| `nginx` | czytelna linia error.log | **nie** — są tam tylko reguły decyzyjne |

!!! warning "Agregaty muszą filtrować `modsec_src`"
    Jedno żądanie = dwa wpisy. Zapytanie liczące trafienia **bez**
    `| modsec_src = "audit"` policzy każde żądanie dwa razy. Wszystkie panele
    dashboardu WAF mają ten filtr; panel z logami celowo pokazuje `nginx`.

Oba wpisy spina `modsec_unique_id`.

### Wpisy audytowe, w których nie zapaliła się żadna reguła

`SecAuditEngine RelevantOnly` (domyślne w obrazie) loguje transakcję z **dwóch
niezależnych powodów**, połączonych `OR`:

1. zapaliła się reguła z akcją `auditlog`,
2. **kod odpowiedzi** pasuje do `SecAuditLogRelevantStatus` — a domyślne w obrazie
   `^(?:5|4(?!04))` to **każde 4xx poza 404 i każde 5xx**.

Powód (2) wpuszcza do audit logu ruch, którego WAF w ogóle nie dotknął. Taki wpis
ma `"messages":[]` — zero informacji o ataku — a mimo to niesie komplet pól
`modsec_*` (URI, IP, kod), więc dla agregatu wygląda identycznie jak trafienie.
Łapie się tam:

- **401** z `auth_request` na `/grafana/`, `/dozzle/`, `/flower/`, `/netdata/` —
  a to jest **ścieżka zaprojektowana**: `error_page 401 = @bpp_login` przekierowuje
  niezalogowanego na logowanie BPP,
- **429** z [rate limitingu](rate-limiting.md),
- **502/503/504**, gdy leży `appserver`.

!!! danger "Objaw: dashboard WAF-a pokazuje własne panele Grafany jako ataki"
    Produkcja, 2026-08-05: wygasła sesja przy otwartej karcie Grafany dała dziewięć
    wpisów 401 (strona + fonty + moduły pluginów), a panel „Najczęściej atakowane
    ścieżki" wyświetlił `Inter-Regular.woff2` i `grafana-lokiexplore-app/module.js`
    jako najczęstsze cele ataków. Trop prowadził donikąd — reguła 10004 działała
    poprawnie, CRS nie zgłosił niczego, bo **nie było czego zgłaszać**.

Dlatego ustawiamy `MODSEC_AUDIT_LOG_RELEVANT_STATUS=^$`: kod statusu jest zawsze
niepusty, więc ten regexp nie pasuje do niczego i zostaje sam powód (1). Zmierzone
na `owasp/modsecurity-crs:nginx`: przy `^$` zwykłe 502 nie zostawia wpisu, a żądanie
z SQLi nadal zostawia wpis z czterema regułami.

Nic przy tym nie tracimy: przy `MODSEC_AUDIT_LOG_PARTS=AHZ` taki wpis niósł mniej
niż linia access logu nginksa (format `bpp_access`, też zbierany przez Alloy),
a błędy 5xx mają własny dashboard
[„Log Monitoring"](../monitoring/dashboardy-grafany.md#log-monitoring).

!!! warning "Agregaty muszą też filtrować `modsec_rule_id`"
    To druga warstwa, niezależna od powyższego ustawienia — `MODSEC_AUDIT_LOG_RELEVANT_STATUS`
    jest jawnym knobem w `.env` i operator może je przywrócić. Każde zapytanie
    dashboardu WAF ma dlatego **oba** filtry:
    `| modsec_src = "audit" | modsec_rule_id != ""`. Wpis bez reguł nie dostaje
    `modsec_rule_id` (JMESPath `messages[0].details.ruleId` na pustej liście nie
    tworzy klucza), a LogQL traktuje brakującą etykietę jak pustą — więc wypada.
    Pilnują tego `tests/test_makefile.sh` (asercja: liczba zapytań z filtrem
    = liczba zapytań po audit logu) i `make test-alloy` (asercja: wpis bez reguł
    nie dostaje `modsec_rule_id`, ale zachowuje `modsec_code=401`).

### Pola `modsec_*`

Wyciągane przez `defaults/alloy/config.alloy` do **structured metadata** (nie do
labeli — `modsec_uri` i `modsec_client` jako stream labele wysadziłyby kardynalność
indeksu strumieni):

| Pole | Znaczenie |
|---|---|
| `modsec_action` | `blocked` (połączenie zerwane) / `detected` (przepuszczone, reguły 10002/10003) |
| `modsec_rule_id` | reguła **wiodąca** — pierwsza dopasowana, ta merytoryczna |
| `modsec_msg` | jej opis |
| `modsec_severity` | severity reguły wiodącej (skala sysloga, 0–7) |
| `modsec_rules` | pełny łańcuch reguł, po przecinku — do wyszukiwania |
| `modsec_attack` | kategoria z tagu `attack-*` (`sqli`, `xss`, `lfi`, `rce`, `disclosure`…) |
| `modsec_paranoia` | poziom paranoi reguły |
| `modsec_direction` | `inbound` / `outbound` |
| `modsec_score` | anomaly score w momencie decyzji |
| `modsec_uri` | URI z query stringiem (czyli zwykle z payloadem) |
| `modsec_method`, `modsec_code` | metoda HTTP, kod odpowiedzi |
| `modsec_client` | adres IP widziany przez nginksa |
| `modsec_hostname` | vhost — istotne przy multi-host |
| `modsec_unique_id` | spina wpis audit z bliźniaczą linią error.log |
| `modsec_src` | `audit` (JSON) / `nginx` (error.log) — **filtruj po tym w agregatach** |

!!! warning "Poziom trafień to `warn`, nie `error`"
    Mimo że nginx loguje je jako `[error]`. Ta sama decyzja co przy
    `limit_req_log_level warn` w [rate limitingu](rate-limiting.md): powódź zdarzeń
    bezpieczeństwa nie ma zalewać dashboardu błędów **aplikacji**. Skan z lipca 2026
    to 2165 żądań z 1342 adresów IP — każde trafienie to osobna linia, czyli tysiące
    „błędów" przy w pełni sprawnej aplikacji. Trafienia mają własny dashboard.

Przykładowe zapytania LogQL:

```logql
# Najczęściej zapalające się reguły
topk(10, sum by (modsec_rule_id, modsec_msg) (
  count_over_time({service="webserver"} | modsec_action != "" [24h])))

# Co zostało zablokowane temu adresowi
{service="webserver"} | modsec_action = "blocked" | modsec_client = "203.0.113.7"

# Trafienia SQLi na konkretnym vhoście
{service="webserver"} | modsec_attack = "sqli" | modsec_hostname = "bpp.example.org"
```

### Pułapka filtrów ad-hoc {#pulapka-filtrow-ad-hoc}

Grafana pokazuje przy komórkach tabeli i przy polach w szczegółach linii logu lupki
**„Filter for value" / „Filter out value"**. Na polach `modsec_*` **nie wolno ich
używać**: kliknięcie wygasza **wszystkie panele dashboardu** naraz — każdy pokaże
„No data". Objaw wygląda jak awaria zbierania logów i nie ma nic wspólnego
z rzeczywistym stanem WAF-a.

Mechanizm. Filtr ad-hoc trafia do **selektora strumienia**:

```logql
{job="docker", service="webserver", modsec_msg="SQL Injection Attack Detected…"}
                                    ^^^^^^^^^^ to jest structured metadata
```

Selektor strumienia jest rozwiązywany po indeksie strumieni, a `modsec_*` **nigdy**
nie były labelami strumienia — celowo, bo `modsec_uri` × `modsec_client` wysadziłoby
kardynalność indeksu (patrz [tabela pól](#pola-modsec_) wyżej). Żaden strumień nie
pasuje, więc wynik jest pusty na każdym panelu. Poprawne miejsce to filtr **za**
selektorem (`| modsec_msg = "…"`) i dokładnie tak robi to panel „Logs" — bo tam
Grafana zna typ pola z odpowiedzi Loki.

Do filtrów ad-hoc ten typ nie jest przekazywany (Grafana 12.4.2,
`datasource.ts` → `addAdHocFilters()` woła `addLabelToQuery()` bez argumentu
`labelType`), a `modifyQuery.ts` bez niego zgaduje po obecności parsera w zapytaniu.
Nasze zapytania parsera nie mają, więc filtr zawsze ląduje w selektorze.

**Przycisku nie da się ukryć** z poziomu JSON-a dashboardu:
`setDashboardPanelContext.ts` ustawia `onAddAdHocFilter` bezwarunkowo dla każdego
panelu na źródle wspierającym filtry ad-hoc, a `filterable: false` (ustawione na
wszystkich naszych tabelach) dotyczy filtra kolumny, nie tego menu. Dlatego obroną
są **własne, działające filtry**: zmienne u góry dashboardu i data linki na wierszach
tabel — [opis](../monitoring/dashboardy-grafany.md#waf-modsecurity-owasp-crs).

Jeśli już w to wejdziesz: usuń chip `Filters` nad dashboardem (×) albo przeładuj
adres bez `&var-Filters=…`.

!!! note "Jedno ograniczenie klikania po ścieżce"
    Data link po `modsec_uri` cytuje wartość literalnie (`\Q…\E`), żeby metaznaki
    regexa w ścieżkach skanerów (`?`, `+`, `.`) nie zmieniały znaczenia filtra.
    Ścieżka zawierająca **literalny backslash** (np. sonda ThinkPHP
    `…/\think\app/…`, jeśli trafi do logu w postaci niezakodowanej) wymagałaby
    podwojenia także jego — czego data link Grafany nie potrafi — i taki klik wróci
    pusty. Postać `%5C`, czyli ta realnie logowana przez ModSecurity, działa
    normalnie.

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

Po tabelce przypadków leci jeszcze jedno, osobne sprawdzenie: **inspekcja ciała
odpowiedzi**. Atrapa serwuje stronę z komunikatem błędu PHP, a test sprawdza,
czy zapaliła się któraś reguła `95xxx`. Asercja idzie po **audit logu**, a nie
po wyniku HTTP — bo [blokowanie wychodzące jest wyścigiem](#reguly-wychodzace)
i wynik HTTP migotał (1 na 5 przebiegów kończył się inaczej). Wykrycie jest
deterministyczne, egzekucja nie.

Trzecie osobne sprawdzenie to **legalne `GET /` po HTTP/3** — przypadek, dla
którego powstała reguła `10005`. Klient QUIC chodzi z **wnętrza** sieci
dockerowej, bo systemowy curl (także ten z obrazów `alpine` i
`curlimages/curl`) jest budowany bez QUIC; stąd `--network-alias` z nazwą
vhosta na kontenerze webservera. Wynik znów rozstrzyga **access log**, a nie
kod wyjścia curla:

- `444` przy `HTTP/3.0` w logu — realna blokada WAF-a, czyli `FAIL`,
- zero linii `HTTP/3.0` — klient zgubił handshake i żądanie w ogóle nie
  dotarło, więc próba się powtarza (po czterech nieudanych: `POMIN`).

Pod emulacją amd64 (host arm64) handshake gubi się mniej więcej raz na pięć
prób. Bez tego rozróżnienia retry maskowałby regresję.

!!! note "Czego ten test NIE obejmuje"
    Sprawdza wyłącznie warstwę brzegową. Sondy o pliki `*.php` (phpMyAdmin,
    WordPress) przechodzą tutaj, bo blokuje je dopiero
    `MaliciousRequestBlockingMiddleware` po stronie Django — a w tym stacku
    backend jest atrapą. To jest w teście oznaczone jako oczekiwany `PASS`.

    **Sama tabelka przypadków nie łapie błędów specyficznych dla HTTP/2 i /3** —
    strzela `curl --http1.1`, czyli protokołem, w którym `Host:` istnieje.
    Dlatego h3 ma osobne sprawdzenie (opisane wyżej); dokładając nowy przypadek
    do tabelki, pamiętaj, że pokrywa on wyłącznie HTTP/1.1.

    **Nie weryfikuje samego wykluczenia `10004`.** Lokalnie `auth_request`
    tłumi inspekcję odpowiedzi na lokacjach paneli — więc `/grafana/` przechodzi
    tam niezależnie od tego, czy reguła istnieje. Na produkcji tego tłumienia
    **nie ma** (audit log z 2026-08-03 pokazuje `953100` na `/grafana/`), ale
    przyczyna tej rozbieżności pozostaje niewyjaśniona. Przypadek testowy na
    `/grafana/` byłby więc lokalnie zawsze zielony — czyli dawałby fałszywy
    spokój — i celowo go nie ma.

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

## Zawężanie wykluczeń po baseline {#zawezanie-wykluczen-po-baseline}

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

Czego też nie rozwiązuje: żądań, które **nie są atakiem, tylko nie są nasze** —
sond o `*.php`, prefiksów obcych CMS-ów, niepodstawionych literałów szablonów.
Dla CRS to zwykłe URL-e i przepuszcza je poprawnie; odcina je osobna, tańsza
warstwa — [Utwardzenie brzegu](utwardzenie-brzegu.md).

Pełne uzasadnienie decyzji i odrzucone warianty:
`docs/superpowers/specs/2026-08-03-waf-owasp-crs-design.md`.

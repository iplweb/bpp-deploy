# WAF na brzegu: OWASP CRS + ModSecurity zamiast gołego nginksa

Data: 2026-08-03
Status: zatwierdzony do implementacji

## Problem

Przegląd 30 dni Rollbara (5.07–3.08.2026, 8 492 wystąpienia) pokazał, że
**7 817 z nich to `Http404`**, a znacząca część tego nie jest ruchem
użytkowników:

- **2 165 żądań to skan SQL injection** (sqlmap) na `publikacje.up.lublin.pl`,
  w trzech dobach: 13.07 (450), 23.07 (375), 27.07 (1 340). Payloady w
  parametrze `_export=` na `/nowe_raporty/autor/…`: `UNION ALL SELECT`,
  `UPDATEXML(…CONCAT(0x7e…))`, `(SELECT … FROM(SELECT COUNT(*)…))`.
- **Skan przyszedł z 1 342 unikalnych IP, z czego 1 340 użyto dokładnie raz**
  (mediana: 1 żądanie na adres), z rotowanymi User-Agentami zwykłych
  przeglądarek. To rotująca pula proxy.
- Osobno 590 żądań od skanera CERT PL Artemis i 1 324 od Googlebota/bingbota/
  SemrushBota — na URL-ach, które wyglądają całkowicie normalnie.

Wnioski, które określają rozwiązanie:

1. **Istniejący `limit_req` (100 r/s per IP) nie miał czego złapać** — każdy
   adres strzelał raz. Blokowanie i limitowanie po IP jest w tym scenariuszu
   bezużyteczne. Jedyna działająca dźwignia to **treść żądania**.
2. **Nic nie przeciekło do bazy**: wszystkie 2 165 prób odbiły się o lookup
   `DefinicjaRaportu` i zwróciły `Http404`, a żaden z 416 błędów poziomu
   `error` nie ma sygnatury SQLi. **Zastrzeżenie:** Rollbar rejestruje wyłącznie
   wyjątki, więc żądanie zakończone HTTP 200 byłoby dla niego niewidoczne.
   Pewność dałby dopiero log dostępowy nginksa z tych trzech dób.
3. Szum topi sygnał: po odsianiu skanów zostaje 5 062 realnych 404 na 1 271
   ścieżkach, w tym 1 300 trafień Googlebota i bingbota na 520 martwych URL-ach
   (zmienione slugi autorów i jednostek, usunięte rekordy) — czyli realne
   zepsute linki, których dziś nie widać.

## Cel

Blokować rozpoznane klasy ataków **na brzegu, zanim dotkną Django**, przy użyciu
gotowego i utrzymywanego zestawu reguł — zamiast własnych wyrażeń regularnych,
które trzeba by rozwijać i pilnować w nieskończoność.

## Decyzje projektowe (ustalone w brainstormingu)

- **OWASP CRS przez obraz `owasp/modsecurity-crs:nginx`.** CRS jest rozwijany
  od 2002 i pokrywa kilkanaście rodzin reguł; rodzina **942 (SQLi)** to
  dokładnie ten przypadek.
- **Bez zmian w repozytorium `bpp`.** `MaliciousRequestBlockingMiddleware`
  zostaje jak jest. Cała zmiana jest w `bpp-deploy`.
- **Paranoia level 1** (domyślny), start w trybie **`DetectionOnly`**.
  Blokowanie włączane dopiero po baseline na realnym ruchu.
- **Wykluczenia wyłącznie przez `SecRuleUpdateTargetById` / `SecRuleRemoveById`
  w osobnym pliku**, nigdy przez edycję plików CRS — inaczej aktualizacja
  zestawu reguł rozjedzie się z lokalnymi zmianami.

### Rozważone i odrzucone

| Wariant | Dlaczego odrzucony |
|---|---|
| Własny `map $args` z listą sygnatur SQLi | Zmierzony na realnym ruchu: 99,3% pokrycia (2 149/2 165), 0 fałszywych alarmów na 462 legalnych żądaniach z query stringiem. Działa — ale to własnoręczna miniatura jednej rodziny CRS, z dożywotnim kosztem utrzymania. |
| Coraza (silnik w Go, ta sama składnia reguł) | Sens przy Caddy/Traefik/Envoy. Przy nginksie ModSecurity jest lepiej ograny. |
| `django-soc-lite` | Martwy: ostatnie wydanie 2019-07-08, przypięte `requests==2.20.0`. |
| `django-waf` | Pierwsze wydanie 2026-04-07, 35 wydań w 4 miesiące. Zbyt świeży na produkcję wielotenantową. |
| Fingerprint skanera po User-Agencie | Skan rotował UA na przeglądarkowe właśnie po to, by ominąć taką regułę. |
| Blokowanie/limitowanie po IP | 1 340 z 1 342 adresów użyto raz. Nie ma czego zablokować. |

## Architektura — trzy fazy, każda z własnym kryterium wyjścia

### Faza 0 — przygotowanie (nic nie trafia na produkcję)

Podmiana `image: nginx:1.30.2` → `owasp/modsecurity-crs:nginx` w
`docker-compose.infrastructure.yml:10` plus konfiguracja limitów ciała żądania.

**Kryterium wyjścia:** `nginx -t` przechodzi, kontener wstaje, wszystkie
montowane pliki konfiguracyjne się ładują, HTTP/3 nadal działa (patrz „Kruche
miejsca", punkt 1).

### Faza 1 — baseline w `DetectionOnly`

`MODSEC_RULE_ENGINE=DetectionOnly` — CRS **loguje**, ale niczego nie blokuje.

**Kryterium wyjścia jest pokryciem, nie czasem.** Odrzucone: „poczekajmy N dni".
Czekanie nie gwarantuje, że przez WAF przejdzie akurat ten ruch, który jest
ryzykowny — a duża część potrzebnych danych już istnieje i da się je odtworzyć
w godzinę zamiast w trzy doby. Baseline stoi na trzech nogach, bo żadna sama
nie pokrywa całości:

**Noga 1 — odtworzenie ruchu z Loki (pokrywa GET).**
`retention_period: 720h` (`defaults/loki/local-config.yaml:51`) oznacza, że na
każdej instalacji leży **30 dni pełnego logu dostępowego nginksa** — w tym
żądania zakończone sukcesem. To korpus, którego nie da się zbudować z Rollbara,
bo tam trafiają wyłącznie wyjątki. Wyciągamy log przez API Loki, odtwarzamy go
przeciwko stagingowi z CRS i zbieramy trafienia reguł.

**Ograniczenie, o którym trzeba pamiętać: log dostępowy zawiera tylko linię
żądania (metoda + ścieżka + query), nigdy ciała POST.** Ta noga nie powie
zatem nic o ryzykach 3–5 z sekcji „Kruche miejsca".

**Noga 2 — scenariusze POST ze skryptu (pokrywa to, czego noga 1 nie może).**
Ręcznie spisana lista scenariuszy odpalana przeciwko stagingowi: zapis szablonu
w `dbtemplates`, import pliku ponad progiem, duży formularz, zapytanie DjangoQL.

**Istniejąca suita `src/integration_tests/` NIE nadaje się do tego celu** —
fixture `channels_live_server` (`bpp/src/channels_live_server.py:185`) startuje
lokalny podproces Daphne i nie ma parametru adresu zdalnego. Scenariusze trzeba
napisać osobno (curl/Playwright celujący w host stagingowy).

**Noga 3 — publiczny staging zostawiony w `DetectionOnly` (pokrywa ruch
organiczny).** Jeden z dwóch serwerów stagingowych jest wystawiony publicznie,
więc sam zbiera ruch skanerów i crawlerów. Nie wymaga czekania — po prostu
akumuluje w tle, a wyniki dokładamy do baseline, kiedy się pojawią.

**Brak Rollbara na publicznym stagingu nie jest przeszkodą.** Sygnałem w tej
fazie jest audit log ModSecurity, a nie wyjątki Django — CRS w trybie
`DetectionOnly` nie generuje wyjątków, tylko wpisy w swoim logu.

**Kryterium wyjścia:** nogi 1 i 2 wykonane, a **każda** reguła, która zapaliła
się na legalnym ruchu, jest wyjaśniona i ma zapadłą decyzję (wykluczenie albo
świadome zostawienie).

### Faza 2 — wykluczenia i włączenie blokowania

Wykluczenia dla miejsc z listy poniżej, następnie `MODSEC_RULE_ENGINE=On`.

**Kryterium wyjścia:** payloady z 27.07 dostają 403, a scenariusze z sekcji
„Testy" przechodzą bez zmian.

## Konfiguracja

| Zmienna | Wartość | Uzasadnienie |
|---|---|---|
Nazwy zmiennych zweryfikowane w README obrazu `coreruleset/modsecurity-crs-docker`
(wartości domyślne w nawiasach — to one są źródłem problemów z sekcji „Kruche
miejsca").

| Zmienna | Wartość | Uzasadnienie |
|---|---|---|
| `MODSEC_RULE_ENGINE` (dom. `On`) | `DetectionOnly` → `On` | rozruch dwuetapowy |
| `BLOCKING_PARANOIA` (dom. `1`) | `1` | zostawiamy domyślny; wyższe poziomy są jawnie bardziej podatne na fałszywe alarmy |
| `MODSEC_REQ_BODY_LIMIT` (dom. `13107200` = 12,5 MiB) | **`132120576`** (126 MiB) | musi być spójne z `client_max_body_size 120M` |
| `MODSEC_REQ_BODY_NOFILES_LIMIT` (dom. `131072` = **128 KiB**) | podniesione | `DATA_UPLOAD_MAX_NUMBER_FIELDS = 50000` nie zmieści się w 128 KiB |
| `MODSEC_AUDIT_ENGINE` (dom. `RelevantOnly`) | `RelevantOnly` | audit log tylko dla trafień |

## Kruche miejsca / kontrakty

> Punkty 1–2 zostały **zweryfikowane na realnym obrazie** `owasp/modsecurity-crs:nginx`
> (2026-08-03). Punkt 1 wypadł pomyślnie; punkt 2 ujawnił trzy niezgodności,
> przez które ta zmiana **nie jest podmianą jednej linii w compose**.

1. **HTTP/3 (QUIC) — ZWERYFIKOWANE, OK.** `nginx -V` w obrazie pokazuje
   `--with-http_v3_module`, a wersja to **nginx 1.30.4** (nowsza niż przypięta
   `1.30.2`). Publikowanie `443:443/udp` i nagłówek `Alt-Svc` z
   `vhost.conf.template` zostają bez zmian. Moduł ModSecurity jest obecny jako
   `/usr/lib/nginx/modules/ngx_http_modsecurity_module.so`, ładowany przez
   `load_module` z szablonu `nginx.conf.template` obrazu.

2. **Renderowanie szablonów — ZWERYFIKOWANE, TRZY NIEZGODNOŚCI.**

   **2a. Inny katalog wyjściowy envsubst — awaria CICHA.** Obraz CRS ustawia
   `NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx`, podczas gdy goły nginx domyślnie ma
   `/etc/nginx/conf.d`. Szablony CRS odwzorowują całe drzewo `/etc/nginx`
   (`templates/nginx.conf.template` → `/etc/nginx/nginx.conf`,
   `templates/conf.d/*.template` → `/etc/nginx/conf.d/*`).

   Konsekwencja dla BPP: mount `default.conf.template` →
   `/etc/nginx/templates/default.conf.template` wyrenderowałby się do
   **`/etc/nginx/default.conf`**, którego `include /etc/nginx/conf.d/*.conf`
   **nie obejmuje**. Cała konfiguracja BPP (strefy `limit_req_zone`, mapy,
   przekierowania HTTP→HTTPS) zniknęłaby, a nginx wstałby **bez błędu**,
   serwując domyślny server block CRS. To najgroźniejszy tryb awarii w całej
   zmianie, bo nie zapala się na `nginx -t`.

   Rozwiązanie: przenieść mount do `/etc/nginx/templates/conf.d/default.conf.template`
   — wtedy renderuje się do `/etc/nginx/conf.d/default.conf` i **celowo nadpisuje**
   własny `default.conf` obrazu CRS (punkt 2c).

   **2b. `NGINX_ENVSUBST_FILTER` — awaria GŁOŚNA, ale blokująca.**
   `docker-compose.infrastructure.yml:15` ustawia `NGINX_ENVSUBST_FILTER: "DJANGO_BPP_"`.
   Filtr zawęża podstawianie do zmiennych o tym prefiksie i **istnieje nie bez
   powodu**: chroni nginksowe `$host`, `$remote_addr`, `$scheme` w konfiguracji
   BPP przed zjedzeniem ich przez envsubst.

   Ale szablony CRS używają `${WORKER_CONNECTIONS}`, `${HTTP2}`,
   `${CLIENT_BODY_TIMEOUT}`, `${KEEPALIVE_TIMEOUT}`, `${NGINX_PORT_IN_REDIRECT}`
   i `${MODSEC_*}` — z tym filtrem zostaną dosłowne, a `worker_connections
   ${WORKER_CONNECTIONS};` to błąd składni → kontener nie wstanie.

   **ROZSTRZYGNIĘCIE (empiryczne, prostsze niż zakładano): filtr usunięty
   w całości.** Pierwotna obawa („rozjedzie się konfiguracja BPP") okazała się
   bezpodstawna — `default.conf.template` **nie używa ani jednej zmiennej
   środowiskowej**. Jedyne wystąpienie `${VAR}` w tym pliku to fragment
   *komentarza* objaśniającego działanie envsubst, a `$http_upgrade` i
   `$connection_upgrade` to zmienne runtime nginksa, których envsubst nie
   rusza (podstawia wyłącznie **zdefiniowane** zmienne środowiskowe).

   Rozważona i odrzucona alternatywa: rozszerzenie filtru o prefiksy CRS.
   Szablony obrazu używają **75 zmiennych** (`WORKER_CONNECTIONS`, `LOGLEVEL`,
   `METRICSLOG`, `SSL_*`, `PROXY_SSL_*`, `CORS_*`…), z czego 37 nie ma prefiksu
   `MODSEC_`/`NGINX_`. Taka lista rozjechałaby się przy pierwszej aktualizacji
   obrazu — dokładnie ten rodzaj długu, dla którego bierzemy CRS zamiast
   własnych reguł.

   Vhosty pozostają nietknięte: renderuje je `30-render-bpp-vhosts.sh`
   własnym `envsubst` z jawną listą trzech zmiennych, niezależnie od
   mechanizmu szablonów obrazu.

   **2c. Własny `conf.d/default.conf` obrazu CRS.** Obraz dostarcza
   `templates/conf.d/default.conf.template` z własnym server blockiem. Po
   przeniesieniu mountu BPP (2a) plik BPP nadpisze go pod tą samą ścieżką
   wyjściową — to zachowanie **zamierzone**, ale musi być świadome i opisane,
   bo inaczej przy aktualizacji obrazu ktoś zobaczy „zniknął plik z obrazu".

   **2d. Kolejność `/docker-entrypoint.d/` — OK.** Obraz CRS ma własne skrypty
   `01`, `10`, `15`, `20-envsubst-on-templates.sh`, `30-tune-worker-processes.sh`
   oraz `90`–`95` (konfiguracja ModSecurity). Montowany przez BPP
   `30-render-bpp-vhosts.sh` wypada alfabetycznie **przed**
   `30-tune-worker-processes.sh` (`r` < `t`) i **po** `20-envsubst-on-templates.sh`,
   czyli dokładnie tam, gdzie trzeba. Przenumerowanie niepotrzebne — ale warto
   dopisać komentarz, bo to zbieg okoliczności, nie gwarancja.
3. **Limit ciała żądania — 12,5 MiB.** Domyślny `MODSEC_REQ_BODY_LIMIT` to
   `13107200` bajtów. Odbije importy POLON/PBN/XLSX większe niż to, mimo że
   nginx przepuszcza do `client_max_body_size 120M`. **To najgroźniejszy punkt
   tej zmiany** — awaria byłaby cicha z punktu widzenia użytkownika
   („import nie działa") i ujawniłaby się dopiero przy dużym pliku, więc już
   po wdrożeniu.
4. **Limit pól formularza — 128 KiB.** Domyślny `MODSEC_REQ_BODY_NOFILES_LIMIT`
   to `131072` bajtów, czyli **ośmiokrotnie mniej, niż wynikałoby z intuicji**.
   Produkcja dopuszcza `DATA_UPLOAD_MAX_NUMBER_FIELDS = 50000`
   (`bpp/src/django_bpp/settings/production.py:106`), więc masowa edycja
   przekroczy ten limit.
5. **`dbtemplates`** (`bpp/src/django_bpp/settings/base.py:508`). Superuser
   edytuje szablony **HTML** w panelu admina, czyli POST-uje surowy HTML z
   JavaScriptem. To kanoniczny przypadek fałszywego alarmu opisany w
   dokumentacji CRS — rodzina **941 (XSS)** zapali się na pewno. Wymaga
   wykluczenia zawężonego do ścieżki admina `dbtemplates`.
6. **DjangoQL** (`/api/v1/zapytanie/rekord`, `…/autor`, `…/autorzy` —
   `bpp/src/api_v1/urls.py:112-116`). Użytkownik wysyła składnię zapytań, która
   z definicji przypomina SQL. Rodzina **942** zapali się na tym. Wykluczenie
   zawężone do tych trzech ścieżek.
7. **`/healthz`.** Healthcheck Dockera (`docker-compose.infrastructure.yml:21`)
   idzie przez nginksa. Ma `access_log off`, ale ModSecurity nadal go
   przetworzy — upewnić się, że nie generuje szumu w audit logu.

## Uruchomienie (kolejność)

1. **Faza 0** lokalnie: podmiana obrazu, `nginx -t`, weryfikacja HTTP/3 i
   montowanych konfiguracji. Bramka — bez tego nie ma sensu iść dalej.
2. **Faza 1, noga 3:** publiczny staging przełączony w `DetectionOnly` i
   zostawiony. Robimy to **najwcześniej**, bo jako jedyna noga zbiera dane
   z upływem czasu — im wcześniej ruszy, tym więcej zdąży zebrać, zanim
   będzie potrzebna.
3. **Faza 1, noga 1:** eksport 30 dni logu z Loki (produkcja o największym
   ruchu — `bpp.apoz.edu.pl` albo `publikacje.up.lublin.pl`), odtworzenie
   przeciwko drugiemu, niepublicznemu stagingowi.
4. **Faza 1, noga 2:** scenariusze POST przeciwko niepublicznemu stagingowi.
5. **Faza 2:** wykluczenia wynikające z nóg 1–3, `On` na stagingu, potem
   produkcja — instalacja po instalacji, nie wszystkie naraz.
6. **Rollback na każdym etapie:** przywrócenie `image: nginx:1.30.2`.
   Konfiguracja nginksa jest montowana wolumenami i nie wymaga zmian, więc
   cofnięcie to jedna linia w compose plus `make run`.

## Testy

**Materiał testowy jest realny — ale ma termin ważności.**

*Zestaw pozytywny* (ma być blokowany): 2 165 przechwyconych payloadów z 13, 23
i 27.07 — klasy `UNION ALL SELECT`, `UPDATEXML`, `EXTRACTVALUE`, error-based
`SELECT…FROM(SELECT COUNT(*)`, sondy `ORDER BY n-- -`.

⚠️ **Wyciągnąć i zapisać jako fixture przed 12.08.2026.** Payloady pochodzą
z Rollbara (`GET /api/1/instances`, stronicowane), a **retencja Rollbara to
30 dni** — dane z 13.07 przepadną około 12.08, z 27.07 około 26.08. Po tym
terminie zestawu pozytywnego nie da się już odtworzyć.

*Zestaw negatywny* (ma przechodzić): 30 dni logu dostępowego z Loki, patrz
Faza 1 noga 1. Tu terminu nie ma — retencja Loki przesuwa się razem z ruchem,
ale zawsze obejmuje ostatnie 30 dni.

Musi **przechodzić** (regresja na legalnym ruchu):

- eksport raportu we wszystkich formatach: `?_export=html|xlsx|docx&_tzju=…&sort=…`
- import pliku **większego niż 12,5 MiB** (POLON/PBN) — próg domyślnego
  `MODSEC_REQ_BODY_LIMIT`
- zapis szablonu HTML w adminie `dbtemplates`
- zapytanie DjangoQL przez `/api/v1/zapytanie/rekord`
- wyszukiwanie tekstem zawierającym angielskie słowa kolidujące z sygnaturami
  SQL — np. „Select topics from organic chemistry", „Selected papers from the
  conference"
- multiseek: `/multiseek/`, `/multiseek/results/`, `/multiseek/do-djangoql/`
- HTTP/3: wymuszone połączenie h3

Musi **być blokowane**: dowolna próbka z zestawu pozytywnego.

## Świadomie pominięte (YAGNI)

- **Reguły dla stosów, których nie ma w ścieżce żądania**: Log4Shell/JNDI,
  deserializacja Javy, NoSQL (`$ne`, `$where`), LDAP. Każda reguła kosztuje
  latencję i ryzyko fałszywego alarmu.
- **Własny `map $args`** — zastąpiony przez CRS 942.
- **Warstwa Django** — brak zmian w repozytorium `bpp`.
- **Reguła wyciszająca 404 od botów w Rollbarze.** Zostaje 1 914 zdarzeń szumu
  od Artemisa i botów wyszukiwarek. Osobny temat, poza zakresem: CRS ich nie
  dotyczy, bo te URL-e wyglądają całkowicie normalnie i nginx nie wie z góry,
  że skończą się 404.
- **Naprawa 520 martwych URL-i widzianych przez wyszukiwarki** (przekierowania
  301 po zmianie sluga autora/jednostki). Osobny temat w repozytorium `bpp`.

## Załącznik: klasy ataków a rodziny reguł CRS

Katalog na przyszłość — co jest pokryte przez CRS i czego wobec tego **nie**
trzeba pisać ręcznie.

| Klasa | Sygnatury | CRS | Znaczenie dla BPP |
|---|---|---|---|
| SQL injection | `union+select`, `updatexml(`, `extractvalue(`, `sleep(`, `benchmark(`, `information_schema`, `/*!50000`, `ORDER BY n-- -` | 942 | **udowodnione** — 2 165 trafień |
| Path traversal / LFI | `../`, `%2e%2e`, `/etc/passwd`, `/etc/shadow`, `/proc/self/environ`, `php://filter` | 930 | tanie ubezpieczenie |
| RCE / command injection | `wget`, `curl`, `nmap`, `ping -c`, `nc -e`, `/bin/sh`, `python -c`, backtick, `$(…)`, `;`, `&&` | 932 | tanie ubezpieczenie |
| XSS | `<script`, `javascript:`, `onerror=`, `onload=`, `<svg`, `<iframe` | 941 | uwaga na `dbtemplates` |
| SSTI / szablony | `{{7*7}}`, `${…}`, `<%= %>` | 934 | w repo istnieje już degenerat tej reguły: blok `{{clickURL}}` w `_bpp-locations.conf` |
| SSRF | `file://`, `gopher://`, `dict://`, `169.254.169.254` | 934 | niskie |
| Skanery po UA | `sqlmap`, `nikto`, `nmap`, `masscan`, `nuclei`, `gobuster` | 913 | **niskie** — obserwowany skan rotował UA |
| Log4Shell, deserializacja Javy, NoSQL, LDAP | — | 944 / 942 | **pomijamy** — brak Javy, Mongo i LDAP-a w ścieżce żądania |

Uwaga do pomysłu blokowania po **nazwie parametru** (np. `update=`): odradzane.
Nazwa parametru sama w sobie nie jest sygnaturą ataku, a łatwo trafić we własny
kod. Wartościowy wariant tej intuicji to parametry podnoszenia uprawnień w GET
(`is_superuser=`, `is_staff=`, `user_id=`), ale przy poprawnych formularzach
Django zysk jest niski. `next=` jest już obsłużone przez `_check_nested_next`
w `bpp.middleware`.

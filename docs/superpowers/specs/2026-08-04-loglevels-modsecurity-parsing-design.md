# Porządek w `detected_level` + parsowanie ModSecurity z error.log

Data: 2026-08-04

## Problem

### 1. Bałagan w wartościach `detected_level`

Dropdown „Log Level" w Grafanie pokazuje dziewięć wartości:

```
critical, debug, error, fatal, info, securitywarning, trace, warn, warning
```

To nie jest jedno brudne pole, tylko **suma dwóch niezależnych detektorów piszących
pod tę samą nazwę**:

| Źródło | Słownik |
|---|---|
| Loki 3.x, `discover_log_levels` (domyślnie **włączone**) | `trace, debug, info, warn, error, fatal, critical, unknown` |
| `defaults/alloy/config.alloy` (stream label) | `info, warning, error, debug, critical` + przeciek `securitywarning` |

Suma tych zbiorów to dokładnie obserwowana lista — `fatal` i `trace` potrafi
wyprodukować wyłącznie Loki, `warning` i `securitywarning` wyłącznie Alloy.
Zero wartości spoza sumy.

Potwierdzenie u źródła (`loki:3.7.1 -help`):

```
-validation.discover-log-levels
      Discover and add log levels during ingestion, if not present already.
      (...) one of the values from 'trace', 'debug', 'info', 'warn', 'error',
      'critical', 'fatal' (case insensitive). (default true)
```

Drugim objawem tej samej przyczyny jest `detected_level_extracted=error`
w szczegółach linii: gdy stream label i structured metadata mają identyczną
nazwę, Loki dokleja jednej z nich sufiks `_extracted`. Trzecim — label
`service_name=webserver`, którego nikt nie ustawia w `config.alloy`: to
bliźniacza funkcja `discover_service_name`, duplikująca nasz label `service`.

### 2. Kaskada detekcji poziomu w Alloy jest ułożona odwrotnie

W `loki.process "log_levels"` kolejne `stage.regex` **nadpisują** wynik
poprzednich — obowiązuje „ostatni wygrywa". Plik jest natomiast ułożony od
najbardziej do najmniej wiarygodnego detektora, czyli dokładnie odwrotnie do
tego, jak działa.

Skutek praktyczny: `stage.regex` z linii 64 (`\b(TRACE|DEBUG|…|ERROR|…)\b`
gdziekolwiek w linii) przykrywa wszystkie precyzyjne reguły powyżej i nadaje
`detected_level=error` linii access logu postaci `GET /jakas-error-page`.

### 3. Zmiany w `config.alloy` nigdy nie docierają na istniejące instalacje

`scripts/ensure-config-files.sh:89` kopiuje `defaults/alloy/config.alloy` przez
`copy_if_missing`. Plik jest bind-mountowany z `$BPP_CONFIGS_DIR`, więc na
każdej instalacji starszej niż jej własny `init-configs` leży wersja z
pierwszego commitu.

Konkretnie: commit `60ea290`, który dodał mapowanie severity CRS → poziom logu
i który `docs/architektura/waf.md` opisuje jako działający, **nie istnieje na
żadnym istniejącym wdrożeniu**. Bez naprawy tego punktu cała reszta tej pracy
również by nie dojechała.

### 4. Trafienia ModSecurity z error.log są nieparsowane

Linie takie jak poniższa trafiają do Loki jako goły tekst — jedyne, co z nich
wyciągamy, to `detected_level=error` z nginksowego `[error]`:

```
2026/08/03 22:08:14 [error] 566#566: *3 [client 78.30.111.25] ModSecurity:
Access denied with code 403 (phase 2). (...) [file "(...)REQUEST-949-BLOCKING-EVALUATION.conf"]
[line "222"] [id "949110"] [msg "Inbound Anomaly Score Exceeded (Total Score: 10)"]
[severity "0"] [ver "OWASP_CRS/4.28.0"] [tag "modsecurity"] [tag "anomaly-evaluation"]
[tag "OWASP_CRS"] [hostname "publikacje-test.up.lublin.pl"] [uri "/"]
[unique_id "17857948943.999347"] (...) request: "GET /?get=/etc/passwd HTTP/2.0"
```

Cała struktura (reguła, komunikat, severity, tagi CRS, URI, IP, anomaly score)
jest w linii obecna i nadaje się do agregacji, ale nie da się po niej filtrować
ani grupować bez ręcznego regexa w każdym zapytaniu.

Istniejący `stage.match` po `ModSecurity-nginx` obsługuje **inny** format —
JSON-owy audit log — i tylko po to, by wyliczyć poziom logu.

## Rozwiązanie

### A. `config.alloy` na force-sync

`scripts/ensure-config-files.sh:89` → `copy_always`.

Uzasadnienie jest identyczne jak przy `datasources.yaml.tpl`: to wersjonowany
artefakt, którego operator nie stroi ręcznie. W przeciwieństwie do
`netdata.conf` nie ma w nim żadnych knobów opisanych w dokumentacji jako
przeznaczone do edycji — wszystkie parametry strojenia siedzą w `.env`.

`defaults/loki/local-config.yaml` **zostaje** `copy_if_missing`: trzyma politykę
retencji per-stream, którą operator ma prawo dostosować do swojego dysku.
Dlatego punkt B nie może polegać na edycji tego pliku.

Do zaktualizowania: lista force-synced plików w `CLAUDE.md` oraz
`docs/monitoring/logowanie.md`.

### B. Wyłączenie detekcji Loki — flagą CLI, nie configiem

W `docker-compose.monitoring.yml`, w `command:` serwisu `loki`:

```
-validation.discover-log-levels=false
```

Plik compose jest wersjonowany i bind-mountowany z repo, więc zmiana dociera
przez `git pull && make up` **bez migracji `.env` i bez dotykania pliku
konfiguracyjnego użytkownika**.

Uwaga na kolejność pierwszeństwa: w Loki (dziedzictwo Cortexa) flagi CLI są
rejestrowane jako wartości domyślne struktury konfiguracyjnej, a plik YAML jest
na nią unmarshalowany — czyli **YAML wygrywa, ale tylko dla kluczy w nim
obecnych**. Istniejące `local-config.yaml` nie zawiera `discover_log_levels`,
więc wartość z flagi przetrwa. Dla świeżych instalacji dopisujemy klucz jawnie
do `defaults/loki/local-config.yaml` (walor dokumentacyjny; zgodny z flagą).

Analogicznie sprawdzamy, czy da się uciszyć `discover_service_name`
(`-validation.discover-service-name`), który dokleja zbędny `service_name`
duplikujący nasz `service`. Jeśli flaga nie przyjmuje pustej listy — punkt
odpada, bez wpływu na resztę.

### C. Przebudowa detekcji poziomu w Alloy

Zamiast łatania kolejnym `stage.replace`, zmiana struktury:

1. **Każdy detektor pisze do własnego klucza** — `lvl_json`, `lvl_kv`, `lvl_py`,
   `lvl_bracket`, `lvl_pywarn`, `lvl_any`, `lvl_modsec_json`, `lvl_modsec_err`.
   Żaden nie może już przykryć wyniku innego.
2. **Jedna bramka** `stage.template` wybiera pierwszy niepusty klucz w kolejności
   zaufania (od najbardziej precyzyjnego) i w tym samym kroku mapuje wynik na
   zamknięty słownik.
3. Wszystko, co nie należy do słownika, staje się `unknown`.

Słownik docelowy — **`critical, error, warn, info, debug, trace, unknown`**;
`warning` → `warn`, `fatal` → `critical`, `*Warning` (`SecurityWarning`,
`DeprecationWarning`, …) → `warn`.

Przeciek w rodzaju `securitywarning` przestaje być możliwy z definicji: nie
istnieje ścieżka, którą wartość spoza słownika trafiłaby na label.

`detected_level` **zostaje stream labelem**. Dzięki temu `error-monitoring.json`
działa bez żadnych zmian — jego selektory (`{job="docker", detected_level=~"$level"}`)
i zmienna `$level` (`label_values(detected_level)`) pozostają poprawne. Dropdown
sam się wyczyści, gdy dane sprzed zmiany wyjdą poza retencję (30 dni dla
większości serwisów, 180 dla `webserver`).

### D. Parsing trafień ModSecurity z error.log

Nowy `stage.match` z selektorem celującym w linie tekstowe error.log, a nie
w JSON-owy audit log:

```
|~ "ModSecurity: (Access denied|Warning|Access allowed)"
```

Wyciągnięte pola trafiają do `stage.structured_metadata` — **nie** do stream
labeli. `modsec_uri`, `modsec_client` i `modsec_unique_id` jako stream labele
wysadziłyby kardynalność indeksu strumieni (każda para IP × URI = nowy strumień
na dysku). Structured metadata jest projektowane dokładnie pod ten przypadek:
filtrowalne i grupowalne w LogQL bez parsera, bez kosztu indeksu.

| Pole | Źródło w linii | Zastosowanie |
|---|---|---|
| `modsec_action` | `Access denied` / `Warning` | zablokowane vs tylko wykryte (reguły 10002/10003) |
| `modsec_rule_id` | `[id "…"]` | która reguła CRS |
| `modsec_msg` | `[msg "…"]` | opis reguły |
| `modsec_severity` | `[severity "…"]` | 0–7, skala sysloga |
| `modsec_attack` | `[tag "attack-sqli"]` → `sqli` | kategoria ataku, gotowa do `by()` |
| `modsec_tags` | wszystkie `[tag …]` → lista po przecinku | pełny kontekst CRS |
| `modsec_uri` | `[uri "…"]` | co atakowano |
| `modsec_client` | `[client …]` | kto atakował |
| `modsec_hostname` | `[hostname "…"]` | który vhost (istotne przy multi-host) |
| `modsec_unique_id` | `[unique_id "…"]` | spięcie linii error.log z wpisem audit logu |
| `modsec_score` | `Total Score: N` | anomaly score (obecny przy 949110) |

Wszystkie wzorce zweryfikowane na prawdziwej linii z produkcji, łącznie ze
zwijaniem powtarzalnego `[tag …]` do `modsecurity,anomaly-evaluation,OWASP_CRS`
(Go RE2 nie potrafi przechwycić powtórzeń grupy, więc łapiemy cały ciąg tagów
jednym regexem i normalizujemy go w `stage.template` przez `regexReplaceAll`).

`request:` z pełnym query stringiem (czyli payloadem ataku) **nie** trafia do
structured metadata — zostaje w treści linii, dostępny w razie potrzeby przy
zapytaniu. Nie ma potrzeby duplikować go do pola indeksowanego.

**Poziom logu dla tych linii: `warn`** — niezależnie od severity reguły.

Uzasadnienie jest tą samą decyzją, która już zapadła przy `limit_req_log_level warn`
(patrz `CLAUDE.md`, sekcja rate limiting): powódź zdarzeń bezpieczeństwa nie ma
zalewać dashboardu błędów aplikacji. Skan z lipca 2026 to 2165 żądań z 1342
adresów IP; nginx loguje **każde** trafienie reguły jako `[error]`, więc jeden
skaner potrafi wygenerować tysiące linii `error` i pomalować error-monitoring na
czerwono, mimo że aplikacja działa bez zarzutu.

Odrzucono mapowanie po severity CRS (jak dla audit logu JSON): reguła 949110,
obecna przy **każdej** blokadzie, ma `[severity "0"]`, czyli EMERGENCY — każdy
zablokowany skan generowałby lawinę `critical`. Byłoby gorzej niż teraz.

Trafienia WAF nie znikają z pola widzenia — dostają własny dashboard (punkt E).

### E. Dashboard `defaults/grafana/provisioning/dashboards/waf.json`

Nowy provisioned dashboard. `dashboards/*` jest już objęte `copy_always`
(glob w `ensure-config-files.sh:97`), więc force-sync działa bez żadnej zmiany
w skrypcie.

Panele:

1. Rząd statystyk: trafienia łącznie, zablokowane, unikalne IP, unikalne reguły
2. Oś czasu trafień z podziałem po `modsec_action` (denied / detected)
3. Top reguły — `modsec_rule_id` + `modsec_msg`
4. Top atakujące adresy IP — `modsec_client`
5. Top atakowane URI — `modsec_uri`
6. Rozbicie po kategorii ataku — `modsec_attack`
7. Rozkład anomaly score — `modsec_score`
8. Tabela ostatnich trafień

Zmienne szablonu: vhost (`modsec_hostname`), akcja (`modsec_action`), minimalna
severity.

### F. Test — `make test-alloy`

W stylu istniejącego `make test-waf`: uruchamiamy **prawdziwy** `config.alloy`
w kontenerze Alloy, podmieniając tylko dwa końce pipeline'u:

- wejście: `loki.source.file` czytający plik z próbkami zamiast `loki.source.docker`
- wyjście: `loki.echo` zamiast `loki.write` — komponent wypisuje wpisy wraz
  z labelami i structured metadata na stdout, więc asercje można robić
  bez stawiania Loki

Zestaw golden-linii i oczekiwań:

| Próbka | Oczekiwanie |
|---|---|
| Linia ModSecurity z produkcji (949110) | `detected_level=warn`, `modsec_rule_id=949110`, `modsec_action=denied`, `modsec_score=10`, `modsec_tags` = 3 tagi |
| Linia ModSecurity dla reguły ataku (942xxx) | `modsec_attack=sqli` |
| Log JSON z `level` | poziom z JSON-a, nie z treści |
| Log Pythona z `SecurityWarning` | `detected_level=warn` (regresja na przeciek) |
| Access log `GET /jakas-error-page` | **nie** `error` (regresja na błąd z punktu C) |
| Linia bez rozpoznawalnego poziomu | `unknown` |

Cel `test-alloy` trafia do `mk/misc.mk` obok `test-waf` (plik jest includowany
w `Makefile:73` — sprawdzone).

> Uwaga przy uruchamianiu testu na maszynie deweloperskiej: bez repo-owego
> `.env` Makefile wchodzi w gałąź `FIRST_RUN` i wystawia **wyłącznie** cel
> `setup` — `make test-alloy` zgłosi wtedy „No rule to make target". Skrypt
> testowy musi dać się uruchomić także bezpośrednio (`./scripts/test-alloy.sh`),
> tak jak `test-waf.sh`, i nie może wymagać `.env` ani działającej instalacji.

## Zakres zmian

| Plik | Zmiana |
|---|---|
| `scripts/ensure-config-files.sh` | `config.alloy` → `copy_always` |
| `docker-compose.monitoring.yml` | flaga `-validation.discover-log-levels=false` |
| `defaults/loki/local-config.yaml` | jawny `discover_log_levels: false` (świeże instalacje) |
| `defaults/alloy/config.alloy` | przebudowa kaskady poziomów + parsing ModSecurity |
| `defaults/grafana/provisioning/dashboards/waf.json` | nowy dashboard |
| `mk/misc.mk` | cel `test-alloy` |
| `scripts/test-alloy.sh` | nowy skrypt testowy (uruchamialny też bezpośrednio) |
| `tests/` | fixture z golden-liniami |
| `docs/architektura/waf.md` | sekcja o parsowanych polach i dashboardzie |
| `docs/monitoring/logowanie.md` | słownik `detected_level`, force-sync `config.alloy` |
| `docs/monitoring/dashboardy-grafany.md` | opis dashboardu WAF |
| `CLAUDE.md` | `config.alloy` na liście force-synced; słownik poziomów |

## Kompatybilność wstecz

Kontrakt z `CLAUDE.md`: nowa wersja musi wstać na starym `.env` bez ręcznej
edycji. Ta zmiana **nie dodaje ani nie zmienia żadnej zmiennej `.env`** —
cała konfiguracja jedzie przez pliki wersjonowane w repo (compose, defaults),
więc `git pull && make up` wystarcza.

Ryzyko do odnotowania: przejście `config.alloy` na `copy_always` **nadpisze
ręczne modyfikacje**, jeśli jakiś operator takowe poczynił. Plik nigdy nie był
udokumentowany jako przeznaczony do edycji, a alternatywa (pozostawienie
`copy_if_missing`) oznacza, że żadna poprawka pipeline'u logów nigdy nie dotrze
na wdrożenie — co jest gorsze i już się zmaterializowało przy commicie `60ea290`.

Stare dane w Loki zachowają poprzednie wartości `detected_level` aż do wygaśnięcia
retencji. Dropdown „Log Level" wyczyści się stopniowo — po 30 dniach dla
większości serwisów, po 180 dniach dla `webserver`. To zachowanie oczekiwane,
nie wymaga kasowania danych.

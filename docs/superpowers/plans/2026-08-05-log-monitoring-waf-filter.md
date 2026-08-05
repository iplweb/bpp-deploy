# Filtr ModSecurity na dashboardzie „Log Monitoring" — plan implementacji

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dodać do dashboardu „Log Monitoring" trójstanową zmienną `ModSecurity`
(wszystko / tylko WAF / bez WAF), która filtruje wszystkie trzy panele po polu
structured metadata `modsec_src`.

**Architecture:** Zmienna typu `custom`, której **wartością jest fragment potoku
LogQL**, wstrzykiwany jako `${waf:raw}` bezpośrednio za selektorem strumienia
w zapytaniu każdego panelu. Zmiana jest jednoplikowa (JSON dashboardu), dociera na
istniejące instalacje przez force-sync (`copy_always`), nie dotyka `.env` — więc
nie wymaga żadnej migracji ani kroku ręcznego operatora.

**Tech Stack:** Grafana 12.4.2 (dashboard provisioned z JSON-a), Loki 3.7.1
(LogQL, structured metadata), bash + grep (testy regresyjne), MkDocs Material (docs).

**Spec:** `docs/superpowers/specs/2026-08-05-log-monitoring-waf-filter-design.md`

## Global Constraints

- **Wersje**: Loki `3.7.1`, Grafana `12.4.2` — dokładnie te tagi co produkcja
  (`docker-compose.monitoring.yml:30` i `:80`). Test empiryczny musi jechać na
  tym samym tagu Loki, inaczej niczego nie dowodzi.
- **Vocabulary `modsec_src`**: zamknięty zbiór dwóch wartości — `audit`
  (wpis JSON audit logu) i `nginx` (czytelna linia error.log). Producent:
  `defaults/alloy/config.alloy` (`stage.template` w liniach 190–193 i 306–309).
- **Wartości opcji zmiennej** — dokładnie te trzy stringi, bajt w bajt:
  - `| modsec_src=~".*"` (tekst opcji: `wszystko`)
  - `| modsec_src="nginx"` (tekst opcji: `tylko WAF`)
  - `| modsec_src=""` (tekst opcji: `bez WAF`)
- **Żadna opcja nie może mieć pustej wartości** — Grafana nie sparsuje takiej
  opcji i do zapytania trafi dosłowny tekst opcji, psując wszystkie trzy panele.
- **Interpolacja tylko przez `${waf:raw}`**, nigdy `$waf` — `:raw` wyłącza
  regex-escapowanie datasource'a Loki, które po ewentualnym włączeniu
  „Multi-value" w UI zamieniłoby `.*` na `\.\*`.
- **Domyślny stan to `wszystko`** — zero zmiany zachowania dla istniejących
  instalacji po `git pull && make up`.
- **Nie dotykamy `.env`, `.env.sample`, Compose'a ani `config.alloy`.** Ta zmiana
  celowo nie wprowadza żadnej nowej zmiennej środowiskowej.
- **Język**: komentarze w kodzie i testach — polski bez polskich znaków
  diakrytycznych (konwencja `tests/test_makefile.sh` i `config.alloy`);
  dokumentacja w `docs/` — polski z diakrytykami.

## Warunek wstępny (blokujący Task 1)

W drzewie roboczym siedzi **niezacommitowana praca z innej sesji** dotykająca
m.in. `tests/test_makefile.sh`, `docs/architektura/waf.md`,
`docs/monitoring/dashboardy-grafany.md` i `defaults/grafana/provisioning/dashboards/waf.json`
— ta sama trójka plików, którą modyfikuje ten plan.

**Nie zaczynaj, dopóki `git status --short` nie jest czyste.** Poza konfliktami
w plikach chodzi o semantykę: tamta zmiana ustawia
`MODSEC_AUDIT_LOG_RELEVANT_STATUS: ^$`, po której zbiór „linie z `modsec_src`"
pokrywa się ze zbiorem „linie, na których zapaliła się reguła". Bez niej stan
„bez WAF" wycinałby także 401 z `auth_request`, 429 z `limit_req` i 5xx
z leżącego appservera — czyli ruch, którego WAF nawet nie dotknął.

Sprawdź:

```bash
cd /Volumes/SSD/Programowanie/bpp-deploy
git status --short
grep -n 'MODSEC_AUDIT_LOG_RELEVANT_STATUS' docker-compose.infrastructure.yml
```

Oczekiwane: `git status --short` nic nie wypisuje, a grep znajduje linię
`MODSEC_AUDIT_LOG_RELEVANT_STATUS: "${MODSEC_AUDIT_LOG_RELEVANT_STATUS:-^$$}"`.
Jeśli drzewo jest brudne — **zatrzymaj się i zapytaj**.

## File Structure

| Plik | Rola w tej zmianie |
|---|---|
| `defaults/grafana/provisioning/dashboards/error-monitoring.json` | **Modyfikowany.** Jedyny plik produkcyjny. Dochodzi czwarta zmienna + fragment `${waf:raw}` w 3 zapytaniach + `&var-waf=…` w 2 data linkach. |
| `tests/test_makefile.sh` | **Modyfikowany.** Nowa funkcja `test_log_monitoring_waf_filter` + wpis na liście wywołań. Chroni kontrakt „fragment w każdym panelu". |
| `docs/monitoring/dashboardy-grafany.md` | **Modyfikowany.** Sekcja „Error Monitoring" → „Log Monitoring" (dryf nazwy) + opis nowej zmiennej. |
| `docs/architektura/waf.md` | **Modyfikowany.** Korekta zdania w linii 293, które po tej zmianie staje się nieprawdziwe. |
| `docs/superpowers/specs/2026-08-05-…-design.md` | **Modyfikowany w Task 1** — dopisujemy wynik weryfikacji empirycznej. |
| *(brak)* | Skrypt sondy Loki jest **jednorazowy i nie trafia do repo** — to weryfikacja założenia, nie narzędzie do utrzymywania. |

---

### Task 1: Weryfikacja empiryczna semantyki `modsec_src` w LogQL

Cały projekt stoi na założeniu, że **brakująca structured metadata zachowuje się
w LogQL jak pusty string**. Poszlaki w repo są mocne (`waf.json` produkcyjnie
używa `| modsec_attack != ""`, żeby odsiać wpisy bez pola), ale to nadal poszlaki.
Ten task zamienia je w dowód albo obala projekt, zanim ktokolwiek dotknie
dashboardu.

**Files:**
- Modify: `docs/superpowers/specs/2026-08-05-log-monitoring-waf-filter-design.md` (sekcja „Założenie do weryfikacji empirycznej")
- Scratch (poza repo): `/private/tmp/claude-501/-Volumes-SSD-Programowanie-bpp-deploy/*/scratchpad/loki-probe.sh`

**Interfaces:**
- Consumes: nic
- Produces: rozstrzygnięcie „idziemy dalej / projekt do przemyślenia" oraz
  zdanie z wynikiem dopisane do spec-a

- [ ] **Step 1: Podnieś jednorazową Loki 3.7.1**

```bash
docker run -d --name loki-probe -p 3199:3100 grafana/loki:3.7.1
sleep 15
curl -s http://localhost:3199/ready
```

Oczekiwane: `ready`. Jeśli przez ~60 s zwraca `Ingester not ready`, poczekaj
i powtórz — Loki potrzebuje chwili na inicjalizację WAL.

- [ ] **Step 2: Wypchnij dwie linie — jedną ze structured metadata, jedną bez**

Timestamp musi być w nanosekundach i „świeży". `date +%s%N` **nie działa na
macOS** (brak `%N`), więc generujemy go Pythonem.

```bash
python3 - <<'PY'
import json, time, urllib.request

ns = str(time.time_ns())
payload = {
  "streams": [
    {
      # Linia WAF-a: ma structured metadata modsec_src
      "stream": {"job": "probe", "service": "webserver"},
      "values": [[ns, "ModSecurity: Access denied with code 403",
                  {"modsec_src": "nginx", "modsec_rule_id": "949110"}]],
    },
    {
      # Linia aplikacji: NIE ma klucza modsec_src w ogole
      "stream": {"job": "probe", "service": "appserver"},
      "values": [[ns, "Django ERROR cos sie posypalo"]],
    },
  ]
}
req = urllib.request.Request(
    "http://localhost:3199/loki/api/v1/push",
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"},
)
print(urllib.request.urlopen(req).status)
PY
```

Oczekiwane: `204`.

- [ ] **Step 3: Odpytaj trzema wariantami filtra i policz linie**

```bash
python3 - <<'PY'
import json, time, urllib.parse, urllib.request

now = time.time_ns()
start, end = str(now - 3_600_000_000_000), str(now + 60_000_000_000)

CASES = [
    ('wszystko',  '{job="probe"} | modsec_src=~".*"',   2),
    ('tylko WAF', '{job="probe"} | modsec_src="nginx"', 1),
    ('bez WAF',   '{job="probe"} | modsec_src=""',      1),
]

ok = True
for name, q, expected in CASES:
    url = "http://localhost:3199/loki/api/v1/query_range?" + urllib.parse.urlencode(
        {"query": q, "start": start, "end": end, "limit": "100"})
    data = json.load(urllib.request.urlopen(url))
    got = sum(len(s["values"]) for s in data["data"]["result"])
    verdict = "OK" if got == expected else "NIEZGODNOSC"
    if got != expected:
        ok = False
    print(f"{verdict:12} {name:10} oczekiwano {expected}, dostano {got}   {q}")

print("\nWYNIK:", "zalozenie potwierdzone" if ok else "ZALOZENIE OBALONE")
PY
```

Oczekiwane wyjście — trzy linie `OK` i `WYNIK: zalozenie potwierdzone`.

Kluczowy jest **trzeci** przypadek: `modsec_src=""` musi zwrócić linię
appservera, która tego klucza w ogóle nie ma. Jeśli zwróci `0`, założenie jest
obalone → **zatrzymaj się, nie implementuj**, wróć do spec-a: stan „bez WAF"
trzeba by wtedy wyrazić inaczej (np. `| modsec_src!="nginx" | modsec_src!="audit"`,
co wymaga sprawdzenia, czy negacja na brakującym kluczu działa lepiej).

- [ ] **Step 4: Posprzątaj kontener**

```bash
docker rm -f loki-probe
```

- [ ] **Step 5: Zapisz wynik w spec-u i zacommituj**

W `docs/superpowers/specs/2026-08-05-log-monitoring-waf-filter-design.md`
zamień akapit zaczynający się od „Weryfikacja mimo to, bo cały projekt na tym
stoi:" na notatkę z wynikiem, w tym kształcie (podstaw realne liczby z Kroku 3):

```markdown
**Zweryfikowane empirycznie 2026-08-05** na `grafana/loki:3.7.1` (ten sam tag
co produkcja). Dwie linie wypchnięte przez `/loki/api/v1/push` — jedna ze
structured metadata `modsec_src="nginx"`, druga bez tego klucza — i trzy
zapytania przez `/loki/api/v1/query_range`:

| Filtr | Oczekiwano | Zwrócono |
|---|---|---|
| `\| modsec_src=~".*"` | 2 | 2 |
| `\| modsec_src="nginx"` | 1 | 1 |
| `\| modsec_src=""` | 1 | 1 |

Brakująca structured metadata faktycznie zachowuje się jak pusty string.
```

```bash
git add docs/superpowers/specs/2026-08-05-log-monitoring-waf-filter-design.md
git commit -m "docs(spec): potwierdzona empirycznie semantyka modsec_src w LogQL

Loki 3.7.1, push dwoch linii + trzy zapytania query_range. Brakujaca
structured metadata zachowuje sie jak pusty string, wiec stan 'bez WAF'
(| modsec_src=\"\") faktycznie lapie linie aplikacji."
```

---

### Task 2: Zmienna `waf` + fragment w trzech panelach (TDD)

Test najpierw: asercja opisuje kontrakt („fragment w **każdym** panelu"), więc
musi umieć zawieść, zanim dashboard się zmieni.

**Files:**
- Modify: `tests/test_makefile.sh` (nowa funkcja + wpis na liście wywołań ok. linii 1322)
- Modify: `defaults/grafana/provisioning/dashboards/error-monitoring.json`
  (zmienna: `templating.list`; zapytania: linie 344, 441, 500; data linki: linie 71, 375)

**Interfaces:**
- Consumes: potwierdzenie z Task 1, że `| modsec_src=""` łapie linie bez klucza
- Produces: zmienna dashboardu o nazwie `waf` z trzema opcjami; funkcja shellowa
  `test_log_monitoring_waf_filter` wywoływana z głównej listy testów

- [ ] **Step 1: Dopisz test regresyjny**

W `tests/test_makefile.sh`, **bezpośrednio po** funkcji `test_waf_audit_only_rules`
(kończy się ok. linii 436), wklej:

```bash
# ============================================================
# TEST: Log Monitoring — filtr ModSecurity we wszystkich panelach
# ============================================================

test_log_monitoring_waf_filter() {
    yellow "=== Test: Log Monitoring — filtr ModSecurity ==="

    local dash="$REPO_DIR/defaults/grafana/provisioning/dashboards/error-monitoring.json"

    # Fragment potoku musi byc w KAZDYM z trzech paneli. Eksport dashboardu
    # z UI Grafany po recznej edycji potrafi zgubic go z jednego — wtedy filtr
    # dziala "prawie", co jest gorsze, niz gdyby nie dzialal wcale.
    local n
    n="$(grep -cF '${waf:raw}' "$dash")"
    if [ "$n" -eq 3 ]; then
        pass "error-monitoring.json: filtr WAF-a we wszystkich 3 panelach"
    else
        fail "error-monitoring.json: filtr WAF-a w $n z 3 paneli"
    fi

    # Interpolacja MUSI byc przez :raw. Samo $waf przy wlaczonym multi-value
    # zamieniloby `.*` na `\.\*` — zapytanie zostaje skladniowo poprawne,
    # tylko przestaje cokolwiek zwracac. Cicha awaria.
    if grep -q '\$waf[^:]' "$dash"; then
        fail "error-monitoring.json: goly \$waf zamiast \${waf:raw}"
    else
        pass "error-monitoring.json: zmienna waf interpolowana przez :raw"
    fi

    assert_file_contains "zmienna waf istnieje" \
        '"name": "waf"' "$dash"

    # Trzy opcje, bajt w bajt. Zadna nie moze byc pusta — Grafana nie sparsuje
    # opcji `custom` bez wartosci i wstawi do zapytania sam tekst opcji.
    assert_file_contains "opcja 'wszystko' = no-op" \
        'modsec_src=~\\"\.\*\\"' "$dash"
    assert_file_contains "opcja 'tylko WAF' = linia error.log" \
        'modsec_src=\\"nginx\\"' "$dash"
    assert_file_contains "opcja 'bez WAF' = brak klucza" \
        'modsec_src=\\"\\"' "$dash"
}
```

Następnie dopisz wywołanie na listę testów — w bloku zaczynającym się od
`test_init_configs_generates_env` (ok. linii 1315), **bezpośrednio po**
`test_waf_audit_only_rules`:

```bash
test_log_monitoring_waf_filter
```

- [ ] **Step 2: Uruchom test i upewnij się, że zawodzi**

```bash
cd /Volumes/SSD/Programowanie/bpp-deploy
bash tests/test_makefile.sh 2>&1 | grep -A6 "Log Monitoring — filtr ModSecurity"
```

Oczekiwane: `FAIL: error-monitoring.json: filtr WAF-a w 0 z 3 paneli`
oraz `FAIL` na wszystkich czterech `assert_file_contains`. Test „interpolowana
przez :raw" **przejdzie** już teraz (nie ma żadnego `$waf`) — to normalne,
on pilnuje regresji, nie napędza implementacji.

- [ ] **Step 3: Dodaj zmienną do dashboardu**

W `defaults/grafana/provisioning/dashboards/error-monitoring.json`, w tablicy
`templating.list`, **po** zmiennej `level` (kończy się ok. linii 605), dopisz
czwarty element:

```json
{
  "type": "custom",
  "name": "waf",
  "label": "ModSecurity",
  "description": "\"tylko WAF\" pokazuje linie error.log, czyli zadania, na ktorych CRS przekroczyl prog anomalii — poziom warn, wiec przy Level=error wynik bedzie pusty. Trafienia podprogowe widac wylacznie na dashboardzie WAF.",
  "query": "wszystko : | modsec_src=~\".*\", tylko WAF : | modsec_src=\"nginx\", bez WAF : | modsec_src=\"\"",
  "options": [
    {
      "selected": true,
      "text": "wszystko",
      "value": "| modsec_src=~\".*\""
    },
    {
      "selected": false,
      "text": "tylko WAF",
      "value": "| modsec_src=\"nginx\""
    },
    {
      "selected": false,
      "text": "bez WAF",
      "value": "| modsec_src=\"\""
    }
  ],
  "includeAll": false,
  "multi": false,
  "current": {
    "text": "wszystko",
    "value": "| modsec_src=~\".*\""
  },
  "hide": 0,
  "skipUrlSync": false
}
```

- [ ] **Step 4: Wstrzyknij fragment do trzech zapytań**

Trzy pojedyncze podmiany. Fragment idzie **zawsze bezpośrednio za klamrą
zamykającą selektor strumienia**, przed nawiasem zakresu.

Linia 344 (`Log volume by level over time`) — było:

```
"expr": "sum(count_over_time({job=\"docker\", service=~\"$service\", container=~\"$container\", detected_level=~\"$level\"} [$__interval])) by (detected_level)",
```

ma być:

```
"expr": "sum(count_over_time({job=\"docker\", service=~\"$service\", container=~\"$container\", detected_level=~\"$level\"} ${waf:raw} [$__interval])) by (detected_level)",
```

Linia 441 (`By service`) — było:

```
"expr": "sum(count_over_time({job=\"docker\", container=~\"$container\", detected_level=~\"$level\"} [$__range])) by (service)",
```

ma być:

```
"expr": "sum(count_over_time({job=\"docker\", container=~\"$container\", detected_level=~\"$level\"} ${waf:raw} [$__range])) by (service)",
```

Linia 500 (`Logs`) — było:

```
"expr": "{job=\"docker\", service=~\"$service\", container=~\"$container\", detected_level=~\"$level\"}",
```

ma być:

```
"expr": "{job=\"docker\", service=~\"$service\", container=~\"$container\", detected_level=~\"$level\"} ${waf:raw}",
```

- [ ] **Step 5: Dopisz `var-waf` do dwóch data linków**

Bez tego klik w serię wykresu lub wiersz tabeli może zresetować filtr do
„wszystko" — zależnie od tego, czy Grafana scala query string, czy go podmienia.
Dopisanie jest bezpieczne w obu przypadkach (przy scalaniu to no-op).

Linia 71 — było `"url": "?var-level=${__field.labels.detected_level}"`, ma być:

```json
"url": "?var-level=${__field.labels.detected_level}&var-waf=${waf:percentencode}"
```

Linia 375 — było `"url": "?var-service=${__data.fields.service}"`, ma być:

```json
"url": "?var-service=${__data.fields.service}&var-waf=${waf:percentencode}"
```

- [ ] **Step 6: Sprawdź, że JSON jest nadal poprawny**

```bash
python3 -c "import json; d=json.load(open('defaults/grafana/provisioning/dashboards/error-monitoring.json')); print('OK, zmiennych:', len(d['templating']['list']))"
```

Oczekiwane: `OK, zmiennych: 4`.

- [ ] **Step 7: Uruchom test i upewnij się, że przechodzi**

```bash
bash tests/test_makefile.sh 2>&1 | grep -A7 "Log Monitoring — filtr ModSecurity"
```

Oczekiwane: sześć linii `PASS`, zero `FAIL`.

- [ ] **Step 8: Uruchom pełny zestaw, żeby nie zepsuć niczego obok**

```bash
bash tests/test_makefile.sh 2>&1 | tail -5
```

Oczekiwane: `RESULTS: N passed, 0 failed, …`. Jeśli coś padło, a nie dotyczy
`error-monitoring.json` — sprawdź, czy nie wróciły niezacommitowane zmiany
z innej sesji (warunek wstępny).

- [ ] **Step 9: Commit**

```bash
git add tests/test_makefile.sh defaults/grafana/provisioning/dashboards/error-monitoring.json
git commit -m "feat(grafana): filtr ModSecurity na dashboardzie Log Monitoring

Trojstanowa zmienna (wszystko / tylko WAF / bez WAF) wstrzykiwana jako
fragment potoku LogQL za selektorem strumienia we wszystkich trzech
panelach. Operator moze wreszcie albo wyizolowac trafienia WAF-a, albo
wyciszyc je, zeby zobaczyc realne bledy aplikacji — dotad nie mial na to
zadnego sposobu poza szukaniem pelnotekstowym.

Domyslnie 'wszystko', czyli no-op — zero zmiany zachowania po git pull.

Trzy szczegoly, ktore latwo zepsuc przy edycji:
- zadna opcja nie moze miec PUSTEJ wartosci (Grafana nie sparsuje opcji
  custom bez wartosci i wstawi do zapytania sam tekst opcji), dlatego
  stan neutralny to jawny no-op | modsec_src=~\".*\";
- interpolacja tylko przez \${waf:raw} — gole \$waf po wlaczeniu
  multi-value w UI zamieni .* na \\.\\* i zapytanie cicho przestanie
  cokolwiek zwracac;
- 'tylko WAF' to modsec_src=\"nginx\", a 'bez WAF' to modsec_src=\"\";
  asymetria jest zamierzona — filtr pozytywny musi wybrac jednego
  blizniaka, negatywny musi wyciac obu."
```

---

### Task 3: Synchronizacja dokumentacji

Dwie strony operatorskie mówią dziś rzeczy, które po Tasku 2 przestają być
prawdziwe. `CLAUDE.md` czyni utrzymanie docs zadaniem pierwszej klasy.

**Files:**
- Modify: `docs/monitoring/dashboardy-grafany.md:12-18`
- Modify: `docs/architektura/waf.md:290-293`

**Interfaces:**
- Consumes: zmienna `waf` z Task 2 (nazwa, etykieta `ModSecurity`, trzy stany)
- Produces: nic — to liść

- [ ] **Step 1: Popraw sekcję w `dashboardy-grafany.md`**

Sekcja nazywa się dziś „Error Monitoring", choć dashboard od dawna nosi tytuł
**„Log Monitoring"** (`error-monitoring.json:614`) — to zastany dryf, prostujemy
przy okazji. Zamień cały blok linii 12–18 na:

```markdown
### Log Monitoring

Wolumen logów w czasie z podziałem na poziom + tabela per serwer + przeglądarka
logów z Loki. Dropdowny `Service` / `Container` / `Log Level` filtrują wszystkie
panele; klik w serię na wykresie ustawia `var-level`, klik w wiersz tabeli —
`var-service` (data linki); drag-select po wykresie zawęża czas. Panel „Logs"
z `enableInfiniteScrolling`.

Czwarty dropdown, **`ModSecurity`**, izoluje albo wycisza trafienia WAF-a:

| Stan | Co pokazuje |
|---|---|
| `wszystko` | domyślny, bez filtrowania |
| `tylko WAF` | wyłącznie czytelne linie error.log ModSecurity |
| `bez WAF` | wszystko **poza** zdarzeniami WAF-a (znikają oba wpisy — JSON audit i linia error.log) |

`tylko WAF` pokazuje żądania, na których CRS przekroczył próg anomalii — te mają
poziom `warn`, więc przy `Log Level = error` wynik będzie pusty. Trafienia
podprogowe (reguła się zapaliła, ale próg nie został przekroczony) nie trafiają
do error.log i widać je wyłącznie na dashboardzie [WAF](#waf-modsecurity-owasp-crs).
```

- [ ] **Step 2: Popraw zdanie w `waf.md`**

Linie 290–293 mówią dziś, że bez własnych pól linię error.log „dałoby się
filtrować wyłącznie pełnotekstowo". Po Tasku 2 istnieje dropdown, więc zdanie
wprowadza w błąd. Zamień akapit zaczynający się od `**Oba wpisy dostają pola`
na:

```markdown
**Oba wpisy dostają pola `modsec_*`** — bo to na linię z error.log patrzy człowiek
w „Log Monitoring" (audit log to ściana JSON-a), a bez własnych pól dałoby się ją
filtrować wyłącznie pełnotekstowo. Te pola są dziś fundamentem dropdownu
**`ModSecurity`** na tamtym dashboardzie (`wszystko` / `tylko WAF` / `bez WAF`,
patrz [Dashboardy Grafany](../monitoring/dashboardy-grafany.md#log-monitoring)) —
`tylko WAF` to `modsec_src="nginx"`, a `bez WAF` to `modsec_src=""`, które łapie
linie bez tego klucza w ogóle. Rozróżnia je **`modsec_src`**:
```

- [ ] **Step 3: Zbuduj docs w trybie strict**

```bash
cd /Volumes/SSD/Programowanie/bpp-deploy
mkdocs build --strict 2>&1 | tail -20
```

Oczekiwane: build kończy się bez `WARNING`/`ERROR`. Najbardziej prawdopodobna
usterka to **martwa kotwica** — `validation.links.anchors: warn` w `mkdocs.yml`
sprawia, że literówka w `#log-monitoring` albo `#waf-modsecurity-owasp-crs`
wywali build. Kotwica jest generowana z nagłówka: małe litery, spacje →
myślniki, znaki `(`, `)`, `/` usuwane.

- [ ] **Step 4: Commit**

```bash
git add docs/monitoring/dashboardy-grafany.md docs/architektura/waf.md
git commit -m "docs: dropdown ModSecurity w Log Monitoring

Przy okazji prostuje zastany dryf nazwy — sekcja nazywala sie 'Error
Monitoring', a dashboard od dawna nosi tytul 'Log Monitoring'.

W waf.md zdanie o filtrowaniu 'wylacznie pelnotekstowo' przestalo byc
prawdziwe: pola modsec_* sa teraz fundamentem dropdownu."
```

---

## Self-Review

**Pokrycie spec-a:**

| Wymaganie ze spec-a | Task |
|---|---|
| Zmienna `custom` z trzema opcjami, `multi: false`, `includeAll: false` | 2, Step 3 |
| Zmaterializowane `options` + `description` | 2, Step 3 |
| Fragment `${waf:raw}` w trzech panelach | 2, Step 4 |
| Domyślnie „wszystko" | 2, Step 3 (`selected: true` + `current`) |
| Weryfikacja empiryczna na Loki 3.7.1 | 1 |
| `&var-waf=${waf:percentencode}` w data linkach | 2, Step 5 |
| Asercja regresyjna w `tests/test_makefile.sh` | 2, Steps 1–2 |
| Docs: `dashboardy-grafany.md` + `waf.md:293` | 3 |
| Zależność od `MODSEC_AUDIT_LOG_RELEVANT_STATUS` | Warunek wstępny |
| Wydajność (brak akcji — świadomie) | — |
| Poza zakresem: zmiana domyślnej opcji, link do dashboardu WAF, czwarta opcja | — |

Bez luk.

**Skan placeholderów:** brak „TBD"/„TODO"/„podobnie jak w Tasku N". Każdy krok
z kodem ma pełny kod, każdy krok weryfikacyjny ma komendę i oczekiwane wyjście.

**Spójność nazw:** `waf` (nazwa zmiennej) i `${waf:raw}` (interpolacja) —
identycznie w Taskach 2 i 3 oraz w asercjach testu. Trzy wartości opcji cytowane
bajt w bajt w Global Constraints, w Step 3 Taska 2 i w asercjach Step 1 —
sprawdzone znak po znaku. Nazwa funkcji testowej `test_log_monitoring_waf_filter`
identyczna w definicji (Step 1) i na liście wywołań (Step 1).

**Jedyne ryzyko rezydualne:** Task 1 może obalić założenie. Dlatego jest pierwszy
i ma jawną instrukcję „zatrzymaj się, nie implementuj".

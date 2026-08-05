# Filtr ModSecurity na dashboardzie „Log Monitoring"

Data: 2026-08-05

## Problem

Od czasu wdrożenia parsowania ModSecurity (`2026-08-04-loglevels-modsecurity-parsing-design.md`)
zdarzenia WAF-a mają komplet pól `modsec_*` i poziom `warn`, więc **normalnie
wpadają do dashboardu „Log Monitoring"** razem z resztą logów. Operator nie ma
tam żadnego sposobu, żeby:

- **wyizolować** same trafienia WAF-a (bez przełączania się na osobny dashboard), ani
- **wyciszyć** je, żeby zobaczyć realne błędy aplikacji.

Jest to szczególnie dotkliwe, bo **każde** żądanie zablokowane przez WAF-a
produkuje **dwie** linie w Loki (bliźniaki `audit` + `nginx`), z czego ta
pierwsza to ściana JSON-a.

Dashboard ma dziś trzy zmienne — `$service`, `$container`, `$level` — wszystkie
typu *query* po **etykietach strumienia**, wstrzykiwane do selektora
`{job="docker", …}`. Żadna z nich nie dosięga pól `modsec_*`.

## Rozwiązanie

Czwarta zmienna, `ModSecurity`, o trzech stanach, wstrzykiwana jako **fragment
potoku LogQL za selektorem strumienia** we wszystkich trzech panelach.

Plik: `defaults/grafana/provisioning/dashboards/error-monitoring.json`.
Dashboardy są **force-synced** (`copy_always` w `scripts/ensure-config-files.sh`),
więc zmiana dociera na istniejące instalacje przez `git pull && make up` — bez
migracji i bez kroku ręcznego.

### Definicja zmiennej

```json
{
  "type": "custom",
  "name": "waf",
  "label": "ModSecurity",
  "description": "„tylko WAF\" = linie error.log, czyli żądania, na których CRS przekroczył próg anomalii (poziom warn — przy Level=error wynik będzie pusty). Trafienia podprogowe widać wyłącznie na dashboardzie WAF.",
  "query": "wszystko : | modsec_src=~\".*\", tylko WAF : | modsec_src=\"nginx\", bez WAF : | modsec_src=\"\"",
  "options": [ /* zmaterializowane, z flagami `selected` — jak w waf.json */ ],
  "multi": false,
  "includeAll": false,
  "current": { "text": "wszystko", "value": "| modsec_src=~\".*\"" }
}
```

`options` materializujemy jawnie (nie licząc na wyprowadzenie ich z `query`), bo
tak wygląda wzorcowa zmienna `custom` w `waf.json` — provisioning jest wtedy
przewidywalny niezależnie od tego, jak dana wersja Grafany parsuje `query`.

| Opcja | Wartość | Efekt |
|---|---|---|
| `wszystko` | `\| modsec_src=~".*"` | no-op — stan domyślny, zero zmiany zachowania |
| `tylko WAF` | `\| modsec_src="nginx"` | wyłącznie czytelna linia error.log |
| `bez WAF` | `\| modsec_src=""` | znikają **oba** bliźniaki |

### Zapytania paneli

Fragment jako `${waf:raw}`, zawsze bezpośrednio za selektorem strumienia:

```logql
# Log volume by level over time
sum(count_over_time({job="docker", service=~"$service", container=~"$container",
    detected_level=~"$level"} ${waf:raw} [$__interval])) by (detected_level)

# By service (click to filter)
sum(count_over_time({job="docker", container=~"$container",
    detected_level=~"$level"} ${waf:raw} [$__range])) by (service)

# Logs
{job="docker", service=~"$service", container=~"$container",
 detected_level=~"$level"} ${waf:raw}
```

## Decyzje projektowe i ich uzasadnienia

### Dlaczego stan „wszystko" to `=~".*"`, a nie pusty fragment

Grafana parsuje opcje zmiennej typu `custom` regexem `^(.+)\s:\s(.+)$` — wartość
musi mieć **co najmniej jeden znak**. Przy pustej wartości dopasowanie nie
zachodzi, Grafana traktuje całą opcję jako parę tekst=wartość i do zapytania
trafia dosłowne `wszystko` → błąd składni LogQL we wszystkich trzech panelach.

Neutralny stan trzeba więc wyrazić jawnym no-opem. Efekt uboczny jest pożądany:
wszystkie trzy warianty mają identyczny kształt (`| modsec_src<operator><wartość>`),
więc podmiana jednej opcji nie zmienia struktury zapytania.

### Dlaczego `${waf:raw}`, a nie `$waf`

Loki datasource przepuszcza wartość zmiennej przez `interpolateQueryExpr`:

- zmienna **bez** `multi`/`includeAll` → `lokiRegularEscape` (escapuje wyłącznie `'`),
- zmienna **z** `multi`/`includeAll` → `lokiSpecialRegexEscape` (escapuje m.in. `.` i `*`).

Przy obecnej definicji (`multi: false`, `includeAll: false`) samo `$waf` by
zadziałało. Ale ktoś, kto kiedykolwiek włączy „Multi-value" w UI Grafany, cicho
zamieni `.*` na `\.\*` i rozwali stan „wszystko" — bez żadnego komunikatu błędu,
bo zapytanie pozostanie składniowo poprawne, tylko przestanie cokolwiek zwracać.
`:raw` wyłącza formatowanie datasource'a i jest odporne na tę pomyłkę.

(To samo dotyczy `allValue: ".*"` w `waf.json` — tam działa, bo Grafana opakowuje
wartość „All" w `CustomAllValue`, którą formattery pomijają. Zwykła opcja
zmiennej takiej ochrony nie ma.)

### Dlaczego „tylko WAF" ≠ negacja „bez WAF"

Asymetria (`="nginx"` vs `=""`) jest zamierzona i wynika z kontraktu bliźniaków:

- filtr **pozytywny** musi wybrać **jedno** źródło — `!=""` pokazałoby ścianę
  JSON-a obok czytelnej linii, czyli podwoiło szum zamiast go usunąć;
  `nginx` to ta wersja, na którą patrzy człowiek (tak samo jak panel
  „Ostatnie trafienia" w `waf.json`);
- filtr **negatywny** musi wyciąć **oba** — linia `audit` też ma `modsec_src`
  ≠ `""`, więc `modsec_src=""` usuwa jedno i drugie.

### Co „tylko WAF" pokazuje, a czego nie — i dlaczego to OK

`modsec_src="nginx"` to linie error.log, a tam trafiają **wyłącznie reguły
decyzyjne** (`949110`, `959100`). Konsekwencja: trafienie **podprogowe** —
reguła się zapaliła, ale anomaly score nie przekroczył progu — zostawia wpis
audit **bez bliźniaka nginx** i w stanie „tylko WAF" **jest niewidoczne**.

To jest akceptowalne i zamierzone: „Log Monitoring" ma odpowiadać na pytanie
„czy coś mi tu blokuje ruch", a nie „jaka jest pełna aktywność WAF-a" — od tego
drugiego jest dashboard `waf.json`. Alternatywa (`modsec_src!=""`) wpuściłaby
ścianę JSON-a, czyli dokładnie ten szum, który usuwamy. Ograniczenie musi być
jednak napisane w `description` zmiennej, żeby operator nie wziął pustego wyniku
za „nic się nie dzieje".

Symetrycznie: „bez WAF" (`modsec_src=""`) wycina **wszystkie** wpisy audit,
także te podprogowe.

!!! note "Zależność od równolegle wdrażanego `MODSEC_AUDIT_LOG_RELEVANT_STATUS`"
    W drzewie roboczym jest niezacommitowana zmiana ustawiająca
    `MODSEC_AUDIT_LOG_RELEVANT_STATUS: ^$`, dzięki której do audit logu przestają
    wpadać transakcje logowane *po kodzie statusu* (401 z `auth_request`, 429
    z `limit_req`, 5xx z leżącego appservera — wpisy z `"messages":[]`).
    Bez tej zmiany „bez WAF" wycinałoby także te wpisy, czyli ruch, którego WAF
    w ogóle nie dotknął. Po niej zbiór „linie z `modsec_src`" == „linie,
    na których zapaliła się reguła". Ten spec **zakłada, że tamta zmiana wchodzi**;
    gdyby wypadła, trzeba dopisać zdanie ostrzegawcze do `description` zmiennej.

### Dlaczego domyślnie „wszystko"

Zmiana domyślnej opcji na „bez WAF" ukryłaby ataki przed operatorem, który nie
wie, że dashboard coś odsiewa. Neutralny domyślny stan = zero zmiany zachowania
dla istniejących instalacji po `git pull`.

## Założenie do weryfikacji empirycznej

**Brakująca structured metadata zachowuje się w LogQL jak pusty string** — tj.
`modsec_src=""` łapie linie appservera (które w ogóle nie mają tego klucza,
bo `stage.structured_metadata` siedzi wewnątrz `stage.match` w `config.alloy`),
a `modsec_src=~".*"` nie gubi żadnej linii.

Poszlaki za: panel „Kategorie ataków" w `waf.json` używa `| modsec_attack != ""`
właśnie po to, by odsiać wpisy bez tego pola — czyli produkcyjnie polegamy już
na tej semantyce.

**Zweryfikowane empirycznie 2026-08-05** na `grafana/loki:3.7.1` (dokładnie ten
tag co produkcja — `docker-compose.monitoring.yml:30`). Dwie linie wypchnięte
przez `/loki/api/v1/push` — jedna ze structured metadata `modsec_src="nginx"`,
druga bez tego klucza — i trzy zapytania przez `/loki/api/v1/query_range`:

| Filtr | Oczekiwano | Zwrócono |
|---|---|---|
| `\| modsec_src=~".*"` | 2 | 2 |
| `\| modsec_src="nginx"` | 1 | 1 |
| `\| modsec_src=""` | 1 | 1 |

Nośny jest **trzeci** przypadek: zwrócił linię appservera, która klucza
`modsec_src` w ogóle nie ma. Brakująca structured metadata jest więc rzutowana
na pusty string.

Warto było to sprawdzić, bo nie jest oczywiste: w Prometheusie brak etykiety
i pusta etykieta to jedno i to samo w selektorze serii, ale LogQL stosuje filtry
potokowe do **każdej linii z osobna**, już po wybraniu strumieni — równie dobrze
mógłby traktować brak klucza jako „nie ma czego porównać" i odrzucać linię.
Gdyby tak było, stan „bez WAF" trzeba by wyrazić podwójną negacją
(`| modsec_src!="nginx" | modsec_src!="audit"`).

## Data links a stan zmiennej

Panel „Log volume" ma data link `?var-level=${__field.labels.detected_level}`
(`error-monitoring.json:71`), a tabela „By service" — `?var-service=…` (`:375`).
Jeśli Grafana 12 przy takim linku **podmienia** query string zamiast go scalać,
klik w tabelę zresetuje `var-waf` do „wszystko" — operator, który wyciszył WAF,
dostanie go z powrotem bez ostrzeżenia.

**Nie weryfikujemy tego empirycznie, bo nie trzeba.** Dopisanie
`&var-waf=${waf:percentencode}` do obu linków jest korzystne w **obu**
przypadkach:

- semantyka „podmienia" → link zachowuje wybrany stan filtra (naprawa),
- semantyka „scala" → link ustawia zmienną na jej własną, bieżącą wartość
  (no-op).

Weryfikacja kosztowałaby postawienie Grafany z provisioningiem, a jedyne, co
by rozstrzygnęła, to *czy* poprawka jest potrzebna — nie *czy* jest bezpieczna.

Percent-encoding jest konieczny, bo wartość zawiera `|`, `"` i spacje. Gdyby
format `:percentencode` okazał się nieobsługiwany, degradacja jest łagodna:
`var-waf` dostaje wartość spoza listy opcji, Grafana cofa się do pierwszej
opcji — czyli do „wszystko", stanu dzisiejszego. Nic się nie psuje.

**Świadomie poza zakresem:** te same linki gubią dziś `var-service`
i `var-container`, jeśli semantyka to „podmienia". To defekt zastany, nie
wprowadzany tą zmianą, i dotyczy zmiennych `multi`, których round-trip przez
URL jest osobnym tematem.

## Zabezpieczenie przed regresją

Statyczna asercja w **`tests/test_makefile.sh`**, wzorowana na
`test_waf_audit_only_rules` (`tests/test_makefile.sh:409`) — ta sama technika
grep-po-JSON-ie z liczeniem wystąpień:

- fragment `${waf:raw}` występuje w **dokładnie trzech** zapytaniach
  `error-monitoring.json` (tyle, ile paneli),
- zmienna `waf` ma trzy opcje.

Powód: eksport dashboardu z UI Grafany po ręcznej edycji potrafi zgubić fragment
z jednego panelu — wtedy filtr działa „prawie", co jest gorsze niż gdyby nie
działał wcale.

## Wydajność

No-op `| modsec_src=~".*"` dodaje etap potoku do każdego zapytania przy
`refresh: 30s`. Koszt jest marginalny — `count_over_time` i tak dekompresuje
każdą linię, a filtr po structured metadata nie wymaga parsera (`| json`,
`| logfmt`). Nie ma tu nic do optymalizowania.

## Dokumentacja

`docs/monitoring/dashboardy-grafany.md` opisuje dropdowny tego dashboardu
(sekcja nadal nazywa się **„Error Monitoring"**, choć dashboard od dawna nosi
tytuł **„Log Monitoring"** — przy okazji synchronizujemy nazwę i listę zmiennych).

`docs/architektura/waf.md:293` mówi dziś, że bliźniaków „nie da się filtrować
inaczej niż pełnotekstowo" — po tej zmianie zdanie jest nieprawdziwe i wymaga
korekty ze wskazaniem na nową zmienną.

## Poza zakresem

- Zmiana domyślnej opcji na „bez WAF".
- Link z „Log Monitoring" do dashboardu WAF.
- Czwarta opcja („tylko WAF — audit JSON") — od analizy jest dashboard `waf.json`.

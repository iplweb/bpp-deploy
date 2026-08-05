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
  "query": "wszystko : | modsec_src=~\".*\", tylko WAF : | modsec_src=\"nginx\", bez WAF : | modsec_src=\"\"",
  "multi": false,
  "includeAll": false,
  "current": { "text": "wszystko", "value": "| modsec_src=~\".*\"" }
}
```

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

Weryfikacja mimo to, bo cały projekt na tym stoi: jednorazowy kontener Loki,
push dwóch linii (jedna ze structured metadata, jedna bez), trzy zapytania przez
`/loki/api/v1/query_range`, sprawdzenie liczby zwróconych linii dla każdego
z trzech wariantów.

## Zabezpieczenie przed regresją

Statyczna asercja w `tests/`: fragment `${waf:raw}` musi występować we
**wszystkich trzech** panelach `error-monitoring.json`, a zmienna `waf` musi mieć
trzy opcje. Powód: eksport dashboardu z UI Grafany po ręcznej edycji potrafi
zgubić fragment z jednego panelu — wtedy filtr działa „prawie", co jest gorsze
niż gdyby nie działał wcale.

## Poza zakresem

- Zmiana domyślnej opcji na „bez WAF".
- Link z „Log Monitoring" do dashboardu WAF.
- Czwarta opcja („tylko WAF — audit JSON") — od analizy jest dashboard `waf.json`.

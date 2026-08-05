# Pułapki przy edycji dashboardów Grafany

Strona dla osoby **edytującej JSON dashboardu** w
`defaults/grafana/provisioning/dashboards/`. Opis samych dashboardów z punktu
widzenia operatora jest osobno:
[Dashboardy Grafany](../monitoring/dashboardy-grafany.md).

Wszystkie opisane tu błędy **były w wysłanych dashboardach** i wszystkie dają ten
sam objaw — „nic nie działa" — bez śladu w logach. Żadnego nie widać w code
review polegającym na przeczytaniu JSON-a: każdy jest składniowo poprawny.

## Data link zaczynający się od `?` gubi ścieżkę dashboardu

```json
"url": "?var-service=${__data.fields.service}"
```

Wygląda na poprawny URL względny — RFC 3986 kazałby zachować bieżącą ścieżkę
i podmienić samo query. **Grafana nie robi rozwiązywania URL-i.** Łańcuch idzie
wprost do `locationService.push()`, a router `history` parsuje `?var-x=1` jako
`pathname: ''` — czyli **stronę główną Grafany**.

!!! bug "Cross-filtr „Log Monitoring" był martwy przez cztery miesiące"

    Od commita `989bf83` do `ef6e8ad` klik w wiersz tabeli wyrzucał operatora na
    listę dashboardów. Objaw jest mylący, bo wygląda na przypadkowe kliknięcie
    albo zawieszenie — nie na zepsuty link.

Zawsze pisz ścieżkę jawnie:

```json
"url": "/d/bpp-waf/waf-modsecurity-owasp-crs?var-rule=${__data.fields.modsec_rule_id}"
```

Działa też pod produkcyjnym subpath (`GF_SERVER_SERVE_FROM_SUB_PATH=true`,
Grafana pod `/grafana/`) — Grafana sama dokleja basename do ścieżki
zaczynającej się od `/`. Sprawdzone; nie „powinno działać".

## Interpoluj przez `${zmienna:queryparam}`, nie ręcznym `var-x=${zmienna}`

| Zapis | Co robi ze zmienną wielowartościową |
|---|---|
| `var-service=${service}` | skleja wartości w jeden łańcuch → filtr trafia w nic |
| `${service:queryparam}` | rozwija do `var-service=a&var-service=b` |

Tylko `:queryparam` obsługuje wielokrotny wybór **i** zachowuje stan `$__all`.
Na naszych dashboardach wielowartościowe są `service`, `container` i `level` —
czyli dokładnie te, po których klika się najczęściej.

Do wartości branych z komórki tabeli (`${__data.fields.X}`) dokładaj
**`:percentencode`**:

```json
"url": "/d/bpp-waf/waf?var-uri=${__data.fields.modsec_uri:percentencode}"
```

Bez tego `?` **wewnątrz wartości** rozcina query string — a ścieżki skanerów są
ich pełne (`/index.php?s=/index/\think\app/invokefunction`). Filtr wtedy albo
łapie ucięty fragment, albo nie łapie nic.

!!! warning "Każdy link musi nieść komplet zmiennych"
    Link przekazujący tylko `var-rule` **kasuje po cichu** pozostałe filtry —
    użytkownik klika „pokaż tę regułę", a traci zawężenie po vhoście i czasie,
    nie dostając o tym żadnego sygnału. Dashboard WAF-a ma pięć data linków
    (reguła, atak, adres IP, ścieżka, score) i **każdy** przekazuje wszystkie
    pięć zmiennych.

## Asymetria pól `modsec_*` — nie każdy filtr wolno wpiąć w każdy panel

Jedno żądanie zostawia w Loki [dwa wpisy](../architektura/waf.md#dwa-wpisy-na-jedno-zadanie):
wpis audytowy (JSON) i bliźniaczą linię `error.log`. **Nie mają tego samego
zestawu pól.**

| Pole | `modsec_src="audit"` | `modsec_src="nginx"` |
|---|---|---|
| `modsec_attack`, `modsec_rules`, `modsec_code`, `modsec_method`, `modsec_paranoia` | **tak** | **nie** |
| pozostałych 11 (`modsec_uri`, `modsec_client`, `modsec_rule_id`, …) | tak | tak |

Panel z logami celowo pokazuje wpisy `nginx` (audit log to ściana JSON-a,
człowiek czyta linię tekstową). Wpięcie w niego filtra `$attack` opróżniałoby
go za każdym razem, gdy operator wybierze kategorię ataku — czyli
**odtwarzałoby dokładnie ten objaw**, który ta strona pomaga wyeliminować.

Pilnuje tego `test_waf_crossfilter` w `tests/test_makefile.sh`.

## Filtry ad-hoc („Filter for value")

Lupka przy komórce tabeli wymaga, żeby zapytanie panelu kończyło się
parserem-zaślepką — inaczej filtr ląduje w selektorze strumienia i wygasza cały
dashboard. Mechanizm, pomiary i lista odrzuconych wariantów parsera:
[WAF → Filtry ad-hoc](../architektura/waf.md#pulapka-filtrow-ad-hoc).

Dokładając **nowy panel** do dashboardu WAF-a, przenieś ten sufiks razem
z zapytaniem — i zostaw go jako **ostatnie** ogniwo potoku.

## Zmiany docierają na wdrożenia same

`grafana/provisioning/dashboards/*` jest
[force-syncowane](../konfiguracja/architektura.md#pliki-force-syncowane-nadpisywane-przy-kazdym-deploy):
poprawiony JSON w repo trafia na żywą instalację przez `git pull && make up`,
bez ręcznego `cp` i bez migracji `.env`. Odwrotnie też: **nie edytuj dashboardu
w UI Grafany**, jeśli ma przeżyć deploy — zmiana zostanie nadpisana.

## Sprawdzenie

```bash
make test-makefile     # asercje strukturalne po JSON-ach dashboardów
```

Asercje pokrywają obecność i **pozycję** parsera-zaślepki, komplet zmiennych
w data linkach oraz zestaw filtrów w zapytaniach WAF-a. Nie zastępują otwarcia
dashboardu — błędy z tej strony są widoczne dopiero w przeglądarce.

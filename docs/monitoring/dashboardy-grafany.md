# Dashboardy Grafany

Dashboardy żyją w `defaults/grafana/provisioning/dashboards/` i są **auto-syncowane na
deploy** (patrz [Architektura konfiguracji](../konfiguracja/architektura.md#pliki-force-syncowane-nadpisywane-przy-kazdym-deploy)) —
zaktualizowany dashboard w repo trafia na żywe wdrożenie z `git pull && make up`, bez
ręcznego `cp`.

Dashboardy tworzone w UI Grafany żyją w jej bazie i nie są ruszane.

## Dostępne dashboardy

### Log Monitoring

Wolumen logów w czasie z podziałem na poziom + tabela per serwer + przeglądarka
logów z Loki. Dropdowny `Service` / `Container` / `Log Level` filtrują wszystkie
panele; klik w serię na wykresie ustawia `var-level`, klik w wiersz tabeli —
`var-service` (data linki); drag-select po wykresie zawęża czas. Panel „Logs"
z `enableInfiniteScrolling`.

Tu obowiązuje to samo ostrzeżenie co na dashboardzie WAF-a: **nie używaj lupek
„Filter for value"** przy polach `modsec_*` w szczegółach linii logu — wygaszą
wszystkie trzy panele naraz
([dlaczego](../architektura/waf.md#pulapka-filtrow-ad-hoc)). Filtrowanie po
`service`, `container` i `detected_level` (labele strumienia) działa normalnie.

Czwarty dropdown, **`ModSecurity`**, izoluje albo wycisza trafienia WAF-a:

| Stan | Co pokazuje |
|---|---|
| `wszystko` | domyślny, bez filtrowania |
| `tylko WAF` | wyłącznie czytelne linie error.log ModSecurity |
| `bez WAF` | wszystko **poza** zdarzeniami WAF-a (znikają oba wpisy — JSON audit i linia error.log) |

`tylko WAF` pokazuje żądania, na których CRS przekroczył próg anomalii — te mają
poziom `warn`, więc przy `Log Level = error` wynik będzie pusty. Trafienia
podprogowe (reguła się zapaliła, ale próg nie został przekroczony) nie trafiają
do error.log i widać je wyłącznie na dashboardzie
[WAF](#waf-modsecurity-owasp-crs).

### WAF (ModSecurity / OWASP CRS)

Trafienia WAF-a w jednym miejscu, żeby ruch skanerów nie mieszał się z awariami
aplikacji w „Log Monitoring". Panele: rząd statystyk (trafienia, zablokowane,
unikalne adresy IP, unikalne reguły), oś czasu z podziałem `blocked` / `detected`,
ranking reguł wiodących, kategorie ataków, najaktywniejsze adresy IP, najczęściej
atakowane ścieżki, rozkład anomaly score i surowe wpisy audit logu.

Filtry u góry: **Vhost** (regex po nazwie hosta — istotne przy multi-host), **Akcja**
(`blocked` = połączenie zerwane; `detected` = trafienie na ścieżce wyjętej z blokowania
regułami 10002/10003, zalogowane ale przepuszczone) oraz **Reguła**, **Atak**,
**Adres IP**, **Ścieżka**, **Anomaly score** — wszystkie regexowe, domyślnie `.*`.

Pięć ostatnich ustawia się **klikiem w wiersz tabeli**: klik w regułę w rankingu
zawęża cały dashboard do tej reguły, klik w adres IP — do tego adresu, i tak dalej.
Klik zachowuje pozostałe filtry, więc dają się składać („co ten adres IP robił na
tej ścieżce"). Wyczyścisz je wpisując `.*` z powrotem w pole u góry.

!!! warning "Nie używaj „Filter for value" z menu komórki"
    Grafana pokazuje przy komórkach tabeli i przy polach w szczegółach linii logu
    lupki **„Filter for value" / „Filter out value"**. Na polach `modsec_*` one
    **wywalają cały dashboard** — wszystkie panele pokażą „No data". Zamiast tego
    klikaj w sam wiersz (data link) albo edytuj filtry u góry.

    Powód i dlaczego tego przycisku nie da się ukryć:
    [Pułapka filtrów ad-hoc](../architektura/waf.md#pulapka-filtrow-ad-hoc).
    Jeśli już w to wejdziesz — usuń chip `Filters` nad dashboardem (×) albo
    przeładuj adres bez `&var-Filters=…`.

Źródłem danych są pola `modsec_*` wyciągane z audit logu przez Alloy — opis pól i
przykładowe zapytania: [WAF](../architektura/waf.md#logi-waf-a-w-grafanie).

Każdy panel agregujący liczy **wyłącznie żądania, w których zapaliła się reguła**
(`| modsec_src = "audit" | modsec_rule_id != ""`). Bez drugiego filtra wpadałyby tam
401 z logowania do paneli, 429 z rate limitingu i awarie 5xx — dlaczego, opisuje
[Wpisy audytowe, w których nie zapaliła się żadna reguła](../architektura/waf.md#wpisy-audytowe-w-ktorych-nie-zapalia-sie-zadna-regua).
Kopiując stamtąd zapytanie do własnego panelu, przenieś **oba** filtry.

### Slow queries (log) i Top 100 queries (pg_stat_statements)

Monitoring wolnych zapytań — opisany osobno: [Wolne zapytania](slow-queries.md).

### PostgreSQL: Maintenance

VACUUM/ANALYZE, dead tuples, bloat, cache hit ratio.

### PostgreSQL: Storage & tables

Rozmiar bazy, największe tabele/indeksy, dead tuples, szacowany bloat.

## Datasource — read-only `bpp_monitor`

Grafana łączy się z PostgreSQL przez read-only rolę `bpp_monitor` (nie superusera
aplikacji). Datasource jest renderowany z force-syncowanego
`datasources.yaml.tpl` przez `scripts/generate-grafana-datasources.sh` — szczegóły
mechaniki w [Architekturze konfiguracji](../konfiguracja/architektura.md#datasourcesyamltpl-dlaczego-force-sync).
Rolę tworzy [`make create-monitoring-user`](netdata-alerty.md#dedykowany-uzytkownik-monitoringu-postgresql).

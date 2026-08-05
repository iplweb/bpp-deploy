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

**Uwaga — inaczej niż na dashboardzie WAF-a**: tutaj lupki „Filter for value" przy
polach `modsec_*` (w szczegółach linii logu) nadal wygaszą wszystkie trzy panele
([dlaczego](../architektura/waf.md#pulapka-filtrow-ad-hoc)). Filtrowanie po
`service`, `container` i `detected_level` działa normalnie — to labele strumienia,
więc trafiają dokładnie tam, gdzie Grafana je wstawia.

Ten dashboard **celowo** nie dostał parsera-zaślepki, który naprawia lupki na WAF-ie.
Cena byłaby tu realna: przeniesienie filtra po `service`/`container` z selektora
strumienia do potoku zamienia wyszukanie po indeksie w skan wszystkich strumieni —
a to jedyny dashboard pytający o logi **wszystkich** kontenerów, nie samego
webservera. Na trzy pola, które i tak działają, nie warto.

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

!!! tip "Lupka „Filter for value" działa"
    Grafana pokazuje przy komórkach tabeli i przy polach w szczegółach linii logu
    lupki **„Filter for value" / „Filter out value"**. Na tym dashboardzie zawężają
    wszystkie panele, a wybrany filtr pojawia się jako chip `Filters` nad
    dashboardem (zdejmujesz go ×). Masz więc trzy równorzędne drogi: lupka,
    kliknięcie w wiersz (data link) i okienka u góry.

    Do 08.2026 ta lupka **wygaszała cały dashboard** — wszystkie panele pokazywały
    „No data". Co to było i czym naprawione:
    [Filtry ad-hoc](../architektura/waf.md#pulapka-filtrow-ad-hoc).

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

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
aplikacji w „Error Monitoring". Panele: rząd statystyk (trafienia, zablokowane,
unikalne adresy IP, unikalne reguły), oś czasu z podziałem `blocked` / `detected`,
ranking reguł wiodących, kategorie ataków, najaktywniejsze adresy IP, najczęściej
atakowane ścieżki, rozkład anomaly score i surowe wpisy audit logu.

Filtry u góry: **Vhost** (regex po nazwie hosta — istotne przy multi-host) i **Akcja**
(`blocked` = połączenie zerwane; `detected` = trafienie na ścieżce wyjętej z blokowania
regułami 10002/10003, zalogowane ale przepuszczone).

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

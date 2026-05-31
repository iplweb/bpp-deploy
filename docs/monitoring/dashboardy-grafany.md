# Dashboardy Grafany

Dashboardy żyją w `defaults/grafana/provisioning/dashboards/` i są **auto-syncowane na
deploy** (patrz [Architektura konfiguracji](../konfiguracja/architektura.md#pliki-force-syncowane-nadpisywane-przy-kazdym-deploy)) —
zaktualizowany dashboard w repo trafia na żywe wdrożenie z `git pull && make up`, bez
ręcznego `cp`.

Dashboardy tworzone w UI Grafany żyją w jej bazie i nie są ruszane.

## Dostępne dashboardy

### Error Monitoring

Liczba błędów w czasie (per serwer) + log błędów z Loki. Dropdowny
`service`/`container`/`level` filtrują oba panele; klik w serię na wykresie ustawia
`var-service` (data link) i zawęża logi; drag-select po wykresie zawęża czas. Panel
„Error Logs" z `enableInfiniteScrolling`.

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

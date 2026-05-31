# Wolne zapytania (slow queries)

Dwa kanały obserwowalności wolnych zapytań PostgreSQL, oba przez istniejącą infrę
Loki + Grafana.

## Bootstrap (jednorazowy, idempotentny)

```bash
make pg-monitoring-setup
```

Tryb external (dbserver poza compose): skrypt wypisuje SQL do ręcznego uruchomienia.

## Dwa kanały

### Logi (`log_min_duration_statement=1000`)

Każde query >1s w logu dbservera → Alloy → Loki (90d retencja). Dashboard
**„Slow queries (log)"** w Grafanie. Pełny tekst query + parametry. Naturalna filtracja
czasowa (UI time picker).

### Statystyki (`pg_stat_statements`)

Agregowane per znormalizowane query (calls, mean/total/stddev exec time). Dashboard
**„Top 100 queries (pg_stat_statements)"** — top N wg średniej. Agregat od ostatniego
`pg_stat_statements_reset()`.

Towarzyszący bar chart **„Top 15 by mean execution time"** — klik w słupek ustawia
zmienną `qid` (data link) i zawęża tabelę do danego `queryid`; puste pole `qid` u góry =
wszystkie 100.

!!! note
    `pg_stat_statements` **nie ma osi czasu**, więc cross-filter jest po `queryid`, nie
    po przedziale czasu. Logi (kanał wyżej) mają oś czasu.

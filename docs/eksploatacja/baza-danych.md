# Baza danych

## Bezpieczne migracje

```bash
make migrate
```

`make migrate` automatycznie: **zatrzymuje workery denorm → uruchamia migracje →
restartuje workery**. To kolejność celowa — denormalizacja oparta o triggery PG i
`LISTEN`/`NOTIFY` mogłaby przetwarzać niespójny stan w trakcie migracji schematu.

## Shell do bazy

```bash
make dbshell          # Django database shell (dbshell)
make dbshell-psql     # Bezpośredni psql w kontenerze dbserver
make shell-dbserver   # Shell systemowy w kontenerze bazy
```

## Uruchamianie komend w kontenerach

Obrazy są slim — `uv` nie jest już obecny. Używaj natywnego `python` / `celery`:

- Django: `python src/manage.py <command>` (CWD to katalog nad `src/`)
- Celery: `celery -A django_bpp.celery_tasks <command>`

## Backup bazy

```bash
make db-backup        # Pojedynczy pg_dump -Fd -j N, spakowany do tar.gz
```

Pełny cykl backupu (baza + media + rclone + powiadomienia) oraz codzienny harmonogram
opisuje [Backup i rclone](backup-i-rclone.md).

## Upgrade wersji PostgreSQL

Minor (ten sam major) to zmiana tagu + restart; major wymaga dump/restore przez
`make upgrade-postgres`. Pełna procedura: [PostgreSQL — wersje i upgrade](../konfiguracja/postgresql.md).

## Monitoring PostgreSQL (pg_stat_statements)

Bootstrap monitoringu wolnych zapytań (jednorazowy, idempotentny):

```bash
make pg-monitoring-setup
```

Szczegóły: [Wolne zapytania](../monitoring/slow-queries.md).

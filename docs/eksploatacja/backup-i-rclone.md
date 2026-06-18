# Backup i rclone

## Komendy

```bash
make db-backup        # Pojedynczy pg_dump (równoległy, tar.gz)
make backup-cycle     # Pełen cykl: pg_dump + tar mediów + rclone + powiadomienia
make rclone-config    # Konfiguracja zdalnego backupu (Google Drive, S3, ...)
make rclone-sync      # Wymuszona synchronizacja z chmurą
make rclone-check     # Sprawdzenie spójności kopii zdalnej
```

## Codzienny backup

Codzienny backup uruchamia Ofelia o **02:30** (label `0 30 2 * * *` na `backup-runner`).
`backup-runner` to efemeryczny kontener: robi `pg_dump`, pakuje media (tar), wysyła
przez rclone i raportuje do Rollbara.

!!! note "Obraz backup-runnera — bez podwójnego ściągania"
    Domyślnie `backup-runner` używa **tego samego** obrazu co `dbserver`
    (`postgres:${DJANGO_BPP_POSTGRESQL_VERSION}`, wariant Debian) — dzięki temu
    współdzieli z nim 100% warstw i nie zajmuje dodatkowego miejsca na dysku
    (osobny `-alpine` nie dzieli warstw z Debianem i kosztowałby ~350 MB więcej).
    `pg_dump` trafia dokładnie w wersję serwera. `rclone`, `curl`, `jq` są
    doinstalowane w runtime (`apt-get`). W trybie **zewnętrznej bazy** `dbserver`
    to lekki sentinel `postgres:<major>-alpine`; tam `init-configs` ustawia
    `BPP_BACKUP_PG_IMAGE=postgres:<major>-alpine`, by `backup-runner` współdzielił
    warstwy z sentinelem (na starych instalacjach dopisuje to `ensure-config-files`
    przy zwykłym `make up`).

`make backup-cycle` uruchamia ten sam cykl ręcznie.

## `make backup` / `make restore` — para baza + media

`make backup` uruchamia `db-backup` (równoległy `pg_dump -Fd`, `tar.gz`) i `media-backup`
(zawartość wolumenu `media` jako `tar.gz`). Oba archiwa lądują w
`$DJANGO_BPP_HOST_BACKUP_DIR` z timestampem:

- `db-backup-YYYYMMDD-HHMMSS.tar.gz`
- `media-backup-YYYYMMDD-HHMMSS.tar.gz`

`make restore` automatycznie wybiera najświeższą parę (lub `--pick` / `--timestamp=...`).
Przed destruktywnym restorem robi safety-backup aktualnej bazy — procedura jest odwracalna.
Wykorzystywane przy [przenosinach serwera](przenosiny-serwera.md).

## Co NIE jest backupowane przez `make backup`

`make backup` zapisuje tylko bazę danych i wolumeny mediów. Loki/Netdata/Grafana (logi
i metryki historyczne) **nie są przenoszone** — po starcie na nowym hoście zaczynają od
pustego stanu. Jeśli zależy Ci na historii monitoringu, skopiuj dodatkowo wolumeny
`loki_data`, `netdata_lib`, `netdata_cache` i `grafana_data` (przy zatrzymanym stacku):

```bash
docker run --rm -v <vol>:/data alpine tar czf - /data | ssh nowy-host 'cat > vol.tar.gz'
```

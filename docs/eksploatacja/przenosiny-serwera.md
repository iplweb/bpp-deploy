# Przenosiny serwera na inną maszynę

Procedura przeniesienia działającej instancji BPP na nowy host (wymiana sprzętu,
migracja do innego data center, klonowanie produkcji na zapasowe środowisko). Sprowadza
się do **trzech katalogów + dwóch komend**.

## Na starej maszynie

### 1. Świeży backup pary baza + media

```bash
cd ~/bpp-deploy
make backup
```

`make backup` uruchamia `db-backup` (równoległy `pg_dump -Fd`, `tar.gz`) i `media-backup`
(wolumen `media` jako `tar.gz`). Oba archiwa lądują w `$DJANGO_BPP_HOST_BACKUP_DIR` z
timestampem.

### 2. Skopiuj trzy katalogi

Przez `rsync`, `scp` lub dysk zewnętrzny:

- `~/bpp-deploy/` — repozytorium (zawiera `.env` wskazujący na katalog konfiguracyjny)
- `$BPP_CONFIGS_DIR` — katalog konfiguracyjny instancji (np. `~/publikacje-uczelnia/`
  z `.env`, certyfikatami SSL, konfiguracją Grafany itd.)
- `$DJANGO_BPP_HOST_BACKUP_DIR` — katalog z backupami (potrzebny tylko najświeższy z
  punktu 1, ale prościej skopiować całość)

```bash
rsync -avzP ~/bpp-deploy/              nowy-host:~/bpp-deploy/
rsync -avzP ~/publikacje-uczelnia/     nowy-host:~/publikacje-uczelnia/
rsync -avzP ~/backups/                 nowy-host:~/backups/
```

!!! warning "Ścieżki absolutne muszą się zgadzać"
    `BPP_CONFIGS_DIR` i `DJANGO_BPP_HOST_BACKUP_DIR` w `.env` muszą się zgadzać po obu
    stronach — albo skopiuj do tych samych ścieżek, albo edytuj `.env` na nowej maszynie
    po przeniesieniu.

## Na nowej maszynie

### 3. Zainstaluj zależności hosta

Zgodnie z sekcją [Instalacja](../instalacja/index.md) — Docker Engine, `make`, `git`,
`gettext`, dodanie użytkownika do grupy `docker`.

!!! danger "Nie uruchamiaj `make init-configs`"
    Masz już skopiowaną konfigurację — świeży `init-configs` rozjedzie hasła z dumpem.
    Pomiń też `make` (bez argumentu, bo odpala first-run).

### 4. Przywróć dane

```bash
cd ~/bpp-deploy
make restore
```

`restore.sh` automatycznie wybiera najświeższą parę `db-backup` + `media-backup`
(możesz podać `--pick` do interaktywnego wyboru z `fzf`/menu albo
`--timestamp=YYYYMMDD-HHMMSS`). Przed destruktywnym restorem robi safety-backup
aktualnej pustej bazy.

### 5. Zweryfikuj

```bash
make health
make logs-appserver
```

Otwórz aplikację w przeglądarce — powinieneś zobaczyć dokładnie ten sam stan, co na
starej maszynie w momencie `make backup`.

## Co przenieść warto, ale opcjonalnie

- **DNS / certyfikaty SSL** — jeśli zmienia się hostname, zaktualizuj `DJANGO_BPP_HOSTNAME`
  i `DJANGO_BPP_CSRF_EXTRA_ORIGINS` w `.env`, podmień certyfikaty w `ssl/` i uruchom
  `make update-ssl-certs`.
- **rclone** — konfiguracja zdalnych backupów już jest w `$BPP_CONFIGS_DIR/rclone/`,
  działa od razu po przeniesieniu.
- **Cron Ofelia** — nic nie trzeba przepisywać, harmonogram jest w
  `docker-compose.application.yml` z repozytorium.

## Co NIE jest backupowane

`make backup` zapisuje tylko bazę i media. Historia monitoringu (Loki/Netdata/Grafana)
nie jest przenoszona — patrz [Backup i rclone](backup-i-rclone.md#co-nie-jest-backupowane-przez-make-backup).

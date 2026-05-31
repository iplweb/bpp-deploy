# PostgreSQL — wersje i upgrade

Kontener `dbserver` używa obrazu `iplweb/bpp_dbserver:psql-${DJANGO_BPP_POSTGRESQL_VERSION}`,
format `MAJOR.MINOR` (np. `16.13`, `17.9`, `18.3`). Wersja jest sterowana zmienną
`DJANGO_BPP_POSTGRESQL_VERSION` w `$BPP_CONFIGS_DIR/.env`. Domyślnie `16.13`.

`DJANGO_BPP_POSTGRESQL_VERSION_MAJOR` (auto-derived z `_VERSION`) jest używana przez
`backup-runner` (`postgres:<major>-alpine` — `pg_dump` musi być ≥ wersji serwera).
W trybie external obie zmienne trzymają tylko major.

Wybór wersji następuje przy pierwszym uruchomieniu `make` — `init-configs` zapyta
`Wersja PostgreSQL [16.13]:`. Lista tagów:
[hub.docker.com/r/iplweb/bpp_dbserver/tags](https://hub.docker.com/r/iplweb/bpp_dbserver/tags).

!!! warning
    Upgrade major wymaga dump/restore — użyj `make upgrade-postgres`, **nie** edytuj
    zmiennej ręcznie.

## Minor upgrade (ten sam major, np. 16.13 → 16.14)

Format PGDATA jest binarnie kompatybilny w obrębie tego samego majora, więc wystarczy
zmiana tagu i restart:

```bash
# 1. W $BPP_CONFIGS_DIR/.env zmień: DJANGO_BPP_POSTGRESQL_VERSION=16.14
# 2. Pobierz nowy obraz i odśwież kontener:
docker compose pull dbserver
docker compose up -d dbserver
```

## Major upgrade (np. 16.13 → 18.3)

Między różnymi major wersjami **nie ma binarnej kompatybilności formatu PGDATA** — każdy
nowy kontener musi wystartować na pustym, świeżo zainicjalizowanym wolumenie. Dane przenosi
się metodą *logical dump & restore*:

```bash
make upgrade-postgres
```

Skrypt (`scripts/upgrade-postgres.sh`) interaktywnie wykonuje kroki:

1. `make db-backup` — świeży `pg_dump -Fd -j N` w `$DJANGO_BPP_HOST_BACKUP_DIR`
2. Stop usług zależnych (app, workery, beat, denorm-queue, flower, authserver)
3. Stop+rm `dbserver`
4. Kopia wolumenu `${COMPOSE_PROJECT_NAME}_postgresql_data` → `..._pg<old>_<ts>`
   (zostaje do ręcznego usunięcia po weryfikacji)
5. Usunięcie `postgresql_data` — nowy kontener potrzebuje pustego wolumenu
6. Bump `DJANGO_BPP_POSTGRESQL_VERSION` (+ `_MAJOR`) w `.env`
7. `docker compose pull dbserver` + `up -d dbserver` → initdb na nowym majorze
8. `pg_restore -Fd -j N` z tarballa
9. `make migrate` + `make up` + smoke-test logów appservera

### Wymagania

- Obraz `iplweb/bpp_dbserver:psql-<MAJOR.MINOR>` już opublikowany na Docker Hub (skrypt
  tylko pobiera, nie buduje).
- Wolne miejsce: ~2.5× rozmiar PGDATA (tarball + kopia wolumenu).
- Stack musi być uruchomiony (`make up`), żeby wykonać `pg_dump`.

### Auto-rollback

Jeśli nowy `dbserver` padnie na kroku [8/10] (błąd init, timeout healthchecku,
niekompatybilny layout wolumenu — np. PG18+), skrypt pyta `„Wykonac auto-rollback?"`.
Po potwierdzeniu: revert bumpu `.env`, usunięcie zepsutego `postgresql_data`, restore
z `BACKUP_VOLUME`, start starego `dbserver`. Backup volume usuwany po sukcesie, tarball
zostaje jako DR.

### Resume po błędzie (`--from-step=N`)

Skrypt zapisuje stan do `$BPP_CONFIGS_DIR/.upgrade-rollback-<ts>` (zaraz po potwierdzeniu,
przed krokiem 1; po kroku 3 dopisuje ścieżkę tarballa). Jeśli krok padnie (np. 8), wznów
bez powtarzania dumpu/kopii wolumenu:

```bash
bash scripts/upgrade-postgres.sh --from-step=8
# auto-wykrywa najnowszy plik stanu, lub podaj --rollback-file=<path>
```

Trap błędu (`on_error`) drukuje dokładną komendę resume. Krok 5 padnie, gdy
`BACKUP_VOLUME` już istnieje (usuń ręcznie); krok 9 zgłasza konflikty przy częściowo
załadowanych danych. `--help` po pełny opis.

### Manualny rollback

Stary wolumen + tarball zostają. Kroki znajdziesz w `$BPP_CONFIGS_DIR/.upgrade-rollback-<ts>`.

## Tryb external

`BPP_DATABASE_COMPOSE=docker-compose.database.external.yml`: upgrade samej bazy wykonujesz
po swojej stronie (managed service, RDS blue/green, `pg_upgradecluster` itp.), a skrypt
wykrywa to i pokazuje 3-krokową instrukcję — opcjonalnie bumpuje `_VERSION` + `_MAJOR` i
odświeża sentinel + backup-runner.

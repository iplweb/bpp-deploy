# PostgreSQL — wersje i upgrade

Kontener `dbserver` używa **oficjalnego obrazu** `postgres:${DJANGO_BPP_POSTGRESQL_VERSION}`
(wariant Debian, nie `-alpine`), format `MAJOR.MINOR` (np. `18.4`, `17.9`, `16.13`). Wersja
jest sterowana zmienną `DJANGO_BPP_POSTGRESQL_VERSION` w `$BPP_CONFIGS_DIR/.env`. Nowe
instalacje dostają domyślnie **`18.4`** (najnowsza wersja z gałęzi 18).

!!! warning "Domyślna `18.4` dotyczy tylko NOWYCH instalacji"
    `init-configs` wpisuje `18.4` przy pierwszym uruchomieniu. Istniejące instalacje
    zachowują swoją wersję z `.env` — **upgrade majora nigdy nie dzieje się sam**
    (wymaga dump/restore przez `make upgrade-postgres`). Fallback w `docker-compose`
    (`:-16.13`) celowo **pozostaje na `16.13`** jako siatka bezpieczeństwa dla
    pradawnych `.env` bez tej zmiennej — gdyby skoczył na `18.4`, taki klaster PG16
    dostałby obraz PG18 na danych PG16 i nie wstałby.

> **Skąd autotune?** Wcześniej `dbserver` używał własnego obrazu `iplweb/bpp_dbserver` —
> jest on **wycofany**, a jego jedynym dodatkiem ponad stockowego postgresa był *autotune*.
> Teraz montujemy dwa skrypty autotune (`dbserver/autotune.sh`,
> `dbserver/docker-entrypoint-autotune.sh` — wersjonowane w repo, bind-mount read-only) na
> obraz oficjalny. Wrapper inicjuje bazę, generuje `/postgresql_optimized.conf` dopasowany
> do limitu pamięci kontenera (`DBSERVER_MEM_LIMIT`, ~95%) i startuje normalnie. Bez buildu,
> bez `python3`. Szczegóły strojenia: [Limity zasobów](limity-zasobow.md).

`DJANGO_BPP_POSTGRESQL_VERSION_MAJOR` (auto-derived z `_VERSION`) trzyma sam major.
W trybie lokalnym `backup-runner` używa jednak tego **samego pełnego obrazu** co
`dbserver` (`postgres:${DJANGO_BPP_POSTGRESQL_VERSION}`, Debian) — współdzieli z nim
warstwy zamiast ściągać osobny `-alpine`; `pg_dump` trafia dokładnie w wersję serwera.
W trybie external `dbserver` to sentinel `postgres:<major>-alpine` i wtedy zmienna
`BPP_BACKUP_PG_IMAGE` kieruje `backup-runner` na ten sam alpine. `_MAJOR` nadal
napędza tag sentinela oraz krok upgrade'u. Szczegóły:
[Backup i rclone](../eksploatacja/backup-i-rclone.md).

Wybór wersji następuje przy pierwszym uruchomieniu `make` — `init-configs` zapyta
`Wersja PostgreSQL [18.4]:`. Lista tagów:
[hub.docker.com/_/postgres](https://hub.docker.com/_/postgres).

!!! note "Kolacja (sortowanie) i PGDATA"
    Świeża inicjalizacja bazy używa `POSTGRES_INITDB_ARGS=--locale-provider=icu
    --icu-locale=pl-PL` (poprawne sortowanie polskich znaków). Dotyczy to **tylko nowych
    instalacji** — istniejące wolumeny zachowują swoją oryginalną kolację, ten argument
    nigdy nie re-kolacjonuje danych. `PGDATA` jest przypięte do `/var/lib/postgresql/data`:
    stock `postgres:18+` domyślnie używa innej ścieżki, więc bez pinu istniejący wolumen
    zostałby zignorowany, a baza zainicjowana od zera.

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
9. `make up` + `make migrate` + smoke-test logów appservera (kolejność istotna:
   `make migrate` robi `docker compose exec appserver …`, więc wymaga już
   działającego appservera — `make up` musi być pierwsze)

### Wymagania

- Obraz `postgres:<MAJOR.MINOR>` — oficjalny obraz Docker, wszystkie majory są zawsze
  dostępne (krok 1 robi `docker pull` i wyłapie literówkę w wersji; skrypt nie buduje obrazu).
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

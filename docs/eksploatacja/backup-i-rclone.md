# Backup i rclone

## Komendy

```bash
make db-backup        # Pojedynczy pg_dump (równoległy, tar.gz)
make backup-cycle     # Pełen cykl: pg_dump + tar mediów + rclone copy + retencja zdalna
make rclone-config    # Konfiguracja zdalnego backupu (Google Drive, S3, ...)
make rclone-sync      # Wymuszona wysyłka do chmury (ten sam układ co cykl nocny)
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
    `pg_dump` trafia dokładnie w wersję serwera. `rclone`, `curl`, `jq`
    **i `ca-certificates`** są doinstalowane w runtime (`apt-get`) — bez tego
    ostatniego kontener nie ma żadnego roota CA i **każde** połączenie HTTPS
    pada (patrz [Awaria TLS](#awaria-tls-certificate-signed-by-unknown-authority)). W trybie **zewnętrznej bazy** `dbserver`
    to lekki sentinel `postgres:<major>-alpine`; tam `init-configs` ustawia
    `BPP_BACKUP_PG_IMAGE=postgres:<major>-alpine`, by `backup-runner` współdzielił
    warstwy z sentinelem (na starych instalacjach dopisuje to `ensure-config-files`
    przy zwykłym `make up`).

`make backup-cycle` uruchamia ten sam cykl ręcznie.

## Układ katalogów na zdalnym

Kopie lądują w **jednym katalogu na miesiąc**:

```
backup_enc:
  2026-07/
    db-backup-20260701-023000.tar.gz
    media-backup-20260701-023000.tar.gz
    ...                                  (2 pliki na dzień)
  2026-08/
    ...
```

Wysyłka to `rclone copy` całego lokalnego katalogu backupów. Ponieważ nazwy
niosą timestamp, a katalog docelowy jest **stały przez cały miesiąc**, `copy`
wysyła tylko to, czego na zdalnym jeszcze nie ma — czyli 2 pliki dziennie.
Jednocześnie co noc „pokazuje" zdalnemu całe lokalne okno 7 kopii, więc dzień,
w którym rclone padł, uzupełnia się sam następnej nocy.

!!! danger "Do katalogu miesięcznego wolno wysyłać wyłącznie `rclone copy`"
    `rclone sync` skasowałby z katalogu miesiąca wszystko, czego nie ma
    lokalnie — czyli **całe archiwum poza ostatnimi 7 dniami** — i zakończyłby
    się sukcesem, bez śladu w logach. Broni tego asercja mutacyjna w
    `make test-rclone`.

!!! info "Skąd ta zmiana (do sierpnia 2026 było inaczej)"
    Wcześniej cykl robił `rclone sync /backup/ REMOTE:YYYY-MM/DD/` — do
    **świeżego, pustego** katalogu na każdy dzień. Skoro cel był za każdym
    razem pusty, rclone nie miał czego pominąć i wysyłał całe lokalne okno
    7 kopii: **14 plików dziennie zamiast 2**, a każdy plik lądował na zdalnym
    w 7 egzemplarzach. Siedmiokrotny narzut na transferze i na miejscu.

    Katalogi dzienne z tamtego okresu zostają tam, gdzie były — sama wysyłka
    ich nie rusza. Scalenie do katalogów miesięcznych to jednorazowa, ręczna
    operacja po stronie backendu (`rclone moveto` + `rclone purge` dopiero po
    weryfikacji, że komplet plików jest już w katalogu miesiąca).

    **Ale retencja zdalna owszem je usunie** — `rclone purge` kasuje katalog
    miesiąca **razem z jego podkatalogami `DD/`**. Przy domyślnych 12
    miesiącach wszystko starsze zniknie po jednym katalogu na dobę,
    niezależnie od tego, czy zdążyłeś je scalić. Jeśli zależy Ci na tych
    danych, scal je **zanim** retencja do nich dojdzie, albo najpierw ustaw
    `DJANGO_BPP_RCLONE_KEEP_MONTHS=0`.

## Retencja zdalna — `DJANGO_BPP_RCLONE_KEEP_MONTHS`

**Domyślnie włączona: 12 miesięcy.** Po udanej wysyłce cykl usuwa najstarsze
katalogi miesięczne, zostawiając `DJANGO_BPP_RCLONE_KEEP_MONTHS` najnowszych,
licząc z bieżącym.

!!! warning "Aktywuje się na sam `git pull`, bez `make up`"
    `backup-runner` ma katalog `./scripts` podmontowany na żywo
    (`./scripts:/scripts:ro`), a Ofelia woła `/scripts/backup-cycle.sh` w
    **działającym** kontenerze. Nowy kod wchodzi więc do gry przy najbliższym
    przebiegu o 02:30 — bez przebudowy, bez restartu, bez `make up`. Jeśli
    chcesz najpierw zobaczyć, co by zniknęło: `make rclone-check` i ustaw
    `DJANGO_BPP_RCLONE_KEEP_MONTHS=0` **zanim** wykonasz `git pull`.

```bash
# w $BPP_CONFIGS_DIR/.env
DJANGO_BPP_RCLONE_KEEP_MONTHS=24   # trzymaj 2 lata
DJANGO_BPP_RCLONE_KEEP_MONTHS=0    # wyłącz retencję zdalną całkowicie
DJANGO_BPP_RCLONE_KEEP_MONTHS=     # to samo — pusta wartość też wyłącza
```

Każda wartość niebędąca dodatnią liczbą całkowitą (`0`, puste, śmieci) znaczy
**wyłączone** — nigdy błąd i nigdy kasowanie na chybił trafił.

Bezpieczniki, każdy celowy:

- **Maksymalnie jeden katalog miesięczny na cykl.** W normalnej pracy i tak co
  miesiąc wypada dokładnie jeden, więc różnicy nie widać — ale instalacja z
  wieloletnią historią nie traci kilkudziesięciu miesięcy jednej nocy, tylko po
  jednym na dobę. Każde usunięcie ma osobny wpis w logu i w komunikacie do
  Rollbara, więc jest doba na reakcję zamiast pojedynczego nieodwracalnego
  zdarzenia.
- **Bieżący miesiąc nie zostanie usunięty nigdy.**
- **Ruszane są wyłącznie katalogi pasujące dokładnie do `YYYY-MM`.** Cokolwiek
  innego w remote — twoje własne katalogi, stare katalogi dzienne wyniesione na
  górny poziom, nazwy typu `2026-08-01` czy `99` — jest nietykalne.
- **Błąd retencji nigdy nie wywraca backupu.** Nieudany `purge` czy nieudane
  listowanie zdalnego to ostrzeżenie w logu i adnotacja w komunikacie sukcesu;
  kod wyjścia cyklu się nie zmienia. Sprzątanie nie ma prawa zamienić udanego
  backupu w alert.

Retencja **lokalna** (`DJANGO_BPP_BACKUP_KEEP_LAST`, domyślnie 7 kopii) jest od
niej niezależna i działa jak dotąd.

## Konfiguracja zdalnego — `make rclone-config`

`make rclone-config` uruchamia interaktywny kreator `rclone config` **wewnątrz
kontenera `backup-runner`**. Powstały plik ląduje w
`$BPP_CONFIGS_DIR/rclone/rclone.conf` (bind mount, więc przeżywa odtworzenie
kontenera) i to jego czytają `make rclone-sync`, `make rclone-check` i nocny
cykl.

Nazwa remote'a musi się zgadzać z `DJANGO_BPP_RCLONE_REMOTE` w `.env`
(domyślnie `backup_enc:`).

!!! warning "`read-only file system` przy zapisie konfiguracji"
    **Symptom** — kreator na każdą odpowiedź odpowiada:

    ```
    ERROR : Failed to save config after 10 tries: failed to create temp file
    for new config: open /config/rclone/rclone.conf1427152738:
    read-only file system
    ```

    i mimo to **brnie dalej**, więc można przeklikać całą konfigurację i dopiero
    na końcu odkryć, że nic nie powstało.

    **Przyczyna.** Do września 2026 katalog `rclone` był montowany `:ro`
    (od pierwszego commita — czyli `make rclone-config` nie zadziałał ani razu).
    rclone tego pliku nie tylko czyta: zapisuje go przez plik tymczasowy
    + `rename` w tym samym katalogu. Wymaga tego również **normalna praca**
    z remote'em OAuth — [dokumentacja rclone](https://rclone.org/docs/), opcja
    `--config`:

    > When token-based authentication are used, the configuration file must be
    > writable, because rclone needs to update the tokens inside it.

    Dla większości remote'ów (Dropbox, Google Drive) `:ro` oznacza tylko
    hałas w logu — refresh-token się nie zmienia, więc kolejne odświeżenie i tak
    się uda. Ale tam, gdzie refresh-token jest **jednorazowy**, brak zapisu
    rozwala autoryzację na trwałe: [dokumentacja Boxa w rclone](https://rclone.org/box/)
    cytuje *„Each refresh_token is valid for one use in 60 days"* i ostrzega, że
    po nieudanym odświeżeniu dostaniesz `Invalid refresh token` i trzeba przejść
    OAuth od nowa.

    **Rozwiązanie** — `git pull && make up`. Sam `git pull` **nie wystarczy**:
    zmiana siedzi w `volumes:` w `docker-compose.backup.yml`, więc kontener musi
    się odtworzyć (tak samo jak przy [awarii CA](#awaria-tls-certificate-signed-by-unknown-authority)).

    Doraźnie, bez odtwarzania kontenera, można skonfigurować remote na kopii
    w `/tmp` i przenieść gotowy plik na hosta:

    ```bash
    docker compose exec backup-runner sh -c \
        'cp /config/rclone/rclone.conf /tmp/rclone.conf 2>/dev/null; \
         rclone --config /tmp/rclone.conf config'
    docker compose cp backup-runner:/tmp/rclone.conf \
        "$BPP_CONFIGS_DIR/rclone/rclone.conf"
    ```

!!! note "Właściciel pliku — poprawiany automatycznie"
    Kreator działa jako `root` w kontenerze, więc `rclone.conf` powstałby na hoście
    jako `root:root`. Backupom to nie przeszkadza (kontener też jest rootem), ale
    przy [przenosinach serwera](przenosiny-serwera.md) `rsync` uruchomiony z konta
    operatora takiego pliku **nie przeczyta** — i nowy serwer wstałby bez
    konfiguracji backupu zdalnego.

    Dlatego `make rclone-config` po zamknięciu kreatora wyrównuje właściciela pliku
    do właściciela katalogu `$BPP_CONFIGS_DIR/rclone/` i zwęża prawa do `0600`
    (funkcja `rclone_fix_config_owner` w `scripts/lib-rclone.sh`). Gdyby się nie
    udało, zobaczysz `UWAGA:` z kodem błędu — backupy działają dalej, ale katalog
    konfiguracyjny przenoś wtedy przez `sudo rsync`.

## Awaria TLS: `certificate signed by unknown authority`

**Symptom** — `rclone` nie dogaduje się ze zdalnym, a komunikat sugeruje wygasły token:

```
ERROR : : error listing: Post "https://api.dropboxapi.com/2/files/list_folder":
couldn't fetch token - maybe it has expired? - refresh with "rclone config reconnect backup:":
Post "https://api.dropboxapi.com/1/oauth2/token":
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

Pierwsza połowa komunikatu myli. Token jest w porządku — **kontener nie ma magazynu
certyfikatów CA**, więc padnie *każde* połączenie HTTPS, nie tylko do Dropboksa.

**Przyczyna.** Oficjalny obraz `postgres` (wariant Debian) instaluje `ca-certificates`
wyłącznie na czas ściągnięcia `gosu`, po czym robi `apt-get purge --auto-remove` —
finalny obraz nie zawiera `/etc/ssl/certs/ca-certificates.crt`. Debianowy pakiet
`rclone` zależy tylko od `libc6` (`ca-certificates` nie ma nawet w *Recommends*),
a instalacja runtime'owa idzie z `--no-install-recommends`, więc nic tej luki nie
łatało. Dopóki `backup-runner` stał na `postgres:*-alpine` (do czerwca 2026),
problemu nie było — alpine ma bundle CA w obrazie bazowym. Przeniesienie
`backup-runnera` na obraz współdzielony z `dbserverem` zabrało go po cichu.

!!! danger "Awaria backupu była niema"
    `notify_rollbar` też strzela `curl`-em po HTTPS. Bez CA nocny cykl kończył się
    na `exit 3` (rclone copy failed), a powiadomienie o tym dostawało `http=000` —
    czyli **alert o nieudanym backupie zdalnym nigdy nie docierał**. Lokalne kopie
    w `$DJANGO_BPP_HOST_BACKUP_DIR` powstawały normalnie; brakowało wyłącznie
    wysyłki na zdalny.

**Diagnoza:**

```bash
docker compose exec backup-runner ls -l /etc/ssl/certs/ca-certificates.crt
# brak pliku  -> to ta usterka
docker compose logs ofelia | grep -i backup_cycle | tail -20
# "rclone-copy (exit=3)" wskazuje, od kiedy wysyłka nie działa
```

**Rozwiązanie** — `git pull && make up`. Tu **nie wystarczy sam `git pull`**:
inaczej niż przy [retencji zdalnej](#retencja-zdalna-django_bpp_rclone_keep_months),
lista instalowanych pakietów siedzi w `command:` w `docker-compose.backup.yml`, czyli
w konfiguracji kontenera — musi się on odtworzyć.

Doraźnie, bez odtwarzania kontenera (ginie przy najbliższym `make up`):

```bash
docker compose exec backup-runner sh -c \
    'apt-get update && apt-get install -y --no-install-recommends ca-certificates'
docker compose exec backup-runner rclone --config /config/rclone/rclone.conf ls backup:
```

Po naprawie zaległe kopie uzupełnią się same przy najbliższym cyklu: na zdalny
wysyłany jest **cały** `$DJANGO_BPP_HOST_BACKUP_DIR`, a nie tylko dzisiejsze pliki.

Nawrót usterki wyłapuje healthcheck `backup-runnera`, który sprawdza bundle CA na
równi z binarkami — bez tego brak CA nie objawia się niczym aż do 02:30 w nocy.

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

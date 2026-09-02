# Backup: orkiestrator zamiast kontenera-kombajnu

**Data:** 2026-09-01
**Status:** projekt po dwóch recenzjach, przed implementacją
**Rewizja:** 3 (po audycie bashizmów — zmiany w §10)

> Spec leży w `specs/`, a **nie** w `docs/`, bo `docs/` to publikowany serwis MkDocs
> z jawną nawigacją — dokument projektowy niezaimplementowanej zmiany nie jest
> dokumentacją operatora.

## 1. Problem

`backup-runner` to dziś kontener-kombajn: startuje na obrazie `postgres`
(współdzielonym z `dbserverem`) i **doinstalowuje w runtime** `rclone`, `curl`, `jq`
i `ca-certificates` przez `apt-get` w `command:`. Wynikają z tego dwie rzeczy:

1. **Każdy start kontenera wymaga sieci i repozytorium Debiana.** Awaria tej
   instalacji jest cicha aż do 02:30.
2. **Klasa regresji, która już wystąpiła.** Brak `ca-certificates` po przejściu na
   obraz Debiana (`f676fba` → naprawione w `a6d96b0`) objawiał się jako „wygasły
   token OAuth", a notyfikacja o awarii szła tym samym zepsutym HTTPS-em.

Osobno: ścieżka *ręczna* jest już zbudowana z zupełnie innych prymitywów niż nocna.
`make db-backup` robi `docker compose exec dbserver pg_dump`, `make media-backup` robi
`docker run --rm alpine tar` — a nocny cykl wykonuje jedno i drugie **w sobie**, na
narzędziach doinstalowanych apt-getem. Ten projekt sprowadza nocną ścieżkę do tych
samych prymitywów co ręczna. **Nie usuwa natomiast samej duplikacji kodu** — flagi
`pg_dump` nadal będą w dwóch miejscach; patrz §9.

## 2. Decyzja

Zamienić `backup-runner` w **orkiestrator** na obrazie `docker:cli`, który nie robi
nic sam poza sekwencją, a ciężkie kroki wykonuje przez `docker exec` w kontenerach,
które i tak istnieją i mają właściwe narzędzia.

### Rozważone i odrzucone

| Wariant | Dlaczego nie |
|---|---|
| **`iplweb/bpp_backup`, obraz publikowany** (`FROM postgres:${PG}` + rclone) | Matryca buildów per wersja PG, bo `pg_dump` musi być ≥ serwer. Zmiana `DJANGO_BPP_POSTGRESQL_VERSION` przestaje działać z marszu. Repo już raz zapłaciło ten koszt i się wycofało — patrz komentarz w `docker-compose.database.yml:17` („Obraz iplweb/bpp_dbserver jest WYCOFANY") oraz `CHANGELOG.md` w `iplweb/bpp-dbserver`, sekcja `Removed: Cały własny obraz i pipeline jego budowy`. |
| **Jeden obraz na wszystkie serwery** (klient z najnowszego majora) | Technicznie działa — `pg_dump` [obsługuje starsze serwery](https://www.postgresql.org/docs/current/app-pgdump.html) („servers back to version 9.2 are supported") — ale obraz przestaje współdzielić warstwy z `dbserverem`, czyli wracają ~350 MB wycięte w `f676fba`. |
| **Trzy niezależne joby Ofelii + sentinele w `/backup`** | Bariera plikowa naprawia kolejność, ale to własnoręcznie pisany protokół rozproszony (format sentinela, przeterminowanie, kto alarmuje przy niespełnionej barierze) w systemie, w którym awarie backupu bywały nieme. Ofelia nie ma zależności między jobami — trójka jobów o 2:30/2:45/3:00 to nadzieja, nie kolejność. |
| **Cron albo timer systemd na hoście jako orkiestrator** | Daje sekwencję za darmo, ale wynosi harmonogram **poza compose**: `git clone && make up` nie odtwarza backupu. |
| **`build:` lokalnie w compose (bez publikowania)** | Nie usuwa `apt-get`, tylko przesuwa go na `make up`. |
| **pgBackRest / WAL-G (backup fizyczny, PITR)** | Inna decyzja, nie ta. Nie backupuje mediów; niemożliwy w trybie external (brak dostępu do katalogu danych); nieprzenośny między majorami, więc `make upgrade-postgres` i tak potrzebuje `pg_dump`; wymaga restartu bazy (`archive_mode`: *„can only be set at server start"*); wprowadza tryb awarii, w którym zepsuta archiwizacja **kładzie bazę** (*„If the file system containing `pg_wal/` fills up, PostgreSQL will do a PANIC shutdown"*). Ta architektura tego nie zamyka. |

## 3. Architektura docelowa

Dwa serwisy zamiast jednego. **Wszystkie mounty deklaruje compose** — skrypty nie
wywołują `docker run`, więc nie ma w nich żadnej ścieżki hosta.

```yaml
backup-runner:
  image: ${BPP_ORCHESTRATOR_IMAGE:-docker:28-cli}
  restart: always                      # bez tego Ofelia nie ma celu dla job-exec
  logging: *default-logging
  env_file: ${BPP_CONFIGS_DIR}/.env    # KRYTYCZNE — patrz niżej
  environment:
    COMPOSE_PROJECT_NAME: ${COMPOSE_PROJECT_NAME}
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock
    - ${DJANGO_BPP_HOST_BACKUP_DIR}:/backup
    - media:/mediaroot:ro
    - ${BPP_CONFIGS_DIR}/rclone:/config/rclone:ro   # tylko do `test -f` — patrz niżej
    - ./scripts:/scripts:ro
  entrypoint: ["/bin/sh", "-c"]
  command: ["exec sleep infinity"]
  healthcheck: docker version … && (set -o pipefail)   # patrz §4
  labels: ofelia.job-exec.backup_cycle → /scripts/backup-cycle.sh, 02:30

rclone:
  image: ${BPP_RCLONE_IMAGE:-rclone/rclone:<pin>}
  restart: always
  logging: *default-logging
  env_file: ${BPP_CONFIGS_DIR}/.env
  volumes:
    - ${BPP_CONFIGS_DIR}/rclone:/config/rclone      # RW — token refresh
    - ${DJANGO_BPP_HOST_BACKUP_DIR}:/backup:ro
    - ./scripts:/scripts:ro                         # rclone-sync.sh, rclone-config.sh
  entrypoint: ["/bin/sh", "-c"]
  command: ["exec sleep infinity"]
  healthcheck: rclone version && [ -s /etc/ssl/certs/ca-certificates.crt ]
```

**`env_file` jest krytyczny, nie kosmetyczny.** `backup-cycle.sh` czyta
`DJANGO_BPP_RCLONE_REMOTE`, `DJANGO_BPP_BACKUP_KEEP_LAST`,
`DJANGO_BPP_RCLONE_KEEP_MONTHS`, `DJANGO_BPP_HOSTNAME`, `PARALLEL_JOBS`. Bez niego
operator z `DJANGO_BPP_RCLONE_KEEP_MONTHS=` (udokumentowany wyłącznik, chroniony
przez `${VAR-12}`) dostaje po wdrożeniu **włączone kasowanie zdalnych kopii**.

**Orkiestrator montuje katalog configu rclone `:ro`, choć sam rclone'a nie uruchamia.**
`backup-cycle.sh:170` sprawdza `[ ! -f "$RCLONE_CONFIG" ]` przed wysyłką; bez tego
mountu warunek byłby prawdziwy **zawsze** i cykl padałby co noc na
`fail rclone-config-missing 3`. Alternatywa (sprawdzenie przez `docker exec … test -f`)
jest droższa bez zysku. Zapis do configu robi wyłącznie serwis `rclone`, który ma go RW.

**Sonda CA zostaje w healthchecku serwisu `rclone`** mimo że obraz upstreamu ma
bundle: `BPP_RCLONE_IMAGE` pozwala podstawić dowolny obraz, a CLAUDE.md wprost
zakazuje usuwania tego sprawdzenia.

### Dlaczego `rclone` jest serwisem, a nie `docker run --rm`

1. **Compose ściąga obrazy tylko zadeklarowanych serwisów.** Obraz użyty wyłącznie
   w `docker run` wewnątrz skryptu byłby pobierany dopiero o 02:30.
2. **`make up` kończy się `docker system prune -af`** (`mk/deployment.mk`), który usuwa
   [*„all images without at least one container associated to them"*](https://docs.docker.com/reference/cli/docker/system/prune/).
   Kontener `--rm` znika natychmiast, więc obraz **byłby kasowany przy każdym
   `make up`** → pull z Huba co noc, a rate limit albo awaria sieci o 02:30 to
   `exit 3`. Działający serwis chroni obraz, bo `make up` podnosi wszystko **przed**
   prune.
3. **Znika klasa błędu „ścieżki hosta w `-v`"**: `docker run -v /backup:…` z wnętrza
   kontenera zamontowałby pustą ścieżkę hosta — mount by się udał, dane nie.

Healthcheck orkiestratora sonduje **dostęp do socketu**. Uwaga na przyszłość:
`docker:cli` działa jako uid 0 i dlatego otwiera socket `root:root` niezależnie od
grupy — **dodanie `user:` do orkiestratora to zepsuje**.

## 4. Zgodność z busybox ash — co zmieniamy, a czego świadomie nie

`docker:cli` i `rclone/rclone` **nie mają basha**, więc shebang `#!/usr/bin/env bash`
w czterech skryptach daje `env: can't execute 'bash'`, **rc=127 przed startem
skryptu** — awaria bez notyfikacji, dokładnie ta klasa, którą projekt ma likwidować.

**Ale to jedyna twarda awaria.** Audyt (uruchomienie w prawdziwych obrazach) wykazał,
że busybox 1.37 w `docker:cli`, `docker:28-cli` i `rclone/rclone` jest zbudowany
z bash-compat i **wspiera** `trap ERR`, `set -E`, `$'...'`, `10#` oraz podstawienia
procesów. Z tego wynikają dwie rzeczy sprzeczne z rewizją 2 tego specu:

1. **E2E pod busyboxem NIE wykryje bashizmów** — one tam przechodzą. Kontraktu
   pilnuje wyłącznie `shellcheck shell=sh`. Rewizja 2 kładła akcent odwrotnie.
2. **Pełne przepisanie na POSIX nie jest wymuszone.** Jest wyborem obronnym:
   bash-compat to opcja kompilacji busyboksa (`CONFIG_ASH_BASH_COMPAT`), a
   `BPP_ORCHESTRATOR_IMAGE`/`BPP_RCLONE_IMAGE` pozwalają operatorowi podstawić
   dowolny obraz.

### Decyzja: zmieniamy to, co darmowe albo korzystne; resztkową zależność czynimy jawną

Pełne przepisanie oznaczałoby pięć pułapek (niżej) w kodzie, którego awarie są
historycznie ciche, a wartość ujawnia się dopiero w dniu odtwarzania. To wymiana
ryzyka hipotetycznego na natychmiastowe. Zakres zmian:

| Konstrukcja | Decyzja | Uzasadnienie |
|---|---|---|
| `#!/usr/bin/env bash` (4 pliki) | → `#!/bin/sh` | jedyna twarda awaria |
| `trap 'fail …' ERR` + `set -E` | → `trap on_exit EXIT` z guardem | i tak lepsze: łapie więcej i nie zależy od wsparcia dla ERR; wzorzec zweryfikowany pod ash |
| `${to_purge%%$'\n'*}` | → `printf '%s\n' "$x" \| sed -n '1p'` | trywialne; **nie `head -1`** — SIGPIPE pod `pipefail` wywraca cały backup |
| `10#$y` / `10#$m` w `_ym_index` | → zdjęcie wiodących zer (`${m#0}`) | trywialne, ale **pułapka**: samo skasowanie `10#` daje `$((08))` = `arithmetic syntax error`, czyli wywrócenie retencji w sierpniu i wrześniu |
| `exec > >(tee -a "$LOG") 2>&1` | **ZOSTAJE** | jedyne miejsce, gdzie POSIX kosztuje niezawodność: zamiennik `mkfifo`+`tee` dowodnie **wprowadza** zombie-`tee` na każdy cykl (PID1 to `sleep`, nie żnie dzieci) oraz nową ścieżkę SIGPIPE. Nie konwertujemy działającego na wymagające dwóch nowych zabezpieczeń |
| `local` | **ZOSTAJE** | wspierane przez ash i dash powszechnie |
| `numfmt` w `fmt_size` | → `awk` | narzędzia nie ma w żadnym z obrazów, więc dzisiejszy fallback odpalałby się **zawsze** — Rollbar dostawałby `"1234567B"` w każdym komunikacie |
| `jq`, `curl` w `notify_rollbar` | znikają | krok 6, §5 |

### Zależność resztkowa: jawna, nie niema

Dwa świadome odstępstwa od POSIX (podstawienie procesów, `local`) dostają
w skryptach dyrektywy `# shellcheck shell=sh` + `disable=` **z komentarzem
uzasadniającym**. Dzięki temu zależność od bash-compat jest zadeklarowana
i przeglądana w code review, a nie odkrywana po awarii.

Do tego **preflight i healthcheck zamiast nadziei**: każdy z trzech skryptów zaczyna
się od twardego sprawdzenia powłoki, a orkiestrator ma to samo w healthchecku.

```sh
if ! (set -o pipefail) 2>/dev/null; then
    echo "BLAD: ten skrypt wymaga powloki z pipefail (busybox ash lub bash)." >&2
    echo "      dash go nie ma - uruchom przez bash albo w kontenerze." >&2
    exit 1
fi
```

Powód jest konkretny: **`set -o pipefail` zabija skrypt pod dashem** (zweryfikowane na
Debianie 11 i 12), a po zmianie shebanga na `#!/bin/sh` bezpośrednie uruchomienie na
hoście linuksowym trafia właśnie na dash. Preflight zamienia dziwną śmierć w nazwaną,
a healthcheck sprawia, że niekompatybilny obraz jest **unhealthy przy `make up`**,
a nie o 02:30 — ta sama lekcja co sonda CA.

### Kontrakty do przypięcia przy przepisywaniu

Wszystkie zweryfikowane eksperymentalnie pod busybox ash:

1. **Każda komenda wewnątrz `on_exit`/`report_fail` musi mieć `|| true`** (z komentarzem
   dlaczego). Błąd w trapie ucina go w połowie, `exit "$rc"` nie zostaje osiągnięty
   i **kod wyjścia jest klobrowany** (7→1). Nowy kanał notyfikacji to
   `docker exec appserver`, który pada dokładnie wtedy, gdy appserver leży — czyli
   w scenariuszu, o którym raportujemy. Dzisiejszy bash ma tę samą wadę, więc to nie
   regresja, ale nowy kanał jest bardziej awaryjny.
2. **`fail` wolno wołać wyłącznie z top-levelu.** W podpowłoce `exit` kończy tylko
   podpowłokę, guard nie wraca do rodzica (podwójna notyfikacja), a `log` z `fail`
   trafia do zmiennej zamiast do loga. Dziś żadne z pięciu wywołań nie jest
   w podpowłoce — i tak musi zostać.
3. **W `$( )` tylko pojedyncza komenda albo potok, którego status jest statusem
   podstawienia.** Błąd nie-ostatniej komendy ash połyka bezgłośnie, a dzisiejszy
   bash z `trap ERR` go łapał. To jedyna realna regresja siatki bezpieczeństwa
   i dlatego jest kontraktem, nie uwagą.
4. **Deklaracja `local` oddzielona od przypisania z `$( )`** — `local v="$(cmd)"`
   maskuje status także w busyboksie. Obecny kod to respektuje; przepisanie nie może
   tego scalić.
5. **`trap '' PIPE`** — śmierć `tee` daje SIGPIPE, rc=141, **bez trapa EXIT
   i bez notyfikacji**. Zignorowanie SIGPIPE sprawia, że zapis zwraca błąd
   i odpala normalną ścieżkę `set -e` → trap → notyfikacja.

Zweryfikowane jako szczelne (nie wymagają zmian): trap EXIT łapie abort z `set -e`
i widzi właściwy `rc`; guard `BPP_INTENDED_EXIT` działa; `pipefail` dziedziczy się
do `$( )`; `while … done | sort` w podpowłoce propaguje kod wyjścia poprawnie — więc
retencja zdalna **nie** była zagrożona.

## 5. Przebieg cyklu

`backup-cycle.sh` zostaje **jednym skryptem**: `set -eu -o pipefail`, trap EXIT,
kody wyjścia 1/2/3 i jeden raport do Rollbara.

| Krok | Dziś | Docelowo |
|---|---|---|
| 1. `pg_dump` | lokalnie w backup-runnerze | `docker exec <dbserver> sh -c 'PGPASSWORD="$DJANGO_BPP_DB_PASSWORD" pg_dump -Fd -j N … -f /backup/db-backup-$TS'` |
| 2. `tar` dumpu | lokalnie | lokalnie w orkiestratorze (busybox `tar`, `/backup` zamontowany) |
| 3. `tar` mediów | lokalnie | lokalnie w orkiestratorze (`media:/mediaroot:ro`) |
| 4. rotacja lokalna | lokalnie | bez zmian |
| 5. `rclone copy` + retencja | lokalnie | `docker exec <rclone> rclone …` przez shim, patrz niżej |
| 6. notyfikacja | `curl` + `jq` | `docker exec <appserver> python -c …` |

**Krok 1 — hasło.** Lokalny `dbserver` ma tylko `POSTGRES_PASSWORD`; `PGPASSWORD` ma
wyłącznie sentinel w trybie external. Dlatego hasło bierzemy **wewnątrz** kontenera
z `DJANGO_BPP_DB_PASSWORD` (jest tam w obu trybach przez wholesale `env_file`) —
sekret nie przechodzi przez `-e`, spójnie z krokiem 6. Mount `/backup` mają oba
warianty `dbservera`, więc pod tym względem rozgałęzienia nie ma.

**Krok 5 — shim, nie przeróbka biblioteki.** `lib-rclone.sh` jest source'owana w
dwóch kontekstach: przez `backup-cycle.sh` (orkiestrator, gdzie `rclone` nie istnieje)
i przez `rclone-sync.sh`/`rclone-config.sh` (wnętrze kontenera rclone, gdzie nie
istnieje `docker`). Biblioteka **zostaje czysta** — woła `rclone` z `PATH` — a
`backup-cycle.sh` definiuje przed jej wczytaniem:

```sh
rclone() { docker exec "$(bpp_container rclone)" rclone "$@"; }
```

**Krok 6.** Python w appserverze escapuje JSON sam (dziś robi to `jq`), a
`ROLLBAR_ACCESS_TOKEN` bierze z własnego `env_file`. Świadomy koszt: **alert
o nieudanym backupie wymaga żywego appservera**. Odrzucona alternatywa: busybox `wget
--post-data` w orkiestratorze (jest, razem z bundlem CA) — odpada, bo ręczne
escapowanie JSON-a to dokładnie ta robota, którą `jq -Rs` robi poprawnie.

**Adresowanie kontenerów** — przez labele
`com.docker.compose.service=<usługa>` + `com.docker.compose.project=$COMPOSE_PROJECT_NAME`,
nie po nazwie (compose nazwy generuje). `COMPOSE_PROJECT_NAME` wstrzykujemy jawnie
przez `environment:`, bo mieszka w repo-lokalnym `.env`, a nie w konfiguracyjnym.

## 6. Kontrakty i kompatybilność wsteczna

- `make backup-cycle`, `make db-backup`, `make media-backup` — **API bez zmian**.
- `make rclone-check` (jedyny wołający dziś gołe `rclone`) zmienia tylko nazwę
  serwisu. `make rclone-sync` i `make rclone-config` **dalej delegują do skryptów** —
  pilnują tego asercje `test_rclone_single_source_of_truth`, a `rclone-config.sh`
  niesie `rclone_fix_config_owner`. Dlatego serwis `rclone` montuje `./scripts`.
- `BPP_BACKUP_PG_IMAGE` **staje się martwa**. Tolerowana i ignorowana w starym `.env`,
  bez migracji — wzorzec `DJANGO_BPP_ENABLE_HTML2DOCX_IMAGE`. Usunąć tylko z części
  **zapisującej**: `scripts/init-configs.sh` i `scripts/ensure-config-files.sh`.
- Nowe: `BPP_ORCHESTRATOR_IMAGE`, `BPP_RCLONE_IMAGE` — obie z domyślną w compose.
- Oba nowe serwisy dostają `logging: *default-logging` (anchor nie przekracza granicy
  `include:` — własny w `docker-compose.backup.yml`).
- **Asymetria wdrożenia zostaje:** zmiany w `scripts/` wchodzą samym `git pull`
  (bind-mount, Ofelia woła skrypt w działającym kontenerze), ale **cała ta migracja
  jest zmianą obrazów i `command:`, więc wymaga `make up`**.
- `rclone_fix_config_owner` zostaje. Rozważane `user:` na serwisie `rclone` ma ukrytą
  interakcję: nie-root nie wykona `chown` i funkcja zwróci rc=3.

## 7. Testy

- `scripts/test-rclone.sh`: dochodzi atrapa `docker`; realnie zastępuje atrapy
  `rclone` i `pg_dump`, ale `date` (MOCK_YM) i `tar` zostają, a ścieżka
  `rclone-sync.sh` **nadal potrzebuje atrapy `rclone`** (wykonuje się w kontenerze
  rclone, nie w orkiestratorze).
- **`shellcheck shell=sh` jest jedynym egzekutorem zgodności** — e2e pod busyboxem
  bashizmów NIE wykryje (bash-compat, §4). Dodatkowy przebieg pod `docker:cli` ma
  sens, ale jako test *działania* skryptu w docelowym środowisku, nie jako sonda
  POSIX-owości.
- **Hostowe wywołania w `scripts/test-rclone.sh` muszą zostać przez `bash`**
  (dziś tak są: `bash "$CYCLE"`). Po zmianie shebanga „uproszczenie" tego do `sh`
  zabije test na Linuksie, bo dash nie zna `pipefail`.
- Asercja mutacyjna: `backup-cycle.sh` nie zawiera `docker run` ani ścieżek hosta.
- `tests/test_makefile.sh`: serwis `rclone` zadeklarowany; `backup-runner` bez
  `apt-get`; oba z `restart: always`, `logging`, `env_file`; healthcheck orkiestratora
  sondujący socket; healthcheck rclone z sondą CA.
- **Do wymiany:** `test_backup_runner_ca_certificates` — asertuje pakiety, których nie
  będzie. `test_rclone_config_mount_writable` przeżywa, jeśli mount zostaje w tym
  samym pliku.

## 8. Dokumentacja do wymiany

`backup-runner` występuje **18 razy w `docs/`**: `eksploatacja/backup-i-rclone.md`,
`eksploatacja/przenosiny-serwera.md`, `architektura/uslugi.md`,
`architektura/zadania-ofelia.md`. W `CLAUDE.md` cała sekcja *„CRITICAL:
`ca-certificates` musi zostać na liście pakietów"* staje się martwa — trzeba ją
**przepisać na nową architekturę**, a nie skasować: jej anti-fixy wciąż uczą czegoś
prawdziwego o sondzie CA w healthchecku, a zostawione bez zmian zaczną mylić agentów.
Zdezaktualizuje się też komentarz w `mk/rclone.mk:3-6` o `apk add` i czekaniu na
healthcheck. Obowiązuje skill `docs-sync`.

## 9. Czego ten projekt NIE robi

Nie usuwa duplikacji między ścieżką ręczną a nocną: flagi `pg_dump` zostają
w `mk/database.mk` i `backup-cycle.sh`, tar mediów ma dwie implementacje
(`docker run --rm alpine` w make, busybox `tar` w orkiestratorze). Unifikacja
wymagałaby wspólnych `scripts/backup-db.sh` / `backup-media.sh` wołanych z obu
kontekstów (host: `docker compose exec`, orkiestrator: `docker exec` po labelach) —
osobne zadanie, zgodne z zasadą „logika w `scripts/`, targety cienkie".

## 10. Historia rewizji

**Rewizja 2 (self-review specu).** Bloker: brak basha w obrazach → nowa §4. Bloker:
brak `PGPASSWORD` w lokalnym `dbserverze` → poprawiony krok 1. Dodany `env_file`
i `COMPOSE_PROJECT_NAME`; sprostowany opis targetów rclone i dodany mount `./scripts`
do serwisu `rclone`; rozstrzygnięty dwukontekstowy `lib-rclone.sh` (shim); osłabiony
problem 3 do faktycznego zakresu (§1, §9); dodana §8. Drobne: `restart: always`; sonda
CA w healthchecku rclone; sprostowany licznik kontenerów z `docker.sock` (dziś
**pięć**: ofelia, autoheal — rw — i trzy monitoringowe; będzie sześć); świadomie
odrzucona alternatywa `wget` w kroku 6.

**Rewizja 3 (audyt bashizmów i semantyki `exit`, wszystko weryfikowane uruchomieniem).**

- **Błąd w specu:** orkiestrator nie montował katalogu configu rclone, więc
  `[ ! -f "$RCLONE_CONFIG" ]` byłoby prawdziwe zawsze → `fail rclone-config-missing 3`
  **co noc**. Dodany mount `:ro` (§3).
- **Obalona teza rewizji 2:** busybox 1.37 ma bash-compat, więc e2e pod nim nie
  wykrywa bashizmów, a pełne przepisanie na POSIX nie jest wymuszone — jedyną twardą
  awarią jest shebang. §4 przepisana: zakres zawężony do zmian darmowych albo
  korzystnych, reszta zadeklarowana jawnie przez `shellcheck disable=` plus preflight
  i healthcheck.
- **`exec > >(tee)` zostaje** — zamiennik `mkfifo` wprowadza zombie-`tee` na każdy
  cykl i nową ścieżkę SIGPIPE.
- **Pięć nowych kontraktów** (§4): `|| true` w trapie (inaczej klobrowanie kodu
  wyjścia), `fail` tylko z top-levelu, jedna komenda w `$( )`, `local` oddzielony od
  przypisania, `trap '' PIPE`.
- **Pułapka przepisania:** skasowanie `10#` bez zdjęcia wiodących zer wywraca
  retencję w miesiącach 08 i 09.
- **`pipefail` nie działa pod dashem** (Debian 11/12) → preflight w skryptach
  i utrzymanie `bash` w wywołaniach hostowych testów.
- **Fałszywy alarm:** `while … done | sort` w podpowłoce propaguje kod wyjścia
  poprawnie; retencja nie była zagrożona.
- `numfmt` nie istnieje w żadnym z obrazów → `fmt_size` przechodzi na `awk`
  (przestaje być kwestią otwartą).

## 11. Kwestie otwarte

- Pin wersji `rclone/rclone` i `docker:cli`.
- Czy `rclone` dostaje limit pamięci (dziś `backup-runner` jako jedyny go nie ma).

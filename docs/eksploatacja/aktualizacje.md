# Aktualizacje i wersje obrazów

Jak bezpiecznie aktualizować obrazy `iplweb/bpp_*` na działającej instalacji:
przypięcie wersji (`make zaspawaj-wersje`), próba generalna migracji na kopii
produkcyjnej bazy (`make test-upgrade`) i zalecany przepływ aktualizacji.

## Problem: ruchomy tag `latest`

Domyślnie obrazy `iplweb/bpp_*` jadą na tagu `latest`
(`${DOCKER_VERSION:-latest}` w plikach compose). To wygodne, ale ma dwie
konsekwencje:

- **każdy `make pull` może podmienić wersję** — także "przy okazji", gdy
  chodziło tylko o restart;
- **nie wiadomo, co dokładnie jest wdrożone** — dwa hosty robiące deploy
  w odstępie godziny mogą dostać różne obrazy, a po awarii trudno wskazać
  wersję, do której należałoby wrócić.

Obrazy spoza rodziny iplweb (nginx, redis, grafana, netdata, …) są przypięte
na sztywno w plikach compose i nie podlegają temu mechanizmowi; PostgreSQL ma
własną zmienną `DJANGO_BPP_POSTGRESQL_VERSION`
([PostgreSQL — wersje i upgrade](../konfiguracja/postgresql.md)).

## `make zaspawaj-wersje` — przypięcie wersji

```bash
make zaspawaj-wersje                  # wersja z działającego appservera
make zaspawaj-wersje TAG=202606.1386  # jawny tag
```

Target utrwala w `$BPP_CONFIGS_DIR/.env` zmienną
`DOCKER_VERSION=<tag CalVer>` odpowiadającą wersji, na której **faktycznie
chodzi** kontener `appserver`. Celowo nie patrzy na lokalny tag `latest`:
po `make pull` bez recreate lokalny `latest` może już wskazywać nowszy,
nieprzetestowany obraz — zaspawanie ma przybić stan faktyczny produkcji,
nie stan cache'u obrazów.

Wersja jest rozwiązywana z digestu działającego kontenera przez API Docker
Huba (tagi CalVer postaci `RRRRMM.NNNN`, np. `202606.1386`). Przy okazji
target sprawdza, czy pozostałe kontenery iplweb (`authserver`,
`workerserver`, `denorm-queue`, `celerybeat`) chodzą na tej samej wersji —
rozjazd to tylko ostrzeżenie (wyrówna go następne `make up`).

Po zaspawaniu:

- `make restart`, awaryjny recreate i nocne restarty Ofelii trzymają się
  przypiętej wersji — nic nie wjedzie "samo";
- nowa wersja wymaga **jawnej decyzji**:

```bash
make zaspawaj-wersje TAG=<nowy> && make pull && make up
```

Nic nie jest restartowane w momencie zaspawania — pin obowiązuje od
następnej operacji compose. Host bez zaspawania (brak `DOCKER_VERSION`
w `.env`) działa po staremu, na `latest`.

## `make test-upgrade` — próba generalna migracji

Najczęstszy scenariusz katastrofy przy aktualizacji to nowy obraz, którego
migracje bazodanowe nie przechodzą — wykrywany dopiero w trakcie deployu,
gdy stare kontenery już nie działają. `test-upgrade` wykrywa go **obok**
produkcji, na świeżej kopii produkcyjnych danych:

```bash
make test-upgrade                  # kandydat = najnowszy tag CalVer z Docker Huba
make test-upgrade TAG=202606.1386  # jawny kandydat
```

Przebieg:

1. **Kandydat** — obraz pobierany **po tagu wersji**, nigdy przez `:latest`
   (lokalny `latest`, na którym chodzi produkcja, pozostaje nietknięty).
2. **Kontrola miejsca** — wymagane ≈ 2,5× rozmiaru bazy (dump + rozpakowanie
   + shadow-wolumen); brak miejsca przerywa próbę zanim cokolwiek ruszy.
   Wymuszenie pominięcia: `SKIP_DISK_CHECK=1 make test-upgrade`.
3. **Backup** — świeży `make db-backup`; błąd backupu przerywa całość.
4. **Shadow stack** — `bpp-shadow-dbserver` (ta sama wersja PostgreSQL co
   produkcja) + `bpp-shadow-redis` na osobnej sieci dockerowej `bpp-shadow`,
   poza projektem Compose, z przyciętymi limitami zasobów.
5. **Restore** dumpa do shadow-bazy (`pg_restore -j`).
6. **Migracja** — `manage.py migrate` obrazem-kandydatem z nadpisanym
   entrypointem: nic poza migracją się nie uruchamia.

Wynik:

- **Sukces (exit 0)** — komunikat, pełne sprzątnięcie shadow stacka.
  Produkcja przez cały czas była nietknięta.
- **Porażka (exit 1)** — shadow stack **zostaje** do inspekcji:

```bash
docker exec -it bpp-shadow-dbserver psql -U $DJANGO_BPP_DB_USER -d $DJANGO_BPP_DB_NAME
make test-upgrade-clean   # sprzątnięcie po obejrzeniu
```

Gwarancje: próba nie dotyka kontenerów ani wolumenów produkcji, nie zmienia
lokalnego tagu `latest`, nie zapisuje niczego do `.env`. Jedyny koszt to
obciążenie CPU/IO podczas dump+restore — na małych hostach uruchamiaj poza
godzinami szczytu.

Limity zasobów shadow stacka można nadpisać zmiennymi środowiskowymi:
`SHADOW_DB_MEM` (domyślnie `1g`), `SHADOW_DB_CPUS` (`1.0`),
`SHADOW_REDIS_MEM` (`256m`), `SHADOW_MIGRATE_MEM` (`2g`),
`PARALLEL_JOBS` (`4`, liczba wątków pg_restore).

## Zalecany przepływ aktualizacji

Na zaspawanym hoście:

```bash
make test-upgrade                          # 1. migracje kandydata przechodzą?
make zaspawaj-wersje TAG=<kandydat>        # 2. przypnij nową wersję
make pull && make up                       # 3. właściwy deploy (health-gate --wait)
```

Kolejność jest istotna: dopiero po udanej próbie generalnej przypinamy
kandydata i dotykamy produkcji. `make up` używa `--wait`, więc niewstający
appserver zwróci błąd zamiast cicho zostawić niedziałający stack.

## Powrót po nieudanej aktualizacji

Zaspawanie czyni ręczny rollback przewidywalnym: stara wersja jest zapisana
w historii `.env` (i w outputach `zaspawaj-wersje`), a świeży dump leży
w katalogu backupów.

```bash
make zaspawaj-wersje TAG=<poprzedni>       # wróć do poprzedniej wersji obrazów
make pull && make up
make restore                               # tylko gdy migracja zdążyła zmienić schemę
```

`make restore` cofa też dane wpisane po backupie — używaj go wyłącznie, gdy
nowa migracja faktycznie zmieniła schemę w sposób niekompatybilny ze starym
obrazem. Szczegóły restore: [Backup i rclone](backup-i-rclone.md).

## Automatyczna aktualizacja (`make autoupdate`)

Zamiast ręcznego `git pull && make run` po każdej nowej publikacji, host może
sam co jakiś czas sprawdzać, czy jest co wdrożyć, i wdrażać to bez logowania.

```bash
make autoupdate
```

`make autoupdate` uruchamia **pętlę**: co `AUTOUPDATE_INTERVAL` sekund
(domyślnie `7200` = 2 h) woła `scripts/autoupdate.sh`, który wykonuje **jeden
cykl**:

1. `git fetch` — czy `origin/main` wyprzedza lokalny HEAD (i czy fast-forward
   jest możliwy);
2. `docker compose pull` — czy któryś obraz zmienił **digest** (działa też dla
   ruchomego `latest`, bo porównujemy digesty, nie tagi). Log wymienia obraz
   i kierunek zmiany, np. `iplweb/bpp_appserver:latest  a1b2c3d4e5f6 -> 9a8b7c6d5e4f`;
3. jeśli **jest** nowy commit **lub** nowy obraz → opcjonalny backup bazy →
   `git pull --ff-only` → `make run`. Jeśli **nie** ma zmian → cykl kończy się
   po cichu, nic nie jest restartowane.

!!! note "Samo zniknięcie tagu to nie jest nowsza wersja"
    W logu może pojawić się linia w rodzaju:

    ```
    mcuadros/ofelia:0.3.21: sam TAG BRAK -> 254bae8e1785 — to nie jest nowsza wersja, pomijam.
    ```

    Oznacza, że obraz **stracił lokalny tag**, a `pull` mu go przywrócił — sam
    obraz cały czas był na dysku (widać po tym, że pull trwa sekundy: nie ma
    czego ściągać). Robi to `docker system prune -af` z końca `make up`: obrazu
    używanego przez działający kontener nie potrafi skasować, więc zdejmuje
    z niego referencję.

    Do sierpnia 2026 autoupdate liczył to jako nową wersję i **wdrażał
    produkcję od nowa co cykl, w nieskończoność** — objawiało się jako „Wykryto
    nowszy obraz Docker." przy obrazie, który nowszy nie był. Pomijanie takich
    przejść niczego nie gubi: prawdziwie nowy obraz zawsze daje
    `ID_stare -> ID_nowe`, a nowa usługa w `docker-compose.*.yml` przychodzi
    razem z commitem, więc deploy odpala się ścieżką „nowy commit".

### Uruchomienie pod `screen` (zalecane)

Pętla musi działać niezależnie od Twojej sesji SSH — najprościej pod nazwaną
sesją `screen`. Jest do tego gotowy target:

```bash
make screen-with-autoupdate   # start pętli w tle, w sesji screen 'bpp-autoupdate'
screen -r bpp-autoupdate      # podgląd (Ctrl-A D = odłącz)
```

`make screen-with-autoupdate` jest **idempotentny**: gdy sesja już działa, nie
uruchamia drugiej. Nazwę sesji można zmienić przez `AUTOUPDATE_SCREEN_NAME`.
Zatrzymanie: `screen -S bpp-autoupdate -X quit`.

### Co odświeża się samo, a co jest zamrożone {#samorestart-petli}

Po `git pull` **prawie wszystko** działa od razu, bez dotykania sesji:

| Element | Odświeża się sam? |
|---|---|
| `scripts/autoupdate.sh` | **Tak** — pętla woła go świeżo w każdej iteracji |
| pozostałe skrypty, `defaults/*`, pliki compose | **Tak** — używa ich `make run` w trakcie deployu |
| **treść pętli** (`mk/deployment.mk`) i **`AUTOUPDATE_INTERVAL`** | **Nie** — `make autoupdate` rozwinął je przy starcie i ten proces żyje dalej |

Ostatni wiersz załatwia **samorestart**: gdy `git pull` zmieni `Makefile` albo
`mk/deployment.mk`, cykl kończy deploy, po czym **zamyka własną sesję screen** —
a strażnik z crona podnosi ją w nowej wersji (do 15 minut).

!!! warning "Samorestart wymaga strażnika"
    Mechanizm uruchamia się **tylko** gdy w crontabie stoi wpis
    `# BPP-AUTOUPDATE` (zakłada go `make setup-autoupdate-cron`) **i** pętla
    naprawdę działa pod `screen`. Bez tego nie ma kto jej wskrzesić, więc
    zamiast zabić sesję skrypt wypisuje ostrzeżenie i prosi o ręczne:

    ```bash
    screen -S bpp-autoupdate -X quit && make screen-with-autoupdate
    ```

    Cicha śmierć pętli byłaby gorsza niż praca na starym ciele pętli — dlatego
    ten warunek jest twardy. Sprawdzenie: `crontab -l | grep BPP-AUTOUPDATE`.

Komunikat o zamknięciu sesji trafia **także** do logu strażnika
(`AUTOUPDATE_CRON_LOG`, domyślnie `.autoupdate-cron.log` w katalogu repo) — bufor
okna `screen` ginie razem z sesją, więc bez tego nie byłoby śladu, dlaczego pętla
zniknęła. Wyłącznik: `AUTOUPDATE_SELF_RESTART=0`.

Odpowiednik ręczny (gdy wolisz sam zarządzać sesją):

```bash
screen -dmS bpp-autoupdate make autoupdate
```

`make autoupdate` nie demonizuje się sam — to celowo najprostsza forma:
widoczna, podpinana, bez uprawnień roota. Żeby pętla przeżyła restart hosta
**i** padnięcie sesji, zainstaluj strażnika w cronie (niżej).

### Strażnik w cronie (`make setup-autoupdate-cron`)

Sama sesja `screen` nie wstaje po restarcie hosta, a gdy padnie (OOM,
przypadkowe `screen -X quit`, zabity proces), auto-aktualizacja milknie i nikt
się o tym nie dowie — host po cichu przestaje się aktualizować. Jedno polecenie
instaluje w crontabie użytkownika wpis-strażnik, który tego pilnuje:

```bash
make setup-autoupdate-cron    # zainstaluj wpis (domyślnie co 15 minut)
make remove-autoupdate-cron   # usuń wpis
make test-autoupdate-cron     # unit-testy skryptu instalującego
```

Zainstalowany wpis to jedna linia postaci:

```cron
*/15 * * * * cd '/opt/bpp-deploy' && PATH='…' make screen-with-autoupdate >> '…/autoupdate-cron.log' 2>&1  # BPP-AUTOUPDATE
```

Ponieważ `make screen-with-autoupdate` jest **idempotentny** (nie startuje
drugiej sesji, gdy pierwsza żyje), jeden okresowy wpis pokrywa **zarówno**
restart hosta, **jak i** padnięcie sesji. To główna przewaga nad zalecanym
wcześniej wpisem `@reboot`, który reaguje wyłącznie na restart.

We wpisie zamrażany jest **minimalny** `PATH` — same katalogi, w których leżą
`make`, `docker`, `git`, `screen` i `bash`, plus standardowe systemowe. Powód
jest dwojaki: cron startuje zadania z jałowym `PATH=/usr/bin:/bin`, w którym te
binarki bywają niewidoczne, ale wklejenie całego `PATH` powłoki też jest złe —
crony z rodziny Vixie (Debian, Ubuntu, `cronie`) tną komendę powyżej ok. 1000
znaków, a rozbudowany `PATH` (`nvm`, `pyenv`, `asdf`, homebrew) sam potrafi mieć
kilka tysięcy. Skrypt pilnuje tego limitu i odmówi instalacji zbyt długiego
wpisu, zamiast zapisać uszkodzony.

`make remove-autoupdate-cron` usuwa wyłącznie linie oznaczone markerem
`# BPP-AUTOUPDATE`. **Nie ubija** przy tym działającej sesji — jeśli chcesz
zatrzymać także pętlę, zrób to osobno:

```bash
make remove-autoupdate-cron
screen -S bpp-autoupdate -X quit
```

Instalacja (i usuwanie) przepisuje cały crontab użytkownika, więc przed zapisem
powstaje kopia zapasowa `crontab.bak.<timestamp>` w katalogu logu strażnika.
Cudze wpisy w crontabie są zachowywane — filtrowany jest tylko marker
`# BPP-AUTOUPDATE`. Ponowna instalacja (także ze zmienionym harmonogramem)
podmienia wpis, nie dubluje go.

#### Log strażnika

Wyjście wpisu trafia do `AUTOUPDATE_CRON_LOG`, domyślnie
`$BPP_CONFIGS_DIR/logs/autoupdate-cron.log` (katalog jest zakładany przy
instalacji). Przy żywej sesji strażnik dopisuje dokładnie 2 linie na tick
(„sesja już działa" + podpowiedź `screen -r`), czyli ~9,6 kB na dobę przy
domyślnym `*/15` — **ok. 3,5 MB rocznie**. Wyjście właściwego deploya tam nie
idzie: `screen -dmS` odłącza sesję, więc logi `make run` zostają w buforze
screena.

Rotacji logu **celowo nie ma** — przy tym tempie przyrostu logrotate byłby
nieproporcjonalny. Ręczne wyjście awaryjne, gdy plik urośnie:

```bash
truncate -s 0 "$BPP_CONFIGS_DIR/logs/autoupdate-cron.log"
```

!!! warning "Sesja wskrzeszona przez crona nie ma agenta SSH"
    Gdy strażnik restartuje pętlę, sesja dziedziczy **środowisko crona** —
    bez `SSH_AUTH_SOCK` i z minimalnym zestawem zmiennych. Jeśli `origin`
    repozytorium jest po SSH z kluczem chronionym passphrase w agencie,
    `git fetch` w `scripts/autoupdate.sh` zawiedzie. Skrypt traktuje to
    **miękko**: loguje ostrzeżenie i pomija część gitową — auto-aktualizacja
    po cichu degraduje do „tylko nowe obrazy Docker", inaczej niż sesja
    odpalona ręcznie z Twojej powłoki. Dla nienadzorowanej aktualizacji ustaw
    `origin` po **HTTPS** albo użyj klucza **bez passphrase**.

!!! tip "Wolisz własny wpis w crontabie?"
    Ręczny wariant nadal działa — dopisz do `crontab -e` linię wołającą ten sam
    idempotentny target (`@reboot` pokrywa wtedy tylko restart hosta, nie crash
    sesji):

    ```cron
    @reboot cd /ścieżka/do/bpp-deploy && make screen-with-autoupdate
    ```

    Ten sam `scripts/autoupdate.sh` można też wołać bezpośrednio z crona lub
    z timera `systemd` — logika jednego cyklu jest oddzielona od harmonogramu.

### Konfiguracja (zmienne środowiskowe / `.env`)

| Zmienna | Domyślnie | Znaczenie |
|---|---|---|
| `AUTOUPDATE_INTERVAL` | `7200` | Odstęp między cyklami w sekundach. |
| `AUTOUPDATE_DB_BACKUP` | `0` (wył.) | `1` = `make db-backup` **przed** każdym auto-deployem. Gdy backup się nie uda, deploy jest przerywany (fail-safe). |
| `AUTOUPDATE_SCREEN_NAME` | `bpp-autoupdate` | Nazwa sesji `screen` używana przez `make screen-with-autoupdate`. |
| `AUTOUPDATE_WARNING_MINUTES` | — (wył.) | Gdy > 0, auto-deploy najpierw wywiesza baner na tyle minut, potem blokuje serwis, wdraża i odblokowuje. Szczegóły: [Przerwa techniczna z ostrzeżeniem](przerwa-techniczna.md). |
| `AUTOUPDATE_CRON_SCHEDULE` | `*/15 * * * *` | Harmonogram wpisu-strażnika instalowanego przez `make setup-autoupdate-cron`. Akceptuje pięć pól cronowych albo makro (`@reboot`, `@hourly`, `@daily`, `@midnight`, `@weekly`, `@monthly`, `@yearly`, `@annually`). |
| `AUTOUPDATE_CRON_LOG` | `$BPP_CONFIGS_DIR/logs/autoupdate-cron.log` | Plik, do którego strażnik dopisuje swoje wyjście; w tym samym katalogu ląduje kopia zapasowa crontaba. |

Wartości można ustawić w `$BPP_CONFIGS_DIR/.env` albo doraźnie w środowisku,
np. `AUTOUPDATE_INTERVAL=3600 make autoupdate` czy
`AUTOUPDATE_CRON_SCHEDULE='*/5 * * * *' make setup-autoupdate-cron`.

!!! note "Nadpisanie w `.env` trafia też do kontenerów"
    `$BPP_CONFIGS_DIR/.env` jest wciągany hurtowo przez `env_file`, więc
    zmienne `AUTOUPDATE_*` ustawione tam wylądują również w środowisku
    kontenerów. Jest to nieszkodliwe (żadna usługa ich nie czyta), ale warto
    o tym wiedzieć, oglądając `docker compose exec … env`. Alternatywa:
    podać wartość doraźnie w wywołaniu `make`.

!!! warning "Auto-deploy uruchamia migracje bazy bez nadzoru"
    `make run` odpala migracje Django automatycznie. Auto-update robi to **bez
    człowieka przy klawiaturze**. Backup przed deployem jest domyślnie
    **wyłączony** (zakłada się, że wystarcza nocny backup) — jeśli chcesz
    dodatkowej ochrony, ustaw `AUTOUPDATE_DB_BACKUP=1`. Przed włączeniem
    auto-update na produkcji warto raz przejść ręcznie przez
    [`make test-upgrade`](#make-test-upgrade-proba-generalna-migracji), by
    upewnić się, że migracje kandydata przechodzą.

### Współistnienie z zaspawaną wersją

Jeśli host ma przypięte `DOCKER_VERSION` (patrz
[`make zaspawaj-wersje`](#make-zaspawaj-wersje-przypiecie-wersji)), auto-update
**nie** wciągnie nowszego obrazu „samo": `docker compose pull` ściąga tylko
przypięty tag, więc wyzwalaczem pozostają wtedy wyłącznie nowe commity na
`origin/main`. Zmianę wersji nadal robisz świadomie przez `make zaspawaj-wersje
TAG=<nowy>`. Na hoście bez zaspawania (goły `latest`) auto-update reaguje na
każdy nowy obraz.

### Zabezpieczenia

- **Lock** (`.autoupdate.lock.d`) — dwa cykle się nie nałożą, a ręczny
  `make run` w trakcie nie zderzy się z auto-deployem.
- **`git pull --ff-only`** — jeśli lokalny `main` rozjechał się z `origin/main`
  (ktoś commitował na hoście), auto-update **nie** robi merge/rebase, tylko
  loguje ostrzeżenie i pomija część gitową — nie psuje drzewa.
- **Health-gate** jest w cyklu wyłączony (`BPP_SKIP_HEALTH_GATE=1`), bo
  interaktywny prompt bramki zdrowia zablokowałby pętlę. Stan usług po deployu
  sprawdzisz jak zwykle: `make health` lub `make doctor`.

## Zobacz też

- [Najważniejsze komendy](komendy.md) — skrócona referencja targetów
- [Backup i rclone](backup-i-rclone.md) — skąd bierze się dump używany przez próbę
- [PostgreSQL — wersje i upgrade](../konfiguracja/postgresql.md) — upgrade samej bazy

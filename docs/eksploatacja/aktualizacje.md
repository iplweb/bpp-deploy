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
   ruchomego `latest`, bo porównujemy digesty, nie tagi);
3. jeśli **jest** nowy commit **lub** nowy obraz → opcjonalny backup bazy →
   `git pull --ff-only` → `make run`. Jeśli **nie** ma zmian → cykl kończy się
   po cichu, nic nie jest restartowane.

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

Odpowiednik ręczny (gdy wolisz sam zarządzać sesją):

```bash
screen -dmS bpp-autoupdate make autoupdate
```

`make autoupdate` nie demonizuje się sam — to celowo najprostsza forma:
widoczna, podpinana, bez uprawnień roota. Jeśli chcesz, żeby pętla wstawała po
restarcie hosta, dodaj jedną linię do crontaba użytkownika (`crontab -e`) —
target sam pilnuje, że nie wystartuje duplikatu:

```cron
@reboot cd /ścieżka/do/bpp-deploy && make screen-with-autoupdate
```

(Ten sam `scripts/autoupdate.sh` można też wołać bezpośrednio z crona/systemd —
logika jednego cyklu jest oddzielona od harmonogramu.)

### Konfiguracja (zmienne środowiskowe / `.env`)

| Zmienna | Domyślnie | Znaczenie |
|---|---|---|
| `AUTOUPDATE_INTERVAL` | `7200` | Odstęp między cyklami w sekundach. |
| `AUTOUPDATE_DB_BACKUP` | `0` (wył.) | `1` = `make db-backup` **przed** każdym auto-deployem. Gdy backup się nie uda, deploy jest przerywany (fail-safe). |
| `AUTOUPDATE_SCREEN_NAME` | `bpp-autoupdate` | Nazwa sesji `screen` używana przez `make screen-with-autoupdate`. |

Wartości można ustawić w `$BPP_CONFIGS_DIR/.env` albo doraźnie w środowisku,
np. `AUTOUPDATE_INTERVAL=3600 make autoupdate`.

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

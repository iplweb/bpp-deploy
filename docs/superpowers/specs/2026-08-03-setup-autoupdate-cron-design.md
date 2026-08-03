# Cron-watchdog dla auto-aktualizacji (`make setup-autoupdate-cron`)

Data: 2026-08-03
Status: zatwierdzony do implementacji

## Problem

`make autoupdate` (spec z 2026-07-08) działa jako pętla pod `screen`, a
`make screen-with-autoupdate` startuje ją w tle. Obie komendy trzeba jednak
uruchomić **ręcznie po każdym restarcie hosta**. Dokumentacja
(`docs/eksploatacja/aktualizacje.md`) zaleca dziś ręczne dopisanie wpisu
`@reboot` do crontaba — czyli krok, który operator musi wykonać sam, zapamiętać
i powtórzyć na każdym serwerze.

Drugi, mniej oczywisty problem: `@reboot` pokrywa wyłącznie restart hosta. Gdy
sesja `screen` padnie między restartami (OOM, przypadkowe `screen -X quit`,
zabity proces), auto-aktualizacja milknie i **nikt się o tym nie dowie** —
host po cichu przestaje się aktualizować.

Trzeci problem, niezależny: targety `autoupdate`, `screen-with-autoupdate`
i `test-autoupdate` **nie są wymienione w `make help`**, mimo że `CLAUDE.md`
deklaruje `make help` jako źródło prawdy o dostępnych targetach. Funkcja jest
odkrywalna wyłącznie przez dokumentację.

## Cel

Jedno polecenie instalujące wpis cron, który pilnuje, żeby pętla
auto-aktualizacji **żyła** — przeżywając zarówno restart hosta, jak i padnięcie
sesji. Plus uzupełnienie `make help`.

## Decyzje projektowe (ustalone w brainstormingu)

- **Kształt wpisu:** okresowy **watchdog** (`*/15 * * * *`), nie `@reboot`.
  Uzasadnienie: `make screen-with-autoupdate` jest **już idempotentny** (sprawdza
  `screen -list` i nie startuje drugiej sesji), więc powtarzalne wywołanie jest
  bezpieczne i jednym wpisem pokrywa reboot **oraz** crash sesji. Nie wymaga to
  ani linijki nowej logiki w istniejących targetach.
- **Lokalizacja:** **crontab użytkownika** (`crontab -l | … | crontab -`), nie
  `/etc/cron.d/`. Bez sudo; wpis dziedziczy uprawnienia tego, kto wołał `make`,
  co jest wymogiem poprawności — `git pull` i `docker` muszą działać na tych
  samych prawach co ręczny `make run`.
- **Zakres:** instalacja + odinstalowanie + log do pliku + unit-testy +
  konfigurowalny harmonogram.
- **Bez zmian** w `scripts/autoupdate.sh` i `screen-with-autoupdate` — działają
  i mają testy.
- **Bez migracji `.env`** — obie nowe zmienne mają domyślne w Makefile, więc
  kontrakt wstecznej kompatybilności jest spełniony bez `init-configs`.

## Architektura

Logika w dedykowanym skrypcie, targety cienkie — konwencja całego repo
(`validate-env-quotes.sh --fix`, `letsencrypt.sh`, `autoupdate.sh`). Dwa targety
dzielą jeden skrypt przez flagę `--remove`, dokładnie jak para
`validate-env-quotes` / `fix-env-quotes`.

### `scripts/setup-autoupdate-cron.sh`

Tryby: instalacja (domyślnie) i `--remove`. Wejścia przez zmienne środowiskowe,
wszystkie z domyślnymi — konwencja z `autoupdate.sh`:

| Zmienna | Domyślnie | Rola |
|---|---|---|
| `AUTOUPDATE_CRON_SCHEDULE` | `*/15 * * * *` | Harmonogram strażnika (5 pól cron) |
| `AUTOUPDATE_CRON_LOG` | `$BPP_CONFIGS_DIR/logs/autoupdate-cron.log` | Log strażnika; fallback `$REPO_DIR/.autoupdate-cron.log`, gdy `BPP_CONFIGS_DIR` puste |
| `AUTOUPDATE_SCREEN_NAME` | `bpp-autoupdate` | Tylko do komunikatów (nazwę sesji zna sam target) |
| `CRONTAB` | `crontab` | Punkt wstrzyknięcia mocka w testach |

Instalowany wpis (jedna linia):

```
*/15 * * * * cd '/opt/bpp-deploy' && PATH='<PATH z chwili instalacji>' make screen-with-autoupdate >> '/…/autoupdate-cron.log' 2>&1  # BPP-AUTOUPDATE
```

#### Dlaczego `PATH` zamrożony w chwili instalacji

Cron startuje zadania z jałowym `PATH=/usr/bin:/bin`. Na hostach, gdzie `docker`
lub `make` leży w `/usr/local/bin` (typowe po `scripts/install-docker.sh`,
typowe na macOS), wpis padałby z `command not found` raz na 15 minut — do logu,
którego nikt nie czyta. Operator uruchamia `make setup-autoupdate-cron`
z powłoki, w której wszystko dowodnie działa, więc zamrożenie tego `PATH` daje
gwarancję, jakiej cronowy default dać nie może.

`PATH` trafia jako **prefiks komendy**, nie jako osobna linia `PATH=` w crontabie
— linia `PATH=` jest globalna dla wszystkich zadań użytkownika, także cudzych.

#### Escaping `%`

Niezaescape'owany `%` w komendzie cron oznacza znak nowej linii: ucina komendę,
a resztę podaje jej na stdin. Jeśli ścieżka repo, ścieżka logu albo `PATH`
zawiera `%`, wpis rozpadłby się w sposób trudny do zdiagnozowania. Skrypt
zamienia `%` na `\%` w całej budowanej linii przed zapisem.

#### Idempotencja i bezpieczeństwo cudzych wpisów

Przepisujemy **cały** crontab użytkownika, więc kolejność jest krytyczna:

1. `$CRONTAB -l 2>/dev/null` — pusty crontab zwraca kod 1; to brak wpisów, nie
   błąd, więc kod wyjścia jest ignorowany, a baza traktowana jako pusta.
2. Kopia zapasowa poprzedniej zawartości do
   `<katalog logu>/crontab.bak.<timestamp>` — konwencja z `fix-env-quotes`.
   Pomijana, gdy crontab był pusty (nie ma czego archiwizować).
3. `grep -v '# BPP-AUTOUPDATE'` — usuwa **wyłącznie** nasze linie, cudze
   przechodzą nietknięte.
4. Dopisanie świeżej linii (pomijane w trybie `--remove`).
5. `$CRONTAB <plik>`.

Ponowna instalacja **podmienia**, nie dubluje. Zmiana harmonogramu = ponowne
`make setup-autoupdate-cron` z inną wartością `AUTOUPDATE_CRON_SCHEDULE`.

#### Walidacja i komunikaty

- Brak `crontab` w `PATH` → błąd, `exit 1`, podpowiedź instalacji
  (`apt-get install -y cron`).
- Brak `screen` → **ostrzeżenie, nie błąd**: wpis i tak będzie poprawny, gdy
  `screen` doinstalujesz później. Podpowiedź `apt-get install -y screen`.
- `AUTOUPDATE_CRON_SCHEDULE` musi mieć dokładnie 5 pól — inaczej błąd
  z czytelnym komunikatem (typowa pomyłka: podanie 6 pól w stylu systemd).
- Po instalacji skrypt drukuje: zainstalowany wpis, ścieżkę logu, komendę
  podglądu (`screen -r`) i komendę wycofującą (`make remove-autoupdate-cron`).
- `--remove` przy braku naszych wpisów → komunikat „nie było czego usuwać",
  `exit 0` (idempotentne).

### Rotacja logu — świadomie pominięta (YAGNI)

Strażnik zapisuje ~2 linie (~100 B) na tick. Przy `*/15` to ~10 kB/dobę,
**~3,5 MB/rok**. Wyjście właściwego deploya tam nie trafia — `screen -dmS`
odłącza sesję, więc logi `make run` idą do bufora screena, nie do crona.
Logrotate byłby nieproporcjonalny. Dokumentujemy tempo przyrostu i podajemy
`truncate -s 0 <log>` jako ręczne wyjście awaryjne.

### `mk/deployment.mk`

Dwie zmienne `?=` (nadpisywalne z `.env`, bo Makefile wciąga
`$(BPP_CONFIGS_DIR)/.env` w linii 55, **przed** `include mk/deployment.mk`
w linii 63) i trzy targety, wszystkie dopisane do `.PHONY`:

```make
AUTOUPDATE_CRON_SCHEDULE ?= */15 * * * *
AUTOUPDATE_CRON_LOG ?=

setup-autoupdate-cron:
	@AUTOUPDATE_CRON_SCHEDULE='$(AUTOUPDATE_CRON_SCHEDULE)' \
	 AUTOUPDATE_CRON_LOG='$(AUTOUPDATE_CRON_LOG)' \
	 bash scripts/setup-autoupdate-cron.sh

remove-autoupdate-cron:
	@AUTOUPDATE_CRON_LOG='$(AUTOUPDATE_CRON_LOG)' \
	 bash scripts/setup-autoupdate-cron.sh --remove

test-autoupdate-cron:
	@bash scripts/test-autoupdate-cron.sh
```

`AUTOUPDATE_CRON_LOG` domyślnie **puste** w Makefile — pustą wartość skrypt
traktuje jak „nie ustawiono" i sam wylicza domyślną ścieżkę. Dzięki temu
logika domyślnej ścieżki żyje w jednym miejscu (skrypcie), a nie jest
zdublowana w Makefile.

### `make help` — nowa sekcja

Sześć pozycji przeciążyłoby sekcję „Deployment", więc dokładamy osobną sekcję
zaraz za nią:

```
  Auto-aktualizacja:
    autoupdate             - Petla: nowy obraz/commit -> make run (pierwszy plan)
    screen-with-autoupdate - Start petli w tle, w sesji screen
    setup-autoupdate-cron  - Wpis cron pilnujacy petli (przezywa reboot i crash)
    remove-autoupdate-cron - Usun wpis cron auto-aktualizacji
    test-autoupdate        - Unit-testy scripts/autoupdate.sh
    test-autoupdate-cron   - Unit-testy scripts/setup-autoupdate-cron.sh
```

Sekcja trafia do bloku `help` w `Makefile`, po sekcji „Deployment:", przed
„Database:". Bez polskich znaków diakrytycznych — spójnie z resztą `help`.

## Testy — `scripts/test-autoupdate-cron.sh`

Konwencja z `test-autoupdate.sh`: mock w `PATH`, bez sieci, bez prawdziwego
crona. Mock `crontab` oparty o plik tymczasowy — `-l` czyta go (kod 1, gdy nie
istnieje), wywołanie z argumentem-plikiem zapisuje.

Przypadki:

1. Instalacja do pustego crontaba → dokładnie 1 wpis z markerem.
2. **Dwukrotna** instalacja → wciąż dokładnie 1 wpis (idempotencja).
3. Cudze wpisy użytkownika przetrwają instalację.
4. Cudze wpisy przetrwają `--remove`; usuwane są tylko linie z markerem.
5. `--remove` na crontabie bez naszych wpisów → kod 0, cudze nietknięte.
6. `AUTOUPDATE_CRON_SCHEDULE` faktycznie ląduje we wpisie.
7. Ścieżka logu oraz `PATH=` obecne w zbudowanej linii.
8. `%` w ścieżce logu zostaje zaescape'owany do `\%`.
9. Harmonogram o złej liczbie pól → kod ≠ 0, crontab nietknięty.

Target `test-autoupdate-cron` dokładany do `make help`; jak
`test-post-deploy-check` i `test-doctor`, nie wchodzi (na razie) do
`tests/test_makefile.sh` w CI.

## Dokumentacja

- `docs/eksploatacja/aktualizacje.md` — sekcja o ręcznym `@reboot` zastąpiona
  opisem `make setup-autoupdate-cron`; ręczny wariant zostaje jako przypis dla
  operatorów, którzy wolą własny wpis. Dopisane: tabela nowych zmiennych,
  ścieżka logu, tempo przyrostu logu, `make remove-autoupdate-cron`.
- `docs/eksploatacja/komendy.md` — nowe pozycje w spisie komend.
- Przed edycją: skill `docs-sync` (wymóg `CLAUDE.md`). Po edycji:
  `mkdocs build --strict`.

`CLAUDE.md` **nie** wymaga zmiany: kontrakt bezpieczeństwa wokół
`BPP_SKIP_HEALTH_GATE` dotyczy `scripts/autoupdate.sh`, którego nie ruszamy —
nowy wpis cron woła `make screen-with-autoupdate`, a nie `make up`/`make run`
bezpośrednio.

## Ryzyka

| Ryzyko | Mitygacja |
|---|---|
| Nadpisanie cudzych wpisów w crontabie | Filtr po markerze + kopia zapasowa + testy 3/4/5 |
| Wpis nie działa przez jałowy `PATH` crona | `PATH` zamrożony w chwili instalacji |
| Dublowanie wpisów przy ponownej instalacji | `grep -v` po markerze przed dopisaniem; test 2 |
| Zalanie maila roota wyjściem co 15 min | Przekierowanie `>> log 2>&1` w samym wpisie |
| Rozjazd `%` w ścieżkach | Escaping `%` → `\%`; test 8 |

## Poza zakresem

- Timer `systemd` jako alternatywa dla crona (`scripts/autoupdate.sh` da się pod
  niego podpiąć ręcznie; nic tego nie blokuje).
- Rotacja logu strażnika (uzasadnienie wyżej).
- Powiadomienia ntfy o tym, że strażnik wskrzesił sesję.
- Wpisywanie `AUTOUPDATE_*` do `.env` przez `init-configs` — domyślne
  w Makefile wystarczą.

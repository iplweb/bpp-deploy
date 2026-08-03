# Cron-watchdog dla auto-aktualizacji (`make setup-autoupdate-cron`)

Data: 2026-08-03
Status: zatwierdzony do implementacji (po review)

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
  Uzasadnienie: `make screen-with-autoupdate` jest **już idempotentny**
  (`mk/deployment.mk`, gałąź `screen -list | grep -qE "\.$(AUTOUPDATE_SCREEN_NAME)[[:space:]]"`),
  więc powtarzalne wywołanie jest bezpieczne i jednym wpisem pokrywa reboot
  **oraz** crash sesji. Nie wymaga to ani linijki nowej logiki w istniejących
  targetach.
- **Lokalizacja:** **crontab użytkownika**, nie `/etc/cron.d/`. Bez sudo; wpis
  dziedziczy uprawnienia tego, kto wołał `make`, co jest wymogiem poprawności —
  `git pull` i `docker` muszą działać na tych samych prawach co ręczny
  `make run`.
- **Sposób zapisu:** `$CRONTAB <plik>` (wariant plikowy), **nie** `crontab -`.
  Wariant plikowy jest jednoznaczny w mocku testowym i pozwala zachować
  zbudowaną zawartość do wglądu przy błędzie.
- **Zakres:** instalacja + odinstalowanie + log do pliku + unit-testy +
  konfigurowalny harmonogram.
- **Bez zmian** w `scripts/autoupdate.sh` i w targecie `screen-with-autoupdate`.
- **Bez migracji `.env`** — obie nowe zmienne mają domyślne w Makefile, więc
  kontrakt wstecznej kompatybilności jest spełniony bez `init-configs`.

## Architektura

Logika w dedykowanym skrypcie, targety cienkie — konwencja całego repo
(`validate-env-quotes.sh --fix`, `letsencrypt.sh`, `autoupdate.sh`). Dwa targety
dzielą jeden skrypt przez flagę `--remove`, analogicznie do pary
`validate-env-quotes` / `fix-env-quotes`.

### `scripts/setup-autoupdate-cron.sh`

Tryby: instalacja (domyślnie) i `--remove`. Wejścia przez zmienne środowiskowe,
wszystkie z domyślnymi — konwencja z `autoupdate.sh`:

| Zmienna | Domyślnie | Rola |
|---|---|---|
| `AUTOUPDATE_CRON_SCHEDULE` | `*/15 * * * *` | Harmonogram strażnika |
| `AUTOUPDATE_CRON_LOG` | `$BPP_CONFIGS_DIR/logs/autoupdate-cron.log` | Log strażnika; fallback `$REPO_DIR/.autoupdate-cron.log`, gdy `BPP_CONFIGS_DIR` puste |
| `AUTOUPDATE_SCREEN_NAME` | `bpp-autoupdate` | Tylko do komunikatów |
| `CRONTAB` | `crontab` | Punkt wstrzyknięcia mocka w testach |

Instalowany wpis (jedna linia):

```
*/15 * * * * cd '/opt/bpp-deploy' && PATH='<PATH z chwili instalacji>' make screen-with-autoupdate >> '/…/autoupdate-cron.log' 2>&1  # BPP-AUTOUPDATE
```

#### KRYTYCZNE: katalog logu musi powstać przed zapisem wpisu

Domyślna ścieżka logu leży w `$BPP_CONFIGS_DIR/logs/`, a **takiego podkatalogu
dziś nie ma** — `scripts/init-configs.sh` tworzy wyłącznie sam katalog
konfiguracyjny (`mkdir -p "$ABS_CONFIG"`), żaden inny skrypt ani compose nie
zakłada `logs/`.

Bez jawnego `mkdir -p "$(dirname "$LOG")"` skutki są dwustopniowe i oba złe:
zapis kopii zapasowej crontaba pada już przy instalacji, a nawet gdyby przeszła
— powłoka otwiera przekierowanie `>>` **przed** uruchomieniem `make`, więc wpis
padałby co tick, `make` nigdy by się nie uruchomił (watchdog martwy), a `sh`
pisałby błąd na stderr, co cron wysyła mailem do roota **co 15 minut**. Czyli
dokładnie to ryzyko, które przekierowanie do logu miało wyeliminować.

Dlatego: skrypt tworzy katalog logu **w obu trybach** (instalacja i `--remove`,
bo tam też ląduje kopia zapasowa), zanim cokolwiek zapisze. Objęte testem.

#### Dlaczego `PATH` zamrożony w chwili instalacji

Cron startuje zadania z jałowym `PATH=/usr/bin:/bin`. To wystarcza dla
standardowej instalacji Dockera z repo apt (`scripts/install-docker.sh` używa
`download.docker.com` → binarki lądują w `/usr/bin`), ale **nie** dla hostów,
gdzie `docker`, `make` czy `git` leży w `/usr/local/bin` lub `/opt/homebrew/bin`
— macOS, Docker Desktop, instalacje ręczne, `mise`/`asdf`. Tam wpis padałby
z `command not found` raz na 15 minut, do logu, którego nikt nie czyta.

Operator uruchamia `make setup-autoupdate-cron` z powłoki, w której wszystko
dowodnie działa, więc zamrożenie tego `PATH` daje gwarancję, jakiej cronowy
default dać nie może.

`PATH` trafia jako **prefiks komendy**, nie jako osobna linia `PATH=` w crontabie
— linia `PATH=` jest globalna dla wszystkich zadań użytkownika, także cudzych.

#### Walidacja harmonogramu

Akceptowane są **dwie** formy:

- pięć pól rozdzielonych białymi znakami (`*/15 * * * *`),
- makro `@`: `@reboot`, `@hourly`, `@daily`, `@midnight`, `@weekly`,
  `@monthly`, `@yearly`, `@annually`.

Dopuszczenie makr jest wymogiem migracyjnym: obecna dokumentacja uczy operatorów
wpisu `@reboot`, więc ktoś przestawi `AUTOUPDATE_CRON_SCHEDULE=@reboot`
i nie może dostać błędu „harmonogram musi mieć 5 pól". Cokolwiek innego → błąd
z komunikatem wymieniającym obie dopuszczalne formy.

Dodatkowo harmonogram **nie może zawierać `%`** — w polach czasu `%` nie ma
znaczenia specjalnego, więc escapowanie go tam byłoby składniowo błędne;
prościej i bezpieczniej odrzucić.

#### Escaping `%` — tylko część komendy

Niezaescape'owany `%` w **komendzie** cron oznacza znak nowej linii: ucina
komendę, a resztę podaje jej na stdin. Jeśli ścieżka repo, ścieżka logu albo
`PATH` zawiera `%`, wpis rozpadłby się w sposób trudny do zdiagnozowania.

Escapowanie `%` → `\%` obejmuje **wyłącznie część komendy** (od `cd '…'` do
markera), nigdy pola harmonogramu — tam `%` jest już odrzucone walidacją.

#### Idempotencja i bezpieczeństwo cudzych wpisów

Przepisujemy **cały** crontab użytkownika, więc kolejność i obsługa błędów są
krytyczne:

1. Odczyt: `$CRONTAB -l`, ze stdout i stderr przechwyconymi **osobno**.
   - kod 0 → zawartość to baza;
   - kod ≠ 0 **i** stderr pasuje do wzorca „no crontab” → pusty crontab,
     baza pusta, to nie błąd;
   - kod ≠ 0 **i** stderr mówi coś innego (np. `cron.deny`, błąd przejściowy)
     → **abort z kodem 1**, bez dotykania crontaba.

   To rozróżnienie jest istotne: potraktowanie każdego niezerowego kodu jako
   „crontab jest pusty" groziłoby wyzerowaniem cudzych wpisów do samego wpisu
   BPP — i to bez kopii zapasowej, bo tej też by wtedy nie było.
2. Kopia zapasowa: zawsze, gdy odczyt zwrócił **niepustą** zawartość →
   `<katalog logu>/crontab.bak.<timestamp>`. Z `fix-env-quotes` dzielimy tylko
   konwencję sufiksu `.bak.<timestamp>`; lokalizacja jest inna (tam: obok
   modyfikowanego pliku — tu crontab nie ma ścieżki, więc kopia idzie do
   katalogu logu).
3. `grep -v '# BPP-AUTOUPDATE'` — usuwa **wyłącznie** nasze linie, cudze
   przechodzą nietknięte.
4. Dopisanie świeżej linii (pomijane w trybie `--remove`).
5. `$CRONTAB <plik>`.

Ponowna instalacja **podmienia**, nie dubluje — także wtedy, gdy zmienił się
harmonogram (stara linia znika, bo filtr działa po markerze, nie po treści).

#### Pozostałe walidacje i komunikaty

- Brak `crontab` w `PATH` → błąd, `exit 1`, podpowiedź `apt-get install -y cron`.
- Brak `screen` → **ostrzeżenie, nie błąd**: wpis i tak będzie poprawny, gdy
  `screen` doinstalujesz później. Podpowiedź `apt-get install -y screen`.
- Demon cron nieaktywny (`pgrep -x cron|crond` albo `systemctl is-active cron`)
  → **ostrzeżenie, nie błąd**. Sama binarka `crontab` nie gwarantuje, że
  cokolwiek ten crontab czyta — a wpis w nieczytanym crontabie to dokładnie ta
  klasa cichej awarii, którą ta funkcja zwalcza. Ostrzeżenie jest miękkie, bo
  detekcja demona jest zawodna (kontenery, macOS, nietypowe inity).
- Po instalacji skrypt drukuje: zainstalowany wpis, ścieżkę logu, komendę
  podglądu (`screen -r`) i komendę wycofującą (`make remove-autoupdate-cron`).
- `--remove` przy braku naszych wpisów → komunikat „nie było czego usuwać”,
  `exit 0` (idempotentne). Gdy crontab w ogóle nie istnieje, `--remove`
  **nie tworzy** pustego crontaba.

### Środowisko sesji wskrzeszonej przez crona — udokumentować

Gdy watchdog faktycznie restartuje sesję, `screen -dmS … make autoupdate`
dziedziczy **środowisko crona**: brak `SSH_AUTH_SOCK`, minimalny zestaw
zmiennych. Jeśli `origin` jest po SSH z kluczem chronionym agentem,
`git fetch` w `scripts/autoupdate.sh` zawiedzie — a ten skrypt traktuje to
miękko (loguje ostrzeżenie i pomija część gitową, `scripts/autoupdate.sh`
gałąź „OSTRZEZENIE: 'git fetch' nieudany”). Efekt: auto-aktualizacja po cichu
degraduje do „tylko nowe obrazy", i to **inaczej niż sesja wystartowana
ręcznie**.

To nie wymaga zmian w kodzie, ale **musi** trafić do dokumentacji: dla
nienadzorowanej aktualizacji `origin` powinien być po HTTPS albo na kluczu bez
passphrase.

### Rotacja logu — świadomie pominięta (YAGNI)

Strażnik zapisuje przy żywej sesji dokładnie 2 linie (`Sesja screen … juz
dziala` + `Podglad: screen -r …`), ~100 B na tick. Przy `*/15` to ~9,6 kB/dobę,
**~3,5 MB/rok**. Wyjście właściwego deploya tam nie trafia — `screen -dmS`
odłącza sesję, więc logi `make run` idą do bufora screena, nie do crona.
Logrotate byłby nieproporcjonalny. Dokumentujemy tempo przyrostu i podajemy
`truncate -s 0 <log>` jako ręczne wyjście awaryjne.

### `mk/deployment.mk`

Dwie zmienne `?=` (nadpisywalne z `.env`, bo Makefile wciąga
`$(BPP_CONFIGS_DIR)/.env` **przed** blokiem `include mk/*.mk`) i trzy targety,
wszystkie dopisane do `.PHONY`:

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
traktuje jak „nie ustawiono" i sam wylicza domyślną ścieżkę. Dzięki temu logika
domyślnej ścieżki żyje w jednym miejscu (skrypcie), a nie jest zdublowana.

Ekspansja `*/15 * * * *` przez make jest bezpieczna: make nie globuje wartości
zmiennych, w wartości nie ma `#`, a recipe opakowuje ją w pojedyncze cudzysłowy.

### `.gitignore`

Dopisać fallbackowe artefakty, które przy pustym `BPP_CONFIGS_DIR` lądują
w repo:

```
.autoupdate-cron.log
crontab.bak.*
```

### `make help` — nowa sekcja

Sześć pozycji przeciążyłoby sekcję „Deployment", więc dokładamy osobną sekcję
między „Deployment:" a „Database:":

```
  Auto-aktualizacja:
    autoupdate             - Petla: nowy obraz/commit -> make run (pierwszy plan)
    screen-with-autoupdate - Start petli w tle, w sesji screen
    setup-autoupdate-cron  - Wpis cron pilnujacy petli (przezywa reboot i crash)
    remove-autoupdate-cron - Usun wpis cron auto-aktualizacji
    test-autoupdate        - Unit-testy scripts/autoupdate.sh
    test-autoupdate-cron   - Unit-testy scripts/setup-autoupdate-cron.sh
```

Bez polskich znaków diakrytycznych — spójnie z resztą `help`.

## Testy — `scripts/test-autoupdate-cron.sh`

Konwencja z `test-autoupdate.sh`: mocki w `PATH`, bez sieci, bez prawdziwego
crona. Mock `crontab` oparty o plik tymczasowy — `-l` czyta go (kod 1 i komunikat
„no crontab for user" na stderr, gdy nie istnieje), wywołanie z argumentem-plikiem
zapisuje.

1. Instalacja do pustego crontaba → dokładnie 1 wpis z markerem.
2. **Dwukrotna** instalacja → wciąż dokładnie 1 wpis (idempotencja).
3. Reinstalacja ze **zmienionym** harmonogramem → 1 wpis, z nową wartością
   (stary zniknął).
4. Cudze wpisy użytkownika przetrwają instalację.
5. Cudze wpisy przetrwają `--remove`; usuwane są tylko linie z markerem.
6. `--remove` na crontabie bez naszych wpisów → kod 0, cudze nietknięte.
7. `--remove` na **nieistniejącym** crontabie → kod 0, crontab nadal nie
   istnieje (nie tworzymy pustego).
8. `AUTOUPDATE_CRON_SCHEDULE` faktycznie ląduje we wpisie.
9. Ścieżka logu oraz `PATH=` obecne w zbudowanej linii.
10. Katalog logu zostaje **utworzony**, gdy nie istniał.
11. Kopia zapasowa `crontab.bak.*` **powstaje**, gdy crontab był niepusty.
12. `%` w ścieżce logu zostaje zaescape'owany do `\%`.
13. Harmonogram o złej liczbie pól → kod ≠ 0, crontab nietknięty.
14. Harmonogram `@reboot` → akceptowany, ląduje we wpisie.
15. Harmonogram z `%` → kod ≠ 0, crontab nietknięty.
16. Brak `crontab` w `PATH` → kod ≠ 0 z czytelnym komunikatem.
17. `crontab -l` kończy się błędem **innym** niż „no crontab" → abort, crontab
    nietknięty.

Target `test-autoupdate-cron` dokładany do `make help`; jak
`test-post-deploy-check` i `test-doctor`, nie wchodzi (na razie) do
`tests/test_makefile.sh` w CI.

## Dokumentacja

- `docs/eksploatacja/aktualizacje.md` — sekcja o ręcznym `@reboot` zastąpiona
  opisem `make setup-autoupdate-cron`; ręczny wariant zostaje jako przypis.
  Dopisane: tabela nowych zmiennych, ścieżka logu, tempo przyrostu logu,
  `make remove-autoupdate-cron`, ostrzeżenie o środowisku crona przy `origin`
  po SSH, uwaga że override w `$BPP_CONFIGS_DIR/.env` trafia hurtowym
  `env_file` także do kontenerów (nieszkodliwe, ale warte wiedzy).
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
| Brak katalogu logu → martwy watchdog + mail co 15 min | `mkdir -p` w obu trybach; test 10 |
| Nadpisanie cudzych wpisów w crontabie | Filtr po markerze + kopia zapasowa + abort przy nieznanym błędzie `-l`; testy 4, 5, 11, 17 |
| Wpis nie działa przez jałowy `PATH` crona | `PATH` zamrożony w chwili instalacji; test 9 |
| Dublowanie wpisów przy ponownej instalacji | `grep -v` po markerze przed dopisaniem; testy 2, 3 |
| Zalanie maila roota wyjściem co 15 min | Przekierowanie `>> log 2>&1` w samym wpisie |
| Rozjazd `%` w ścieżkach | Escaping w części komendy, odrzucenie w harmonogramie; testy 12, 15 |
| Wpis w crontabie, którego nikt nie czyta | Miękkie ostrzeżenie o nieaktywnym demonie cron |
| Cicha degradacja do „tylko obrazy" przy `origin` po SSH | Udokumentowane w `aktualizacje.md` |

## Poza zakresem

- Timer `systemd` jako alternatywa dla crona (`scripts/autoupdate.sh` da się pod
  niego podpiąć ręcznie; nic tego nie blokuje).
- Rotacja logu strażnika (uzasadnienie wyżej).
- Powiadomienia ntfy o tym, że strażnik wskrzesił sesję.
- Testy samego targetu `screen-with-autoupdate` — dziś nie ma ich wcale
  (`scripts/test-autoupdate.sh` pokrywa wyłącznie `autoupdate.sh`); ta luka
  istnieje niezależnie od tej zmiany i jej nie zasypujemy.
- Wpisywanie `AUTOUPDATE_*` do `.env` przez `init-configs` — domyślne
  w Makefile wystarczą.

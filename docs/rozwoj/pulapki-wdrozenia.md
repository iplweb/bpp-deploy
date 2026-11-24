# Pułapki przy zmianie sesji wdrożeniowej i pętli auto-update

Strona dla osoby edytującej `scripts/deploy-with-warning.sh`,
`scripts/site-down-warning.sh`, `scripts/autoupdate.sh` i cele w
`mk/deployment.mk`. Instrukcje operatorskie są osobno:
[Przerwa techniczna](../eksploatacja/przerwa-techniczna.md) i
[Aktualizacje](../eksploatacja/aktualizacje.md).

Wspólna cecha wszystkich opisanych tu błędów: **awaria jest cicha**. Serwis
zostaje zablokowany albo pętla umiera, a jedynym śladem jest brak śladu.

## Przerwa techniczna

### To repozytorium nie zawiera logiki odliczania

Baner, strona 503 i każda zmiana stanu należą do **`django-countdown` (>= 0.3.0)**
w obrazie BPP. My wyłącznie wołamy `manage.py`.

!!! danger "Nie przywracaj ścieżki przez `manage.py shell`"
    Wcześniejsza implementacja pisała wprost do modelu `SiteCountdown`. To
    obchodzi walidację i logikę aplikacji, a przy zmianie schematu w obrazie
    psuje się bez ostrzeżenia. Jeśli brakuje operacji — należy ona do
    `django-countdown`, nie tutaj.

### Domyślny zakres różni się między komendami

To nie jest niekonsekwencja do „posprzątania" — to kontrakt aplikacji nadrzędnej,
a jego zignorowanie zostawia otwarte domeny w trakcie przerwy.

| Komenda | Domyślny cel | Ma `--all`? |
|---|---|---|
| `stop_countdown`, `show_countdown` | **wszystkie** witryny | — |
| `extend_countdown`, `shorten_countdown` | tylko **bieżąca** | tak |
| `start_countdown` | tylko **bieżąca** | **nie** |

Ostatni wiersz jest powodem, dla którego istnieje pętla po `SITE_IDS`. Przy
[multi-hoście](../konfiguracja/multi-host.md) jedna instalacja obsługuje wiele
domen (`DJANGO_BPP_HOSTNAMES` → wiele wierszy `Site`, rozwiązywanych per żądanie
przez `SiteResolutionMiddleware`) — bez tej pętli zablokujesz jedną, a resztę
zostawisz otwartą.

### Nigdy nie ucisz heartbeatu przez `|| true`

Podtrzymanie terminu to `extend_countdown --at-least`, dla którego **pusty cel
jest celowo sukcesem**. Skoro tak, to niezerowy kod wyjścia niesie konkretną
informację: **podłoga dead-man's switcha wygasła**.

Sesja ma to głośno zalogować i pracować dalej (nieudany `exec` w środku
recreate'u jest spodziewany). Zamiana na `|| true` zamienia jedyny sygnał
o wygasłej blokadzie w ciszę.

`maintenance_until` służy tu dwóm panom naraz — jest ETA pokazywanym
użytkownikom **i** dead-man's switchem. Godzi je `max(ETA operatora, teraz + FLOOR)`,
czyli dokładnie to, co `--at-least` liczy po stronie bazy.

### Sonda obecności nie może wchodzić w `grep -q`

```bash
# ŹLE — losowa cicha degradacja
manage.py help | grep -q start_countdown
```

Pod `set -o pipefail`: `grep -q` zamyka potok na pierwszym dopasowaniu, producent
ginie od SIGPIPE (141), a **udane** dopasowanie zwraca porażkę. Efekt: wdrożenie
schodzi do trybu „bez ostrzeżenia", losowo i bez komunikatu.

Poprawnie: wczytaj całe wyjście do zmiennej, dopasuj w bashu. Pilnuje tego
`test_site_down_warning_contract` w `tests/test_makefile.sh`.

### Bramka zdrowia musi być wyłączona, a `post-deploy-check` karmiony `</dev/null`

Sesja woła `make run` z `BPP_SKIP_HEALTH_GATE=1` (ten sam powód co w
`autoupdate.sh`), a `scripts/post-deploy-check.sh` uruchamia **jawnie**, z
przekierowanym stdin. Bez tego prompt `[s]`hell/`[d]`octor potrafi zawiesić
sesję **w momencie, gdy serwis jest zablokowany** — czyli przerwa techniczna
trwa, dopóki ktoś nie zauważy pytania na ekranie.

### Zachowanie przy przerwaniu zależy od fazy

| Przerwanie | Co zrobić |
|---|---|
| w trakcie banera (przed odcięciem) | `stop_countdown` — nic się jeszcze nie stało |
| po odcięciu / po błędzie `make run` | **zostaw blokadę** — stack jest w nieznanym stanie |

W drugim przypadku blokada wygaśnie sama, gdy przestanie bić heartbeat. To jest
projekt, nie niedoróbka: lepiej pokazać stronę przerwy niż serwis na wpół
zmigrowanej bazie.

### Zależność od `proxy_intercept_errors`

Strona odliczania to **503 z Django**. Włączenie `proxy_intercept_errors`
gdziekolwiek w konfiguracji nginksa sprawi, że nginx połknie je i pokaże
statyczne `maintenance.html` — użytkownik straci licznik i godzinę powrotu.
Dyrektywa jest domyślnie wyłączona i
[celowo tego nie zmieniamy](../architektura/waf.md#dlaczego-444-a-nie-403).

## Pętla auto-update

### Zwolnij lock **przed** `exec screen -X quit`

Samorestart pętli kończy własną sesję screen. Ten zabój **nie daje szansy na
wykonanie `trap EXIT`**, więc katalog-lock trzeba zwolnić, a `trap` wyczyścić,
*zanim* padnie `exec`.

!!! danger "Osierocony lock zabija auto-update na zawsze"
    Każdy kolejny cykl kończy się wtedy na „inny cykl trwa" — jedna linia w logu
    jako jedyny ślad po tym, że host przestał się aktualizować. Pilnuje tego
    jawna asercja w `scripts/test-autoupdate.sh`.

### Osierocony lock: przejmuj tylko martwego właściciela

Na produkcji (2026-09-10) cykl się nie dokończył, a pętla przez dwie doby
kończyła każdą iterację na „inny cykl trwa". Które przerwania osierocają lock
(zmierzone na bashu 5.2, katalog-lock + `trap EXIT`):

| Przerwanie | Lock |
|---|---|
| SIGHUP (`screen -X quit`, zamknięcie terminala), SIGTERM (`kill`) | zwolniony — `trap EXIT` się wykonuje |
| SIGKILL (`kill -9`, OOM killer) | **osierocony** |
| restart / awaria hosta | **osierocony** — katalog leży na dysku |

Dlatego lock ma plik `owner` (`pid`, `boot`, `started`), a przejęcie następuje
tylko po **dowodzie** śmierci właściciela: inny identyfikator rozruchu, brak
procesu o tym PID albo PID zajęty przez proces, który nie jest `autoupdate.sh`.
Każdy z tych warunków, a także pozostałe bezpieczniki niżej, ma w
`scripts/test-autoupdate.sh` test, który gaśnie po jego usunięciu (sprawdzone
mutacjami).

Decyzje, których nie należy „upraszczać":

- **Żywego właściciela nie przejmujemy po wieku** — ponad
  `AUTOUPDATE_LOCK_MAX_AGE_MINUTES` tylko ostrzegamy. Deploy może jeszcze trwać,
  a przejęcie oznaczałoby dwa równoległe `make run`. Wiek decyduje sam wyłącznie
  o locku **bez** pliku `owner` (starsza wersja skryptu), bo tam nie ma PID-u
  do sprawdzenia.
- **Sam `kill -0` nie wystarcza** — PID po restarcie hosta (albo po dniach
  pracy) bywa nadany innemu procesowi. Stąd identyfikator rozruchu i porównanie
  komendy procesu.
- **Pusty wynik `ps` znaczy „nie ma procesu" tylko, gdy `ps` działa** — skrypt
  najpierw pyta `ps` o własny PID. Bez tej sondy brak/niekompatybilny `ps`
  (np. busybox bez `-p`) sprawiłby, że każdy żywy lock wyglądałby na martwy.
- **Przejęcie pod osobną blokadą** (`<lock>.takeover`, też `mkdir`) z ponowną
  oceną pod nią — bez niej dwa procesy mogą naraz uznać lock za martwy, a drugi
  skasuje świeży lock pierwszego. Osierocona blokada przejmowania (starsza niż
  minuta) jest usuwana, inaczej ten sam błąd wróciłby piętro wyżej.
- **Żadnego `rm -rf` na katalogu locka** — usuwamy tylko `owner`/`owner.tmp`
  i robimy `rmdir`. Pomyłkowy `AUTOUPDATE_LOCK_DIR` wskazujący na cudzy katalog
  kończy się błędem `rmdir`, a nie jego skasowaniem.
- **`owner` zapisywany przez plik tymczasowy + `mv`** — czytający widzi plik
  pełny albo żaden, nigdy pusty w połowie zapisu.
- **Zwolnienie musi skasować `owner`, zanim zrobi `rmdir`** — sam `rmdir` na
  niepustym katalogu po cichu zawodzi. Każdy cykl zostawiałby wtedy lock, który
  następny przejmowałby jako „martwy" — błąd schowany za mechanizmem, który
  miał go łapać.

### Nie próbuj zamiast tego przerywać pętli kodem wyjścia

Kuszące „niech `while` zrobi `break`, a strażnik podniesie" **nie może zadziałać**:
ta zmiana siedzi w pliku, który działająca sesja rozwinęła przy starcie i trzyma
zamrożony. Poprawka nigdy by się nie wdrożyła sama — a to jest cały cel
mechanizmu. Stąd zabicie sesji z zewnątrz.

Co jest zamrożone, a co odświeża się samo:
[Samorestart pętli](../eksploatacja/aktualizacje.md#samorestart-petli).

### `docker image inspect` na brakującym tagu drukuje pustą linię

Zanim zawiedzie, wypisuje na **stdout** pusty wiersz. Naiwne
`$(docker image inspect … || echo none)` daje więc wpis dwuliniowy, który
psuje porównanie parami. Konieczne jest `| head -1` plus `${id:-none}`.

### Przejścia z/do `none` nie są zmianą wersji

Brak lokalnego **tagu** to nie jest nowszy obraz. Pomijanie takich przejść niczego
nie gubi i zapobiega wdrażaniu produkcji w kółko — pełne uzasadnienie
z przypadkiem produkcyjnym:
[Samo zniknięcie tagu](../eksploatacja/aktualizacje.md#automatyczna-aktualizacja-make-autoupdate).

**Loguj, który obraz się zmienił.** Bezimienne „Wykryto nowszy obraz Docker."
przy 18 obrazach było nie do zdiagnozowania.

## `make up`

### Najpierw stop konsumentów, potem `--force-recreate` {#kolejnosc-restartu}

**Objaw, który tu prowadzi:** po każdym wdrożeniu do Sentry/GlitchTip (i Rollbara)
wpada seria błędów, których w działającym systemie nie ma:
`OperationalError: could not translate host name "dbserver"`,
`Error -3 connecting to redis:6379`, kombu
`AttributeError: 'NoneType' object has no attribute 'hostname'` przy
`WorkerShutdown`.

**Przyczyna:** `docker compose up --force-recreate` odtwarza kontenery w
kolejności zależności — najpierw `dbserver`, `redis`, `pgbouncer`, dopiero potem
ich konsumentów. Stary `appserver` i workery Celery żyją więc dalej, kiedy baza
i Redis już zniknęły (nazwa hosta przestaje się rozwiązywać), i zgłaszają to,
co widzą. `depends_on` porządkuje start i `down`, ale **nie** chroni przed
odtworzeniem zależności pod działającym konsumentem. Odtworzone na zabawkowym
projekcie Compose (`docker events`): `stop db` → `stop app` → `start db` →
`start app` — między pierwszym a drugim krokiem `app` żyje bez bazy.

**Poprawka:** pierwszy krok recepty `up` to `scripts/stop-db-consumers.sh`,
który robi `docker compose stop -t ${BPP_DEPLOY_STOP_TIMEOUT:-30}` na
konsumentach. Lista jest **wyliczana**, nie wpisana na sztywno: działające
kontenery projektu, które przechodnio zależą (`depends_on`) od `dbserver`,
`redis` albo `pgbouncer` — zależności czytane z labela
`com.docker.compose.depends_on`, który Compose nadaje kontenerom. Dziś wychodzi
`appserver`, `authserver`, `workerserver`, `denorm-queue`, `celerybeat`,
`flower`, `ofelia` (przez `appserver`) i `workerserver-status`, jeśli akurat
działa. **Nie** wychodzą: `webserver` (nginx ma pokazywać stronę serwisową),
monitoring, `backup-runner`, `rclone`, `html2docx`, `motyw-kompilator` — żaden nie
ma `depends_on` na bazę/Redisa.

Skrypt jest **fail-open**: brak kontenerów (świeża instalacja), błąd
`docker compose ps`/`inspect`/`stop` → komunikat i exit 0, `up` idzie dalej jak
dawniej. Kontrakt pilnuje `test_up_stops_consumers_first` w
`tests/test_makefile.sh` — wykonuje prawdziwą receptę `make up` na atrapie
dockera i sprawdza **kolejność wywołań** (sprawdzone: bez poprawki test gaśnie).

!!! danger "Anti-fixy — nie rób tego"
    - **Nie usuwaj kroku „bo `depends_on` wystarczy"** — nie wystarcza, patrz wyżej.
      Objaw powrotu: znów seria fałszywych błędów połączeń po każdym wdrożeniu.
    - **Nie zatrzymuj `webservera`** — w czasie przerwy nginx serwuje
      `maintenance.html` (502 → `error_page`). Bez niego użytkownik dostaje
      zerwane połączenie.
    - **Nie każ skryptowi wywracać deployu** przy błędzie — to optymalizacja
      zgłoszeń błędów, nie warunek wdrożenia.
    - **Nie hardkoduj listy usług** — nowy konsument (np. kolejny worker) dopisany
      w compose musi trafić na listę sam, przez `depends_on`.

**`denorm-queue` ma `stop_signal: SIGINT`.** Jego PID 1 to goły
`python manage.py denorm_queue` bez handlera SIGTERM, a PID 1 w kontenerze
ignoruje sygnały bez handlera — `docker stop` czekał cały timeout i kończył
SIGKILL-em. Ponieważ Compose zatrzymuje usługi w odwrotnej kolejności zależności,
blokowało to też `workerserver` i `appserver` za nim (zmierzone: 30 s przestoju
więcej). SIGINT Python obsługuje zawsze (`KeyboardInterrupt`): wyjście w < 1 s,
kod 0. **Nie usuwaj tego „bo domyślny sygnał wystarczy"** — nie wystarcza.

**Wpływ na przerwę — zmierzone na lokalnym stacku** (`dbserver`, `redis`,
`pgbouncer`, `appserver`, `authserver`, `workerserver`, `denorm-queue`,
`celerybeat`, `flower`, `ofelia`; obraz BPP 202611.1407):

| | Przed | Po |
|---|---|---|
| czas od początku do „wszystko zdrowe" | 46 s | 46 s (stop 5 s + up 41 s) |
| `appserver` niedostępny | ~26 s, ale bez bazy już od 1. sekundy | ~24 s |
| linie z błędami połączeń w logach | 11 (`could not translate host name "dbserver"`, `Error 111 connecting to redis:6379`, `denorm-queue` padł dwa razy) | **0** |

Czas zatrzymywania nie jest nowy — `--force-recreate` i tak zatrzymywał każdy
z tych kontenerów; teraz dzieje się to wcześniej. Różnica jest w tym, **co
widzi użytkownik**, gdy baza jest odtwarzana: dawniej `appserver` żył bez bazy
i odpowiadał błędami, teraz nginx pokazuje stronę serwisową. Najgorszy przypadek
wydłużenia: zajęty worker Celery, który wykorzystuje cały timeout
(`BPP_DEPLOY_STOP_TIMEOUT`, 30 s zamiast domyślnych 10 s Compose).

**Przerwa techniczna (`make run-with-warning`):** strona odliczania to 503
z Django, więc zatrzymany `appserver` jej nie serwuje — w tym oknie nginx pokazuje
statyczne `maintenance.html`. Nie jest to regresja: bez bazy (odtwarzanej i tak
przy każdym `make up`) Django też nie odczyta stanu odliczania, a heartbeat
(`docker compose exec appserver …`) nie działał już w trakcie recreate'u —
blokada trzyma się na podłodze `--at-least` zapisanej w bazie.

**`make up-quick` celowo bez tego kroku** — nie ma `--force-recreate`, więc
odtwarza tylko usługi, które się zmieniły; bezwarunkowy stop konsumentów
dokładałby przerwę na każdym wywołaniu. Zostaje ryzyko szczątkowe: gdy po `pull`
zmieni się obraz `redis`/`postgres`, `up-quick` odtworzy go pod działającą
aplikacją (te same fałszywe błędy, jednorazowo).

## Testy

```bash
make test-deploy-with-warning   # sesja wdrożeniowa (mocki docker/make)
bash scripts/test-autoupdate.sh # pętla auto-update
make test-makefile              # asercje kontraktowe (statyczne)
```

Dwa pierwsze są **osobnymi krokami CI** i oba przechodzą przez ścieżkę
`make run` — regresja w jednym zwykle zapala się też w drugim.

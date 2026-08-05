# Przerwa techniczna z ostrzeżeniem — projekt

Data: 2026-08-05
Status: zaakceptowany, we wdrożeniu

## Problem

Aktualizacja BPP (`make run`) kładzie stack na kilka minut bez żadnego uprzedzenia.
Użytkownik trafia w środek deployu, dostaje 502 ze statycznej strony `maintenance.html`
i nie wie, czy to awaria, czy planowana przerwa. Chcemy sesję deployową, która:

1. najpierw ściąga obrazy (bez wpływu na użytkowników),
2. wywiesza baner „za N minut aktualizacja” i odczekuje N minut,
3. blokuje serwis i robi właściwy deploy,
4. zdejmuje blokadę,

a przy tym wypisuje statusy z upływem czasu, żeby dało się to prowadzić pod `screen`.

## Fundament: `django-countdown` 0.3.0

Aplikacja `django_countdown` (repo `iplweb/django-countdown`, w BPP w `INSTALLED_APPS`
od X 2025) realizuje całą warstwę widoczną dla użytkownika:

- model `SiteCountdown` — **jeden wiersz per `django.contrib.sites.Site`** (OneToOne):
  - `countdown_time` — moment odcięcia dostępu,
  - `maintenance_until` — deklarowany koniec przerwy (`NULL` = bezterminowo),
  - `message`, `long_description`;
- **faza banera** (przed `countdown_time`): baner z tykającym licznikiem, wstrzykiwany
  przez context processor;
- **faza blokady** (po `countdown_time`): `CountdownBlockingMiddleware` zwraca **HTTP 503**
  ze stroną przerwy. Superuser przechodzi; wyjęte są `/admin/`, `/static/`, `/media/`.

`bpp-deploy` **nie dubluje tej logiki i nie pisze do modelu** — steruje wyłącznie przez
komendy `manage.py`. W tym repo nie ma ani linii Pythona dotykającej countdownu.

### Kontrakt komend (`django-countdown` 0.3.0, na PyPI)

```bash
manage.py start_countdown    --banner +5m --service +10m --message "..." --noinput --force
manage.py stop_countdown     --noinput
manage.py extend_countdown   --service +Nm | --at-least Nm   [--noinput]
manage.py shorten_countdown  --service +Nm                   [--noinput]
manage.py show_countdown     --json
```

Własności, na których opiera się ten projekt (zweryfikowane w kodzie 0.3.0):

- `--banner` liczone **od teraz**, `--service` **od `countdown_time`** — dokładnie jak
  w naszym modelu dwóch faz;
- `extend --service` / `shorten --service` ruszają **wyłącznie `maintenance_until`**;
  `--banner` przesuwałby cały harmonogram, więc go nie używamy;
- `--at-least Nm` ustawia `maintenance_until = max(obecne, teraz + Nm)` i **nie pisze
  nic**, gdy warunek już zachodzi — idempotentne, powtórzenia się nie kumulują;
- obie komendy biorą **dodatnie** czasy; kierunek wynika z nazwy komendy (świadoma
  decyzja upstreamu: `adjust -15m` da się źle odczytać, `shorten +15m` nie);
- `show_countdown --json` → lista rekordów `site_id`, `domain`, `message`, `phase`
  (`unscheduled` / `banner` / `blocked` / `blocked_indefinite` / `finished`),
  `countdown_time`, `maintenance_until`, `next_event`, `seconds_to_next`; przy braku
  wpisów `[]`, nigdy proza. Komenda **zawsze kończy się kodem 0** — czyta się wyjście,
  nie exit status;
- `stop_countdown` jest idempotentne (brak wpisu = sukces) i **usuwa wiersz**, a nie
  tylko kończy okno;
- `--noinput` obowiązkowe wszędzie poza `show_countdown` — bez terminala komendy
  odmawiają zamiast zgadywać.

#### Domyślne cele różnią się między komendami

| Komenda | Bez argumentów działa na | Poszerzenie |
|---|---|---|
| `stop_countdown`, `show_countdown` | **wszystkich** witrynach | — |
| `start_countdown` | bieżącej witrynie | **brak `--all`** — trzeba pętli po `--site-id` |
| `extend_countdown`, `shorten_countdown` | bieżącej witrynie | `--all` |

To nie jest niekonsekwencja: `stop` kończy incydent (gdy strona leży, nie chcemy
najpierw ustalać, który `SITE_ID` zawinił), a `start`/`extend` edytują harmonogram,
gdzie rozjechany cel po cichu przesunąłby okno innego najemcy.

#### `--at-least` nie wolno owijać w `|| true`

Pusty cel jest dla `--at-least` celowo **sukcesem**, właśnie po to, żeby niezerowy kod
wyjścia znaczył „ochrona przestała działać”. `|| true` zamieniłoby „ktoś ręcznie zdjął
blokadę” i „podłoga przestała być podtrzymywana, a serwis serwuje ruch w środku
deployu” w tę samą ciszę. Heartbeat loguje więc każde niepowodzenie głośno, ale nie
zabija sesji — w trakcie `make run` appserver znika i nieudany `exec` jest spodziewany.

## Architektura

```
scripts/site-down-warning.sh        # cienka warstwa nad komendami Django
scripts/deploy-with-warning.sh      # orkiestracja sesji + heartbeat + trap
scripts/test-deploy-with-warning.sh # unit-testy (mock docker/make)
mk/deployment.mk                    # 5 cienkich celow
scripts/autoupdate.sh               # nowa galaz AUTOUPDATE_WARNING_MINUTES
```

`site-down-warning.sh` woła `docker compose exec -T appserver python src/manage.py …`
(`-T` obowiązkowe — skrypt bywa uruchamiany bez TTY).

### Cele Makefile

| Cel | Komenda Django |
|---|---|
| `enable-site-down-warning MINUTES=5 SERVICE=10 MESSAGE="…"` | `start_countdown --banner +5m --service +10m --message … --noinput --force` |
| `disable-site-down-warning` | `stop_countdown --noinput` |
| `extend-site-down-warning MINUTES=+5` | `extend_countdown --service +5m --noinput` |
| `extend-site-down-warning MINUTES=-5` | `shorten_countdown --service +5m --noinput` |
| `status-site-down-warning` | `show_countdown --json` → formatowanie w skrypcie |
| `run-with-warning MINUTES=5 SERVICE=10` | pełna sesja (niżej) |
| *(wewnętrzne, w tle)* heartbeat | `extend_countdown --at-least 5m --noinput` |

Znak w `MINUTES` wybiera komendę; do komendy trafia zawsze wartość dodatnia.

### Parametry i wartości domyślne

Kolejność: argument `make` → zmienna z `$BPP_CONFIGS_DIR/.env` → stała w skrypcie.

| Argument | Zmienna `.env` | Domyślnie |
|---|---|---|
| `MINUTES` (okno banera) | `SITE_DOWN_WARNING_MINUTES` | `5` |
| `SERVICE` (deklarowana długość przerwy) | `SITE_DOWN_SERVICE_MINUTES` | `10` |
| `MESSAGE` | `SITE_DOWN_WARNING_MESSAGE` | `Planowana przerwa techniczna — aktualizacja systemu` |
| `SITE_IDS` (lista, patrz „Multi-host”) | `SITE_DOWN_SITE_IDS` | puste = bieżąca witryna |
| — | `SITE_DOWN_HEARTBEAT_FLOOR_MINUTES` | `5` |
| — | `SITE_DOWN_HEARTBEAT_INTERVAL` | `60` (sekundy) |
| — | `SITE_DOWN_TICK_INTERVAL` | `30` (sekundy) |

Wszystkie zmienne są **nowe** i każda ma fallback w skrypcie — stary `.env` działa bez
zmian, żadnej migracji w `init-configs.sh` nie trzeba (kontrakt backwards-compat,
`docs/rozwoj/backwards-compatibility.md`).

## Przebieg `run-with-warning`

```
[+00:00] === FAZA 1: pobieranie obrazow (bez wplywu na uzytkownikow) ===
[+00:00] make pull
[+07:12] pull OK
[+07:12] === FAZA 2: ostrzezenie ===
[+07:12] ostrzezenie WLACZONE dla 1 witryny (publikacje.uczelnia.pl)
         odciecie: 14:35:00, deklarowany powrot: 14:45:00
[+07:42] do odciecia 4:30 ...
[+08:12] do odciecia 4:00 ...
   ...                                    <- tick co 30 s, okno SZTYWNE
[+12:12] === FAZA 3: przerwa techniczna ===
[+12:12] strona ZABLOKOWANA (503 ze strona przerwy)
         heartbeat: co 60 s podtrzymuje maintenance_until >= teraz + 5 min
         regulacja ETA z innego okna: make extend-site-down-warning MINUTES=+5
[+12:12] make run
   ... (wyjscie make leci na zywo) ...
[+14:33] make run OK (2 min 21 s)
[+14:33] kontrola stanu: scripts/post-deploy-check.sh
[+14:38] wszystkie uslugi zdrowe
[+14:38] === FAZA 4: koniec ===
[+14:38] ostrzezenie ZDJETE — strona dostepna
[+14:38] laczny czas sesji 14 min 38 s, niedostepnosc 2 min 26 s
```

`make pull` przed banerem jest świadomy: pobieranie obrazów nie dotyka działającej
instalacji, więc okno banera to czysty czas na uprzedzenie ludzi, a realna
niedostępność ≈ czas `make run`. `make run` ma `pull` we własnych zależnościach —
drugi pull będzie no-opem albo dociągnie deltę wypchniętą w międzyczasie.

### Okno banera jest sztywne

Faza 2 to zwykły `sleep` z tickiem statusu. Żadnych klawiszy skracających ani
wydłużających: `countdown_time` to obietnica złożona użytkownikom, którzy widzieli
konkretną godzinę na banerze.

### Heartbeat i podwójna rola `maintenance_until`

`maintenance_until` pełni dwie role naraz: **komunikat dla użytkownika** (ETA powrotu
na stronie blokady) i **wyłącznik bezpieczeństwa** (po tym czasie blokada znika sama).
Konflikt rozstrzyga wzór, który realizuje `--at-least`:

```
maintenance_until = max(ETA zadeklarowane przez operatora, teraz + FLOOR)
```

Konsekwencje:

- dopóki deploy mieści się w obietnicy, wygrywa ETA operatora — użytkownik widzi
  stabilną godzinę powrotu i nic z tej mechaniki nie zauważa;
- gdy deploy przeciągnie się poza ETA, godzina zaczyna przesuwać się po `FLOOR` minut —
  uczciwie, bo faktycznie nie wróciliśmy;
- gdy sesja zginie (`kill -9`, OOM, reboot hosta), heartbeat przestaje bić i blokada
  wygasa sama najpóźniej po `FLOOR` minutach.

Wybór heartbeatu zamiast trybu bezterminowego jest świadomy i ma znaną wadę: jeśli
padnie **host** w środku migracji, serwis otworzy się na wpół zmigrowanej bazie.
Odwrotny wariant (`--service indefinite` + jawny `stop_countdown`) chroni przed tym,
ale za cenę bezterminowego zamknięcia, gdy nikt nie zauważy. Wybieramy wariant, w
którym wcześniejsze otwarcie jest przeżywalne, a nienadzorowane trwałe zamknięcie nie.

### Regulacja ETA w trakcie

Z drugiego okna (`screen`: Ctrl-A C):

```bash
make extend-site-down-warning MINUTES=+10   # przesun powrot o 10 min
make extend-site-down-warning MINUTES=-5    # sciagnij o 5 min
make status-site-down-warning               # podglad stanu
make disable-site-down-warning              # awaryjne odblokowanie
```

Sesja główna niczego nie przechwytuje z klawiatury — strumieniuje wyjście `make run`
w oryginale.

### Trap zależny od fazy

| Kiedy | Ctrl-C / błąd | Uzasadnienie |
|---|---|---|
| Faza 1–2 (pull, baner; stack nietknięty) | `stop_countdown` — baner znika, czysty exit | Nic się nie stało, nie zostawiamy wiszącego ostrzeżenia |
| Faza 3–4 (po odcięciu, stack ruszony) | blokada **zostaje**, głośna instrukcja, `exit != 0` | Deploy w nieznanym stanie — lepiej pokazać stronę przerwy niż połowicznie zaktualizowany serwis |

W drugim przypadku heartbeat umiera razem z sesją, więc blokada wygasa sama po `FLOOR`
minutach, jeśli nikt nie przyjdzie. Operator, który potrzebuje więcej czasu, ma
`make extend-site-down-warning MINUTES=+30`.

### `BPP_SKIP_HEALTH_GATE=1` jest obowiązkowe

`scripts/deploy-with-warning.sh` **musi** wyeksportować `BPP_SKIP_HEALTH_GATE=1` przed
`make run` — inaczej `scripts/post-deploy-check.sh` pod pseudo-TTY `screena` wyświetli
prompt `[s]hell/[d]octor` i zablokuje sesję (ten sam trap, który omija
`scripts/autoupdate.sh`). Bramkę odpalamy sami, jawnie, po `make run`, i jej wynik
wchodzi do definicji sukcesu: usługa `unhealthy` = deploy nieudany = blokada zostaje.

### Degradacja na starym obrazie

Wsparcie wykrywane raz na sesję:

```bash
docker compose exec -T appserver python src/manage.py help --commands | grep -qx show_countdown
```

- brak wsparcia + `run-with-warning` w TTY → głośne ostrzeżenie i pytanie
  „deploy bez ostrzeżenia dla użytkowników — kontynuować? [t/N]”;
- brak wsparcia + `run-with-warning` bez TTY (cron, `autoupdate`) → ostrzeżenie na
  wyjściu i **zwykły deploy**, bez zatrzymywania nienadzorowanej pętli;
- brak wsparcia + `enable` / `disable` / `extend` / `status` → błąd z instrukcją
  „zaktualizuj obraz BPP” i nazwą brakującej komendy.

Żadnego trybu zgodności przez `manage.py shell` — nie kopiujemy logiki cudzego modelu.

### Multi-host

BPP ma `SiteResolutionMiddleware`, a `SITE_ID` jest tylko fallbackiem
(`settings/base.py:222`). Przy `DJANGO_BPP_HOSTNAMES` w bazie żyje wiele wierszy `Site`,
a `get_current_site(request)` — którego używa middleware countdownu — rozstrzyga je po
domenie żądania. `start_countdown` **nie ma `--all`**, więc pojedyncze wywołanie
zablokowałoby jedną domenę i zostawiło resztę otwartą.

Rozwiązanie: `SITE_IDS` (lista id, np. `SITE_IDS="1 2 3"`). Gdy podana, `enable`,
`extend`/`shorten` i heartbeat robią pętlę po `--site-id`. Gdy pusta — działają na
bieżącej witrynie, co jest poprawne dla instalacji single-host (przytłaczająca
większość). `disable` woła `stop_countdown` **bez** `--site-id`, więc zamiata wszystko,
łącznie z osieroconym wierszem `example.com`, który tworzy `migrate` — na instalacji
BPP wszystkie domeny należą do tego samego operatora, więc nie ma tu cudzego okna do
zdeptania.

### Zależność od konfiguracji nginxa

`defaults/webserver/_bpp-locations.conf` ma `error_page 502 503 504 /maintenance.html`,
ale `proxy_intercept_errors` jest **wyłączone** (świadomie, komentarz w liniach 42–47).
Dzięki temu 503 wygenerowane przez Django przechodzi do użytkownika w oryginale —
zobaczy stronę z `django-countdown`, nie statyczny `maintenance.html`. **Włączenie
gdziekolwiek `proxy_intercept_errors on` po cichu zepsuje tę funkcję.**

Uboczny efekt: w trakcie samego `make run` appserver znika, więc nginx generuje 502
własnymi siłami i wtedy zadziała `maintenance.html`. Użytkownik zobaczy w jednej sesji
dwie różne strony przerwy. Ujednolicenie ich wyglądu jest poza zakresem.

## Integracja z `autoupdate`

Nowa zmienna `AUTOUPDATE_WARNING_MINUTES` (pusta lub `0` = zachowanie jak dziś).
Gdy ustawiona, `scripts/autoupdate.sh` po wykryciu zmian woła
`scripts/deploy-with-warning.sh` zamiast gołego `make run`. Ścieżka jest nie-TTY, więc:
okno banera to zwykły `sleep`, degradacja na starym obrazie nie zadaje pytań, a błąd
cyklu nie zabija pętli (jak dotychczas).

## Testy

`scripts/test-deploy-with-warning.sh` w konwencji `scripts/test-autoupdate.sh`
(mock `docker`/`make` na `PATH`, bez sieci i bez Dockera). Przypadki:

1. pełna ścieżka sukcesu — kolejność: `pull` → `start_countdown` → `make run`
   → `post-deploy-check` → `stop_countdown`;
2. `make pull` wykonany **przed** `start_countdown`, nie po (kolejność faz);
3. `BPP_SKIP_HEALTH_GATE=1` wyeksportowane przy `make run`;
4. przerwanie w fazie 2 → wywołane `stop_countdown`;
5. błąd `make run` → `stop_countdown` **nie** wywołane, exit != 0;
6. `post-deploy-check` zgłasza problem → traktowane jak błąd (blokada zostaje);
7. heartbeat woła `extend_countdown --at-least` cyklicznie, a jego błąd jest logowany,
   nie przerywa sesji i nie jest wyciszany przez `|| true`;
8. brak komendy w obrazie + nie-TTY → deploy leci, `start_countdown` nie wywołane;
9. brak komendy w obrazie + `enable-site-down-warning` → exit != 0;
10. `MINUTES=+5` → `extend_countdown --service`, `MINUTES=-5` → `shorten_countdown
    --service` z **dodatnią** wartością;
11. `SITE_IDS="1 2"` → `start_countdown` wołane raz na id, każde z `--site-id`;
12. parametry: argument `make` wygrywa z `.env`, `.env` wygrywa ze stałą.

Nowy cel `make test-deploy-with-warning`; statyczne asercje na obecność celów
w `tests/test_makefile.sh`.

## Dokumentacja

Przez skill `docs-sync`:

- nowa strona `docs/eksploatacja/przerwa-techniczna.md` (pełne how-to + nav w `mkdocs.yml`);
- `docs/eksploatacja/komendy.md` — nowe cele w tabeli;
- `CLAUDE.md` — krótki kontrakt: dwa pola modelu, `--at-least` bez `|| true`, rozjazd
  domyślnych celów komend, zakaz `proxy_intercept_errors on`, `SITE_IDS` w multi-host,
  obowiązkowe `BPP_SKIP_HEALTH_GATE=1`;
- `README.md` bez zmian (to nie jest temat instalacyjny);
- `mkdocs build --strict` po edycji.

## Poza zakresem

- `screen-with-warning` — sesję odpala się ręcznie: `screen -dmS bpp-deploy make run-with-warning`;
- kopia bazy przed deployem (`make db-backup` zostaje osobną decyzją operatora);
- ujednolicenie wyglądu strony blokady z `django-countdown` i `defaults/webserver/maintenance.html`;
- implementacja komend w `django-countdown` — dostarcza je tamto repo (0.3.0).

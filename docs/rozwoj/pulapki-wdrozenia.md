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

## Testy

```bash
make test-deploy-with-warning   # sesja wdrożeniowa (mocki docker/make)
bash scripts/test-autoupdate.sh # pętla auto-update
make test-makefile              # asercje kontraktowe (statyczne)
```

Dwa pierwsze są **osobnymi krokami CI** i oba przechodzą przez ścieżkę
`make run` — regresja w jednym zwykle zapala się też w drugim.

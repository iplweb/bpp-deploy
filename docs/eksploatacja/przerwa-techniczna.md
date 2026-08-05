# Przerwa techniczna z ostrzeżeniem

Zwykły `make run` kładzie serwis na kilka minut **bez uprzedzenia**. Użytkownik trafia
w środek wdrożenia, dostaje stronę „konserwacja" i nie wie, czy to awaria, czy plan.

`make run-with-warning` prowadzi całe wdrożenie tak, żeby ludzie wiedzieli z góry:

```
make pull  →  baner „za 5 minut przerwa"  →  odcięcie  →  make run  →  odblokowanie
   (bez wpływu           (5–10 min)          (503 ze stroną      (strona wraca)
  na użytkowników)                            przerwy)
```

Obrazy pobierane są **przed** wywieszeniem banera — pobieranie nie dotyka działającej
instalacji, więc okno ostrzeżenia to czysty czas na uprzedzenie ludzi, a realna
niedostępność ≈ czas samego `make run`.

!!! info "Wymagany obraz BPP z `django-countdown >= 0.3.0`"
    Banerem i blokadą zarządza aplikacja `django-countdown` wbudowana w obraz BPP.
    Na starszym obrazie `make run-with-warning` wypisze ostrzeżenie i zrobi
    **zwykłe wdrożenie** (bez uprzedzenia użytkowników) — nie zatrzyma się.
    Pozostałe komendy zgłoszą wtedy błąd.

## Szybki start

```bash
# typowa sesja: 5 minut ostrzeżenia, deklarowany powrót 10 minut po odcięciu
make run-with-warning

# dłuższe uprzedzenie i dłuższe okno serwisowe
make run-with-warning MINUTES=15 SERVICE=30 MESSAGE="Aktualizacja modułu raportów"
```

Pod `screen` (zalecane przy pracy zdalnej — sesja przeżyje zerwane połączenie):

```bash
screen -dmS bpp-deploy make run-with-warning MINUTES=10
screen -r bpp-deploy          # podgląd; odłączenie: Ctrl-A D
```

Sesja wypisuje statusy z upływem czasu:

```
[+00:00] === FAZA 1: pobieranie obrazow (bez wplywu na uzytkownikow) ===
[+07:12] pull OK
[+07:12] === FAZA 2: ostrzezenie ===
[+07:12] ostrzezenie WLACZONE
         odciecie:            14:35:00
         deklarowany powrot:  14:45:00
[+07:42] do odciecia 4 min 30 s ...
[+12:12] === FAZA 3: przerwa techniczna ===
[+12:12] strona ZABLOKOWANA (503 ze strona przerwy)
[+14:33] make run OK (2 min 21 s)
[+14:38] wszystkie uslugi zdrowe
[+14:38] === FAZA 4: koniec ===
[+14:38] ostrzezenie ZDJETE — strona dostepna
[+14:38] laczny czas sesji 14 min 38 s, niedostepnosc 2 min 26 s
```

## Co widzi użytkownik

| Faza | Zwykły użytkownik | Zalogowany superuser |
|---|---|---|
| Baner (przed odcięciem) | Pasek z komunikatem i tykającym licznikiem do przerwy | To samo |
| Blokada (po odcięciu) | Strona przerwy, HTTP **503**, z godziną powrotu | Serwis działa normalnie (można dokończyć pracę) |
| Trwa `make run` | Statyczna strona „konserwacja" (502 z nginxa — Django nie żyje) | To samo |
| Po zdjęciu | Serwis działa | Serwis działa |

Blokada **nie obejmuje** `/admin/`, `/static/` i `/media/` — to celowe: panel admina
musi być dostępny, żeby dało się dokończyć robotę.

## Komendy

| Komenda | Działanie |
|---|---|
| `make run-with-warning` | Pełna sesja: pull → baner → odcięcie → `make run` → odblokowanie |
| `make enable-site-down-warning` | Sam baner, bez wdrożenia (np. gdy chcesz uprzedzić i zrobić coś ręcznie) |
| `make disable-site-down-warning` | Zdejmuje baner i blokadę — **awaryjne odblokowanie strony** |
| `make extend-site-down-warning MINUTES=+10` | Przesuwa deklarowany powrót o 10 minut (`MINUTES=-5` ściąga o 5) |
| `make status-site-down-warning` | Stan przerwy; `JSON=1` daje dane maszynowe |

### Parametry

| Parametr | Zmienna w `.env` | Domyślnie | Znaczenie |
|---|---|---|---|
| `MINUTES` | `SITE_DOWN_WARNING_MINUTES` | `5` | Ile minut wisi baner, zanim strona zostanie odcięta |
| `SERVICE` | `SITE_DOWN_SERVICE_MINUTES` | `10` | Deklarowana długość przerwy (liczona **od odcięcia**) |
| `MESSAGE` | `SITE_DOWN_WARNING_MESSAGE` | `Planowana przerwa techniczna — aktualizacja systemu` | Nagłówek banera i strony przerwy (max 200 znaków) |
| `LONG_DESCRIPTION` | `SITE_DOWN_LONG_DESCRIPTION` | — | Dłuższy tekst, pokazywany tylko na stronie przerwy |
| `SITE_IDS` | `SITE_DOWN_SITE_IDS` | — | Lista id witryn przy multi-hoście (patrz niżej) |

Parametr podany przy `make` wygrywa z `.env`, `.env` wygrywa z wartością domyślną.
Wszystkie zmienne są nowe i mają wartości domyślne — **stary `.env` działa bez zmian**.

## Regulacja powrotu w trakcie przerwy

Sesja **nic nie czyta z klawiatury** — strumieniuje wyjście `make run` w oryginale.
Gdy okazuje się, że wdrożenie potrwa dłużej (albo skończyło się szybciej),
zmieniasz deklarowany powrót **z innego okna**:

```bash
make status-site-down-warning              # gdzie jesteśmy
make extend-site-down-warning MINUTES=+10  # "wracamy 10 minut później"
make extend-site-down-warning MINUTES=-5   # "wracamy 5 minut wcześniej"
```

Pod `screen`: `Ctrl-A C` otwiera nowe okno, `Ctrl-A "` przełącza między nimi.

Zmieniany jest **wyłącznie moment powrotu**. Godzina odcięcia jest obietnicą złożoną
użytkownikom, którzy widzieli ją na banerze, i sesja jej nie rusza.

## Zabezpieczenie na wypadek padniętej sesji

Dopóki sesja żyje, co 60 sekund podtrzymuje deklarowany powrót tak, żeby był
**nie bliżej niż 5 minut od teraz**:

```
moment powrotu = max(to, co zadeklarował operator, teraz + 5 min)
```

Dzięki temu:

- dopóki wdrożenie mieści się w obietnicy, użytkownik widzi **stabilną godzinę
  powrotu** i nic z tej mechaniki nie zauważa;
- gdy wdrożenie się przeciąga, godzina przesuwa się co 5 minut — uczciwie, bo
  faktycznie jeszcze nie wróciliśmy;
- gdy sesja zginie (`kill -9`, OOM, restart hosta), nikt już nie podtrzymuje
  terminu i **strona odblokuje się sama** najpóźniej po 5 minutach.

!!! warning "Świadomy kompromis"
    Ten mechanizm chroni przed „nikt nie zauważył, że serwis został zamknięty na
    zawsze". Nie chroni przed odwrotnym przypadkiem: jeśli padnie **cały host**
    w środku migracji, serwis otworzy się na wpół zmigrowanej bazie. Wybraliśmy
    wariant, w którym wcześniejsze otwarcie jest przeżywalne, a nienadzorowane
    trwałe zamknięcie nie.

## Gdy coś pójdzie nie tak

| Sytuacja | Zachowanie sesji |
|---|---|
| Błąd `make pull` (faza 1) | Przerwanie, nic się jeszcze nie stało |
| Ctrl-C w trakcie banera (faza 2) | Baner **zdejmowany**, czysty koniec — użytkownicy nic nie tracą |
| Błąd `make run` (faza 3) | Blokada **zostaje**, kod wyjścia ≠ 0, instrukcja na ekranie |
| Usługa `unhealthy` po wdrożeniu | Traktowane jak błąd — blokada zostaje |
| Ctrl-C po odcięciu | Blokada zostaje (stack w nieznanym stanie) |

Po odcięciu blokada zostaje **celowo**: lepiej pokazać stronę przerwy niż na wpół
zaktualizowany serwis. Gdy sesja padła, heartbeat nie bije, więc blokada wygaśnie
sama za ≤ 5 minut. Jeśli potrzebujesz więcej czasu na naprawę:

```bash
make extend-site-down-warning MINUTES=+30   # kup sobie pół godziny
make status-site-down-warning               # sprawdź stan
make disable-site-down-warning              # gotowe — otwórz serwis
```

## Multi-host

Przy [multi-hoście](../konfiguracja/multi-host.md) (`DJANGO_BPP_HOSTNAMES`) jedna
instalacja obsługuje wiele domen, a każda z nich jest osobną witryną w bazie.
Baner i blokada są zakładane **per witryna**, więc bez wskazania listy zablokujesz
tylko witrynę bieżącą, a pozostałe domeny zostaną otwarte.

Podaj listę id witryn:

```bash
make run-with-warning SITE_IDS="1 2 3"
```

albo na stałe w `$BPP_CONFIGS_DIR/.env`:

```bash
SITE_DOWN_SITE_IDS=1 2 3
```

Id witryn zobaczysz w panelu admina (*Witryny*) albo przez
`make status-site-down-warning JSON=1`, gdy przerwa jest już aktywna.

`make disable-site-down-warning` działa zawsze na **wszystkich** witrynach — gdy
serwis leży, nie chcesz najpierw ustalać, która domena zawiniła.

## Nienadzorowana aktualizacja z ostrzeżeniem

[Auto-update](aktualizacje.md#automatyczna-aktualizacja-make-autoupdate) może
uprzedzać użytkowników tak samo. W `$BPP_CONFIGS_DIR/.env`:

```bash
AUTOUPDATE_WARNING_MINUTES=10
```

Wtedy każdy automatyczny deploy zaczyna się od 10-minutowego banera. Puste albo `0`
= zachowanie dotychczasowe (wdrożenie bez uprzedzenia). Pętla nie zatrzymuje się,
gdy obraz nie wspiera przerwy — robi wtedy zwykłe wdrożenie.

## Testy

```bash
make test-deploy-with-warning
```

Sprawdza kolejność faz, przekazanie `BPP_SKIP_HEALTH_GATE=1`, zachowanie przy błędzie
wdrożenia, przerwanie w fazie banera, bicie heartbeatu i degradację na starym obrazie.
Nie wymaga `.env`, Dockera ani sieci — wszystko na mockach.

## Zobacz też

- [Najważniejsze komendy](komendy.md)
- [Aktualizacje i wersje obrazów](aktualizacje.md)
- [Multi-host](../konfiguracja/multi-host.md)

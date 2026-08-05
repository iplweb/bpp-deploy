# Utwardzenie brzegu (nginx)

Zestaw tanich reguł nginksa, które **odcinają ruch niebędący ruchem BPP, zanim
dotknie on Django** — i nie oddają skanerowi informacji o serwerze. To warstwa
niezależna od [WAF-a](waf.md): ModSecurity rozpoznaje *ataki*, a te reguły
rozpoznają *żądania, które z definicji nie są nasze*.

Wszystko siedzi w **wersjonowanych plikach** (`defaults/webserver/`), nie w
`$BPP_CONFIGS_DIR` — `git pull && make up` aktywuje bez migracji `.env`.

## Nagłówek `Server` bez numeru wersji

```nginx
server_tokens off;   # defaults/webserver/default.conf.template
```

Bez tego każda **poprawna** odpowiedź niosła `Server: nginx/1.30.4`. To zdanie
przeczyło reszcie konfiguracji: blokady oddajemy jako
[444, czyli bez sygnału zwrotnego](waf.md#dlaczego-444-a-nie-403), po czym sami
podawaliśmy wersję serwera do dopasowania z listą CVE — bez wysyłania czegokolwiek,
co WAF mógłby zauważyć.

!!! warning "To była regresja, nie brak funkcji"

    Obraz `owasp/modsecurity-crs:nginx` ma w środowisku `SERVER_TOKENS=off`.
    Dyrektywa, która tę zmienną czyta, siedzi jednak w **jego**
    `templates/conf.d/default.conf.template` — a ten plik
    [celowo nadpisujemy własnym](waf.md#1-inny-katalog-wyjsciowy-envsubst).
    Razem z generycznym reverse-proxy obrazu wypadł więc `server_tokens` i nginx
    wracał do wbudowanego `on`. **Ustawienie zmiennej `SERVER_TOKENS` w Compose
    nic by nie dało** — nie ma już szablonu, który by ją czytał.

Sam nagłówek `Server: nginx` zostaje. Usunięcie go całkiem wymaga
`more_clear_headers` (moduł headers-more, obecny w obrazie), ale pusty lub
nietypowy `Server` bywa sygnaturą sam w sobie, więc zysk byłby zerowy.

## Rozszerzenia wykonywalne → 444

```nginx
location ~* \.(php[0-9]*|phtml|asp|aspx|jsp|jspx|cgi|cfm|exe|dll|jar)$
```

BPP nie serwuje **ani jednego** pliku z rozszerzeniem wykonywalnym, więc to nie
jest lista cudzych podatności (taka się starzeje), tylko **negatywna definicja
własnej przestrzeni URL**.

!!! tip "Dlaczego `php[0-9]*`, a nie `php|php3|php5|php7`"

    Przegląd 72 h access logów produkcji (05.08.2026) pokazał realne sondy:
    `.php73`, `.php56`, `.php7`, `.PhP7`. Wyliczenie wariantów, które wyglądało
    rozsądnie, **przepuściłoby 3 z 5 trafień**. Skanery celowo sypią
    wersjonowanymi rozszerzeniami, bo serwery z PHP-FPM często wykonują wszystko,
    co pasuje do `\.php`. Klasa znaków łapie też to, czego jeszcze nie wymyślono;
    modyfikator `~*` załatwia wielkość liter.

Ta warstwa jest **druga, nie pierwsza**: te same rozszerzenia blokuje już
`MaliciousRequestBlockingMiddleware` w obrazie BPP (`BLOCKED_EXTENSIONS`
w `bpp/src/bpp/middleware.py`, również przez 444). Różnica jest w koszcie — tam
żądanie zajmuje workera Django i przechodzi cały stos proxy, tutaj kończy się
na brzegu. **Ochrona się nie zmienia, zmienia się cena.**

## Prefiksy obcych aplikacji → 444

```nginx
location ~* ^/(wp-admin|wp-content|wp-includes|wp-json|wordpress|wp
              |phpmyadmin|pma|myadmin|dbadmin|adminer
              |administrator|typo3|telescope|_ignition|vendor
              |actuator|jmx-console|solr|jenkins|manager/html
              |owa|autodiscover|ecp|_next|_nuxt|cgi-bin|minishell)(/|$)
```

Ścieżki, które **nigdy** nie mogą być URL-em BPP. Kryterium doboru: nazwa
produktowa obcej aplikacji — nie „coś podejrzanego" i nie generyczne słowo
angielskie (`console`, `debug` są świadomie **pominięte**: mogłyby kiedyś stać się
realną ścieżką BPP).

`(/|$)` na końcu jest konieczne — bez niego `administrator` złapałoby także
`/admin/`, czyli panel Django.

!!! note "Uczciwa miara wartości"

    Ten sam pomiar 72 h pokazał **~20 takich żądań, czyli ~0,3/h**. To nie jest
    odpowiedź na bieżące obciążenie — appservera nikt tu nie zjada. To
    ubezpieczenie na wypadek, gdyby ktoś puścił w serwis pełny słownik.

    **Nie rozbudowuj tej listy „na zapas".** Publiczne słowniki skanerów mają
    dziesiątki tysięcy pozycji, więc kompletność nie jest osiągalna, a każda
    kolejna pozycja to ryzyko kolizji z przyszłym URL-em BPP.

## Niepodstawione literały szablonów → 444

```nginx
location ~* (\{\{[^}]*\}\}|\$\{[^}]*\})
```

Boty i zepsute frontendy chodzą po URL-ach z niepodstawionym literałem szablonu,
np. `/bpp/rekord/<slug>/{{ clickURL }}` albo `/bpp/uczelnia/UP/${todayFeature.link}`.

!!! bug "Poprzednia wersja miała dziurę"

    Wzorzec brzmiał `\{\{\s*clickURL\s*\}\}`, a produkcja dostawała
    `%7B%7B+clickURL+%7D%7D`. Nginx dekoduje `%7B` na `{` przed dopasowaniem
    location, ale **`+` w ścieżce nie jest dekodowany na spację** — to konwencja
    `application/x-www-form-urlencoded`, obowiązująca w query stringu, nie w
    ścieżce. `\s*` nie miało więc czego dopasować i żądanie szło do Django
    (11 sztuk na 72 h, wszystkie jako 404).

    Zweryfikowane doświadczalnie: wariant ze spacją i bez separatora dawały 444,
    wariant z `+` dawał 404. `make test-waf` pilnuje teraz wszystkich trzech.

`[^}]*` przyjmuje spację, `+`, `%20` i cokolwiek jeszcze wygeneruje szablon.
Wzorzec jest też celowo szerszy niż sam `clickURL` — łapie każdy niepodstawiony
literał `{{…}}` (Angular/Vue/Handlebars) oraz `${…}` (template literal JS). Żaden
legalny URL BPP nie zawiera nawiasów klamrowych.

## Timeouty klienta

```nginx
client_header_timeout 15s;
send_timeout          30s;
```

Domyślne nginksowe 60 s oznacza, że klient może trzymać połączenie przez minutę,
wysyłając nagłówki po bajcie (slowloris); każde takie połączenie zajmuje slot
workera (`WORKER_CONNECTIONS=1024` w obrazie).

!!! danger "`client_body_timeout` ustawia się zmienną, nie dyrektywą"

    Obraz CRS ustawia `client_body_timeout` w kontekście `http`
    (`nginx.conf.template`), z domyślną wartością **10 s** — ostrzejszą niż
    cokolwiek, co warto tam wpisać. Powtórzenie tej dyrektywy w tym samym
    kontekście to **twardy błąd startu**:

    ```
    [emerg] "client_body_timeout" directive is duplicate
    ```

    czyli cały serwis nie wstaje. Gdyby trzeba było ją zmienić, właściwym miejscem
    jest zmienna `CLIENT_BODY_TIMEOUT` w `environment` webservera. To samo dotyczy
    `KEEPALIVE_TIMEOUT` (60 s) i `WORKER_CONNECTIONS`.

Nie mylić z `proxy_*_timeout` w `_bpp-locations.conf` (60/300/300 s): tamte
dotyczą rozmowy nginx ↔ Django i **muszą** zostać długie, bo raporty BPP liczą się
minutami. Te tutaj dotyczą wyłącznie rozmowy klient ↔ nginx.

`send_timeout` to przerwa w **odbiorze** przez klienta, a nie czas na całą
odpowiedź — wolne, ale postępujące pobieranie dużego PDF-a z `/media/` nie jest
zrywane.

## Pułapka przy każdej zmianie: regex bije prefiks

W nginksie `location` z wyrażeniem regularnym ma pierwszeństwo przed zwykłym
prefiksem. Dlatego reguły z tej strony działają także wewnątrz `/static/` i
`/media/` — i dlatego **do listy rozszerzeń nie wolno wnieść niczego, co realnie
serwujecie**. `\.js$` zabiłoby całą statykę serwisu, mimo że w bloku `/media/`
identyczny wpis jest poprawny (tam nic się nie wykonuje).

Ta sama klasa błędu wymusiła kiedyś `^~` przy
[`/.well-known/`](rate-limiting.md#well-known-wyjatek-przed-blokada-plikow-ukrytych).

Bateria `make test-waf` ma na to dwie kontrole granic: `/admin/` nie może złapać
się na `administrator`, a `/static/js/app.js` musi przejść.

## Sprawdzenie

```bash
make test-waf
```

35 przypadków, w tym wszystkie reguły z tej strony i asercja, że `Server` nie
niesie numeru wersji. Szczegóły stanowiska: [WAF → `make test-waf`](waf.md#sprawdzenie-czy-waf-dziala-make-test-waf).

## Pomiar: co naprawdę puka do Waszego serwisu

Listy z tej strony aktualizuje się **pomiarem, nie zgadywaniem**. Źródłem prawdy
jest własny access log — poniższe zapytanie pokazuje ścieżki, które przeszły przez
CRS czysto, zajęły workera Django i skończyły się 404:

```bash
docker logs $(docker ps -q -f label=com.docker.compose.service=webserver) --since 72h 2>/dev/null \
  | awk '$9==404 {print $7}' | sed 's/?.*//' | sort | uniq -c | sort -rn | head -40
```

`$7` to ścieżka, `$9` to status — układ zgodny z formatem `bpp_access`
(`defaults/webserver/00-log-format.conf`), tym samym, na którym opiera się
[`make request-stats`](rate-limiting.md#pomiar-przed-strojeniem).

W praktyce większość wyników tego zapytania to **nie skanery**, tylko własne
zepsute linki, brakujące pliki w `/media/` i błędy frontendu. To również jest
wartościowa informacja — tyle że dla aplikacji, nie dla nginksa.

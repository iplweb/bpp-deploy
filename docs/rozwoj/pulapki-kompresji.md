# Pułapki przy kompresji odpowiedzi

Strona dla osoby ruszającej kompresję w `defaults/webserver/_bpp-locations.conf`
albo rozważającej brotli/zstd. Zbiera dowody, których nie widać w review: dwa
sposoby na to, żeby kompresja **wyglądała** na włączoną i nie działała, oraz
zmierzony werdykt w sprawie brotli.

Konfiguracja gzipa żyje w `_bpp-locations.conf` (kontekst `server`, plik
bind-mountowany z repo — `git pull && make up` aktywuje zmiany bez migracji
`.env`).

## `gzip_static on` bez plików `.gz` to cicha atrapa

`gzip_static on` **nie znaczy** „kompresuj statyki". Znaczy: „jeśli obok
`x.js` leży `x.js.gz`, wyślij ten plik zamiast kompresować w locie".

!!! bug "Dyrektywa była włączona i nie robiła nic — przez cały czas życia konfiguracji"

    Pomiar na obrazie `iplweb/bpp_appserver:202608.1399rc5`: **3429 plików
    w `/app/staticroot.baked`, z tego 0 plików `.gz`**. Nginx nie miał czego
    znaleźć, więc spadał na `gzip on` i kompresował `plotly.min.js` (4,4 MB)
    od nowa przy każdym cache-missie.

    Objawu nie ma żadnego. Strona działa, nagłówek `Content-Encoding: gzip`
    jest, rozmiar odpowiedzi się zgadza. Różnica siedzi wyłącznie w zużyciu
    CPU na brzegu i w poziomie kompresji (w locie 5, offline 9).

Naprawa jest **po stronie obrazu BPP**, nie tutaj: `docker/bpp_base/Dockerfile`
(krok „R16") gzipuje `staticroot.baked` zaraz po `collectstatic`. W tym repo
nie trzeba zmieniać nic — `gzip_static on` zaczyna działać samo, gdy tylko
przyjedzie obraz z plikami `.gz`.

## Dlaczego prekompresja MUSI powstawać razem z plikiem źródłowym

To jest powód, dla którego kompresja nie może być krokiem runtime'owym na
wolumenie `staticfiles`.

!!! danger "Nginx serwując `x.js.gz` NIE porównuje mtime z `x.js`"

    Nieaktualny `.gz` = **wieczne serwowanie starego JS-a** wszystkim
    przeglądarkom deklarującym gzip (czyli wszystkim), bez śladu w logach.
    Objaw zgłaszany przez operatora brzmi „zaktualizowałem i nic się nie
    zmieniło".

Generowanie `.gz` w tym samym kroku builda co plik źródłowy usuwa problem
z definicji — nie ma okna, w którym mogłyby się rozjechać. Dokłada się do tego
zachowanie entrypointu appservera, który robi **`cp -rf`** (nie `-u`!)
z `.baked` do `$STATIC_ROOT`, więc przy każdym starcie kontenera para
`.js` + `.js.gz` jest nadpisywana razem.

Częściowo chroni też `ManifestStaticFilesStorage`: pliki z content-hashem
w nazwie (`bundle.622407b566ad.js`) przy zmianie treści dostają nową nazwę.
Ale obok leżą **wersje bez hasza** (`bundle.js`, `plotly.min.js`) i te są
podatne — nie licz na hashe jako zabezpieczenie.

## django-compressor: to, co pobiera przeglądarka, powstaje dopiero w runtime

Druga pułapka tej samej rodziny, a wygląda zupełnie inaczej.

BPP używa `django-compressor` (`COMPRESS_ENABLED = not DEBUG`,
`COMPRESS_ROOT = STATIC_ROOT`, `COMPRESS_OUTPUT_DIR = "CACHE"`).
Szablon `bare.html` pakuje `bundle.js` (786 KB) w `{% compress js %}` — czyli
przeglądarka pobiera **`/static/CACHE/js/output.<hash>.js`**, a nie plik
z `.baked`. Prekompresja zrobiona wyłącznie w buildzie obrazu ominęłaby ten
plik w całości.

Dlatego drugi krok siedzi w `docker/appserver/entrypoint-appserver.sh`, zaraz
po `manage.py compress`. Tu nieaktualny `.gz` nie grozi, bo compressor nazywa
wyjście content-hashem — zmiana treści to nowa nazwa, nie nadpisanie starej.

!!! tip "Które assety idą którą drogą"

    Trzy największe pliki — `plotly.min.js` (4,4 MB), `three-bundle.js`
    (1,9 MB), `cytoscape-bundle.js` (886 KB) — są w szablonach ładowane przez
    `{% static %}` **poza** blokami `{% compress %}`, czyli serwowane wprost
    z `.baked`. Sprawdź to, zanim uznasz, że jeden z dwóch kroków wystarczy.

## Brotli i zstd — zmierzony werdykt

Pytanie wraca regularnie w review. Odpowiedź: **zysk jest realny, cena też**,
i nie jest tam, gdzie się jej intuicyjnie szuka.

### Zysk

| plik | surowo | gzip‑5 (w locie) | gzip‑9 (offline) | brotli‑11 (offline) |
|---|---:|---:|---:|---:|
| `plotly.min.js` | 4452 KB | 1315 KB | 1299 KB | **948 KB** (−28%) |
| `bundle.js` | 786 KB | 225 KB | 222 KB | **187 KB** (−17%) |

Dotyczy to **wyłącznie `/static/`** — HTML z Django idzie przez proxy.
A `/static/` ma `expires` + `Cache-Control: immutable`, więc powracający
użytkownik i tak nic nie pobiera: **brotli poprawia głównie pierwszą wizytę.**

### Cena — trzy rzeczy, które wychodzą dopiero przy próbie

Wszystkie trzy zweryfikowane empirycznie na `owasp/modsecurity-crs:nginx`
(nginx 1.30.4, Debian 13):

1. **Repo nginx.org nie ma modułu brotli.** Pełna lista dla trixie: `geoip`,
   `image-filter`, `njs`, `otel`, `perl`, `xslt`. Wariant „doinstaluj pakiet"
   nie istnieje.
2. **Moduł debianowy odbija się o ABI.** `libnginx-mod-http-brotli-filter`
   deklaruje `Depends: nginx-abi-1.26.3-1`; wymuszony ręcznie daje
   `[emerg] module ... version 1026003 instead of 1030004`. `--with-compat`
   tego nie ratuje. Zostaje kompilacja ze źródeł (zmierzone: 73 s).
3. **Łatka na `nginx.conf` nie przeżywa startu kontenera.** Entrypoint CRS
   regeneruje ten plik z `/etc/nginx/templates/nginx.conf.template` przy
   **każdym** starcie. Build z `sed` na `nginx.conf` jest zielony, a kontener
   nie wstaje: `[emerg] unknown directive "brotli_static"`. Łatać trzeba
   szablon, z `test -f` przed `sed`, żeby zmiana u upstreamu wywalała **build**,
   a nie produkcję.

To ta sama rodzina co `server_tokens off` w
[utwardzeniu brzegu](../architektura/utwardzenie-brzegu.md): obraz CRS traktuje
całe `/etc/nginx/` jako **generowane**, nie jako stan.

### Dlaczego mimo to nie wchodzimy

Prawdziwy koszt nie leży w Dockerfile (~25 linii), tylko w utrzymaniu:

- **Sprzężenie wersji jest twarde i kładzie serwis.** Moduł ma wpisane
  `1030004`; podbicie nginksa w obrazie bazowym → nginx nie wstaje. A tag
  `owasp/modsecurity-crs:nginx` jest **pływający** (patrz komentarz
  w `docker-compose.infrastructure.yml`) — upstream może to zrobić cicho.
- **Model wdrożenia zmienia się z „pull" na „build"** — albo kompilacja na
  każdym hoście, albo szósty publikowany obraz w `DOCKER_VERSION`
  i `lib-docker-versions.sh`.
- **`autoupdate.sh` porównuje digesty z rejestru**, których obraz budowany
  lokalnie nie ma.
- **`make test-waf` przestaje testować to, co jedzie na produkcję**, dopóki
  nie zacznie budować naszego obrazu.

Niezmierzone i wymagające sprawdzenia przed ewentualnym wdrożeniem: kolejność
filtra brotli względem inspekcji odpowiedzi przez ModSecurity (reguły
`RESPONSE-95x`, patrz [WAF](../architektura/waf.md)).

**zstd odpada bez dyskusji** — nie ma go w żadnym pakiecie, tylko
`tokers/zstd-nginx-module` do zbudowania ze źródeł. Doklejanie kompilacji
trzeciej strony do kontenera brzegowego z WAF-em to zły interes za ~10% ponad
brotli.

# Design: `make test-upgrade` (próba generalna migracji) + `make zaspawaj-wersje` (pinowanie DOCKER_VERSION)

Data: 2026-06-12
Status: zaakceptowany kierunek, do implementacji

## Kontekst i motywacja

Docelowo bpp-deploy ma dostać automatyczny, zdalny deployment w modelu pull
(systemd timer na hoście wykrywa nowy release-tag → pipeline: kotwica → pull →
backup → próba generalna → `make run` → zaspawanie wersji → ntfy; awaria =
stop + alert + sesja tmux do wglądu). Ten spec realizuje **dwa pierwsze,
samodzielnie użyteczne klocki** tego pipeline'u jako ręczne cele make:

1. **`test-upgrade`** — próba generalna: czy migracje obrazu-kandydata
   przechodzą na kopii produkcyjnej bazy, bez dotykania działającego stacka.
2. **`zaspawaj-wersje`** — utrwalenie w `.env` wersji obrazów iplweb, na
   której faktycznie chodzi produkcja (`DOCKER_VERSION=<tag CalVer>` zamiast
   ruchomego `latest`).

Główne ryzyko, które adresujemy: "zbuduje się kupa" — nowy obraz z migracją,
która nie przechodzi, wykładał produkcję dopiero w trakcie deployu. Po tej
zmianie padnięta migracja zostaje wykryta na boku, na świeżej kopii
produkcyjnych danych, zanim ktokolwiek dotknie działających usług.

## Zakres

**W zakresie:**

- Target `make test-upgrade [TAG=...]` + skrypt `scripts/test-upgrade.sh`.
- Target `make test-upgrade-clean` (sprzątanie shadow stacka po awarii).
- Target `make zaspawaj-wersje [TAG=...]` + skrypt `scripts/zaspawaj-wersje.sh`.
- Wspólny helper rozwiązywania wersji (digest ↔ tag CalVer przez API Docker Huba).
- Dokumentacja (docs/eksploatacja/komendy.md + pomoc `make help`).

**Poza zakresem (przyszłe etapy):**

- Auto-deploy (systemd timer, tmux, ntfy, lockfile, kotwica, rollback).
- Pinowanie wersji w release'ach bpp-deploy (release deklaruje DOCKER_VERSION).
- Zmiany w `make release` / `wait-for-build.sh`.

## Cel 1: `make test-upgrade`

```
make test-upgrade [TAG=202606.1386]
```

### Przebieg

1. **Rozwiązanie kandydata.** Bez `TAG`: najnowszy tag CalVer
   (wzorzec `^[0-9]{6}\.[0-9]+$`) z API Docker Huba dla `iplweb/bpp_appserver`.
   Obraz jest pullowany **po tagu wersji, nie przez `:latest`** — lokalny tag
   `latest`, na którym chodzi produkcja, pozostaje nietknięty (jedyny "cichy"
   kanał nadpisania produkcji zostaje zamknięty).
2. **Backup.** `make db-backup` (istniejący: `pg_dump -Fd -j4` → tar.gz w
   `$DJANGO_BPP_HOST_BACKUP_DIR`). Błąd backupu = twarde przerwanie —
   zasada "bez kotwicy nie ruszamy dalej".
3. **Shadow stack** — poza projektem Compose, na dedykowanej sieci docker
   `bpp-shadow` (czysty `docker run`, prefiks nazw `bpp-shadow-*`):
   - `bpp-shadow-dbserver`: `iplweb/bpp_dbserver:psql-$DJANGO_BPP_POSTGRESQL_VERSION`
     (ten sam obraz co produkcja — już lokalnie obecny), tymczasowy wolumen,
     te same `DJANGO_BPP_DB_USER/PASSWORD/NAME` co produkcja (zgodność ról
     przy restore), limity zasobów przycięte (RAM/CPU), czekanie na
     `pg_isready`.
   - `bpp-shadow-redis`: `redis:8.6.2` (ta sama wersja co w
     `docker-compose.infrastructure.yml`).
4. **Restore dumpa** do shadow-bazy: untar + `pg_restore -Fd -j N --no-owner`.
5. **Migracja kandydatem** — entrypoint override, nic poza migracją się nie
   uruchamia:

   ```
   docker run --rm --network bpp-shadow \
     -e DJANGO_BPP_DB_HOST=bpp-shadow-dbserver \
     -e DJANGO_BPP_REDIS_HOST=bpp-shadow-redis \
     (… reszta wymaganych env z $BPP_CONFIGS_DIR/.env …) \
     --entrypoint python \
     iplweb/bpp_appserver:<kandydat> src/manage.py migrate --noinput
   ```

6. **Wynik:**
   - **Sukces** → komunikat "migracje \<kandydat\> przechodzą na kopii
     produkcyjnej bazy", pełne sprzątanie (kontenery + wolumen + sieć),
     exit 0.
   - **Porażka** → ogon logu migracji, **shadow stack zostaje** do ręcznej
     inspekcji (`docker exec`/`psql`), instrukcja sprzątnięcia
     (`make test-upgrade-clean`), exit 1.

Exit code czyni target komponowalnym — w przyszłym auto-deployu będzie
krokiem "próba generalna" bez zmian.

### Gwarancje nienaruszalności produkcji

- Zero operacji na kontenerach/wolumenach projektu Compose.
- Zero zmian lokalnego tagu `latest` (pull wyłącznie po tagu wersji).
- Zero zapisu do `$BPP_CONFIGS_DIR/.env`.
- Jedyne obciążenie: CPU/IO podczas dump+restore oraz dysk ≈ rozmiar bazy
  (sprawdzany przed startem; brak miejsca = czytelne przerwanie).

### `make test-upgrade-clean`

Idempotentne usunięcie `bpp-shadow-*` (kontenery, wolumen, sieć). Wywoływane
też automatycznie na początku `test-upgrade` (zombie z poprzedniego przebiegu).

## Cel 2: `make zaspawaj-wersje`

```
make zaspawaj-wersje [TAG=202606.1386]
```

### Przebieg

1. Bez `TAG`: odczytaj digest obrazu z **działającego kontenera** `appserver`
   (nie z lokalnego tagu `latest` — po `make pull` bez recreate lokalny
   `latest` może już wskazywać nowszy, nieprzetestowany obraz; spawamy stan
   faktyczny produkcji).
2. Rozwiąż digest → tag CalVer przez API Docker Huba.
3. Sanity-check: pozostałe kontenery iplweb (`authserver`, `workerserver`,
   `denorm-queue`, `celerybeat`) chodzą na tej samej wersji? Rozjazd →
   ostrzeżenie (spawamy wg appservera).
4. `set_env_var DOCKER_VERSION=<tag>` w `$BPP_CONFIGS_DIR/.env` — istniejące
   stabilne helpery (`env_has_var`/`get_env_var`/`set_env_var`), nie własny sed.
5. Komunikat końcowy; **nic nie jest restartowane** — pin obowiązuje od
   następnej operacji compose.

Z `TAG=` target jest też ręczną ścieżką aktualizacji na zaspawanym hoście:
`make zaspawaj-wersje TAG=<nowy> && make pull && make up`.

### Zasięg zmiennej

`DOCKER_VERSION` steruje dokładnie pięcioma obrazami iplweb: `bpp_appserver`,
`bpp_authserver`, `bpp_workerserver`, `bpp_denorm_queue`, `bpp_beatserver`.
Pozostałe obrazy (nginx, redis, grafana, netdata, ofelia, certbot, …) są już
przypięte na sztywno w plikach compose; dbserver ma własną
`DJANGO_BPP_POSTGRESQL_VERSION`. Target nie dotyka niczego poza
`DOCKER_VERSION`.

### Tryby błędu

- Kontener `appserver` nie działa → błąd z podpowiedzią (`TAG=` albo `make up`).
- Digest nieznany w Hubie (obraz budowany lokalnie, bardzo stary tag) lub brak
  sieci → czytelny błąd, `.env` nietknięty.
- `DOCKER_VERSION` już ustawiony → nadpisanie z komunikatem
  (target jest idempotentny: "przybij to, co chodzi").

## Wspólny helper: rozwiązywanie wersji

Oba cele potrzebują mapowania digest ↔ tag CalVer. Wspólna funkcja (w
`scripts/`, source'owana przez oba skrypty):

- `resolve_latest_calver(repo)` → najnowszy tag `^[0-9]{6}\.[0-9]+$` z
  `hub.docker.com/v2/repositories/iplweb/<repo>/tags`.
- `resolve_digest_to_calver(repo, digest)` → tag CalVer o tym samym digeście.

Zależności: `curl` + `jq` (jq jest już zależnością `wait-for-build.sh`).
Implementacja może dodatkowo preferować etykietę OCI
`org.opencontainers.image.version`, jeśli obrazy ją niosą (do weryfikacji
w trakcie implementacji); API Huba pozostaje ścieżką gwarantowaną.

## Kompatybilność wsteczna

- Żadnych nowych wymaganych zmiennych. Domyślka compose
  `${DOCKER_VERSION:-latest}` zostaje — host bez zaspawania działa jak dotąd.
- `zaspawaj-wersje` jest opt-in per host; `.env` modyfikowany wyłącznie
  stabilnymi helperami.
- `test-upgrade` niczego nie zmienia w konfiguracji — jest czystym odczytem
  (plus dump, który i tak jest standardową operacją).

## Testy

- Skrypty z testami jednostkowymi w konwencji repo
  (`scripts/test-letsencrypt.sh`-style: mockowany `docker`/`curl`, bez sieci)
  dla logiki rozwiązywania wersji i ścieżek błędów.
- Test manualny na hoście stagingowym: pełny przebieg `test-upgrade`
  (sukces + symulowana porażka migracji), `zaspawaj-wersje` na działającym
  stacku.

## Dokumentacja (docs-sync)

- `docs/eksploatacja/komendy.md`: sekcje dla obu targetów.
- `make help`: wpisy w sekcjach Deployment/Konfiguracja.
- `CLAUDE.md`: wzmianka o pinowaniu DOCKER_VERSION (kontrakt: latest vs pin).
- `mkdocs build --strict` po zmianach.

## Roadmapa (kontekst, poza tym specem)

Kolejność dalszych etapów uzgodniona w dyskusji 2026-06-12:

1. ten spec (klocki ręczne),
2. auto-deploy pull-based: timer systemd + tmux + ntfy + lockfile + kotwica
   (stary kod wykonuje pre-flight: kotwica → pull → backup → test-upgrade;
   `git checkout <tag>` dopiero po udanej próbie; `make run` nowym kodem;
   zaspawanie po sukcesie),
3. ewentualnie: release bpp-deploy deklarujący wersję obrazów.

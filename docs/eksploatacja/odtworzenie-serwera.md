# Odtworzenie serwera po awarii

Serwer padł, a zostały tylko kopie na zdalnym (rclone). `make restore-server`
stawia na **czystej maszynie** cały serwer BPP z jednej nocy kopii:
konfigurację (z kluczem szyfrowania), obrazy Dockera, bazę i media. Działa także
wtedy, gdy **Docker Hub albo GitHub są niedostępne**, pod warunkiem że na zdalnym
jest [archiwum obrazów](backup-i-rclone.md#archiwum-obrazow).

To, czy ta procedura naprawdę działa, sprawdza **raz na kwartał**
[`make proba-odtworzenia`](#proba-kwartalna). Próba uruchamia ten sam kod obok
produkcji i nie zmienia na niej niczego.

## Co jest potrzebne

- maszyna z Dockerem i pluginem Compose ([Instalacja](../instalacja/index.md)),
- repozytorium `bpp-deploy`:
  ```bash
  git clone https://github.com/iplweb/bpp-deploy.git ~/bpp-deploy
  # GitHub nie działa? Repo jest w archiwum obrazów na zdalnym:
  rclone copy backup_enc:obrazy/<YYYYMMDD-HHMMSS>/bpp-deploy.bundle ~/
  git clone ~/bpp-deploy.bundle ~/bpp-deploy
  ```
- **dostęp do kopii zdalnej**, czyli jedno z dwóch:
    - `rclone.conf` z remote'em kopii (np. zapisany w menedżerze haseł albo
      skopiowany z innego serwera),
    - dostęp do samego magazynu (np. konto Google Drive) i **hasło `crypt`**.
      Skrypt pyta wtedy o ścieżkę zaszyfrowanych danych i o hasło.

!!! warning "Hasło crypt trzymaj poza serwerem"
    Plik `rclone.conf` jest w kopii konfiguracji, ale ta kopia sama leży
    w zaszyfrowanym remote. Bez hasła `crypt` (albo bez `rclone.conf` trzymanego
    gdzie indziej) kopii **nie da się odczytać**. Zapisz hasło w menedżerze haseł
    instytucji.

- `rclone` **na hoście**, gdy Docker Hub nie działa (pakiet dystrybucji albo
  binarka z rclone.org). Bez niego skrypt użyje obrazu `rclone/rclone`, a ten
  pochodzi z Docker Huba.

## Odtworzenie

```bash
cd ~/bpp-deploy
make restore-server                            # najnowszy komplet
make restore-server DATA=20261124              # konkretna noc
make restore-server RCLONE_CONF=~/rclone.conf BPP_CONFIGS_DIR=/home/bpp/uczelnia
```

!!! danger "Nie uruchamiaj wcześniej `make` ani `make init-configs`"
    Na świeżym hoście `make` wchodzi w pierwsze uruchomienie, a `init-configs`
    wygenerowałby **nowy klucz szyfrowania**. Wtedy sekrety zapisane w bazie
    (tokeny PBN, hasła integracji) stają się nieczytelne. `make restore-server`
    działa bez `.env` i sam odtwarza konfigurację, zanim wywoła jakiekolwiek
    inne polecenie `make`.

Przebieg:

1. **Dostęp do kopii.** Skrypt pyta o ścieżkę do `rclone.conf` (Enter uruchamia
   kreator `rclone config`) i o nazwę remote'a (domyślnie `backup_enc:`). Jeśli
   tego remote'a nie ma w pliku, pyta o ścieżkę zaszyfrowanych danych i o hasło
   `crypt`. Hasło jest czytane bez echa i **nigdy nie trafia do argumentów
   procesów**: ani do `ps`, ani do historii powłoki.
2. **Wybór kompletu.** Skrypt szuka najnowszej nocy, która ma **wszystkie trzy**
   pliki z tym samym znacznikiem czasu: `db-backup-`, `media-backup-` i
   `config-backup-<TS>.tar.gz`. Nowsze niekompletne noce pomija i wypisuje
   ostrzeżenie. `DATA=` wskazuje konkretną noc. Jeśli wskazana noc jest
   niekompletna, skrypt kończy się błędem z listą brakujących plików i niczego
   nie zmienia.
3. **Pobranie i weryfikacja**: integralność gzip/tar, obecność `toc.dat`
   w zrzucie bazy i `.env` w kopii konfiguracji. Potem podsumowanie
   i potwierdzenie: trzeba wpisać `tak`.
4. **Konfiguracja.** Odtwarza ją `restore-config` (z jego zabezpieczeniami).
   Repo-lokalny `.env` zapisuje się sam. Działający `rclone.conf`, którym
   pobrano kopie, zastępuje plik z archiwum (ma świeższy token OAuth); plik
   z archiwum zostaje jako `rclone.conf.z-kopii-<TS>`.
5. **Obrazy.** Skrypt pobiera z `REMOTE:obrazy/` zestaw nie nowszy niż kopia,
   czyli obrazy, na których serwer działał tamtej nocy, i wczytuje go przez
   `make images-load`. Bez archiwum robi `docker pull` dokładnie wersji
   z manifestu (`repo@digest`), a bez manifestu wersji z `.env`
   (`DOCKER_VERSION`). `OBRAZY=archiwum` wymusza archiwum, `OBRAZY=pull`
   wymusza pobranie z Huba. Archiwum może nie istnieć, jeśli serwer miał za
   mało miejsca na dysku ([rezerwa](backup-i-rclone.md#archiwum-obrazow):
   adnotacja `obrazy=ZA-MALO-MIEJSCA` w raporcie nocnym) albo je wyłączono —
   wtedy odtworzenie wymaga działającego Docker Huba.
6. **Zrzut bazy** sprawdza `pg_restore --list` w obrazie `dbserver`.
7. **Baza i media** wracają przez `make restore` (bez kopii bezpieczeństwa,
   bo na czystej maszynie nie ma czego zabezpieczać), potem uruchamia się
   `make up`.
8. **Sprawdzenie**: appserver musi odpowiedzieć na `/health/` i na `/`
   (kod 2xx/3xx, nagłówek `Host` z konfiguracji).

Na końcu skrypt wypisuje jedną linię wyniku i dopisuje ją do
`$BPP_CONFIGS_DIR/logs/odtworzenie-serwera.log`. Pobrane pliki zostają
w `bpp-odtworzenie-<data>/` obok katalogu konfiguracyjnego i można je usunąć
ręcznie.

Skrypt odmawia działania, gdy na hoście chodzi już stack BPP. Na działającym
serwerze służą do tego `make restore` (baza i media z lokalnych kopii) albo
[próba](#proba-kwartalna).

!!! note "Baza zewnętrzna"
    Kopia konfiguracji nie obejmuje repo-lokalnego `.env`. Przy bazie
    zewnętrznej dopisz tam `BPP_DATABASE_COMPOSE=docker-compose.database.external.yml`
    po kroku 4 i uruchom ponownie.

Po odtworzeniu: DNS, certyfikaty i adresy, jak w
[przenosinach serwera](przenosiny-serwera.md#co-przeniesc-warto-ale-opcjonalnie).

## Próba kwartalna — `make proba-odtworzenia` {#proba-kwartalna}

Kopia, której nikt nie próbował odtworzyć, jest tylko nadzieją. Próbę uruchamia
się **na serwerze produkcyjnym**:

```bash
cd ~/bpp-deploy
make proba-odtworzenia                   # najnowszy komplet ze zdalnego
make proba-odtworzenia DATA=20261124     # konkretna noc
```

Kod jest ten sam co przy odtworzeniu (wybór kompletu, pobranie, weryfikacja,
`restore-config`), ale baza, media i appserver lądują w **shadow stacku**
`bpp-shadow-*`, tym samym, którego używa
[`make test-upgrade`](aktualizacje.md#make-test-upgrade-proba-generalna-aktualizacji),
i pod tą samą blokadą (obie próby naraz się nie uruchomią, exit 2). Produkcja
pozostaje nietknięta:

- konfiguracja z kopii trafia do katalogu tymczasowego, a produkcyjny `.env`
  nie jest zmieniany. Próba porównuje tylko klucz szyfrowania z kopii
  z produkcyjnym (`klucz zgodny` / `klucz INNY niż produkcja`);
- archiwum obrazów jest sprawdzane (suma sha256, manifest, `git bundle verify`),
  ale **nie** przez `docker load`. Wczytanie przepięłoby produkcyjne tagi
  (np. `latest`) na obrazy z archiwum. Shadow startuje na obrazie z manifestu,
  jeśli jest lokalnie, a inaczej na tym, na którym chodzi produkcja;
- rclone tylko czyta ze zdalnego, a kanały powiadomień appservera shadow
  (Rollbar, GlitchTip, Slack) są wyzerowane. Nic nie jest nigdzie wysyłane;
- shadow i pobrane pliki (`$DJANGO_BPP_HOST_BACKUP_DIR/.proba-odtworzenia-*`)
  są sprzątane. Po błędzie przy terminalu shadow zostaje do obejrzenia
  (`KEEP_SHADOW=0|1` wymusza decyzję), a sprząta go `make test-upgrade-clean`.

Potrzebne miejsce: pobrany komplet, rozpakowana baza i archiwum obrazów, czyli
mniej więcej 4–5× rozmiar `db-backup` plus media plus 0,7 GB. Limity RAM shadowa
są takie same jak w `test-upgrade` (`SHADOW_*_MEM`).

### Procedura (raz na kwartał)

1. `make proba-odtworzenia` w godzinach małego ruchu (pobranie i `pg_restore`
   obciążają dysk i sieć).
2. Skopiuj ostatnią linię wyniku z wyjścia albo z
   `$BPP_CONFIGS_DIR/logs/odtworzenie-serwera.log` do tabeli poniżej
   w dokumentacji instancji (wiki, notatka serwisowa).
3. Wynik `BLAD` traktuj jak awarię backupu: przyczyna jest w wyjściu (brak
   kompletu, uszkodzone archiwum, appserver nie wstaje na kopii), a log
   appservera shadow widać przy `KEEP_SHADOW=1`.
4. Co drugi kwartał przećwicz też ścieżkę **bez Huba**: na maszynie testowej
   `make restore-server OBRAZY=archiwum` z rclone na hoście.

Linia wyniku jest gotowym wierszem tabeli:

| Data | Tryb | Kopia | Czas | Wynik | Szczegóły |
|---|---|---|---|---|---|
| 2026-11-25 | proba | kopia 2026-11-24 01:45 | 12 min 31 s | OK | baza + media + konfiguracja (klucz zgodny), obrazy 20261120-014500 (bundle OK), / HTTP 302 |

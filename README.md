<a href="https://github.com/iplweb/bpp"><img src="https://github.com/iplweb/bpp/raw/dev/src/bpp/static/bpp/images/logo_bpp.png" align="right" width="120" alt="BPP Logo"></a>

# BPP Deploy

[![CI](https://github.com/iplweb/bpp-deploy/actions/workflows/ci.yml/badge.svg)](https://github.com/iplweb/bpp-deploy/actions/workflows/ci.yml)
![Version](https://img.shields.io/badge/version-2026.04.27.9-blue)

Konfiguracja wdrożeniowa systemu **[BPP (Bibliografia Publikacji Pracowników)](https://github.com/iplweb/bpp)** — orkiestracja Docker Compose z monitoringiem, backupami i automatyczną konfiguracją.

<p align="center">
  <b>Wsparcie komercyjne zapewnia</b><br><br>
  <a href="https://bpp.iplweb.pl"><img src="https://www.iplweb.pl/images/ipl-logo-large.png" width="150" alt="IPL Web"></a>
</p>

## Spis treści

- [Jak zainstalować i uruchomić system BPP przy pomocy bpp-deploy](#jak-zainstalować-i-uruchomić-system-bpp-przy-pomocy-bpp-deploy)
  - [Linux](#linux)
  - [macOS](#macos)
  - [Windows](#windows)
- [Wspólne kroki konfiguracji](#wspólne-kroki-konfiguracji)
- [Struktura katalogów](#struktura-katalogów)
- [Najważniejsze komendy](#najważniejsze-komendy)
- [Usługi](#usługi)
- [Rozwiązywanie problemów](#rozwiązywanie-problemów)
- [Jak rozwijać pakiet bpp-deploy](#jak-rozwijać-pakiet-bpp-deploy)
  - [Testy](#testy)
  - [Pre-commit hooks](#pre-commit-hooks)
- [Licencja](#licencja)

## Jak zainstalować i uruchomić system BPP przy pomocy bpp-deploy

Wybierz swój system operacyjny — instrukcje są podzielone na sekcje per-OS. Po zakończeniu kroków właściwych dla Twojego systemu przejdź do **[wspólnych kroków konfiguracji](#wspólne-kroki-konfiguracji)**, identycznych dla wszystkich platform.

| System | Instrukcja |
|--------|------------|
| 🐧 **Linux** (Debian / Ubuntu / Fedora / Arch / openSUSE) | [→ przejdź do instrukcji dla Linuksa](#linux) |
| 🍎 **macOS** (Intel + Apple Silicon) | [→ przejdź do instrukcji dla macOS](#macos) |
| 🪟 **Windows** (10 / 11) | [→ przejdź do instrukcji dla Windows](#windows) |

### Linux

Otwórz **Terminal** (zazwyczaj skrót `Ctrl+Alt+T` lub znajdziesz go w menu aplikacji).

Wybierz swoją dystrybucję i wpisz podane polecenia jedno po drugim:

<details>
<summary><b>Debian / Ubuntu</b></summary>

```bash
sudo apt update
sudo apt install -y git make openssl gettext
```

Zainstaluj Docker Engine — oficjalna instrukcja dla [Debian](https://docs.docker.com/engine/install/debian/) lub [Ubuntu](https://docs.docker.com/engine/install/ubuntu/) (zawiera Docker Compose).

</details>

<details>
<summary><b>Fedora</b></summary>

```bash
sudo dnf install -y git make openssl gettext
```

Zainstaluj Docker Engine — [oficjalna instrukcja dla Fedory](https://docs.docker.com/engine/install/fedora/) (zawiera Docker Compose).

</details>

<details>
<summary><b>Arch Linux</b></summary>

```bash
sudo pacman -Sy --noconfirm git make openssl gettext
```

Zainstaluj Docker Engine:

```bash
sudo pacman -Sy --noconfirm docker docker-compose
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

Wyloguj się i zaloguj ponownie, aby uprawnienia do Dockera zaczęły działać.

</details>

<details>
<summary><b>openSUSE</b></summary>

```bash
sudo zypper install -y git make openssl gettext-runtime
```

Zainstaluj Docker Engine — [oficjalna instrukcja dla SLES/openSUSE](https://docs.docker.com/engine/install/sles/) (zawiera Docker Compose).

</details>

Po zainstalowaniu narzędzi i Dockera, sklonuj repozytorium i przejdź do katalogu:

```bash
git clone https://github.com/iplweb/bpp-deploy.git
cd bpp-deploy
```

> **Podpowiedź:** Możesz też zainstalować Docker poleceniem `make install-docker` po sklonowaniu repo.

---

### macOS

Otwórz **Terminal** — znajdziesz go w Finderze pod ścieżką *Programy > Narzędzia > Terminal* (albo wyszukaj "Terminal" przez Spotlight: `Cmd+Spacja`).

Zainstaluj Xcode Command Line Tools (zawiera git i make). Wpisz w Terminalu:

```bash
xcode-select --install
```

Pojawi się okno z prośbą o potwierdzenie — kliknij **Zainstaluj** i poczekaj na zakończenie.

Zainstaluj [Docker Desktop dla macOS](https://docs.docker.com/desktop/install/mac-install/) — pobierz ze strony (wybierz wariant zgodny z Twoim Makiem: **Apple Silicon** dla M1/M2/M3/M4 lub **Intel** dla starszych modeli), otwórz plik `.dmg` i przeciągnij Docker do folderu Programy. Uruchom Docker Desktop i poczekaj, aż ikona w pasku menu przestanie się animować.

Zainstaluj `envsubst` (potrzebny do generowania konfiguracji). Jeśli nie masz jeszcze [Homebrew](https://brew.sh/), najpierw go zainstaluj, a potem wpisz w Terminalu:

```bash
brew install gettext
```

Sklonuj repozytorium i przejdź do katalogu:

```bash
git clone https://github.com/iplweb/bpp-deploy.git
cd bpp-deploy
```

---

### Windows

Pobierz i zainstaluj (klikając "Dalej" w instalatorach):

- [Git for Windows](https://gitforwindows.org/) — dostarcza **Git Bash**, czyli terminal z narzędziami Unix
- [Docker Desktop for Windows](https://docs.docker.com/desktop/install/windows-install/) — po instalacji uruchom Docker Desktop i poczekaj, aż ikona w zasobniku przestanie się animować

Zainstaluj GNU Make. Otwórz **PowerShell jako Administrator** (kliknij prawym przyciskiem na menu Start > "Terminal (Administrator)" lub "Windows PowerShell (Administrator)") i wpisz:

```powershell
choco install make
```

Jeśli nie masz [Chocolatey](https://chocolatey.org/install), możesz zamiast tego użyć [Scoop](https://scoop.sh/):

```powershell
scoop install make
```

Otwórz **Git Bash** (znajdziesz go w menu Start po wpisaniu "Git Bash") i sklonuj repozytorium:

```bash
git clone https://github.com/iplweb/bpp-deploy.git
cd bpp-deploy
```

> **Ważne:** Od tego momentu wszystkie komendy `make` uruchamiaj w **Git Bash**, nie w CMD ani PowerShell.

## Wspólne kroki konfiguracji

Poniższe kroki wykonujesz po zakończeniu instrukcji właściwych dla Twojego systemu operacyjnego. Są identyczne dla Linux, macOS i Windows.

### 1. Pierwsze uruchomienie

```bash
make
```

Przy pierwszym uruchomieniu `make` zapyta o ścieżkę do **katalogu konfiguracyjnego** — musi znajdować się poza repozytorium. Jego nazwa stanie się nazwą projektu Docker Compose.

```
=== BPP Deploy - pierwsze uruchomienie ===

Podaj sciezke do katalogu konfiguracyjnego instancji BPP.
Katalog musi znajdowac sie POZA repozytorium.

Przyklad: /home/deploy/publikacje-uczelnia

Sciezka: /home/deploy/moja-instancja
```

`make` automatycznie:
- utworzy strukturę katalogów konfiguracyjnych,
- skopiuje szablonowe pliki z `defaults/`,
- wygeneruje losowe hasła do bazy danych,
- utworzy plik `.env` z konfiguracją.

### 2. Sprawdź i dostosuj konfigurację

Otwórz plik `.env` z katalogu konfiguracyjnego w dowolnym edytorze tekstu (np. Notepad, VS Code, nano, vim):

```
# Ścieżka wyświetli się po pierwszym uruchomieniu make, np.:
# /home/deploy/moja-instancja/.env
```

Co trzeba zmienić w `.env`:
- `DJANGO_BPP_HOSTNAME` — właściwa nazwa hosta (np. `publikacje.uczelnia.pl`)
- `DJANGO_BPP_CSRF_EXTRA_ORIGINS` — dozwolone originy CSRF
- Sprawdź wygenerowane hasła (opcjonalnie)

Dodaj certyfikaty SSL (lub wygeneruj samopodpisane):
```bash
# Opcja A: własne certyfikaty — skopiuj cert.pem i key.pem
#          do podkatalogu ssl/ w katalogu konfiguracyjnym

# Opcja B: samopodpisane certyfikaty (snakeoil) do testów
make generate-snakeoil-certs
```

### 3. Uruchom usługi

```bash
make run
```

### 4. Otwórz aplikację w przeglądarce

Po uruchomieniu `make run` główny serwis jest dostępny przez `webserver` (Nginx), który wystawia standardowe porty HTTP i HTTPS:

- `80:80`
- `443:443`

Na Docker Desktop pod macOS oznacza to, że porty są mapowane na hosta macOS. Aplikację otwierasz więc w przeglądarce przez adres hosta, a nie przez wewnętrzne porty kontenerów.

Zalecane warianty konfiguracji lokalnej:

- ustaw `DJANGO_BPP_HOSTNAME=localhost` i otwórz `https://localhost/`
- albo ustaw własną nazwę, np. `bpp.local`, dodaj ją do `/etc/hosts`, a następnie otwórz `https://bpp.local/`

Uwaga: Nginx akceptuje tylko hostname zgodny z `DJANGO_BPP_HOSTNAME`. Jeśli w konfiguracji ustawisz inną nazwę hosta, wejście przez `localhost` może nie działać poprawnie mimo poprawnego mapowania portów.

Przy pierwszym uruchomieniu, jeśli baza danych jest pusta, aplikacja automatycznie przekieruje do `/setup/`. Jest to oczekiwane zachowanie kreatora konfiguracji początkowej, w którym tworzysz pierwsze konto administratora.

Dodatkowe narzędzia administracyjne i monitoring nie są wystawiane jako osobne porty hosta. Są dostępne przez Nginx pod ścieżkami:

- `https://<hostname>/grafana/`
- `https://<hostname>/flower/`
- `https://<hostname>/dozzle/`

## Struktura katalogów

```
~/
├── bpp-deploy/                     # To repozytorium
│   ├── .env                        # Wskazuje katalog konfiguracyjny
│   ├── Makefile
│   ├── docker-compose.*.yml
│   ├── mk/                         # Moduły Makefile
│   ├── defaults/             # Szablonowe pliki konfiguracyjne
│   └── tests/
│
├── moja-instancja/                 # Katalog konfiguracyjny (BPP_CONFIGS_DIR)
│   ├── .env                        # Zmienne aplikacyjne (hasła, hostname)
│   ├── ssl/                        # Certyfikaty SSL
│   ├── alloy/                      # Konfiguracja Grafana Alloy
│   ├── prometheus/                 # Konfiguracja Prometheus
│   ├── grafana/provisioning/       # Dashboardy i datasources Grafana
│   ├── rclone/                     # Konfiguracja backupów
│   └── dozzle/                     # Użytkownicy Dozzle
│
└── backups/                        # Backupy baz danych
```

## Najważniejsze komendy

```bash
make help             # Pełna lista wszystkich targetów Make (źródło prawdy)
```

### Wdrożenie

```bash
make run              # Pełne wdrożenie (pull, build, configs, up)
make up               # Start wszystkich usług (force recreate)
make up-quick         # Szybki start bez recreation
make refresh          # prune + pull + recreate (po update obrazu)
make wait             # Czeka na build z GH Actions, potem make refresh
make stop             # Zatrzymaj usługi
make restart-appserver  # Restart serwera aplikacji
```

### Baza danych

```bash
make migrate          # Migracje Django (bezpiecznie zatrzymuje workery)
make db-backup        # Backup bazy (równoległy pg_dump, tar.gz)
make dbshell          # Django database shell
make dbshell-psql     # Bezpośredni psql
make upgrade-postgres # Upgrade major wersji PostgreSQL (np. 16.13 -> 18.3)
```

### Monitoring i logi

```bash
make health           # Szybki healthcheck wszystkich usług
make logs-appserver   # Logi serwera aplikacji
make logs-celery      # Logi workerów Celery
make ps               # Lista kontenerów
make celery-stats     # Statystyki zadań Celery
```

### Konfiguracja

```bash
make update-configs     # Regeneruj datasources.yaml (envsubst)
make update-ssl-certs   # Przeładuj nginx po zmianie certyfikatów
make init-configs       # Uzupełnij brakujące pliki w katalogu konfiguracyjnym
make configure-resources # Dostrój limity RAM/CPU dla wszystkich serwisów
make generate-snakeoil-certs  # Wygeneruj samopodpisane certyfikaty SSL
```

#### Limity zasobów (`make configure-resources`)

Podczas pierwszego uruchomienia `make` skrypt `configure-resources` jest odpalany automatycznie — wykrywa RAM i liczbę rdzeni hosta, proponuje proporcjonalny podział budżetu między 7 serwisów wysokiego ryzyka (dbserver, appserver, workerserver-general/denorm, redis, loki, prometheus) i pyta użytkownika o akceptację każdej wartości. Jeżeli odstąpisz od zaproponowanego defaultu dla któregoś serwisu, pozostałe mają swój budżet proporcjonalnie powiększony lub zmniejszony.

Docker traktuje limit RAM jako **twardy** (przekroczenie → OOM kill), a CPU jako **miękki** (throttling bez zabijania). RAM ustawiaj z zapasem.

Wynik ląduje w `$BPP_CONFIGS_DIR/.env` jako zmienne `DBSERVER_MEM_LIMIT`, `APPSERVER_MEM_LIMIT` itd. Możesz wrócić i przekonfigurować w każdej chwili uruchamiając `make configure-resources` ręcznie.

### Wersja serwera PostgreSQL

Kontener `dbserver` używa obrazu `iplweb/bpp_dbserver:psql-<MAJOR.MINOR>`. Wersja jest sterowana zmienną `DJANGO_BPP_POSTGRESQL_VERSION` w `$BPP_CONFIGS_DIR/.env` (obok jest auto-derived `DJANGO_BPP_POSTGRESQL_VERSION_MAJOR` używana przez backup-runnera `postgres:<major>-alpine`). Aktualna lista tagów: [hub.docker.com/r/iplweb/bpp_dbserver/tags](https://hub.docker.com/r/iplweb/bpp_dbserver/tags) (np. `16.13`, `17.9`, `18.3`).

**Domyślna wersja**: `16.13`. Wybór wersji następuje przy pierwszym uruchomieniu `make` — skrypt `init-configs` zapyta o `Wersja PostgreSQL [16.13]:`. Możesz wpisać dowolną dostępną na Docker Hub.

#### Minor upgrade (ta sama wersja major, np. 16.13 → 16.14)

Format PGDATA jest binarnie kompatybilny w obrębie tego samego majora, więc wystarczy zmiana tagu i restart:

```bash
# 1. W $BPP_CONFIGS_DIR/.env zmień: DJANGO_BPP_POSTGRESQL_VERSION=16.14
# 2. Pobierz nowy obraz i odśwież kontener:
docker compose pull dbserver
docker compose up -d dbserver
```

#### Major upgrade (np. 16.13 → 18.3)

Między różnymi major wersjami PostgreSQL **nie ma binarnej kompatybilności formatu PGDATA** — każdy nowy kontener musi wystartować na pustym, świeżo zainicjalizowanym wolumenie. Dane przenosi się metodą *logical dump & restore*:

```bash
make upgrade-postgres
```

Skrypt interaktywnie wykonuje 9 kroków (dump → kopia volume → bump `.env` → initdb na nowym majorze → restore → migracje), z **automatycznym rollbackiem** w razie nieudanego startu nowej bazy oraz trybem **resume** (`--from-step=N`) pozwalającym wznowić po błędzie bez powtarzania długiego dumpu.

**Wymagania**:
- Obraz `iplweb/bpp_dbserver:psql-<nowa_wersja>` musi być opublikowany na Docker Hub.
- Wolne miejsce: ~2.5× rozmiar PGDATA (tarball + kopia starego volume).
- Stack musi być uruchomiony (`make up`), żeby wykonać `pg_dump`.

Pełna dokumentacja kroków, rollbacku i resume:

```bash
bash scripts/upgrade-postgres.sh --help
```

**Tryb external** (`BPP_DATABASE_COMPOSE=docker-compose.database.external.yml`): upgrade samej bazy wykonujesz po swojej stronie (managed service, RDS blue/green, `pg_upgradecluster` itp.), a skrypt tylko synchronizuje `DJANGO_BPP_POSTGRESQL_VERSION` + `_MAJOR` i odświeża sentinel/backup-runner.

### Backup

```bash
make db-backup        # Pojedynczy pg_dump (równoległy, tar.gz)
make backup-cycle     # Pełen cykl: pg_dump + tar mediów + rclone + powiadomienia
make rclone-config    # Konfiguracja zdalnego backupu (Google Drive, S3, ...)
make rclone-sync      # Wymuszona synchronizacja z chmurą
make rclone-check     # Sprawdzenie spójności kopii zdalnej
```

Codzienny backup uruchamia Ofelia o `02:30` — opisane szerzej w sekcji [Usługi](#usługi).

### Wydanie

```bash
make release          # Tag + push: YYYY.MM.DD lub YYYY.MM.DD.N (calendar versioning)
make version          # Wyświetl bieżącą wersję
```

### Zarządzanie hostem

```bash
make base-host-update-upgrade  # Aktualizacja systemu (apt update + full-upgrade)
make base-host-reboot          # Restart hosta
make install-docker            # Instalacja Dockera na hoście
```

## Usługi

| Usługa | Opis |
|--------|------|
| **appserver** | Serwer aplikacji Django |
| **authserver** | Serwer uwierzytelniania dla nginx |
| **dbserver** | PostgreSQL |
| **webserver** | Nginx (reverse proxy + static files) |
| **redis** | Cache, broker Celery i result backend |
| **workerserver-general** | Ogólne zadania Celery |
| **workerserver-denorm** | Zadania denormalizacji |
| **denorm-queue** | Bridge PostgreSQL LISTEN → Celery (single instance!) |
| **celerybeat** | Harmonogram zadań okresowych |
| **flower** | UI monitorowania Celery (`/flower`) |
| **grafana** | Dashboardy i wizualizacje (`/grafana`) |
| **prometheus** | Metryki |
| **loki** | Agregacja logów |
| **alloy** | Kolektor logów z kontenerów Docker |
| **dozzle** | Przeglądarka logów w czasie rzeczywistym (`/dozzle`) |
| **rclone** | Backup do chmury |
| **ofelia** | Cron dla Dockera |

## Rozwiązywanie problemów

#### Porty 80/443 są zajęte

Symptom: `make up` kończy się błędem `bind: address already in use` na `webserver`. Lokalna instalacja nginx, Apache lub innego serwera zajmuje porty.

```bash
# Sprawdź, kto trzyma port:
sudo lsof -iTCP:80 -sTCP:LISTEN
sudo lsof -iTCP:443 -sTCP:LISTEN
```

Zatrzymaj kolidującą usługę (`sudo systemctl stop nginx`) albo zmień mapowanie portów w `docker-compose.infrastructure.yml` (np. `8080:80`, `8443:443`) — pamiętaj o zaktualizowaniu URL-i, którymi otwierasz aplikację.

#### Przeglądarka pokazuje ostrzeżenie o niezaufanym certyfikacie

Symptom: po `make generate-snakeoil-certs` przeglądarka blokuje stronę z komunikatem `NET::ERR_CERT_AUTHORITY_INVALID` lub podobnym.

To certyfikat **samopodpisany** — przewidziany do testów lokalnych. Opcje:

- **Lokalnie**: kliknij „Zaawansowane" → „Mimo to przejdź do strony" (Chrome/Edge) lub „Zaakceptuj ryzyko" (Firefox).
- **Produkcyjnie**: wystaw prawdziwy certyfikat przez Let's Encrypt / komercyjne CA i podmień `cert.pem`/`key.pem` w katalogu `ssl/` w `$BPP_CONFIGS_DIR`. Następnie `make update-ssl-certs`.

#### `permission denied` przy `docker compose` (Linux)

Symptom: `Got permission denied while trying to connect to the Docker daemon socket`.

Twój użytkownik nie należy do grupy `docker`:

```bash
sudo usermod -aG docker $USER
# Wyloguj się i zaloguj ponownie, albo:
newgrp docker
```

#### Setup wizard `/setup/` się nie pokazuje

Symptom: aplikacja zamiast `/setup/` rzuca błąd 500 lub przekierowuje na login. Najczęstsza przyczyna: migracje nie zostały uruchomione na pustej bazie.

```bash
make migrate
make logs-appserver  # Sprawdź, czy migracje przeszły bez błędu
```

#### Worker / appserver się restartuje w kółko

Symptom: `make ps` pokazuje status `restarting` albo `unhealthy`.

```bash
make health                    # Globalny przegląd
make logs-<service>            # Zastąp <service> nazwą z make ps
docker compose logs --tail=200 <service>
```

Najczęstsze przyczyny: brak migracji bazy (uruchom `make migrate`), brak połączenia z Redis (sprawdź czy `redis` jest healthy), niepoprawne wartości w `.env`.

#### Po `git pull` coś się rozjechało

Symptom: nowe usługi się nie pojawiają, obrazy są stare, `.env` nie ma nowych zmiennych.

```bash
make init-configs   # Uzupełnia brakujące zmienne w .env (idempotentne)
make refresh        # prune + pull + recreate całego stacku
```

Backwards compatibility jest gwarantowana — `bpp-deploy` zawsze startuje na starym `.env` (patrz `CLAUDE.md`, sekcja „Backwards Compatibility"). Jeśli mimo to coś nie działa, zgłoś issue.

## Jak rozwijać pakiet bpp-deploy

> **Zakres:** ta sekcja dotyczy wyłącznie rozwoju **`bpp-deploy`** — czyli orkiestracji Docker Compose, Makefile, skryptów konfiguracyjnych i monitoringu opisanych w tym repozytorium.
>
> Rozwój **samej aplikacji BPP** (kod Django w `/src/`, modele, widoki, importery, integracje z PBN, ORCID itd.) odbywa się w osobnym repozytorium: **[github.com/iplweb/bpp](https://github.com/iplweb/bpp)** — tam też znajdziesz dokumentację dla developerów aplikacji.

### Testy

```bash
./tests/test_makefile.sh
```

Testy weryfikują orkiestrację `bpp-deploy`:
- first-run setup (tworzenie konfiguracji, generowanie haseł)
- idempotentność `init-configs`
- losowość haseł między instancjami
- dostępność targetów Make w trybie normalnym
- poprawność bind mountów w docker-compose
- brak mechanizmów SCP w konfiguracji

### Pre-commit hooks

Repozytorium używa [pre-commit](https://pre-commit.com/) z następującymi hookami:

- **trailing-whitespace**, **end-of-file-fixer** — formatowanie
- **check-yaml** — walidacja YAML
- **check-merge-conflict** — wykrywanie konfliktów merge
- **detect-private-key** — blokada kluczy prywatnych
- **shellcheck** — linter bash
- **TruffleHog** — wykrywanie sekretów i haseł

```bash
pip install pre-commit
pre-commit install
```

## Licencja

MIT

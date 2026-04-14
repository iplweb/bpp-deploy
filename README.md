<a href="https://github.com/iplweb/bpp"><img src="https://github.com/iplweb/bpp/raw/dev/src/bpp/static/bpp/images/logo_bpp.png" align="right" width="120" alt="BPP Logo"></a>

# BPP Deploy

[![CI](https://github.com/iplweb/bpp-deploy/actions/workflows/ci.yml/badge.svg)](https://github.com/iplweb/bpp-deploy/actions/workflows/ci.yml)
![Version](https://img.shields.io/badge/version-2026.04.14-blue)

Konfiguracja wdrożeniowa systemu **[BPP (Bibliografia Publikacji Pracowników)](https://github.com/iplweb/bpp)** — orkiestracja Docker Compose z monitoringiem, backupami i automatyczną konfiguracją.

<p align="center">
  <b>Wsparcie komercyjne zapewnia</b><br><br>
  <a href="https://bpp.iplweb.pl"><img src="https://www.iplweb.pl/images/ipl-logo-large.png" width="150" alt="IPL Web"></a>
</p>

## Instalacja

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

Otwórz **Terminal** — znajdziesz go w Finderze pod sciezką *Aplikacje > Narzędzia > Terminal* (albo wyszukaj "Terminal" przez Spotlight: `Cmd+Spacja`).

Zainstaluj Xcode Command Line Tools (zawiera git i make). Wpisz w Terminalu:

```bash
xcode-select --install
```

Pojawi się okno z prośbą o potwierdzenie — kliknij **Zainstaluj** i poczekaj na zakończenie.

Zainstaluj [Docker Desktop dla macOS](https://docs.docker.com/desktop/install/mac-install/) — pobierz ze strony, otwórz plik `.dmg` i przeciągnij Docker do folderu Aplikacje. Uruchom Docker Desktop i poczekaj, aż ikona w pasku menu przestanie się animować.

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

#### 1. Zainstaluj potrzebne programy

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

#### 2. Sklonuj repozytorium

Otwórz **Git Bash** (znajdziesz go w menu Start po wpisaniu "Git Bash"). Wpisz:

```bash
git clone https://github.com/iplweb/bpp-deploy.git
cd bpp-deploy
```

> **Ważne:** Od tego momentu wszystkie komendy `make` uruchamiaj w **Git Bash**, nie w CMD ani PowerShell.

## Szybki start

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
- wygeneruje losowe hasła do bazy danych i RabbitMQ,
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
- `https://<hostname>/rabbitmq/`

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
│   ├── rabbitmq/                   # Pluginy RabbitMQ
│   ├── rclone/                     # Konfiguracja backupów
│   └── dozzle/                     # Użytkownicy Dozzle
│
└── backups/                        # Backupy baz danych
```

## Najważniejsze komendy

### Wdrożenie

```bash
make run              # Pełne wdrożenie (pull, build, configs, up)
make up               # Start wszystkich usług (force recreate)
make up-quick         # Szybki start bez recreation
make stop             # Zatrzymaj usługi
make restart-appserver  # Restart serwera aplikacji
```

### Baza danych

```bash
make migrate          # Migracje Django (bezpiecznie zatrzymuje workery)
make db-backup        # Backup bazy (równoległy pg_dump, tar.gz)
make dbshell          # Django database shell
make dbshell-psql     # Bezpośredni psql
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
make generate-snakeoil-certs  # Wygeneruj samopodpisane certyfikaty SSL
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
| **redis** | Cache i broker Celery |
| **rabbitmq** | Broker wiadomości |
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

## Testy

```bash
./tests/test_makefile.sh
```

Testy weryfikują:
- first-run setup (tworzenie konfiguracji, generowanie haseł)
- idempotentność `init-configs`
- losowość haseł między instancjami
- dostępność targetów Make w trybie normalnym
- poprawność bind mountów w docker-compose
- brak mechanizmów SCP w konfiguracji

## Pre-commit hooks

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

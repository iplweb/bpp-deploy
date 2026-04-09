<a href="https://github.com/iplweb/bpp"><img src="https://github.com/iplweb/bpp/raw/dev/src/bpp/static/bpp/images/logo_bpp.png" align="right" width="120" alt="BPP Logo"></a>

# BPP Deploy

[![CI](https://github.com/iplweb/bpp-deploy/actions/workflows/ci.yml/badge.svg)](https://github.com/iplweb/bpp-deploy/actions/workflows/ci.yml)
![Version](https://img.shields.io/badge/version-0.0.0-blue)

Konfiguracja wdrożeniowa systemu **[BPP (Bibliografia Publikacji Pracowników)](https://github.com/iplweb/bpp)** — orkiestracja Docker Compose z monitoringiem, backupami i automatyczną konfiguracją.

<p align="center">
  <b>Wsparcie komercyjne zapewnia</b><br><br>
  <a href="https://bpp.iplweb.pl"><img src="https://www.iplweb.pl/images/ipl-logo-large.png" width="150" alt="IPL Web"></a>
</p>

## Instalacja

### Linux (Debian/Ubuntu)

Zainstaluj podstawowe narzędzia:

```bash
$ sudo apt update
$ sudo apt install -y git make openssl gettext
```

Zainstaluj Docker Engine — oficjalna instrukcja dla [Debian](https://docs.docker.com/engine/install/debian/) lub [Ubuntu](https://docs.docker.com/engine/install/ubuntu/) (zawiera Docker Compose).

Sklonuj repozytorium i przejdź do katalogu:

```bash
$ git clone https://github.com/iplweb/bpp-deploy.git
$ cd bpp-deploy
```

> **Podpowiedź:** Możesz też zainstalować Docker poleceniem `make install-docker` po sklonowaniu repo.

---

### macOS

Zainstaluj Xcode Command Line Tools (zawiera git i make):

```bash
$ xcode-select --install
```

Zainstaluj [Docker Desktop dla macOS](https://docs.docker.com/desktop/install/mac-install/) — zawiera Docker Engine i Docker Compose.

Zainstaluj `envsubst` (potrzebny do generowania konfiguracji):

```bash
$ brew install gettext
```

Sklonuj repozytorium i przejdź do katalogu:

```bash
$ git clone https://github.com/iplweb/bpp-deploy.git
$ cd bpp-deploy
```

---

### Windows

Zainstaluj [Git for Windows](https://gitforwindows.org/) — dostarcza Git Bash z narzędziami Unix (bash, grep, sed, openssl).

Zainstaluj [Docker Desktop for Windows](https://docs.docker.com/desktop/install/windows-install/) — zawiera Docker Engine i Docker Compose.

Zainstaluj GNU Make — najprościej przez [Chocolatey](https://chocolatey.org/install):

```bash
$ choco install make
```

...lub przez [Scoop](https://scoop.sh/):

```bash
$ scoop install make
```

Otwórz **Git Bash** i sklonuj repozytorium:

```bash
$ git clone https://github.com/iplweb/bpp-deploy.git
$ cd bpp-deploy
```

> **Ważne:** Wszystkie komendy `make` uruchamiaj w **Git Bash**, nie w CMD ani PowerShell.

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

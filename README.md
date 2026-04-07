<a href="https://github.com/iplweb/bpp"><img src="https://github.com/iplweb/bpp/raw/dev/src/bpp/static/bpp/images/logo_bpp.png" align="right" width="120" alt="BPP Logo"></a>

# BPP Deploy

[![CI](https://github.com/iplweb/bpp-deploy/actions/workflows/ci.yml/badge.svg)](https://github.com/iplweb/bpp-deploy/actions/workflows/ci.yml)

Konfiguracja wdrożeniowa systemu **[BPP (Bibliografia Publikacji Pracowników)](https://github.com/iplweb/bpp)** — orkiestracja Docker Compose z monitoringiem, backupami i automatyczną konfiguracją.

<p align="center">
  <b>Wsparcie komercyjne zapewnia</b><br><br>
  <a href="https://bpp.iplweb.pl"><img src="https://www.iplweb.pl/images/ipl-logo-large.png" width="150" alt="IPL Web"></a>
</p>

## Wymagania

- [Git](https://git-scm.com/downloads) — system kontroli wersji
- [Docker Engine](https://docs.docker.com/engine/install/) 24+ z [Docker Compose](https://docs.docker.com/compose/install/) v2.20+
- [GNU Make](https://www.gnu.org/software/make/) — automatyzacja zadań
- `openssl` (do generowania haseł, zazwyczaj preinstalowany)
- `envsubst` (zazwyczaj w pakiecie `gettext`)

### Instalacja na Linux (Debian/Ubuntu)

1. Zainstaluj narzędzia systemowe:
   ```bash
   sudo apt update && sudo apt install -y git make openssl gettext
   ```
2. Zainstaluj [Docker Engine dla Debian](https://docs.docker.com/engine/install/debian/) lub [Docker Engine dla Ubuntu](https://docs.docker.com/engine/install/ubuntu/) (zawiera Docker Compose)
   — lub po sklonowaniu repo: `make install-docker`

### Instalacja na macOS

1. Zainstaluj Xcode Command Line Tools (zawiera git i make):
   ```bash
   xcode-select --install
   ```
2. Zainstaluj [Docker Desktop dla macOS](https://docs.docker.com/desktop/install/mac-install/) — zawiera Docker Engine i Docker Compose
3. Zainstaluj `envsubst`:
   ```bash
   brew install gettext
   ```

### Instalacja na Windows

1. Zainstaluj [Git for Windows](https://gitforwindows.org/) — dostarcza Git Bash z narzędziami Unix (bash, grep, sed, openssl)
2. Zainstaluj [Docker Desktop for Windows](https://docs.docker.com/desktop/install/windows-install/) — zawiera Docker Engine i Docker Compose
3. Zainstaluj GNU Make — najprościej przez [Chocolatey](https://chocolatey.org/install):
   ```
   choco install make
   ```
   lub przez [Scoop](https://scoop.sh/):
   ```
   scoop install make
   ```
4. Wszystkie komendy `make` uruchamiaj w **Git Bash** (nie w CMD ani PowerShell)

## Szybki start

### 1. Sklonuj repozytorium

```bash
git clone https://github.com/iplweb/bpp-deploy.git
cd bpp-deploy
```

### 2. Pierwsze uruchomienie

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

### 3. Sprawdź i dostosuj konfigurację

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

### 4. Uruchom usługi

```bash
make run
```

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
